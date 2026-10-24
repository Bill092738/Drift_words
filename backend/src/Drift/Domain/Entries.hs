{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The sidebar entry table: written entries, their priority and whether they
-- are struck through.
--
-- Everything here is pure. The session's @decide@ and @apply@ delegate to
-- 'decideCuration' and 'applyEntryEvent' for the entry-related part of the
-- protocol, so the rules live in one place and mirror the frontend reducer in
-- @frontend/src/store/session.ts@.
module Drift.Domain.Entries
  ( EntryState (..)
  , Entries
  , emptyEntries
  , applyEntryEvent
  , replayEntries
  , decideCuration
  , entriesForNode
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Drift.Protocol

-- | One entry as the sidebar shows it.
data EntryState = EntryState
  { entry :: Entry
  , priority :: Int -- ^ 0 when written; raised by promotions, without an upper limit
  , struck :: Bool
  , writtenSeq :: Int -- ^ sequence number of the event that first wrote the entry
  }
  deriving stock (Eq, Show)

type Entries = Map EntryId EntryState

emptyEntries :: Entries
emptyEntries = Map.empty

-- | Applies one event at the given sequence number. Events that do not concern
-- entries, or that name an unknown entry, leave the table unchanged.
applyEntryEvent :: Int -> Event -> Entries -> Entries
applyEntryEvent seqNo ev entries = case ev of
  EntryWritten {entry = e} -> write e
  EntryRevised {entry = e} -> write e
  EntryPromoted {entryId = i, levels = n} -> Map.adjust (\s -> s {priority = s.priority + n}) i entries
  EntryStruck {entryId = i} -> Map.adjust (\s -> s {struck = True}) i entries
  EntryRestored {entryId = i} -> Map.adjust (\s -> s {struck = False}) i entries
  _ -> entries
  where
    write e = Map.alter (Just . maybe (fresh e) (\(EntryState _ p k w) -> EntryState e p k w)) e.entryId entries
    fresh e = EntryState {entry = e, priority = 0, struck = False, writtenSeq = seqNo}

-- | Folds a log, oldest event first.
replayEntries :: [Stamped] -> Entries
replayEntries = foldl (\acc s -> applyEntryEvent s.seq s.event acc) emptyEntries

-- | Validates a curation command against the entry table.
--
-- Returns 'Nothing' for commands that are not curation commands, so callers
-- can chain it with the rest of their @decide@.
decideCuration :: Entries -> Command -> Maybe (Either Text [Event])
decideCuration entries = \case
  Promote {entryId = i, levels = n}
    | n < 1 -> Just (Left "promote needs at least one level")
    | otherwise -> Just (withEntry i (const (Right [EntryPromoted {entryId = i, levels = n}])))
  Strike {entryId = i} ->
    Just . withEntry i $ \s ->
      if s.struck then Left "entry is already struck" else Right [EntryStruck {entryId = i}]
  Restore {entryId = i} ->
    Just . withEntry i $ \s ->
      if s.struck then Right [EntryRestored {entryId = i}] else Left "entry is not struck"
  _ -> Nothing
  where
    withEntry i k = maybe (Left "unknown entry") k (Map.lookup i entries)

-- | Entries written for the edge into the given node.
entriesForNode :: NodeId -> Entries -> [EntryState]
entriesForNode n = filter (\s -> s.entry.node == n) . Map.elems

