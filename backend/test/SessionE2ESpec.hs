{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module SessionE2ESpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (unless, void)
import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (toUpper)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Drift.Api (CreateSessionResponse (..))
import Drift.Domain.State (replay)
import Drift.Domain.Types (Log (..), Placement (..), Session (..))
import Drift.Protocol
import Network.HTTP.Client
  ( Manager, Request (..), RequestBody (..), Response, defaultManagerSettings
  , httpLbs, newManager, parseRequest, responseBody, responseStatus )
import Network.HTTP.Types (statusCode)
import Network.Socket
  ( Family (AF_INET), SocketType (Stream), SockAddr (SockAddrInet), bind
  , close, defaultProtocol, getSocketName, setSocketOption, socket
  , SocketOption (ReuseAddr) )
import Network.WebSockets
  ( Connection, receiveData, runClient, sendTextData )
import System.Directory
  ( createDirectory, doesFileExist, getCurrentDirectory, getTemporaryDirectory
  , removeFile, removePathForcibly )
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.FilePath ((</>), isAbsolute, takeDirectory)
import System.IO (IOMode (ReadWriteMode, WriteMode), hClose, openFile, openTempFile, withFile)
import System.Info (os)
import System.Process
  ( CreateProcess (..), ProcessHandle, StdStream (Inherit, NoStream, UseHandle), createProcess
  , getProcessExitCode, proc, readCreateProcessWithExitCode, terminateProcess
  , waitForProcess )
import System.Exit (ExitCode (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  sourceSpec
  writingSpec
  restartSpec

sourceSpec :: Spec
sourceSpec = describe "M6 server sources" $ do
  it "starts enabled source assembly without DRIFT_CONFIG and never prints its optional key" $ do
    executable <- resolveServerExecutable
    port <- reservePort
    withTemporaryDatabase $ \databasePath -> do
      inherited <- getEnvironment
      let logPath = databasePath <> ".log"
          environment = [("DRIFT_SOURCES", "1"), ("OPENALEX_API_KEY", "sentinel-openalex-secret")]
            <> serverEnvironment Nothing port databasePath inherited
      withFile logPath WriteMode $ \output -> bracket
        (createProcess (proc executable []) {env = Just environment,
          std_in = NoStream, std_out = UseHandle output, std_err = UseHandle output})
        (\(_, _, _, process) -> stopServer process)
        (\_ -> waitForHealth port)
      output <- readFile logPath
      output `shouldSatisfy` Text.isInfixOf "sources: Wikipedia/OpenAlex (OpenAlex key present)" . Text.pack
      output `shouldSatisfy` (not . Text.isInfixOf "sentinel-openalex-secret" . Text.pack)

  it "persists fake live sources, citations and placements through real server process restart" $ do
    executable <- getExecutablePath
    port <- reservePort
    withTemporaryDatabase $ \databasePath -> do
      let runFixture action = do
            inherited <- getEnvironment
            bracket
              (createProcess (proc executable ["--source-server-fixture"])
                {env = Just (serverEnvironment Nothing port databasePath inherited),
                 std_in = NoStream, std_out = Inherit, std_err = Inherit})
              (\(_, _, _, process) -> stopServer process) (const action)
      (identifier, history) <- runFixture $ do
        waitForHealth port
        created <- createSession port "en"
        history <- withSession port (sessionId created) $ \connection -> do
          initial <- receiveEvents connection
          submitCommand connection 1 (StartWithWord "root")
          root <- collectUntil connection (\case NodeChosen _ _ _ _ _ -> True; _ -> False)
          submitCommand connection 2 (InsertWord "child")
          child <- collectUntil connection isEntry
          [source | Stamped _ _ (SourceFound source) <- child] `shouldSatisfy` (not . null)
          [entry | Stamped _ _ (EntryWritten entry) <- child]
            `shouldBe` [Entry (EntryId 1) (NodeId 2) "root \8594 child" "" [SourceId 1]]
          submitCommand connection 3 (PlaceSource (SourceId 1) (Vec2 3.5 (-4.25)) 0.6)
          placed <- collectUntil connection (\case SourcePlaced _ _ _ -> True; _ -> False)
          submitCommand connection 4 (SetDivergence 0.33)
          fenced <- collectUntil connection (== DivergenceSet 0.33)
          pure (initial <> root <> child <> placed <> fenced)
        pure (sessionId created, history)
      runFixture $ do
        waitForHealth port
        withSession port identifier $ \connection -> do
          restored <- receiveEvents connection
          restored `shouldBe` history
          let state = replay (Log (reverse restored))
          Map.size (sessionSources state) `shouldBe` 1
          Map.size (sessionEntries state) `shouldBe` 1
          sessionSourcePlacements state `shouldBe`
            Map.singleton (SourceId 1) (Placement (Vec2 3.5 (-4.25)) 0.6)
          submitCommand connection 5 (InsertWord "grandchild")
          continued <- collectUntil connection isEntry
          [entry | Stamped _ _ (EntryWritten entry) <- continued]
            `shouldBe` [Entry (EntryId 2) (NodeId 3) "child \8594 grandchild" "" [SourceId 2]]
          [identifier' | Stamped _ _ (SourceFound (Source identifier' _ _ _ _ _ _ _)) <- continued]
            `shouldBe` [SourceId 2]

writingSpec :: Spec
writingSpec = describe "M7 server writing" $ do
  it "removes mixed-case inherited model and source configuration before offline startup" $ do
    let inherited =
          [ ("drift_config", "must-not-load-real-provider.yaml")
          , ("dRiFt_SoUrCeS", "1")
          , ("openalex_api_key", "sentinel-source-key")
          , ("OpenAI_Api_Key", "sentinel-model-key")
          , ("DrIfT_WrItInG", "1")
          , ("drift_port", "9999")
          , ("Drift_Db_Path", "inherited.sqlite")
          , ("PATH", "test-toolchain")
          ]
    serverEnvironment (Just "0") 8081 "offline.sqlite" inherited `shouldBe`
      [("DRIFT_PORT", "8081"), ("DRIFT_DB_PATH", "offline.sqlite"),
       ("DRIFT_WRITING", "0"), ("PATH", "test-toolchain")]

  it "defaults to template writing with no model config and replays the entry after restart" $ do
    executable <- resolveServerExecutable
    port <- reservePort
    withTemporaryDatabase $ \databasePath -> do
      (identifier, history) <- withWritingServer Nothing executable port databasePath $ do
        waitForHealth port
        created <- createSession port "en"
        withSession port (sessionId created) $ \connection -> do
          _ <- receiveEvents connection
          submitCommand connection 1 (StartWithWord "root")
          _ <- collectUntil connection isSeal
          submitCommand connection 2 (InsertWord "child")
          _ <- collectUntil connection isSeal
          pure ()
        -- Inspect snapshots outside the socket callback: a missing entry is
        -- a bounded assertion failure, rather than a stalled socket read.
        snapshot <- awaitEntryHistory port (sessionId created) 50
        [entry | Stamped _ _ (EntryWritten entry) <- snapshot]
          `shouldBe` [Entry (EntryId 1) (NodeId 2) "root \8594 child" "" []]
        history <- withSession port (sessionId created) $ \connection -> do
          replayed <- receiveEvents connection
          submitCommand connection 3 WrapUp
          wrapped <- collectUntil connection (== WrappedUp)
          pure (replayed <> wrapped)
        pure (sessionId created, history)
      withWritingServer Nothing executable port databasePath $ do
        waitForHealth port
        withSession port identifier $ \connection -> receiveEvents connection `shouldReturn` history

  it "disables entries explicitly with DRIFT_WRITING=0" $ do
    executable <- resolveServerExecutable
    port <- reservePort
    withTemporaryDatabase $ \databasePath -> withWritingServer (Just "0") executable port databasePath $ do
      waitForHealth port
      created <- createSession port "en"
      withSession port (sessionId created) $ \connection -> do
        initial <- receiveEvents connection
        submitCommand connection 1 (StartWithWord "root")
        root <- collectUntil connection isSeal
        submitCommand connection 2 (InsertWord "child")
        child <- collectUntil connection isSeal
        submitCommand connection 3 WrapUp
        wrapped <- collectUntil connection (== WrappedUp)
        filter (isEntry . eventOf) (initial <> root <> child <> wrapped) `shouldBe` []

restartSpec :: Spec
restartSpec = describe "M1 server process restart" $
  it "replays and continues an explored session across real process restarts" $ do
    executable <- resolveServerExecutable
    port <- reservePort
    withTemporaryDatabase $ \databasePath -> do
      firstSession <- withServer executable port databasePath $ do
        waitForHealth port
        created <- createSession port "en"
        history <- withSession port (sessionId created) $ \connection -> do
          initial <- receiveEvents connection
          cloud <- case initial of
            [Stamped 1 _ (CloudSpawned En candidates)] -> pure candidates
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
          submitCommand connection 500 (StartWithWord "\x72EC\x7ACB")
          events <- collectUntil connection (\case NodeChosen _ _ "\x72EC\x7ACB" StartWord _ -> True; _ -> False)
          events `shouldSatisfy` any (\stamped -> case eventOf stamped of
            NodeChosen _ _ "\x72EC\x7ACB" StartWord _ -> True
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
          candidate <- case current of
            first : _ -> pure first
            [] -> expectationFailure "Expected a current branch candidate" >> fail "Missing branch candidate"
          submitCommand connection 800 (Pick (candidateIdOf candidate))
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
withServer = withWritingServer (Just "0")

withWritingServer :: Maybe String -> FilePath -> Int -> FilePath -> IO a -> IO a
withWritingServer writing executable port databasePath action =
  bracket (startServer writing executable port databasePath) stopServer (const action)

startServer :: Maybe String -> FilePath -> Int -> FilePath -> IO ProcessHandle
startServer writing executable port databasePath = do
  inherited <- getEnvironment
  let process = (proc executable [])
        {env = Just (serverEnvironment writing port databasePath inherited)}
  if os == "mingw32"
    then processHandle <$> createProcess process
      { std_in = NoStream, std_out = Inherit, std_err = Inherit }
    else do
      -- Keep all three descriptors open on POSIX. Closing stdout lets the
      -- runtime reuse fd 1 for an internal pipe, which breaks server startup.
      null' <- openFile "/dev/null" ReadWriteMode
      processHandle <$> createProcess process
        { std_in = UseHandle null', std_out = UseHandle null', std_err = UseHandle null' }
  where
    processHandle (_, _, _, handle) = handle

-- The real process fixture and its regression share this environment builder.
-- Keep inherited configuration out even when its spelling differs by case.
serverEnvironment :: Maybe String -> Int -> FilePath -> [(String, String)] -> [(String, String)]
serverEnvironment writing port databasePath inherited =
  let overrides = [("DRIFT_PORT", show port), ("DRIFT_DB_PATH", databasePath)]
        <> maybe [] (\value -> [("DRIFT_WRITING", value)]) writing
      offlineVariables = ["DRIFT_CONFIG", "DRIFT_SOURCES", "DRIFT_WRITING", "OPENALEX_API_KEY",
        "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "ANTHROPIC_API_KEY"]
      environment = overrides <> filter ((`notElem` (offlineVariables <> map fst overrides)) . map toUpper . fst) inherited
   in environment

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
waitForHealth port = do
  manager <- newManager defaultManagerSettings
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
createSession port language = do
  manager <- newManager defaultManagerSettings
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
withSession port identifier = runClient "127.0.0.1" port
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

isEntry :: Event -> Bool
isEntry (EntryWritten _) = True
isEntry _ = False

awaitEntryHistory :: Int -> Text -> Int -> IO [Stamped]
awaitEntryHistory port identifier remaining = do
  history <- withSession port identifier receiveEvents
  if any (isEntry . eventOf) history || remaining <= 0 then pure history
    else threadDelay 10000 >> awaitEntryHistory port identifier (remaining - 1)
