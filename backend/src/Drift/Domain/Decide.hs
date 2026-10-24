{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Pure command validation and admission of actor-owned pipeline results.
module Drift.Domain.Decide (decide, offerBranches, admitEntry, admitSource) where

import Control.Applicative ((<|>))
import Control.Monad (unless, when)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Char (isSpace)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Drift.Domain.Entries (decideCuration, entriesForNode)
import Drift.Domain.Types
import Drift.Domain.Word (cap, wordKey)
import Drift.Protocol
import Drift.Pipeline.Writing (reviseForSource)
import Drift.Search.Text (normalizeDoi, normalizeKey)
import Drift.Search.Types (SourceDraft, toSource)

decide :: Session -> Command -> Either Rejection [Event]
decide s command = case command of
  -- Placement and repeated wrap-up remain legal after wrapping.
  PlaceNode n position rotation -> do
    require (Map.member n s.sessionNodes) "Cannot place an unknown node."
    validPlacement position rotation
    pure [NodePlaced n position rotation]
  PlaceSource sid position rotation -> do
    require (Map.member sid s.sessionSources) "Cannot place an unknown source."
    validPlacement position rotation
    pure [SourcePlaced sid position rotation]
  WrapUp -> pure (if s.sessionWrapped then [] else [WrappedUp])
  _ -> do
    require (not s.sessionWrapped) "The session is wrapped up; exploration and curation are closed."
    explore command
  where
    explore = \case
      Pick cid -> do
        c <- maybe (Left (Rejection "That candidate is not currently available.")) Right
          (Map.lookup cid s.sessionCandidates)
        unvisited s c.word
        let origin = if s.sessionFocus == Nothing then Cloud else Branch
        pure [NodeChosen s.sessionNextNodeId s.sessionFocus c.word origin (Just cid)]
      StartWithWord input -> do
        require (Map.null s.sessionNodes) "A starting word is only allowed before the first node."
        word <- validWord input
        unvisited s word
        pure [NodeChosen s.sessionNextNodeId Nothing word StartWord Nothing]
      InsertWord input -> do
        parent <- maybe (Left (Rejection "Choose a word before inserting a child.")) Right s.sessionFocus
        word <- validWord input
        unvisited s word
        pure [NodeChosen s.sessionNextNodeId (Just parent) word Insert Nothing]
      Backtrack n -> do
        require (Map.member n s.sessionNodes) "Cannot revisit an unknown node."
        -- Going "back" to the current focus would reroll a ring the user can
        -- already see, which idea.md rules out (branches cannot be
        -- regenerated). It stays allowed while nothing is pickable, which is
        -- how a lost or failed ring is recovered.
        require (s.sessionFocus /= Just n || Map.null s.sessionCandidates)
          "Those branches are already on the desk; they cannot be regenerated."
        pure [NodeRevisited n]
      SetDivergence d -> do
        require (finite d && d >= 0 && d <= 1) "Divergence must be a finite number between 0 and 1."
        pure [DivergenceSet d]
      -- Curation rules live in "Drift.Domain.Entries", shared with the writing pipeline.
      c@(Promote _ _) -> curate c
      c@(Strike _) -> curate c
      c@(Restore _) -> curate c
      -- Exhaustive handling keeps additions to Command visible to -Wall.
      PlaceNode n position rotation -> decide s (PlaceNode n position rotation)
      PlaceSource sid position rotation -> decide s (PlaceSource sid position rotation)
      WrapUp -> decide s WrapUp
    curate c = case decideCuration s.sessionEntries c of
      Just (Left reason) -> Left (Rejection reason)
      Just (Right events) -> Right events
      Nothing -> Left (Rejection "Not a curation command.")

-- | Validate all IDs before filtering words. Previously visible IDs cannot be
-- recycled even when their new word would otherwise be filtered out.
-- Generation tokens belong to the actor: a node ID alone cannot distinguish
-- a stale result from a previous generation for the same focus node.
offerBranches :: Session -> NodeId -> [Candidate] -> Either Rejection [Event]
offerBranches s n candidates = do
  require (not s.sessionWrapped) "The session is wrapped up; no new branches can be offered."
  require (s.sessionFocus == Just n) "Branches no longer belong to the current focus."
  let ids = map (\c -> c.candidateId) candidates
      uniqueIds = Set.fromList ids
  require (Set.size uniqueIds == length ids) "A branch result contains duplicate candidate IDs."
  require (Set.null (Set.intersection uniqueIds s.sessionSeenCandidates))
    "A branch result reuses a previously visible candidate ID."
  let (_, reversed) = foldl' admit (Set.empty, []) candidates
      accepted = reverse reversed
  pure (map (CandidateStreamed n) accepted <> [BranchesOffered n accepted])
  where
    admit (seenWords, accepted) c =
      let key = wordKey c.word
          count = Map.findWithDefault 0 key s.sessionAppearances
       in if Set.member key seenWords || Set.member key s.sessionVisited || count >= cap s.sessionDivergence
          then (Set.insert key seenWords, accepted)
          else (Set.insert key seenWords, c : accepted)

-- | A worker proposes content only. The actor's current replayed state owns
-- the ID and all sources attached since the worker took its snapshot.
admitEntry :: Session -> Entry -> Either Rejection [Event]
admitEntry s proposed = do
  requireEdge s proposed.node
  require (null (entriesForNode proposed.node s.sessionEntries)) "That edge already has an entry."
  mapM_ validCitation proposed.cites
  let eid = case Map.lookupMax s.sessionEntries of
        Nothing -> EntryId 1
        Just (EntryId previous, _) -> EntryId (previous + 1)
      current = [src.sourceId | src <- Map.elems s.sessionSources, src.node == proposed.node]
      citations = foldl' (\acc sid -> if sid `elem` acc then acc else acc <> [sid]) [] (proposed.cites <> current)
  pure [EntryWritten (proposed {entryId = eid, cites = citations})]
  where
    validCitation sid = do
      src <- maybe (Left (Rejection "An entry cites an unknown source.")) Right (Map.lookup sid s.sessionSources)
      require (src.node == proposed.node) "An entry may only cite sources belonging to its edge."

-- | Admit a source once per edge, atomically attaching it to any existing
-- entry. EntryRevised changes only content, so replay retains curation.
admitSource :: Session -> NodeId -> SourceDraft -> Either Rejection [Event]
admitSource s n draft = do
  requireEdge s n
  let sid = case Map.lookupMax s.sessionSources of
        Nothing -> SourceId 1
        Just (SourceId previous, _) -> SourceId (previous + 1)
      src = toSource sid n draft
      existing = filter (\old -> old.node == n) (Map.elems s.sessionSources)
  require (all ((/= sourceIdentity src) . sourceIdentity) existing) "That source already belongs to this edge."
  pure (SourceFound src : reviseForSource s.sessionEntries src)

requireEdge :: Session -> NodeId -> Either Rejection ()
requireEdge s n = do
  require (not s.sessionWrapped) "The session is wrapped up; no new sources or entries can be admitted."
  chosen <- maybe (Left (Rejection "Cannot attach a result to an unknown node.")) Right (Map.lookup n s.sessionNodes)
  require (chosen.nodeParent /= Nothing) "A root node has no edge for a source or entry."

-- | DOI metadata and resolver links share an identity; otherwise use the
-- canonical URL, falling back to the title for replayed sources without one.
sourceIdentity :: Source -> Text
sourceIdentity src = case metadataDoi <|> normalizeDoi src.url of
  Just doi -> "doi:" <> doi
  Nothing
    | not (Text.null urlKey) -> "url:" <> urlKey
    | otherwise -> "title:" <> normalizeKey src.title
  where
    urlKey = normalizeKey src.url
    metadataDoi = case src.csl of
      Just (Object fields) -> case KeyMap.lookup "DOI" fields of
        Just (String doi) -> normalizeDoi doi
        _ -> Nothing
      _ -> Nothing

validWord :: Text -> Either Rejection Text
validWord input = do
  let word = Text.strip input
  require (not (Text.null word)) "Enter a nonempty word."
  require (not (Text.any isSpace word)) "Enter exactly one word without internal whitespace."
  pure word

unvisited :: Session -> Text -> Either Rejection ()
unvisited s word = when (Set.member (wordKey word) s.sessionVisited)
  (Left (Rejection "That word has already been chosen."))

validPlacement :: Vec2 -> Double -> Either Rejection ()
validPlacement (Vec2 px py) rotation =
  require (all finite [px, py, rotation]) "Position coordinates and angle must be finite numbers."

finite :: Double -> Bool
finite n = not (isNaN n || isInfinite n)

require :: Bool -> Text -> Either Rejection ()
require condition reason = unless condition (Left (Rejection reason))
