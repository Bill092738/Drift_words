-- | Cleaning of text that comes from the network. Titles and extracts are
-- untrusted: Wikipedia search results carry markup and HTML entities, and
-- nothing downstream should ever see either.
module Drift.Search.Text
  ( stripHtml
  , decodeEntities
  , plainText
  , normalizeKey
  , tokens
  , stem
  , normalizeDoi
  , isWebUrl
  ) where

import Data.Char (chr, isAlphaNum, isHexDigit, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Normalize (NormalizationMode (NFKC), normalize)
import Numeric (readHex)

-- | Removes every @<...>@ tag. An unclosed @<@ keeps the rest as text.
stripHtml :: Text -> Text
stripHtml = T.concat . go
  where
    go t = case T.breakOn "<" t of
      (before, rest)
        | T.null rest -> [before]
        | otherwise -> case T.breakOn ">" (T.drop 1 rest) of
            (_, after) | T.null after -> [before, rest]
            (_, after) -> before : go (T.drop 1 after)

-- | Decodes the named entities that appear in titles and extracts and every
-- numeric entity. Anything else is left as written.
decodeEntities :: Text -> Text
decodeEntities = T.concat . go
  where
    go t = case T.breakOn "&" t of
      (before, rest)
        | T.null rest -> [before]
        | otherwise ->
            let body = T.drop 1 rest
                (name, after) = T.breakOn ";" (T.take 10 body)
             in case (T.null after, entity name) of
                  (False, Just c) -> before : T.singleton c : go (T.drop (T.length name + 1) body)
                  _ -> before : "&" : go body
    entity name = case T.unpack name of
      "amp" -> Just '&'
      "lt" -> Just '<'
      "gt" -> Just '>'
      "quot" -> Just '"'
      "apos" -> Just '\''
      "nbsp" -> Just ' '
      '#' : 'x' : hex | not (null hex), all isHexDigit hex -> codePoint (fst <$> safeHead (readHex hex))
      '#' : 'X' : hex | not (null hex), all isHexDigit hex -> codePoint (fst <$> safeHead (readHex hex))
      '#' : digits | not (null digits), all (`elem` ['0' .. '9']) digits -> codePoint (Just (read digits))
      _ -> Nothing
    safeHead = \case
      x : _ -> Just x
      [] -> Nothing
    codePoint = \case
      Just n | n > 0, n <= 0x10FFFF, not (n >= 0xD800 && n <= 0xDFFF) -> Just (chr n)
      _ -> Nothing

-- | Tags removed first, then entities decoded (so an encoded @&lt;b&gt;@ stays
-- visible as text), then runs of white space collapsed.
plainText :: Text -> Text
plainText = T.unwords . T.words . decodeEntities . stripHtml

-- | The key for comparing words and titles: NFKC, case folded, trimmed.
normalizeKey :: Text -> Text
normalizeKey = T.strip . T.toCaseFold . normalize NFKC

-- | Lower-case words, split on anything that is not a letter or digit.
tokens :: Text -> [Text]
tokens = filter (not . T.null) . T.split (not . isAlphaNum) . normalizeKey

-- | A deliberately small stemmer: drops a plural "s" (so "tides" matches
-- "tide"). It is a heuristic, not linguistics.
stem :: Text -> Text
stem w
  | T.length w > 3, "s" `T.isSuffixOf` w, not ("ss" `T.isSuffixOf` w) = T.dropEnd 1 w
  | otherwise = w

-- | A DOI without the resolver prefix, lower case, or Nothing if the text is
-- not a DOI. DOIs are case-insensitive, so lower case is the canonical form.
normalizeDoi :: Text -> Maybe Text
normalizeDoi raw =
  let t = T.toLower (T.strip raw)
      stripped = foldr (\p acc -> maybe acc id (T.stripPrefix p acc)) t prefixes
      doi = T.strip stripped
   in if "10." `T.isPrefixOf` doi && T.any (== '/') doi && not (T.any isSpace doi)
        then Just doi
        else Nothing
  where
    prefixes = ["doi:", "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/"]

-- | Only http(s) links go to the desk: a source opens in the browser when the
-- user taps it, and the text came from the network.
isWebUrl :: Text -> Bool
isWebUrl u = any (`T.isPrefixOf` T.toLower u) ["https://", "http://"] && not (T.any isSpace u)
