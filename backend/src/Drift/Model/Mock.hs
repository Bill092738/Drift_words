{-# LANGUAGE OverloadedStrings #-}

module Drift.Model.Mock (mockProvider, mockWords) where

import Data.Text (Text)
import qualified Data.Text as T
import Drift.Model.Provider

mockProvider :: ModelProvider
mockProvider = ModelProvider
  { providerName = "mock"
  , generate = mockGenerate
  , embed = Just (pure . map embedWord)
  }

mockGenerate :: GenRequest -> (Text -> IO ()) -> IO Text
mockGenerate request onChunk = do
  let output = T.intercalate "\n" (take (max 1 (genMaxTokens request)) (mockWords (genPrompt request) (genDivergence request)))
      chunks = T.chunksOf 8 output
  mapM_ onChunk chunks
  pure output

mockWords :: Text -> Double -> [Text]
mockWords prompt divergence
  | safeDivergence divergence < 0.5 = ["tide", "wave", "current", "shore", "coral", "harbor", "sail", "reef"]
  | otherwise = ["memory", "boundary", "migration", "gravity", "language", "silence", "network", "time"]
  where
    _seed = T.toCaseFold (T.strip prompt)
    safeDivergence = max 0 . min 1

embedWord :: Text -> Embedding
embedWord word =
  let seed = fromIntegral (T.foldl' (\acc c -> (acc * 33 + fromEnum c) `mod` 2147483647) 5381 word) :: Double
      coordinates = [sin (seed / fromIntegral n) | n <- [1 .. 16 :: Int]]
      norm = sqrt (sum (map (\x -> x * x) coordinates))
   in if norm == 0 then replicate 16 0 else map (/ norm) coordinates
