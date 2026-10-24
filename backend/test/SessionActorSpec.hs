{-# LANGUAGE OverloadedRecordDot #-}

module SessionActorSpec (spec) where

import Control.Concurrent.Async (AsyncCancelled, concurrently)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, catch, finally, throwIO)
import Control.Monad (forM_, void)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Database.SQLite.Simple as SQL
import Drift.Domain.State (replay)
import Drift.Domain.Types
import Drift.Model.SessionMock (mockBranches, mockCloud)
import Drift.Protocol
import Drift.Server.SessionActor
import Drift.Store.SQLite
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "Session actor" $ do
  it "persists the localized cloud before returning and restores a complete log after reopen" $
    withDatabase $ \path -> do
      (sid, history) <- bracket (openStore path) closeStore $ \store ->
        bracket (newManager store quiet) stopManager $ \manager -> do
          sid <- createManagedSession manager Zh
          Just initial <- loadEvents store sid
          map (\e -> e.seq) initial `shouldBe` [1]
          map (\e -> e.event) initial `shouldBe`
            [CloudSpawned Zh (zipWith Candidate (map CandidateId [1 ..]) (mockCloud Zh))]
          sub <- connected manager sid
          events sub `shouldReturn` initial
          submit sub (ClientMsg 1 (SetDivergence 0.8))
          batch <- events sub
          pure (sid, initial <> batch)
      bracket (openStore path) closeStore $ \store ->
        bracket (newManager store quiet) stopManager $ \manager -> do
          sub <- connected manager sid
          events sub `shouldReturn` history
          fresh <- createManagedSession manager En
          fresh `shouldNotBe` sid
          loadEvents store sid `shouldReturn` Just history

  it "broadcasts commits to two subscribers but echoes the exact rejection request only to its sender" $
    withEngine quiet $ \_ _ manager -> do
      sid <- createManagedSession manager En
      a <- connected manager sid
      b <- connected manager sid
      initial <- events a
      events b `shouldReturn` initial
      submit a (ClientMsg 917 (Pick (CandidateId (-1))))
      message <- bounded (receive a)
      case message of
        Rejected request reason -> do
          request `shouldBe` 917
          reason `shouldSatisfy` (not . Text.null)
        _ -> expectationFailure (show message)
      submit b (ClientMsg 2 (SetDivergence 0.7))
      committed <- events b
      events a `shouldReturn` committed
      map (\e -> e.seq) committed `shouldBe` [2]
      unsubscribe b
      submit b (ClientMsg 3 (SetDivergence 0.1))
      submit a (ClientMsg 4 WrapUp)
      _ <- events a
      noMessage b
      submit a (ClientMsg 5 WrapUp)
      noMessage a

  it "rejects unknown sessions without creating a durable session" $
    withEngine quiet $ \_ store manager -> do
      let missing = SessionId "does-not-exist"
      result <- subscribeSession manager missing
      case result of
        Left (Rejection reason) -> reason `shouldSatisfy` (not . Text.null)
        Right _ -> expectationFailure "Unknown session was subscribed"
      loadEvents store missing `shouldReturn` Nothing

  it "serializes concurrent first subscriptions through one actor" $
    withEngine quiet $ \_ store creator -> do
      sid <- createManagedSession creator En
      -- A fresh registry forces the concurrent load/create-actor path.
      bracket (newManager store quiet) stopManager $ \manager -> do
        (a, b) <- concurrently (connected manager sid) (connected manager sid)
        initial <- events a
        events b `shouldReturn` initial
        concurrently (submit a (ClientMsg 1 (SetDivergence 0.2)))
          (submit b (ClientMsg 2 (SetDivergence 0.3)))
        aa <- events a
        ab <- events a
        events b `shouldReturn` aa
        events b `shouldReturn` ab
        map (\e -> e.seq) (aa <> ab) `shouldBe` [2, 3]

  it "has no duplicate or missing sequence when subscribe races a commit" $
    withEngine quiet $ \_ _ manager -> do
      sid <- createManagedSession manager En
      writer <- connected manager sid
      _ <- events writer
      forM_ [1 .. 30] $ \request -> do
        (_, reader) <- concurrently
          (submit writer (ClientMsg request (SetDivergence 0.6)))
          (connected manager sid)
        _ <- events writer
        snapshot <- events reader
        observed <- if length snapshot == request + 1
          then pure snapshot else (snapshot <>) <$> events reader
        map (\e -> e.seq) observed `shouldBe` [1 .. request + 1]
        noMessage reader
        unsubscribe reader

  it "does not advance state or broadcast a failed write, and accepts the same command after repair" $
    withEngine quiet $ \path store manager -> do
      sid <- createManagedSession manager En
      a <- connected manager sid
      b <- connected manager sid
      initial <- events a
      _ <- events b
      withRaw path $ \connection -> SQL.execute_ connection
        "CREATE TRIGGER reject_second BEFORE INSERT ON events WHEN NEW.seq = 2 BEGIN SELECT RAISE(ABORT, 'private-storage-diagnostic'); END"
      submit a (ClientMsg 81 (StartWithWord "root"))
      rejected <- bounded (receive a)
      case rejected of
        Rejected request reason -> do
          request `shouldBe` 81
          reason `shouldSatisfy` (not . Text.isInfixOf "private-storage-diagnostic")
        _ -> expectationFailure (show rejected)
      loadEvents store sid `shouldReturn` Just initial
      noMessage b
      withRaw path $ \connection -> SQL.execute_ connection "DROP TRIGGER reject_second"
      submit a (ClientMsg 82 (StartWithWord "root"))
      chosen <- events a
      events b `shouldReturn` chosen
      map (\e -> e.seq) chosen `shouldBe` [2]
      map (\e -> e.event) chosen `shouldBe` [NodeChosen (NodeId 1) Nothing "root" StartWord Nothing]

  it "rolls back an entire generated stream-and-seal batch if a later insert fails" $
    withGates False $ \path store manager calls -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      initial <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      chosen <- events sub
      gate <- nextGate calls
      withRaw path $ \connection -> SQL.execute_ connection
        "CREATE TRIGGER reject_fourth BEFORE INSERT ON events WHEN NEW.seq = 4 BEGIN SELECT RAISE(ABORT, 'stream failure'); END"
      putMVar (gateWords gate) ["alpha", "beta"]
      -- A subsequent command serves as a barrier after the failed internal batch.
      -- Wait for the worker to finish, then a subscription replay verifies durability;
      -- polling is bounded and never assumes a sleep is a commit boundary.
      noMessage sub
      submit sub (ClientMsg 2 (SetDivergence 0.4))
      changed <- events sub
      map (\e -> e.seq) changed `shouldBe` [3]
      loadEvents store sid `shouldReturn` Just (initial <> chosen <> changed)
      withRaw path $ \connection -> SQL.execute_ connection "DROP TRIGGER reject_fourth"
      submit sub (ClientMsg 3 (Backtrack (NodeId 1)))
      _ <- events sub
      retryGate <- nextGate calls
      putMVar (gateWords retryGate) ["alpha", "beta"]
      offers <- events sub
      length offers `shouldBe` 3

  it "discards a cancellation-resistant result after changing focus" $
    withGates True $ \_ _ manager calls -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      old <- nextGate calls
      submit sub (ClientMsg 2 (InsertWord "child"))
      _ <- events sub
      fresh <- nextGate calls
      bounded (readMVar (gateCancelled old))
      putMVar (gateWords old) ["stale"]
      putMVar (gateWords fresh) ["fresh"]
      offers <- events sub
      streamedWords offers `shouldBe` ["fresh"]
      noMessage sub

  it "invalidates the token even for a same-node backtrack" $
    withGates True $ \_ _ manager calls -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      old <- nextGate calls
      submit sub (ClientMsg 2 (Backtrack (NodeId 1)))
      revisited <- events sub
      map (\e -> e.event) revisited `shouldBe` [NodeRevisited (NodeId 1)]
      fresh <- nextGate calls
      bounded (readMVar (gateCancelled old))
      putMVar (gateWords old) ["stale"]
      putMVar (gateWords fresh) ["fresh"]
      offers <- events sub
      streamedWords offers `shouldBe` ["fresh"]
      noMessage sub

  it "cancels a worker on wrap-up and ignores its late result" $
    withGates True $ \_ _ manager calls -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      gate <- nextGate calls
      submit sub (ClientMsg 2 WrapUp)
      wrapped <- events sub
      map (\e -> e.event) wrapped `shouldBe` [WrappedUp]
      bounded (readMVar (gateCancelled gate))
      putMVar (gateWords gate) ["late"]
      noMessage sub

  it "waits for worker cancellation on shutdown and consistently refuses new work" $
    withGates False $ \_ _ manager calls -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      gate <- nextGate calls
      bounded (stopManager manager)
      bounded (readMVar (gateCancelled gate))
      bounded (stopManager manager)
      subscribeSession manager sid >>= \case
        Left _ -> pure ()
        Right _ -> expectationFailure "Stopped manager accepted a subscription"
      createManagedSession manager En `shouldThrow` anyIOException
      submit sub (ClientMsg 2 (InsertWord "ignored"))
      unsubscribe sub
      noMessage sub

  it "remains usable after a generator exception" $
    withEngine (\_ _ -> throwIO (userError "private generator error")) $ \_ _ manager -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      forM_ (zip [2 ..]
        [InsertWord "child", Backtrack (NodeId 1), PlaceNode (NodeId 1) (Vec2 2 3) 0, WrapUp]) $ \(request, command) -> do
        submit sub (ClientMsg request command)
        batch <- events sub
        length batch `shouldBe` 1
      noMessage sub

  forM_ [En, Zh] $ \language ->
    it ("walks 15 mock nodes with chronological sequences and globally fresh visible candidate IDs: " <> show language) $
      withEngine mockBranches $ \_ store manager -> do
        sid <- createManagedSession manager language
        sub <- connected manager sid
        initial <- events sub
        let CloudSpawned _ cloud = (head initial).event
        walk sub 15 (head cloud)
        Just history <- loadEvents store sid
        let state = replay (Log (reverse history))
            visible = [c.candidateId | stamped <- history, c <- case stamped.event of
              CloudSpawned _ cs -> cs
              CandidateStreamed _ candidate -> [candidate]
              _ -> []]
        Map.size state.sessionNodes `shouldBe` 15
        map (\e -> e.seq) history `shouldBe` [1 .. length history]
        all (\e -> e.atMs > 0) history `shouldBe` True
        length visible `shouldBe` length (nub visible)
        Set.size state.sessionVisited `shouldBe` 15

quiet :: BranchGenerator
quiet _ _ = atomically retry

walk :: Subscription -> Int -> Candidate -> IO ()
walk sub remaining candidate = do
  submit sub (ClientMsg remaining (Pick candidate.candidateId))
  _ <- events sub
  offered <- events sub
  case [cs | stamped <- offered, BranchesOffered _ cs <- [stamped.event]] of
    [next : _] | remaining > 1 -> walk sub (remaining - 1) next
    [_ : _] -> pure ()
    _ -> expectationFailure "Mock exhausted its branch vocabulary"

streamedWords :: [Stamped] -> [Text]
streamedWords batch = [candidate.word | stamped <- batch, CandidateStreamed _ candidate <- [stamped.event]]

connected :: Manager -> SessionId -> IO Subscription
connected manager sid = bounded (subscribeSession manager sid) >>= \case
  Left rejection -> expectationFailure (show rejection) >> fail "Subscription failed"
  Right sub -> pure sub

events :: Subscription -> IO [Stamped]
events sub = bounded (receive sub) >>= \case
  Events batch -> pure batch
  other -> expectationFailure (show other) >> fail "Expected events"

bounded :: IO a -> IO a
bounded action = timeout 3000000 action >>= maybe (fail "Timed out waiting for actor") pure

noMessage :: Subscription -> Expectation
noMessage sub = timeout 30000 (receive sub) `shouldReturn` Nothing

data Gate = Gate
  { gateWords :: MVar [Text]
  , gateCancelled :: MVar ()
  }

nextGate :: TQueue Gate -> IO Gate
nextGate = bounded . atomically . readTQueue

withGates :: Bool -> (FilePath -> Store -> Manager -> TQueue Gate -> IO ()) -> IO ()
withGates stubborn action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store -> do
  calls <- newTQueueIO
  gates <- newTVarIO []
  let generator _ _ = do
        gate <- Gate <$> newEmptyMVar <*> newEmptyMVar
        atomically $ modifyTVar' gates (gate :) >> writeTQueue calls gate
        readMVar (gateWords gate) `catch` \(err :: AsyncCancelled) -> do
          void (tryPutMVar (gateCancelled gate) ())
          if stubborn then readMVar (gateWords gate) else throwIO err
      release = readTVarIO gates >>= mapM_ (\gate -> void (tryPutMVar (gateWords gate) []))
  manager <- newManager store generator
  action path store manager calls `finally` (release >> bounded (stopManager manager))

withEngine :: BranchGenerator -> (FilePath -> Store -> Manager -> IO ()) -> IO ()
withEngine generator action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
  bracket (newManager store generator) stopManager (action path store)

withRaw :: FilePath -> (SQL.Connection -> IO a) -> IO a
withRaw path = bracket (SQL.open path) SQL.close

withDatabase :: (FilePath -> IO a) -> IO a
withDatabase action = bracket acquire removeFile action
  where
    acquire = do
      directory <- getTemporaryDirectory
      (path, handle) <- openTempFile directory "drift-actor-test.sqlite"
      hClose handle
      pure path
