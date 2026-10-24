{-# LANGUAGE OverloadedRecordDot #-}

module DomainPropertySpec (spec) where

import Control.Monad (unless)
import Data.List (mapAccumL)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Drift.Domain.Decide
import Drift.Domain.State
import Drift.Domain.Types
import Drift.Domain.Word
import Drift.Protocol
import Test.Hspec
import Test.QuickCheck hiding (replay)

-- Each generated history starts with a root, admitted batch and chosen child;
-- subsequent actions mix successful/rejected commands, fresh offers, repeats,
-- backtracks, slider changes and invalid input. Shrinking preserves that prefix.
data Step = Step Session [Event] Session deriving Show

wordsToTry :: [Text]
wordsToTry = ["root", "ＲＯＯＴ", "river", "RIVER", "Ａ", "a", "Straße", "STRASSE", "\x68EE\x6797", "\x4E2D\x6587", "ocean", "two words", ""]

history :: [Int] -> [Step]
history choices = initial <> snd (mapAccumL advance started choices)
  where
    initialEvents = required (decide emptySession (StartWithWord "root"))
    rooted = foldl' apply emptySession initialEvents
    offered = required (offerBranches rooted (NodeId 1)
      [Candidate (CandidateId 1) "river", Candidate (CandidateId 2) "\x68EE\x6797"])
    offeredState = foldl' apply rooted offered
    chosen = required (decide offeredState (Pick (CandidateId 1)))
    childState = foldl' apply offeredState chosen
    revisited = required (decide childState (Backtrack (NodeId 1)))
    started = foldl' apply childState revisited
    initial = [Step emptySession initialEvents rooted, Step rooted offered offeredState,
               Step offeredState chosen childState, Step childState revisited started]
    required = either (error . ("Required property prefix rejected: " <>) . show) id
    advance s input =
      let n = toInteger input -- Avoid abs minBound overflow during shrinking.
          slot :: Int -> Int
          slot limit = fromInteger (abs n `mod` toInteger limit)
          w = wordsToTry !! slot (length wordsToTry)
          focused = maybe (NodeId 999) id s.sessionFocus
          oldNode = case s.sessionSelectionOrder of
            [] -> NodeId 999
            nodes -> nodes !! slot (length nodes)
          pickId = case Map.keys s.sessionCandidates of
            [] -> CandidateId 999
            ids -> ids !! slot (length ids)
          CandidateId next = s.sessionNextCandidateId
          batch = [Candidate (CandidateId next) w,
                   Candidate (CandidateId (next + 1)) (wordsToTry !! ((slot (length wordsToTry) + 1) `mod` length wordsToTry))]
          result = case slot 10 of
            0 -> decide s (InsertWord w)
            1 -> decide s (Pick pickId)
            2 -> decide s (Backtrack oldNode)
            3 -> decide s (SetDivergence (fromIntegral (slot 11) / 10))
            4 -> decide s (StartWithWord w)
            5 -> decide s (Backtrack (NodeId 999))
            6 -> decide s (PlaceNode oldNode (Vec2 2 3) 0)
            _ -> offerBranches s focused batch
          events = either (const []) id result
          nextState = foldl' apply s events
       in (nextState, Step s events nextState)

histories :: ([Step] -> Property) -> Property
histories assertion = forAllShrink (resize 80 (listOf arbitrary)) (shrinkList shrink) $ \choices ->
  counterexample ("Action integers: " <> show choices) (assertion (history choices))

-- QuickCheck's complete Result includes usedSeed and usedSize on Failure.
-- Print them explicitly so every failure can be reproduced with the same RNG.
checkProperty :: Testable prop => prop -> Expectation
checkProperty p = do
  result <- quickCheckWithResult stdArgs {maxSuccess = 100} p
  case result of
    Failure {usedSeed = seed, usedSize = size} ->
      expectationFailure ("QuickCheck RNG seed: " <> show seed <> "; size: " <> show size <> "\n" <> output result)
    _ -> unless (isSuccess result) (expectationFailure (output result))

spec :: Spec
spec = describe "domain invariants over generated decisions (100 cases each)" $ do
  it "never newly admits a visited word" $ checkProperty $ histories $ \steps ->
    conjoin [counterexample (show step) (property (Set.notMember (wordKey c.word) prior.sessionVisited))
            | step@(Step prior events _) <- steps, CandidateStreamed _ c <- events]
  it "never increases an admitted word's appearance count above the admission-time cap" $
    checkProperty $ histories $ \steps ->
      conjoin [counterexample (show step) $
                 Map.findWithDefault 0 (wordKey c.word) nextState.sessionAppearances ===
                   Map.findWithDefault 0 (wordKey c.word) prior.sessionAppearances + 1
                 .&&. property (Map.findWithDefault 0 (wordKey c.word) nextState.sessionAppearances <= cap prior.sessionDivergence)
               | step@(Step prior events nextState) <- steps, CandidateStreamed _ c <- events]
  it "gives every nonroot node an existing, earlier-selected parent" $
    checkProperty $ histories $ \steps ->
      conjoin [counterexample (show step) (validTree nextState) | step@(Step _ _ nextState) <- steps]
  it "replays every generated prefix to its incremental apply state" $
    checkProperty $ histories $ \steps ->
      let prefixes = drop 1 (scanl (\previous (Step _ events _) -> previous <> events) [] steps)
       in conjoin [counterexample (show step) $
                    replay (Log (reverse (zipWith (\i e -> Stamped i (fromIntegral i) e) [1..] events))) === nextState
                  | (step@(Step _ _ nextState), events) <- zip steps prefixes]

validTree :: Session -> Property
validTree s =
  let nodes = Map.elems s.sessionNodes
      validParent n = case n.nodeParent of
        Nothing -> n.nodeSelectionOrder == 1
        Just p -> case Map.lookup p s.sessionNodes of
          Nothing -> False
          Just parent -> parent.nodeSelectionOrder < n.nodeSelectionOrder
   in conjoin
      [ property (all validParent nodes)
      , length (filter ((== Nothing) . nodeParent) nodes) === 1
      , map (\nid -> nodeSelectionOrder <$> Map.lookup nid s.sessionNodes) s.sessionSelectionOrder ===
          map Just [1 .. length nodes]
      , Set.size (Set.fromList s.sessionSelectionOrder) === length nodes
      ]
