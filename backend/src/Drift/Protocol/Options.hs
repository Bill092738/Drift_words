-- | aeson options for the wire protocol. A separate module because Template
-- Haskell splices in "Drift.Protocol" can only use imported definitions.
module Drift.Protocol.Options
  ( wireOptions
  , enumOptions
  ) where

import Data.Aeson.TH (Options (..), SumEncoding (..), defaultOptions)
import Data.Char (toLower)

lowerFirst :: String -> String
lowerFirst = \case
  c : cs -> toLower c : cs
  [] -> []

-- | Every sum type is an object tagged with a @"type"@ field; record fields
-- keep their Haskell names; 'Nothing' encodes as @null@.
wireOptions :: Options
wireOptions =
  defaultOptions
    { sumEncoding = TaggedObject {tagFieldName = "type", contentsFieldName = "contents"}
    , omitNothingFields = False
    , allNullaryToStringTag = False
    }

-- | Enum-like types encode as camelCase strings (@"en"@, @"webPage"@, ...).
enumOptions :: Options
enumOptions = wireOptions {allNullaryToStringTag = True, constructorTagModifier = lowerFirst}
