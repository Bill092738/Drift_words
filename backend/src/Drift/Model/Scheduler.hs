{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | A single-slot scheduler for model work.
--
-- Jobs are stable within a priority. P0 work preempts a running P1-P3 job;
-- other priorities wait for the current job to finish.
module Drift.Model.Scheduler
  ( Priority (..)
  , JobError (..)
  , Scheduler
  , Job
  , newScheduler
  , submit
  , await
  , cancel
  , shutdown
  , isAsyncException
  ) where

import Control.Concurrent.Async (Async)
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, try)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as Text

-- | P0 is the latency-critical selected branch; P3 is final assembly.
data Priority = P0 | P1 | P2 | P3
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data JobError
  = JobCancelled
  | SchedulerStopped
  | JobFailed Text
  deriving stock (Eq, Show)

data Job a = Job
  { jobPriority :: Priority
  , jobAction :: IO a
  , jobResult :: TMVar (Either JobError a)
  }

data QueuedJob = forall a. QueuedJob (Job a)

data Queues = Queues
  { p0Queue :: TQueue QueuedJob
  , p1Queue :: TQueue QueuedJob
  , p2Queue :: TQueue QueuedJob
  , p3Queue :: TQueue QueuedJob
  }

data Scheduler = Scheduler
  { schedulerQueues :: Queues
  , schedulerStopped :: TVar Bool
  , schedulerWorker :: Async ()
  }

data CurrentEvent
  = CurrentResolved
  | StopRequested
  | UrgentQueued QueuedJob
  | WorkerExited

newScheduler :: IO Scheduler
newScheduler = do
  queues <- atomically $
    Queues <$> newTQueue <*> newTQueue <*> newTQueue <*> newTQueue
  stopped <- newTVarIO False
  worker <- Async.async (schedulerLoop queues stopped)
  pure
    Scheduler
      { schedulerQueues = queues
      , schedulerStopped = stopped
      , schedulerWorker = worker
      }

submit :: Scheduler -> Priority -> IO a -> IO (Job a)
submit scheduler priority action = do
  result <- newEmptyTMVarIO
  let job =
        Job
          { jobPriority = priority
          , jobAction = action
          , jobResult = result
          }
  atomically $ do
    stopped <- readTVar scheduler.schedulerStopped
    if stopped
      then void (tryPutTMVar result (Left SchedulerStopped))
      else writeTQueue (queueFor scheduler.schedulerQueues priority) (QueuedJob job)
  pure job

await :: Job a -> IO (Either JobError a)
await = atomically . readTMVar . jobResult

-- | Cancel queued or running work. Every current and future waiter observes the
-- same terminal result.
cancel :: Job a -> IO ()
cancel job =
  atomically $ void (tryPutTMVar job.jobResult (Left JobCancelled))

-- | Stop accepting work, interrupt the running action, and resolve all queued
-- and running jobs before returning. Safe to call more than once.
shutdown :: Scheduler -> IO ()
shutdown scheduler = do
  atomically $ writeTVar scheduler.schedulerStopped True
  void (Async.waitCatch scheduler.schedulerWorker)

schedulerLoop :: Queues -> TVar Bool -> IO ()
schedulerLoop queues stopped = next
 where
  next = do
    nextJob <- atomically $ do
      isStopped <- readTVar stopped
      if isStopped then pure Nothing else Just <$> dequeue queues
    case nextJob of
      Nothing -> atomically (stopQueued queues)
      Just queued -> run queued

  run :: QueuedJob -> IO ()
  run queued@(QueuedJob job) = do
    pending <- atomically (isEmptyTMVar job.jobResult)
    if not pending
      then next
      else do
        worker <- Async.async (execute job)
        waitFor worker queued

  waitFor :: Async () -> QueuedJob -> IO ()
  waitFor worker current@(QueuedJob job) = do
    event <- atomically $
      stopEvent stopped
        `orElse` resolvedEvent job
        `orElse` urgentEvent queues job.jobPriority
        `orElse` (Async.waitCatchSTM worker >> pure WorkerExited)
    case event of
      StopRequested -> do
        atomically $ do
          void (tryPutTMVar job.jobResult (Left SchedulerStopped))
          stopQueued queues
        Async.cancel worker
        void (Async.waitCatch worker)
      CurrentResolved -> do
        Async.cancel worker
        void (Async.waitCatch worker)
        next
      WorkerExited -> next
      UrgentQueued urgent@(QueuedJob urgentJob) -> do
        urgentPending <- atomically (isEmptyTMVar urgentJob.jobResult)
        if urgentPending
          then do
            atomically $ void (tryPutTMVar job.jobResult (Left JobCancelled))
            Async.cancel worker
            void (Async.waitCatch worker)
            run urgent
          else waitFor worker current

execute :: Job a -> IO ()
execute job = do
  outcome <- try @SomeException job.jobAction
  atomically . void . tryPutTMVar job.jobResult $
    case outcome of
      Right value -> Right value
      Left exception ->
        Left $
          if isAsyncException exception
            then JobCancelled
            else JobFailed (Text.pack (displayException exception))

-- | True for any asynchronous exception: base's 'ThreadKilled' as well as the
-- @async@ library's 'Async.AsyncCancelled', which 'Async.cancel' throws.
isAsyncException :: SomeException -> Bool
isAsyncException exception =
  case fromException @SomeAsyncException exception of
    Just _ -> True
    Nothing -> False

stopEvent :: TVar Bool -> STM CurrentEvent
stopEvent stopped = do
  isStopped <- readTVar stopped
  check isStopped
  pure StopRequested

resolvedEvent :: Job a -> STM CurrentEvent
resolvedEvent job = do
  resolved <- not <$> isEmptyTMVar job.jobResult
  check resolved
  pure CurrentResolved

urgentEvent :: Queues -> Priority -> STM CurrentEvent
urgentEvent queues priority = do
  check (priority /= P0)
  UrgentQueued <$> readTQueue queues.p0Queue

dequeue :: Queues -> STM QueuedJob
dequeue queues =
  readTQueue queues.p0Queue
    `orElse` readTQueue queues.p1Queue
    `orElse` readTQueue queues.p2Queue
    `orElse` readTQueue queues.p3Queue

queueFor :: Queues -> Priority -> TQueue QueuedJob
queueFor queues = \case
  P0 -> queues.p0Queue
  P1 -> queues.p1Queue
  P2 -> queues.p2Queue
  P3 -> queues.p3Queue

stopQueued :: Queues -> STM ()
stopQueued queues = do
  stopQueue queues.p0Queue
  stopQueue queues.p1Queue
  stopQueue queues.p2Queue
  stopQueue queues.p3Queue
 where
  stopQueue queue =
    tryReadTQueue queue >>= \case
      Nothing -> pure ()
      Just (QueuedJob job) -> do
        void (tryPutTMVar job.jobResult (Left SchedulerStopped))
        stopQueue queue