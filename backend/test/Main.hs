module Main (main) where

import qualified BranchServiceSpec
import qualified BranchesSpec
import qualified CitationsSpec
import qualified CslSpec
import qualified DomainDecideSpec
import qualified DomainPropertySpec
import qualified DomainReplaySpec
import qualified EntriesSpec
import qualified HttpSpec
import qualified LiveSpec
import qualified ModelProviderSpec
import qualified OpenAlexSpec
import qualified PipelineSpec
import qualified PrefetchSpec
import qualified ProtocolSpec
import qualified RelevanceSpec
import qualified SchedulerSpec
import qualified ServerSpec
import qualified SessionActorSpec
import qualified SessionE2ESpec
import qualified StoreSpec
import Test.Hspec (describe, hspec)
import qualified TextSpec
import qualified WikipediaSpec
import qualified WritingSpec

main :: IO ()
main = hspec $ do
  describe "Protocol" ProtocolSpec.spec
  describe "Domain replay" DomainReplaySpec.spec
  describe "Domain decide" DomainDecideSpec.spec
  describe "Domain properties" DomainPropertySpec.spec
  describe "Store" StoreSpec.spec
  describe "Session actor" SessionActorSpec.spec
  describe "Server" ServerSpec.spec
  describe "Session end to end" SessionE2ESpec.spec
  describe "Entries" EntriesSpec.spec
  describe "Citations" CitationsSpec.spec
  describe "Writing" WritingSpec.spec
  describe "Model providers" ModelProviderSpec.spec
  describe "Branches" BranchesSpec.spec
  describe "Branch service" BranchServiceSpec.spec
  describe "Scheduler" SchedulerSpec.spec
  describe "Prefetch" PrefetchSpec.spec
  HttpSpec.spec
  TextSpec.spec
  WikipediaSpec.spec
  OpenAlexSpec.spec
  CslSpec.spec
  RelevanceSpec.spec
  PipelineSpec.spec
  LiveSpec.spec
