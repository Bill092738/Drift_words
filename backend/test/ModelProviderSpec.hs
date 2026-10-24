{-# LANGUAGE OverloadedStrings #-}

module ModelProviderSpec (spec) where

import Control.Monad (forM_)
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Model.Config
import Drift.Model.Mock
import Drift.Model.OpenAICompat (parseChatCompletion, parseEmbeddingResponse, parseSseData)
import Drift.Model.Provider
import Test.Hspec

spec :: Spec
spec = do
  describe "mock provider" $ do
    it "streams chunks whose concatenation equals the returned text" $ do
      let provider = mockProvider
          request = GenRequest "ocean" "mock" 0.1 8
      chunks <- collectChunks provider request
      full <- generate provider request (const (pure ()))
      T.concat chunks `shouldBe` full
      chunks `shouldSatisfy` (not . null)

    it "returns deterministic, divergence-sensitive candidate sets" $ do
      let provider = mockProvider
          run divergence = generate provider (GenRequest "ocean" "mock" divergence 8) (const (pure ()))
      low <- run 0.1
      high <- run 0.9
      low `shouldNotBe` high
      low `shouldBe` low

    it "provides deterministic embeddings" $ do
      let provider = mockProvider
      case embed provider of
        Nothing -> expectationFailure "mock provider should expose embeddings"
        Just embedTexts -> do
          first <- embedTexts ["ocean", "tide"]
          second <- embedTexts ["ocean", "tide"]
          first `shouldBe` second
          length first `shouldBe` 2

  describe "provider role routing" $ do
    it "resolves a configured role to its provider" $ do
      let config = ModelConfig
            { providers = [("local", ProviderConfig OpenAICompatible "http://localhost:11434/v1" "model" Nothing Nothing)]
            , roles = [(BranchesRole, "local"), (EmbeddingsRole, "local")]
            }
      resolveRole config BranchesRole `shouldBe` Right "local"
      resolveRole config WritingRole `shouldBe` Left (MissingRole WritingRole)

    it "rejects a role that names an absent provider" $ do
      let config = ModelConfig {providers = [], roles = [(BranchesRole, "missing")]}
      resolveRole config BranchesRole `shouldBe` Left (UnknownProvider "missing")

    it "treats an optional role that is left out as absent, not as an error" $ do
      let local = ProviderConfig OpenAICompatible "http://localhost:11434/v1" "model" Nothing Nothing
          withoutEmbeddings = ModelConfig {providers = [("local", local)], roles = [(BranchesRole, "local")]}
          withEmbeddings = withoutEmbeddings {roles = [(BranchesRole, "local"), (EmbeddingsRole, "local")]}
          dangling = withoutEmbeddings {roles = [(EmbeddingsRole, "missing")]}
      resolveOptionalProvider withoutEmbeddings EmbeddingsRole `shouldBe` Right Nothing
      resolveOptionalProvider withEmbeddings EmbeddingsRole `shouldBe` Right (Just local)
      resolveOptionalProvider dangling EmbeddingsRole `shouldBe` Left (UnknownProvider "missing")

    it "loads the committed configs, with no mock embeddings behind a real model" $
      forM_ ["config.packycode.yaml", "config.codex-sale.yaml"] $ \path -> do
        loaded <- loadModelConfig path
        case loaded of
          Left err -> expectationFailure (path <> ": " <> T.unpack err)
          Right config -> resolveOptionalProvider config EmbeddingsRole `shouldBe` Right Nothing

  describe "OpenAI-compatible response parsing" $ do
    it "parses completion and embedding payloads" $ do
      parseChatCompletion "{\"choices\":[{\"message\":{\"content\":\"tide\"}}]}"
        `shouldBe` Right "tide"
      parseEmbeddingResponse "{\"data\":[{\"embedding\":[0.25,-0.5]}]}"
        `shouldBe` Right [[0.25, -0.5]]

    it "joins SSE data lines and ignores comments and done markers" $ do
      parseSseData [": keep-alive", "data: {\"choices\":[]}", "data: [DONE]"]
        `shouldBe` ["{\"choices\":[]}"]

collectChunks :: ModelProvider -> GenRequest -> IO [Text]
collectChunks provider request = do
  ref <- newIORef []
  _ <- generate provider request (\chunk -> modifyIORef' ref (<> [chunk]))
  readIORef ref
