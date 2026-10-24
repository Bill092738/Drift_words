{-# LANGUAGE OverloadedRecordDot #-}

module CiteSpec (spec) where

import Citeproc (Style)
import Citeproc.CslJson (CslJson)
import Data.Aeson (Value, decode)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Output.Cite
import Drift.Protocol (NodeId (..), Source (..), SourceId (..), SourceKind (..))
import Test.Hspec

-- Normalized CSL-JSON of two real papers (the form the sources package produces).
csl :: FilePath -> IO Value
csl name = fromJust . decode <$> LBS.readFile ("test/fixtures/" <> name)

paper :: Int -> Text -> Maybe Value -> Source
paper n title c = Source (SourceId n) (NodeId 2) Paper title (Just "Journal") ("https://doi.org/10.1/x" <> T.pack (show n)) Nothing c

style' :: IO (Style (CslJson Text))
style' = either (\e -> fail ("APA style does not parse: " <> T.unpack e)) pure apaStyle

nature, jgr :: IO Source
nature = paper 1 "Moon, tides and climate" . Just <$> csl "csl-nature.json"
jgr = paper 2 "Tides on the Moon: Theory and determination of dissipation" . Just <$> csl "csl-jgr.json"

spec :: Spec
spec = describe "Drift.Output.Cite" $ do
  it "parses the embedded APA style" $ do
    _ <- style'
    pure ()

  describe "renderCitations" $ do
    it "formats a journal article in APA" $ do
      st <- style'
      n <- nature
      let r = renderCitations st (Map.fromList [(SourceId 1, n)]) [[SourceId 1]]
      r.citations `shouldBe` ["(Wunsch, 2000)"]
      map snd r.bibliography
        `shouldBe` ["Wunsch, C. (2000). Moon, tides and climate. *Nature*, *405*(6788), 743\8211\&744. <https://doi.org/10.1038/35015639>"]

    it "groups several sources in one citation, in the style's order" $ do
      st <- style'
      n <- nature
      j <- jgr
      let r = renderCitations st (Map.fromList [(SourceId 1, n), (SourceId 2, j)]) [[SourceId 2, SourceId 1]]
      -- APA sorts the sources of one citation alphabetically, whatever order they were given in.
      r.citations `shouldBe` ["(Williams & Boggs, 2015; Wunsch, 2000)"]

    it "lists each cited source once, however often it is cited" $ do
      st <- style'
      n <- nature
      j <- jgr
      let r = renderCitations st (Map.fromList [(SourceId 1, n), (SourceId 2, j)]) [[SourceId 1], [SourceId 2, SourceId 1], [SourceId 1]]
      map fst r.bibliography `shouldMatchList` [SourceId 1, SourceId 2]
      length r.citations `shouldBe` 3

    it "never cites a source that was not retrieved" $ do
      st <- style'
      n <- nature
      let r = renderCitations st (Map.fromList [(SourceId 1, n)]) [[SourceId 99], [SourceId 1, SourceId 99], []]
      r.citations `shouldBe` ["", "(Wunsch, 2000)", ""]
      map fst r.bibliography `shouldBe` [SourceId 1]

    it "has no references when nothing is cited" $ do
      st <- style'
      n <- nature
      let r = renderCitations st (Map.fromList [(SourceId 1, n)]) [[], []]
      r.citations `shouldBe` ["", ""]
      r.bibliography `shouldBe` []

    it "orders the reference list by the style, not by citation order" $ do
      st <- style'
      n <- nature
      j <- jgr
      let r = renderCitations st (Map.fromList [(SourceId 1, n), (SourceId 2, j)]) [[SourceId 2], [SourceId 1]]
      map fst r.bibliography `shouldBe` [SourceId 2, SourceId 1] -- Williams before Wunsch

    it "still references a source that has no usable CSL" $ do
      st <- style'
      let plain = paper 3 "A page without metadata" Nothing
          bad = paper 4 "Broken metadata" (Just (fromJust (decode "{\"type\":42}")))
          r = renderCitations st (Map.fromList [(SourceId 3, plain), (SourceId 4, bad)]) [[SourceId 3], [SourceId 4]]
      map fst r.bibliography `shouldMatchList` [SourceId 3, SourceId 4]
      case map snd r.bibliography of
        [a, b] -> do
          T.unpack a `shouldContain` "A page without metadata"
          T.unpack a `shouldContain` "https://doi.org/10.1/x3"
          T.unpack b `shouldContain` "Broken metadata"
          T.unpack b `shouldContain` "https://doi.org/10.1/x4"
        other -> expectationFailure ("expected two references, got " <> show other)

    it "keeps markup in titles from becoming markup in the document" $ do
      st <- style'
      let s = paper 5 "x" (Just (fromJust (decode "{\"type\":\"article-journal\",\"title\":\"A *bold* [claim](http://evil.example) <b>x</b>\",\"issued\":{\"date-parts\":[[2020]]}}")))
          r = renderCitations st (Map.fromList [(SourceId 5, s)]) [[SourceId 5]]
      case r.bibliography of
        [(_, t)] -> do
          -- No raw HTML and no live link: the brackets and asterisks are escaped.
          T.unpack t `shouldNotContain` "<b>"
          T.unpack t `shouldNotContain` "[claim]"
          T.unpack t `shouldContain` "\\[claim\\]"
          T.unpack t `shouldContain` "\\*bold\\*"
        other -> expectationFailure ("expected one reference, got " <> show other)

  describe "escapeMarkdown" $ do
    it "escapes markup and folds line breaks" $ do
      escapeMarkdown "a *b* _c_ [d] <e> `f` ~g~ | h" `shouldBe` "a \\*b\\* \\_c\\_ \\[d\\] \\<e\\> \\`f\\` \\~g\\~ \\| h"
      escapeMarkdown "line one\nline   two" `shouldBe` "line one line two"
    it "leaves ordinary text alone" $
      escapeMarkdown "Entropy measures information (Shannon, 1948)." `shouldBe` "Entropy measures information (Shannon, 1948)."
