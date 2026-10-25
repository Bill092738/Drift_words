{-# LANGUAGE OverloadedRecordDot #-}

-- | Does this source support the connection between two words? The question is
-- behind a replaceable 'RelevanceJudge', so the heuristic used now can be
-- swapped for a model-backed judge later without touching the pipeline.
--
-- A judge answers yes or no with a score. It never produces text that ends up
-- in a reference: citations come from retrieved metadata only.
module Drift.Sources.Relevance
  ( Verdict (..)
  , RelevanceJudge (..)
  , heuristicJudge
  , heuristicVerdict
  , acceptAll
  , rejectAll
  ) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Search.Text (stem, tokens)
import Drift.Protocol (SourceKind (Audio, Image))
import Drift.Search.Types (Hit (..), SourceDraft (..), SourceRequest (..))

data Verdict = Verdict
  { supports :: Bool
  , score :: Double
  -- ^ 0 to 1; used to choose between sources that all pass
  , reason :: Text
  -- ^ for logs and the command line, never shown to the user
  }
  deriving stock (Eq, Show)

newtype RelevanceJudge = RelevanceJudge {judge :: SourceRequest -> Hit -> IO Verdict}

acceptAll, rejectAll :: RelevanceJudge
acceptAll = RelevanceJudge (\_ _ -> pure (Verdict True 0.5 "accept all"))
rejectAll = RelevanceJudge (\_ _ -> pure (Verdict False 0 "reject all"))

heuristicJudge :: RelevanceJudge
heuristicJudge = RelevanceJudge (\req hit -> pure (heuristicVerdict req hit))

-- | Word overlap, no model. Both words of the connection must appear in the
-- title or the provider's text (plurals count as the same word), and at least
-- one must be in the title, so a page that only mentions a word in passing is
-- not enough. A root node has only one word to look for.
--
-- The words above the edge ('pathWords') disambiguate: they never decide
-- whether a source passes, but among sources that pass, one that also
-- mentions the nearest of them scores higher. One that mentions all of them
-- outranks one that has both words in its title but none of the context. On the path
-- "gravity", "apple", "newton", a page that also mentions gravity ranks above
-- the Apple Newton PDA's page, though both still pass. They
-- are not added to the search query, because both providers require every
-- query word to match, which would leave most edges with no results.
heuristicVerdict :: SourceRequest -> Hit -> Verdict
heuristicVerdict req hit
  | null wanted = Verdict False 0 "no words to look for"
  | inText < length wanted = Verdict False 0 ("missing: " <> T.unwords (filter (`notElem` textWords) wanted))
  | inTitle == 0 = Verdict False 0 "neither word is in the title"
  | null context = Verdict True base "words found"
  | otherwise =
      Verdict
        True
        (0.6 * base + 0.4 * fromIntegral inContext / fromIntegral (length context))
        ("words found, " <> T.pack (show inContext) <> " of " <> T.pack (show (length context)) <> " context words")
  where
    wanted = dedupe (concatMap (map stem . tokens) (maybe [] pure req.fromWord <> [req.toWord]))
    -- Commons file names are short; for images and audio the description
    -- plays the part of the title.
    titleText
      | hit.hitDraft.kind `elem` [Image, Audio] = hit.hitDraft.title <> " " <> hit.hitSnippet
      | otherwise = hit.hitDraft.title
    titleWords = map stem (tokens titleText)
    textWords = map stem (tokens hit.hitSnippet) <> titleWords
    inTitle = length (filter (`elem` titleWords) wanted)
    inText = length (filter (`elem` textWords) wanted)
    base = fromIntegral (2 * inTitle + inText) / fromIntegral (3 * length wanted)
    -- The nearest few words above the edge; far ancestors say little about it.
    context = take contextSize (filter (`notElem` wanted) (nub (concatMap (map stem . tokens) (reverse req.pathWords))))
    inContext = length (filter (`elem` textWords) context)
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | How many words above the edge 'heuristicVerdict' reads.
contextSize :: Int
contextSize = 3
