module Main (main) where

import qualified BranchServiceSpec
import qualified BranchesSpec
import qualified CiteSpec
import qualified CitationsSpec
import qualified CslSpec
import qualified DomainDecideSpec
import qualified DomainPropertySpec
import qualified DomainReplaySpec
import qualified DraftSpec
import qualified EntriesSpec
import qualified ExportSpec
import qualified FinalSpec
import qualified HttpSpec
import qualified LiveSpec
import qualified ModelProviderSpec
import qualified OpenAlexSpec
import qualified OutputsWiringSpec
import qualified PipelineSpec
import qualified PrefetchSpec
import qualified ProtocolSpec
import qualified RelevanceSpec
import qualified SchedulerSpec
import qualified ServerSpec
import qualified SessionActorSpec
import qualified SessionE2ESpec
import qualified StoreSpec
import SourceServerFixture (runSourceServer)
import System.Environment (getArgs)
import Test.Hspec (describe, hspec)
import qualified TextSpec
import qualified TreeSpec
import qualified WikipediaSpec
import qualified WritingSpec

main :: IO ()
main = getArgs >>= \case
  ["--source-server-fixture"] -> runSourceServer
  _ -> runSpecs

runSpecs :: IO ()
runSpecs = hspec $ do
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
  describe "Decision tree" TreeSpec.spec
  describe "Citations in outputs" CiteSpec.spec
  describe "Draft" DraftSpec.spec
  describe "Final document" FinalSpec.spec
  describe "Export" ExportSpec.spec
  describe "Wrap-up outputs" OutputsWiringSpec.spec
