module StoreSpec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, try)
import qualified Database.SQLite.Simple as SQL
import Drift.Domain.Types (SessionId (..))
import Drift.Protocol (Event (..), Lang (..), Stamped (..))
import Drift.Store.SQLite
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Hspec

spec :: Spec
spec = describe "SQLite event store" $ do
  it "restores ordered events after closing and reopening the database" $
    withDatabase $ \path -> do
      withStore path $ \store -> do
        createSession store sid [cloud]
        appendEvents store sid 1 [second, third]
      withStore path $ \store ->
        loadEvents store sid `shouldReturn` Just [cloud, second, third]

  it "distinguishes an unknown session from a known empty session after reopening" $
    withDatabase $ \path -> do
      withStore path $ \store -> createSession store sid []
      withStore path $ \store -> do
        loadEvents store sid `shouldReturn` Just []
        loadEvents store (SessionId "missing") `shouldReturn` Nothing

  it "rejects duplicate session identifiers without replacing their events" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud]
      createSession store sid [] `shouldThrow` (== SessionAlreadyExists sid)
      loadEvents store sid `shouldReturn` Just [cloud]

  it "rejects appends to unknown sessions" $
    withDatabase $ \path -> withStore path $ \store ->
      appendEvents store sid 0 [cloud] `shouldThrow` (== SessionNotFound sid)

  it "rejects a stale expected tail, including for empty appends" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud]
      appendEvents store sid 0 [second] `shouldThrow` (== TailMismatch sid 0 1)
      appendEvents store sid 0 [] `shouldThrow` (== TailMismatch sid 0 1)
      loadEvents store sid `shouldReturn` Just [cloud]

  it "allows an empty append when its expected tail matches" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid []
      appendEvents store sid 0 []
      appendEvents store sid 0 [cloud]
      loadEvents store sid `shouldReturn` Just [cloud]

  it "rejects duplicate sequence numbers and rolls back the whole batch" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud]
      appendEvents store sid 1 [second, second]
        `shouldThrow` (== InvalidSequence sid 3 2)
      loadEvents store sid `shouldReturn` Just [cloud]

  it "rejects a gap or an already persisted sequence number" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud]
      appendEvents store sid 1 [third] `shouldThrow` (== InvalidSequence sid 2 3)
      appendEvents store sid 1 [cloud] `shouldThrow` (== InvalidSequence sid 2 1)
      loadEvents store sid `shouldReturn` Just [cloud]

  it "requires creation batches to start at one and leaves no empty session on failure" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud, third] `shouldThrow` (== InvalidSequence sid 2 3)
      loadEvents store sid `shouldReturn` Nothing
      createSession store sid [cloud]

  it "rolls back earlier inserts when SQLite fails partway through an append" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud]
      withRaw path $ \connection -> SQL.execute_ connection
        "CREATE TRIGGER reject_third BEFORE INSERT ON events WHEN NEW.seq = 3 BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
      appendEvents store sid 1 [second, third] `shouldThrow` isStorageFailure
      loadEvents store sid `shouldReturn` Just [cloud]

  it "rolls back session creation when inserting its initial event fails" $
    withDatabase $ \path -> withStore path $ \store -> do
      withRaw path $ \connection -> SQL.execute_ connection
        "CREATE TRIGGER reject_events BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
      createSession store sid [cloud] `shouldThrow` isStorageFailure
      loadEvents store sid `shouldReturn` Nothing

  it "reports malformed persisted JSON instead of skipping the event" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud]
      withRaw path $ \connection -> SQL.execute_ connection
        "UPDATE events SET payload = 'not JSON' WHERE seq = 1"
      loadEvents store sid `shouldThrow` isMalformedEvent

  it "reports persisted sequence gaps on reads and appends" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud, second, third]
      withRaw path $ \connection -> SQL.execute_ connection "DELETE FROM events WHERE seq = 2"
      loadEvents store sid `shouldThrow` (== InvalidSequence sid 2 3)
      appendEvents store sid 3 [] `shouldThrow` (== InvalidSequence sid 2 3)

  it "closes idempotently and rejects access after close" $
    withDatabase $ \path -> do
      store <- openStore path
      closeStore store
      closeStore store
      loadEvents store sid `shouldThrow` (== StoreClosed)

  it "serializes competing appends on a shared connection" $
    withDatabase $ \path -> withStore path $ \store -> do
      createSession store sid [cloud]
      outcomes <- raceAppends store store
      outcomes `shouldMatchList` [Right (), Left (TailMismatch sid 1 2)]
      loadEvents store sid `shouldReturn` Just [cloud, second]

  it "checks the expected tail atomically across separate connections" $
    withDatabase $ \path -> withStore path $ \first -> withStore path $ \other -> do
      createSession first sid [cloud]
      outcomes <- raceAppends first other
      outcomes `shouldMatchList` [Right (), Left (TailMismatch sid 1 2)]
      loadEvents first sid `shouldReturn` Just [cloud, second]

sid :: SessionId
sid = SessionId "session-\x6d4b\x8bd5"

cloud, second, third :: Stamped
cloud = Stamped 1 1700000000000 (CloudSpawned En [])
second = Stamped 2 1700000000010 (DivergenceSet 0.75)
third = Stamped 3 1700000000020 WrappedUp

isStorageFailure :: StoreException -> Bool
isStorageFailure (StorageFailure _) = True
isStorageFailure _ = False

isMalformedEvent :: StoreException -> Bool
isMalformedEvent (MalformedEvent session sequenceNumber _) = session == sid && sequenceNumber == 1
isMalformedEvent _ = False

raceAppends :: Store -> Store -> IO [Either StoreException ()]
raceAppends first other = do
  firstResult <- newEmptyMVar
  otherResult <- newEmptyMVar
  _ <- forkIO (try (appendEvents first sid 1 [second]) >>= putMVar firstResult)
  _ <- forkIO (try (appendEvents other sid 1 [second]) >>= putMVar otherResult)
  sequence [takeMVar firstResult, takeMVar otherResult]

withStore :: FilePath -> (Store -> IO a) -> IO a
withStore path = bracket (openStore path) closeStore

withRaw :: FilePath -> (SQL.Connection -> IO a) -> IO a
withRaw path = bracket (SQL.open path) SQL.close

withDatabase :: (FilePath -> IO a) -> IO a
withDatabase action = bracket acquire removeFile action
  where
    acquire = do
      directory <- getTemporaryDirectory
      (path, handle) <- openTempFile directory "drift-store-test.sqlite"
      hClose handle
      pure path
