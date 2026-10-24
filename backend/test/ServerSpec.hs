{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ServerSpec (spec) where

import Control.Exception (SomeException, bracket, try)
import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Drift.Api
import Drift.Model.SessionMock (mockBranches)
import Drift.Protocol (CandidateId (..), ClientMsg (..), Event (..), ServerMsg (..), Stamped (..), Lang (..))
import Drift.Server.SessionActor (Manager, stopManager)
import qualified Drift.Server.SessionActor as Actor
import Drift.Server.WebSocket (webSocketApp)
import Drift.Store.SQLite (closeStore, openStore)
import Network.HTTP.Client
  ( Request (..), RequestBody (..), Response, defaultManagerSettings
  , httpLbs, newManager, parseRequest, responseBody, responseStatus )
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Servant (serve)
import Network.WebSockets
  ( Connection, DataMessage (..), defaultConnectionOptions, receiveData
  , receiveDataMessage, runClient, sendBinaryData, sendTextData )
import qualified Network.WebSockets as WebSockets
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "HTTP and WebSocket server" $ do
  it "keeps the health endpoint plain text and creates sessions in both languages" $
    withBackend $ \port _ -> do
      health <- httpRequest port "GET" "/api/health" LazyByteString.empty
      statusCode (responseStatus health) `shouldBe` 200
      responseBody health `shouldBe` "ok"
      en <- createSession port "en"
      zh <- createSession port "zh"
      sessionId en `shouldNotBe` sessionId zh

  it "rejects invalid or missing language fields" $ withBackend $ \port _ -> do
    invalid <- httpRequest port "POST" "/api/sessions" "{\"lang\":\"fr\"}"
    missing <- httpRequest port "POST" "/api/sessions" "{}"
    statusCode (responseStatus invalid) `shouldSatisfy` (>= 400)
    statusCode (responseStatus missing) `shouldSatisfy` (>= 400)

  it "rejects unknown sessions during the WebSocket handshake" $ withBackend $ \port _ -> do
    result <- try (runClient "127.0.0.1" (fromIntegral port) "/api/sessions/missing/ws" (const (pure ())))
      :: IO (Either SomeException ())
    result `shouldSatisfy` either (const True) (const False)

  it "sends initial history, streamed and sealed events, and matching rejections" $
    withBackend $ \port _ -> do
      created <- createSession port "en"
      withSession port (sessionId created) $ \connection -> do
        initial <- receiveServerMessage connection
        case initial of
          Events [Stamped 1 _ (CloudSpawned En _)] -> pure ()
          other -> expectationFailure ("Unexpected initial history: " <> show other)
        sendTextData connection (encode (ClientMsg 7 (StartWithWord "root")))
        generated <- collectThroughSeal connection
        let committed = concatMap eventsOf generated
            eventKinds = map event committed
            sequences = map seq committed
        length committed `shouldSatisfy` (>= 4)
        sequences `shouldBe` [2 .. fromIntegral (length committed + 1)]
        eventKinds `shouldSatisfy` any isNodeChosen
        eventKinds `shouldSatisfy` any isCandidateStream
        eventKinds `shouldSatisfy` any isBranchesSeal
        sendTextData connection ("{\"req\":91,\"command\":{\"type\":\"NoSuchCommand\"}}" :: ByteString.ByteString)
        receiveServerMessage connection `shouldReturn` Rejected 91 "Invalid client message."
        sendTextData connection (encode (ClientMsg 92 (Pick (CandidateId 999999))))
        receiveServerMessage connection >>= \case
          Rejected requestId _ -> requestId `shouldBe` 92
          other -> expectationFailure ("Expected a matching rejection, got " <> show other)

  it "closes malformed JSON with protocol error without changing the session" $
    withBackend $ \port _ -> do
      created <- createSession port "en"
      withSession port (sessionId created) $ \connection -> do
        _ <- receiveServerMessage connection
        sendTextData connection ("{\"req\":3,\"command\":" :: ByteString.ByteString)
        expectProtocolClose connection
      withSession port (sessionId created) $ \connection -> do
        receiveServerMessage connection >>= \case
          Events [Stamped 1 _ (CloudSpawned En _)] -> pure ()
          other -> expectationFailure ("Malformed message changed session history: " <> show other)

  it "closes binary frames with protocol error" $ withBackend $ \port _ -> do
    created <- createSession port "zh"
    withSession port (sessionId created) $ \connection -> do
      _ <- receiveServerMessage connection
      sendBinaryData connection ("not JSON" :: ByteString.ByteString)
      expectProtocolClose connection

  it "broadcasts the same ordered event batch to concurrent clients" $
    withBackend $ \port _ -> do
      created <- createSession port "en"
      withSession port (sessionId created) $ \first ->
        withSession port (sessionId created) $ \second -> do
          firstSnapshot <- receiveServerMessage first
          secondSnapshot <- receiveServerMessage second
          secondSnapshot `shouldBe` firstSnapshot
          sendTextData first (encode (ClientMsg 1 (SetDivergence 0.4)))
          firstEvent <- receiveServerMessage first
          secondEvent <- receiveServerMessage second
          firstEvent `shouldBe` secondEvent
          firstEvent `shouldSatisfy` \case
            Events [Stamped 2 _ (DivergenceSet 0.4)] -> True
            _ -> False

httpRequest :: Int -> ByteString.ByteString -> String -> LazyByteString.ByteString -> IO (Network.HTTP.Client.Response LazyByteString.ByteString)
httpRequest port method path body = do
  manager <- newManager defaultManagerSettings
  request <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  httpLbs request
    { method = method
    , requestBody = RequestBodyLBS body
    , requestHeaders = [("Content-Type", "application/json")]
    } manager

createSession :: Int -> Text -> IO CreateSessionResponse
createSession port language = do
  response <- httpRequest port "POST" "/api/sessions"
    (LazyByteString.fromStrict (TextEncoding.encodeUtf8 ("{\"lang\":\"" <> language <> "\"}")))
  case eitherDecode (responseBody response) of
    Left failure -> expectationFailure ("Invalid create response: " <> failure) >> fail failure
    Right value -> pure value

withSession :: Int -> Text -> (Connection -> IO a) -> IO a
withSession port identifier = runClient "127.0.0.1" (fromIntegral port)
  ("/api/sessions/" <> Text.unpack identifier <> "/ws")

receiveServerMessage :: Connection -> IO ServerMsg
receiveServerMessage connection = do
  result <- timeout 5000000 (receiveData connection :: IO LazyByteString.ByteString)
  case result of
    Nothing -> fail "Timed out waiting for a server message"
    Just payload -> case eitherDecode payload of
      Left failure -> fail ("Invalid server JSON: " <> failure)
      Right message -> pure message

collectThroughSeal :: Connection -> IO [ServerMsg]
collectThroughSeal connection = go []
  where
    go messages
      | length messages >= 8 = fail "No branch seal arrived within eight messages"
      | otherwise = do
          message <- receiveServerMessage connection
          let next = messages <> [message]
          if any isBranchesSeal (concatMap eventsOf next)
            then pure next
            else go next

eventsOf :: ServerMsg -> [Stamped]
eventsOf (Events values) = values
eventsOf Rejected {} = []

isNodeChosen, isCandidateStream, isBranchesSeal :: Stamped -> Bool
isNodeChosen (Stamped _ _ NodeChosen {}) = True
isNodeChosen _ = False
isCandidateStream (Stamped _ _ CandidateStreamed {}) = True
isCandidateStream _ = False
isBranchesSeal (Stamped _ _ BranchesOffered {}) = True
isBranchesSeal _ = False

expectProtocolClose :: Connection -> IO ()
expectProtocolClose connection = do
  result <- timeout 5000000 (try (receiveDataMessage connection) :: IO (Either WebSockets.CloseRequest DataMessage))
  case result of
    Nothing -> expectationFailure "Timed out waiting for protocol close"
    Just (Left (WebSockets.CloseRequest code _)) -> code `shouldBe` 1002
    Just (Right _) -> expectationFailure "Expected a WebSocket protocol close"

withBackend :: (Int -> Manager -> IO a) -> IO a
withBackend action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
  bracket (Actor.newManager store mockBranches) stopManager $ \manager ->
    testWithApplication (pure (websocketsOr defaultConnectionOptions (webSocketApp manager) (serve api (server manager))))
      (\port -> action port manager)

withDatabase :: (FilePath -> IO a) -> IO a
withDatabase action = bracket createDatabase removeFile action
  where
    createDatabase = do
      directory <- getTemporaryDirectory
      (path, handle) <- openTempFile directory "drift-server-spec.sqlite"
      hClose handle
      removeFile path
      pure path
