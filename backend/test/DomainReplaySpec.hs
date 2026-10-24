{-# LANGUAGE OverloadedRecordDot #-}

module DomainReplaySpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict)
import qualified Data.ByteString.Char8 as BS
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text
import Drift.Domain.Entries (EntryState (..))
import Drift.Domain.State
import Drift.Domain.Types
import Drift.Domain.Word
import Drift.Protocol
import Test.Hspec
import Test.QuickCheck (property)

live :: [Event] -> Session
live = foldl' apply emptySession

stamps :: [Event] -> [Stamped]
stamps = zipWith (\i e -> Stamped i (fromIntegral i) e) [1 ..]

root :: Event
root = NodeChosen (NodeId 1) Nothing "Root" StartWord Nothing

spec :: Spec
spec = do
  describe "word identity and repeat policy" $ do
    it "normalizes compatibility, case, composition and surrounding space" $ do
      wordKey "  ＳＴＲＡＳＳＥ  " `shouldBe` wordKey "Straße"
      wordKey "e\x0301" `shouldBe` wordKey "É"
      wordKey "　Ａ　" `shouldBe` "a"
    it "clamps divergence and has the specified endpoint caps" $
      map cap [-1, 0, 0.49, 0.5, 0.99, 1, 2] `shouldBe` [3, 3, 3, 2, 2, 1, 1]
  describe "session fold" $ do
    it "starts empty with divergence 0.5 and IDs starting at one" $ do
      emptySession.sessionDivergence `shouldBe` 0.5
      emptySession.sessionNextNodeId `shouldBe` NodeId 1
      emptySession.sessionNextCandidateId `shouldBe` CandidateId 1
      replay (Log []) `shouldBe` emptySession
    it "makes the initial cloud pickable and clears it on the first choice" $ do
      let a = Candidate (CandidateId 12) "Root"
          cloud = apply emptySession (CloudSpawned En [a])
          chosen = apply cloud (NodeChosen (NodeId 1) Nothing "Root" Cloud (Just (CandidateId 12)))
      cloud.sessionCandidates `shouldBe` Map.singleton (CandidateId 12) a
      cloud.sessionRingNode `shouldBe` Nothing
      chosen.sessionCloud `shouldBe` [a]
      chosen.sessionCandidates `shouldBe` Map.empty
      chosen.sessionRingNode `shouldBe` Just (NodeId 1)
      fmap nodeFromCandidate (Map.lookup (NodeId 1) chosen.sessionNodes) `shouldBe` Just (Just (CandidateId 12))
    it "counts visibility once per ID across cloud, stream and seal" $ do
      let a = Candidate (CandidateId 7) "Ａ"
          b = Candidate (CandidateId 9) " a "
          s = live [CloudSpawned Zh [a, a], root, CandidateStreamed (NodeId 1) a,
                    BranchesOffered (NodeId 1) [a], CandidateStreamed (NodeId 1) b,
                    BranchesOffered (NodeId 1) [a, b]]
      Map.lookup "a" s.sessionAppearances `shouldBe` Just 2
      s.sessionLanguage `shouldBe` Just Zh
      s.sessionNextCandidateId `shouldBe` CandidateId 10
      Map.elems s.sessionCandidates `shouldBe` [a, b]
      Map.lookup (NodeId 1) s.sessionStreamed `shouldBe` Just [a, b]
    it "keeps fork links, selection order and nearest-parent-first breadcrumbs" $ do
      let s = live [root, NodeChosen (NodeId 9) (Just (NodeId 1)) "left" Branch Nothing,
                    NodeChosen (NodeId 3) (Just (NodeId 9)) "leaf" Insert Nothing,
                    NodeRevisited (NodeId 1),
                    NodeChosen (NodeId 4) (Just (NodeId 1)) "right" Branch (Just (CandidateId 99))]
      s.sessionFocus `shouldBe` Just (NodeId 4)
      s.sessionBreadcrumbs `shouldBe` [NodeId 1]
      s.sessionSelectionOrder `shouldBe` [NodeId 1, NodeId 9, NodeId 3, NodeId 4]
      fmap nodeChildren (Map.lookup (NodeId 1) s.sessionNodes) `shouldBe` Just [NodeId 9, NodeId 4]
      fmap nodeParent (Map.lookup (NodeId 3) s.sessionNodes) `shouldBe` Just (Just (NodeId 9))
      fmap nodeSelectionOrder (Map.lookup (NodeId 4) s.sessionNodes) `shouldBe` Just 4
      Set.member "root" s.sessionVisited `shouldBe` True
      s.sessionNextNodeId `shouldBe` NodeId 10
      s.sessionNextCandidateId `shouldBe` CandidateId 100
    it "clears offers when moving and ignores off-focus offers for the active ring" $ do
      let a = Candidate (CandidateId 1) "a"
          s = live [root, BranchesOffered (NodeId 1) [a],
                    NodeChosen (NodeId 2) (Just (NodeId 1)) "child" Insert Nothing,
                    CandidateStreamed (NodeId 1) (Candidate (CandidateId 2) "late")]
      s.sessionCandidates `shouldBe` Map.empty
      (apply s (NodeRevisited (NodeId 1))).sessionCandidates `shouldBe` Map.empty
      (apply s (NodeRevisited (NodeId 1))).sessionBreadcrumbs `shouldBe` []
    it "retains sources, revised entries, cumulative promotion and reversible strikes" $ do
      let src = Source (SourceId 7) (NodeId 1) Paper "title" Nothing "url" Nothing Nothing
          e = Entry (EntryId 3) (NodeId 1) "relation" "draft" []
          revised = Entry (EntryId 3) (NodeId 1) "relation" "revised" [SourceId 7]
          s = live [root, SourceFound src, EntryWritten e, EntryPromoted (EntryId 3) 2,
                    EntryStruck (EntryId 3), EntryRevised revised, EntryPromoted (EntryId 3) 1]
      Map.lookup (SourceId 7) s.sessionSources `shouldBe` Just src
      fmap (.entry) (Map.lookup (EntryId 3) s.sessionEntries) `shouldBe` Just revised
      fmap (.priority) (Map.lookup (EntryId 3) s.sessionEntries) `shouldBe` Just 3
      fmap (.struck) (Map.lookup (EntryId 3) s.sessionEntries) `shouldBe` Just True
      fmap (.struck) (Map.lookup (EntryId 3) (apply s (EntryRestored (EntryId 3))).sessionEntries) `shouldBe` Just False
    it "records divergence, latest placements, wrap-up and outputs" $ do
      let out = Outputs "tree" "draft" "final"
          s = live [DivergenceSet 0.8, NodePlaced (NodeId 4) (Vec2 1 2) 0,
                    NodePlaced (NodeId 4) (Vec2 3 4) 0.5,
                    SourcePlaced (SourceId 2) (Vec2 5 6) (-0.2), WrappedUp, OutputsReady out]
      s.sessionDivergence `shouldBe` 0.8
      Map.lookup (NodeId 4) s.sessionNodePlacements `shouldBe` Just (Placement (Vec2 3 4) 0.5)
      Map.lookup (SourceId 2) s.sessionSourcePlacements `shouldBe` Just (Placement (Vec2 5 6) (-0.2))
      s.sessionWrapped `shouldBe` True
      s.sessionOutputs `shouldBe` Just out
    it "never lowers candidate high-water marks when older IDs arrive" $ do
      let s = live [CloudSpawned En [Candidate (CandidateId 80) "cloud"], root,
                    CandidateStreamed (NodeId 1) (Candidate (CandidateId 100) "stream"),
                    BranchesOffered (NodeId 1) [Candidate (CandidateId 7) "seal"]]
      s.sessionNextCandidateId `shouldBe` CandidateId 101
    it "replays newest-first logs in chronological order" $ property $ \(words' :: [Int]) ->
      let es = zipWith (\i w -> NodeChosen (NodeId i) (if i == 1 then Nothing else Just (NodeId (i - 1)))
                                (wordKey (fromStringInt w)) Insert Nothing) [1 ..] words'
       in replay (Log (reverse (stamps es))) == live es
  describe "fixture replay" $
    forM_ [("exploration.jsonl", 6, 5, 55, True), ("sources-heavy.jsonl", 4, 8, 33, False)] $
      \(name, nodes, sources, nextCandidate, wrapped) ->
        it ("decodes and replays " <> name <> " including every prefix") $ do
          ls <- filter (not . BS.null) . BS.lines <$> BS.readFile ("../protocol/fixtures/" <> name)
          case traverse (eitherDecodeStrict @Stamped) ls of
            Left err -> expectationFailure err
            Right chronological -> do
              let s = replay (Log (reverse chronological))
              Map.size s.sessionNodes `shouldBe` nodes
              Map.size s.sessionSources `shouldBe` sources
              s.sessionNextCandidateId `shouldBe` CandidateId nextCandidate
              s.sessionWrapped `shouldBe` wrapped
              forM_ [0 .. length chronological] $ \n -> do
                let prefix = take n chronological
                replay (Log (reverse prefix)) `shouldBe` foldl' applyStamped emptySession prefix

fromStringInt :: Int -> Data.Text.Text
fromStringInt = Data.Text.pack . show
