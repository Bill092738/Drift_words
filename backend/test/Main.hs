module Main (main) where

import qualified ProtocolSpec
import Test.Hspec (hspec)

main :: IO ()
main = hspec ProtocolSpec.spec
