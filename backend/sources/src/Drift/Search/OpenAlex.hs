{-# LANGUAGE OverloadedRecordDot #-}

-- | Paper search through the OpenAlex works API.
--
-- OpenAlex is free without a key but metered: a keyless client shares a small
-- daily budget (USD 0.10, about 100 searches) with everyone on its IP address,
-- and a free key raises it tenfold. A search costs the same whatever its
-- size, so the pipeline makes at most one per edge and never retries a 429
-- (the HTTP layer stops calling the host until its budget resets).
module Drift.Search.OpenAlex
  ( searchOpenAlex
  , parseOpenAlex
  , abstractFromIndex
  ) where

import Data.Aeson (ToJSON (toJSON), Value, eitherDecode, object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as Key
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as LBS
import Data.Either (rights)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Protocol (SourceKind (Paper))
import Drift.Search.Http (Fetch (..), FetchError (..), HttpRequest (..), HttpResponse (..))
import Drift.Search.Text (doiUrl, normalizeDoi, plainText)
import Drift.Search.Types (Hit (..), SourceDraft (..))
import Drift.Sources.Csl (cslObject, openAlexType, splitPersonName)

-- | One request for up to @limit@ works matching the words in title or
-- abstract. @select@ keeps the response to the fields read below.
searchOpenAlex :: Fetch -> Maybe Text -> Text -> Int -> IO (Either FetchError [Hit])
searchOpenAlex fetch apiKey query limit = do
  r <-
    fetch.runFetch
      HttpRequest
        { reqUrl = "https://api.openalex.org/works"
        , reqQuery =
            [ ("search.title_and_abstract", query)
            , ("per_page", T.pack (show limit))
            , ("select", "id,doi,title,publication_year,type,language,relevance_score,authorships,primary_location,biblio,abstract_inverted_index")
            ]
              <> [("api_key", k) | Just k <- [apiKey]]
        , reqHeaders = [("Accept", "application/json")]
        }
  pure $ r >>= \resp -> either (Left . Network . ("openalex: " <>)) Right (parseOpenAlex resp.respBody)

-- | Reads the response. A work without a usable DOI or title is skipped: a
-- paper that cannot be cited properly is not worth putting on the desk.
parseOpenAlex :: LBS.ByteString -> Either Text [Hit]
parseOpenAlex body = do
  v <- either (Left . T.pack) Right (eitherDecode body)
  works <- either (Left . T.pack) Right (parseEither resultsP v)
  pure (catMaybes (rights (zipWith (\i w -> parseEither (workP i) w) [0 ..] works)))
  where
    resultsP :: Value -> Parser [Value]
    resultsP = withObject "response" (.: "results")

workP :: Int -> Value -> Parser (Maybe Hit)
workP rank = withObject "work" $ \o -> do
  rawDoi <- o .:? "doi"
  rawTitle <- o .:? "title"
  year <- o .:? "publication_year" :: Parser (Maybe Int)
  workType <- o .:? "type"
  authorships <- fromMaybe [] <$> (o .:? "authorships" :: Parser (Maybe [Value]))
  location <- o .:? "primary_location" :: Parser (Maybe Value)
  biblio <- o .:? "biblio" :: Parser (Maybe Value)
  inverted <- o .:? "abstract_inverted_index" :: Parser (Maybe (Map Text [Int]))
  let names = mapMaybe authorName authorships
      journal = location >>= sourceName
      pages = biblio >>= pageRange
      doi = rawDoi >>= normalizeDoi
      cleanTitle = plainText <$> rawTitle
      abstractText = maybe "" abstractFromIndex inverted
  pure $ case (doi, cleanTitle) of
    (Just d, Just t) | not (T.null t) ->
      let link = doiUrl d
          item =
            cslObject
              [ ("type", Just (toJSON (openAlexType (fromMaybe "article" workType))))
              , ("title", Just (toJSON t))
              , ("author", if null names then Nothing else Just (toJSON (map splitPersonName names)))
              , ("container-title", toJSON <$> journal)
              , ("volume", toJSON <$> (biblio >>= field "volume"))
              , ("issue", toJSON <$> (biblio >>= field "issue"))
              , ("page", toJSON <$> pages)
              , ("DOI", Just (toJSON d))
              , ("URL", Just (toJSON link))
              , ("issued", (\y -> object ["date-parts" .= [[y]]]) <$> year)
              ]
       in Just
            Hit
              { hitProvider = "openalex"
              , hitDraft =
                  SourceDraft
                    { kind = Paper
                    , title = t
                    , site = journal
                    , url = link
                    , thumbnailUrl = Nothing
                    , csl = Just item
                    }
              , hitSnippet = T.unwords (filter (not . T.null) [t, abstractText])
              , hitDoi = Just d
              , hitRank = rank
              }
    _ -> Nothing

authorName :: Value -> Maybe Text
authorName v = case parseEither (withObject "authorship" (\o -> o .: "author" >>= withObject "author" (.: "display_name"))) v of
  Right n | not (T.null (T.strip n)) -> Just (T.strip n)
  _ -> Nothing

sourceName :: Value -> Maybe Text
sourceName v = case parseEither (withObject "location" (\o -> o .: "source" >>= withObject "source" (.: "display_name"))) v of
  Right n | not (T.null (T.strip n)) -> Just (T.strip n)
  _ -> Nothing

-- | A biblio field as text. OpenAlex sends numbers as strings.
field :: Text -> Value -> Maybe Text
field name v = case parseEither (withObject "biblio" (\o -> o .:? Key.fromText name)) v of
  Right (Just t) | not (T.null t) -> Just t
  _ -> Nothing

pageRange :: Value -> Maybe Text
pageRange v = case (field "first_page" v, field "last_page" v) of
  (Just a, Just b) | a /= b -> Just (a <> "-" <> b)
  (Just a, _) -> Just a
  _ -> Nothing

-- | OpenAlex stores an abstract as word to positions; this puts the words
-- back in order. Capped, because only the start is needed for relevance.
abstractFromIndex :: Map Text [Int] -> Text
abstractFromIndex idx =
  T.take 1500 . T.unwords . map snd . sortOn fst $
    [(p, w) | (w, ps) <- Map.toList idx, p <- ps]
