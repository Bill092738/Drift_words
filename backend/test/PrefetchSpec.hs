module PrefetchSpec (spec) where

import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (finally)
import Data.IORef
import Drift.Pipeline.Prefetch
import System.Timeout (timeout)
import Test.Hspec

within :: IO a -> IO a
within action = do
  result <- timeout 2000000 action
  maybe (expectationFailure "operation timed out" >> fail "unreachable") pure result

spec :: Spec
spec = describe "prefetch cache" $ do
  it "starts at most one computation per key and consumes it once" $ do
    cache <- newPrefetchCache :: IO (PrefetchCache String Int)
    runs <- newIORef (0 :: Int)
    let work = atomicModifyIORef' runs (\n -> (n + 1, ())) >> pure (42 :: Int)

    startPrefetch cache "word" work `shouldReturn` PrefetchStarted
    startPrefetch cache "word" work `shouldReturn` PrefetchAlreadyPresent
    takePrefetch cache "word" `shouldReturn` Just (Right 42)
    takePrefetch cache "word" `shouldReturn` Nothing
    readIORef runs `shouldReturn` 1
    shutdownPrefetchCache cache

  it "lets only one concurrent waiter claim a prefetched value" $ do
    cache <- newPrefetchCache :: IO (PrefetchCache String Int)
    gate <- newEmptyMVar
    startPrefetch cache "word" (takeMVar gate >> pure (7 :: Int)) `shouldReturn` PrefetchStarted
    first <- newEmptyMVar
    second <- newEmptyMVar
    _ <- forkResult (takePrefetch cache "word") first
    _ <- forkResult (takePrefetch cache "word") second
    putMVar gate ()

    results <- within $ sequence [takeMVar first, takeMVar second]
    results `shouldMatchList` [Just (Right 7), Nothing]
    shutdownPrefetchCache cache

  it "keeps the selected prediction and cancels every unselected one" $ do
    cache <- newPrefetchCache :: IO (PrefetchCache String Int)
    selectedGate <- newEmptyMVar
    discardedStarted <- newEmptyMVar
    discardedStopped <- newEmptyMVar
    startPrefetch cache "selected" (takeMVar selectedGate >> pure (1 :: Int)) `shouldReturn` PrefetchStarted
    startPrefetch cache "discarded" (
      (putMVar discardedStarted () >> threadDelay 10000000 >> pure (2 :: Int))
        `finally` putMVar discardedStopped ()) `shouldReturn` PrefetchStarted
    takeMVar discardedStarted

    cancelUnselected cache "selected"
    within (takeMVar discardedStopped) `shouldReturn` ()
    takePrefetch cache "discarded" `shouldReturn` Nothing
    putMVar selectedGate ()
    within (takePrefetch cache "selected") `shouldReturn` Just (Right 1)
    shutdownPrefetchCache cache

  it "shuts down idempotently and refuses new prefetches" $ do
    cache <- newPrefetchCache :: IO (PrefetchCache String ())
    startPrefetch cache "word" (threadDelay 10000000 >> pure ()) `shouldReturn` PrefetchStarted
    within (shutdownPrefetchCache cache)
    shutdownPrefetchCache cache
    startPrefetch cache "late" (pure ()) `shouldReturn` PrefetchCacheClosed
    takePrefetch cache "word" `shouldReturn` Nothing

forkResult :: IO a -> MVar a -> IO ThreadId
forkResult action destination = forkIO (action >>= putMVar destination)
