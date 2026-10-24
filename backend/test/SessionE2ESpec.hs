{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module SessionE2ESpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (unless, void)
import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Drift.Api (CreateSessionResponse (..))
import Drift.Domain.State (replay)
import Drift.Domain.Types (Log (..), Session (..))
import Drift.Protocol
import Network.HTTP.Client
  ( Manager, Request (..), RequestBody (..), Response, defaultManagerSettings
  , closeManager, httpLbs, newManager, parseRequest, responseBody, responseStatus )
import Network.HTTP.Types (statusCode)
import Network.Socket
  ( Family (AF_INET), SocketType (Stream), SockAddr (SockAddrInet), bind
  , close, defaultProtocol, getSocketName, setSocketOption, socket
  , SocketOption (ReuseAddr) )
import Network.WebSockets
  ( Connection, defaultConnectionOptions, receiveData, runClient, sendTextData )
import System.Directory
  ( createDirectory, doesFileExist, getCurrentDirectory, getTemporaryDirectory
  , removeFile, removePathForcibly )
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath ((</>), isAbsolute, takeDirectory)
import System.IO (hClose, openTempFile)
import System.Process
  ( CreateProcess (..), ProcessHandle, StdStream (NoStream), createProcess
  , getProcessExitCode, proc, readCreateProcessWithExitCode, terminateProcess
  , waitForProcess )
import System.Exit (ExitCode (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "M1 server process restart" $
  it "replays and continues an explored session across real process restarts" $ do
    executable <- resolveServerExecutable
    port <- reservePort
    withTemporaryDatabase $ \databasePath -> do
      firstSession <- withServer executable port databasePath $ do
        waitForHealth port
        created <- createSession port "en"
        history <- withSession port (sessionId created) $ \connection -> do
          initial <- receiveEvents connection
          let cloud = case initial of
                [Stamped 1 _ (CloudSpawned En candidates)] -> candidates
                other -> expectationFailure ("Unexpected initial cloud: " <> show other) >> pure []
          walked <- walkFifteen connection cloud initial
          submitCommand connection 700 (SetDivergence 0.4)
          divergenceEvents <- collectUntil connection (\case DivergenceSet value -> value == 0.4; _ -> False)
          submitCommand connection 701 (InsertWord "e2e-insert")
          inserted <- collectUntil connection isSeal
          let root = NodeId 1
          submitCommand connection 702 (Backtrack root)
          revisited <- collectUntil connection isSeal
          submitCommand connection 703 (PlaceNode root (Vec2 1.25 (-2.5)) 0.75)
          placement <- collectUntil connection (\case NodePlaced _ _ _ -> True; _ -> False)
          let beforeInvalid = walked <> divergenceEvents <> inserted <> revisited <> placement
          assertContiguous beforeInvalid
          submitCommand connection 704 (Pick (CandidateId 2147483000))
          receiveServerMessage connection >>= \case
            Rejected requestId _ -> requestId `shouldBe` 704
            other -> fail ("Expected rejected invalid candidate request, got " <> show other)
          pure beforeInvalid
        historyAfterOps <- withSession port (sessionId created) $ \connection -> do
          initial <- receiveEvents connection
          initial `shouldBe` history
          let session = replay (Log (reverse initial))
          sessionFocus session `shouldBe` Just (NodeId 1)
          pure initial
        -- A separate session exercises the StartWithWord path, independently
        -- of the candidate-driven path whose history is persisted above.
        startWordSession <- createSession port "zh"
        withSession port (sessionId startWordSession) $ \connection -> do
          _ <- receiveEvents connection
          submitCommand connection 500 (StartWithWord "独立")
          events <- collectUntil connection (\case NodeChosen _ _ "独立" StartWord _ -> True; _ -> False)
          events `shouldSatisfy` any (\stamped -> case eventOf stamped of
            NodeChosen _ _ "独立" StartWord _ -> True
            _ -> False)
          _ <- collectUntil connection isSeal
          pure ()
        pure (created, historyAfterOps)

      let (created, persistedBeforeRestart) = firstSession
      assertContiguous persistedBeforeRestart
      beforeState <- pure (replay (Log (reverse persistedBeforeRestart)))

      secondSession <- withServer executable port databasePath $ do
        waitForHealth port
        withSession port (sessionId created) $ \connection -> do
          restored <- receiveEvents connection
          restored `shouldBe` persistedBeforeRestart
          replay (Log (reverse restored)) `shouldBe` beforeState
          let previouslyVisible = visibleCandidateIds restored
              priorNodeIds = chosenNodeIds restored
              current = latestSealedCandidates restored
          current `shouldSatisfy` (not . null)
          submitCommand connection 800 (Pick (candidateIdOf (head current)))
          continuation <- collectUntil connection isSeal
          let continued = restored <> continuation
          assertContiguous continued
          let newNodes = chosenNodeIds continuation
              newVisible = visibleCandidateIds continuation
          newNodes `shouldSatisfy` (not . null)
          all (`notElem` priorNodeIds) newNodes `shouldBe` True
          newVisible `shouldSatisfy` (not . null)
          all (> maximum (0 : previouslyVisible)) newVisible `shouldBe` True

          submitCommand connection 801 WrapUp
          wrapped <- collectUntilEvent connection (== WrappedUp)
          pure (continued <> wrapped)

      let historyAfterContinuation = secondSession
      assertContiguous historyAfterContinuation

      withServer executable port databasePath $ do
        waitForHealth port
        withSession port (sessionId created) $ \connection -> do
          finalHistory <- receiveEvents connection
          finalHistory `shouldBe` historyAfterContinuation
          sessionWrapped (replay (Log (reverse finalHistory))) `shouldBe` True
          map eventOf finalHistory `shouldSatisfy` elem WrappedUp

withServer :: FilePath -> Int -> FilePath -> IO a -> IO a
withServer executable port databasePath action =
  bracket (startServer executable port databasePath) stopServer (const action)

startServer :: FilePath -> Int -> FilePath -> IO ProcessHandle
startServer executable port databasePath = do
  inherited <- getEnvironment
  let overrides = [("DRIFT_PORT", show port), ("DRIFT_DB_PATH", databasePath)]
      environment = overrides <> filter ((`notElem` map fst overrides) . fst) inherited
      process = (proc executable [])
        { env = Just environment
        , std_in = NoStream
        , std_out = NoStream
        , std_err = NoStream
        }
  (_, _, _, handle) <- createProcess process
  pure handle

stopServer :: ProcessHandle -> IO ()
stopServer handle = do
  status <- try (getProcessExitCode handle) :: IO (Either SomeException (Maybe ExitCode))
  case status of
    Right (Just _) -> pure ()
    _ -> void (try (terminateProcess handle) :: IO (Either SomeException ()))
  void (try (waitForProcess handle) :: IO (Either SomeException ExitCode))

resolveServerExecutable :: IO FilePath
resolveServerExecutable = do
  override <- lookupEnv "DRIFT_SERVER_EXE"
  case override of
    Just path -> ensureExecutable path
    Nothing -> do
      packageRoot <- findPackageRoot =<< getCurrentDirectory
      (exitCode, output, errors) <- readCreateProcessWithExitCode
        ((proc "cabal" ["list-bin", "drift-server"]) {cwd = Just packageRoot}) ""
      case exitCode of
        ExitSuccess -> do
          let reported = Text.unpack (Text.strip (Text.pack output))
              path = if isAbsolute reported then reported else packageRoot </> reported
          ensureExecutable path
        _ -> fail ("cabal list-bin drift-server failed: " <> errors)
  where
    ensureExecutable path = do
      exists <- doesFileExist path
      unless exists (fail ("drift-server executable does not exist: " <> path <> "; run cabal build drift-server first"))
      pure path

findPackageRoot :: FilePath -> IO FilePath
findPackageRoot path = do
  found <- doesFileExist (path </> "drift.cabal")
  if found
    then pure path
    else let parent = takeDirectory path
         in if parent == path then fail "Could not locate backend/drift.cabal from the test working directory"
            else findPackageRoot parent

waitForHealth :: Int -> IO ()
waitForHealth port = bracket (newManager defaultManagerSettings) closeManager $ \manager -> do
  result <- timeout 30000000 (go manager)
  case result of
    Nothing -> fail "drift-server did not become healthy within 30 seconds"
    Just () -> pure ()
  where
    go manager = do
      ready <- try (do
        response <- httpRequest manager port "GET" "/api/health" LazyByteString.empty
        pure (statusCode (responseStatus response) == 200 && responseBody response == "ok"))
        :: IO (Either SomeException Bool)
      case ready of
        Right True -> pure ()
        _ -> threadDelay 100000 >> go manager

createSession :: Int -> Text -> IO CreateSessionResponse
createSession port language = bracket (newManager defaultManagerSettings) closeManager $ \manager -> do
  body <- httpRequest manager port "POST" "/api/sessions"
    (LazyByteString.fromStrict (TextEncoding.encodeUtf8 ("{\"lang\":\"" <> language <> "\"}")))
  case eitherDecode (responseBody body) of
    Left failure -> fail ("POST /api/sessions returned invalid JSON: " <> failure)
    Right created -> pure created

httpRequest :: Manager -> Int -> ByteString.ByteString -> String
  -> LazyByteString.ByteString -> IO (Response LazyByteString.ByteString)
httpRequest manager port requestMethod path body = do
  request <- parseRequest ("http://127.0.0.1:" <> show port <> path)
  httpLbs request
    { method = requestMethod
    , requestBody = RequestBodyLBS body
    , requestHeaders = [("Content-Type", "application/json")]
    } manager

withTemporaryDatabase :: (FilePath -> IO a) -> IO a
withTemporaryDatabase action = do
  bracket createDirectoryPath removePathForcibly $ \directory -> action (directory </> "sessions.sqlite")
  where
    createDirectoryPath = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary "drift-m1-e2e-"
      hClose handle
      removeFile path
      createDirectory path
      pure path

reservePort :: IO Int
reservePort = bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
  setSocketOption sock ReuseAddr 1
  bind sock (SockAddrInet 0 0)
  getSocketName sock >>= \case
    SockAddrInet port _ -> pure (fromIntegral port)
    address -> fail ("Unexpected local socket address: " <> show address)

withSession :: Int -> Text -> (Connection -> IO a) -> IO a
withSession port identifier = runClient "127.0.0.1" (fromIntegral port)
  ("/api/sessions/" <> Text.unpack identifier <> "/ws")

receiveEvents :: Connection -> IO [Stamped]
receiveEvents connection = receiveServerMessage connection >>= \case
  Events stamped -> pure stamped
  rejected -> fail ("Unexpected rejection while replaying history: " <> show rejected)

receiveServerMessage :: Connection -> IO ServerMsg
receiveServerMessage connection = do
  bounded <- timeout 15000000 (receiveData connection :: IO LazyByteString.ByteString)
  payload <- maybe (fail "Timed out waiting for a committed server event") pure bounded
  case eitherDecode payload of
    Left failure -> fail ("Invalid server JSON: " <> failure)
    Right message -> pure message

submitCommand :: Connection -> Int -> Command -> IO ()
-- This only submits the request; callers establish commitment by consuming
-- the resulting Events batch or the matching rejection from the server.
submitCommand connection requestId command = sendTextData connection (encode (ClientMsg requestId command))

collectUntil :: Connection -> (Event -> Bool) -> IO [Stamped]
collectUntil connection predicate = go []
  where
    go accumulated = do
      batch <- receiveEvents connection
      let combined = accumulated <> batch
      if any (predicate . eventOf) batch then pure combined else go combined

collectUntilEvent :: Connection -> (Event -> Bool) -> IO [Stamped]
collectUntilEvent connection predicate = go []
  where
    go accumulated = do
      receiveServerMessage connection >>= \case
        Events batch ->
          let combined = accumulated <> batch
          in if any (predicate . eventOf) batch then pure combined else go combined
        rejected -> fail ("Unexpected rejection while waiting for commit: " <> show rejected)

walkFifteen :: Connection -> [Candidate] -> [Stamped] -> IO [Stamped]
walkFifteen connection = go 0
  where
    go depth candidates history
      | depth == 15 = pure history
      | otherwise = case candidates of
          [] -> fail "Mock branch result unexpectedly contained no active candidate"
          chosen : _ -> do
            submitCommand connection (1000 + depth) (Pick (candidateIdOf chosen))
            committed <- collectUntil connection isSeal
            let allEvents = history <> committed
                offered = latestSealedCandidates committed
            go (depth + 1) offered allEvents

isSeal :: Event -> Bool
isSeal (BranchesOffered _ _) = True
isSeal _ = False

latestSealedCandidates :: [Stamped] -> [Candidate]
latestSealedCandidates stamped = case [candidates | Stamped _ _ (BranchesOffered _ candidates) <- stamped] of
  [] -> []
  values -> last values

eventOf :: Stamped -> Event
eventOf (Stamped _ _ value) = value

candidateIdOf :: Candidate -> CandidateId
candidateIdOf (Candidate identifier _) = identifier

visibleCandidateIds :: [Stamped] -> [Int]
visibleCandidateIds = nub . concatMap fromEvent . map eventOf
  where
    fromEvent (CloudSpawned _ candidates) = map (unwrap . candidateIdOf) candidates
    fromEvent (CandidateStreamed _ candidate) = [unwrap (candidateIdOf candidate)]
    fromEvent (BranchesOffered _ candidates) = map (unwrap . candidateIdOf) candidates
    fromEvent _ = []
    unwrap (CandidateId identifier) = identifier

chosenNodeIds :: [Stamped] -> [NodeId]
chosenNodeIds stamped = [identifier | Stamped _ _ (NodeChosen identifier _ _ _ _) <- stamped]

assertContiguous :: [Stamped] -> IO ()
assertContiguous stamped = [number | Stamped number _ _ <- stamped] `shouldBe` [1 .. length stamped]
