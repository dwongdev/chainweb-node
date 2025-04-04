{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Cut.Create
-- Copyright: Copyright © 2020 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- The steps for extending a Cut with a new Block are usually as follows:
--
-- 1. Select a chain for the new Block header
-- 2. Call 'getCutExtension'. If the result is 'Nothing' the chain is
--    blocked. In which case another chain must be choosen.
-- 3. Call pact service to create new payload for the new block
-- 4. Assemble preliminary work header, with preliminary time and nonce value
--    (time should be current time, nonce should be 0) and send work header
--    to the miner.
-- 5. Receive resolved header (with final nonce and creation time) from miner
-- 6. Create new header by computing the merkle hash for the resolved header
-- 7. Extend cut with new header by calling 'tryMonotonicCutExtension'
-- 8. Create new cut hashes with the new header and payload attached.
-- 9. Submit cut hashes (along with attached new header and payload) to cut
--    validation pipeline.
--
module Chainweb.Cut.Create
(
-- * Cut Extension
  CutExtension
, _cutExtensionCut
, cutExtensionCut
, _cutExtensionParent
, cutExtensionParent
, _cutExtensionAdjacentHashes
, cutExtensionAdjacentHashes
, getCutExtension

-- * Work
, WorkHeader(..)
, encodeWorkHeader
, decodeWorkHeader
, workOnHeader
, newHeaderForPayload
, newHeaderForPayloadPure

-- * Solved Work
, SolvedWork
, encodeSolvedWork
, decodeSolvedWork
, solvedWorkPayloadHash
, makeSolvedWork
, extend
, InvalidSolvedHeader(..)
, extendCut
) where

import Control.DeepSeq
import Control.Lens
import Control.Monad
import Control.Monad.Catch

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SB
import Data.HashMap.Strict qualified as HM
import Data.HashSet qualified as HS
import Data.Text qualified as T

import GHC.Generics
import GHC.Stack

-- internal modules

import Chainweb.BlockCreationTime
import Chainweb.BlockHash
import Chainweb.BlockHeader.Internal
import Chainweb.BlockHeader.Validation
import Chainweb.BlockHeight
import Chainweb.ChainValue
import Chainweb.Cut
import Chainweb.Cut.CutHashes
import Chainweb.Difficulty
import Chainweb.Payload
import Chainweb.Time
import Chainweb.Utils
import Chainweb.Utils.Serialization
import Chainweb.Version
import Chainweb.Version.Utils

-- -------------------------------------------------------------------------- --
-- Adjacent Parent Hashes

-- | Witnesses that a cut can be extended for the respective header.
--
data CutExtension = CutExtension
    { _cutExtensionCut' :: !Cut
        -- ^ the cut which is to be extended
        --
        -- This is overly restrictive, since the same cut extension can be
        -- valid for more than one cut. It's fine for now.
    , _cutExtensionParent' :: !ParentHeader
        -- ^ the header onto which the new block is created. It is expected
        -- that this header is contained in the cut.
    , _cutExtensionAdjacentHashes' :: !BlockHashRecord
    }
    deriving (Show, Eq, Generic)

makeLenses ''CutExtension

_cutExtensionCut :: CutExtension -> Cut
_cutExtensionCut = _cutExtensionCut'

cutExtensionCut :: Lens' CutExtension Cut
cutExtensionCut = cutExtensionCut'

-- | The header onto which the new block is created.
--
_cutExtensionParent :: CutExtension -> ParentHeader
_cutExtensionParent = _cutExtensionParent'

-- | The header onto which the new block is created.
--
cutExtensionParent :: Lens' CutExtension ParentHeader
cutExtensionParent = cutExtensionParent'

_cutExtensionAdjacentHashes :: CutExtension -> BlockHashRecord
_cutExtensionAdjacentHashes = _cutExtensionAdjacentHashes'

cutExtensionAdjacentHashes :: Lens' CutExtension BlockHashRecord
cutExtensionAdjacentHashes = cutExtensionAdjacentHashes'

instance HasChainId CutExtension where
    _chainId = _chainId . _cutExtensionParent
    {-# INLINE _chainId #-}

instance HasChainwebVersion CutExtension where
    _chainwebVersion = _chainwebVersion . _cutExtensionCut
    {-# INLINE _chainwebVersion #-}

-- | Witness that a cut can be extended for the given chain by trying to
-- assemble the adjacent hashes for a new work header.
--
-- complexity: O(degree(Graph))
--
-- Generally, adajacent validation uses the graph of the parent header. This
-- ensures that during a graph transition the current header and all
-- dependencies use the same graph and the inductive validation step works
-- without special cases. Genesis headers don't require validation, because they
-- are hard-coded. Only in the first step after the transition, the dependencies
-- have a different graph. But at this point all dependencies exist.
--
-- A transition cut is a cut where the graph of minimum height header is
-- different than the graph of the header of maximum height. If this is a
-- transition cut, i.e. the cut contains block headers with different graphs, we
-- wait until all chains transitions to the new graph before add the genesis
-- blocks for the new chains and move ahead. So steps in the new graph are not
-- allowed.
--
-- TODO: it is important that the semantics of this function corresponds to the
-- respective validation in the module "Chainweb.Cut", in particular
-- 'isMonotonicCutExtension'. It must not happen, that a cut passes validation
-- that can't be further extended.
--
getCutExtension
    :: HasCallStack
    => HasChainId cid
    => Cut
        -- ^ the cut which is to be extended
    -> cid
        -- ^ the chain which is to be extended
    -> Maybe CutExtension
getCutExtension c cid = do

    -- In a graph transition we wait for all chains to do the transition to the
    -- new graph before moving ahead. Blocks chains that reach the new graph
    -- until all chains have reached the new graph.
    --
    guard (not $ isGraphTransitionCut && isGraphTransitionPost)

    as <- BlockHashRecord <$> newAdjHashes parentGraph

    return CutExtension
        { _cutExtensionCut' = c
        , _cutExtensionParent' = ParentHeader p
        , _cutExtensionAdjacentHashes' = as
        }
  where
    p = c ^?! ixg (_chainId cid)
    v = _chainwebVersion c
    parentHeight = view blockHeight p
    targetHeight = parentHeight + 1
    parentGraph = chainGraphAt p parentHeight

    -- true if the parent height is the first of a new graph.
    isGraphTransitionPost = isGraphChange c parentHeight

    -- true if a graph transition occurs in the cut.
    isGraphTransitionCut = _cutIsTransition c
        -- this is somewhat expensive

    -- | Try to get all adjacent hashes dependencies for the given graph.
    --
    newAdjHashes :: ChainGraph -> Maybe (HM.HashMap ChainId BlockHash)
    newAdjHashes g =
        imapM (\xcid _ -> hashForChain xcid)
        $ HS.toMap -- converts to Map Foo ()
        $ adjacentChainIds g p

    hashForChain acid
        -- existing chain
        | Just b <- lookupCutM acid c = tryAdj b
        | targetHeight == genesisHeight v acid = error $ T.unpack
            $ "getAdjacentParents: invalid cut extension, requested parent of a genesis block for chain "
            <> sshow acid
            <> ".\n Parent: " <> encodeToText (ObjectEncoded p)
        | otherwise = error $ T.unpack
            $ "getAdjacentParents: invalid cut, can't find adjacent hash for chain "
            <> sshow acid
            <> ".\n Cut: " <> sshow c

    tryAdj :: BlockHeader -> Maybe BlockHash
    tryAdj b

        -- When the block is behind, we can move ahead
        | view blockHeight b == targetHeight = Just $! view blockParent b

        -- if the block is ahead it's blocked
        | view blockHeight b + 1 == parentHeight = Nothing -- chain is blocked

        -- If this is not a graph transition cut we can move ahead
        | view blockHeight b == parentHeight = Just $! view blockHash b

        -- The cut is invalid
        | view blockHeight b > targetHeight = error $ T.unpack
            $ "getAdjacentParents: detected invalid cut (adjacent parent too far ahead)."
            <> "\n Parent: " <> encodeToText (ObjectEncoded p)
            <> "\n Conflict: " <> encodeToText (ObjectEncoded b)
        | view blockHeight b + 1 < parentHeight = error $ T.unpack
            $ "getAdjacentParents: detected invalid cut (adjacent parent too far behind)."
            <> "\n Parent: " <> encodeToText (ObjectEncoded  p)
            <> "\n Conflict: " <> encodeToText (ObjectEncoded b)
        | otherwise = error
            $ "Chainweb.Miner.Coordinator.getAdjacentParents: internal code invariant violation"

-- -------------------------------------------------------------------------- --
-- Mining Work Header

-- | A work header has a preliminary creation time and an invalid nonce of 0.
-- It is the job of the miner to update the creation time and find a valid nonce
-- that satisfies the target of the header.
--
-- The updated header has type 'SolvedHeader'.
--
data WorkHeader = WorkHeader
    { _workHeaderChainId :: !ChainId
    , _workHeaderTarget :: !HashTarget
    , _workHeaderBytes :: !SB.ShortByteString
        -- ^ 286 work bytes.
        -- The last 8 bytes are the nonce
        -- The creation time is encoded in bytes 8-15
    }
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (NFData)

encodeWorkHeader :: WorkHeader -> Put
encodeWorkHeader wh = do
    encodeChainId $ _workHeaderChainId wh
    encodeHashTarget $ _workHeaderTarget wh
    putByteString $ SB.fromShort $ _workHeaderBytes wh

-- FIXME: We really want this indepenent of the block height. For production
-- chainweb version this is actually the case.
--
decodeWorkHeader :: ChainwebVersion -> BlockHeight -> Get WorkHeader
decodeWorkHeader ver h = WorkHeader
    <$> decodeChainId
    <*> decodeHashTarget
    <*> (SB.toShort <$> getByteString (int $ workSizeBytes ver h))

workOnHeader :: BlockHeader -> WorkHeader
workOnHeader nh = WorkHeader
    { _workHeaderBytes = SB.toShort $ runPutS $ encodeAsWorkHeader nh
    , _workHeaderTarget = view blockTarget nh
    , _workHeaderChainId = _chainId nh
    }

-- | Create work header for cut
--
newHeaderForPayload
    :: ChainValueCasLookup hdb BlockHeader
    => hdb
    -> CutExtension
    -> BlockPayloadHash
    -> IO BlockHeader
newHeaderForPayload hdb e h = do
    creationTime <- BlockCreationTime <$> getCurrentTimeIntegral
    newHeaderForPayloadPure (chainLookupM hdb) creationTime e h

-- | A pure version of 'newWorkHeader' that is useful in testing.
--
newHeaderForPayloadPure
    :: Applicative m
    => (ChainValue BlockHash -> m BlockHeader)
    -> BlockCreationTime
    -> CutExtension
    -> BlockPayloadHash
    -> m BlockHeader
newHeaderForPayloadPure hdb creationTime extension phash = do
    -- Collect block headers for adjacent parents, some of which may be
    -- available in the cut.
    createWithParents <$> getAdjacentParentHeaders hdb extension
  where
    -- Assemble a candidate `BlockHeader` without a specific `Nonce`
    -- value. `Nonce` manipulation is assumed to occur within the
    -- core Mining logic.
    --
    createWithParents parents =
        newBlockHeader parents phash (Nonce 0) creationTime
            $! _cutExtensionParent extension
                -- FIXME: check that parents also include hashes on new chains!

-- | Get all adjacent parent headers for a new block header for a given cut.
--
-- This yields the same result as 'blockAdjacentParentHeaders', however, it is
-- more efficient when the cut and the adjacent parent hashes are already known.
-- Also, it works across graph changes. It is not checked whether the given
-- adjacent parent hashes are consistent with the cut.
--
-- Only those parents are included that are not block parent hashes of genesis
-- blocks. This can occur when new graphs are introduced. The headers are used
-- in 'newBlockHeader' for computing the target. That means that during a graph
-- change the target computation may only use some (or none) adjacent parents to
-- adjust the epoch start, which is fine.
--
-- If the parent header doesn't exist, because the chain is new, only the
-- genesis parent hash is included as 'Left' value.
--
getAdjacentParentHeaders
    :: HasCallStack
    => Applicative m
    => (ChainValue BlockHash -> m BlockHeader)
    -> CutExtension
    -> m (HM.HashMap ChainId ParentHeader)
getAdjacentParentHeaders hdb extension
    = itraverse select
    . _getBlockHashRecord
    $ _cutExtensionAdjacentHashes extension
  where
    c = _cutExtensionCut extension

    select cid h = case c ^? ixg cid of
        Just ch -> ParentHeader <$> if view blockHash ch == h
            then pure ch
            else hdb (ChainValue cid h)

        Nothing -> error $ T.unpack
            $ "Chainweb.Cut.Create.getAdjacentParentHeaders: inconsistent cut extension detected"
            <> ". ChainId: " <> encodeToText cid
            <> ". CutHashes: " <> encodeToText (cutToCutHashes Nothing c)

-- -------------------------------------------------------------------------- --
-- Solved Header
--

-- | A solved header is the result of mining. It has the final creation time and
-- a valid nonce. The binary representation doesn't yet contain a Merkle Hash.
-- Also, the block header is not yet validated. It also may contain a hashed record
-- of adjacent blocks instead of the actual record of the adjacent block hashes.
--
-- This is an internal data type. On the client/miner side only the serialized
-- representation is used.
--
newtype SolvedWork = SolvedWork BlockHeader
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (NFData)

encodeSolvedWork :: SolvedWork -> Put
encodeSolvedWork (SolvedWork hdr) = encodeBlockHeaderWithoutHash hdr

decodeSolvedWork :: Get SolvedWork
decodeSolvedWork = SolvedWork <$> decodeBlockHeaderWithoutHash

solvedWorkPayloadHash :: SolvedWork -> BlockPayloadHash
solvedWorkPayloadHash (SolvedWork bh) = view blockPayloadHash bh

makeSolvedWork :: BlockHeader -> SolvedWork
makeSolvedWork = SolvedWork


data InvalidSolvedHeader = InvalidSolvedHeader T.Text
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (NFData)

instance Exception InvalidSolvedHeader

-- | Extend a Cut with a solved work value.
--
-- The function verifies that the solved work actually is a valid extension of
-- the cut and matches the given payload data. It also checks a few other
-- invariants. It does't do a full validation.
--
-- The resulting 'CutHashes' value contains the new header and payload as
-- attachement and can be submitted into a cut pipeline.
--
-- The result is 'Nothing' if the given cut can't be extended with the solved
-- work.
--
extend
    :: MonadThrow m
    => Cut
    -> PayloadWithOutputs
    -> SolvedWork
    -> BlockHeader
    -> m (BlockHeader, Maybe CutHashes)
extend c pwo work bh = do
    (bh', mc) <- extendCut c (_payloadWithOutputsPayloadHash pwo) work bh
    return $ (bh',) $ toCutHashes <$> mc
  where
    toCutHashes c' = cutToCutHashes Nothing c'
        & set cutHashesHeaders
            (HM.singleton (view blockHash bh) bh)
        & set cutHashesPayloads
            (HM.singleton (view blockPayloadHash bh) (payloadWithOutputsToPayloadData pwo))
        & set cutHashesLocalPayload
            (Just (view blockPayloadHash bh, pwo))

-- | For internal use and testing
--
extendCut
    :: MonadThrow m
    => Cut
    -> BlockPayloadHash
    -> SolvedWork
    -> BlockHeader
    -> m (BlockHeader, Maybe Cut)
extendCut c ph (SolvedWork wh) bh = do
    bh' <-
        -- encoding and decoding the block header is required to update the
        -- block hash, after we changed the contents (that is the nonce,
        -- creation time)
        runGetS decodeBlockHeaderWithoutHash
            $ runPutS
            $ encodeBlockHeaderWithoutHash
            $ set blockNonce (wh ^. blockNonce)
            $ set blockCreationTime (wh ^. blockCreationTime)
            $ bh
    when (runPutS (encodeAsWorkHeader bh') /= runPutS (encodeBlockHeaderWithoutHash wh))
        $ throwM $ InvalidSolvedHeader $
            "work header does not match original header: \n\n" <>
            sshow (BS.unpack (runPutS $ encodeAsWorkHeader bh')) <>
            "\n\n" <>
            sshow (BS.unpack (runPutS $ encodeBlockHeaderWithoutHash wh))

    -- Fail Early: If a `BlockHeader`'s injected Nonce (and thus its POW
    -- Hash) is trivially incorrect, reject it.
    --
    when (not (prop_block_pow bh'))
        $ throwM $ InvalidSolvedHeader $
            "block header fails proof of work check: \n\n" <>
                sshow (BS.unpack (runPutS $ encodeAsWorkHeader bh'))

    -- Fail Early: check that the given payload matches the new block.
    --
    unless (view blockPayloadHash bh' == ph) $ throwM $ InvalidSolvedHeader
        $ "Invalid payload hash"
        <> ". Expected: " <> sshow (view blockPayloadHash bh')
        <> ", Got: " <> sshow ph

    -- If the `BlockHeader` is already stale and can't be appended to the
    -- best `Cut`, Nothing is returned
    --
    (bh',) <$> tryMonotonicCutExtension c bh'
