{-# LANGUAGE OverloadedRecordDot #-}

-- | The M2 branch pipeline ("Drift.Pipeline.BranchService") behind the session
-- actor's 'BranchGenerator' seam, so the live server offers model-generated
-- rings.
--
-- The actor calls the generator for its focus node after every pick, inserted
-- word and backtrack, and retries it when it throws. This module turns the
-- session into a 'BranchContext', runs 'branchesFor', and then starts a
-- speculative prefetch for every word of the new ring, so the next pick
-- usually finds its ring already generated.
--
-- Rings are offered sealed: the actor emits each word's 'CandidateStreamed'
-- together with 'BranchesOffered' once the ring is complete.
--
-- Prefetch keys are the normalized words from the root down to the node the
-- prefetch is for. One service is shared by every session on the server (the
-- model slot is single by design), and two sessions with the same path ask the
-- same question, so sharing a prefetch between them is harmless; it is
-- filtered again against the picking session either way.
module Drift.Pipeline.SessionBranches
  ( PrefetchKey
  , ringSize
  , liveBranches
  , branchContext
  , childContext
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Domain.Types (Node (..), Session (..))
import Drift.Domain.Word (wordKey)
import Drift.Model.Provider (readableError)
import Drift.Model.Scheduler (JobError (..))
import Drift.Model.SessionMock (BranchGenerator)
import Drift.Pipeline.BranchService
import Drift.Pipeline.Branches (BranchContext (..))
import Drift.Protocol (NodeId, Origin (..))

-- | Normalized words from the root down to the node a ring is for.
type PrefetchKey = [Text]

-- | Words per ring, as in the offline mocks.
ringSize :: Int
ringSize = 6

-- | A generator backed by the branch service. With @prefetch@ off, rings are
-- generated only when they are needed. A failed model call throws, so the
-- actor retries it; a ring with nothing left after filtering is empty.
liveBranches :: Bool -> BranchService PrefetchKey -> BranchGenerator
liveBranches prefetch service session target = case branchContext session target of
  Nothing -> pure []
  Just context -> do
    result <- branchesFor service (pickKey session target context) context (const (pure ()))
    case result of
      Left NoCandidates -> pure []
      Left (BranchJobFailed failure) -> throwIO (userError (T.unpack ("The branch model failed: " <> jobErrorText failure)))
      Right ring -> do
        when prefetch $
          forM_ ring $ \word ->
            let next = childContext context ring word
             in prefetchBranches service (keyOf next) next
        pure ring

-- | A scheduler error as a person should read it, without the backtrace.
jobErrorText :: JobError -> Text
jobErrorText = \case
  JobFailed message -> readableError message
  JobCancelled -> "the request was cancelled"
  SchedulerStopped -> "the model scheduler stopped"

-- | The prefetch to reuse for this ring, if any. Only a word just picked from
-- a ring can have one. Anything else (a backtrack, an inserted or typed word, a
-- cloud word) passes 'Nothing', which also cancels every running prefetch.
pickKey :: Session -> NodeId -> BranchContext -> Maybe PrefetchKey
pickKey session target context = case Map.lookup target session.sessionNodes of
  Just node
    | node.nodeOrigin == Branch
    , lastChosen == Just target ->
        Just (keyOf context)
  _ -> Nothing
  where
    lastChosen = case session.sessionSelectionOrder of
      [] -> Nothing
      order -> Just (last order)

keyOf :: BranchContext -> PrefetchKey
keyOf context = map wordKey context.pathToRoot

-- | The context for generating the ring of @target@: its word, the path from
-- the root down to it, the session's divergence, every chosen word, and how
-- often each word has been offered so far.
branchContext :: Session -> NodeId -> Maybe BranchContext
branchContext session target = do
  node <- Map.lookup target session.sessionNodes
  pure
    BranchContext
      { currentWord = node.nodeWord
      , pathToRoot = reverse (pathUp Set.empty target)
      , divergence = session.sessionDivergence
      , chosenWords = session.sessionVisited
      , appearanceCounts = session.sessionAppearances
      , branchCount = ringSize
      }
  where
    -- Words from @n@ up to the root. The guard keeps a malformed parent cycle
    -- from looping, as in "Drift.Domain.State".
    pathUp seen n
      | Set.member n seen = []
      | otherwise = case Map.lookup n session.sessionNodes of
          Nothing -> []
          Just node -> node.nodeWord : maybe [] (pathUp (Set.insert n seen)) node.nodeParent

-- | The context @word@ would have once picked from @ring@: one level deeper,
-- with the word chosen and every word of the ring offered once more.
childContext :: BranchContext -> [Text] -> Text -> BranchContext
childContext parent ring word =
  parent
    { currentWord = word
    , pathToRoot = parent.pathToRoot <> [word]
    , chosenWords = Set.insert (wordKey word) parent.chosenWords
    , appearanceCounts = Map.unionWith (+) parent.appearanceCounts (Map.fromListWith (+) [(wordKey w, 1) | w <- ring])
    }
