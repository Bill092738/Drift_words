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
mockCloud Zh = ["河流", "光芒", "森林", "记忆", "轨道", "丝线"]

mockBranches :: BranchGenerator
mockBranches session (NodeId node) = pure $
  map (<> Text.pack (show node)) $ case session.sessionLanguage of
    Just Zh -> ["涟漪", "桥梁", "星辰", "回声", "种子", "远方"]
    _ -> ["ripple", "bridge", "starlight", "echo", "seed", "horizon"]
