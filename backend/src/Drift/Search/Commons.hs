{-# LANGUAGE OverloadedRecordDot #-}

-- | Image and audio search on Wikimedia Commons through the MediaWiki API
-- (@action=query&generator=search@ over the File namespace). No key needed.
-- Every file carries its licence, kept in the CSL @note@ because Commons
-- licences (CC BY-SA and the like) require attribution.
module Drift.Search.Commons
  ( CommonsMedia (..)
  , searchCommons
  , parseCommons
  , isPronunciationClip
  , minAudioSeconds
  ) where

import Data.Aeson (ToJSON (toJSON), Value, eitherDecode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlpha, isDigit)
import Data.Either (rights)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Protocol (SourceKind (Audio, Image))
import Drift.Search.Http (Fetch (..), FetchError (..), HttpRequest (..), HttpResponse (..))
import Drift.Search.Text (plainText)
import Drift.Search.Types (Hit (..), SourceDraft (..))
import Drift.Sources.Csl (cslObject)

data CommonsMedia = CommonsImages | CommonsAudio
  deriving stock (Eq, Show)

-- | Audio shorter than this is almost always a pronunciation or a sound effect.
minAudioSeconds :: Double
minAudioSeconds = 5

searchCommons :: Fetch -> CommonsMedia -> Text -> Int -> IO (Either FetchError [Hit])
searchCommons fetch media query limit = do
  r <-
    fetch.runFetch
      HttpRequest
        { reqUrl = "https://commons.wikimedia.org/w/api.php"
        , reqQuery =
            [ ("action", "query")
            , ("format", "json")
            , ("generator", "search")
            , ("gsrnamespace", "6")
            , ("gsrlimit", T.pack (show limit))
            , ("gsrsearch", fileType <> " " <> query)
            , ("prop", "imageinfo")
            , ("iiprop", "url|mime|size|extmetadata")
            , ("iiurlwidth", "320")
            , ("iiextmetadatafilter", "LicenseShortName|Artist|ImageDescription|DateTimeOriginal")
            ]
        , reqHeaders = [("Accept", "application/json")]
        }
  pure $ r >>= \resp -> either (Left . Network . ("commons: " <>)) Right (parseCommons resp.respBody)
  where
    fileType = case media of
      CommonsImages -> "filetype:bitmap|drawing"
      CommonsAudio -> "filetype:audio"

-- | Reads the response, best match first. A file that cannot be read, has an
-- unexpected MIME type, or is a short pronunciation clip is skipped. An empty
-- search has no @query@ object at all, which is not an error.
parseCommons :: LBS.ByteString -> Either Text [Hit]
parseCommons body = do
  v <- either (Left . T.pack) Right (eitherDecode body)
  pages <- either (Left . T.pack) Right (parseEither pagesP v)
  let ordered = sortOn fst [(i, p) | p <- Map.elems pages, Right i <- [parseEither indexP p]]
  pure (catMaybes (rights (zipWith (\rank (_, p) -> parseEither (fileP rank) p) [0 ..] ordered)))
  where
    pagesP :: Value -> Parser (Map Text Value)
    pagesP = withObject "response" $ \o -> do
      q <- o .:? "query"
      maybe (pure Map.empty) (withObject "query" (\qo -> fromMaybe Map.empty <$> qo .:? "pages")) q
    indexP :: Value -> Parser Int
    indexP = withObject "page" (\o -> fromMaybe maxBound <$> o .:? "index")

fileP :: Int -> Value -> Parser (Maybe Hit)
fileP rank = withObject "page" $ \o -> do
  fileTitle <- o .: "title"
  infos <- fromMaybe [] <$> (o .:? "imageinfo" :: Parser (Maybe [Value]))
  case infos of
    [] -> pure Nothing
    info : _ -> flip (withObject "imageinfo") info $ \i -> do
      mime <- fromMaybe "" <$> i .:? "mime"
      page <- i .:? "descriptionurl"
      thumb <- i .:? "thumburl"
      duration <- i .:? "duration" :: Parser (Maybe Double)
      meta <- fromMaybe Map.empty <$> (i .:? "extmetadata" :: Parser (Maybe (Map Text Value)))
      let name = displayTitle fileTitle
          metaText key = plainText <$> (Map.lookup key meta >>= metaValue)
          description = fromMaybe "" (metaText "ImageDescription")
          artist = metaText "Artist"
          licence = metaText "LicenseShortName"
          year = metaText "DateTimeOriginal" >>= leadingYear
          kind
            | "image/" `T.isPrefixOf` mime = Just Image
            | "audio/" `T.isPrefixOf` mime || mime == "application/ogg" = Just Audio
            | otherwise = Nothing
          tooShort = maybe False (< minAudioSeconds) duration
      pure $ case (kind, page) of
        (Just k, Just link)
          | not (T.null name)
          , not (k == Audio && (isPronunciationClip name || tooShort)) ->
              Just
                Hit
                  { hitProvider = "commons"
                  , hitDraft =
                      SourceDraft
                        { kind = k
                        , title = name
                        , site = Just "Wikimedia Commons"
                        , url = link
                        , thumbnailUrl = if k == Image then thumb else Nothing
                        , csl =
                            Just $
                              cslObject
                                [ ("type", Just (toJSON (if k == Image then "graphic" else "song" :: Text)))
                                , ("title", Just (toJSON name))
                                , ("author", (\a -> toJSON [object ["literal" .= a]]) <$> nonEmpty artist)
                                , ("issued", (\y -> object ["date-parts" .= [[y]]]) <$> year)
                                , ("container-title", Just (toJSON ("Wikimedia Commons" :: Text)))
                                , ("URL", Just (toJSON link))
                                , ("note", (\l -> toJSON ("License: " <> l)) <$> nonEmpty licence)
                                ]
                        }
                  , hitSnippet = description
                  , hitDoi = Nothing
                  , hitRank = rank
                  }
        _ -> Nothing
  where
    metaValue :: Value -> Maybe Text
    metaValue v = either (const Nothing) Just (parseEither (withObject "meta" (.: "value")) v)
    nonEmpty = \case
      Just t | not (T.null (T.strip t)) -> Just (T.strip t)
      _ -> Nothing

-- | "File:High tide sun moon.png" becomes "High tide sun moon".
displayTitle :: Text -> Text
displayTitle t =
  let bare = fromMaybe t (T.stripPrefix "File:" t)
      (stem, ext) = T.breakOnEnd "." bare
   in T.strip $
        if not (T.null stem) && not (T.null ext) && T.length ext <= 5 && T.all isAlpha ext
          then T.dropEnd 1 stem
          else bare

-- | Pronunciation recordings are named after a language code: "En-us-tide",
-- "De-Tide". Same as @^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?-@, whose optional
-- region group makes it "two or three letters, then a hyphen". Only applied
-- to audio, together with the duration filter.
isPronunciationClip :: Text -> Bool
isPronunciationClip t =
  let (lang, rest) = T.span isAsciiLetter t
   in T.length lang `elem` [2, 3] && "-" `T.isPrefixOf` rest
  where
    isAsciiLetter c = isAlpha c && c < '\x80'

-- | The year at the start of a Commons date ("2014-06-03 10:12", "1898").
leadingYear :: Text -> Maybe Int
leadingYear t =
  let digits = T.takeWhile isDigit (T.strip t)
   in if T.length digits == 4 then Just (read (T.unpack digits)) else Nothing
