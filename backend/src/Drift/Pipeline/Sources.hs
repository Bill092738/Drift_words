{-# LANGUAGE OverloadedRecordDot #-}

-- | The source pipeline for one edge of the word tree (TECH_ROADMAP.md 4.7):
-- search, check relevance, make the CSL-JSON exact, drop duplicates, and hand
-- each accepted source to the caller as it is found.
--
-- It knows nothing about sessions or the model scheduler. The caller gets
-- 'SourceDraft's through a callback and turns each into a @SourceFound@ event
-- with "Drift.Search.Types".'toSource'.
module Drift.Pipeline.Sources
  ( SourceEnv (..)
  , defaultSourceEnv
  , findSources
  , queryFor
  , dedupeKey
  , sanitize
  ) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Search.Http (Fetch, FetchError)
import Drift.Search.OpenAlex (searchOpenAlex)
import Drift.Search.Text (isWebUrl, normalizeKey, normalizeUrl)
import Drift.Search.Types (Hit (..), SourceDraft (..), SourceRequest (..))
import Drift.Search.Wikipedia (searchWikipedia)
import Drift.Sources.Doi (fetchCsl)
import Drift.Sources.Relevance (RelevanceJudge (..), Verdict (..), heuristicJudge)

data SourceEnv = SourceEnv
  { envFetch :: Fetch
  , envJudge :: RelevanceJudge
  , envOpenAlexKey :: Maybe Text
  -- ^ optional free OpenAlex key; raises the daily budget tenfold
  , envMaxPerEdge :: Int
  -- ^ not every connection needs many sources; fewer is better
  , envResolveCsl :: Bool
  -- ^ fetch exact CSL-JSON from doi.org for papers, falling back to OpenAlex's fields
  , envLog :: Text -> IO ()
  }

defaultSourceEnv :: Fetch -> SourceEnv
defaultSourceEnv fetch =
  SourceEnv
    { envFetch = fetch
    , envJudge = heuristicJudge
    , envOpenAlexKey = Nothing
    , envMaxPerEdge = 2
    , envResolveCsl = True
    , envLog = \_ -> pure ()
    }

-- | The words searched for: the parent word and the new word together.
queryFor :: SourceRequest -> Text
queryFor req = T.unwords (catMaybes [req.fromWord, Just req.toWord])

data Chosen = Chosen
  { count :: Int
  , seen :: Set.Set Text
  }

-- | A result that passed the relevance check, with the position of its
-- provider in the provider list, used to break ties.
data Candidate = Candidate
  { verdict :: Verdict
  , providerIndex :: Int
  , candidateHit :: Hit
  }

-- | Best score first, then the provider's own ranking, then provider order,
-- so the order never depends on which provider answered first.
candidateOrder :: Candidate -> (Double, Int, Int)
candidateOrder c = (negate c.verdict.score, c.candidateHit.hitRank, c.providerIndex)

-- | Finds up to 'envMaxPerEdge' sources for an edge, calling @emit@ once for
-- each as soon as it is accepted, so sources land one at a time. Returns when
-- the search is finished. It may call @emit@ zero times, which is normal.
-- Network and parse failures are logged and dropped; cancelling the thread
-- cancels the search.
--
-- The best passing source of each provider comes first (one article and one
-- paper rather than two of the same kind); free places are filled from the
-- rest, in 'candidateOrder', after every provider has answered.
--
-- When there is a place for every provider's best, each best is emitted as
-- soon as its provider answers. When there are fewer places (for example
-- 'envMaxPerEdge' = 1), the bests compete for them, so the pipeline waits for
-- every provider and takes them in 'candidateOrder'. The result is then the
-- same whichever provider answers first.
findSources :: SourceEnv -> SourceRequest -> (SourceDraft -> IO ()) -> IO ()
findSources env req emit = do
  chosen <- newMVar (Chosen 0 Set.empty)
  results <- mapConcurrently (provider chosen) (zip [0 ..] providers)
  let bests = [c | c : _ <- results]
      rest = concat [cs | _ : cs <- results]
  unless streaming $ forM_ (sortOn candidateOrder bests) (accept chosen)
  forM_ (sortOn candidateOrder rest) (accept chosen)
  where
    query = queryFor req

    providers :: [(Text, IO (Either FetchError [Hit]))]
    providers =
      [ ("wikipedia", searchWikipedia env.envFetch req.lang query 5)
      , ("openalex", searchOpenAlex env.envFetch env.envOpenAlexKey query 6)
      ]

    streaming = env.envMaxPerEdge >= length providers

    -- Searches and judges one provider, and returns its passing results best
    -- first. When streaming, the best is accepted here, as soon as it is known.
    provider :: MVar Chosen -> (Int, (Text, IO (Either FetchError [Hit]))) -> IO [Candidate]
    provider chosen (index, (name, search)) = do
      outcome <- safely search
      case outcome of
        Left e -> [] <$ env.envLog (name <> ": failed: " <> T.pack (show e))
        Right (Left e) -> [] <$ env.envLog (name <> ": " <> T.pack (show e))
        Right (Right hits) -> do
          judged <- mapM (\h -> (\v -> Candidate v index h) <$> env.envJudge.judge req h) hits
          let passing = sortOn candidateOrder [c | c <- judged, c.verdict.supports]
          env.envLog (name <> ": " <> T.pack (show (length passing)) <> " of " <> T.pack (show (length hits)) <> " passed")
          case passing of
            best : _ | streaming -> accept chosen best
            _ -> pure ()
          pure passing

    -- Reserve a place under the lock, then do the slow work (the DOI lookup) outside it.
    accept :: MVar Chosen -> Candidate -> IO ()
    accept chosen candidate = case sanitize hit.hitDraft of
      Nothing -> pure ()
      Just draft -> do
        let key = dedupeKey hit
        reserved <- modifyMVar chosen $ \c ->
          if c.count >= env.envMaxPerEdge || key `Set.member` c.seen
            then pure (c, False)
            else pure (Chosen (c.count + 1) (Set.insert key c.seen), True)
        when reserved $ do
          exact <- case hit.hitDoi of
            Just doi | env.envResolveCsl -> fetchCsl env.envFetch doi
            _ -> pure Nothing
          emit (maybe draft (\c -> draft {csl = Just c}) exact)
      where
        hit = candidate.candidateHit

-- | The identity of a source, for dropping duplicates: its DOI, else its link,
-- else its title.
dedupeKey :: Hit -> Text
dedupeKey h = case h.hitDoi of
  Just d -> "doi:" <> d
  Nothing
    | not (T.null h.hitDraft.url) -> "url:" <> normalizeUrl h.hitDraft.url
    | otherwise -> "title:" <> normalizeKey h.hitDraft.title

-- | The last check before a source can reach the desk: a web link and a title.
sanitize :: SourceDraft -> Maybe SourceDraft
sanitize d
  | not (isWebUrl d.url) = Nothing
  | T.null title' = Nothing
  | otherwise = Just d {title = title', site = T.take 120 <$> d.site}
  where
    title' = T.take 300 (T.strip d.title)

safely :: IO a -> IO (Either SomeException a)
safely action = do
  r <- try action
  case r of
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    _ -> pure r
