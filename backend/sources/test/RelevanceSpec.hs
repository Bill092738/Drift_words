{-# LANGUAGE OverloadedRecordDot #-}

module RelevanceSpec (spec) where

import Data.Text (Text)
import Drift.Protocol (Lang (En), SourceKind (WebPage))
import Drift.Search.Types (Hit (..), SourceDraft (..), SourceRequest (..))
import Drift.Sources.Relevance
import Test.Hspec

hit :: Text -> Text -> Hit
hit title snippet =
  Hit
    { hitProvider = "test"
    , hitDraft = SourceDraft WebPage title Nothing "https://example.org/x" Nothing Nothing
    , hitSnippet = snippet
    , hitDoi = Nothing
    , hitRank = 0
    }

edge :: Text -> Text -> SourceRequest
edge from to = SourceRequest (Just from) to [from] En

root :: Text -> SourceRequest
root to = SourceRequest Nothing to [] En

spec :: Spec
spec = describe "Drift.Sources.Relevance" $ do
  describe "heuristicVerdict" $ do
    it "accepts a page about one word that explains the other" $ do
      let v = heuristicVerdict (edge "tide" "moon") (hit "Tide" "Tides are the rise and fall of sea level caused by the Moon and the Sun")
      v.supports `shouldBe` True
    it "treats plurals and case as the same word" $
      (heuristicVerdict (edge "Tide" "MOON") (hit "Theory of tides" "the Moons pull")).supports `shouldBe` True
    it "rejects a source that mentions only one of the words" $
      (heuristicVerdict (edge "tide" "moon") (hit "Tide" "Sea level rises and falls")).supports `shouldBe` False
    it "rejects a source that has both words only in the body, not the title" $
      (heuristicVerdict (edge "tide" "moon") (hit "Oceans" "the tide and the moon")).supports `shouldBe` False
    it "rejects when neither word appears" $
      (heuristicVerdict (edge "tide" "moon") (hit "Gravity" "A force of attraction")).supports `shouldBe` False
    it "needs only the new word for a root node" $ do
      (heuristicVerdict (root "gravity") (hit "Gravity" "A force")).supports `shouldBe` True
      (heuristicVerdict (root "gravity") (hit "Tide" "The moon")).supports `shouldBe` False
    it "rejects a request with no words" $
      (heuristicVerdict (root "") (hit "Tide" "x")).supports `shouldBe` False
    it "scores a title match above a body-only match" $ do
      let both = heuristicVerdict (edge "tide" "moon") (hit "Moon and tide" "x")
          one = heuristicVerdict (edge "tide" "moon") (hit "Tide" "the moon")
      both.score `shouldSatisfy` (> one.score)
    it "keeps the score between 0 and 1" $ do
      let v = heuristicVerdict (edge "tide" "moon") (hit "Moon tide" "moon tide")
      v.score `shouldSatisfy` (\s -> s > 0 && s <= 1)

  describe "judges are replaceable" $ do
    it "acceptAll and rejectAll answer without looking" $ do
      a <- acceptAll.judge (edge "a" "b") (hit "x" "y")
      r <- rejectAll.judge (edge "a" "b") (hit "x" "y")
      (a.supports, r.supports) `shouldBe` (True, False)
