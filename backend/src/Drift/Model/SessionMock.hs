{-# LANGUAGE OverloadedRecordDot #-}

-- | Deterministic offline vocabulary. The numeric suffix gives every depth an
-- inexhaustible, single-token continuation in either supported language.
module Drift.Model.SessionMock (BranchGenerator, mockCloud, mockBranches) where

import Data.Text (Text)
import qualified Data.Text as Text
import Drift.Domain.Types (Session (..))
import Drift.Protocol (Lang (..), NodeId (..))

type BranchGenerator = Session -> NodeId -> IO [Text]

mockCloud :: Lang -> [Text]
mockCloud En = ["river", "light", "forest", "memory", "orbit", "thread"]
mockCloud Zh = ["\x6CB3\x6D41", "\x5149\x8292", "\x68EE\x6797", "\x8BB0\x5FC6", "\x8F68\x9053", "\x4E1D\x7EBF"]

mockBranches :: BranchGenerator
mockBranches session (NodeId node) = pure $
  map (<> Text.pack (show node)) $ case session.sessionLanguage of
    Just Zh -> ["\x6D9F\x6F2A", "\x6865\x6881", "\x661F\x8FB0", "\x56DE\x58F0", "\x79CD\x5B50", "\x8FDC\x65B9"]
    _ -> ["ripple", "bridge", "starlight", "echo", "seed", "horizon"]
