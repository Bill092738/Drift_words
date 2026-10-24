{-# LANGUAGE OverloadedRecordDot #-}

-- | drift-branches: generate a ring of branch words for one word, through the
-- same library call the session engine uses ("Drift.Pipeline.BranchService").
-- With --measure it also reports miss and prefetch-hit latency.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM_, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Drift.Model.Config
import Drift.Model.Provider
import Drift.Pipeline.BranchService
import Drift.Pipeline.Branches
import GHC.Clock (getMonotonicTime)
import Options.Applicative
import System.Exit (die)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

data Options = Options
  { optionWord :: Text
  , optionDivergence :: Double
  , optionConfig :: FilePath
  , optionMeasure :: Bool
  }

main :: IO ()
main = do
  options <- execParser parserInfo
  when (isNaN (optionDivergence options) || isInfinite (optionDivergence options) || optionDivergence options < 0 || optionDivergence options > 1) $
    die "--divergence must be finite and between 0 and 1"
  configResult <- loadModelConfig (optionConfig options)
  config <- either (die . T.unpack) pure configResult
  branchConfig <- either (die . show) pure (resolveProvider config BranchesRole)
  embeddingConfig <- either (die . show) pure (resolveOptionalProvider config EmbeddingsRole)
  branchProvider <- createModelProvider branchConfig
  -- Without an embeddings role, selection keeps the model's order (prompt-only).
  embedder <- case embeddingConfig of
    Nothing -> Nothing <$ hPutStrLn stderr "no embeddings role configured: selecting candidates in the model's order"
    Just embeddingProviderConfig -> do
      when (providerKind embeddingProviderConfig == Mock && providerKind branchConfig /= Mock) $
        hPutStrLn stderr "warning: mock embeddings carry no meaning; divergence filtering will be random"
      embed <$> createModelProvider embeddingProviderConfig
  let context = rootContext (optionWord options) (optionDivergence options)
  bracket (newBranchService branchProvider (providerModel branchConfig) embedder) closeBranchService $ \service ->
    if optionMeasure options
      then measure service context
      else branchesFor service Nothing context (const (pure ())) >>= either (die . show) (TIO.putStr . T.unlines)

rootContext :: Text -> Double -> BranchContext
rootContext word divergenceValue =
  BranchContext
    { currentWord = word
    , pathToRoot = [word]
    , divergence = divergenceValue
    , chosenWords = Set.singleton word
    , appearanceCounts = Map.empty
    , branchCount = 5
    }

-- | The context a ring word would have once picked from the root's ring.
childContext :: BranchContext -> [Text] -> Text -> BranchContext
childContext parent ring word =
  parent
    { currentWord = word
    , pathToRoot = parent.pathToRoot <> [word]
    , chosenWords = Set.insert word parent.chosenWords
    , appearanceCounts = Map.fromListWith (+) [(normalizeWord w, 1) | w <- ring]
    }

-- | Runs a request and returns (ms to the first streamed word, ms to the sealed ring, result).
timed :: ((Text -> IO ()) -> IO a) -> IO (Maybe Double, Double, a)
timed run = do
  start <- getMonotonicTime
  first <- newIORef Nothing
  result <- run $ \_ -> readIORef first >>= maybe (getMonotonicTime >>= writeIORef first . Just) (const (pure ()))
  end <- getMonotonicTime
  firstAt <- readIORef first
  pure (fmap (\t -> (t - start) * 1000) firstAt, (end - start) * 1000, result)

-- | TECH_ROADMAP M2 acceptance: latency on a miss and on a prefetch hit.
measure :: BranchService Int -> BranchContext -> IO ()
measure service context = do
  (missFirst, missRing, missResult) <- timed (branchesFor service Nothing context)
  ring <- either (die . show) pure missResult
  report "miss" missFirst missRing ring
  pick <- case ring of
    word : _ -> pure word
    [] -> die "the ring is empty"

  -- Prefetch every ring word, as the session engine does after offering a ring.
  queued <- getMonotonicTime
  forM_ (zip [0 ..] ring) $ \(key, word) -> prefetchBranches service key (childContext context ring word)
  awaitPrefetch service 0
  ready <- getMonotonicTime
  printf "prefetch of \"%s\" was ready %.0f ms after it was queued\n" pick ((ready - queued) * 1000)

  (hitFirst, hitRing, hitResult) <- timed (branchesFor service (Just 0) (childContext context ring pick))
  hitWords <- either (die . show) pure hitResult
  report ("hit, picked \"" <> T.unpack pick <> "\"") hitFirst hitRing hitWords
 where
  report :: String -> Maybe Double -> Double -> [Text] -> IO ()
  report label firstMs ringMs ws =
    printf "%-24s first word %s, ring %.1f ms: %s\n" label (maybe "n/a" (printf "%.1f ms") firstMs :: String) ringMs (T.unpack (T.unwords ws))

parserInfo :: ParserInfo Options
parserInfo = info (optionsParser <**> helper) (fullDesc <> progDesc "Generate semantic branches for a word")

optionsParser :: Parser Options
optionsParser = Options
  <$> (T.pack <$> strArgument (metavar "WORD" <> help "Starting word"))
  <*> option auto (long "divergence" <> short 'd' <> metavar "0..1" <> value 0.5 <> showDefault <> help "Semantic divergence from 0 to 1")
  <*> strOption (long "config" <> metavar "FILE" <> value "config.yaml" <> showDefault <> help "Model provider YAML configuration")
  <*> switch (long "measure" <> help "Also report miss and prefetch-hit latency (TECH_ROADMAP M2 acceptance)")
