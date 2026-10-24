{-# LANGUAGE OverloadedRecordDot #-}

module BranchesSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Drift.Pipeline.Branches
import Test.Hspec
import Test.QuickCheck (property)

spec :: Spec
spec = do
  describe "streaming candidate parsing" $ do
    it "waits for delimiters and handles delimiters split across chunks" $ do
      let (parser1, first) = feedCandidateChunk emptyStreamParser "  1. Apple, ba"
          (parser2, second) = feedCandidateChunk parser1 "nana\n* Cherry"
      first `shouldBe` ["Apple"]
      second `shouldBe` ["banana"]
      finishCandidateStream parser2 `shouldBe` ["Cherry"]

    it "strips list and JSON punctuation without emitting empty candidates" $ do
      let (parser, parsed) = feedCandidateChunk emptyStreamParser "[\"apple\", , 'banana'; • cherry]\n"
      parsed <> finishCandidateStream parser `shouldBe` ["apple", "banana", "cherry"]

    it "rejects phrases instead of leaking prose as a candidate" $ do
      let (parser, parsed) = feedCandidateChunk emptyStreamParser "apple pie, pear\n"
      parsed <> finishCandidateStream parser `shouldBe` ["pear"]

  describe "normalization and filtering" $ do
    it "normalizes with NFKC, full case folding, and trimming" $ do
      normalizeWord "  Kｅｙ  " `shouldBe` "key"
      normalizeWord "Straße" `shouldBe` "strasse"

    it "removes normalized duplicates, chosen words, and exhausted repeats" $ do
      let context = BranchContext "origin" ["root", "origin"] 0.75 (Set.fromList ["APPLE"]) (Map.fromList [("BANANA", repeatCap 0.75)]) 4
      filterCandidates context [" Apple ", "pear", "PEAR", "banana", "plum"] `shouldBe` ["pear", "plum"]

    it "uses a repeat cap that never increases with divergence" $
      property $ \rawA rawB ->
        let a = clamp01 rawA
            b = clamp01 rawB
            (lower, higher) = if a <= b then (a, b) else (b, a)
         in repeatCap lower >= repeatCap higher

  describe "embedding distance and divergence" $ do
    it "computes cosine distance and rejects unusable vectors" $ do
      cosineDistance [1, 0] [1, 0] `shouldBe` Just 0
      cosineDistance [1, 0] [0, 1] `shouldBe` Just 1
      cosineDistance [1, 0] [-1, 0] `shouldBe` Just 2
      cosineDistance [] [] `shouldBe` Nothing
      cosineDistance [0, 0] [1, 0] `shouldBe` Nothing
      cosineDistance [1] [1, 0] `shouldBe` Nothing

    it "moves the target band farther away as divergence increases" $ do
      let (lowMin, lowMax) = divergenceBand 0.1
          (highMin, highMax) = divergenceBand 0.9
      lowMin `shouldSatisfy` (>= 0)
      lowMax `shouldSatisfy` (< highMin)
      highMax `shouldSatisfy` (<= 2)

  describe "candidate selection" $ do
    it "keeps candidates in the semantic band and applies deterministic MMR" $ do
      let candidates = [("near-a", Just [0.98, 0.20]), ("near-b", Just [0.97, 0.24]), ("diverse", Just [0.80, -0.60]), ("too-far", Just [-1, 0])]
          first = selectCandidates 2 0.1 (Just [1, 0]) candidates
      first `shouldBe` ["diverse", "near-b"]
      selectCandidates 2 0.1 (Just [1, 0]) candidates `shouldBe` first

    it "falls back to prompt order when embeddings are absent or malformed" $ do
      let wordsInOrder = [("alpha", Nothing), ("beta", Nothing), ("gamma", Nothing)]
          malformed = [("alpha", Just [1, 0]), ("beta", Just [1])]
      selectCandidates 2 0.8 Nothing wordsInOrder `shouldBe` ["alpha", "beta"]
      selectCandidates 2 0.8 (Just [1, 0]) malformed `shouldBe` ["alpha", "beta"]
    it "falls back to prompt order when no candidate lands in the divergence band" $ do
      let candidates = [("opposite", Just [-1, 0]), ("also-opposite", Just [-2, 0])]
      selectCandidates 2 0.1 (Just [1, 0]) candidates `shouldBe` ["opposite", "also-opposite"]

  describe "branch prompt" $ do
    it "contains the current word, root path, divergence, and output constraint" $ do
      let context = BranchContext "rain" ["cloud", "storm", "rain"] 0.7 Set.empty Map.empty 5
          prompt = buildBranchPrompt context
      T.isInfixOf "rain" prompt `shouldBe` True
      T.isInfixOf "cloud -> storm -> rain" prompt `shouldBe` True
      T.isInfixOf "0.7" prompt `shouldBe` True
      T.isInfixOf "one word per line" prompt `shouldBe` True

clamp01 :: Double -> Double
clamp01 = max 0 . min 1
