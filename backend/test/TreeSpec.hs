{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module TreeSpec (spec) where

import Data.Aeson (decode)
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Output.Tree
import Drift.Protocol (Event (..), NodeId (..), Origin (..), Outputs (..), Stamped (..))
import Test.Hspec

-- | The events of a protocol fixture, oldest first.
fixtureEvents :: FilePath -> IO [Event]
fixtureEvents name = do
  raw <- LBS.readFile ("../protocol/fixtures/" <> name)
  pure [s.event | l <- LBS.lines raw, Just s <- [decode l :: Maybe Stamped]]

chosen :: Int -> Maybe Int -> Text -> Event
chosen n p w = NodeChosen (NodeId n) (NodeId <$> p) w Branch Nothing

back :: Int -> Event
back = NodeRevisited . NodeId

mermaid :: [Event] -> Text
mermaid = renderMermaid . buildTree

spec :: Spec
spec = describe "Drift.Output.Tree" $ do
  describe "against the exploration fixture" $ do
    it "renders exactly the decision tree the fixture ships with" $ do
      evs <- fixtureEvents "exploration.jsonl"
      [expected] <- pure [o.decisionTree | OutputsReady o <- evs]
      decisionTreeMarkdown evs `shouldBe` expected

    it "has one node per choice, and an edge for each one with a parent" $ do
      evs <- fixtureEvents "exploration.jsonl"
      let t = buildTree evs
      length t.nodes `shouldBe` length [() | NodeChosen {} <- evs]
      length t.edges `shouldBe` length (mapMaybe (\case NodeChosen {parent = p} -> p; _ -> Nothing) evs)

    it "marks the branch taken after the backtrack, and only that one" $ do
      evs <- fixtureEvents "exploration.jsonl"
      let t = buildTree evs
      [(e.from, e.to) | e <- t.edges, e.revisited] `shouldBe` [(NodeId 2, NodeId 5)]

  describe "shape of the tree" $ do
    it "shows a single word on its own" $
      mermaid [chosen 1 Nothing "entropy"] `shouldBe` "flowchart TD\n  n1[entropy]"

    it "is an empty chart for an empty session" $
      mermaid [] `shouldBe` "flowchart TD"

    it "labels a node where it first appears" $
      mermaid [chosen 1 Nothing "a", chosen 2 (Just 1) "b", chosen 3 (Just 2) "c"]
        `shouldBe` "flowchart TD\n  n1[a] --> n2[b]\n  n2 --> n3[c]"

    it "draws a fork as a dotted edge once the user went back" $
      mermaid [chosen 1 Nothing "a", chosen 2 (Just 1) "b", back 1, chosen 3 (Just 1) "c"]
        `shouldBe` "flowchart TD\n  n1[a] --> n2[b]\n  n1 -. revisited .-> n3[c]"

    it "forgets a backtrack once the next choice is made" $
      mermaid [chosen 1 Nothing "a", chosen 2 (Just 1) "b", back 1, chosen 3 (Just 1) "c", chosen 4 (Just 3) "d"]
        `shouldBe` "flowchart TD\n  n1[a] --> n2[b]\n  n1 -. revisited .-> n3[c]\n  n3 --> n4[d]"

    it "does not mark a branch when the backtrack went to another word" $
      mermaid [chosen 1 Nothing "a", chosen 2 (Just 1) "b", chosen 3 (Just 2) "c", back 1, back 2, chosen 4 (Just 3) "d"]
        `shouldBe` "flowchart TD\n  n1[a] --> n2[b]\n  n2 --> n3[c]\n  n3 --> n4[d]"

    it "ignores events that do not shape the path" $
      mermaid [chosen 1 Nothing "a", DivergenceSet 0.4, chosen 2 (Just 1) "b", WrappedUp]
        `shouldBe` "flowchart TD\n  n1[a] --> n2[b]"

    it "keeps the order of the choices" $ do
      let t = buildTree [chosen 1 Nothing "a", chosen 2 (Just 1) "b", back 1, chosen 3 (Just 1) "c"]
      map (.word) t.nodes `shouldBe` ["a", "b", "c"]
      map (.to) t.edges `shouldBe` [NodeId 2, NodeId 3]

  describe "mermaidLabel" $ do
    it "keeps plain words and non-ASCII letters as they are" $ do
      mermaidLabel "creativity" `shouldBe` "creativity"
      mermaidLabel "caf\233" `shouldBe` "caf\233"
      mermaidLabel "\28418\27969" `shouldBe` "\28418\27969"
    it "quotes anything Mermaid could read as syntax" $ do
      mermaidLabel "a]b" `shouldBe` "\"a]b\""
      mermaidLabel "say \"hi\"" `shouldBe` "\"say #quot;hi#quot;\""
      mermaidLabel "x --> y" `shouldBe` "\"x --> y\""
      mermaidLabel "End" `shouldBe` "\"End\""
    it "never leaves a raw closing bracket or newline inside an unquoted label" $ do
      let hostile = ["]", "a\nb", "[x]", "\"", "<b>", "end", "a|b", "{x}", "(y)", ""]
      mapM_ (\w -> T.any (== '\n') (mermaidLabel w) `shouldBe` False) hostile
      mapM_ (\w -> if T.any (== ']') w then T.head (mermaidLabel w) `shouldBe` '"' else pure ()) hostile
