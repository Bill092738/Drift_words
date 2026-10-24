module Main (main) where

import qualified BranchesSpec
import qualified ModelProviderSpec
import qualified PrefetchSpec
import qualified ProtocolSpec
import qualified SchedulerSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  ProtocolSpec.spec
  ModelProviderSpec.spec
  BranchesSpec.spec
  SchedulerSpec.spec
  PrefetchSpec.spec
