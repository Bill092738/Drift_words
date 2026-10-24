{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The decision tree output: how the user got here, step by step, including
-- every fork and every backtrack (idea.md, "Wrapping up and the three
-- outputs"). It is derived from the event log alone, with no model and no
-- sources, so it is the same on every replay.
module Drift.Output.Tree
  ( DecisionTree (..)
  , TreeNode (..)
  , TreeEdge (..)
  , buildTree
  , renderMermaid
  , decisionTreeMarkdown
  , mermaidLabel
  ) where

import Data.Char (isAlphaNum)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Protocol (Event (..), NodeId (..), Origin)

data TreeNode = TreeNode
  { nodeId :: NodeId
  , word :: Text
  , origin :: Origin
  }
  deriving stock (Eq, Show)

-- | A step from a parent word to a child word. 'revisited' is set when the
-- user had gone back to the parent before choosing the child: the second and
-- later branches out of a word, after a backtrack.
data TreeEdge = TreeEdge
  { from :: NodeId
  , to :: NodeId
  , revisited :: Bool
  }
  deriving stock (Eq, Show)

-- | Nodes and edges in the order the user made the choices.
data DecisionTree = DecisionTree
  { nodes :: [TreeNode]
  , edges :: [TreeEdge]
  }
  deriving stock (Eq, Show)

data Walk = Walk
  { nodesRev :: [TreeNode]
  , edgesRev :: [TreeEdge]
  , backAt :: Maybe NodeId
  -- ^ set by a revisit, cleared by the next choice
  }

-- | Builds the tree from the session's events, oldest first. Events that do
-- not shape the path (sources, entries, placements, ...) are ignored.
buildTree :: [Event] -> DecisionTree
buildTree evs =
  let end = foldl' step (Walk [] [] Nothing) evs
   in DecisionTree (reverse end.nodesRev) (reverse end.edgesRev)
  where
    step w = \case
      NodeChosen {node = n, parent = p, word = wd, origin = o} ->
        w
          { nodesRev = TreeNode n wd o : w.nodesRev
          , edgesRev = case p of
              Just par -> TreeEdge par n (w.backAt == Just par) : w.edgesRev
              Nothing -> w.edgesRev
          , backAt = Nothing
          }
      NodeRevisited {node = n} -> w {backAt = Just n}
      _ -> w

-- | The Mermaid flowchart, in the form of the protocol fixtures: each node is
-- labelled where it first appears, and a branch taken after a backtrack is a
-- dotted edge marked "revisited". A node with no edges is declared on its own
-- line so a one-word session still shows its word.
renderMermaid :: DecisionTree -> Text
renderMermaid t =
  T.intercalate "\n" ("flowchart TD" : map ("  " <>) (edgeLines <> loneLines))
  where
    wordOf = \n -> maybe "" (.word) (lookup n [(x.nodeId, x) | x <- t.nodes])
    ref n declared =
      if n `Set.member` declared
        then (nodeName n, declared)
        else (nodeName n <> "[" <> mermaidLabel (wordOf n) <> "]", Set.insert n declared)
    (edgeLines, declaredAfterEdges) = foldl' edge ([], Set.empty) t.edges
    edge (acc, declared) e =
      let (a, d1) = ref e.from declared
          (b, d2) = ref e.to d1
          arrow = if e.revisited then " -. revisited .-> " else " --> "
       in (acc <> [a <> arrow <> b], d2)
    loneLines =
      [ fst (ref x.nodeId declaredAfterEdges)
      | x <- t.nodes
      , x.nodeId `Set.notMember` declaredAfterEdges
      ]

nodeName :: NodeId -> Text
nodeName (NodeId n) = "n" <> T.pack (show n)

-- | A label Mermaid cannot misread. Plain words stay plain, as in the
-- fixtures; anything with markup characters is quoted with the double quote
-- escaped as an entity. The word "end" is quoted too, because Mermaid reads a
-- bare @end@ inside a flowchart as the end of a subgraph.
mermaidLabel :: Text -> Text
mermaidLabel w
  | not (T.null w) && T.all plain w && T.toLower (T.strip w) /= "end" = w
  | otherwise = "\"" <> T.concatMap escape (T.strip w) <> "\""
  where
    plain c = isAlphaNum c || c `elem` ("-_' " :: String)
    escape = \case
      '"' -> "#quot;"
      '\n' -> " "
      c -> T.singleton c

-- | The decision tree as it goes into 'Outputs': a fenced Mermaid block.
decisionTreeMarkdown :: [Event] -> Text
decisionTreeMarkdown evs = "```mermaid\n" <> renderMermaid (buildTree evs) <> "\n```"
