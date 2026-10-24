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

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Search.Http (Fetch)
import Drift.Search.OpenAlex (searchOpenAlex)
import Drift.Search.Text (isWebUrl, normalizeKey)
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

-- | Finds up to 'envMaxPerEdge' sources for an edge, calling @emit@ once for
-- each as soon as it is accepted, so sources land one at a time. Returns when
-- the search is finished. It may call @emit@ zero times, which is normal.
-- Network and parse failures are logged and dropped; cancelling the thread
-- cancels the search.
--
-- The best passing source of each provider is emitted first (one article and
-- one paper rather than two of the same kind); free places are filled from the
-- rest, best score first, after both providers have answered.
findSources :: SourceEnv -> SourceRequest -> (SourceDraft -> IO ()) -> IO ()
findSources env req emit = do
  chosen <- newMVar (Chosen 0 Set.empty)
  leftovers <- newIORef []
  concurrently_
    (provider chosen leftovers "wikipedia" (searchWikipedia env.envFetch req.lang query 5))
    (provider chosen leftovers "openalex" (searchOpenAlex env.envFetch env.envOpenAlexKey query 6))
  rest <- readIORef leftovers
  forM_ (sortOn (\(v, h) -> (negate v.score, h.hitRank)) rest) (accept chosen)
  where
    query = queryFor req

    provider chosen leftovers name search = do
      outcome <- safely search
      case outcome of
        Left e -> env.envLog (name <> ": failed: " <> T.pack (show e))
        Right (Left e) -> env.envLog (name <> ": " <> T.pack (show e))
        Right (Right hits) -> do
          judged <- mapM (\h -> (,h) <$> env.envJudge.judge req h) hits
          let passing = sortOn (\(v, h) -> (negate v.score, h.hitRank)) [(v, h) | (v, h) <- judged, v.supports]
          env.envLog (name <> ": " <> T.pack (show (length passing)) <> " of " <> T.pack (show (length hits)) <> " passed")
          case passing of
            [] -> pure ()
            best : others -> do
              accept chosen best
              atomicModifyIORef' leftovers (\xs -> (others <> xs, ()))

    -- Reserve a place under the lock, then do the slow work (the DOI lookup) outside it.
    accept :: MVar Chosen -> (Verdict, Hit) -> IO ()
    accept chosen (_, hit) = case sanitize hit.hitDraft of
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

-- | The identity of a source, for dropping duplicates: its DOI, else its link,
-- else its title.
dedupeKey :: Hit -> Text
dedupeKey h = case h.hitDoi of
  Just d -> "doi:" <> d
  Nothing
    | not (T.null h.hitDraft.url) -> "url:" <> normalizeKey h.hitDraft.url
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
