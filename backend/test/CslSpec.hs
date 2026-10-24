module CslSpec (spec) where

import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromJust)
import Drift.Sources.Csl
import Test.Hspec

-- Real doi.org responses, saved from the live service.
natureDoi, jgrDoi :: IO Value
natureDoi = fromJust . decode <$> LBS.readFile "test/fixtures/doi-csl-10-1038-35015639.json"
jgrDoi = fromJust . decode <$> LBS.readFile "test/fixtures/doi-csl-10-1002-2014je004755.json"

keys :: Value -> [String]
keys (Object o) = map show (KM.keys o)
keys _ = []

json :: LBS.ByteString -> Value
json = fromJust . decode

spec :: Spec
spec = describe "Drift.Sources.Csl" $ do
  describe "normalizeCrossrefCsl on a real doi.org response" $ do
    it "turns Crossref's format into CSL-JSON" $ do
      Just csl <- normalizeCrossrefCsl <$> natureDoi
      csl
        `shouldBe` fromJust
          ( decode
              "{\"type\":\"article-journal\",\"title\":\"Moon, tides and climate\",\
              \\"author\":[{\"family\":\"Wunsch\",\"given\":\"Carl\"}],\
              \\"container-title\":\"Nature\",\"volume\":\"405\",\"issue\":\"6788\",\"page\":\"743-744\",\
              \\"publisher\":\"Springer Science and Business Media LLC\",\
              \\"DOI\":\"10.1038/35015639\",\"URL\":\"https://doi.org/10.1038/35015639\",\
              \\"issued\":{\"date-parts\":[[2000,6]]}}"
          )

    it "drops indexing, license and reference data" $ do
      Just csl <- normalizeCrossrefCsl <$> jgrDoi
      let ks = keys csl
      mapM_ (\k -> ks `shouldNotContain` [k]) ["\"indexed\"", "\"license\"", "\"reference\"", "\"funder\"", "\"abstract\""]

    it "keeps every author's family and given names, and nothing else about them" $ do
      Just (Object o) <- normalizeCrossrefCsl <$> jgrDoi
      KM.lookup "author" o
        `shouldBe` decode
          "[{\"family\":\"Williams\",\"given\":\"James G.\"},{\"family\":\"Boggs\",\"given\":\"Dale. H.\"}]"

    it "uses the https DOI link, not the old dx.doi.org one" $ do
      Just (Object o) <- normalizeCrossrefCsl <$> jgrDoi
      KM.lookup "URL" o `shouldBe` Just (String "https://doi.org/10.1002/2014je004755")

  describe "normalizeCrossrefCsl on odd input" $ do
    it "needs a title" $ do
      normalizeCrossrefCsl (json "{\"type\":\"journal-article\",\"DOI\":\"10.1/x\"}") `shouldBe` Nothing
      normalizeCrossrefCsl (String "x") `shouldBe` Nothing
    it "accepts list-valued titles and journal names" $ do
      Just (Object o) <- pure (normalizeCrossrefCsl (json "{\"title\":[\"A title\"],\"container-title\":[\"A Journal\"]}"))
      KM.lookup "title" o `shouldBe` Just (String "A title")
      KM.lookup "container-title" o `shouldBe` Just (String "A Journal")
    it "turns an organisation author into a literal name" $ do
      Just (Object o) <- pure (normalizeCrossrefCsl (json "{\"title\":\"T\",\"author\":[{\"name\":\"LIGO Scientific Collaboration\"}]}"))
      KM.lookup "author" o `shouldBe` decode "[{\"literal\":\"LIGO Scientific Collaboration\"}]"
    it "falls back to another publication date when issued is missing" $ do
      Just (Object o) <- pure (normalizeCrossrefCsl (json "{\"title\":\"T\",\"published-online\":{\"date-parts\":[[2015,4,15]]}}"))
      KM.lookup "issued" o `shouldBe` decode "{\"date-parts\":[[2015,4,15]]}"
    it "does not invent fields that are missing" $ do
      Just csl <- pure (normalizeCrossrefCsl (json "{\"title\":\"Only a title\"}"))
      keys csl `shouldMatchList` ["\"title\"", "\"type\""]

  describe "type mapping" $ do
    it "maps Crossref types" $ do
      crossrefType "journal-article" `shouldBe` "article-journal"
      crossrefType "proceedings-article" `shouldBe` "paper-conference"
      crossrefType "book-chapter" `shouldBe` "chapter"
      crossrefType "something-new" `shouldBe` "article"
    it "maps OpenAlex types" $ do
      openAlexType "article" `shouldBe` "article-journal"
      openAlexType "preprint" `shouldBe` "article"
      openAlexType "conference-paper" `shouldBe` "paper-conference"

  describe "splitPersonName" $ do
    it "takes the last word as the family name" $
      splitPersonName "Carl Isaac Wunsch" `shouldBe` json "{\"family\":\"Wunsch\",\"given\":\"Carl Isaac\"}"
    it "keeps a single word as a literal name" $
      splitPersonName "Plato" `shouldBe` json "{\"literal\":\"Plato\"}"
