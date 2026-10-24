{-# LANGUAGE OverloadedStrings #-}

module Drift.Model.OpenAICompat
  ( OpenAISettings (..)
  , openAICompatibleProvider
  , openAIResponsesProvider
  , temperatureFor
  , chatCompletionPayload
  , responsesPayload
  , httpErrorMessage
  , parseChatCompletion
  , parseResponsesEvent
  , parseEmbeddingResponse
  , parseSseData
  ) where

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Data.IORef (newIORef, modifyIORef', readIORef)
import Data.List (sortOn)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Drift.Model.Provider
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

data OpenAISettings = OpenAISettings
  { openAIBaseUrl :: Text
  , openAIDefaultModel :: Text
  , openAIEmbeddingModel :: Maybe Text
  , openAIApiKey :: Maybe Text
  }
  deriving (Eq, Show)

openAICompatibleProvider :: OpenAISettings -> IO ModelProvider
openAICompatibleProvider settings = do
  manager <- newManager tlsManagerSettings
  let embeddingAction = fmap (embedTexts manager settings) (openAIEmbeddingModel settings)
  pure ModelProvider
    { providerName = "openai-compatible"
    , generate = generateStream manager settings
    , embed = embeddingAction
    }

openAIResponsesProvider :: OpenAISettings -> IO ModelProvider
openAIResponsesProvider settings = do
  manager <- newManager tlsManagerSettings
  pure ModelProvider
    { providerName = "openai-responses"
    , generate = generateResponsesStream manager settings
    , embed = Nothing
    }

generateStream :: Manager -> OpenAISettings -> GenRequest -> (Text -> IO ()) -> IO Text
generateStream manager settings request onChunk = do
  initial <- parseRequest (T.unpack (trimSlash (openAIBaseUrl settings) <> "/chat/completions"))
  let payload = chatCompletionPayload (openAIDefaultModel settings) request
      requestWithBody = initial
        { method = "POST"
        , requestHeaders = ("Content-Type", "application/json") : requestHeaders initial
        , requestBody = RequestBodyLBS (encode payload)
        , responseTimeout = responseTimeoutMicro 120000000
        }
      req = addAuth settings requestWithBody
  withResponse req manager $ \response -> do
    ensureStreamSuccess response
    output <- newIORef T.empty
    consumeSse (responseBody response) $ \jsonBytes ->
      case parseDelta jsonBytes of
        Left message -> ioError (userError (T.unpack message))
        Right Nothing -> pure ()
        Right (Just content) -> do
          onChunk content
          modifyIORef' output (<> content)
    readIORef output

generateResponsesStream :: Manager -> OpenAISettings -> GenRequest -> (Text -> IO ()) -> IO Text
generateResponsesStream manager settings request onChunk = do
  initial <- parseRequest (T.unpack (trimSlash (openAIBaseUrl settings) <> "/responses"))
  let payload = responsesPayload (openAIDefaultModel settings) request
      requestWithBody = initial
        { method = "POST"
        , requestHeaders = ("Content-Type", "application/json") : requestHeaders initial
        , requestBody = RequestBodyLBS (encode payload)
        , responseTimeout = responseTimeoutMicro 120000000
        }
      req = addAuth settings requestWithBody
  withResponse req manager $ \response -> do
    ensureStreamSuccess response
    output <- newIORef T.empty
    consumeSse (responseBody response) $ \jsonBytes ->
      case parseResponsesEvent jsonBytes of
        Left message -> ioError (userError (T.unpack message))
        Right Nothing -> pure ()
        Right (Just content) -> do
          onChunk content
          modifyIORef' output (<> content)
    readIORef output

-- | Sampling temperature for a divergence setting: 0.5 when focused, up to
-- 1.1 when the user asks for surprising associations.
temperatureFor :: Double -> Double
temperatureFor divergence = 0.5 + 0.6 * max 0 (min 1 divergence)

-- | Request body for @/chat/completions@; the request's model wins over the default.
chatCompletionPayload :: Text -> GenRequest -> Value
chatCompletionPayload defaultModel request =
  object $
    [ "model" .= requestModel defaultModel request
    , "messages" .= [object ["role" .= ("user" :: Text), "content" .= genPrompt request]]
    , "temperature" .= temperatureFor (genDivergence request)
    , "stream" .= True
    ]
      <> ["max_tokens" .= genMaxTokens request | genMaxTokens request > 0]

-- | Request body for @/responses@; the request's model wins over the default.
responsesPayload :: Text -> GenRequest -> Value
responsesPayload defaultModel request =
  object $
    [ "model" .= requestModel defaultModel request
    , "input" .= [object
        [ "role" .= ("user" :: Text)
        , "content" .= [object ["type" .= ("input_text" :: Text), "text" .= genPrompt request]]
        ]]
    , "temperature" .= temperatureFor (genDivergence request)
    , "stream" .= True
    ]
      <> ["max_output_tokens" .= genMaxTokens request | genMaxTokens request > 0]

requestModel :: Text -> GenRequest -> Text
requestModel defaultModel request = if T.null (genModel request) then defaultModel else genModel request

embedTexts :: Manager -> OpenAISettings -> Text -> [Text] -> IO [Embedding]
embedTexts _ _ _ [] = pure []
embedTexts manager settings model inputs = do
  initial <- parseRequest (T.unpack (trimSlash (openAIBaseUrl settings) <> "/embeddings"))
  let payload = object ["model" .= model, "input" .= inputs]
      requestWithBody = initial
        { method = "POST"
        , requestHeaders = ("Content-Type", "application/json") : requestHeaders initial
        , requestBody = RequestBodyLBS (encode payload)
        }
      req = addAuth settings requestWithBody
  response <- httpLbs req manager
  ensureSuccess (statusCode (responseStatus response)) (LBS.toStrict (LBS.take errorBodyLimit (responseBody response)))
  either (ioError . userError . T.unpack) pure (parseEmbeddingResponse (LBS.toStrict (responseBody response)))

addAuth :: OpenAISettings -> Request -> Request
addAuth settings request = case openAIApiKey settings of
  Nothing -> request
  Just key | T.null (T.strip key) -> request
           | otherwise -> request {requestHeaders = ("Authorization", BSC.pack ("Bearer " <> T.unpack key)) : requestHeaders request}

trimSlash :: Text -> Text
trimSlash = T.dropWhileEnd (== '/')

-- | How much of an error response body to keep in the error message.
errorBodyLimit :: Num a => a
errorBodyLimit = 500

-- | Fails with the status and the start of the response body, which is where
-- providers explain a 4xx (for example a model that rejects temperature).
-- Request headers, and so the API key, are never included.
ensureSuccess :: Int -> BS.ByteString -> IO ()
ensureSuccess code body
  | code >= 200 && code < 300 = pure ()
  | otherwise = ioError (userError (httpErrorMessage code body))

-- | 'ensureSuccess' for a streamed response: reads at most the first
-- 'errorBodyLimit' bytes of the body, only when the status is an error.
ensureStreamSuccess :: Response BodyReader -> IO ()
ensureStreamSuccess response = do
  let code = statusCode (responseStatus response)
  body <- if code >= 200 && code < 300 then pure BS.empty else LBS.toStrict <$> brReadSome (responseBody response) errorBodyLimit
  ensureSuccess code body

httpErrorMessage :: Int -> BS.ByteString -> String
httpErrorMessage code body =
  let excerpt = T.strip (decodeUtf8Lenient (BS.take errorBodyLimit body))
   in "OpenAI-compatible endpoint returned HTTP " <> show code <> if T.null excerpt then "" else ": " <> T.unpack excerpt

consumeSse :: BodyReader -> (BS.ByteString -> IO ()) -> IO ()
consumeSse reader onData = loop BS.empty []
  where
    loop pending current = do
      chunk <- brRead reader
      if BS.null chunk
        then flush pending current
        else do
          let (linesReady, rest) = splitLines (pending <> chunk)
          current' <- foldLines current linesReady
          loop rest current'
    foldLines current [] = pure current
    foldLines current (line : linesReady)
      | BS.null line = dispatch current >> foldLines [] linesReady
      | BSC.isPrefixOf ":" line = foldLines current linesReady
      | BSC.isPrefixOf "data:" line =
          let value = BSC.dropWhile (== ' ') (BS.drop 5 line)
           in foldLines (current <> [value]) linesReady
      | otherwise = foldLines current linesReady
    flush pending current = do
      let finalLines = if BS.null pending then [] else [stripCR pending]
      final <- foldLines current finalLines
      dispatch final
    dispatch [] = pure ()
    dispatch values = do
      let message = BS.intercalate "\n" values
      if message == "[DONE]" then pure () else onData message

splitLines :: BS.ByteString -> ([BS.ByteString], BS.ByteString)
splitLines input = go [] input
  where
    go acc bytes = case BSC.break (== '\n') bytes of
      (line, rest) | BS.null rest -> (reverse acc, line)
                   | otherwise -> go (stripCR line : acc) (BS.drop 1 rest)

stripCR :: BS.ByteString -> BS.ByteString
stripCR line = if BS.isSuffixOf "\r" line then BS.init line else line

parseSseData :: [Text] -> [Text]
parseSseData = foldr collect []
  where
    collect line rest
      | "data:" `T.isPrefixOf` line =
          let payload = T.strip (T.drop 5 line)
           in if payload == "[DONE]" then rest else payload : rest
      | otherwise = rest

parseChatCompletion :: BS.ByteString -> Either Text Text
parseChatCompletion bytes = do
  value <- decodeValue bytes
  content <- lookupPath ["choices", "0", "message", "content"] value
  case content of
    String text -> Right text
    _ -> Left "completion response did not contain text content"

parseEmbeddingResponse :: BS.ByteString -> Either Text [Embedding]
parseEmbeddingResponse bytes = do
  value <- decodeValue bytes
  dataValue <- lookupPath ["data"] value
  rows <- asArray dataValue
  indexed <- traverse readRow rows
  pure (map snd (sortOn fst indexed))
  where
    readRow row = do
      index <- case lookupPath ["index"] row of
        Left _ -> Right 0
        Right indexValue -> asInt indexValue
      embeddingValue <- lookupPath ["embedding"] row
      values <- asArray embeddingValue
      vector <- traverse asDouble values
      pure (index, vector)

parseDelta :: BS.ByteString -> Either Text (Maybe Text)
parseDelta bytes = do
  value <- decodeValue bytes
  case lookupPath ["choices", "0", "delta", "content"] value of
    Left _ -> Right Nothing
    Right (String text) -> Right (Just text)
    Right _ -> Right Nothing

parseResponsesEvent :: BS.ByteString -> Either Text (Maybe Text)
parseResponsesEvent bytes = do
  value <- decodeValue bytes
  case lookupPath ["type"] value of
    Right (String "response.output_text.delta") ->
      case lookupPath ["delta"] value of
        Right (String text) -> Right (Just text)
        _ -> Right Nothing
    _ -> Right Nothing

decodeValue :: BS.ByteString -> Either Text Value
decodeValue = either (Left . T.pack) Right . eitherDecodeStrict'

lookupPath :: [Text] -> Value -> Either Text Value
lookupPath [] value = Right value
lookupPath (part : rest) value = case value of
  Object fields -> maybe (Left ("missing JSON field: " <> part)) (lookupPath rest) (KM.lookup (Key.fromText part) fields)
  Array values -> case reads (T.unpack part) of
    [(index, "")] | index >= 0 -> maybe (Left "JSON array index out of bounds") (lookupPath rest) (atMay (toList values) index)
    _ -> Left "invalid JSON array index"
  _ -> Left "unexpected JSON value shape"

asArray :: Value -> Either Text [Value]
asArray (Array values) = Right (toList values)
asArray _ = Left "expected JSON array"

asInt :: Value -> Either Text Int
asInt (Number value) = Right (round value)
asInt _ = Left "expected JSON integer"

asDouble :: Value -> Either Text Double
asDouble (Number value) = Right (toRealFloat value)
asDouble _ = Left "embedding coordinate was not numeric"

atMay :: [a] -> Int -> Maybe a
atMay xs index = case drop index xs of
  value : _ -> Just value
  [] -> Nothing

