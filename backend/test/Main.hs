module Main (main) where

import qualified BranchServiceSpec
import qualified BranchesSpec
import qualified CitationsSpec
import qualified EntriesSpec
import qualified ModelProviderSpec
import qualified PrefetchSpec
import qualified ProtocolSpec
import qualified SchedulerSpec
import Test.Hspec (describe, hspec)
import qualified WritingSpec

main :: IO ()
main = hspec $ do
  describe "Protocol" ProtocolSpec.spec
  describe "Entries" EntriesSpec.spec
  describe "Citations" CitationsSpec.spec
  describe "Writing" WritingSpec.spec
  describe "Model providers" ModelProviderSpec.spec
  describe "Branches" BranchesSpec.spec
  describe "Branch service" BranchServiceSpec.spec
  describe "Scheduler" SchedulerSpec.spec
  describe "Prefetch" PrefetchSpec.spec
