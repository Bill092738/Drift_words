{-# LANGUAGE OverloadedStrings #-}

module Drift.Model.Provider
  ( Embedding
  , GenRequest (..)
  , ModelProvider (..)
  , authFailureMarker
  , isAuthFailureMessage
  , readableError
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | Starts every error where a provider rejected the API key. Retrying those
-- cannot help, so callers report them at once.
authFailureMarker :: Text
authFailureMarker = "The model rejected the API key"

isAuthFailureMessage :: Text -> Bool
isAuthFailureMessage = (authFailureMarker `T.isInfixOf`)

-- | An exception's text as a person should read it: the first line only (GHC
-- appends a call-stack backtrace after it), without the @user error (...)@
-- wrapper that 'userError' adds.
readableError :: Text -> Text
readableError raw =
  let firstLine = T.strip (T.takeWhile (/= '\n') (T.replace "\\n" "\n" raw))
      unwrapped = case T.stripPrefix "user error (" firstLine of
        Just rest -> T.dropWhileEnd (== ')') rest
        Nothing -> firstLine
   in T.strip unwrapped

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
