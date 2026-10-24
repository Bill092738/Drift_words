{-# LANGUAGE OverloadedStrings #-}

module Drift.Model.Config
  ( ProviderKind (..)
  , ProviderRole (..)
  , ProviderConfig (..)
  , ModelConfig (..)
  , ConfigError (..)
  , loadModelConfig
  , resolveRole
  , resolveProvider
  , toOpenAISettings
  , createModelProvider
  ) where

import Data.Aeson (FromJSON (..), Value (..), (.:), (.:?), (.!=), withObject)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import Drift.Model.Mock (mockProvider)
import Drift.Model.OpenAICompat (OpenAISettings (..), openAICompatibleProvider, openAIResponsesProvider)
import Drift.Model.Provider (ModelProvider)
import System.Environment (lookupEnv)

data ProviderKind = OpenAICompatible | OpenAIResponses | Mock
  deriving (Eq, Show)

data ProviderRole = BranchesRole | EmbeddingsRole | WritingRole | FinalRole
  deriving (Eq, Ord, Show, Enum, Bounded)

data ProviderConfig = ProviderConfig
  { providerKind :: ProviderKind
  , providerBaseUrl :: Text
  , providerModel :: Text
  , providerEmbeddingModel :: Maybe Text
  , providerApiKeyEnv :: Maybe Text
  }
  deriving (Eq, Show)

data ModelConfig = ModelConfig
  { providers :: [(Text, ProviderConfig)]
  , roles :: [(ProviderRole, Text)]
  }
  deriving (Eq, Show)

data ConfigError = MissingRole ProviderRole | UnknownProvider Text
  deriving (Eq, Show)

data ConfigFile = ConfigFile [(Text, ProviderConfig)] [(ProviderRole, Text)]

instance FromJSON ConfigFile where
  parseJSON = withObject "model config" $ \root -> do
    providerValue <- root .: "providers"
    roleValue <- root .: "roles"
    providerRows <- withObject "providers" (traverse parseProvider . KM.toList) providerValue
    roleRows <- withObject "roles" (traverse parseRole . KM.toList) roleValue
    pure (ConfigFile providerRows roleRows)
    where
      parseProvider (key, value) = do
        config <- parseJSON value
        pure (Key.toText key, config)
      parseRole (key, String value) = case roleFromText (Key.toText key) of
        Nothing -> fail ("unknown model role: " <> T.unpack (Key.toText key))
        Just role -> pure (role, value)
      parseRole (key, _) = fail ("model role must be a string: " <> T.unpack (Key.toText key))

instance FromJSON ProviderConfig where
  parseJSON = withObject "provider" $ \obj -> do
    kindText <- obj .: "kind"
    kind <- case (kindText :: Text) of
      "mock" -> pure Mock
      "openai-compatible" -> pure OpenAICompatible
      "openai-responses" -> pure OpenAIResponses
      other -> fail ("unsupported provider kind: " <> T.unpack other)
    baseUrl <- obj .:? "base_url" .!= ""
    model <- obj .:? "model" .!= "mock"
    embeddingModel <- obj .:? "embedding_model"
    apiKeyEnv <- obj .:? "api_key_env"
    pure (ProviderConfig kind baseUrl model embeddingModel apiKeyEnv)

loadModelConfig :: FilePath -> IO (Either Text ModelConfig)
loadModelConfig path = do
  decoded <- Yaml.decodeFileEither path
  pure $ case decoded of
    Left err -> Left (T.pack (Yaml.prettyPrintParseException err))
    Right (ConfigFile ps rs) -> Right (ModelConfig ps rs)

resolveRole :: ModelConfig -> ProviderRole -> Either ConfigError Text
resolveRole config role = case lookup role (roles config) of
  Nothing -> Left (MissingRole role)
  Just name | any ((== name) . fst) (providers config) -> Right name
            | otherwise -> Left (UnknownProvider name)

resolveProvider :: ModelConfig -> ProviderRole -> Either ConfigError ProviderConfig
resolveProvider config role = do
  name <- resolveRole config role
  maybe (Left (UnknownProvider name)) Right (lookup name (providers config))

toOpenAISettings :: ProviderConfig -> IO OpenAISettings
toOpenAISettings config = do
  key <- case providerApiKeyEnv config of
    Nothing -> pure Nothing
    Just envName -> fmap (fmap T.pack) (lookupEnv (T.unpack envName))
  pure OpenAISettings
    { openAIBaseUrl = providerBaseUrl config
    , openAIDefaultModel = providerModel config
    , openAIEmbeddingModel = providerEmbeddingModel config
    , openAIApiKey = key
    }

createModelProvider :: ProviderConfig -> IO ModelProvider
createModelProvider config = case providerKind config of
  Mock -> pure mockProvider
  OpenAICompatible -> toOpenAISettings config >>= openAICompatibleProvider
  OpenAIResponses -> toOpenAISettings config >>= openAIResponsesProvider

roleFromText :: Text -> Maybe ProviderRole
roleFromText "branches" = Just BranchesRole
roleFromText "embeddings" = Just EmbeddingsRole
roleFromText "writing" = Just WritingRole
roleFromText "final" = Just FinalRole
roleFromText _ = Nothing
