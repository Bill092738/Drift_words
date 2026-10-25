{-# LANGUAGE OverloadedRecordDot #-}

-- | Wikipedia page search through the Wikimedia REST API
-- (@GET \/w\/rest.php\/v1\/search\/page@). Each hit is an encyclopedia page.
module Drift.Search.Wikipedia
  ( searchWikipedia
  , parseWikipediaSearch
  , wikipediaHost
  ) where

import Data.Aeson (Value, eitherDecode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as LBS
import Data.Either (rights)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Drift.Protocol (Lang (..), SourceKind (WebPage))
import Drift.Search.Http (Fetch (..), FetchError (..), HttpRequest (..), HttpResponse (..))
import Drift.Search.Text (plainText)
import Drift.Search.Types (Hit (..), SourceDraft (..))
import Network.HTTP.Types.URI (urlEncode)

-- | The Wikipedia edition for a desk language.
wikipediaHost :: Lang -> Text
wikipediaHost = \case
  En -> "en.wikipedia.org"
  Zh -> "zh.wikipedia.org"

searchWikipedia :: Fetch -> Lang -> Text -> Int -> IO (Either FetchError [Hit])
searchWikipedia fetch lang query limit = do
  let host = wikipediaHost lang
  r <-
    fetch.runFetch
      HttpRequest
        { reqUrl = "https://" <> host <> "/w/rest.php/v1/search/page"
        , reqQuery = [("q", query), ("limit", T.pack (show limit))]
        , reqHeaders = [("Accept", "application/json")]
        }
  pure $ r >>= \resp -> either (Left . Network . ("wikipedia: " <>)) Right (parseWikipediaSearch host resp.respBody)

-- | Reads the search response. A page that cannot be read is skipped rather
-- than failing the whole search; disambiguation pages are dropped because they
-- connect nothing.
parseWikipediaSearch :: Text -> LBS.ByteString -> Either Text [Hit]
parseWikipediaSearch host body = do
  v <- either (Left . T.pack) Right (eitherDecode body)
  pages <- either (Left . T.pack) Right (parseEither pagesP v)
  pure [h | h <- rights (zipWith (\i p -> parseEither (pageP host i) p) [0 ..] pages), not (isDisambiguation h)]
  where
    pagesP :: Value -> Parser [Value]
    pagesP = withObject "search response" (.: "pages")

pageP :: Text -> Int -> Value -> Parser Hit
pageP host rank = withObject "page" $ \o -> do
  key <- o .: "key"
  pageTitle <- plainText <$> o .: "title"
  excerpt <- maybe "" plainText <$> o .:? "excerpt"
  description <- maybe "" plainText <$> o .:? "description"
  thumbnail <- o .:? "thumbnail" >>= maybe (pure Nothing) (withObject "thumbnail" (.:? "url"))
  let pageUrl = "https://" <> host <> "/wiki/" <> TE.decodeUtf8 (urlEncode False (TE.encodeUtf8 key))
      cslItem =
        object
          [ "type" .= ("entry-encyclopedia" :: Text)
          , "title" .= pageTitle
          , "container-title" .= ("Wikipedia" :: Text)
          , "URL" .= pageUrl
          ]
  pure
    Hit
      { hitProvider = "wikipedia"
      , hitDraft =
          SourceDraft
            { kind = WebPage
            , title = pageTitle
            , site = Just "Wikipedia"
            , url = pageUrl
            , thumbnailUrl = absoluteUrl <$> thumbnail
            , csl = Just cslItem
            }
      , hitSnippet = T.unwords (filter (not . T.null) [excerpt, description])
      , hitDoi = Nothing
      , hitRank = rank
      }

-- | The search API gives protocol-relative thumbnail links ("//upload...").
absoluteUrl :: Text -> Text
absoluteUrl u = if "//" `T.isPrefixOf` u then "https:" <> u else u

isDisambiguation :: Hit -> Bool
isDisambiguation h =
  let t = T.toLower h.hitSnippet
   in any (`T.isInfixOf` t) ["disambiguation page", "may refer to", "topics referred to by the same term"]
