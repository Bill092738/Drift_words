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
  , WantedKind (..)
  , kindWeights
  , drawKinds
  , edgeSeed
  , queryFor
  , dedupeKey
  , sanitize
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Bits (xor)
import Data.Char (ord)
import Drift.Search.Commons (CommonsMedia (..), searchCommons)
import Drift.Search.Http (Fetch, FetchError)
import Drift.Search.OpenAlex (searchOpenAlex)
import Drift.Search.Text (isWebUrl, normalizeDoi, normalizeKey, normalizeUrl)
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
  , envKinds :: SourceRequest -> [WantedKind]
  -- ^ which kinds of material an edge looks for first; see 'drawKinds'
  , envFallback :: Bool
  -- ^ when the wanted kinds leave places free, also ask the keyless providers
  -- not asked yet (never OpenAlex, whose budget is metered)
  }

-- | The kinds of material an edge can ask for, each served by one provider.
data WantedKind = WantImage | WantWeb | WantPaper | WantAudio
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | How often each kind is drawn. Audio matches least often, so it is rarest.
kindWeights :: [(WantedKind, Double)]
kindWeights = [(WantImage, 0.35), (WantWeb, 0.25), (WantPaper, 0.25), (WantAudio, 0.15)]

-- | Draws @n@ different kinds by weight, without repeats, from a seed. The
-- same seed always gives the same kinds, so tests and replays are stable.
drawKinds :: Int -> Int -> [WantedKind]
drawKinds n seed = go n (lcg seed) kindWeights
  where
    go 0 _ _ = []
    go _ _ [] = []
    go k r pool =
      let total = sum (map snd pool)
          target = fromIntegral (r `mod` 1000000) / 1000000 * total
          pick = pickAt target pool
       in pick : go (k - 1) (lcg r) (filter ((/= pick) . fst) pool)
    pickAt _ [(w, _)] = w
    pickAt t ((w, weight) : rest) = if t < weight then w else pickAt (t - weight) rest
    pickAt _ [] = WantWeb
    lcg x = (x * 1103515245 + 12345) `mod` 2147483648

-- | A stable seed for an edge, from its words (FNV-1a over the path and the
-- two words), so each edge gets its own mix and keeps it across restarts.
edgeSeed :: SourceRequest -> Int
edgeSeed req = fromInteger (T.foldl' step 2166136261 key `mod` 2147483648)
  where
    key = T.intercalate "\x1f" (req.pathWords <> catMaybes [req.fromWord, Just req.toWord])
    step :: Integer -> Char -> Integer
    step h c = ((h `xor` toInteger (ord c)) * 16777619) `mod` 4294967296

defaultSourceEnv :: Fetch -> SourceEnv
defaultSourceEnv fetch =
  SourceEnv
    { envFetch = fetch
    , envJudge = heuristicJudge
    , envOpenAlexKey = Nothing
    , envMaxPerEdge = 2
    , envResolveCsl = True
    , envLog = \_ -> pure ()
    , envKinds = drawKinds 2 . edgeSeed
    , envFallback = True
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
  let wanted = nubKinds (env.envKinds req)
      primary = map providerFor wanted
      -- Keyless providers not asked yet, for an edge whose wanted kinds came up short.
      fallback = [providerFor k | k <- [WantWeb, WantImage, WantAudio], k `notElem` wanted]
  env.envLog ("wanted kinds: " <> T.pack (show wanted))
  searchRound chosen primary
  remaining <- (\c -> env.envMaxPerEdge - c.count) <$> readMVar chosen
  when (env.envFallback && remaining > 0 && not (null fallback)) $ do
    env.envLog "fallback: searching the other free providers"
    searchRound chosen fallback
  where
    query = queryFor req

    nubKinds = foldr (\k acc -> if k `elem` acc then acc else k : acc) []

    providerFor :: WantedKind -> (Text, IO (Either FetchError [Hit]))
    providerFor = \case
      WantWeb -> ("wikipedia", searchWikipedia env.envFetch req.lang query 5)
      WantPaper -> ("openalex", searchOpenAlex env.envFetch env.envOpenAlexKey query 6)
      WantImage -> ("commons images", searchCommons env.envFetch CommonsImages query 6)
      WantAudio -> ("commons audio", searchCommons env.envFetch CommonsAudio query 6)

    -- Asks a set of providers at once. The best passing result of each comes
    -- first (one of each kind rather than two of the same); free places are
    -- then filled from the rest, in 'candidateOrder'.
    searchRound :: MVar Chosen -> [(Text, IO (Either FetchError [Hit]))] -> IO ()
    searchRound chosen providers = do
      free <- (\c -> env.envMaxPerEdge - c.count) <$> readMVar chosen
      let streaming = free >= length providers
      results <- mapConcurrently (provider chosen streaming) (zip [0 ..] providers)
      let bests = [c | c : _ <- results]
          rest = concat [cs | _ : cs <- results]
      unless streaming $ forM_ (sortOn candidateOrder bests) (accept chosen)
      forM_ (sortOn candidateOrder rest) (accept chosen)

    -- Searches and judges one provider, and returns its passing results best
    -- first. When streaming, the best is accepted here, as soon as it is known.
    provider :: MVar Chosen -> Bool -> (Int, (Text, IO (Either FetchError [Hit]))) -> IO [Candidate]
    provider chosen streaming (index, (name, search)) = do
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
dedupeKey h = case (h.hitDoi >>= normalizeDoi) <|> normalizeDoi h.hitDraft.url of
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
