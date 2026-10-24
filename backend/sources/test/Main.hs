module Main (main) where

import qualified CslSpec
import qualified LiveSpec
import qualified OpenAlexSpec
import qualified PipelineSpec
import qualified RelevanceSpec
import Test.Hspec (hspec)
import qualified TextSpec
import qualified WikipediaSpec

main :: IO ()
main = hspec $ do
  TextSpec.spec
  WikipediaSpec.spec
  OpenAlexSpec.spec
  CslSpec.spec
  RelevanceSpec.spec
  PipelineSpec.spec
  LiveSpec.spec
