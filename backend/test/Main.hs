module Main (main) where

import qualified CitationsSpec
import qualified EntriesSpec
import qualified ProtocolSpec
import Test.Hspec (describe, hspec)
import qualified WritingSpec

main :: IO ()
main = hspec $ do
  describe "Protocol" ProtocolSpec.spec
  describe "Entries" EntriesSpec.spec
  describe "Citations" CitationsSpec.spec
  describe "Writing" WritingSpec.spec
