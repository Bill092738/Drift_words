{-# LANGUAGE OverloadedRecordDot #-}

-- | Tests against the real public APIs. They are skipped unless
-- @DRIFT_LIVE_TESTS=1@ is set, so CI and ordinary runs never touch the network
-- (OpenAlex without a key shares a small daily budget; see "Drift.Search.OpenAlex").
module LiveSpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Text as T
import Drift.Pipeline.Sources (defaultSourceEnv, findSources)
import Drift.Protocol (Lang (En))
import Drift.Search.Http (defaultHttpConfig, newFetch)
import Drift.Search.Text (isWebUrl)
import Drift.Search.Types (SourceDraft (..), SourceRequest (..))
import System.Environment (lookupEnv)
import Test.Hspec

spec :: Spec
spec = describe "live APIs (DRIFT_LIVE_TESTS=1)" $ do
  enabled <- runIO (lookupEnv "DRIFT_LIVE_TESTS")
  let run = case enabled of
        Just "1" -> id
        _ -> \_ -> pendingWith "set DRIFT_LIVE_TESTS=1 to call the real APIs"
  it "finds well-formed sources for tide -> moon" . run $ do
    fetch <- newFetch defaultHttpConfig
    out <- newIORef []
    findSources (defaultSourceEnv fetch) (SourceRequest (Just "tide") "moon" ["tide"] En) (\d -> modifyIORef' out (d :))
    found <- readIORef out
    found `shouldSatisfy` (not . null)
    found `shouldSatisfy` ((<= 2) . length)
    mapM_ (\d -> d.url `shouldSatisfy` isWebUrl) found
    mapM_ (\d -> T.null d.title `shouldBe` False) found
