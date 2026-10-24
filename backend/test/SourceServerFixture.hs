-- | Real HTTP/WebSocket/SQLite server in a child process, with an entirely
-- deterministic source seam. No production environment switch enables this.
module SourceServerFixture (runSourceServer) where

import Control.Exception (bracket)
import Control.Concurrent.STM (atomically, retry)
import qualified Data.Text as Text
import Drift.Api (api, server)
import Drift.Pipeline.Writing (templateEntry)
import Drift.Protocol (SourceKind (Article))
import Drift.Search.Types (SourceDraft (..), SourceRequest (..))
import Drift.Server.SessionActor (Pipelines (..), SourceSearch, newManagerWith, stopManager)
import Drift.Server.WebSocket (webSocketApp)
import Drift.Store.SQLite (closeStore, openStore)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets (defaultConnectionOptions)
import Servant (serve)
import System.Environment (getEnv)

runSourceServer :: IO ()
runSourceServer = do
  port <- read <$> getEnv "DRIFT_PORT"
  database <- getEnv "DRIFT_DB_PATH"
  let sources :: SourceSearch
      sources request emit = do
        let draft = SourceDraft Article (toWord request) Nothing
              ("https://example.org/" <> Text.toLower (toWord request)) Nothing Nothing
        emit draft
        emit draft -- callback duplicates must not become durable duplicates
      pipelines = Pipelines (\_ _ -> atomically retry) (Just templateEntry) (Just sources)
  bracket (openStore database) closeStore $ \store ->
    bracket (newManagerWith store pipelines) stopManager $ \manager ->
      run port (websocketsOr defaultConnectionOptions (webSocketApp manager)
        (serve api (server manager)))
