{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | What the source search takes in and gives out. Nothing here knows about
-- sessions: the caller (the session actor, later) allocates the 'SourceId' and
-- turns a 'SourceDraft' into a 'Source' with 'toSource'.
module Drift.Search.Types
  ( SourceRequest (..)
  , SourceDraft (..)
  , Hit (..)
  , toSource
  ) where

import Data.Aeson (Value)
import Data.Text (Text)
import Drift.Protocol (Lang, NodeId, Source (Source), SourceId, SourceKind)

-- | The edge to find material for: the connection from 'fromWord' into
-- 'toWord'. A root node has no parent word.
data SourceRequest = SourceRequest
  { fromWord :: Maybe Text
  , toWord :: Text
  , pathWords :: [Text]
  -- ^ words from the root down to 'fromWord', for disambiguation
  , lang :: Lang
  }
  deriving stock (Eq, Show)

-- | A source that passed every check, without the two things only the session
-- knows: its 'SourceId' and the node it belongs to.
data SourceDraft = SourceDraft
  { kind :: SourceKind
  , title :: Text
  , site :: Maybe Text
  , url :: Text
  , thumbnailUrl :: Maybe Text
  , csl :: Maybe Value
  }
  deriving stock (Eq, Show)

-- | A search result before the relevance check: the draft plus what the check
-- reads. Only the draft ever leaves this package.
data Hit = Hit
  { hitProvider :: Text
  -- ^ "wikipedia" or "openalex"
  , hitDraft :: SourceDraft
  , hitSnippet :: Text
  -- ^ plain text from the provider (an extract or an abstract), never markup
  , hitDoi :: Maybe Text
  -- ^ normalized: lower case, no URL prefix
  , hitRank :: Int
  -- ^ position in the provider's own ranking, from 0
  }
  deriving stock (Eq, Show)

-- | Fills in what the session owns. The wire type is the one in
-- "Drift.Protocol"; positional so a new protocol field is a compile error here.
toSource :: SourceId -> NodeId -> SourceDraft -> Source
toSource sid node d = Source sid node d.kind d.title d.site d.url d.thumbnailUrl d.csl
