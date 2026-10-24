module Main (main) where

import Control.Exception (bracket)
import Drift.Api (api, server)
import Drift.Model.SessionMock (mockBranches)
import Drift.Server.SessionActor (newManager, stopManager)
import Drift.Server.WebSocket (webSocketApp)
import Drift.Store.SQLite (closeStore, openStore)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets (defaultConnectionOptions)
import Servant (serve)
import System.Environment (lookupEnv)
import System.IO (BufferMode (..), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  port <- maybe 8080 read <$> lookupEnv "DRIFT_PORT"
  databasePath <- maybe "drift.sqlite" id <$> lookupEnv "DRIFT_DB_PATH"
  putStrLn ("drift-server listening on http://localhost:" <> show port)
  putStrLn ("session database: " <> databasePath)
  bracket (openStore databasePath) closeStore $ \store ->
    bracket (newManager store mockBranches) stopManager $ \manager ->
      run port (websocketsOr defaultConnectionOptions (webSocketApp manager) (serve api (server manager)))
