module CitationsSpec (spec) where

import qualified Data.Set as Set
import qualified Data.Text as T
import Drift.Pipeline.Citations
import Drift.Protocol (SourceId (..))
import Test.Hspec
import Test.QuickCheck

known :: Set.Set SourceId
known = Set.fromList [SourceId 1, SourceId 2]

spec :: Spec
spec = do
  describe "source keys" $ do
    it "round-trip" $ property $ \(NonNegative n) ->
      parseSourceKey (sourceKey (SourceId n)) === Just (SourceId n)

    it "reject other keys" $
      map parseSourceKey ["src", "src1a", "doc1", "src-1"] `shouldBe` replicate 4 Nothing

  describe "groundCitations" $ do
    it "keeps known keys" $
      groundCitations known "Shannon defined it [@src1]."
        `shouldBe` Grounded "Shannon defined it [@src1]." [SourceId 1] []

    it "drops an invented key together with its space" $
      groundCitations known "Shannon defined it [@src9]."
        `shouldBe` Grounded "Shannon defined it." [] ["src9"]

    it "filters keys inside a group and accepts commas" $
      groundCitations known "See [@src2, @smith2020; @src1]."
        `shouldBe` Grounded "See [@src2; @src1]." [SourceId 2, SourceId 1] ["smith2020"]

    it "lists each source once, in order of first citation" $
      groundCitations known "a [@src2] b [@src1] c [@src2]"
        `shouldSatisfy` ((== [SourceId 2, SourceId 1]) . groundedCites)

    it "leaves brackets that are not citations alone" $
      groundCitations known "a [sic] b [@ x] c [@src1" `shouldBe` Grounded "a [sic] b [@ x] c [@src1" [] []

    it "never cites a source outside the known set" $
      property $ \(ns :: [Int]) (filler :: [Bool]) ->
        let keys = ["[@src" <> T.pack (show (abs n)) <> "]" | n <- ns]
            text = T.unwords (zipWith (\k b -> if b then k else "word") keys (filler <> repeat True))
            g = groundCitations known text
         in all (`Set.member` known) (groundedCites g)
              .&&. groundedCites (groundCitations known (groundedText g)) === groundedCites g
              .&&. droppedKeys (groundCitations known (groundedText g)) === []

  describe "stripCitations" $
    it "removes every citation group" $
      stripCitations "Noise [@src1] is unpredictable [@src9; @src2]." `shouldBe` "Noise is unpredictable."
