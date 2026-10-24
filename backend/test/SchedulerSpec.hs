module SchedulerSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Exception (AsyncException (..), ErrorCall (..), finally, toException)
import Control.Monad (forM, void)
import Drift.Model.Scheduler
import System.Timeout (timeout)
import Test.Hspec

within :: IO a -> IO a
within action = do
  result <- timeout 2000000 action
  maybe (expectationFailure "operation timed out" >> fail "unreachable") pure result

spec :: Spec
spec = describe "model scheduler" $ do
  it "recognizes base and async-library cancellation as asynchronous exceptions" $ do
    isAsyncException (toException AsyncCancelled) `shouldBe` True
    isAsyncException (toException ThreadKilled) `shouldBe` True
    isAsyncException (toException (ErrorCall "boom")) `shouldBe` False

  it "runs queued jobs by priority and preserves FIFO within a priority" $ do
    scheduler <- newScheduler
    gate <- newEmptyMVar
    started <- newEmptyMVar
    order <- newMVar []
    blocker <- submit scheduler P0 $ putMVar started () >> takeMVar gate
    takeMVar started

    let record label = modifyMVar_ order (pure . (<> [label]))
    jobs <- forM [(P2, "p2"), (P1, "p1-a"), (P3, "p3"), (P1, "p1-b")] $ \(priority, label) ->
      submit scheduler priority (record label)
    putMVar gate ()

    await blocker `shouldReturn` Right ()
    mapM await jobs `shouldReturn` replicate 4 (Right ())
    readMVar order `shouldReturn` ["p1-a", "p1-b", "p2", "p3"]
    shutdown scheduler

  it "cancels a running lower-priority job when P0 arrives" $ do
    scheduler <- newScheduler
    started <- newEmptyMVar
    interrupted <- newEmptyMVar
    low <- submit scheduler P2 $
      (putMVar started () >> threadDelay 10000000)
        `finally` putMVar interrupted ()
    takeMVar started

    urgent <- submit scheduler P0 (pure "urgent")

    within (await urgent) `shouldReturn` Right "urgent"
    within (await low) `shouldReturn` Left JobCancelled
    within (takeMVar interrupted) `shouldReturn` ()
    shutdown scheduler

  it "supports explicit cancellation and resolves every waiter" $ do
    scheduler <- newScheduler
    started <- newEmptyMVar
    job <- submit scheduler P1 (putMVar started () >> threadDelay 10000000)
    takeMVar started
    cancel job

    waits <- forM [1 :: Int .. 3] $ \_ -> within (await job)
    waits `shouldBe` replicate 3 (Left JobCancelled)
    shutdown scheduler

  it "cancels running and queued jobs on shutdown and rejects later work" $ do
    scheduler <- newScheduler
    started <- newEmptyMVar
    running <- submit scheduler P1 (putMVar started () >> threadDelay 10000000)
    takeMVar started
    queued <- submit scheduler P3 (pure ())

    within (shutdown scheduler)

    await running `shouldReturn` Left SchedulerStopped
    await queued `shouldReturn` Left SchedulerStopped
    late <- submit scheduler P0 (pure ())
    await late `shouldReturn` Left SchedulerStopped
    void (shutdown scheduler)