module Chainweb.Test.Mempool.RestAPI (tests) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception

import qualified Data.Pool as Pool
import qualified Data.Vector as V

import qualified Network.HTTP.Client as HTTP
import Network.Wai (Application)

import Servant.Client (BaseUrl(..), ClientEnv, Scheme(..), mkClientEnv)

import Test.Tasty

-- internal modules

import Chainweb.Chainweb.Configuration
import Chainweb.Graph
import qualified Chainweb.Mempool.InMem as InMem
import Chainweb.Mempool.InMemTypes (InMemConfig(..))
import Chainweb.Mempool.Mempool
import qualified Chainweb.Mempool.RestAPI.Client as MClient
import Chainweb.RestAPI
import Chainweb.Test.Mempool (InsertCheck, MempoolWithFunc(..))
import qualified Chainweb.Test.Mempool
import Chainweb.Test.Utils (withTestAppServer)
import Chainweb.Test.TestVersions
import Chainweb.Utils (Codec(..))
import Chainweb.Version
import Chainweb.Version.Utils

import Chainweb.Storage.Table.RocksDB

import Network.X509.SelfSigned

------------------------------------------------------------------------------
tests :: TestTree
tests = withResource newPool Pool.destroyAllResources $
        \poolIO -> testGroup "Chainweb.Mempool.RestAPI"
            $ Chainweb.Test.Mempool.remoteTests
            $ MempoolWithFunc
            $ withRemoteMempool poolIO

data TestServer = TestServer
    { _tsRemoteMempool :: !(MempoolBackend MockTx)
    , _tsLocalMempool :: !(MempoolBackend MockTx)
    , _tsInsertCheck :: InsertCheck
    , _tsServerThread :: !ThreadId
    }

newTestServer :: IO TestServer
newTestServer = mask_ $ do
    checkMv <- newMVar (pure . V.map Right)
    let inMemCfg = InMemConfig txcfg mockBlockGasLimit 0 2048 Right (checkMvFunc checkMv) (1024 * 10)
    inmemMv <- newEmptyMVar
    envMv <- newEmptyMVar
    tid <- forkIOWithUnmask $ \u -> server inMemCfg inmemMv envMv u
    inmem <- takeMVar inmemMv
    env <- takeMVar envMv
    let remoteMp0 = MClient.toMempool version chain txcfg env
    -- allow remoteMp to call the local mempool's getBlock (for testing)
    let remoteMp = remoteMp0 { mempoolGetBlock = mempoolGetBlock inmem }
    return $! TestServer remoteMp inmem checkMv tid
  where
    checkMvFunc mv xs = do
        f <- readMVar mv
        f xs

    server inMemCfg inmemMv envMv restore = do
        inmem <- InMem.startInMemoryMempoolTest inMemCfg
        putMVar inmemMv inmem
        restore $ withTestAppServer True (return $! mkApp inmem) mkEnv $ \env -> do
            putMVar envMv env
            atomically retry

    version :: ChainwebVersion
    version = barebonesTestVersion singletonChainGraph

    host :: String
    host = "127.0.0.1"

    chain :: ChainId
    chain = someChainId version

    mkApp :: MempoolBackend MockTx -> Application
    mkApp mp = chainwebApplication conf (serverMempools [(chain, mp)])

    conf = defaultChainwebConfiguration version

    mkEnv :: Int -> IO ClientEnv
    mkEnv port = do
        mgrSettings <- certificateCacheManagerSettings TlsInsecure
        mgr <- HTTP.newManager mgrSettings
        return $! mkClientEnv mgr $ BaseUrl Https host port ""

destroyTestServer :: TestServer -> IO ()
destroyTestServer = killThread . _tsServerThread

newPool :: IO (Pool.Pool TestServer)
newPool = Pool.newPool $ Pool.defaultPoolConfig
    newTestServer
    destroyTestServer
    10 {- ttl seconds -}
    20 {- max entries -}

------------------------------------------------------------------------------

serverMempools
    :: [(ChainId, MempoolBackend t)]
    -> ChainwebServerDbs t RocksDbTable {- ununsed -}
serverMempools mempools = emptyChainwebServerDbs
    { _chainwebServerMempools = mempools
    }

withRemoteMempool
    :: IO (Pool.Pool TestServer)
    -> (InsertCheck -> MempoolBackend MockTx -> IO a)
    -> IO a
withRemoteMempool poolIO userFunc = do
    pool <- poolIO
    Pool.withResource pool $ \ts -> do
        mempoolClear $ _tsLocalMempool ts
        userFunc (_tsInsertCheck ts) (_tsRemoteMempool ts)

txcfg :: TransactionConfig MockTx
txcfg = TransactionConfig mockCodec hasher hashmeta mockGasPrice
                          mockGasLimit mockMeta
  where
    hashmeta = chainwebTestHashMeta
    hasher = chainwebTestHasher . codecEncode mockCodec
