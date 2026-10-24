-- | Durable, oldest-first event logs. A Store serializes access to its
-- connection; immediate write transactions also protect optimistic appends
-- against other connections to the same database.
module Drift.Store.SQLite
  ( Store
  , StoreException (..)
  , openStore
  , closeStore
  , createSession
  , loadEvents
  , appendEvents
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (Exception, bracketOnError, catch, mask, onException, throwIO)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Database.SQLite.Simple as SQL
import Drift.Domain.Types (SessionId (..))
import Drift.Protocol (Event, Stamped (..))

newtype Store = Store (MVar (Maybe SQL.Connection))

-- | All expected store failures are catchable as one exception type.
-- TailMismatch carries expected then actual tail; InvalidSequence carries
-- expected then observed sequence. SQLite failures retain their diagnostics.
data StoreException
  = SessionAlreadyExists SessionId
  | SessionNotFound SessionId
  | TailMismatch SessionId Int Int
  | InvalidSequence SessionId Int Int
  | MalformedEvent SessionId Int Text
  | StorageFailure Text
  | StoreClosed
  deriving stock (Eq, Show)

instance Exception StoreException

openStore :: FilePath -> IO Store
openStore path = sqliteErrors $
  bracketOnError (SQL.open path) SQL.close $ \connection -> do
    SQL.execute_ connection "PRAGMA foreign_keys = ON"
    SQL.execute_ connection "PRAGMA busy_timeout = 5000"
    writeTransaction connection $ do
      SQL.execute_ connection
        "CREATE TABLE IF NOT EXISTS sessions (session_id TEXT PRIMARY KEY NOT NULL)"
      SQL.execute_ connection
        "CREATE TABLE IF NOT EXISTS events (session_id TEXT NOT NULL REFERENCES sessions(session_id), seq INTEGER NOT NULL CHECK (seq >= 1), ts INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (session_id, seq))"
    Store <$> newMVar (Just connection)

-- | Closing twice is harmless. Calls queued behind a close fail with StoreClosed.
closeStore :: Store -> IO ()
closeStore (Store lock) = sqliteErrors $ modifyMVar_ lock $ \case
  Nothing -> pure Nothing
  Just connection -> SQL.close connection >> pure Nothing

-- | The session marker and all initial events commit together, including when
-- the caller supplies an empty initial log.
createSession :: Store -> SessionId -> [Stamped] -> IO ()
createSession store session@(SessionId identifier) events =
  withConnection store $ \connection -> writeTransaction connection $ do
    exists <- sessionExists connection session
    when exists (throwIO (SessionAlreadyExists session))
    SQL.execute connection "INSERT INTO sessions (session_id) VALUES (?)" (SQL.Only identifier)
    insertEvents connection session 0 events

-- | Nothing denotes an unknown session; Just [] denotes a durable empty one.
-- Corrupt JSON and noncontiguous stored sequences fail the entire read.
loadEvents :: Store -> SessionId -> IO (Maybe [Stamped])
loadEvents store session = withConnection store $ \connection ->
  SQL.withTransaction connection $ readEvents connection session

-- | expectedTail is zero for an empty log. The comparison, sequence validation,
-- and every insert happen in one transaction, even for an empty batch.
appendEvents :: Store -> SessionId -> Int -> [Stamped] -> IO ()
appendEvents store session expectedTail events =
  withConnection store $ \connection -> writeTransaction connection $ do
    existing <- readEvents connection session >>= maybe (throwIO (SessionNotFound session)) pure
    let actualTail = length existing
    unless (expectedTail == actualTail) $
      throwIO (TailMismatch session expectedTail actualTail)
    insertEvents connection session actualTail events

withConnection :: Store -> (SQL.Connection -> IO a) -> IO a
withConnection (Store lock) action = sqliteErrors $ withMVar lock $ \case
  Nothing -> throwIO StoreClosed
  Just connection -> action connection

sqliteErrors :: IO a -> IO a
sqliteErrors action = action
  `catch` (\(err :: SQL.SQLError) -> throwIO (StorageFailure (Text.pack (show err))))
  `catch` (\(err :: SQL.ResultError) -> throwIO (StorageFailure (Text.pack (show err))))
  `catch` (\(err :: SQL.FormatError) -> throwIO (StorageFailure (Text.pack (show err))))

-- sqlite-simple's transaction helper rolls back action failures only. Explicit
-- cleanup also covers COMMIT failures (for example a reader holding a lock),
-- so the connection cannot retain an uncommitted batch after a failed append.
writeTransaction :: SQL.Connection -> IO a -> IO a
writeTransaction connection action = mask $ \restore -> do
  SQL.execute_ connection "BEGIN IMMEDIATE TRANSACTION"
  result <- restore action `onException` rollback
  SQL.execute_ connection "COMMIT TRANSACTION" `onException` rollback
  pure result
  where
    rollback = SQL.execute_ connection "ROLLBACK TRANSACTION"
      `catch` (\(_ :: SQL.SQLError) -> pure ())

sessionExists :: SQL.Connection -> SessionId -> IO Bool
sessionExists connection (SessionId identifier) = do
  rows <- SQL.query connection "SELECT 1 FROM sessions WHERE session_id = ?"
    (SQL.Only identifier) :: IO [SQL.Only Int]
  pure (not (null rows))

readEvents :: SQL.Connection -> SessionId -> IO (Maybe [Stamped])
readEvents connection session@(SessionId identifier) = do
  exists <- sessionExists connection session
  if not exists then pure Nothing else do
    rows <- SQL.query connection
      "SELECT seq, ts, payload FROM events WHERE session_id = ? ORDER BY seq ASC"
      (SQL.Only identifier) :: IO [(Int, Int64, Text)]
    events <- forM (zip [1 ..] rows) $ \(expected, (sequenceNumber, timestamp, payload)) -> do
      checkSequence session expected sequenceNumber
      event <- either (throwIO . MalformedEvent session sequenceNumber . Text.pack) pure
        (eitherDecodeStrict' (TextEncoding.encodeUtf8 payload) :: Either String Event)
      pure (Stamped sequenceNumber timestamp event)
    pure (Just events)

insertEvents :: SQL.Connection -> SessionId -> Int -> [Stamped] -> IO ()
insertEvents connection session@(SessionId identifier) tailSequence events =
  forM_ (zip [toInteger tailSequence + 1 ..] events) $ \(expected, Stamped sequenceNumber timestamp event) -> do
    -- Compare as Integer so a full Int tail cannot wrap to a negative sequence.
    unless (expected == toInteger sequenceNumber) $
      if expected > toInteger (maxBound :: Int)
        then throwIO (StorageFailure "Event sequence exceeds the supported Int range")
        else throwIO (InvalidSequence session (fromInteger expected) sequenceNumber)
    SQL.execute connection "INSERT INTO events (session_id, seq, ts, payload) VALUES (?, ?, ?, ?)"
      (identifier, sequenceNumber, timestamp, TextEncoding.decodeUtf8 (LBS.toStrict (encode event)))

checkSequence :: SessionId -> Int -> Int -> IO ()
checkSequence session expected observed = unless (expected == observed) $
  throwIO (InvalidSequence session expected observed)
