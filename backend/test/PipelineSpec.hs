{-# LANGUAGE OverloadedRecordDot #-}

module PipelineSpec (spec) where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), decode, encode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Drift.Pipeline.Sources
import Drift.Protocol (Event (SourceFound), Lang (En), NodeId (NodeId), SourceId (SourceId), SourceKind (..))
import Drift.Search.Http (Fetch (..), FetchError (..), HttpRequest (..), HttpResponse (..))
import Drift.Search.Types (Hit (..), SourceDraft (..), SourceRequest (..), toSource)
import Drift.Sources.Relevance (acceptAll, rejectAll)
import Test.Hspec

ok :: LBS.ByteString -> Either FetchError HttpResponse
ok = Right . HttpResponse 200 []

fixture :: FilePath -> IO LBS.ByteString
fixture name = LBS.readFile ("test/fixtures/" <> name)

-- | A 'Fetch' that answers from saved responses, by host, and records the
-- requests it saw. Nothing here touches the network.
data Canned = Canned
  { wiki :: Either FetchError HttpResponse
  , alex :: Either FetchError HttpResponse
  , doi :: Text -> Either FetchError HttpResponse
  , commonsImages :: Either FetchError HttpResponse
  , commonsAudio :: Either FetchError HttpResponse
  }

fakeFetch :: Canned -> IO (Fetch, IO [Text])
fakeFetch canned = do
  seen <- newIORef []
  let run rq = do
        modifyIORef' seen (rq.reqUrl :)
        pure $ case () of
          _
            | "en.wikipedia.org" `T.isInfixOf` rq.reqUrl -> canned.wiki
            | "api.openalex.org" `T.isInfixOf` rq.reqUrl -> canned.alex
            | "https://doi.org/" `T.isPrefixOf` rq.reqUrl -> canned.doi (T.drop 16 rq.reqUrl)
            | "commons.wikimedia.org" `T.isInfixOf` rq.reqUrl ->
                if any (\(k, v) -> k == "gsrsearch" && "filetype:audio" `T.isPrefixOf` v) rq.reqQuery
                  then canned.commonsAudio
                  else canned.commonsImages
            | otherwise -> Left (Network "unexpected host")
  pure (Fetch run, reverse <$> readIORef seen)

realResponses :: IO Canned
realResponses = do
  w <- fixture "wiki-search-tide-moon.json"
  a <- fixture "openalex-tides-moon-select.json"
  nature <- fixture "doi-csl-10-1038-35015639.json"
  jgr <- fixture "doi-csl-10-1002-2014je004755.json"
  images <- fixture "commons-image-tide-moon.json"
  audio <- fixture "commons-audio-tide.json"
  pure
    Canned
      { wiki = ok w
      , alex = ok a
      , doi = \d -> case d of
          "10.1038/35015639" -> ok nature
          "10.1002/2014je004755" -> ok jgr
          _ -> Left (BadStatus 404)
      , commonsImages = ok images
      , commonsAudio = ok audio
      }

tideToMoon :: SourceRequest
tideToMoon = SourceRequest (Just "tide") "moon" ["tide"] En

collect :: SourceEnv -> SourceRequest -> IO [SourceDraft]
collect env req = do
  out <- newIORef []
  findSources env req (\d -> modifyIORef' out (d :))
  reverse <$> readIORef out

-- | The original pairing (one article, one paper) without the fallback round,
-- so these tests keep their meaning; the kind draw is tested separately.
envWith :: Fetch -> SourceEnv
envWith fetch = (defaultSourceEnv fetch) {envKinds = const [WantWeb, WantPaper], envFallback = False}

draft :: Text -> Text -> SourceDraft
draft u t = SourceDraft WebPage t Nothing u Nothing Nothing

spec :: Spec
spec = describe "Drift.Pipeline.Sources" $ do
  describe "kinds per edge" $ do
    it "searches only the providers for the wanted kinds" $ do
      (fetch, urls) <- realResponses >>= fakeFetch
      found <- collect (envWith fetch) {envKinds = const [WantImage, WantPaper]} tideToMoon
      seen <- urls
      length (filter ("wikipedia.org/w/rest.php" `T.isInfixOf`) seen) `shouldBe` 0
      map (.kind) found `shouldMatchList` [Image, Paper]

    it "fills an empty kind's place from the other kind's passing results" $ do
      -- No tide audio mentions the moon, so the audio place goes to a second image.
      (fetch, _) <- realResponses >>= fakeFetch
      found <- collect (envWith fetch) {envKinds = const [WantAudio, WantImage]} tideToMoon
      map (.kind) found `shouldBe` [Image, Image]

    it "falls back to the other keyless providers, never OpenAlex, when places stay free" $ do
      (fetch, urls) <- realResponses >>= fakeFetch
      found <- collect (envWith fetch) {envKinds = const [WantAudio], envFallback = True} tideToMoon
      seen <- urls
      length found `shouldBe` 2
      filter ("openalex.org" `T.isInfixOf`) seen `shouldBe` []

    it "draws the kinds by default and still finds sources for a real edge" $ do
      (fetch, _) <- realResponses >>= fakeFetch
      found <- collect (defaultSourceEnv fetch) tideToMoon
      length found `shouldBe` 2


  describe "findSources with saved real responses" $ do
    it "emits the best Wikipedia page and the best paper, at most two" $ do
      (fetch, _) <- realResponses >>= fakeFetch
      found <- collect (envWith fetch) tideToMoon
      map (.title) found `shouldMatchList` ["Tide", "Moon, tides and climate"]

    it "replaces the paper's CSL with the exact record from doi.org" $ do
      (fetch, _) <- realResponses >>= fakeFetch
      found <- collect (envWith fetch) tideToMoon
      [Just (Object o)] <- pure [d.csl | d <- found, d.title == "Moon, tides and climate"]
      -- Only the doi.org record carries the publisher; OpenAlex's fields do not.
      KM.lookup "publisher" o `shouldBe` Just (String "Springer Science and Business Media LLC")
      KM.lookup "type" o `shouldBe` Just (String "article-journal")

    it "keeps OpenAlex's own CSL when doi.org has nothing" $ do
      canned <- realResponses
      (fetch, _) <- fakeFetch canned {doi = const (Left (BadStatus 404))}
      found <- collect (envWith fetch) tideToMoon
      [Just (Object o)] <- pure [d.csl | d <- found, d.title == "Moon, tides and climate"]
      KM.lookup "container-title" o `shouldBe` Just (String "Nature")
      KM.lookup "publisher" o `shouldBe` Nothing

    it "makes no DOI requests when asked not to" $ do
      (fetch, urls) <- realResponses >>= fakeFetch
      _ <- collect (envWith fetch) {envResolveCsl = False} tideToMoon
      seen <- urls
      filter ("https://doi.org/" `T.isPrefixOf`) seen `shouldBe` []

    it "searches each provider once, with both words" $ do
      (fetch, urls) <- realResponses >>= fakeFetch
      _ <- collect (envWith fetch) tideToMoon
      seen <- urls
      length (filter ("wikipedia.org" `T.isInfixOf`) seen) `shouldBe` 1
      length (filter ("openalex.org" `T.isInfixOf`) seen) `shouldBe` 1

    it "never exceeds the per-edge limit, and fills free places with the best of the rest" $ do
      canned <- realResponses
      (f1, _) <- fakeFetch canned
      one <- collect (envWith f1) {envMaxPerEdge = 1} tideToMoon
      length one `shouldBe` 1
      (f3, _) <- fakeFetch canned
      three <- collect (envWith f3) {envMaxPerEdge = 3} tideToMoon
      length three `shouldBe` 3
      length (nub (map (.url) three)) `shouldBe` 3

    it "emits nothing when the judge accepts nothing" $ do
      (fetch, _) <- realResponses >>= fakeFetch
      found <- collect (envWith fetch) {envJudge = rejectAll} tideToMoon
      found `shouldBe` []

    it "uses whatever judge it is given" $ do
      (fetch, _) <- realResponses >>= fakeFetch
      found <- collect (envWith fetch) {envJudge = acceptAll, envMaxPerEdge = 5} tideToMoon
      length found `shouldBe` 5

  describe "failures never reach the caller" $ do
    it "skips a failing provider and still delivers from the other" $ do
      canned <- realResponses
      (fetch, _) <- fakeFetch canned {wiki = Left (BadStatus 500)}
      found <- collect (envWith fetch) tideToMoon
      map (.title) found `shouldSatisfy` ("Moon, tides and climate" `elem`)
      map (.title) found `shouldSatisfy` ("Tide" `notElem`)

    it "treats a rate-limited provider as empty" $ do
      canned <- realResponses
      (fetch, _) <- fakeFetch canned {alex = Left (RateLimited 3600)}
      found <- collect (envWith fetch) tideToMoon
      map (.title) found `shouldSatisfy` ("Tide" `elem`)

    it "delivers nothing, and does not throw, when everything fails" $ do
      (fetch, _) <- fakeFetch (Canned (Left Timeout) (Left (Network "down")) (const (Left Timeout)) (Left Timeout) (Left Timeout))
      found <- collect (envWith fetch) tideToMoon
      found `shouldBe` []

    it "survives a malformed body" $ do
      canned <- realResponses
      (fetch, _) <- fakeFetch canned {wiki = ok "<html>oops</html>", alex = ok "{}"}
      found <- collect (envWith fetch) tideToMoon
      found `shouldBe` []

    it "logs what each provider did" $ do
      (fetch, _) <- realResponses >>= fakeFetch
      logged <- newIORef []
      _ <- collect (envWith fetch) {envLog = \l -> modifyIORef' logged (l :)} tideToMoon
      ls <- readIORef logged
      any ("wikipedia: " `T.isPrefixOf`) ls `shouldBe` True
      any ("openalex: " `T.isPrefixOf`) ls `shouldBe` True

  describe "duplicates" $ do
    it "gives percent-encoded DOI resolver URLs the same identity as DOI metadata" $ do
      let encoded = Hit "test" (draft "https://doi.org/10.1234/a%3Fb" "Reference") "" Nothing 0
          metadata = Hit "test" (draft "https://publisher.org/article" "Reference") "" (Just "10.1234/a?b") 0
      dedupeKey encoded `shouldBe` "doi:10.1234/a?b"
      dedupeKey metadata `shouldBe` "doi:10.1234/a?b"
    it "normalizes URL scheme and host while preserving case-sensitive components" $ do
      let hit = Hit "test" (draft "HTTPS://User:Pass@EXAMPLE.ORG/A?Token=Ab#Section" "Reference") "" Nothing 0
      dedupeKey hit `shouldBe` "url:https://User:Pass@example.org/A?Token=Ab#Section"
    it "keeps URL paths that differ only in case distinct" $ do
      let upper = Hit "test" (draft "https://example.org/A" "Reference") "" Nothing 0
          lower = Hit "test" (draft "https://example.org/a" "Reference") "" Nothing 0
      dedupeKey upper `shouldNotBe` dedupeKey lower
    it "drops the same DOI returned twice" $ do
      let work t = "{\"doi\":\"https://doi.org/10.1/abc\",\"title\":\"" <> t <> "\",\"type\":\"article\",\"authorships\":[]}"
          body = LBS.fromStrict (TE.encodeUtf8 ("{\"results\":[" <> work "Moon tide" <> "," <> work "Moon tide (preprint)" <> "]}"))
      canned <- realResponses
      (fetch, _) <- fakeFetch canned {wiki = Left (BadStatus 500), alex = ok body, doi = const (Left (BadStatus 404))}
      found <- collect (envWith fetch) {envMaxPerEdge = 5} tideToMoon
      length found `shouldBe` 1

  describe "the callback" $ do
    it "is called as sources are found, so an exception in it stops the search" $ do
      (fetch, _) <- realResponses >>= fakeFetch
      findSources (envWith fetch) tideToMoon (\_ -> throwIO (userError "stop")) `shouldThrow` anyIOException

  describe "sanitize" $ do
    it "only lets http(s) links through" $ do
      sanitize (draft "javascript:alert(1)" "x") `shouldBe` Nothing
      sanitize (draft "file:///etc/passwd" "x") `shouldBe` Nothing
      fmap (.url) (sanitize (draft "https://example.org" "x")) `shouldBe` Just "https://example.org"
    it "needs a title and limits its length" $ do
      sanitize (draft "https://example.org" "   ") `shouldBe` Nothing
      fmap (T.length . (.title)) (sanitize (draft "https://example.org" (T.replicate 1000 "a"))) `shouldBe` Just 300

  describe "toSource" $ do
    it "produces the wire event the frontend already understands" $ do
      let d = (draft "https://en.wikipedia.org/wiki/Tide" "Tide") {site = Just "Wikipedia"}
          event = SourceFound (toSource (SourceId 7) (NodeId 3) d)
      decode (encode event) `shouldBe` Just event
      (decode (encode event) :: Maybe Value)
        `shouldBe` decode
          "{\"type\":\"SourceFound\",\"source\":{\"sourceId\":7,\"node\":3,\"kind\":\"webPage\",\"title\":\"Tide\",\"site\":\"Wikipedia\",\"url\":\"https://en.wikipedia.org/wiki/Tide\",\"thumbnailUrl\":null,\"csl\":null}}"
