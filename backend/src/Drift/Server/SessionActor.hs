{-# LANGUAGE OverloadedRecordDot #-}

-- | One serialized writer per session. The registry belongs to one manager;
-- callers must not run two live managers against the same session database.
module Drift.Server.SessionActor
  ( BranchGenerator, Manager, Subscription
  , newManager, createManagedSession, subscribeSession
  , newManagerWithAppendObserver, subscribeSessionWithJoinObserver
  , submit, receive, unsubscribe, stopManager
  ) where

import Control.Concurrent.Async (Async, async, asyncWithUnmask, cancel, mapConcurrently_, poll, wait, waitCatch)
import Control.Concurrent.MVar (MVar, modifyMVarMasked, newMVar)
import Control.Concurrent.STM
import Control.Exception (SomeException, catch, evaluate, finally, mask, onException, throwIO, try)
import Control.Monad (filterM, forM_, void, when)
import Data.Int (Int64)
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import Drift.Domain.Decide (decide, offerBranches)
import Drift.Domain.State (applyStamped, replay)
import Drift.Domain.Types
import Drift.Model.SessionMock (BranchGenerator, mockCloud)
import Drift.Protocol
import Drift.Store.SQLite

data Manager = Manager
  { managerStore :: Store
  , managerGenerator :: BranchGenerator
  , managerRegistry :: MVar Registry
  , managerAppendObserver :: SessionId -> [Event] -> Either StoreException () -> IO ()
  }

data Registry = Running (Map.Map SessionId Actor) | Stopped (Async ())

data Actor = Actor
  { actorInbox :: TQueue Message
  , actorAlive :: TVar Bool
  , actorThread :: Async ()
  }

data Subscription = Subscription
  { subscriptionId :: Int
  , subscriptionInbox :: TQueue Message
  , subscriptionAlive :: TVar Bool
  , subscriptionActive :: TVar Bool
  , subscriptionOutput :: TQueue ServerMsg
  }

data Message
  = Join Subscription (TMVar ())
  | Leave Int
  | Request Subscription ClientMsg
  | Generated Integer NodeId (Maybe [Text])
  | Halt

data ActorState = ActorState
  { stateSession :: Session
  , stateLog :: Log
  , stateTail :: Int
  , stateSubscribers :: Map.Map Int Subscription
  , stateGeneration :: Integer
  , stateNextCandidate :: CandidateId
  , stateCurrentWorker :: Maybe (Async ())
  , stateWorkers :: [Async ()]
  }

newManager :: Store -> BranchGenerator -> IO Manager
newManager store generator = newManagerWithAppendObserver store generator (\_ _ _ -> pure ())

-- | Test seam, never sent over the wire. The observer runs after each append
-- attempt and must return normally; production wiring uses newManager.
newManagerWithAppendObserver
  :: Store -> BranchGenerator
  -> (SessionId -> [Event] -> Either StoreException () -> IO ()) -> IO Manager
newManagerWithAppendObserver store generator observer = do
  registry <- newMVar (Running Map.empty)
  pure (Manager store generator registry observer)

-- | A collision is retried against the durable uniqueness constraint. No
-- process-local counter or clock value is trusted to prove global uniqueness.
-- Storage failures propagate; stopped creation throws an IOException.
createManagedSession :: Manager -> Lang -> IO SessionId
createManagedSession manager language = modifyMVarMasked manager.managerRegistry $ \case
  Stopped _ -> throwIO (userError "The session manager is stopped.")
  Running actors -> do
    (sid, history) <- createFresh
    actor <- startActor manager sid history
    pure (Running (Map.insert sid actor actors), sid)
  where
    createFresh = do
      now <- unixMillis
      unique <- hashUnique <$> newUnique
      let sid = SessionId ("session-" <> Text.pack (show now) <> "-" <> Text.pack (show unique))
          cloud = zipWith Candidate (map CandidateId [1 ..]) (mockCloud language)
          history = [Stamped 1 now (CloudSpawned language cloud)]
      (createSession manager.managerStore sid history >> pure (sid, history))
        `catch` \failure -> case failure of
          SessionAlreadyExists _ -> createFresh
          _ -> throwIO (failure :: StoreException)

-- | Snapshot and registration are one actor message. The registry lock also
-- serializes the first load, so concurrent connections cannot spawn two writers.
subscribeSession :: Manager -> SessionId -> IO (Either Rejection Subscription)
subscribeSession manager sid = subscribeSessionWithJoinObserver manager sid (const (pure ()))

-- | Test seam for cancelling an acquisition after enqueue but before reply.
-- Exceptions from the observer have the same cleanup as a cancelled wait.
subscribeSessionWithJoinObserver
  :: Manager -> SessionId -> (Subscription -> IO ())
  -> IO (Either Rejection Subscription)
subscribeSessionWithJoinObserver manager sid observer = mask $ \restore -> do
  found <- modifyMVarMasked manager.managerRegistry $ \case
    stopped@(Stopped _) -> pure (stopped, Left stoppedReason)
    Running actors -> case Map.lookup sid actors of
      Just actor -> pure (Running actors, Right actor)
      Nothing -> do
        loaded <- try (loadEvents manager.managerStore sid)
        case loaded of
          Left (_ :: StoreException) -> pure (Running actors, Left unavailableReason)
          Right Nothing -> pure (Running actors, Left (Rejection "That session does not exist."))
          Right (Just history) -> do
            actor <- startActor manager sid history
            pure (Running (Map.insert sid actor actors), Right actor)
  case found of
    Left rejection -> pure (Left rejection)
    Right actor -> do
      identity <- hashUnique <$> newUnique
      active <- newTVarIO True
      output <- newTQueueIO
      reply <- newEmptyTMVarIO
      let subscription = Subscription identity actor.actorInbox actor.actorAlive active output
      accepted <- atomically $ do
        alive <- readTVar actor.actorAlive
        when alive (writeTQueue actor.actorInbox (Join subscription reply))
        pure alive
      if not accepted then pure (Left stoppedReason) else
        restore (do
          observer subscription
          atomically $
            (takeTMVar reply >> pure (Right subscription)) `orElse` do
              alive <- readTVar actor.actorAlive
              check (not alive)
              pure (Left stoppedReason))
        `onException` unsubscribe subscription

-- | Submissions after unsubscribe or manager stop are harmlessly ignored.
submit :: Subscription -> ClientMsg -> IO ()
submit subscription message = atomically $ do
  active <- readTVar subscription.subscriptionActive
  alive <- readTVar subscription.subscriptionAlive
  when (active && alive) (writeTQueue subscription.subscriptionInbox (Request subscription message))

-- | Blocking queue read. Already queued messages can still be drained after
-- shutdown; transports should cancel a blocked receive when they disconnect.
receive :: Subscription -> IO ServerMsg
receive subscription = atomically (readTQueue subscription.subscriptionOutput)

unsubscribe :: Subscription -> IO ()
unsubscribe subscription = atomically $ do
  active <- readTVar subscription.subscriptionActive
  alive <- readTVar subscription.subscriptionAlive
  writeTVar subscription.subscriptionActive False
  when (active && alive) (writeTQueue subscription.subscriptionInbox (Leave subscription.subscriptionId))

-- | A detached, shared shutdown job survives cancellation of a caller waiting
-- here. Every stop caller waits for the same actors and their worker cleanup.
-- The caller owns the Store and closes it after this function returns.
stopManager :: Manager -> IO ()
stopManager manager = do
  -- No interruptible operation lies between starting a child and publishing
  -- its owner. Pending caller cancellation is delivered after registry release.
  job <- modifyMVarMasked manager.managerRegistry $ \case
    stopped@(Stopped job) -> pure (stopped, job)
    Running actors -> do
      job <- asyncWithUnmask $ \unmask -> unmask $ do
        atomically $ forM_ (Map.elems actors) $ \actor -> do
          writeTVar actor.actorAlive False
          writeTQueue actor.actorInbox Halt
        mapM_ (void . waitCatch . actorThread) (Map.elems actors)
      pure (Stopped job, job)
  wait job

startActor :: Manager -> SessionId -> [Stamped] -> IO Actor
startActor manager sid history = do
  inbox <- newTQueueIO
  alive <- newTVarIO True
  let logValue = Log (reverse history)
      session = replay logValue
      initial = ActorState session logValue (length history) Map.empty 0
        session.sessionNextCandidateId Nothing []
  -- Registry mutation stays masked; the actor itself runs unmasked.
  thread <- asyncWithUnmask $ \unmask ->
    unmask (loop inbox initial `finally` atomically (writeTVar alive False))
  pure (Actor inbox alive thread)
  where
    loop inbox state = do
      -- Retain only jobs still needing cleanup; completed workers and their
      -- asynchronous cancellation helpers do not accumulate across a long walk.
      workers <- filterM (fmap isRunning . poll) state.stateWorkers
      let current = state {stateWorkers = workers}
      atomically (readTQueue inbox) >>= \case
        Halt -> mapConcurrently_ cancel workers
        Join subscription reply -> do
          let Log newest = current.stateLog
          active <- atomically $ do
            active <- readTVar subscription.subscriptionActive
            when active (writeTQueue subscription.subscriptionOutput (Events (reverse newest)))
            putTMVar reply ()
            pure active
          loop inbox (if active then current
            {stateSubscribers = Map.insert subscription.subscriptionId subscription current.stateSubscribers}
            else current)
        Leave identity -> loop inbox current {stateSubscribers = Map.delete identity current.stateSubscribers}
        Request subscription message -> do
          active <- readTVarIO subscription.subscriptionActive
          next <- if not active then pure current else case decide current.stateSession message.command of
            Left rejection -> reject subscription message.req rejection >> pure current
            Right [] -> pure current
            Right events -> do
              persisted <- commit current events
              case persisted of
                Nothing -> reject subscription message.req unavailableReason >> pure current
                Just committed -> if any changesGeneration events
                  then regenerate inbox committed else pure committed
          loop inbox next
        Generated token target result -> do
          next <- if token /= current.stateGeneration || current.stateSession.sessionFocus /= Just target
              || current.stateSession.sessionWrapped
            then pure current
            else case result of
              Nothing -> pure current {stateCurrentWorker = Nothing}
              Just words -> do
                let CandidateId first = max current.stateNextCandidate current.stateSession.sessionNextCandidateId
                    candidates = zipWith Candidate (map CandidateId [first ..]) words
                case offerBranches current.stateSession target candidates of
                  Left _ -> pure current {stateCurrentWorker = Nothing}
                  Right events -> commit current events >>= \case
                    Nothing -> pure current {stateCurrentWorker = Nothing}
                    Just committed -> pure committed
                      { stateNextCandidate = CandidateId (first + length words)
                      , stateCurrentWorker = Nothing }
          loop inbox next

    commit state events = do
      now <- unixMillis
      let stamped = zipWith (\number event -> Stamped number now event) [state.stateTail + 1 ..] events
      persisted <- try (appendEvents manager.managerStore sid state.stateTail stamped)
      manager.managerAppendObserver sid events persisted
      case persisted of
        Left (_ :: StoreException) -> pure Nothing
        Right () -> do
          let session = foldl' applyStamped state.stateSession stamped
              Log newest = state.stateLog
              committed = state
                { stateSession = session
                , stateLog = Log (foldl' (flip (:)) newest stamped)
                , stateTail = state.stateTail + length stamped }
          atomically $ forM_ (Map.elems state.stateSubscribers) $ \subscription -> do
            active <- readTVar subscription.subscriptionActive
            when active (writeTQueue subscription.subscriptionOutput (Events stamped))
          pure (Just committed)

    regenerate inbox state = do
      -- cancel waits for the target to finish. Run that wait outside the actor
      -- so even a slow cancellation cannot block insert/backtrack/wrap-up.
      cancellations <- case state.stateCurrentWorker of
        Nothing -> pure []
        Just worker -> (: []) <$> async (cancel worker)
      let token = state.stateGeneration + 1
          invalidated = state
            { stateGeneration = token
            , stateCurrentWorker = Nothing
            , stateWorkers = cancellations <> state.stateWorkers }
      case state.stateSession.sessionFocus of
        Just target | not state.stateSession.sessionWrapped -> do
          worker <- async $ do
            result <- try $ do
              words <- manager.managerGenerator state.stateSession target
              -- Force the result spine and Text values in the worker, keeping
              -- delayed provider exceptions away from the actor's pure fold.
              _ <- evaluate (sum (map Text.length words))
              pure words
            atomically $ writeTQueue inbox (Generated token target (case result of
              Left (_ :: SomeException) -> Nothing
              Right words -> Just words))
          pure invalidated
            { stateCurrentWorker = Just worker
            , stateWorkers = worker : invalidated.stateWorkers }
        _ -> pure invalidated

isRunning :: Maybe a -> Bool
isRunning Nothing = True
isRunning (Just _) = False

changesGeneration :: Event -> Bool
changesGeneration (NodeChosen _ _ _ _ _) = True
changesGeneration (NodeRevisited _) = True
changesGeneration WrappedUp = True
changesGeneration _ = False

reject :: Subscription -> Int -> Rejection -> IO ()
reject subscription request (Rejection reason) = atomically $ do
  active <- readTVar subscription.subscriptionActive
  when active (writeTQueue subscription.subscriptionOutput (Rejected request reason))

stoppedReason, unavailableReason :: Rejection
stoppedReason = Rejection "The session manager is stopped."
unavailableReason = Rejection "The session could not be updated. Please try again."

unixMillis :: IO Int64
unixMillis = floor . (* 1000) <$> getPOSIXTime
