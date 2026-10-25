{-# LANGUAGE OverloadedRecordDot #-}

module WikipediaSpec (spec) where

import Data.Aeson (Value, decode)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import qualified Data.Text as T
import Drift.Protocol (SourceKind (WebPage))
import Drift.Search.Types (Hit (..), SourceDraft (..))
import Drift.Search.Wikipedia (parseWikipediaSearch)
import Test.Hspec

-- A real response for "tide moon", saved from the live API.
fixture :: IO LBS.ByteString
fixture = LBS.readFile "test/fixtures/wiki-search-tide-moon.json"

spec :: Spec
spec = describe "Drift.Search.Wikipedia" $ do
  it "reads the pages of a real search response, in the provider's order" $ do
    Right hits <- parseWikipediaSearch "en.wikipedia.org" <$> fixture
    map (.hitDraft.title) hits `shouldBe` ["Tide", "Earth tide", "King tide", "Theory of tides", "Tide clock"]
    map (.hitRank) hits `shouldBe` [0 .. 4]

  it "makes a web page source with the CSL the fixtures use" $ do
    Right (tide : _) <- parseWikipediaSearch "en.wikipedia.org" <$> fixture
    tide.hitDraft.kind `shouldBe` WebPage
    tide.hitDraft.site `shouldBe` Just "Wikipedia"
    tide.hitDraft.url `shouldBe` "https://en.wikipedia.org/wiki/Tide"
    tide.hitDraft.thumbnailUrl `shouldSatisfy` maybe False ("https://thumb.wikimedia.org/" `T.isPrefixOf`)
    -- Exactly the CSL of the Tide source in protocol/fixtures/sources-heavy.jsonl.
    (decode "{\"type\":\"entry-encyclopedia\",\"title\":\"Tide\",\"container-title\":\"Wikipedia\",\"URL\":\"https://en.wikipedia.org/wiki/Tide\"}" :: Maybe Value)
      `shouldBe` tide.hitDraft.csl

  it "gives the relevance check plain text, without markup or entities" $ do
    Right hits <- parseWikipediaSearch "en.wikipedia.org" <$> fixture
    mapM_ (\h -> T.unpack h.hitSnippet `shouldNotContain` "<") hits
    mapM_ (\h -> T.unpack h.hitSnippet `shouldNotContain` "&#") hits
    case hits of
      _ : earth : _ -> T.unpack earth.hitSnippet `shouldContain` "solid earth's surface"
      _ -> expectationFailure "expected at least two hits"

  it "percent-encodes page keys in the link" $ do
    let body = "{\"pages\":[{\"key\":\"Caf\\u00e9_(drink)\",\"title\":\"Caf\\u00e9\",\"excerpt\":\"x\",\"description\":null,\"thumbnail\":null}]}"
    Right [h] <- pure (parseWikipediaSearch "en.wikipedia.org" body)
    h.hitDraft.url `shouldBe` "https://en.wikipedia.org/wiki/Caf%C3%A9_%28drink%29"

  it "drops disambiguation pages and skips unreadable ones" $ do
    let body =
          LBS8.pack . concat $
            [ "{\"pages\":["
            , "{\"key\":\"Mercury\",\"title\":\"Mercury\",\"excerpt\":\"Mercury may refer to\",\"description\":\"Topics referred to by the same term\"},"
            , "{\"title\":\"no key\"},"
            , "{\"key\":\"Moon\",\"title\":\"Moon\",\"excerpt\":\"Earth's natural satellite\",\"description\":null}"
            , "]}"
            ]
    fmap (map (.hitDraft.title)) (parseWikipediaSearch "en.wikipedia.org" body) `shouldBe` Right ["Moon"]

  it "reports a body that is not a search response" $ do
    parseWikipediaSearch "en.wikipedia.org" "not json" `shouldSatisfy` isLeft'
    parseWikipediaSearch "en.wikipedia.org" "{\"error\":1}" `shouldSatisfy` isLeft'
  where
    isLeft' = either (const True) (const False)
