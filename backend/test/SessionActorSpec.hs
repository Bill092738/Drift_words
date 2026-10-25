{-# LANGUAGE OverloadedRecordDot #-}

module SessionActorSpec (spec) where

import Control.Concurrent.Async (AsyncCancelled, async, cancel, concurrently, waitCatch)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, catch, finally, throwIO)
import Control.Monad (forM_, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Database.SQLite.Simple as SQL
import Drift.Domain.State (replay)
import Drift.Domain.Entries (EntryState (..))
import Drift.Domain.Types
import Drift.Pipeline.Writing (WritingInput (..), templateEntry)
import Drift.Search.Types (SourceDraft (..), SourceRequest (..))
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

  it "combines a custom cloud with live notes and sources, then replays without regenerating" $
    withDatabase $ \path -> do
      let customCloud _ = pure ["custom-root"]
          search _ emit = emit sourceDraft
          branches _ _ = pure ["child"]
          pipelines = Pipelines branches (Just templateEntry) (Just search)
      sid <- bracket (openStore path) closeStore $ \store ->
        bracket (newManagerWithPipelinesAndCloud store pipelines customCloud) stopManager $ \manager -> do
          sid <- createManagedSession manager En
          sub <- connected manager sid
          initial <- events sub
          map (.event) initial `shouldBe`
            [CloudSpawned En [Candidate (CandidateId 1) "custom-root"]]
          submit sub (ClientMsg 1 (Pick (CandidateId 1)))
          _ <- events sub
          offered <- awaitActor sub (\case BranchesOffered {} -> True; _ -> False)
          child <- case [candidate | BranchesOffered _ [candidate] <- offered] of
            [candidate] -> pure candidate
            other -> expectationFailure ("Expected one child candidate, got " <> show other) >> fail "invalid child ring"
          submit sub (ClientMsg 2 (Pick child.candidateId))
          _ <- events sub
          sourceEvents <- awaitActor sub (\case SourceFound {} -> True; _ -> False)
          entryEvents <- awaitActor sub (\case EntryWritten {} -> True; _ -> False)
          [source.sourceId | SourceFound source <- sourceEvents] `shouldBe` [SourceId 1]
          [entry.cites | EntryWritten entry <- entryEvents] `shouldBe` [[SourceId 1]]
          pure sid
      bracket (openStore path) closeStore $ \store ->
        bracket
          (newManagerWithPipelinesAndCloud store pipelines (\_ -> error "existing sessions must not regenerate their cloud"))
          stopManager $ \manager -> do
            sub <- connected manager sid
            snapshot <- events sub
            [candidate.word | Stamped _ _ (CloudSpawned _ [candidate]) <- snapshot] `shouldBe` ["custom-root"]
            length [() | Stamped _ _ (SourceFound _) <- snapshot] `shouldBe` 1
            [entry.cites | Stamped _ _ (EntryWritten entry) <- snapshot] `shouldBe` [[SourceId 1]]

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
        _ <- concurrently (submit a (ClientMsg 1 (SetDivergence 0.2)))
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

  it "rolls back an entire generated stream-and-seal batch if a later insert fails" $ do
    attempts <- newTQueueIO
    withGatesObserved False (\_ batch result -> atomically (writeTQueue attempts (batch, result))) $ \path store manager calls -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      initial <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      chosen <- events sub
      gate <- nextGate calls
      withRaw path $ \connection -> SQL.execute_ connection
        "CREATE TRIGGER reject_fourth BEFORE INSERT ON events WHEN NEW.seq = 4 BEGIN SELECT RAISE(ABORT, 'stream failure'); END"
      putMVar (gateWords gate) ["alpha", "beta"]
      -- The observer acknowledges the actual store outcome, so no quiet interval
      -- or scheduler assumption can stand in for the failed append attempt.
      (failedBatch, outcome) <- nextGeneratedAttempt attempts
      length failedBatch `shouldBe` 3
      case outcome of
        Left (StorageFailure _) -> pure ()
        other -> expectationFailure (show other)
      loadEvents store sid `shouldReturn` Just (initial <> chosen)
      receive sub `shouldReturn` Diagnostic LevelError
        "Saving the generated branches failed; revisit this word to generate them again."
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

  it "deactivates a cancelled queued Join before the actor can register it" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    let observer _ batch _ = case batch of
          [DivergenceSet 0.61] -> putMVar entered () >> readMVar release
          _ -> pure ()
    withObservedEngine quiet observer $ \_ _ manager -> do
      sid <- createManagedSession manager En
      writer <- connected manager sid
      _ <- events writer
      submit writer (ClientMsg 1 (SetDivergence 0.61))
      bounded (takeMVar entered)
      captured <- newEmptyMVar
      let acquiring = subscribeSessionWithJoinObserver manager sid $ \subscription -> do
            putMVar captured subscription
            atomically retry
      pendingJoin <- async acquiring
      (do
        orphan <- bounded (takeMVar captured)
        bounded (cancel pendingJoin)
        bounded (waitCatch pendingJoin) >>= \case
          Left _ -> pure ()
          Right _ -> expectationFailure "Join acquisition was not cancelled"
        putMVar release ()
        _ <- events writer
        submit writer (ClientMsg 2 (SetDivergence 0.4))
        _ <- events writer
        -- The second command is behind Join/Leave in the mailbox. It proves
        -- the cancelled Join was handled without snapshot or live output.
        noMessage orphan)
        `finally` (void (tryPutMVar release ()) >> cancel pendingJoin)

  it "cleans a cancelled first subscription after its actor and snapshot are installed" $
    withEngine quiet $ \_ store creator -> do
      sid <- createManagedSession creator En
      stopManager creator
      bracket (newManager store quiet) stopManager $ \manager -> do
        captured <- newEmptyMVar
        pendingJoin <- async $ subscribeSessionWithJoinObserver manager sid $ \subscription -> do
          _ <- events subscription
          putMVar captured subscription
          atomically retry
        (do
          orphan <- bounded (takeMVar captured)
          bounded (cancel pendingJoin)
          -- Cancellation happened after lazy actor startup and Join delivery.
          -- The published registry still owns that actor and remains usable.
          survivor <- connected manager sid
          _ <- events survivor
          submit survivor (ClientMsg 1 (SetDivergence 0.4))
          _ <- events survivor
          noMessage orphan)
          `finally` cancel pendingJoin

  it "keeps shutdown owned when the first waiting caller is cancelled" $
    withGates True $ \_ _ manager calls -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      gate <- nextGate calls
      stopping <- async (stopManager manager)
      bounded (readMVar (gateCancelled gate))
      bounded (cancel stopping)
      -- The shared shutdown job continues waiting for this resistant worker.
      putMVar (gateWords gate) []
      bounded (stopManager manager)
      subscribeSession manager sid >>= \case
        Left _ -> pure ()
        Right _ -> expectationFailure "Cancelled stop caller reopened the registry"

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

  it "retries generation twice, reports each retry, and publishes the recovered result" $ do
    attempts <- newIORef (0 :: Int)
    let generator _ _ = do
          attempt <- atomicModifyIORef' attempts (\n -> let next = n + 1 in (next, next))
          if attempt < 3 then throwIO (userError "temporary generator error") else pure ["recovered"]
    withEngine generator $ \_ _ manager -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      receive sub `shouldReturn` Diagnostic LevelWarning
        "Branch generation failed (attempt 1 of 3), retrying: temporary generator error"
      receive sub `shouldReturn` Diagnostic LevelWarning
        "Branch generation failed (attempt 2 of 3), retrying: temporary generator error"
      streamedWords <$> events sub `shouldReturn` ["recovered"]
      readIORef attempts `shouldReturn` 3
      noMessage sub

  it "reports a final diagnostic after three failures and remains usable" $ do
    attempts <- newIORef (0 :: Int)
    let generator _ _ = do
          atomicModifyIORef' attempts (\n -> (n + 1, ()))
          throwIO (userError "private generator error")
    withEngine generator $ \_ _ manager -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      receive sub `shouldReturn` Diagnostic LevelWarning
        "Branch generation failed (attempt 1 of 3), retrying: private generator error"
      receive sub `shouldReturn` Diagnostic LevelWarning
        "Branch generation failed (attempt 2 of 3), retrying: private generator error"
      receive sub `shouldReturn` Diagnostic LevelError
        "Branch generation failed after 3 attempts: private generator error"
      readIORef attempts `shouldReturn` 3
      submit sub (ClientMsg 2 (SetDivergence 0.4))
      map (\stamped -> stamped.event) <$> events sub `shouldReturn` [DivergenceSet 0.4]
      noMessage sub

  it "does not retry a rejected API key and says which setting to check" $ do
    attempts <- newIORef (0 :: Int)
    let generator _ _ = do
          atomicModifyIORef' attempts (\n -> (n + 1, ()))
          throwIO (userError "The model rejected the API key. OpenAI-compatible endpoint returned HTTP 401")
    withEngine generator $ \_ _ manager -> do
      sid <- createManagedSession manager En
      sub <- connected manager sid
      _ <- events sub
      submit sub (ClientMsg 1 (StartWithWord "root"))
      _ <- events sub
      message <- bounded (receive sub)
      case message of
        Diagnostic LevelError why -> Text.unpack why `shouldContain` "api_key_env"
        other -> expectationFailure (show other)
      readIORef attempts `shouldReturn` 1

  forM_ [En, Zh] $ \language ->
    it ("walks 15 mock nodes with chronological sequences and globally fresh visible candidate IDs: " <> show language) $
      withEngine mockBranches $ \_ store manager -> do
        sid <- createManagedSession manager language
        sub <- connected manager sid
        initial <- events sub
        firstCandidate <- case initial of
          Stamped _ _ (CloudSpawned _ (candidate : _)) : _ -> pure candidate
          _ -> expectationFailure "Expected a non-empty initial cloud" >> fail "Missing initial cloud"
        walk sub 15 firstCandidate
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

  describe "live sources" $ do
    it "includes sources completed before the writer snapshot" $ do
      snapshots <- newTQueueIO
      let writer input = atomically (writeTQueue snapshots input) >> templateEntry input
      -- Hold deadline delivery behind STM, so source completion (rather than
      -- scheduler speed within 250ms) is the only way to start this writer.
      let makeManager store pipelines = newManagerWithSourceWait store pipelines (atomically retry)
      withSourceGatesUsing makeManager writer $ \_ _ manager calls -> do
        (_, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        gate <- bounded (atomically (readTQueue calls))
        sourceEmit gate sourceDraft
        admitted <- events sub
        map (.event) admitted `shouldSatisfy` (\case [SourceFound _] -> True; _ -> False)
        putMVar (sourceRelease gate) ()
        input <- bounded (atomically (readTQueue snapshots))
        map (.title) input.sources `shouldBe` ["A source"]
        observed <- awaitActor sub (\case EntryWritten _ -> True; _ -> False)
        [entry.cites | EntryWritten entry <- observed] `shouldBe` [[SourceId 1]]

    it "reconciles sources between snapshot and entry commit" $ do
      snapshot <- newEmptyMVar
      releaseWriter <- newEmptyMVar
      let writer input = putMVar snapshot input >> takeMVar releaseWriter >> templateEntry input
      withSourceGates writer $ \_ _ manager calls -> do
        (_, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        gate <- bounded (atomically (readTQueue calls))
        input <- withinSourceWait (takeMVar snapshot)
        input.sources `shouldBe` []
        sourceEmit gate sourceDraft
        _ <- awaitActor sub (\case SourceFound _ -> True; _ -> False)
        putMVar releaseWriter ()
        observed <- awaitActor sub (\case EntryWritten _ -> True; _ -> False)
        [entry.cites | EntryWritten entry <- observed] `shouldBe` [[SourceId 1]]

    it "revises an entry when its source arrives after writing" $
      withSourceGates templateEntry $ \_ store manager calls -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        gate <- bounded (atomically (readTQueue calls))
        written <- withinSourceWait (awaitActor sub (\case EntryWritten _ -> True; _ -> False))
        [entry.cites | EntryWritten entry <- written] `shouldBe` [[]]
        sourceEmit gate sourceDraft
        batch <- events sub
        map (.event) batch `shouldSatisfy` (\case [SourceFound _, EntryRevised _] -> True; _ -> False)
        Just history <- loadEvents store sid
        let state = replay (Log (reverse history))
        map (\entry -> entry.entry.cites) (Map.elems state.sessionEntries) `shouldBe` [[SourceId 1]]

    it "isolates a search exception, redacts its details, and still writes" $
      withSources templateEntry (\_ _ -> throwIO (userError "api_key=sentinel-private-key")) $ \_ _ manager -> do
        (_, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        bounded (receive sub) >>= \case
          Diagnostic LevelWarning message -> message `shouldSatisfy` (not . Text.isInfixOf "sentinel-private-key")
          other -> expectationFailure (show other)
        entryBatch sub `shouldReturn` [Entry (EntryId 1) (NodeId 2) "root → child" "" []]
        submit sub (ClientMsg 3 (SetDivergence 0.3))
        map (.event) <$> events sub `shouldReturn` [DivergenceSet 0.3]

    it "rolls back source and entry revision together on append failure, then accepts a retry" $
      withSourceGates templateEntry $ \path store manager calls -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        gate <- bounded (atomically (readTQueue calls))
        _ <- awaitActor sub (\case EntryWritten _ -> True; _ -> False)
        beforeSource <- loadEvents store sid
        withRaw path $ \connection -> SQL.execute_ connection
          "CREATE TRIGGER reject_source_revision BEFORE INSERT ON events WHEN NEW.seq = 6 BEGIN SELECT RAISE(ABORT, 'private-source-failure'); END"
        sourceEmit gate sourceDraft
        bounded (receive sub) `shouldReturn` Diagnostic LevelError "Saving the source failed."
        loadEvents store sid `shouldReturn` beforeSource
        fence <- connected manager sid
        snapshot <- events fence
        Map.null (replay (Log (reverse snapshot))).sessionSources `shouldBe` True
        withRaw path $ \connection -> SQL.execute_ connection "DROP TRIGGER reject_source_revision"
        sourceEmit gate sourceDraft
        batch <- events sub
        map (.event) batch `shouldSatisfy` (\case [SourceFound _, EntryRevised _] -> True; _ -> False)

    it "isolates a lazy search completion failure without losing its pool worker" $ do
      attempts <- newIORef (0 :: Int)
      let search _ emit = do
            attempt <- atomicModifyIORef' attempts (\n -> (n + 1, n))
            if attempt == 0 then pure (error "api_key=lazy-private-search") else emit sourceDraft
      withSources templateEntry search $ \_ _ manager -> do
        (_, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        bounded (receive sub) >>= \case
          Diagnostic LevelWarning message -> message `shouldSatisfy` (not . Text.isInfixOf "lazy-private-search")
          other -> expectationFailure (show other)
        _ <- entryBatch sub
        submit sub (ClientMsg 3 (InsertWord "next"))
        _ <- events sub
        observed <- awaitActor sub (\case EntryWritten _ -> True; _ -> False)
        [entry.cites | EntryWritten entry <- observed] `shouldBe` [[SourceId 1]]

    it "keeps picks, backtracking and rings moving while a search never ends" $ do
      entered <- newEmptyMVar
      let search _ _ = putMVar entered () >> atomically retry
      withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
        bracket (newManagerWith store (Pipelines mockBranches (Just templateEntry) (Just search))) stopManager $ \manager -> do
          (_, sub) <- startWritingSession manager
          _ <- awaitActor sub (\case BranchesOffered _ _ -> True; _ -> False)
          submit sub (ClientMsg 2 (InsertWord "child"))
          bounded (takeMVar entered)
          childEvents <- awaitActor sub (\case BranchesOffered (NodeId 2) _ -> True; _ -> False)
          submit sub (ClientMsg 3 (Backtrack (NodeId 1)))
          revisitedEvents <- awaitActor sub (\case BranchesOffered (NodeId 1) _ -> True; _ -> False)
          let isWritten (EntryWritten _) = True
              isWritten _ = False
          if any isWritten (childEvents <> revisitedEvents) then pure ()
            else void (withinSourceWait (awaitActor sub isWritten))
          pure ()

    it "accepts old-edge sources after focus moves and deduplicates repeated callbacks" $
      withSourceGates templateEntry $ \_ store manager calls -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        gate <- bounded (atomically (readTQueue calls))
        submit sub (ClientMsg 3 (Backtrack (NodeId 1)))
        _ <- events sub
        sourceEmit gate sourceDraft
        sourceEmit gate sourceDraft
        _ <- awaitActor sub (\case SourceFound _ -> True; _ -> False)
        fence <- connected manager sid
        snapshot <- events fence
        let state = replay (Log (reverse snapshot))
        Map.size state.sessionSources `shouldBe` 1
        map (.node) (Map.elems state.sessionSources) `shouldBe` [NodeId 2]
        Just history <- loadEvents store sid
        length [() | Stamped _ _ (SourceFound _) <- history] `shouldBe` 1

    it "drops sources after wrap-up and cancels and joins source work on halt" $ do
      cancelled <- newEmptyMVar
      callbacks <- newEmptyMVar
      let search _ emit = (putMVar callbacks emit >> atomically retry) `finally` putMVar cancelled ()
      withSources templateEntry search $ \_ store manager -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        emit <- bounded (takeMVar callbacks)
        submit sub (ClientMsg 3 WrapUp)
        _ <- events sub
        emit sourceDraft
        fence <- connected manager sid
        snapshot <- events fence
        Map.null (replay (Log (reverse snapshot))).sessionSources `shouldBe` True
        bounded (stopManager manager)
        bounded (takeMVar cancelled)
        Just history <- loadEvents store sid
        Map.null (replay (Log (reverse history))).sessionSources `shouldBe` True

    it "bounds active searches globally, skips newest on queue overflow, and writes every edge" $ do
      started <- newTQueueIO
      active <- newTVarIO (0 :: Int)
      peak <- newTVarIO (0 :: Int)
      observedStarts <- newTVarIO []
      let search request _ = do
            release <- newEmptyMVar
            bracket
              (atomically $ do
                modifyTVar' active (+ 1)
                count <- readTVar active
                modifyTVar' peak (max count)
                modifyTVar' observedStarts (<> [request.toWord])
                writeTQueue started (request.toWord, release))
              (\_ -> atomically (modifyTVar' active (subtract 1)))
              (\_ -> takeMVar release)
          nextStarted = bounded (atomically (readTQueue started))
      withSources templateEntry search $ \_ store manager -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "edge-1"))
        _ <- events sub
        (firstWord, releaseFirst) <- nextStarted
        firstWord `shouldBe` "edge-1"
        -- The second live actor must share the same server-wide concurrency gate.
        (_, other) <- startWritingSession manager
        submit other (ClientMsg 2 (InsertWord "other-edge"))
        _ <- events other
        (otherWord, _) <- nextStarted
        otherWord `shouldBe` "other-edge"
        forM_ [2 .. 22 :: Int] $ \number ->
          submit sub (ClientMsg (number + 1) (InsertWord ("edge-" <> Text.pack (show number))))
        let collect count warnings
              | count == 22 = pure warnings
              | otherwise = receive sub >>= \case
                  Events batch -> collect (count + length [() | Stamped _ _ (EntryWritten _) <- batch]) warnings
                  Diagnostic LevelWarning message -> collect count (message : warnings)
                  otherMessage -> fail (show otherMessage)
        warnings <- bounded (collect 0 [])
        length (filter (Text.isInfixOf "queue is full") warnings) `shouldBe` 5
        readTVarIO active `shouldReturn` 2
        readTVarIO peak `shouldReturn` 2
        Just history <- loadEvents store sid
        Map.size (replay (Log (reverse history))).sessionEntries `shouldBe` 22
        -- Keep the other actor's search blocked while one worker drains exactly
        -- the sixteen oldest requests. Every start needs an explicit release.
        let queuedWords = ["edge-" <> Text.pack (show number) | number <- [2 .. 17 :: Int]]
        putMVar releaseFirst ()
        forM_ queuedWords $ \expected -> do
          (actual, release) <- nextStarted
          actual `shouldBe` expected
          putMVar release ()
        -- A later accepted probe fences the queue: any retained overflow job
        -- would start and block before it, making this exact identity fail.
        submit sub (ClientMsg 30 (InsertWord "queue-probe"))
        (probeWord, _) <- nextStarted
        probeWord `shouldBe` "queue-probe"
        readTVarIO observedStarts `shouldReturn` (["edge-1", "other-edge"] <> queuedWords <> ["queue-probe"])
        readTVarIO peak `shouldReturn` 2
        bounded (stopManager manager)
        readTVarIO active `shouldReturn` 0

  describe "live writing" $ do
    it "writes one template entry for a child and none for the root" $
      withWriting templateEntry $ \_ store manager -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        written <- entryBatch sub
        written `shouldBe` [Entry (EntryId 1) (NodeId 2) "root → child" "" []]
        Just history <- loadEvents store sid
        length [() | Stamped _ _ (EntryWritten _) <- history] `shouldBe` 1

    it "admits out-of-order completions for old nodes with unique actor-owned IDs" $ do
      calls <- newTQueueIO
      let writer input = do
            release <- newEmptyMVar
            atomically (writeTQueue calls (input, release))
            takeMVar release
            templateEntry input
      withWriting writer $ \_ store manager -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "first"))
        _ <- events sub
        (first, releaseFirst) <- bounded (atomically (readTQueue calls))
        first.path `shouldBe` ["root"]
        submit sub (ClientMsg 3 (InsertWord "second"))
        _ <- events sub
        (second, releaseSecond) <- bounded (atomically (readTQueue calls))
        second.path `shouldBe` ["root", "first"]
        submit sub (ClientMsg 4 (Backtrack (NodeId 1)))
        _ <- events sub
        putMVar releaseSecond ()
        entryBatch sub `shouldReturn` [Entry (EntryId 1) (NodeId 3) "first → second" "" []]
        putMVar releaseFirst ()
        entryBatch sub `shouldReturn` [Entry (EntryId 2) (NodeId 2) "root → first" "" []]
        Just history <- loadEvents store sid
        Map.size (replay (Log (reverse history))).sessionEntries `shouldBe` 2

    it "drops a writer completion after wrap-up" $ do
      entered <- newEmptyMVar
      release <- newEmptyMVar
      done <- newEmptyMVar
      let writer input = do
            putMVar entered ()
            takeMVar release
            templateEntry input `finally` putMVar done ()
      withWriting writer $ \_ store manager -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        bounded (takeMVar entered)
        submit sub (ClientMsg 3 WrapUp)
        _ <- events sub
        putMVar release ()
        bounded (takeMVar done)
        noMessage sub
        Just history <- loadEvents store sid
        Map.null (replay (Log (reverse history))).sessionEntries `shouldBe` True

    it "cancels and joins blocked writers on halt" $ do
      entered <- newEmptyMVar
      cancelled <- newEmptyMVar
      let writer _ = (putMVar entered () >> atomically retry) `finally` putMVar cancelled ()
      withWriting writer $ \_ _ manager -> do
        (_, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        bounded (takeMVar entered)
        bounded (stopManager manager)
        bounded (takeMVar cancelled)
        noMessage sub

    it "does not broadcast or retain an entry when append fails" $ do
      entered <- newEmptyMVar
      release <- newEmptyMVar
      let writer input = putMVar entered () >> takeMVar release >> templateEntry input
      withWriting writer $ \path store manager -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        bounded (takeMVar entered)
        historyBefore <- loadEvents store sid
        withRaw path $ \connection -> SQL.execute_ connection
          "CREATE TRIGGER reject_entry BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'entry failure'); END"
        putMVar release ()
        bounded (receive sub) >>= \case
          Diagnostic LevelError _ -> pure ()
          other -> expectationFailure (show other)
        loadEvents store sid `shouldReturn` historyBefore
        noMessage sub
        withRaw path $ \connection -> SQL.execute_ connection "DROP TRIGGER reject_entry"
        submit sub (ClientMsg 3 (SetDivergence 0.4))
        map (.event) <$> events sub `shouldReturn` [DivergenceSet 0.4]

    it "isolates an ordinary writer exception and keeps exploration usable" $
      withWriting (\_ -> throwIO (userError "writer failure")) $ \_ _ manager -> do
        (_, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        bounded (receive sub) >>= \case
          Diagnostic LevelWarning _ -> pure ()
          other -> expectationFailure (show other)
        entryBatch sub `shouldReturn` [Entry (EntryId 1) (NodeId 2) "root → child" "" []]
        submit sub (ClientMsg 3 (SetDivergence 0.3))
        map (.event) <$> events sub `shouldReturn` [DivergenceSet 0.3]

    it "isolates a lazy writer field failure without leaking its sentinel diagnostic" $ do
      let sentinel = "sentinel-secret-from-lazy-writer"
          writer input = pure (Entry (EntryId 0) input.node (error sentinel) "" [])
      withWriting writer $ \_ store manager -> do
        (sid, sub) <- startWritingSession manager
        submit sub (ClientMsg 2 (InsertWord "child"))
        _ <- events sub
        bounded (receive sub) >>= \case
          Diagnostic LevelWarning message ->
            message `shouldSatisfy` (not . Text.isInfixOf (Text.pack sentinel))
          other -> expectationFailure (show other)
        entryBatch sub `shouldReturn` [Entry (EntryId 1) (NodeId 2) "root \8594 child" "" []]
        submit sub (ClientMsg 3 (SetDivergence 0.2))
        map (.event) <$> events sub `shouldReturn` [DivergenceSet 0.2]
        Just history <- loadEvents store sid
        Map.size (replay (Log (reverse history))).sessionEntries `shouldBe` 1

    it "recovers a missing child entry on restart without duplicating existing entries" $
      withDatabase $ \path -> bracket (openStore path) closeStore $ \store -> do
        sid <- bracket (newManager store quiet) stopManager $ \manager -> do
          (sid, sub) <- startWritingSession manager
          submit sub (ClientMsg 2 (InsertWord "child"))
          _ <- events sub
          pure sid
        let recover = bracket (newManagerWith store (Pipelines quiet (Just templateEntry) Nothing)) stopManager
        recover $ \manager -> do
          sub <- connected manager sid
          snapshot <- events sub
          let existing = [entry | Stamped _ _ (EntryWritten entry) <- snapshot]
          recovered <- if null existing then entryBatch sub else pure existing
          recovered `shouldBe` [Entry (EntryId 1) (NodeId 2) "root → child" "" []]
        recover $ \manager -> do
          sub <- connected manager sid
          snapshot <- events sub
          length [() | Stamped _ _ (EntryWritten _) <- snapshot] `shouldBe` 1
          noMessage sub

data SourceGate = SourceGate
  { sourceEmit :: SourceDraft -> IO ()
  , sourceRelease :: MVar ()
  }

sourceDraft :: SourceDraft
sourceDraft = SourceDraft Article "A source" Nothing "https://example.org/source" Nothing Nothing

withSourceGates :: EntryWriter -> (FilePath -> Store -> Manager -> TQueue SourceGate -> IO ()) -> IO ()
withSourceGates = withSourceGatesUsing newManagerWith

withSourceGatesUsing :: (Store -> Pipelines -> IO Manager) -> EntryWriter
  -> (FilePath -> Store -> Manager -> TQueue SourceGate -> IO ()) -> IO ()
withSourceGatesUsing makeManager writer action = do
  calls <- newTQueueIO
  let search _ emit = do
        release <- newEmptyMVar
        atomically (writeTQueue calls (SourceGate emit release))
        takeMVar release
  withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
    bracket (makeManager store (Pipelines quiet (Just writer) (Just search))) stopManager
      (\manager -> action path store manager calls)

withSources :: EntryWriter -> SourceSearch -> (FilePath -> Store -> Manager -> IO ()) -> IO ()
withSources writer search action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
  bracket (newManagerWith store (Pipelines quiet (Just writer) (Just search))) stopManager (action path store)

-- The production deadline controls the test bound; no test sleeps to arrange
-- source/writer order. Barriers establish each ordering explicitly.
withinSourceWait :: IO a -> IO a
withinSourceWait action = timeout (sourceWaitMicros * 4) action >>= maybe
  (fail "Writer did not start within the bounded source wait") pure

awaitActor :: Subscription -> (Event -> Bool) -> IO [Event]
awaitActor sub predicate = bounded (go [])
  where
    go accumulated = receive sub >>= \case
      Events batch -> let combined = accumulated <> map (.event) batch
        in if any predicate combined then pure combined else go combined
      Diagnostic _ _ -> go accumulated
      other -> fail (show other)

withWriting :: EntryWriter -> (FilePath -> Store -> Manager -> IO ()) -> IO ()
withWriting writer action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
  bracket (newManagerWith store (Pipelines quiet (Just writer) Nothing)) stopManager (action path store)

startWritingSession :: Manager -> IO (SessionId, Subscription)
startWritingSession manager = do
  sid <- createManagedSession manager En
  sub <- connected manager sid
  _ <- events sub
  submit sub (ClientMsg 1 (StartWithWord "root"))
  _ <- events sub
  pure (sid, sub)

entryBatch :: Subscription -> IO [Entry]
entryBatch sub = do
  batch <- events sub
  pure [entry | Stamped _ _ (EntryWritten entry) <- batch]

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
withGates stubborn = withGatesObserved stubborn (\_ _ _ -> pure ())

withGatesObserved
  :: Bool -> (SessionId -> [Event] -> Either StoreException () -> IO ())
  -> (FilePath -> Store -> Manager -> TQueue Gate -> IO ()) -> IO ()
withGatesObserved stubborn observer action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store -> do
  calls <- newTQueueIO
  gates <- newTVarIO []
  let generator _ _ = do
        gate <- Gate <$> newEmptyMVar <*> newEmptyMVar
        atomically $ modifyTVar' gates (gate :) >> writeTQueue calls gate
        readMVar (gateWords gate) `catch` \(err :: AsyncCancelled) -> do
          void (tryPutMVar (gateCancelled gate) ())
          if stubborn then readMVar (gateWords gate) else throwIO err
      release = readTVarIO gates >>= mapM_ (\gate -> void (tryPutMVar (gateWords gate) []))
  manager <- newManagerWithAppendObserver store generator observer
  action path store manager calls `finally` (release >> bounded (stopManager manager))

withEngine :: BranchGenerator -> (FilePath -> Store -> Manager -> IO ()) -> IO ()
withEngine generator = withObservedEngine generator (\_ _ _ -> pure ())

withObservedEngine
  :: BranchGenerator -> (SessionId -> [Event] -> Either StoreException () -> IO ())
  -> (FilePath -> Store -> Manager -> IO ()) -> IO ()
withObservedEngine generator observer action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
  bracket (newManagerWithAppendObserver store generator observer) stopManager (action path store)

nextGeneratedAttempt
  :: TQueue ([Event], Either StoreException ()) -> IO ([Event], Either StoreException ())
nextGeneratedAttempt attempts = bounded (atomically awaitGenerated)
  where
    awaitGenerated = do
      attempt@(batch, _) <- readTQueue attempts
      if any isSeal batch then pure attempt else awaitGenerated
    isSeal (BranchesOffered _ _) = True
    isSeal _ = False

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
