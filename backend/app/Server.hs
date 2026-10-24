module Main (main) where

import Drift.Api (api, server)
import Network.Wai.Handler.Warp (run)
import Servant (serve)
import System.Environment (lookupEnv)
import System.IO (BufferMode (..), hSetBuffering, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  port <- maybe 8080 read <$> lookupEnv "DRIFT_PORT"
  putStrLn ("drift-server listening on http://localhost:" <> show port)
  run port (serve api server)
