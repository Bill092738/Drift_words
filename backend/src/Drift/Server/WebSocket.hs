{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | WebSocket transport for the protocol event stream.
module Drift.Server.WebSocket
  ( webSocketApp
  ) where

import Control.Concurrent.Async (race_, withAsync, waitAnyCatch)
import Control.Concurrent.STM
  ( TMVar, TQueue, atomically, newEmptyTMVarIO, newTQueueIO, putTMVar, readTQueue
  , takeTMVar, writeTQueue )
import Control.Exception (SomeException, catch, finally, onException, try)
import Control.Monad (forever, void)
import Data.Aeson (Result (..), Value (..), eitherDecode, encode, fromJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as TextEncoding
import Drift.Domain.Types (SessionId (..))
import Drift.Protocol (ClientMsg (..), ServerMsg (..))
import Drift.Server.SessionActor
  ( Manager, Subscription, receive, submit, subscribeSession, unsubscribe )
import Network.WebSockets
  ( DataMessage (..), PendingConnection, ServerApp, acceptRequest, pendingRequest
  , receiveDataMessage, rejectRequest, requestPath, sendCloseCode, sendTextData
  )
import qualified Network.WebSockets as WebSockets

webSocketApp :: Manager -> ServerApp
webSocketApp manager pending = case sessionPath (requestPath (pendingRequest pending)) of
  Nothing -> rejectRequest pending "Invalid WebSocket path"
  Just sid -> subscribeSession manager sid >>= \case
    Left _ -> rejectRequest pending "Unknown session"
    Right subscription -> do
      connection <- acceptRequest pending `onException` unsubscribe subscription
      serveConnection connection subscription `finally` unsubscribe subscription

sessionPath :: ByteString.ByteString -> Maybe SessionId
sessionPath raw = case ByteString.split 47 raw of
  ["", "api", "sessions", identifier, "ws"]
    | not (ByteString.null identifier) ->
        case TextEncoding.decodeUtf8' identifier of
          Left _ -> Nothing
          Right value -> Just (SessionId value)
  _ -> Nothing

data Outbound = SendMessage ServerMsg | CloseForProtocolError (TMVar ())

serveConnection :: WebSockets.Connection -> Subscription -> IO ()
serveConnection connection subscription = do
  outgoing <- newTQueueIO
  -- subscribeSession only returns after its serialized Join delivered this
  -- snapshot. Queue it before starting the reader or event-forwarding task.
  initial <- receive subscription
  atomically (writeTQueue outgoing (SendMessage initial))
  let writer = atomically (readTQueue outgoing) >>= \case
        SendMessage serverMessage -> sendTextData connection (encode serverMessage) >> writer
        CloseForProtocolError acknowledged -> do
          sendCloseCode connection 1002 ("Invalid WebSocket message" :: Text)
          let waitForPeer = receiveDataMessage connection >> waitForPeer
          void (try (waitForPeer `catch` \(_ :: SomeException) -> pure ()) :: IO (Either SomeException ()))
          atomically (putTMVar acknowledged ())
      relay = forever $ receive subscription >>= atomically . writeTQueue outgoing . SendMessage
      reader = receiveLoop outgoing
      receiveLoop queue = receiveDataMessage connection >>= \case
        Text payload _ -> case eitherDecode payload of
          Right message -> submit subscription message >> receiveLoop queue
          Left _ -> case reliableRequestId payload of
            Just requestId -> do
              atomically $ writeTQueue queue (SendMessage (Rejected requestId "Invalid client message."))
              receiveLoop queue
            Nothing -> closeProtocol queue
        Binary _ -> closeProtocol queue
  withAsync writer $ \writerTask -> withAsync relay $ \relayTask ->
    race_ reader (void (waitAnyCatch [writerTask, relayTask]))

reliableRequestId :: LazyByteString.ByteString -> Maybe Int
reliableRequestId payload = case eitherDecode payload of
  Right (Object objectValue) -> case KeyMap.lookup "req" objectValue of
    Just value -> case fromJSON value of
      Success requestId -> Just requestId
      Error _ -> Nothing
    Nothing -> Nothing
  _ -> Nothing

closeProtocol :: TQueue Outbound -> IO ()
closeProtocol queue = do
  acknowledged <- newEmptyTMVarIO
  atomically (writeTQueue queue (CloseForProtocolError acknowledged))
  atomically (takeTMVar acknowledged)
