{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (when)
import Data.IORef (newIORef, modifyIORef', readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Drift.Model.Config
import Drift.Model.Provider
import Drift.Model.Scheduler
import Drift.Pipeline.Branches
import Options.Applicative
import System.Exit (die)

data Options = Options
  { optionWord :: Text
  , optionDivergence :: Double
  , optionConfig :: FilePath
  }

main :: IO ()
main = do
  options <- execParser parserInfo
  when (isNaN (optionDivergence options) || isInfinite (optionDivergence options) || optionDivergence options < 0 || optionDivergence options > 1) $
    die "--divergence must be finite and between 0 and 1"
  configResult <- loadModelConfig (optionConfig options)
  config <- either (die . T.unpack) pure configResult
  branchConfig <- either (die . show) pure (resolveProvider config BranchesRole)
  embeddingConfig <- either (die . show) pure (resolveProvider config EmbeddingsRole)
  branchProvider <- createModelProvider branchConfig
  embeddingProvider <- createModelProvider embeddingConfig
  let context = BranchContext
        { currentWord = optionWord options
        , pathToRoot = [optionWord options]
        , divergence = optionDivergence options
        , chosenWords = Set.empty
        , appearanceCounts = Map.empty
        , branchCount = 5
        }
      request = GenRequest (buildBranchPrompt context) (providerModel branchConfig) (optionDivergence options) (context.branchCount * 2)
  streamState <- newIORef (emptyStreamParser, [])
  generatedResult <- bracket newScheduler shutdown $ \scheduler -> do
    job <- submit scheduler P0 $
      generate branchProvider request $ \chunk ->
        modifyIORef' streamState $ \(parser, wordsSoFar) ->
          let (nextParser, complete) = feedCandidateChunk parser chunk
           in (nextParser, wordsSoFar <> complete)
    await job
  generated <- either (die . show) pure generatedResult
  (pendingParser, streamedWords) <- readIORef streamState
  let candidates = filterCandidates context (streamedWords <> finishCandidateStream pendingParser)
  (anchor, rows) <- case embed embeddingProvider of
    Nothing -> pure (Nothing, map (\word -> (word, Nothing)) candidates)
    Just embedTexts -> do
      vectors <- embedTexts (optionWord options : candidates)
      if length vectors == length candidates + 1
        then case vectors of
          anchorVector : candidateVectors -> pure (Just anchorVector, zipWith (\word vector -> (word, Just vector)) candidates candidateVectors)
          [] -> pure (Nothing, map (\word -> (word, Nothing)) candidates)
        else pure (Nothing, map (\word -> (word, Nothing)) candidates)
  when (T.null (T.strip generated)) (die "model returned an empty candidate stream")
  let selected = selectCandidates context.branchCount context.divergence anchor rows
  if null selected
    then die "no candidates remain after filtering and semantic selection"
    else TIO.putStr (T.unlines selected)

parserInfo :: ParserInfo Options
parserInfo = info (optionsParser <**> helper) (fullDesc <> progDesc "Generate semantic branches for a word")

optionsParser :: Parser Options
optionsParser = Options
  <$> (T.pack <$> strArgument (metavar "WORD" <> help "Starting word"))
  <*> option auto (long "divergence" <> short 'd' <> metavar "0..1" <> value 0.5 <> showDefault <> help "Semantic divergence from 0 to 1")
  <*> strOption (long "config" <> metavar "FILE" <> value "config.yaml" <> showDefault <> help "Model provider YAML configuration")

