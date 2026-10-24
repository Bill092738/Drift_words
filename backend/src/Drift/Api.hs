{-# LANGUAGE OverloadedRecordDot #-}
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
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Control.Monad.IO.Class (liftIO)
import Drift.Domain.Types (SessionId (..))
import Drift.Output.Export (Exported (..), docKindFromText, exportDocument, formatFromText)
import Drift.Protocol (Lang)
import Drift.Server.SessionActor (Manager, StoredOutputs (..), createManagedSession, storedOutputs)
import Network.HTTP.Types (Status, status200, status400, status404)
import Network.Wai (Response, responseLBS)
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
  :<|> "api" :> "sessions" :> Capture "id" Text :> "export" :> Capture "doc" Text :> Capture "format" Text :> Raw
    -- ^ @GET \/api\/sessions\/:id\/export\/{tree,draft,final}\/{md,html,docx}@: a download of
    -- one of the wrap-up outputs, once the session has them

api :: Proxy Api
api = Proxy

server :: Manager -> Server Api
server manager = health :<|> create :<|> exportOutputs manager
  where
    health = pure "ok"
    create request = do
      SessionId identifier <- liftIO (createManagedSession manager (lang request))
      pure (CreateSessionResponse identifier)

-- | A wrap-up output as a file. The file names are fixed by the document and the
-- format, never taken from the request.
exportOutputs :: Manager -> Text -> Text -> Text -> Tagged Handler Application
exportOutputs manager identifier doc format = Tagged $ \_ reply ->
  case (docKindFromText doc, formatFromText format) of
    (Just kind, Just fmt) -> do
      stored <- storedOutputs manager (SessionId identifier)
      reply $ case stored of
        OutputsStored outputs ->
          let file = exportDocument kind fmt outputs
           in responseLBS
                status200
                [ ("Content-Type", TE.encodeUtf8 file.contentType)
                , ("Content-Disposition", "attachment; filename=\"" <> TE.encodeUtf8 file.fileName <> "\"")
                , ("Cache-Control", "no-store")
                ]
                file.bytes
        OutputsNotReady -> plain status404 "The outputs of this session are not ready yet."
        NoSuchSession -> plain status404 "That session does not exist."
    _ -> reply (plain status400 "Unknown document or format. Use tree, draft or final, and md, html or docx.")
  where
    plain :: Status -> LBS.ByteString -> Response
    plain status = responseLBS status [("Content-Type", "text/plain; charset=utf-8")]
