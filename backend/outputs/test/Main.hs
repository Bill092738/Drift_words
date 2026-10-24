module Main (main) where

import Test.Hspec (hspec)
import qualified TreeSpec

main :: IO ()
main = hspec TreeSpec.spec
