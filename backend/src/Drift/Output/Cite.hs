{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Citations and reference lists, rendered by citeproc from the sources' own
-- CSL-JSON (TECH_ROADMAP.md 4.8). A reference exists only for a source that was
-- really retrieved, and its text comes from that source's metadata, never from
-- model text (invariant 6). The style is APA 7th edition, the same family the
-- frontend previews while the user explores; the style file is embedded.
module Drift.Output.Cite
  ( Rendered (..)
  , apaStyle
  , renderCitations
  , escapeMarkdown
  , escapeInline
  , escapeBlockStart
  ) where

import Citeproc
  ( Citation (..)
  , CitationItem (..)
  , CitationItemType (NormalCite)
  , CiteprocOptions (..)
  , ItemId (..)
  , Reference
  , Result (..)
  , Style
  , citeproc
  , defaultCiteprocOptions
  , parseStyle
  , prettyCiteprocError
  )
import Citeproc.CslJson (CslJson (..))
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import Data.Bifunctor (first)
import Data.FileEmbed (embedFile)
import Data.Functor.Identity (runIdentity)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Drift.Pipeline.Citations (parseSourceKey, sourceKey)
import Drift.Protocol (Source (..), SourceId)

-- | The embedded APA style (data/apa.csl, CC BY-SA 3.0, from
-- citation-style-language/styles). Citeproc embeds the locale files itself.
apaStyle :: Either Text (Style (CslJson Text))
apaStyle =
  first prettyCiteprocError . runIdentity $
    parseStyle (\_ -> pure mempty) (TE.decodeUtf8 $(embedFile "data/apa.csl"))

data Rendered = Rendered
  { citations :: [Text]
  -- ^ one Markdown citation per input group, empty when nothing in the group is known
  , bibliography :: [(SourceId, Text)]
  -- ^ one Markdown reference for each source that is cited, in the style's order
  }
  deriving stock (Eq, Show)

-- | Renders the citation of each group of sources and the reference list of
-- every source cited anywhere. Sources that were not retrieved (not in the map)
-- are dropped from the groups, so nothing unknown is ever cited. All groups go
-- through citeproc together, so the style can disambiguate (for example two
-- works by one author in one year).
renderCitations :: Style (CslJson Text) -> Map SourceId Source -> [[SourceId]] -> Rendered
renderCitations style sources groups =
  Rendered
    { citations = fillBack (map (null . snd) numbered) (map markdown result.resultCitations)
    , bibliography = mapMaybe bibEntry result.resultBibliography
    }
  where
    usable :: Map SourceId (Reference (CslJson Text))
    usable = Map.mapMaybe referenceFor sources

    known g = [i | i <- nub g, i `Map.member` usable]
    numbered = zip [1 :: Int ..] (map known groups)
    -- citeproc lists every reference it is given, so give it only the cited ones:
    -- the reference list is exactly what the text cites.
    refs = Map.restrictKeys usable (Set.fromList (concatMap snd numbered))
    nonEmpty = [(n, g) | (n, g) <- numbered, not (null g)]
    cites =
      [ Citation
          { citationId = Just ("c" <> T.pack (show n))
          , citationResetPosition = False
          , citationNoteNumber = Nothing
          , citationPrefix = Nothing
          , citationSuffix = Nothing
          , citationItems = [CitationItem (ItemId (sourceKey i)) Nothing Nothing NormalCite Nothing Nothing Nothing | i <- g]
          }
      | (n, g) <- nonEmpty
      ]
    result = citeproc defaultCiteprocOptions {linkBibliography = True} style Nothing (Map.elems refs) cites

    -- Empty groups have no citation; the others come back in order.
    fillBack empties rendered = go empties rendered
      where
        go [] _ = []
        go (True : es) rs = "" : go es rs
        go (False : es) (r : rs) = r : go es rs
        go (False : es) [] = "" : go es []

    bibEntry (key, out) = do
      sid <- parseSourceKey key
      pure (sid, markdown out)

-- | The CSL-JSON item for a source, with the id citeproc cites it by. A source
-- whose CSL is missing or unusable still gets a plain reference from its title
-- and link, so a cited source never silently vanishes from the list.
referenceFor :: Source -> Maybe (Reference (CslJson Text))
referenceFor s = decode (withId (fromMaybe fallback (s.csl >>= withTitle))) `orElse` decode (withId fallback)
  where
    -- citeproc accepts almost any object, and would print a reference with no
    -- title as just "(n.d.)."; metadata without a title is not worth citing from.
    withTitle v = case v of
      Object o | Just (String t) <- KM.lookup "title" o, not (T.null (T.strip t)) -> Just v
      _ -> Nothing
    key = sourceKey s.sourceId
    withId = \case
      Object o -> Object (KM.insert "id" (String key) o)
      _ -> object ["id" .= key]
    fallback =
      object
        ( [ "type" .= ("webpage" :: Text)
          , "title" .= s.title
          , "URL" .= s.url
          ]
            <> ["container-title" .= site | Just site <- [s.site]]
        )
    decode v = case A.fromJSON v of
      A.Success r -> Just r
      _ -> Nothing
    orElse a b = maybe b Just a

-- | CSL formatting as Markdown: italics and bold, curly quotes, links as
-- autolinks, and the rest (small caps, sub and superscript, case hints) as
-- plain text. Text is escaped, so a title cannot add markup of its own.
markdown :: CslJson Text -> Text
markdown = \case
  CslText t -> escapeInline t
  CslEmpty -> ""
  CslConcat a b -> markdown a <> markdown b
  CslQuoted x -> "\8220" <> markdown x <> "\8221"
  CslItalic x -> wrap "*" (markdown x)
  CslBold x -> wrap "**" (markdown x)
  CslNormal x -> markdown x
  CslUnderline x -> markdown x
  CslNoDecoration x -> markdown x
  CslSmallCaps x -> markdown x
  CslBaseline x -> markdown x
  CslSup x -> markdown x
  CslSub x -> markdown x
  CslNoCase x -> markdown x
  CslDiv _ x -> markdown x
  CslLink url x
    | isWeb url -> "<" <> url <> ">"
    | otherwise -> markdown x
  where
    isWeb u = any (`T.isPrefixOf` T.toLower u) ["https://", "http://"] && not (T.any (`elem` (" <>" :: String)) u)
    -- An empty run, or one that already ends in a space, must not leave a dangling marker.
    wrap m inner
      | T.null (T.strip inner) = inner
      | otherwise = m <> inner <> m

-- | Backslash-escapes what Markdown would read as markup, and folds line
-- breaks into spaces. Model and web text goes through here before it reaches a
-- document, so it cannot inject headings, links, HTML or emphasis.
escapeMarkdown :: Text -> Text
escapeMarkdown = escapeInline . T.unwords . T.words

-- | Stops a paragraph from being read as a heading, list item or rule by its
-- first characters. Apply it to the start of every paragraph of foreign text.
escapeBlockStart :: Text -> Text
escapeBlockStart t = case T.uncons t of
  Just (c, _) | c `elem` ("#-+=" :: String) -> "\\" <> t
  Just (c, _) | c >= '0' && c <= '9' ->
    let (digits, rest) = T.span (\x -> x >= '0' && x <= '9') t
     in case T.uncons rest of
          Just (p, more) | p == '.' || p == ')' -> digits <> "\\" <> T.singleton p <> more
          _ -> t
  _ -> t

-- | Escapes without touching white space, for the pieces citeproc emits, whose
-- leading and trailing spaces are part of the reference.
escapeInline :: Text -> Text
escapeInline = T.concatMap esc . T.map (\c -> if c == '\n' || c == '\r' then ' ' else c)
  where
    esc c
      | c `elem` ("\\`*_[]<>~|" :: String) = T.pack ['\\', c]
      | otherwise = T.singleton c
