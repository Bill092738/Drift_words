module Main (main) where

import qualified CiteSpec
import qualified DraftSpec
import qualified FinalSpec
import Test.Hspec (hspec)
import qualified TreeSpec

main :: IO ()
main = hspec $ do
  TreeSpec.spec
  CiteSpec.spec
  DraftSpec.spec
  FinalSpec.spec
