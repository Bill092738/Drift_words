-- | Pure, replay-derived session state. All IDs are session-local.
module Drift.Domain.Types
  ( SessionId (..), Rejection (..), Log (..)
  , Node (..), Placement (..), Session (..)
  ) where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Drift.Domain.Entries (Entries)
import Drift.Protocol

newtype SessionId = SessionId Text deriving (Eq, Ord, Show)

newtype Rejection = Rejection Text deriving (Eq, Show)

-- | Newest event first. Reverse chronological wire arrays exactly once
-- when constructing this value, not on every append.
newtype Log = Log [Stamped] deriving (Eq, Show)

data Node = Node
  { nodeId :: NodeId
  , nodeParent :: Maybe NodeId
  , nodeWord :: Text
  , nodeOrigin :: Origin
  , nodeFromCandidate :: Maybe CandidateId
  , nodeSelectionOrder :: Int
  , nodeChildren :: [NodeId]
  } deriving (Eq, Show)

data Placement = Placement
  { placementPosition :: Vec2
  , placementAngle :: Double
  } deriving (Eq, Show)

data Session = Session
  { sessionLanguage :: Maybe Lang
  , sessionNodes :: Map NodeId Node
  , sessionSelectionOrder :: [NodeId] -- ^ Oldest choice first.
  , sessionFocus :: Maybe NodeId
  , sessionBreadcrumbs :: [NodeId] -- ^ Parent first, root last.
  , sessionVisited :: Set Text -- ^ Normalized word keys.
  , sessionAppearances :: Map Text Int
  , sessionSeenCandidates :: Set CandidateId
  , sessionCloud :: [Candidate] -- ^ Original cloud, retained after choosing.
  , sessionRingNode :: Maybe NodeId -- ^ Nothing while the cloud is active.
  , sessionCandidates :: Map CandidateId Candidate -- ^ Currently pickable offers.
  , sessionRings :: Map NodeId [Candidate] -- ^ Last sealed offer per node.
  , sessionStreamed :: Map NodeId [Candidate] -- ^ Current generation, in arrival order.
  , sessionNextNodeId :: NodeId
  , sessionNextCandidateId :: CandidateId
  , sessionDivergence :: Double
  , sessionSources :: Map SourceId Source
  , sessionEntries :: Entries -- ^ Sidebar entries; rules live in "Drift.Domain.Entries".
  , sessionNodePlacements :: Map NodeId Placement
  , sessionSourcePlacements :: Map SourceId Placement
  , sessionWrapped :: Bool
  , sessionOutputs :: Maybe Outputs
  } deriving (Eq, Show)
