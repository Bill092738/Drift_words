{-# LANGUAGE OverloadedRecordDot #-}

module Drift.Domain.State (emptySession, apply, applyStamped, replay) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Drift.Domain.Entries (applyEntryEvent, emptyEntries)
import Drift.Domain.Types
import Drift.Domain.Word (wordKey)
import Drift.Protocol

emptySession :: Session
emptySession = Session
  { sessionLanguage = Nothing
  , sessionNodes = Map.empty
  , sessionSelectionOrder = []
  , sessionFocus = Nothing
  , sessionBreadcrumbs = []
  , sessionVisited = Set.empty
  , sessionAppearances = Map.empty
  , sessionSeenCandidates = Set.empty
  , sessionCloud = []
  , sessionRingNode = Nothing
  , sessionCandidates = Map.empty
  , sessionRings = Map.empty
  , sessionStreamed = Map.empty
  , sessionNextNodeId = NodeId 1
  , sessionNextCandidateId = CandidateId 1
  , sessionDivergence = 0.5
  , sessionSources = Map.empty
  , sessionEntries = emptyEntries
  , sessionNodePlacements = Map.empty
  , sessionSourcePlacements = Map.empty
  , sessionWrapped = False
  , sessionOutputs = Nothing
  }

-- | Apply a recorded event at its sequence number. Entries remember the
-- sequence number that first wrote them, so replay and the live actor use this.
applyStamped :: Session -> Stamped -> Session
applyStamped s stamped = applyAt stamped.seq s stamped.event

-- | Apply an event without a sequence number (entries written here record 0).
-- For pure tests and decisions that do not depend on entry order.
apply :: Session -> Event -> Session
apply = applyAt 0

-- | Apply recorded facts, without command validation or new ID allocation.
-- Explicit matching makes protocol additions produce an exhaustiveness warning.
applyAt :: Int -> Session -> Event -> Session
applyAt seqNo s = \case
  CloudSpawned language cs ->
    let counted = observeAll s cs
     in counted { sessionLanguage = Just language, sessionCloud = cs
                , sessionCandidates = if s.sessionFocus == Nothing then candidateMap cs else s.sessionCandidates }
  NodeChosen n parent word origin from ->
    let order = length s.sessionSelectionOrder + 1
        chosen = Node n parent word origin from order []
        nodes = Map.insert n chosen s.sessionNodes
        linked = maybe nodes (\p -> Map.adjust (\old -> old {nodeChildren = old.nodeChildren <> [n]}) p nodes) parent
        NodeId i = n
        nextCandidate = maybe s.sessionNextCandidateId (advanceCandidate s.sessionNextCandidateId) from
        moved = moveFocus (s {sessionNodes = linked}) n
     in moved { sessionSelectionOrder = s.sessionSelectionOrder <> [n]
              , sessionVisited = Set.insert (wordKey word) s.sessionVisited
              , sessionNextNodeId = max s.sessionNextNodeId (NodeId (i + 1))
              , sessionNextCandidateId = nextCandidate }
  CandidateStreamed n c ->
    let counted = observe s c
        previous = Map.findWithDefault [] n s.sessionStreamed
        streamed = if any (\old -> old.candidateId == c.candidateId) previous then previous else previous <> [c]
     in counted { sessionStreamed = Map.insert n streamed s.sessionStreamed
                , sessionCandidates = if s.sessionFocus == Just n
                    then Map.insert c.candidateId c s.sessionCandidates else s.sessionCandidates }
  BranchesOffered n cs ->
    let counted = observeAll s cs
     in counted { sessionRings = Map.insert n cs s.sessionRings
                , sessionCandidates = if s.sessionFocus == Just n then candidateMap cs else s.sessionCandidates }
  NodeRevisited n -> moveFocus s n
  DivergenceSet d -> s {sessionDivergence = d}
  SourceFound src -> s {sessionSources = Map.insert src.sourceId src s.sessionSources}
  event@(EntryWritten _) -> entries event
  event@(EntryRevised _) -> entries event
  event@(EntryPromoted _ _) -> entries event
  event@(EntryStruck _) -> entries event
  event@(EntryRestored _) -> entries event
  NodePlaced n pos angle -> s {sessionNodePlacements = Map.insert n (Placement pos angle) s.sessionNodePlacements}
  SourcePlaced sid pos angle -> s {sessionSourcePlacements = Map.insert sid (Placement pos angle) s.sessionSourcePlacements}
  WrappedUp -> s {sessionWrapped = True}
  OutputsReady outputs -> s {sessionOutputs = Just outputs}
  where
    entries event = s {sessionEntries = applyEntryEvent seqNo event s.sessionEntries}

-- | Logs are newest-first; consume recorded events oldest-first exactly once.
replay :: Log -> Session
replay (Log events) = foldl' applyStamped emptySession (reverse events)

candidateMap :: [Candidate] -> Map.Map CandidateId Candidate
candidateMap = Map.fromList . map (\c -> (c.candidateId, c))

advanceCandidate :: CandidateId -> CandidateId -> CandidateId
advanceCandidate current (CandidateId i) = max current (CandidateId (i + 1))

observeAll :: Session -> [Candidate] -> Session
observeAll = foldl' observe

observe :: Session -> Candidate -> Session
observe s c = s
  { sessionNextCandidateId = advanceCandidate s.sessionNextCandidateId c.candidateId
  , sessionSeenCandidates = Set.insert c.candidateId s.sessionSeenCandidates
  , sessionAppearances = if Set.member c.candidateId s.sessionSeenCandidates
      then s.sessionAppearances
      else Map.insertWith (+) (wordKey c.word) 1 s.sessionAppearances
  }

-- | A move starts a fresh generation. Old sealed rings remain in history but
-- cannot be picked while replacement offers are still being generated.
moveFocus :: Session -> NodeId -> Session
moveFocus s n = s
  { sessionFocus = Just n
  , sessionBreadcrumbs = ancestors Set.empty n
  , sessionRingNode = Just n
  , sessionCandidates = Map.empty
  , sessionStreamed = Map.insert n [] s.sessionStreamed
  }
  where
    -- Valid command logs form a tree. The guard also keeps malformed imported
    -- logs total instead of looping forever on a cyclic parent link.
    ancestors seen child
      | Set.member child seen = []
      | otherwise = case Map.lookup child s.sessionNodes >>= nodeParent of
          Nothing -> []
          Just parent
            | Set.member parent (Set.insert child seen) -> []
            | otherwise -> parent : ancestors (Set.insert child seen) parent
