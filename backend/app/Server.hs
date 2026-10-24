-- | drift-server: the session engine over HTTP and WebSocket, plus the built
-- frontend.
--
-- Environment:
--
-- * @DRIFT_PORT@ (default 8080) and @DRIFT_DB_PATH@ (default drift.sqlite).
-- * @DRIFT_CONFIG@: a model configuration such as config.example.yaml. Its
--   @branches@ role generates the rings, and its optional @embeddings@ role
--   drives divergence selection. Without it the server uses the deterministic
--   offline vocabulary ("Drift.Model.SessionMock"), which needs no model.
-- * @DRIFT_WRITING@: set to 0 to disable sidebar entries. By default each
--   non-root edge receives a deterministic template entry, without a model.
-- * @DRIFT_PREFETCH@: set to 0 to turn off speculative prefetch of the next
--   rings (on by default; it costs one extra model call per offered word).
-- * @DRIFT_STATIC_DIR@: the built frontend to serve at @/@ (default
--   ../frontend/dist, when it exists). Unknown paths get index.html, so
--   client-side pages such as /playground load too.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (when)
import qualified Data.Text as T
import Drift.Api (api, server)
import Drift.Model.Config
import Drift.Model.Provider (ModelProvider (..))
import Drift.Model.SessionMock (BranchGenerator, mockBranches)
import Drift.Pipeline.BranchService (closeBranchService, newBranchService)
import Drift.Pipeline.SessionBranches (liveBranches)
import Drift.Pipeline.Writing (templateEntry)
import Drift.Server.SessionActor (Pipelines (..), newManagerWith, stopManager)
import Drift.Server.WebSocket (webSocketApp)
import Drift.Store.SQLite (closeStore, openStore)
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, pathInfo, responseFile, responseLBS)
import Network.Wai.Application.Static (defaultWebAppSettings, ss404Handler, staticApp)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets (defaultConnectionOptions)
import Servant (serve)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  port <- maybe 8080 read <$> lookupEnv "DRIFT_PORT"
  databasePath <- maybe "drift.sqlite" id <$> lookupEnv "DRIFT_DB_PATH"
  configPath <- lookupEnv "DRIFT_CONFIG"
  writing <- (/= Just "0") <$> lookupEnv "DRIFT_WRITING"
  prefetch <- (/= Just "0") <$> lookupEnv "DRIFT_PREFETCH"
  staticDir <- maybe "../frontend/dist" id <$> lookupEnv "DRIFT_STATIC_DIR"
  frontend <- frontendApp staticDir
  withGenerator configPath prefetch $ \generator -> do
    putStrLn (if writing then "writing: deterministic template" else "writing: disabled")
    putStrLn ("drift-server listening on http://localhost:" <> show port)
    putStrLn ("session database: " <> databasePath)
    bracket (openStore databasePath) closeStore $ \store ->
      bracket (newManagerWith store (Pipelines generator (if writing then Just templateEntry else Nothing) Nothing)) stopManager $ \manager -> do
        let backend = serve api (server manager)
            app request respond = case pathInfo request of
              "api" : _ -> backend request respond
              _ -> frontend request respond
        run port (websocketsOr defaultConnectionOptions (webSocketApp manager) app)

-- | The branch generator for the configured model, or the offline mock.
-- Configuration errors stop the server at start, not at the first pick.
withGenerator :: Maybe FilePath -> Bool -> (BranchGenerator -> IO a) -> IO a
withGenerator Nothing _ action = do
  putStrLn "branches: offline mock vocabulary (set DRIFT_CONFIG to use a model)"
  action mockBranches
withGenerator (Just path) prefetch action = do
  config <- loadModelConfig path >>= either (die . (("cannot read " <> path <> ": ") <>) . T.unpack) pure
  branchConfig <- either (die . (("model config " <> path <> ": ") <>) . show) pure (resolveProvider config BranchesRole)
  embeddingConfig <- either (die . (("model config " <> path <> ": ") <>) . show) pure (resolveOptionalProvider config EmbeddingsRole)
  provider <- createModelProvider branchConfig
  embedder <- case embeddingConfig of
    Nothing -> Nothing <$ putStrLn "embeddings: none (rings keep the model's order)"
    Just embeddingProvider -> do
      when (providerKind embeddingProvider == Mock && providerKind branchConfig /= Mock) $
        hPutStrLn stderr "warning: mock embeddings carry no meaning; divergence selection will be random"
      model <- createModelProvider embeddingProvider
      putStrLn ("embeddings: " <> T.unpack (providerName model))
      pure (embed model)
  -- Names only: the API key is never printed.
  putStrLn
    ( "branches: " <> T.unpack (providerName provider) <> " " <> T.unpack (providerModel branchConfig)
        <> " at " <> T.unpack (providerBaseUrl branchConfig)
        <> (if prefetch then ", with prefetch" else ", no prefetch")
    )
  bracket (newBranchService provider (providerModel branchConfig) embedder) closeBranchService $ \service ->
    action (liveBranches prefetch service)

-- | Serves the built frontend, with index.html for every path that is not a
-- file. Without a build, it answers with a hint instead.
frontendApp :: FilePath -> IO Application
frontendApp dir = do
  let index = dir </> "index.html"
  built <- doesFileExist index
  if not built
    then do
      putStrLn ("frontend: no build in " <> dir <> " (run `pnpm build` in frontend/, or use `make dev`)")
      pure $ \_ respond ->
        respond (responseLBS status404 [("Content-Type", "text/plain")] "No frontend build. Run `pnpm build` in frontend/, or use `make dev`.\n")
    else do
      putStrLn ("frontend: serving " <> dir)
      -- A missing asset (a path with a file extension) stays a 404, so a stale
      -- bundle reference fails visibly instead of loading HTML as script.
      let spa request respond = case reverse (pathInfo request) of
            final : _ | T.any (== '.') final ->
              respond (responseLBS status404 [("Content-Type", "text/plain")] "Not found\n")
            _ -> respond (responseFile status200 [("Content-Type", "text/html; charset=utf-8")] index Nothing)
      pure (staticApp (defaultWebAppSettings dir) {ss404Handler = Just spa})
