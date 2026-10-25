-- | drift-server: the session engine over HTTP and WebSocket, plus the built
-- frontend.
--
-- Environment:
--
-- * @DRIFT_PORT@ (default 8080) and @DRIFT_DB_PATH@ (default drift.sqlite).
-- * @DRIFT_CONFIG@: a model configuration such as config.gemini.yaml. Its
--   @branches@ role generates rings, optional @embeddings@ drives divergence,
--   and optional @cloud@ makes the starting cloud. Without it the server uses
--   the deterministic offline vocabulary ("Drift.Model.SessionMock").
-- * @DRIFT_WRITING@: set to 0 to disable sidebar entries. By default each
--   non-root edge receives a deterministic template entry, without a model.
-- * @DRIFT_SOURCES@: set to 0 to turn off source search. By default every
--   non-root edge searches Wikipedia and OpenAlex (no model or key needed;
--   @OPENALEX_API_KEY@ raises the OpenAlex daily budget).
-- * The config's optional @final@ role writes the final document at wrap-up.
--   Without it, or when the model fails, the final document is the kept
--   entries' own text.
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
import Drift.Model.OpenAICompat (RequestOptions (..), checkModelAccess)
import Drift.Model.Provider (GenRequest (..), ModelProvider (..), isAuthFailureMessage)
import Drift.Model.SessionMock (BranchGenerator, mockBranches, mockCloud)
import Drift.Output.Assemble (modelOutputs, orElseOutputs)
import Drift.Output.Final (Generate)
import Drift.Pipeline.Cloud (modelCloud)
import Drift.Pipeline.BranchService (closeBranchService, newBranchService, withParallelPrefetch)
import Drift.Pipeline.SessionBranches (liveBranches)
import Drift.Pipeline.Writing (templateEntry)
import Drift.Pipeline.Sources (SourceEnv (..), defaultSourceEnv, findSources)
import Drift.Search.Http (defaultHttpConfig, redactApiKeys, withFetch)
import Drift.Server.SessionActor
  (CloudGenerator, Pipelines (..), SourceSearch, newManagerWithPipelinesAndCloud, stopManager, withOutputs)
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
  finalModel <- loadFinalModel configPath
  let outputsLog = hPutStrLn stderr . ("final outputs: " <>) . T.unpack
  outputs <-
    either (die . ("final outputs: " <>) . T.unpack) pure $
      -- If building the outputs throws, fall back to model-free outputs.
      orElseOutputs <$> modelOutputs finalModel outputsLog <*> modelOutputs Nothing outputsLog
  withGenerator configPath prefetch $ \generator cloud -> withSources $ \sources -> do
    putStrLn (if writing then "writing: deterministic template" else "writing: disabled")
    putStrLn ("drift-server listening on http://localhost:" <> show port)
    putStrLn ("session database: " <> databasePath)
    bracket (openStore databasePath) closeStore $ \store ->
      bracket
        (withOutputs outputs <$> newManagerWithPipelinesAndCloud store
          (Pipelines generator (if writing then Just templateEntry else Nothing) sources) cloud)
        stopManager $ \manager -> do
          let backend = serve api (server manager)
              app request respond = case pathInfo request of
                "api" : _ -> backend request respond
                _ -> frontend request respond
          run port (websocketsOr defaultConnectionOptions (webSocketApp manager) app)

-- | Source HTTP state is shared across all sessions. Search is on unless
-- @DRIFT_SOURCES=0@; nothing is built or called when it is off. The manager
-- and its workers close inside this scope, before the HTTP owner.
withSources :: (Maybe SourceSearch -> IO a) -> IO a
withSources action = lookupEnv "DRIFT_SOURCES" >>= \case
  Just "0" -> putStrLn "sources: disabled (DRIFT_SOURCES=0)" >> action Nothing
  _ -> do
    key <- fmap T.pack <$> lookupEnv "OPENALEX_API_KEY"
    putStrLn ("sources: Wikipedia/OpenAlex (OpenAlex key " <> maybe "absent" (const "present") key <> ")")
    withFetch defaultHttpConfig $ \fetch -> do
      let sourceEnv = (defaultSourceEnv fetch)
            { envOpenAlexKey = key
            , envLog = hPutStrLn stderr . T.unpack . redactApiKeys }
      action (Just (findSources sourceEnv))

-- | The branch and cloud generators for the configured model, or the offline
-- mock. Configuration errors stop the server at start, not at the first pick.
withGenerator :: Maybe FilePath -> Bool -> (BranchGenerator -> CloudGenerator -> IO a) -> IO a
withGenerator Nothing _ action = do
  putStrLn "branches: offline mock vocabulary (set DRIFT_CONFIG to use a model)"
  action mockBranches (pure . mockCloud)
withGenerator (Just path) prefetch action = do
  config <- loadModelConfig path >>= either (die . (("cannot read " <> path <> ": ") <>) . T.unpack) pure
  branchConfig <- either (die . (("model config " <> path <> ": ") <>) . show) pure (resolveProvider config BranchesRole)
  embeddingConfig <- either (die . (("model config " <> path <> ": ") <>) . show) pure (resolveOptionalProvider config EmbeddingsRole)
  cloudConfig <- either (die . (("model config " <> path <> ": ") <>) . show) pure (resolveOptionalProvider config CloudRole)
  provider <- createModelProvider branchConfig
  checkAccess branchConfig
  embedder <- case embeddingConfig of
    Nothing -> Nothing <$ putStrLn "embeddings: none (rings keep the model's order)"
    Just embeddingProvider -> do
      when (providerKind embeddingProvider == Mock && providerKind branchConfig /= Mock) $
        hPutStrLn stderr "warning: mock embeddings carry no meaning; divergence selection will be random"
      model <- createModelProvider embeddingProvider
      putStrLn ("embeddings: " <> T.unpack (providerName model))
      pure (embed model)
  let parallel = concurrentRequests (providerOptions branchConfig)
  -- Names only: the API key is never printed.
  putStrLn
    ( "branches: " <> T.unpack (providerName provider) <> " " <> T.unpack (providerModel branchConfig)
        <> " at " <> T.unpack (providerBaseUrl branchConfig)
        <> (if not prefetch then ", no prefetch" else if parallel then ", with parallel prefetch" else ", with prefetch")
    )
  cloud <- case cloudConfig of
    Nothing -> pure (pure . mockCloud) <* putStrLn "cloud: offline words (no cloud role)"
    Just cloudProvider -> do
      model <- createModelProvider cloudProvider
      putStrLn ("cloud: " <> T.unpack (providerName model) <> " " <> T.unpack (providerModel cloudProvider))
      pure (modelCloud (putStrLn . T.unpack) 20 model (providerModel cloudProvider))
  let configure = if parallel then withParallelPrefetch else id
  bracket (configure <$> newBranchService provider (providerModel branchConfig) embedder) closeBranchService $ \service ->
    action (liveBranches prefetch service) cloud

-- | Fails at startup when the provider rejects the API key, instead of at the
-- first pick. Other failures (no network, no @/models@ route) only warn.
checkAccess :: ProviderConfig -> IO ()
checkAccess cfg
  | providerKind cfg `notElem` [OpenAICompatible, OpenAIResponses] = pure ()
  | otherwise = do
      result <- toOpenAISettings cfg >>= checkModelAccess
      case result of
        Right () -> putStrLn "model access: the API key works"
        Left why
          | isAuthFailureMessage why ->
              die (T.unpack why <> "\nCheck the variable " <> maybe "named by api_key_env" T.unpack (providerApiKeyEnv cfg) <> " (DRIFT_CONFIG).")
          | otherwise -> hPutStrLn stderr ("warning: could not check model access: " <> T.unpack why)

-- | The model for the final document, from the config's optional @final@ role.
-- Only names are printed: the API key never is.
loadFinalModel :: Maybe FilePath -> IO (Maybe Generate)
loadFinalModel Nothing = pure Nothing
loadFinalModel (Just path) = do
  config <- loadModelConfig path >>= either (die . (("cannot read " <> path <> ": ") <>) . T.unpack) pure
  finalConfig <- either (die . (("model config " <> path <> ": ") <>) . show) pure (resolveOptionalProvider config FinalRole)
  case finalConfig of
    Nothing -> Nothing <$ putStrLn "final document: no final role, using the kept entries' own text"
    Just cfg -> do
      provider <- createModelProvider cfg
      putStrLn ("final document: " <> T.unpack (providerName provider) <> " " <> T.unpack (providerModel cfg))
      pure (Just (\prompt -> generate provider (GenRequest prompt (providerModel cfg) 0 700) (const (pure ()))))

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
