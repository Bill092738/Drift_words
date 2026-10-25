{-# LANGUAGE OverloadedRecordDot #-}

-- | The three wrap-up outputs from a session's events: what goes into the
-- protocol's 'OutputsReady' (TECH_ROADMAP.md 4.8).
module Drift.Output.Assemble
  ( OutputsGenerator
  , assembleOutputs
  , modelOutputs
  , orElseOutputs
  ) where

import Citeproc (Style)
import Citeproc.CslJson (CslJson)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Text (Text)
import Drift.Output.Cite (apaStyle)
import Drift.Output.Draft (draftMarkdown)
import Drift.Output.Final (FinalDoc (..), Generate, defaultFinalOptions, finalMarkdown)
import Drift.Output.Tree (decisionTreeMarkdown)
import Drift.Protocol (Outputs (..), Stamped (..))

-- | What the session actor calls after wrap-up, with the session's whole log,
-- oldest first.
type OutputsGenerator = [Stamped] -> IO Outputs

-- | Decision tree, draft and final document. The model is optional: without
-- one, or when it fails, the final document is the kept entries' own text.
-- The warnings of the final stage are returned for the caller's log.
assembleOutputs :: Maybe Generate -> Style (CslJson Text) -> [Stamped] -> IO (Outputs, [Text])
assembleOutputs model style evs = do
  final <- finalMarkdown model defaultFinalOptions style evs
  pure
    ( Outputs
        { decisionTree = decisionTreeMarkdown (map (.event) evs)
        , draft = draftMarkdown style evs
        , final = finalText final
        }
    , finalWarnings final
    )

-- | An 'OutputsGenerator' on the embedded APA style, reporting the final stage's
-- warnings through the given logger. Fails with the style's parse error if the
-- style cannot be read, which only a broken build can cause.
-- | Uses the first generator, and the second when the first throws, so a
-- wrap-up still ends with outputs (for example, model-free ones).
-- Cancellation is not caught.
orElseOutputs :: OutputsGenerator -> OutputsGenerator -> OutputsGenerator
orElseOutputs primary fallback evs = do
  r <- try (primary evs)
  case r of
    Right outputs -> pure outputs
    Left (e :: SomeException)
      | Just _ <- fromException @SomeAsyncException e -> throwIO e
      | otherwise -> fallback evs

modelOutputs :: Maybe Generate -> (Text -> IO ()) -> Either Text OutputsGenerator
modelOutputs model logWarning = do
  style <- apaStyle
  pure $ \evs -> do
    (outputs, warnings) <- assembleOutputs model style evs
    mapM_ logWarning warnings
    pure outputs
