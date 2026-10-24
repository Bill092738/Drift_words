{-# LANGUAGE OverloadedStrings #-}

module Drift.Model.Provider
  ( Embedding
  , GenRequest (..)
  , ModelProvider (..)
  ) where

import Data.Text (Text)

type Embedding = [Double]

data GenRequest = GenRequest
  { genPrompt :: Text
  , genModel :: Text
  , genDivergence :: Double
  , genMaxTokens :: Int
  -- ^ Output token budget, sent to the API as max_tokens / max_output_tokens.
  -- 0 or less means no limit.
  }
  deriving (Eq, Show)

data ModelProvider = ModelProvider
  { providerName :: Text
  , generate :: GenRequest -> (Text -> IO ()) -> IO Text
  , embed :: Maybe ([Text] -> IO [Embedding])
  }
