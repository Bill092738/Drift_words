{-# LANGUAGE OverloadedRecordDot #-}

module DomainDecideSpec (spec) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import Drift.Domain.Decide
import Drift.Domain.State
import Drift.Domain.Types
import Drift.Protocol
import Test.Hspec

live :: [Event] -> Session
live = foldl' apply emptySession

root :: Session
root = live [NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing]

candidate :: Int -> Text.Text -> Candidate
candidate i = Candidate (CandidateId i)

curated :: Session
curated = live
  [ NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing
  , SourceFound (Source (SourceId 1) (NodeId 1) WebPage "Reference" Nothing "https://example.org" Nothing Nothing)
  , EntryWritten (Entry (EntryId 1) (NodeId 1) "Relation" "Explanation" [SourceId 1])
  ]

rejected :: Either Rejection a -> Expectation
rejected result = case result of
  Left (Rejection reason) -> reason `shouldSatisfy` (not . Text.null . Text.strip)
  Right _ -> expectationFailure "Expected a human-readable rejection"

spec :: Spec
spec = do
  describe "decide: words and picks" $ do
    forM_ [" ocean ", "\t森林\n", "Straße"] $ \input ->
      it ("accepts one trimmed token: " <> show input) $
        decide emptySession (StartWithWord input) `shouldBe`
          Right [NodeChosen (NodeId 1) Nothing (Text.strip input) StartWord Nothing]
    forM_ ["", " \t\n", "two words", "two\twords", "两 个", "a\x2003\&b"] $ \input ->
      it ("rejects empty or multiple-token input: " <> show input) $ do
        rejected (decide emptySession (StartWithWord input))
        rejected (decide root (InsertWord input))
    it "requires an empty tree for a typed root, even when focus is absent" $ do
      rejected (decide root (StartWithWord "new"))
      rejected (decide (root {sessionFocus = Nothing}) (StartWithWord "new"))
    it "requires focus for insertion" $
      rejected (decide emptySession (InsertWord "child"))
    it "inserts with the next node ID, focus parent and Insert origin" $
      decide root (InsertWord " 森林 ") `shouldBe`
        Right [NodeChosen (NodeId 2) (Just (NodeId 1)) "森林" Insert Nothing]
    it "rejects visited identity under NFKC and case folding" $ do
      let s = live [NodeChosen (NodeId 1) Nothing "Straße" StartWord Nothing]
      rejected (decide s (InsertWord "ＳＴＲＡＳＳＥ"))
      rejected (decide (s {sessionNodes = Map.empty}) (StartWithWord "STRASSE"))
    it "picks only active IDs and links the current focus" $ do
      let c = candidate 7 "child"
          s = apply root (BranchesOffered (NodeId 1) [c])
      decide s (Pick (CandidateId 7)) `shouldBe`
        Right [NodeChosen (NodeId 2) (Just (NodeId 1)) "child" Branch (Just (CandidateId 7))]
      rejected (decide s (Pick (CandidateId 99)))
      rejected (decide emptySession (Pick (CandidateId 7)))
    it "permits an active initial-cloud pick with no parent" $ do
      let s = apply emptySession (CloudSpawned En [candidate 8 "ocean"])
      decide s (Pick (CandidateId 8)) `shouldBe`
        Right [NodeChosen (NodeId 1) Nothing "ocean" Cloud (Just (CandidateId 8))]
    it "rejects a visited word even when its candidate ID is active" $ do
      let s = apply root (BranchesOffered (NodeId 1) [candidate 8 "ＲＯＯＴ"])
      rejected (decide s (Pick (CandidateId 8)))
    it "uses the high-water node ID rather than the tree size" $
      decide (root {sessionNextNodeId = NodeId 40}) (InsertWord "child") `shouldBe`
        Right [NodeChosen (NodeId 40) (Just (NodeId 1)) "child" Insert Nothing]
  describe "decide: backtrack and divergence" $ do
    it "revisits an earlier node and clears old pickable candidates on apply" $ do
      let c = candidate 4 "child"
          sibling = candidate 5 "sibling"
          offered = apply root (BranchesOffered (NodeId 1) [c, sibling])
          s = apply offered (NodeChosen (NodeId 2) (Just (NodeId 1)) "child" Branch (Just (CandidateId 4)))
      decide s (Backtrack (NodeId 1)) `shouldBe` Right [NodeRevisited (NodeId 1)]
      let moved = apply s (NodeRevisited (NodeId 1))
      moved.sessionCandidates `shouldBe` Map.empty
      Map.lookup (NodeId 1) moved.sessionRings `shouldBe` Just [c, sibling]
      rejected (decide moved (Pick (CandidateId 5)))
      rejected (decide s (Backtrack (NodeId 99)))
    it "rejects a backtrack to the current focus once its ring is pickable (no rerolls)" $ do
      rejected (decide (apply root (BranchesOffered (NodeId 1) [candidate 4 "child"])) (Backtrack (NodeId 1)))
      -- With nothing pickable (still generating, or the ring was lost) it recovers the ring.
      decide root (Backtrack (NodeId 1)) `shouldBe` Right [NodeRevisited (NodeId 1)]
    forM_ [0, 0.25, 0.5, 1] $ \d ->
      it ("accepts finite divergence " <> show d) $
        decide root (SetDivergence d) `shouldBe` Right [DivergenceSet d]
    forM_ [-0.01, 1.01, 0/0, 1/0, -1/0] $ \d ->
      it ("rejects invalid divergence " <> show d) $
        rejected (decide root (SetDivergence d))
    it "tightening the cap does not remove existing offers or forbid picking them" $ do
      let a = candidate 1 "echo"
          b = candidate 2 "ＥＣＨＯ"
          s = live [NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing,
                    CandidateStreamed (NodeId 1) a, BranchesOffered (NodeId 1) [a],
                    CandidateStreamed (NodeId 1) b, BranchesOffered (NodeId 1) [b]]
          tightened = apply s (DivergenceSet 1)
      decide s (SetDivergence 1) `shouldBe` Right [DivergenceSet 1]
      tightened.sessionCandidates `shouldBe` s.sessionCandidates
      decide tightened (Pick (CandidateId 2)) `shouldSatisfy` (not . isLeft)
      offerBranches tightened (NodeId 1) [candidate 3 "echo"] `shouldBe`
        Right [BranchesOffered (NodeId 1) []]
  describe "decide: placement and curation" $ do
    it "emits valid placements, including after wrap-up" $ do
      forM_ [curated, apply curated WrappedUp] $ \s -> do
        decide s (PlaceNode (NodeId 1) (Vec2 (-2) 3) 0.5) `shouldBe`
          Right [NodePlaced (NodeId 1) (Vec2 (-2) 3) 0.5]
        decide s (PlaceSource (SourceId 1) (Vec2 2 (-3)) (-0.5)) `shouldBe`
          Right [SourcePlaced (SourceId 1) (Vec2 2 (-3)) (-0.5)]
    it "rejects unknown placement targets" $ do
      rejected (decide curated (PlaceNode (NodeId 99) (Vec2 0 0) 0))
      rejected (decide curated (PlaceSource (SourceId 99) (Vec2 0 0) 0))
    forM_ [0/0, 1/0, -1/0] $ \bad ->
      it ("rejects each non-finite placement component " <> show bad) $
        forM_ [(Vec2 bad 0, 0), (Vec2 0 bad, 0), (Vec2 0 0, bad)] $ \(p, a) -> do
          rejected (decide curated (PlaceNode (NodeId 1) p a))
          rejected (decide curated (PlaceSource (SourceId 1) p a))
    it "promotes by positive levels only and validates all entry IDs" $ do
      decide curated (Promote (EntryId 1) 3) `shouldBe` Right [EntryPromoted (EntryId 1) 3]
      forM_ [0, -1, minBound] $ \n -> rejected (decide curated (Promote (EntryId 1) n))
      forM_ [Promote (EntryId 99) 1, Strike (EntryId 99), Restore (EntryId 99)] $ \cmd ->
        rejected (decide curated cmd)
    it "strikes and restores an existing entry" $ do
      decide curated (Strike (EntryId 1)) `shouldBe` Right [EntryStruck (EntryId 1)]
      decide (apply curated (EntryStruck (EntryId 1))) (Restore (EntryId 1)) `shouldBe`
        Right [EntryRestored (EntryId 1)]
      -- Shared rules from Drift.Domain.Entries: no double strike, no restore of a live entry.
      rejected (decide (apply curated (EntryStruck (EntryId 1))) (Strike (EntryId 1)))
      rejected (decide curated (Restore (EntryId 1)))
  describe "decide: wrap-up" $ do
    it "emits one wrap event and is idempotent thereafter" $ do
      decide root WrapUp `shouldBe` Right [WrappedUp]
      decide (apply root WrappedUp) WrapUp `shouldBe` Right []
    it "rejects every exploration and curation command after wrapping" $ do
      let s = apply curated WrappedUp
      forM_ [Pick (CandidateId 1), StartWithWord "start", InsertWord "child",
             Backtrack (NodeId 1), SetDivergence 0.5, Promote (EntryId 1) 1,
             Strike (EntryId 1), Restore (EntryId 1)] $ \cmd -> rejected (decide s cmd)
      rejected (decide s (PlaceNode (NodeId 99) (Vec2 0 0) 0))
  describe "offerBranches" $ do
    it "admits in order, streams each candidate once, then seals once" $ do
      let cs = [candidate 9 "river", candidate 2 "森林"]
          events = map (CandidateStreamed (NodeId 1)) cs <> [BranchesOffered (NodeId 1) cs]
      offerBranches root (NodeId 1) cs `shouldBe` Right events
      let s = foldl' apply root events
      s.sessionAppearances `shouldBe` Map.fromList [("river", 1), ("森林", 1)]
      s.sessionSeenCandidates `shouldBe` Set.fromList [CandidateId 9, CandidateId 2]
      Map.lookup (NodeId 1) s.sessionStreamed `shouldBe` Just cs
      Map.lookup (NodeId 1) s.sessionRings `shouldBe` Just cs
    it "rejects absent, wrong or wrapped focus" $ do
      rejected (offerBranches emptySession (NodeId 1) [])
      rejected (offerBranches root (NodeId 99) [])
      rejected (offerBranches (apply root WrappedUp) (NodeId 1) [])
    it "rejects duplicate IDs before word filtering, even for visited words" $
      rejected (offerBranches root (NodeId 1) [candidate 7 "root", candidate 7 "child"])
    it "rejects any previously visible ID, including stream/seal and cloud IDs" $ do
      let c = candidate 7 "echo"
      forM_ [apply root (CandidateStreamed (NodeId 1) c),
             apply root (BranchesOffered (NodeId 1) [c]),
             live [CloudSpawned En [c], NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing]] $ \s ->
        rejected (offerBranches s (NodeId 1) [candidate 7 "unrelated"])
    it "filters normalized visited and batch duplicates, preserving first occurrence" $ do
      let a = candidate 2 "Straße"
          b = candidate 5 "森林"
      offerBranches root (NodeId 1)
        [candidate 1 "ＲＯＯＴ", a, candidate 3 "ＳＴＲＡＳＳＥ", b, candidate 6 "森林"]
        `shouldBe` Right [CandidateStreamed (NodeId 1) a, CandidateStreamed (NodeId 1) b,
                          BranchesOffered (NodeId 1) [a, b]]
    it "counts normalized fresh-ID appearances and filters exactly at the cap" $ do
      let a = candidate 1 "echo"
          b = candidate 2 "ＥＣＨＯ"
          s = live [NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing,
                    CandidateStreamed (NodeId 1) a, BranchesOffered (NodeId 1) [a]]
      offerBranches s (NodeId 1) [b] `shouldBe`
        Right [CandidateStreamed (NodeId 1) b, BranchesOffered (NodeId 1) [b]]
      let full = live [NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing,
                       CandidateStreamed (NodeId 1) a, BranchesOffered (NodeId 1) [a],
                       CandidateStreamed (NodeId 1) b, BranchesOffered (NodeId 1) [b]]
      offerBranches full (NodeId 1) [candidate 3 "echo", candidate 4 "river"] `shouldBe`
        Right [CandidateStreamed (NodeId 1) (candidate 4 "river"),
               BranchesOffered (NodeId 1) [candidate 4 "river"]]
    it "seals an empty result for empty or entirely filtered batches" $ do
      offerBranches root (NodeId 1) [] `shouldBe` Right [BranchesOffered (NodeId 1) []]
      offerBranches root (NodeId 1) [candidate 1 "root"] `shouldBe`
        Right [BranchesOffered (NodeId 1) []]
    it "relaxing divergence allows another fresh ID without resetting appearances" $ do
      let a = candidate 1 "echo"
          s = live [NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing,
                    DivergenceSet 1, CandidateStreamed (NodeId 1) a,
                    BranchesOffered (NodeId 1) [a]]
          relaxed = apply s (DivergenceSet 0)
          b = candidate 2 "ＥＣＨＯ"
      offerBranches s (NodeId 1) [b] `shouldBe` Right [BranchesOffered (NodeId 1) []]
      relaxed.sessionAppearances `shouldBe` s.sessionAppearances
      offerBranches relaxed (NodeId 1) [b] `shouldBe`
        Right [CandidateStreamed (NodeId 1) b, BranchesOffered (NodeId 1) [b]]
