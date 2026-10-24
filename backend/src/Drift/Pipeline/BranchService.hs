{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeApplications #-}

-- | The whole branch pipeline as one library call for the session engine:
-- build the prompt, stream and parse the model output, filter, embed, select,
-- and reuse speculative prefetches.
--
-- == Wiring it into the session engine (M1/M5)
--
-- * Create one 'BranchService' per server with 'newBranchService', and close
--   it on shutdown.
-- * When the user picks candidate @c@, call @'branchesFor' service (Just c)
--   context onWord@ with the context of the new node. @onWord@ receives each
--   word as soon as it is parsed and passes the filters, at most
--   'branchCount' of them: emit 'CandidateStreamed' for it. The returned list
--   is the sealed ring: emit 'BranchesOffered'. With embeddings configured, the
--   sealed ring can differ from what streamed; clients drop streamed words
--   that are not in the sealed ring.
-- * After offering a ring, call 'prefetchBranches' for each offered candidate,
--   with the context that node would have once picked. When the user picks
--   one, 'branchesFor' with its key cancels the other prefetches and reuses
--   this one. On a backtrack or an inserted word, call 'branchesFor' with
--   'Nothing', which cancels all prefetches.
-- * @onWord@ runs on a scheduler thread: keep it cheap and thread-safe (for
--   example, write to the session actor's inbox).
--
-- Keys are chosen by the caller; 'CandidateId' is the natural one.
module Drift.Pipeline.BranchService
  ( BranchService
  , BranchError (..)
  , RawBranches (..)
  , newBranchService
  , withParallelPrefetch
  , closeBranchService
  , branchesFor
  , prefetchBranches
  , awaitPrefetch
  , finalizeBranches
  , streamFiltered
  ) where

import Control.Exception (SomeException, onException, throwIO, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Model.Provider (GenRequest (..), ModelProvider (..))
import Drift.Model.Scheduler
import Drift.Pipeline.Branches
import Drift.Pipeline.Prefetch

data BranchService k = BranchService
  { serviceProvider :: ModelProvider
  , serviceModel :: Text
  -- ^ Model name for requests; empty means the provider's default.
  , serviceEmbed :: Maybe ([Text] -> IO [Embedding])
  -- ^ Nothing selects in the model's order (prompt-only).
  , serviceScheduler :: Scheduler
  , servicePrefetch :: PrefetchCache k RawBranches
  , serviceParallelPrefetch :: Bool
  -- ^ run prefetches side by side instead of one at a time at P1
  }

data BranchError
  = BranchJobFailed JobError
  | NoCandidates
  -- ^ Nothing survived parsing and filtering.
  deriving stock (Eq, Show)

-- | One generation before filtering, so a prefetched result can be filtered
-- again against the session as it is when the user actually picks.
data RawBranches = RawBranches
  { rawWords :: [Text]
  -- ^ Parsed words in the model's order, unfiltered.
  , rawAnchor :: Maybe Embedding
  -- ^ Embedding of the current word.
  , rawVectors :: Map.Map Text Embedding
  -- ^ Embeddings keyed by 'normalizeWord'.
  }
  deriving stock (Eq, Show)

newBranchService :: ModelProvider -> Text -> Maybe ([Text] -> IO [Embedding]) -> IO (BranchService k)
newBranchService provider model embedder =
  BranchService provider model embedder <$> newScheduler <*> newPrefetchCache <*> pure False

-- | For an endpoint that serves requests in parallel (a hosted API):
-- prefetches no longer queue behind the scheduler's single slot, so the rings
-- of all offered words are ready after one model round trip instead of one
-- per word. A pick that misses still runs at P0 on the scheduler. Cancelling
-- a prefetch still stops its request.
withParallelPrefetch :: BranchService k -> BranchService k
withParallelPrefetch service = service {serviceParallelPrefetch = True}

closeBranchService :: BranchService k -> IO ()
closeBranchService service = do
  shutdownPrefetchCache service.servicePrefetch
  shutdown service.serviceScheduler

-- | The ring for a node the user just picked. Other prefetches are cancelled
-- first (all of them when @key@ is 'Nothing'), so they stop using the model.
-- A prefetched result for @key@ is reused when it succeeds, waiting for it if
-- it is still running (re-filtered against @context@, and each selected word
-- is passed to @onWord@ at once); otherwise the ring is generated at P0,
-- streaming provisional words to @onWord@.
branchesFor :: Ord k => BranchService k -> Maybe k -> BranchContext -> (Text -> IO ()) -> IO (Either BranchError [Text])
branchesFor service key context onWord = do
  maybe (cancelAllPrefetches service.servicePrefetch) (cancelUnselected service.servicePrefetch) key
  prefetched <- maybe (pure Nothing) (takePrefetch service.servicePrefetch) key
  case prefetched of
    Just (Right raw) -> do
      let selected = finalizeBranches context raw
      mapM_ onWord selected
      pure (nonEmpty selected)
    _ -> do
      job <- submit service.serviceScheduler P0 (generateRaw service context onWord)
      result <- await job
      pure $ case result of
        Left err -> Left (BranchJobFailed err)
        Right raw -> nonEmpty (finalizeBranches context raw)
 where
  nonEmpty [] = Left NoCandidates
  nonEmpty xs = Right xs

-- | Speculatively generates, at P1, the ring that @key@ would grow. A P0
-- request preempts it; a preempted prefetch counts as a miss later.
-- Cancelling the prefetch also withdraws its job from the scheduler.
prefetchBranches :: Ord k => BranchService k -> k -> BranchContext -> IO ()
prefetchBranches service key context = do
  _ <- startPrefetch service.servicePrefetch key $
    if service.serviceParallelPrefetch
      then generateRaw service context (const (pure ()))
      else do
        job <- submit service.serviceScheduler P1 (generateRaw service context (const (pure ())))
        result <- await job `onException` cancel job
        either (throwIO . userError . show) pure result
  pure ()

-- | Blocks until the prefetch for @key@ has finished (or was cancelled),
-- without taking it. For measurements and tests.
awaitPrefetch :: Ord k => BranchService k -> k -> IO ()
awaitPrefetch service = waitPrefetch service.servicePrefetch

-- | Filters a generation against the context and selects the ring. Pure, so a
-- prefetched generation costs no model or network time when it is taken.
finalizeBranches :: BranchContext -> RawBranches -> [Text]
finalizeBranches context raw =
  let candidates = filterCandidates context raw.rawWords
      rows = [(w, Map.lookup (normalizeWord w) raw.rawVectors) | w <- candidates]
   in selectCandidates context.branchCount context.divergence raw.rawAnchor rows

-- | Words that newly pass the filters once @parsed@ grew from @before@
-- parsed words to all of @parsed@, capped at the ring size. Filtering is a
-- stable left fold, so earlier results are a prefix of later ones.
streamFiltered :: BranchContext -> [Text] -> [Text] -> [Text]
streamFiltered context before parsed =
  let wanted = context.branchCount
      already = length (take wanted (filterCandidates context before))
   in take (wanted - already) (drop already (filterCandidates context parsed))

generateRaw :: BranchService k -> BranchContext -> (Text -> IO ()) -> IO RawBranches
generateRaw service context onWord = do
  state <- newIORef (emptyStreamParser, [])
  let request =
        GenRequest
          { genPrompt = buildBranchPrompt context
          , genModel = service.serviceModel
          , genDivergence = context.divergence
          , genMaxTokens = branchTokenBudget context.branchCount
          }
      onChunk chunk = do
        fresh <- atomicModifyIORef' state $ \(parser, parsed) ->
          let (parser', complete) = feedCandidateChunk parser chunk
              parsed' = parsed <> complete
           in ((parser', parsed'), streamFiltered context parsed parsed')
        mapM_ onWord fresh
  _ <- service.serviceProvider.generate request onChunk
  (parser, parsed) <- readIORef state
  let final = parsed <> finishCandidateStream parser
  mapM_ onWord (streamFiltered context parsed final)
  (anchor, vectors) <- embedAll service context.currentWord final
  pure (RawBranches final anchor vectors)

-- | Embeds the current word and every distinct parsed word. A failed or
-- malformed embedding call falls back to prompt-only selection instead of
-- failing the ring; asynchronous exceptions (cancellation) still propagate.
embedAll :: BranchService k -> Text -> [Text] -> IO (Maybe Embedding, Map.Map Text Embedding)
embedAll service current parsed = case service.serviceEmbed of
  Nothing -> pure (Nothing, Map.empty)
  Just embedTexts -> do
    let keys = Map.toList (Map.fromListWith (\_ first -> first) [(normalizeWord w, w) | w <- parsed, not (T.null (normalizeWord w))])
        inputs = current : map snd keys
    result <- try @SomeException (embedTexts inputs)
    case result of
      Left e | isAsyncException e -> throwIO e
      Right (anchor : vectors) | length vectors == length keys -> pure (Just anchor, Map.fromList (zip (map fst keys) vectors))
      _ -> pure (Nothing, Map.empty)
