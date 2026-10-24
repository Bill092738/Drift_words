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

import Data.Text (Text)
import qualified Data.Text as T
import Drift.Search.Text (stem, tokens)
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
heuristicVerdict :: SourceRequest -> Hit -> Verdict
heuristicVerdict req hit
  | null wanted = Verdict False 0 "no words to look for"
  | inText < length wanted = Verdict False 0 ("missing: " <> T.unwords (filter (`notElem` textWords) wanted))
  | inTitle == 0 = Verdict False 0 "neither word is in the title"
  | otherwise = Verdict True (fromIntegral (2 * inTitle + inText) / fromIntegral (3 * length wanted)) "words found"
  where
    wanted = dedupe (concatMap (map stem . tokens) (maybe [] pure req.fromWord <> [req.toWord]))
    titleWords = map stem (tokens hit.hitDraft.title)
    textWords = map stem (tokens hit.hitSnippet) <> titleWords
    inTitle = length (filter (`elem` titleWords) wanted)
    inText = length (filter (`elem` textWords) wanted)
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
