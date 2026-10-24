{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The wire contract between the frontend and the backend.
--
-- This module is the single source of truth. TypeScript declarations in
-- @frontend/src/protocol/generated.ts@ are generated from it by the
-- @drift-gen-ts@ executable; never edit the generated file by hand.
--
-- Encoding rules are in "Drift.Protocol.Options".
module Drift.Protocol
  ( -- * Identifiers
    NodeId (..)
  , CandidateId (..)
  , SourceId (..)
  , EntryId (..)
    -- * Shared values
  , Lang (..)
  , Vec2 (..)
  , Candidate (..)
  , Origin (..)
  , SourceKind (..)
  , Source (..)
  , Entry (..)
  , Outputs (..)
    -- * Client to server
  , Command (..)
  , ClientMsg (..)
    -- * Server to client
  , Event (..)
  , Stamped (..)
  , ServerMsg (..)
  ) where

import Data.Aeson (Value)
import Data.Aeson.TH (deriveJSON)
import Data.Aeson.TypeScript.TH (deriveTypeScript)
import Data.Int (Int64)
import Data.Text (Text)
import Drift.Protocol.Options (enumOptions, wireOptions)

------------------------------------------------------------------------------
-- Identifiers. Allocated by the server, unique within a session.

newtype NodeId = NodeId Int deriving (Eq, Ord, Show)

newtype CandidateId = CandidateId Int deriving (Eq, Ord, Show)

newtype SourceId = SourceId Int deriving (Eq, Ord, Show)

newtype EntryId = EntryId Int deriving (Eq, Ord, Show)

------------------------------------------------------------------------------
-- Shared values

-- | Language of the words on the desk.
data Lang = En | Zh deriving (Eq, Show)

-- | A position on the desk, in world units.
data Vec2 = Vec2 {x :: Double, y :: Double} deriving (Eq, Show)

-- | A word on offer that the user may pick.
data Candidate = Candidate {candidateId :: CandidateId, word :: Text}
  deriving (Eq, Show)

-- | How a node entered the tree.
data Origin
  = Cloud -- ^ picked from the initial random cloud
  | StartWord -- ^ typed as the starting word
  | Branch -- ^ picked from a ring of branch words
  | Insert -- ^ the user's own inserted word
  deriving (Eq, Show)

data SourceKind = Article | Paper | Pdf | WebPage | Image | Audio
  deriving (Eq, Show)

-- | Material backing the connection into 'node' from its parent.
data Source = Source
  { sourceId :: SourceId
  , node :: NodeId -- ^ the edge is identified by its child node
  , kind :: SourceKind
  , title :: Text
  , site :: Maybe Text -- ^ site or publisher name shown under the icon
  , url :: Text
  , thumbnailUrl :: Maybe Text
  , csl :: Maybe Value -- ^ CSL-JSON item used to render the reference
  }
  deriving (Eq, Show)

-- | A sidebar entry describing the connection into 'node' from its parent.
data Entry = Entry
  { entryId :: EntryId
  , node :: NodeId
  , relation :: Text -- ^ how the previous word relates to this one
  , explanation :: Text -- ^ one or two sentences of explanation
  , cites :: [SourceId]
  }
  deriving (Eq, Show)

-- | The three results of a wrap-up, as Markdown.
data Outputs = Outputs
  { decisionTree :: Text
  , draft :: Text
  , final :: Text
  }
  deriving (Eq, Show)

------------------------------------------------------------------------------
-- Commands: what the user wants to do. The server may reject them.

data Command
  = Pick {candidateId :: CandidateId}
  | StartWithWord {word :: Text}
  | InsertWord {word :: Text}
  | Backtrack {node :: NodeId}
  | SetDivergence {divergence :: Double}
  | PlaceNode {node :: NodeId, pos :: Vec2, angle :: Double}
  | PlaceSource {sourceId :: SourceId, pos :: Vec2, angle :: Double}
  | Promote {entryId :: EntryId, levels :: Int}
  | Strike {entryId :: EntryId}
  | Restore {entryId :: EntryId}
  | WrapUp
  deriving (Eq, Show)

-- | A command with a client-chosen request id, echoed back on rejection.
data ClientMsg = ClientMsg {req :: Int, command :: Command}
  deriving (Eq, Show)

------------------------------------------------------------------------------
-- Events: what happened. The session is the fold of its events.

data Event
  = CloudSpawned {lang :: Lang, candidates :: [Candidate]}
  | NodeChosen
      { node :: NodeId
      , parent :: Maybe NodeId
      , word :: Text
      , origin :: Origin
      , fromCandidate :: Maybe CandidateId
      }
  | CandidateStreamed {node :: NodeId, candidate :: Candidate}
    -- ^ one branch word for 'node', sent as soon as it is generated
  | BranchesOffered {node :: NodeId, candidates :: [Candidate]}
    -- ^ the sealed, final ring of branch words for 'node'
  | NodeRevisited {node :: NodeId}
  | DivergenceSet {divergence :: Double}
  | SourceFound {source :: Source}
  | EntryWritten {entry :: Entry}
  | EntryRevised {entry :: Entry}
  | EntryPromoted {entryId :: EntryId, levels :: Int}
  | EntryStruck {entryId :: EntryId}
  | EntryRestored {entryId :: EntryId}
  | NodePlaced {node :: NodeId, pos :: Vec2, angle :: Double}
  | SourcePlaced {sourceId :: SourceId, pos :: Vec2, angle :: Double}
  | WrappedUp
  | OutputsReady {outputs :: Outputs}
  deriving (Eq, Show)

-- | An event with its position in the session log and its time.
data Stamped = Stamped
  { seq :: Int -- ^ 1-based, strictly increasing within a session
  , atMs :: Int64 -- ^ Unix time in milliseconds
  , event :: Event
  }
  deriving (Eq, Show)

data ServerMsg
  = Events {events :: [Stamped]}
    -- ^ new events; on connect, the whole log so far
  | Rejected {req :: Int, reason :: Text}
  deriving (Eq, Show)

------------------------------------------------------------------------------
-- JSON and TypeScript instances

$(concat <$> traverse (\n -> (<>) <$> deriveJSON wireOptions n <*> deriveTypeScript wireOptions n)
    [''NodeId, ''CandidateId, ''SourceId, ''EntryId])

$(concat <$> traverse (\n -> (<>) <$> deriveJSON enumOptions n <*> deriveTypeScript enumOptions n)
    [''Lang, ''Origin, ''SourceKind])

$(concat <$> traverse (\n -> (<>) <$> deriveJSON wireOptions n <*> deriveTypeScript wireOptions n)
    [ ''Vec2, ''Candidate, ''Source, ''Entry, ''Outputs
    , ''Command, ''ClientMsg, ''Event, ''Stamped, ''ServerMsg
    ])
