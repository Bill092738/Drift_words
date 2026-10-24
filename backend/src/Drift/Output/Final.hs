{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The final document: only the entries the user kept (not struck, at or above
-- a priority), reorganized into continuous prose, with references computed from
-- what that prose actually cites (TECH_ROADMAP.md 4.8 and 7.3, M8).
--
-- * The walk is split into sections at each backtrack, and each section is
--   headed by the first kept word in it. With a single section there are no
--   headings.
-- * A model rewrites each section's notes as prose. It is a plain
--   @Text -> IO Text@, so this module does not depend on a provider. Its reply
--   is checked: only sources cited by the kept entries can be cited, anything
--   else is dropped (invariants 5 and 6).
-- * Without a model, or when it fails or answers with nothing usable, the
--   section is the kept entries' own text, still with their citations. The
--   final document is never empty because a model was away.
-- * The reference list is rendered from the citations that survive in the final
--   text, so it is exactly the sources the text cites, and it can only contain
--   sources that a kept entry cited, which the draft also cites.
module Drift.Output.Final
  ( FinalOptions (..)
  , defaultFinalOptions
  , Generate
  , FinalDoc (..)
  , Section (..)
  , Piece (..)
  , finalMarkdown
  , retainedEntries
  , sectionsOf
  , sectionPrompt
  , citationPieces
  ) where

import Citeproc (Style)
import Citeproc.CslJson (CslJson)
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Char (toUpper)
import Data.List (mapAccumL, nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Domain.Entries (EntryState (..))
import Drift.Output.Cite (Rendered (..), escapeBlockStart, escapeInline, escapeMarkdown, renderCitations)
import Drift.Output.Draft (orderedEntries, pathTitle, sourcesOf)
import Drift.Pipeline.Citations (Grounded (..), groundCitations, parseSourceKey, sourceKey)
import Drift.Protocol (Entry (..), Event (..), Lang (..), NodeId, Source (..), SourceId, Stamped (..))

-- | The model, as a function from a prompt to its reply. With
-- "Drift.Model.Provider" it is @\\p -> generate provider (GenRequest p model 0 600) (const (pure ()))@
-- under the @final@ role.
type Generate = Text -> IO Text

data FinalOptions = FinalOptions
  { minPriority :: Int
  -- ^ entries below this are left out; 1 keeps every entry the user raised at least once
  , maxReplyChars :: Int
  -- ^ longer replies are cut, so a runaway model cannot flood the document
  }

defaultFinalOptions :: FinalOptions
defaultFinalOptions = FinalOptions {minPriority = 1, maxReplyChars = 4000}

data FinalDoc = FinalDoc
  { finalText :: Text
  , finalReferences :: [SourceId]
  -- ^ the sources of the reference list, in its order
  , finalWarnings :: [Text]
  -- ^ what fell back or was dropped, for logs; never shown to the user
  }
  deriving stock (Eq, Show)

-- | A stretch of the walk between two backtracks, with the entries kept in it.
data Section = Section
  { sectionWord :: Text
  , sectionEntries :: [EntryState]
  }
  deriving stock (Eq, Show)

-- | Entries that are not struck and have at least the minimum priority, in the
-- order they were written.
retainedEntries :: FinalOptions -> [Stamped] -> [EntryState]
retainedEntries opts evs = [st | st <- orderedEntries evs, not st.struck, st.priority >= opts.minPriority]

data Walk = Walk
  { current :: Int
  , backed :: Bool
  , segmentOf :: Map NodeId Int
  , wordOfNode :: Map NodeId Text
  }

walkOf :: [Stamped] -> Walk
walkOf = foldl step (Walk 0 False Map.empty Map.empty) . map (.event)
  where
    step w = \case
      NodeRevisited {} -> w {backed = True}
      NodeChosen {node = n, word = wd} ->
        let s = if w.backed then w.current + 1 else w.current
         in Walk s False (Map.insert n s w.segmentOf) (Map.insert n wd w.wordOfNode)
      _ -> w

-- | Groups the kept entries by the stretch of the walk their node was chosen in:
-- a new stretch starts with the first choice after a backtrack.
sectionsOf :: [Stamped] -> [EntryState] -> [Section]
sectionsOf evs kept =
  [ Section (Map.findWithDefault "" first.entry.node w.wordOfNode) es
  | (_, es@(first : _)) <- Map.toAscList grouped
  ]
  where
    w = walkOf evs
    grouped = Map.fromListWith (\new old -> old <> new) [(Map.findWithDefault 0 st.entry.node w.segmentOf, [st]) | st <- kept]

-- | What the model is asked for one section. Only the section's own kept notes
-- and the sources they cite go in: struck and low-priority entries never reach
-- the model.
sectionPrompt :: Lang -> Text -> [EntryState] -> [Source] -> Text
sectionPrompt lang topic es srcs =
  T.unlines $
    [ "You turn a user's notes from an exploration of ideas into a short passage of continuous prose."
    , ""
    , "Passage topic: " <> oneLine topic
    , ""
    , "Notes, in order. Each is a step the user chose to keep:"
    ]
      <> map note es
      <> [""]
      <> sourceBlock
      <> [ ""
         , "Write one to three short paragraphs that connect the notes into a flowing passage."
         , "Use only what the notes say; add no new facts, names or numbers."
         , "Cite only with the source keys above, written like [@src1] or [@src1; @src2], right after the claim they support. Never invent a key."
         , "Plain prose only: no headings, lists, tables or code."
         , languageNote lang
         ]
  where
    note st =
      "- " <> oneLine st.entry.relation <> ": " <> oneLine st.entry.explanation
        <> case nub st.entry.cites of
          [] -> ""
          ids -> " (sources: " <> T.intercalate ", " ["[@" <> sourceKey i <> "]" | i <- ids] <> ")"
    sourceBlock
      | null srcs = ["No sources are available. Do not cite anything."]
      | otherwise =
          "Sources you may cite, only by their key:"
            : ["[@" <> sourceKey s.sourceId <> "] " <> oneLine s.title <> maybe "" (\site -> " - " <> oneLine site) s.site | s <- srcs]
    oneLine = T.unwords . T.words
    languageNote = \case
      En -> "Write in English."
      Zh -> "Write in Simplified Chinese."

-- | Text with citation markers pulled out: @[\@src1; \@src2]@ becomes 'Cite'.
data Piece = Plain Text | Cite [SourceId]
  deriving stock (Eq, Show)

citationPieces :: Text -> [Piece]
citationPieces t = case T.breakOn "[@" t of
  (before, rest)
    | T.null rest -> plain before
    | otherwise ->
        let (inside, after) = T.breakOn "]" (T.drop 1 rest)
            ids = mapMaybe (parseSourceKey . T.drop 1 . T.strip) (T.splitOn ";" inside)
         in if T.null after
              then [Plain t]
              else plain before <> [Cite ids | not (null ids)] <> citationPieces (T.drop 1 after)
  where
    plain x = [Plain x | not (T.null x)]

-- | The marker for a group of sources.
marker :: [SourceId] -> Text
marker ids = "[" <> T.intercalate "; " ["@" <> sourceKey i | i <- ids] <> "]"

-- | The kept entries' own text as prose, with their citations: the fallback.
fallbackBody :: Set SourceId -> [EntryState] -> Text
fallbackBody allowed es = T.unwords (map one es)
  where
    one st =
      let cites = [i | i <- nub st.entry.cites, i `Set.member` allowed]
          relation = sentence (T.unwords (T.words st.entry.relation))
          explanation = T.unwords (T.words st.entry.explanation)
       in if T.null explanation
            then relation <> (if null cites then "" else " " <> marker cites)
            else relation <> " " <> withMarker explanation cites
    withMarker t [] = t
    withMarker t cites = case T.unsnoc t of
      Just (body, c) | c `elem` (".!?" :: String) -> body <> " " <> marker cites <> T.singleton c
      _ -> t <> " " <> marker cites <> "."
    sentence t = case T.unsnoc t of
      Just (_, c) | c `elem` (".!?" :: String) -> t
      Just _ -> t <> "."
      Nothing -> t

-- | Asks the model for one section and checks the answer. Returns the section's
-- text with citation markers, and what went wrong if anything.
runSection :: Maybe Generate -> FinalOptions -> Lang -> Map SourceId Source -> Set SourceId -> Section -> IO (Text, [Text])
runSection model opts lang sources allowed sec = case model of
  Nothing -> pure (fallback, [])
  Just generate -> do
    r <- try (generate prompt)
    case r of
      Left (e :: SomeException)
        | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        | otherwise -> pure (fallback, [label <> ": the model failed, used the kept entries' own text"])
      Right raw ->
        let g = groundCitations allowed (T.take opts.maxReplyChars (T.filter (/= '\r') raw))
            dropped = [label <> ": dropped a citation of " <> k | k <- g.droppedKeys]
         in if usable g.groundedText
              then pure (g.groundedText, dropped)
              else pure (fallback, dropped <> [label <> ": the model's reply was unusable, used the kept entries' own text"])
  where
    label = "section \"" <> sec.sectionWord <> "\""
    fallback = fallbackBody allowed sec.sectionEntries
    own = nub [i | st <- sec.sectionEntries, i <- st.entry.cites, i `Set.member` allowed]
    prompt = sectionPrompt lang sec.sectionWord sec.sectionEntries (mapMaybe (`Map.lookup` sources) own)
    -- Enough words of its own, not just a citation or a fragment.
    usable t = T.length (T.strip (T.concat [x | Plain x <- citationPieces t])) >= 20

finalMarkdown :: Maybe Generate -> FinalOptions -> Style (CslJson Text) -> [Stamped] -> IO FinalDoc
finalMarkdown model opts style evs = do
  let kept = retainedEntries opts evs
      sources = sourcesOf evs
      allowed = Set.fromList [i | st <- kept, i <- st.entry.cites, i `Map.member` sources]
      sections = sectionsOf evs kept
      lang = case [l | st <- evs, CloudSpawned {lang = l} <- [st.event]] of
        l : _ -> l
        [] -> En
      title = "# " <> maybe "Final" capitalize (pathTitle evs)
  if null kept
    then pure (FinalDoc (title <> "\n\n_No entries were kept at high priority._") [] [])
    else do
      results <- mapM (runSection model opts lang sources allowed) sections
      let bodies = map fst results
          warnings = concatMap snd results
          paragraphs = map (map citationPieces . paragraphsOf) bodies
          groups = [ids | ps <- paragraphs, p <- ps, Cite ids <- p]
          rendered = renderCitations style sources groups
          (_, filled) = mapAccumL fillSection rendered.citations paragraphs
          headed = length sections > 1
          block sec ps =
            [ "## " <> capitalize (escapeMarkdown sec.sectionWord)
            | headed
            , not (T.null (T.strip sec.sectionWord))
            ]
              <> [T.intercalate "\n\n" ps]
          bodyBlocks = concat (zipWith block sections filled)
          refs
            | null rendered.bibliography = []
            | otherwise = ["## References", T.intercalate "\n\n" (map snd rendered.bibliography)]
      pure (FinalDoc (T.intercalate "\n\n" ([title] <> bodyBlocks <> refs)) (map fst rendered.bibliography) warnings)

-- | Substitutes the rendered citations, in order, into a section's paragraphs,
-- escaping all other text.
fillSection :: [Text] -> [[Piece]] -> ([Text], [Text])
fillSection cites paras = mapAccumL para cites paras
  where
    para cs pieces =
      let (cs', parts) = mapAccumL piece cs pieces
       in (cs', escapeBlockStart (T.concat parts))
    piece cs = \case
      Plain t -> (cs, escapeInline t)
      Cite _ -> case cs of
        c : rest -> (rest, c)
        [] -> ([], "")

-- | Paragraphs of a reply: blank-line separated, white space folded, none empty.
paragraphsOf :: Text -> [Text]
paragraphsOf = filter (not . T.null) . map (T.unwords . T.words . T.unlines) . blocks . T.lines
  where
    blocks ls = case break (T.null . T.strip) ls of
      (a, []) -> [a]
      (a, _ : rest) -> a : blocks rest

capitalize :: Text -> Text
capitalize t = case T.uncons t of
  Just (c, rest) -> T.cons (toUpper c) rest
  Nothing -> t
