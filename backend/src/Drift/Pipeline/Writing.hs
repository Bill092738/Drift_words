{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The writing pipeline: one sidebar entry for each new edge of the word
-- tree (TECH_ROADMAP.md section 4.8).
--
-- The session actor runs 'writeEntry' as P2 model work once a node with a
-- parent is chosen. It passes the sources already found for that edge, after
-- waiting briefly for the source job. Sources that land later go through
-- 'reviseForSource', which attaches the citation without another model call.
--
-- The model is given as a plain @Text -> IO Text@ so this module does not
-- depend on a particular provider. With "Drift.Model.Provider" it is
-- @\\p -> generate provider (GenRequest p model 0 256) (const (pure ()))@.
module Drift.Pipeline.Writing
  ( WritingInput (..)
  , buildWritingPrompt
  , parseWritingOutput
  , entryFromOutput
  , fallbackEntry
  , templateEntry
  , writeEntry
  , reviseForSource
  ) where

import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Data.Char (isSpace, toLower)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Domain.Entries (Entries, EntryState (..), entriesForNode)
import Drift.Pipeline.Citations
import Drift.Protocol

-- | Everything the model needs to write the entry for the edge into 'node'.
data WritingInput = WritingInput
  { node :: NodeId -- ^ the child node; it identifies the edge
  , fromWord :: Text -- ^ the parent word
  , toWord :: Text -- ^ the chosen word
  , path :: [Text] -- ^ words from the root down to 'fromWord'
  , origin :: Origin
  , lang :: Lang
  , sources :: [Source] -- ^ sources found for this edge so far
  }
  deriving stock (Eq, Show)

buildWritingPrompt :: WritingInput -> Text
buildWritingPrompt i =
  T.unlines $
    [ "You write short notes for a thinking tool. The user is exploring ideas by"
    , "picking one word after another. Explain the step they just took."
    , ""
    , "Path so far: " <> T.intercalate " -> " (i.path <> [i.toWord])
    , "Step: from \"" <> i.fromWord <> "\" to \"" <> i.toWord <> "\"" <> originNote i.origin
    , ""
    ]
      <> sourceBlock
      <> [ "Reply with exactly two lines and nothing else:"
         , "RELATION: how \"" <> i.fromWord <> "\" relates to \"" <> i.toWord <> "\", as a phrase of at most eight words"
         , "EXPLANATION: one or two plain sentences explaining the connection"
         , ""
         , languageNote i.lang
         ]
  where
    sourceBlock
      | null i.sources =
          ["No sources are available. Do not cite anything.", ""]
      | otherwise =
          ["Sources you may cite, only by their key in square brackets such as [@" <> sourceKey (firstId i.sources) <> "]:"]
            <> map describe i.sources
            <> ["Cite a source only if it supports the connection. Never invent keys.", ""]
    firstId = \case
      s : _ -> s.sourceId
      [] -> SourceId 1
    describe s =
      "[@" <> sourceKey s.sourceId <> "] " <> s.title <> maybe "" (" - " <>) s.site

originNote :: Origin -> Text
originNote = \case
  Insert -> " (the user typed this word themselves)"
  _ -> ""

languageNote :: Lang -> Text
languageNote = \case
  En -> "Write in English."
  Zh -> "Write in Simplified Chinese, but keep the labels RELATION and EXPLANATION in English."

-- | Reads the relation and the explanation from a model reply. Accepts the
-- labelled format the prompt asks for, with some tolerance for markdown and
-- extra lines, and falls back to "first line, then the rest".
parseWritingOutput :: Text -> Maybe (Text, Text)
parseWritingOutput raw =
  let ls = filter (not . T.null) (map cleanLine (T.lines raw))
      labelled = labelledFields ls
      (relation, explanation) = case labelled of
        Just fields -> fields
        Nothing -> case ls of
          first : rest -> (first, T.unwords rest)
          [] -> ("", "")
      relation' = unquote (T.strip relation)
   in if T.null relation' then Nothing else Just (relation', T.strip explanation)

labelledFields :: [Text] -> Maybe (Text, Text)
labelledFields ls
  | any (isJust . fst) tagged = Just (field "relation", field "explanation")
  | otherwise = Nothing
  where
    tagged = map splitLabel ls
    field k = fromMaybe "" (lookup k (groups tagged))
    -- A label starts a field; unlabelled lines continue the previous one.
    groups = \case
      [] -> []
      (lbl, v) : rest ->
        let (more, rest') = break (isJust . fst) rest
         in (fromMaybe "" lbl, T.unwords (v : map snd more)) : groups rest'
    splitLabel l = case T.breakOn ":" l of
      (lbl, rest)
        | not (T.null rest)
        , let k = T.map toLower (T.strip lbl)
        , k == "relation" || k == "explanation" ->
            (Just k, T.strip (T.drop 1 rest))
      _ -> (Nothing, l)

cleanLine :: Text -> Text
cleanLine = T.strip . T.filter (/= '*') . T.dropWhile (\c -> c == '-' || c == '#' || isSpace c)

unquote :: Text -> Text
unquote t = case T.uncons t of
  Just (q, rest) | q `elem` ("\"'\8220" :: String), Just (body, e) <- T.unsnoc rest, e `elem` ("\"'\8221" :: String) -> body
  _ -> t

-- | Builds the entry from a model reply. Citation keys are checked against the
-- edge's sources; the sidebar text carries no inline markers, and 'cites'
-- lists the sources in the order the text cites them.
entryFromOutput :: EntryId -> WritingInput -> Text -> Maybe Entry
entryFromOutput eid i raw = do
  (relation, explanation) <- parseWritingOutput raw
  let known = Set.fromList (map (.sourceId) i.sources)
      gr = groundCitations known relation
      ge = groundCitations known explanation
      tidy = T.unwords . T.words . stripCitations
      relation' = tidy relation
  if T.null relation'
    then Nothing
    else
      Just
        Entry
          { entryId = eid
          , node = i.node
          , relation = relation'
          , explanation = tidy explanation
          , cites = dedupe (gr.groundedCites <> ge.groundedCites)
          }
  where
    dedupe = foldr (\x acc -> x : filter (/= x) acc) []

-- | Used when the model fails or replies with something unusable, so every
-- step still gets an entry the user can curate.
fallbackEntry :: EntryId -> WritingInput -> Entry
fallbackEntry eid i =
  Entry
    { entryId = eid
    , node = i.node
    , relation = i.fromWord <> " \8594 " <> i.toWord
    , explanation = ""
    , cites = []
    }

-- | Provider-independent live writing. The placeholder ID and provisional
-- citations are replaced by admission against the actor's current state.
templateEntry :: WritingInput -> IO Entry
templateEntry = pure . fallbackEntry (EntryId 0)

-- | Asks the model for the entry. Model errors fall back to 'fallbackEntry';
-- cancellation by the scheduler is passed through.
writeEntry :: (Text -> IO Text) -> EntryId -> WritingInput -> IO Entry
writeEntry generateText eid i = do
  reply <- try (generateText (buildWritingPrompt i))
  case reply of
    Right raw -> pure (fromMaybe (fallbackEntry eid i) (entryFromOutput eid i raw))
    Left (e :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> pure (fallbackEntry eid i)

-- | A source landed for an edge: every entry for that edge that does not cite
-- it yet is revised to cite it. The text is unchanged.
reviseForSource :: Entries -> Source -> [Event]
reviseForSource entries s =
  [ EntryRevised {entry = e {cites = e.cites <> [s.sourceId]}}
  | st <- entriesForNode s.node entries
  , let e = st.entry
  , s.sourceId `notElem` e.cites
  ]
