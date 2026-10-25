{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The draft: everything in the sidebar, in the order the user walked, with
-- the struck entries crossed out and kept, and the full reference list
-- (idea.md, "Wrapping up and the three outputs"). Sources cited by a struck
-- entry stay in the draft's references.
--
-- Pure and model-free: the text of each entry is whatever the writing pipeline
-- stored, escaped so it cannot add markup, and every citation and reference
-- comes from a source that was really retrieved.
module Drift.Output.Draft
  ( draftMarkdown
  , sourcesOf
  , orderedEntries
  , pathTitle
  , keptPathTitle
  , entryLine
  ) where

import Citeproc (Style)
import Citeproc.CslJson (CslJson)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Domain.Entries (EntryState (..), entriesForNode, replayEntries)
import Drift.Output.Cite (Rendered (..), escapeMarkdown, renderCitations)
import Drift.Protocol (Entry (..), Event (..), Source (..), SourceId, Stamped (..))

-- | The sources found so far, by id. A later event for the same id replaces an earlier one.
sourcesOf :: [Stamped] -> Map SourceId Source
sourcesOf evs = Map.fromList [(s.sourceId, s) | st <- evs, SourceFound {source = s} <- [st.event]]

-- | Entries in the order they were written, which is the order of the walk.
orderedEntries :: [Stamped] -> [EntryState]
orderedEntries = sortOn (.writtenSeq) . Map.elems . replayEntries

-- | "from first to last" over the words chosen, or just the word if there is one.
pathTitle :: [Stamped] -> Maybe Text
pathTitle evs = case [w | st <- evs, NodeChosen {word = w} <- [st.event]] of
  [] -> Nothing
  [w] -> Just (escapeMarkdown w)
  first : rest -> Just ("from " <> escapeMarkdown first <> " to " <> escapeMarkdown (foldl (\_ w -> w) first rest))

-- | Like 'pathTitle', but ending at the last word the user kept: a node whose
-- notes are all struck through does not name the final document.
keptPathTitle :: [Stamped] -> Maybe Text
keptPathTitle evs =
  let entries = replayEntries evs
      struckOnly n = case entriesForNode n entries of
        [] -> False
        es -> all (.struck) es
      chosen = [(n, w) | st <- evs, NodeChosen {node = n, word = w} <- [st.event]]
      kept = [w | (n, w) <- chosen, not (struckOnly n)]
   in case kept of
        [] -> Nothing
        [w] -> Just (escapeMarkdown w)
        first : rest -> Just ("from " <> escapeMarkdown first <> " to " <> escapeMarkdown (last rest))

draftMarkdown :: Style (CslJson Text) -> [Stamped] -> Text
draftMarkdown style evs =
  case orderedEntries evs of
    [] -> T.intercalate "\n\n" [heading, "_No entries yet._"]
    entries ->
      let rendered = renderCitations style (sourcesOf evs) (map (\e -> e.entry.cites) entries)
          lines' = [entryLine n e c | (n, e, c) <- zip3 [1 ..] entries rendered.citations]
          refs
            | null rendered.bibliography = []
            | otherwise = ["## References", T.intercalate "\n\n" (map snd rendered.bibliography)]
       in T.intercalate "\n\n" ([heading, T.intercalate "\n" lines'] <> refs)
  where
    heading = maybe "# Draft" ("# Draft: " <>) (pathTitle evs)

-- | One numbered line: the relation in bold, the explanation, the citation
-- placed before the closing full stop, the whole line crossed out when the
-- entry is struck.
entryLine :: Int -> EntryState -> Text -> Text
entryLine n st citation = T.pack (show n) <> ". " <> (if st.struck then "~~" <> body <> "~~" else body)
  where
    e = st.entry
    relation = sentence (escapeMarkdown e.relation)
    explanation = escapeMarkdown e.explanation
    body
      | T.null explanation = bold relation <> cite " "
      | otherwise = bold relation <> " " <> withCitation explanation
    bold t = if T.null t then "" else "**" <> t <> "**"
    cite sep = if T.null citation then "" else sep <> citation
    withCitation t
      | T.null citation = t
      | otherwise = case T.unsnoc t of
          Just (body', c) | c `elem` (".!?" :: String) -> body' <> " " <> citation <> T.singleton c
          _ -> t <> " " <> citation <> "."
    sentence t = case T.unsnoc t of
      Just (_, c) | c `elem` (".!?" :: String) -> t
      Just _ -> t <> "."
      Nothing -> t
