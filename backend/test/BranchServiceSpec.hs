{-# LANGUAGE OverloadedRecordDot #-}

module BranchServiceSpec (spec) where

import Control.Exception (bracket)
import Data.IORef
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Model.Mock (mockProvider)
import Drift.Model.Provider (ModelProvider (..))
import Drift.Pipeline.BranchService
import Drift.Pipeline.Branches
import Test.Hspec
import Test.QuickCheck (Positive (..), property, (===))

ctx :: Text -> [Text] -> BranchContext
ctx word chosen = BranchContext word [word] 0.2 (Set.fromList chosen) Map.empty 4

-- | A provider whose words carry the number of the call that produced them.
countingProvider :: IORef Int -> ModelProvider
countingProvider calls =
  ModelProvider
    { providerName = "counting"
    , generate = \_ onChunk -> do
        n <- atomicModifyIORef' calls (\c -> (c + 1, c + 1))
        let out = T.intercalate "\n" [w <> T.pack (show n) | w <- ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"]]
        mapM_ onChunk (T.chunksOf 5 out)
        pure out
    , embed = Nothing
    }

withService :: ModelProvider -> Maybe ([Text] -> IO [Embedding]) -> (BranchService Int -> IO a) -> IO a
withService provider embedder = bracket (newBranchService provider "" embedder) closeBranchService

collect :: IO (IORef [Text], Text -> IO ())
collect = do
  ref <- newIORef []
  pure (ref, \w -> modifyIORef' ref (<> [w]))

spec :: Spec
spec = describe "branch service" $ do
  it "streams exactly the filtered prefix, however the output is split" $
    property $ \(Positive a) (Positive b) ->
      let parsed = ["Tide", "tide", "moon", "ocean", "salt", "Moon", "wave", "reef", "shore"]
          c = (ctx "ocean" ["salt"]) {branchCount = 4}
          i = min a (length parsed)
          j = min (i + b) (length parsed)
          steps = [take i parsed, take j parsed, parsed]
          streamed = concat (zipWith (streamFiltered c) ([] : steps) steps)
       in streamed === take 4 (filterCandidates c parsed)

  it "generates on a miss, streaming the same words it selects without embeddings" $
    withService mockProvider Nothing $ \service -> do
      (streamed, onWord) <- collect
      result <- branchesFor service Nothing (ctx "ocean" ["tide"]) onWord
      sent <- readIORef streamed
      result `shouldBe` Right sent
      length sent `shouldBe` 4
      sent `shouldNotContain` ["tide"]

  it "reuses a prefetch without calling the model again, filtered against the state at pick time" $ do
    calls <- newIORef 0
    withService (countingProvider calls) Nothing $ \service -> do
      prefetchBranches service 7 (ctx "ocean" [])
      (streamed, onWord) <- collect
      result <- branchesFor service (Just 7) (ctx "ocean" ["beta1"]) onWord
      readIORef calls `shouldReturn` 1
      result `shouldBe` Right ["alpha1", "gamma1", "delta1", "epsilon1"]
      readIORef streamed `shouldReturn` ["alpha1", "gamma1", "delta1", "epsilon1"]

  it "cancels every prefetch on a request without a key, so a later pick generates afresh" $ do
    calls <- newIORef 0
    withService (countingProvider calls) Nothing $ \service -> do
      prefetchBranches service 7 (ctx "ocean" [])
      _ <- branchesFor service Nothing (ctx "moon" []) (const (pure ()))
      result <- branchesFor service (Just 7) (ctx "ocean" []) (const (pure ()))
      latest <- readIORef calls
      fmap (map (T.takeWhileEnd (`elem` ['0' .. '9']))) result `shouldBe` Right (replicate 4 (T.pack (show latest)))

  it "falls back to the model's order when the embedding call fails" $
    withService mockProvider (Just (\_ -> ioError (userError "embeddings down"))) $ \service -> do
      result <- branchesFor service Nothing (ctx "ocean" []) (const (pure ()))
      fmap length result `shouldBe` Right 4

  it "selects with embeddings when they are available" $ do
    let raw = RawBranches ["near", "far", "mid"] (Just [1, 0]) (Map.fromList [("near", [0.98, 0.2]), ("far", [0, 1]), ("mid", [0.5, 0.86])])
    finalizeBranches (ctx "x" []) {branchCount = 2, divergence = 0.1} raw `shouldBe` ["near", "mid"]
