{-# LANGUAGE OverloadedRecordDot #-}

-- | Varied source kinds: Commons images and audio, OpenAlex PDFs, Wikipedia
-- thumbnails and the per-edge kind draw. Saved real responses only.
module CommonsSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Drift.Pipeline.Sources (WantedKind (..), drawKinds, edgeSeed)
import Drift.Protocol (Lang (En), SourceKind (..))
import Drift.Search.Commons
import Drift.Search.OpenAlex (isPdfLink, parseOpenAlex)
import Drift.Search.Types (Hit (..), SourceDraft (..), SourceRequest (..))
import Drift.Search.Wikipedia (parseWikipediaSearch)
import Test.Hspec

fixture :: FilePath -> IO LBS.ByteString
fixture name = LBS.readFile ("test/fixtures/" <> name)

spec :: Spec
spec = do
  describe "Commons images" $ do
    it "reads every file as an image with a thumbnail and a licensed graphic CSL item" $ do
      Right hits <- parseCommons <$> fixture "commons-image-tide-moon.json"
      length hits `shouldBe` 6
      map (.hitDraft.kind) hits `shouldSatisfy` all (== Image)
      -- Served with Access-Control-Allow-Origin: *, so the desk can use them as textures.
      map (.hitDraft.thumbnailUrl) hits `shouldSatisfy` all (maybe False (\u -> any (`T.isPrefixOf` u) ["https://thumb.wikimedia.org/", "https://upload.wikimedia.org/"]))
      map (.hitRank) hits `shouldBe` [0 .. 5]
      [differential] <- pure [h | h <- hits, h.hitDraft.title == "Tide moon gravity differential"]
      differential.hitDraft.url `shouldBe` "https://commons.wikimedia.org/wiki/File:Tide_moon_gravity_differential.png"
      differential.hitDraft.site `shouldBe` Just "Wikimedia Commons"
      case differential.hitDraft.csl of
        Just (Object o) -> do
          KM.lookup "type" o `shouldBe` Just (String "graphic")
          KM.lookup "note" o `shouldSatisfy` maybe False (\case String n -> "License: " `T.isPrefixOf` n; _ -> False)
        other -> expectationFailure (show other)

  describe "Commons audio" $ do
    it "drops pronunciation clips and anything under five seconds, and has no thumbnail" $ do
      Right hits <- parseCommons <$> fixture "commons-audio-tide.json"
      map (.hitDraft.title) hits
        `shouldBe` ["Llamada a oración Mezquita Hassan II", "Sounds of Blackpool High Tide Organ - douglasheld"]
      map (.hitDraft.kind) hits `shouldSatisfy` all (== Audio)
      map (.hitDraft.thumbnailUrl) hits `shouldSatisfy` all (== Nothing)

    it "recognizes pronunciation file names" $ do
      map isPronunciationClip ["En-us-tide", "De-Tide", "Fr-mar\x00e9e", "En-us-tide waiter"] `shouldBe` [True, True, True, True]
      map isPronunciationClip ["Sounds of Blackpool", "Tide organ", "E-tide", "Mezquita-1"] `shouldBe` [False, False, False, False]

    it "treats an empty search as no results, not an error" $
      parseCommons "{\"batchcomplete\":\"\"}" `shouldBe` Right []

  describe "OpenAlex PDFs" $ do
    it "marks a work with an open-access PDF as a PDF linking to it, and keeps the DOI" $ do
      Right hits <- parseOpenAlex <$> fixture "openalex-tides-moon-oa.json"
      let pdfs = [h | h <- hits, h.hitDraft.kind == Pdf]
      map (.hitDraft.url) pdfs `shouldBe` ["https://academic.oup.com/gji/article-pdf/70/1/261/2089824/70-1-261.pdf"]
      map (.hitDoi) pdfs `shouldSatisfy` all (/= Nothing)
      length [h | h <- hits, h.hitDraft.kind == Paper] `shouldBe` length hits - 1

    it "tells PDFs from landing pages" $ do
      map isPdfLink
        [ "https://academic.oup.com/gji/article-pdf/70/1/261/70-1-261.pdf"
        , "https://arxiv.org/pdf/1602.03837"
        , "https://example.org/paper.PDF?download=1"
        ]
        `shouldBe` [True, True, True]
      map isPdfLink ["https://hdl.handle.net/10023/123", "https://dc.cod.edu/cgi/viewcontent.cgi?article=1", "ftp://x.org/a.pdf"]
        `shouldBe` [False, False, False]

  describe "Wikipedia thumbnails" $
    it "reads the protocol-relative thumbnail as an https link, and none when absent" $ do
      Right hits <- parseWikipediaSearch "en.wikipedia.org" <$> fixture "wiki-search-tide-moon.json"
      let thumbOf t = [h.hitDraft.thumbnailUrl | h <- hits, h.hitDraft.title == t]
      thumbOf "Tide" `shouldSatisfy` all (maybe False ("https://thumb.wikimedia.org/" `T.isPrefixOf`))
      thumbOf "Earth tide" `shouldBe` [Nothing]

  describe "kind draw" $ do
    it "draws two different kinds, the same ones for the same seed" $ do
      let seeds = [0 .. 499]
      map (drawKinds 2) seeds `shouldBe` map (drawKinds 2) seeds
      map (length . nub . drawKinds 2) seeds `shouldSatisfy` all (== 2)

    it "follows the weights: images most often, audio least" $ do
      let counts = Map.fromListWith (+) [(k, 1 :: Int) | s <- [0 .. 9999], k <- take 1 (drawKinds 2 s)]
          share k = fromIntegral (Map.findWithDefault 0 k counts) / 10000 :: Double
      share WantImage `shouldSatisfy` (\x -> x > 0.30 && x < 0.40)
      share WantAudio `shouldSatisfy` (\x -> x > 0.10 && x < 0.20)

    it "seeds from the edge, so each edge keeps its mix" $ do
      let edge a b = SourceRequest (Just a) b [a] En
      edgeSeed (edge "tide" "moon") `shouldBe` edgeSeed (edge "tide" "moon")
      edgeSeed (edge "tide" "moon") `shouldNotBe` edgeSeed (edge "moon" "tide")
