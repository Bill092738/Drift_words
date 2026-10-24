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
  , resolveOptionalProvider
  , toOpenAISettings
  , createModelProvider
  , geminiBaseUrl
  ) where

import Control.Monad (when)
import Data.Aeson (FromJSON (..), Value (..), (.:), (.:?), (.!=), withObject)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import Drift.Model.Mock (mockProvider)
import Drift.Model.OpenAICompat (OpenAISettings (..), RequestOptions (..), defaultRequestOptions, openAICompatibleProvider, openAIResponsesProvider)
import Drift.Model.Provider (ModelProvider)
import System.Environment (lookupEnv)

data ProviderKind = OpenAICompatible | OpenAIResponses | Mock
  deriving (Eq, Show)

-- | 'CloudRole' makes the starting word cloud; it is optional.
data ProviderRole = BranchesRole | EmbeddingsRole | WritingRole | FinalRole | CloudRole
  deriving (Eq, Ord, Show, Enum, Bounded)

data ProviderConfig = ProviderConfig
  { providerKind :: ProviderKind
  , providerBaseUrl :: Text
  , providerModel :: Text
  , providerEmbeddingModel :: Maybe Text
  , providerApiKeyEnv :: Maybe Text
  , providerOptions :: RequestOptions
  -- ^ request shaping: reasoning effort, temperature, output limit, timeout
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

-- | Optional keys, all with the defaults of 'defaultRequestOptions':
--
-- > reasoning_effort: low        # sent as reasoning_effort; default: not sent
-- > send_temperature: false      # derive temperature from divergence; default true
-- > limit_output_tokens: false   # send the token budget as max_tokens; default true
-- > timeout_seconds: 60          # default 120
-- > concurrent_requests: true    # run prefetches in parallel; default false
--
-- @kind: gemini@ is the Gemini API's OpenAI-compatible endpoint with the
-- settings Gemini 3 models need: the base URL, the key in @GEMINI_API_KEY@,
-- @reasoning_effort: low@ (Gemini 3 cannot stop thinking), no temperature
-- (Google advises keeping the default), no output limit (it also counts
-- thinking tokens, so a small one returns an empty answer), and parallel
-- prefetches. Each can still be overridden.
instance FromJSON ProviderConfig where
  parseJSON = withObject "provider" $ \obj -> do
    kindText <- obj .: "kind"
    (kind, preset) <- case (kindText :: Text) of
      "mock" -> pure (Mock, Nothing)
      "openai-compatible" -> pure (OpenAICompatible, Nothing)
      "openai-responses" -> pure (OpenAIResponses, Nothing)
      "gemini" -> pure (OpenAICompatible, Just geminiPreset)
      other -> fail ("unsupported provider kind: " <> T.unpack other)
    let base = maybe defaultRequestOptions snd preset
    baseUrl <- obj .:? "base_url" .!= maybe "" (const geminiBaseUrl) preset
    model <- obj .:? "model" .!= "mock"
    embeddingModel <- obj .:? "embedding_model"
    apiKeyEnv <- maybe (obj .:? "api_key_env") (\(env, _) -> Just <$> obj .:? "api_key_env" .!= env) preset
    effort <- obj .:? "reasoning_effort" .!= reasoningEffort base
    temperature <- obj .:? "send_temperature" .!= sendTemperature base
    limit <- obj .:? "limit_output_tokens" .!= limitOutputTokens base
    timeout <- obj .:? "timeout_seconds" .!= timeoutSeconds base
    concurrent <- obj .:? "concurrent_requests" .!= concurrentRequests base
    when (timeout <= 0) (fail "timeout_seconds must be positive")
    pure (ProviderConfig kind baseUrl model embeddingModel apiKeyEnv (RequestOptions effort temperature limit timeout concurrent))
    where
      geminiPreset = ("GEMINI_API_KEY", RequestOptions (Just "low") False False 60 True)

-- | The Gemini API's OpenAI-compatible endpoint.
geminiBaseUrl :: Text
geminiBaseUrl = "https://generativelanguage.googleapis.com/v1beta/openai"


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

-- | Like 'resolveProvider' for a role that may be left out of the config, such
-- as embeddings: a missing role is 'Nothing', but a role naming an absent
-- provider is still an error.
resolveOptionalProvider :: ModelConfig -> ProviderRole -> Either ConfigError (Maybe ProviderConfig)
resolveOptionalProvider config role = case resolveProvider config role of
  Left (MissingRole _) -> Right Nothing
  other -> Just <$> other

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
    , openAIOptions = providerOptions config
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
roleFromText "cloud" = Just CloudRole
roleFromText _ = Nothing
