{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | A keyed, one-shot cache for speculative branch generation.
module Drift.Pipeline.Prefetch
  ( PrefetchCache
  , PrefetchStart (..)
  , PrefetchError (..)
  , newPrefetchCache
  , startPrefetch
  , takePrefetch
  , cancelUnselected
  , shutdownPrefetchCache
  ) where

import Control.Concurrent.Async (Async)
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.STM
import Control.Exception (AsyncException, SomeException, displayException, fromException, mask, try)
import Control.Monad (void, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

data PrefetchStart
  = PrefetchStarted
  | PrefetchAlreadyPresent
  | PrefetchCacheClosed
  deriving stock (Eq, Show)

data PrefetchError
  = PrefetchCancelled
  | PrefetchFailed Text
  deriving stock (Eq, Show)

data Entry v = Entry
  { entryId :: Int
  , entryClaimed :: TVar Bool
  , entryResult :: TMVar (Either PrefetchError v)
  , entryWorker :: TMVar (Async ())
  }

data PrefetchCache k v = PrefetchCache
  { cacheEntries :: TVar (Map k (Entry v))
  , cacheNextId :: TVar Int
  , cacheClosed :: TVar Bool
  }

newPrefetchCache :: IO (PrefetchCache k v)
newPrefetchCache =
  atomically $
    PrefetchCache
      <$> newTVar Map.empty
      <*> newTVar 0
      <*> newTVar False

-- | Start a computation unless the key already has an outstanding value.
-- The map reservation and duplicate check are one STM transaction.
startPrefetch :: Ord k => PrefetchCache k v -> k -> IO v -> IO PrefetchStart
startPrefetch cache key action = mask $ \_ -> do
  claimed <- newTVarIO False
  result <- newEmptyTMVarIO
  workerSlot <- newEmptyTMVarIO
  entryNumber <- atomically $ do
    nextId <- readTVar cache.cacheNextId
    pure nextId
  let entry =
        Entry
          { entryId = entryNumber
          , entryClaimed = claimed
          , entryResult = result
          , entryWorker = workerSlot
          }
  started <- atomically $ reserve cache key entry
  case started of
    PrefetchStarted -> do
      worker <- Async.async (execute entry action)
      shouldCancel <- atomically $ do
        putTMVar entry.entryWorker worker
        not <$> isEmptyTMVar entry.entryResult
      when shouldCancel $ do
        Async.cancel worker
        void (Async.waitCatch worker)
      pure PrefetchStarted
    other -> pure other

-- | Claim and consume a prefetched result. Exactly one caller can claim an
-- entry; concurrent or later callers receive 'Nothing'.
takePrefetch
  :: Ord k
  => PrefetchCache k v
  -> k
  -> IO (Maybe (Either PrefetchError v))
takePrefetch cache key = do
  claimed <- atomically $ do
    entries <- readTVar cache.cacheEntries
    case Map.lookup key entries of
      Nothing -> pure Nothing
      Just entry -> do
        alreadyClaimed <- readTVar entry.entryClaimed
        if alreadyClaimed
          then pure Nothing
          else writeTVar entry.entryClaimed True >> pure (Just entry)
  case claimed of
    Nothing -> pure Nothing
    Just entry -> do
      value <- atomically (readTMVar entry.entryResult)
      atomically $ modifyTVar' cache.cacheEntries (deleteEntry key entry.entryId)
      pure (Just value)

-- | Keep the selected prediction and cancel all alternatives, including an
-- alternative that has already been claimed by a waiter.
cancelUnselected :: Ord k => PrefetchCache k v -> k -> IO ()
cancelUnselected cache selected = do
  discarded <- atomically $ do
    entries <- readTVar cache.cacheEntries
    let (kept, removed) = Map.partitionWithKey (\key _ -> key == selected) entries
    writeTVar cache.cacheEntries kept
    pure (Map.elems removed)
  mapM_ cancelEntry discarded

shutdownPrefetchCache :: PrefetchCache k v -> IO ()
shutdownPrefetchCache cache = do
  entries <- atomically $ do
    closed <- readTVar cache.cacheClosed
    if closed
      then pure []
      else do
        writeTVar cache.cacheClosed True
        current <- readTVar cache.cacheEntries
        writeTVar cache.cacheEntries Map.empty
        pure (Map.elems current)
  mapM_ cancelEntry entries

reserve
  :: Ord k
  => PrefetchCache k v
  -> k
  -> Entry v
  -> STM PrefetchStart
reserve cache key entry = do
  closed <- readTVar cache.cacheClosed
  entries <- readTVar cache.cacheEntries
  if closed
    then pure PrefetchCacheClosed
    else
      if Map.member key entries
        then pure PrefetchAlreadyPresent
        else do
          nextId <- readTVar cache.cacheNextId
          writeTVar cache.cacheNextId (nextId + 1)
          writeTVar cache.cacheEntries (Map.insert key (entry {entryId = nextId}) entries)
          pure PrefetchStarted

execute :: Entry v -> IO v -> IO ()
execute entry action = do
  outcome <- try @SomeException action
  atomically . void . tryPutTMVar entry.entryResult $
    case outcome of
      Right value -> Right value
      Left exception ->
        Left $
          if isAsyncException exception
            then PrefetchCancelled
            else PrefetchFailed (Text.pack (displayException exception))

cancelEntry :: Entry v -> IO ()
cancelEntry entry = do
  atomically $ void (tryPutTMVar entry.entryResult (Left PrefetchCancelled))
  worker <- atomically (readTMVar entry.entryWorker)
  Async.cancel worker
  void (Async.waitCatch worker)

deleteEntry :: Ord k => k -> Int -> Map k (Entry v) -> Map k (Entry v)
deleteEntry key expectedId entries =
  case Map.lookup key entries of
    Just entry | entry.entryId == expectedId -> Map.delete key entries
    _ -> entries

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  case fromException @AsyncException exception of
    Just _ -> True
    Nothing -> False