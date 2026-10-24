{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

-- | HTTP endpoints served beside the session WebSocket.
module Drift.Api
  ( Api
  , CreateSessionRequest (..)
  , CreateSessionResponse (..)
  , api
  , server
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Text (Text)
import Control.Monad.IO.Class (liftIO)
import Drift.Domain.Types (SessionId (..))
import Drift.Protocol (Lang)
import Drift.Server.SessionActor (Manager, createManagedSession)
import Servant

data CreateSessionRequest = CreateSessionRequest
  { lang :: Lang
  } deriving (Eq, Show)

instance FromJSON CreateSessionRequest where
  parseJSON = withObject "CreateSessionRequest" $ \value ->
    CreateSessionRequest <$> value .: "lang"

data CreateSessionResponse = CreateSessionResponse
  { sessionId :: Text
  } deriving (Eq, Show)

instance ToJSON CreateSessionResponse where
  toJSON response = object ["sessionId" .= sessionId response]

instance FromJSON CreateSessionResponse where
  parseJSON = withObject "CreateSessionResponse" $ \value ->
    CreateSessionResponse <$> value .: "sessionId"

type Api =
       "api" :> "health" :> Get '[PlainText] Text
  :<|> "api" :> "sessions" :> ReqBody '[JSON] CreateSessionRequest :> Post '[JSON] CreateSessionResponse

api :: Proxy Api
api = Proxy

server :: Manager -> Server Api
server manager = health :<|> create
  where
    health = pure "ok"
    create request = do
      SessionId identifier <- liftIO (createManagedSession manager (lang request))
      pure (CreateSessionResponse identifier)
