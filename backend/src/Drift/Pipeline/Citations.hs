-- | Grounded citations in model text.
--
-- Models may cite only by source key, written @[\@src12]@ or
-- @[\@src3; \@src12]@, from a list they are given. Every key is checked against
-- the sources that were actually retrieved; unknown keys are dropped, so no
-- reference can originate from model text alone (TECH_ROADMAP.md section 4.8,
-- invariant 6).
module Drift.Pipeline.Citations
  ( sourceKey
  , parseSourceKey
  , Grounded (..)
  , groundCitations
  , stripCitations
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.List (nub)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Drift.Protocol (SourceId (..))

-- | The key a model uses to cite a source, without the @\@@: @src12@.
sourceKey :: SourceId -> Text
sourceKey (SourceId n) = "src" <> T.pack (show n)

parseSourceKey :: Text -> Maybe SourceId
parseSourceKey key = do
  digits <- T.stripPrefix "src" key
  case TR.decimal digits of
    Right (n, rest) | T.null rest, T.all isDigit digits -> Just (SourceId n)
    _ -> Nothing

data Grounded = Grounded
  { groundedText :: Text
    -- ^ the text with unknown keys removed and known ones normalized
  , groundedCites :: [SourceId]
    -- ^ known sources in order of first citation, without duplicates
  , droppedKeys :: [Text]
    -- ^ keys that matched no retrieved source
  }
  deriving stock (Eq, Show)

-- | Keeps citations of known sources and removes every other citation group.
groundCitations :: Set SourceId -> Text -> Grounded
groundCitations known t =
  let (out, cited, dropped) = scan render known t
   in Grounded out (nub cited) dropped
  where
    render ids = "[" <> T.intercalate "; " (map (("@" <>) . sourceKey) ids) <> "]"

-- | Removes every citation group, for text shown without inline markers (the
-- sidebar shows an entry's 'cites' next to the text instead).
stripCitations :: Text -> Text
stripCitations t = let (out, _, _) = scan (const "") Set.empty t in out

-- | Walks the text, replacing each bracketed citation group. Brackets that do
-- not hold a citation group are left alone.
scan :: ([SourceId] -> Text) -> Set SourceId -> Text -> (Text, [SourceId], [Text])
scan render known = go [] [] []
  where
    go out cited dropped t =
      case T.breakOn "[" t of
        (pre, rest)
          | T.null rest -> finish (pre : out) cited dropped
          | otherwise ->
              let body = T.drop 1 rest
                  (inside, after) = T.breakOn "]" body
               in case citationGroup inside of
                    Just keys | not (T.null after) ->
                      let ids = [i | Just i <- map parseSourceKey keys, i `Set.member` known]
                          bad = [k | k <- keys, maybe True (`Set.notMember` known) (parseSourceKey k)]
                          piece = if null ids then "" else render ids
                          pre' = if T.null piece then T.dropWhileEnd isSpace pre else pre
                       in go (piece : pre' : out) (cited <> ids) (dropped <> bad) (T.drop 1 after)
                    _ -> go ("[" : pre : out) cited dropped body
    finish out cited dropped = (T.concat (reverse out), cited, dropped)

-- | The keys of a group such as @\@src1; \@src2@ or @\@src1, \@src2@.
citationGroup :: Text -> Maybe [Text]
citationGroup inside =
  let items = map T.strip (T.split (\c -> c == ';' || c == ',') inside)
   in traverse key items
  where
    key item = do
      k <- T.stripPrefix "@" item
      if not (T.null k) && T.all (\c -> isAlphaNum c || c `elem` ("_-:." :: String)) k
        then Just k
        else Nothing
