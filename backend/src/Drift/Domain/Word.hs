module Drift.Domain.Word (wordKey, cap) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Normalize (NormalizationMode (NFKC), normalize)

-- | One identity for typed, offered and visited words. Normalize again after
-- case folding so the resulting key remains in compatibility normal form.
wordKey :: Text -> Text
wordKey = Text.strip . normalize NFKC . Text.toCaseFold . normalize NFKC

-- | Maximum appearances at the current divergence. NaN follows the default
-- policy rather than reaching the partial 'floor' operation.
cap :: Double -> Int
cap d = 3 - floor (2 * clamped)
  where
    clamped = if isNaN d then 0.5 else max 0 (min 1 d)
