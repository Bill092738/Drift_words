{-# LANGUAGE OverloadedRecordDot #-}

-- | CSL-JSON for the sources. References come from retrieved metadata only,
-- never from model text (TECH_ROADMAP.md, invariant 6). The frontend previews
-- them with @reference.ts@ and the final outputs render them with citeproc, so
-- the shape here is the CSL-JSON schema: @article-journal@, @author@ as
-- family/given or literal, @issued@ as @date-parts@, and so on.
module Drift.Sources.Csl
  ( normalizeCrossrefCsl
  , crossrefType
  , openAlexType
  , splitPersonName
  , cslObject
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (catMaybes, mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Drift.Search.Text (doiUrl, normalizeDoi)

-- | Builds a CSL object from the fields that are present.
cslObject :: [(Key, Maybe Value)] -> Value
cslObject fields = Object (KM.fromList [(k, v) | (k, Just v) <- fields])

-- | The CSL item type for a Crossref work type.
crossrefType :: Text -> Text
crossrefType = \case
  "journal-article" -> "article-journal"
  "proceedings-article" -> "paper-conference"
  "book-chapter" -> "chapter"
  "reference-entry" -> "entry-encyclopedia"
  "posted-content" -> "article"
  "dissertation" -> "thesis"
  "monograph" -> "book"
  "edited-book" -> "book"
  "book" -> "book"
  "report" -> "report"
  "dataset" -> "dataset"
  _ -> "article"

-- | The CSL item type for an OpenAlex work type.
openAlexType :: Text -> Text
openAlexType = \case
  "article" -> "article-journal"
  "review" -> "article-journal"
  "conference-paper" -> "paper-conference"
  "book-chapter" -> "chapter"
  "book" -> "book"
  "dissertation" -> "thesis"
  "preprint" -> "article"
  "dataset" -> "dataset"
  "report" -> "report"
  _ -> "article"

-- | Splits a display name into family and given names by taking the last word
-- as the family name. This is only right for many Western names, so it is used
-- when the DOI's own metadata is unavailable; one-word names stay literal.
splitPersonName :: Text -> Value
splitPersonName name = case T.words name of
  [] -> object ["literal" .= name]
  [single] -> object ["literal" .= single]
  ws -> object ["family" .= last ws, "given" .= T.unwords (init ws)]

-- | Cleans the JSON that doi.org returns for @Accept: application/vnd.citationstyles.csl+json@.
-- That response is Crossref's own format (type @journal-article@, an old
-- @dx.doi.org@ URL, @publisher-location@ and @edition-number@ instead of the
-- CSL names, indexing and license data), so it is cut down to the CSL fields a
-- reference needs, including the editor, edition and place that book and
-- chapter references use. Nothing is invented: a missing field stays missing.
-- Returns Nothing when there is no title to cite.
normalizeCrossrefCsl :: Value -> Maybe Value
normalizeCrossrefCsl = \case
  Object o -> do
    title <- textField "title" o
    let doi = textField "DOI" o >>= normalizeDoi
    pure . cslObject $
      [ ("type", Just (String (maybe "article" crossrefType (textField "type" o))))
      , ("title", Just (String title))
      , ("author", people "author" o)
      , ("editor", people "editor" o)
      , ("container-title", String <$> textField "container-title" o)
      , ("edition", String <$> (textOrNumber "edition" o <|> textOrNumber "edition-number" o))
      , ("volume", String <$> textField "volume" o)
      , ("issue", String <$> textField "issue" o)
      , ("page", String <$> textField "page" o)
      , ("publisher", String <$> textField "publisher" o)
      , ("publisher-place", String <$> (textField "publisher-place" o <|> textField "publisher-location" o))
      , ("DOI", String <$> doi)
      , ("URL", String . doiUrl <$> doi)
      , ("issued", issued o)
      ]
  _ -> Nothing

-- | Like 'textField', but a JSON number is also accepted. Crossref sends
-- @edition-number@ as a string; other registries may not.
textOrNumber :: Key -> KM.KeyMap Value -> Maybe Text
textOrNumber k o = case KM.lookup k o of
  Just (Number n) -> Just $ case floatingOrInteger n :: Either Double Int of
    Right i -> T.pack (show i)
    Left d -> T.pack (show d)
  _ -> textField k o

-- | A text field, whether the source gave a string or a list of strings
-- (Crossref sometimes does, for titles and journal names).
textField :: Key -> KM.KeyMap Value -> Maybe Text
textField k o = case KM.lookup k o of
  Just (String t) | not (T.null (T.strip t)) -> Just (T.strip t)
  Just (Array a) -> case [t | String t <- V.toList a, not (T.null (T.strip t))] of
    t : _ -> Just (T.strip t)
    [] -> Nothing
  _ -> Nothing

-- | A list of names (@author@ or @editor@) as CSL names: family and given, or
-- a literal for an organisation. Affiliations, ORCIDs and roles are dropped.
people :: Key -> KM.KeyMap Value -> Maybe Value
people key o = case KM.lookup key o of
  Just (Array a) -> case mapMaybe person (V.toList a) of
    [] -> Nothing
    ps -> Just (Array (V.fromList ps))
  _ -> Nothing
  where
    person = \case
      Object p -> case (textField "family" p, textField "given" p, textField "name" p, textField "literal" p) of
        (Just family, given, _, _) -> Just (cslObject [("family", Just (String family)), ("given", String <$> given)])
        (Nothing, _, Just name, _) -> Just (object ["literal" .= name])
        (Nothing, _, Nothing, Just lit) -> Just (object ["literal" .= lit])
        _ -> Nothing
      _ -> Nothing

-- | @issued@, or the first publication date that exists, kept to its
-- @date-parts@ numbers.
issued :: KM.KeyMap Value -> Maybe Value
issued o = case catMaybes [dateParts =<< KM.lookup k o | k <- ["issued", "published-print", "published-online", "published"]] of
  parts : _ -> Just (object ["date-parts" .= [parts]])
  [] -> Nothing
  where
    dateParts = \case
      Object d -> case KM.lookup "date-parts" d of
        Just (Array outer) | Just (Array inner) <- outer V.!? 0 -> case mapMaybe whole (V.toList inner) of
          [] -> Nothing
          ns -> Just ns
        _ -> Nothing
      _ -> Nothing
    whole = \case
      Number n -> case floatingOrInteger n :: Either Double Int of
        Right i -> Just i
        Left _ -> Nothing
      _ -> Nothing
