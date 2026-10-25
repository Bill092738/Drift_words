{-# LANGUAGE OverloadedRecordDot #-}

module OpenAlexSpec (spec) where

import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Drift.Protocol (SourceKind (Paper))
import Drift.Search.OpenAlex (abstractFromIndex, parseOpenAlex)
import Drift.Search.Types (Hit (..), SourceDraft (..))
import Test.Hspec

-- A real response for "tides moon" with the fields the pipeline selects.
fixture :: IO LBS.ByteString
fixture = LBS.readFile "test/fixtures/openalex-tides-moon-select.json"

spec :: Spec
spec = describe "Drift.Search.OpenAlex" $ do
  it "keeps only works that can be cited with a DOI" $ do
    Right hits <- parseOpenAlex <$> fixture
    -- Five works came back; two have no DOI.
    map (.hitDoi) hits
      `shouldBe` [Just "10.1038/35015639", Just "10.1109/oceanse.2019.8867251", Just "10.1002/2014je004755"]
    map (.hitRank) hits `shouldBe` [1, 2, 4]

  it "makes paper sources linking to the DOI" $ do
    Right (nature : _) <- parseOpenAlex <$> fixture
    nature.hitDraft.kind `shouldBe` Paper
    nature.hitDraft.title `shouldBe` "Moon, tides and climate"
    nature.hitDraft.site `shouldBe` Just "Nature"
    nature.hitDraft.url `shouldBe` "https://doi.org/10.1038/35015639"

  it "builds CSL-JSON from the fields OpenAlex gave" $ do
    Right (nature : _) <- parseOpenAlex <$> fixture
    case nature.hitDraft.csl of
      Just (Object o) -> do
        KM.lookup "type" o `shouldBe` Just (String "article-journal")
        KM.lookup "container-title" o `shouldBe` Just (String "Nature")
        KM.lookup "volume" o `shouldBe` Just (String "405")
        KM.lookup "issue" o `shouldBe` Just (String "6788")
        KM.lookup "page" o `shouldBe` Just (String "743-744")
        KM.lookup "DOI" o `shouldBe` Just (String "10.1038/35015639")
        KM.lookup "URL" o `shouldBe` Just (String "https://doi.org/10.1038/35015639")
        KM.lookup "issued" o `shouldBe` decode "{\"date-parts\":[[2000]]}"
        KM.lookup "author" o `shouldBe` decode "[{\"family\":\"Wunsch\",\"given\":\"Carl Isaac\"}]"
      other -> expectationFailure ("expected a CSL object, got " <> show other)

  it "maps other work types to CSL types" $ do
    Right (_ : conference : _) <- parseOpenAlex <$> fixture
    case conference.hitDraft.csl of
      Just (Object o) -> KM.lookup "type" o `shouldBe` Just (String "paper-conference")
      other -> expectationFailure ("expected a CSL object, got " <> show other)

  it "rebuilds the abstract in word order for the relevance check" $ do
    Right hits <- parseOpenAlex <$> fixture
    case reverse hits of
      jgr : _ -> do
        T.unpack jgr.hitSnippet `shouldContain` "Tides on the Moon: Theory and determination of dissipation"
        T.unpack jgr.hitSnippet `shouldContain` "Solid body tides on the Moon vary by about"
      [] -> expectationFailure "no hits"
    abstractFromIndex (Map.fromList [("world", [1]), ("Hello", [0]), ("again", [2, 3])])
      `shouldBe` "Hello world again again"

  it "reports a body that is not a works response" $ do
    parseOpenAlex "nope" `shouldSatisfy` either (const True) (const False)
    parseOpenAlex "{\"results\":5}" `shouldSatisfy` either (const True) (const False)
