{-# LANGUAGE OverloadedRecordDot #-}

-- | Wrap-up: the actor builds the outputs, commits and broadcasts them, and the
-- export route serves them.
module OutputsWiringSpec (spec) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, throwIO)
import Data.Aeson (decode)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TE
import Drift.Api (api, server)
import Drift.Domain.Types (SessionId (..))
import Drift.Output.Assemble (modelOutputs)
import Drift.Protocol
import Drift.Server.SessionActor
import Drift.Server.WebSocket (webSocketApp)
import Drift.Store.SQLite
import Network.HTTP.Client (defaultManagerSettings, httpLbs, parseRequest, responseBody, responseHeaders, responseStatus)
import qualified Network.HTTP.Client as Client
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets (defaultConnectionOptions)
import Servant (serve)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import System.Timeout (timeout)
import Test.Hspec

quiet :: BranchGenerator
quiet _ _ = atomically retry

fakeOutputs :: Outputs
fakeOutputs = Outputs "tree" "draft" "final"

-- | A session with two chosen words, one entry that was promoted and cites a source.
seededLog :: [Event]
seededLog =
  [ CloudSpawned En [Candidate (CandidateId 1) "tide"]
  , NodeChosen (NodeId 1) Nothing "tide" Cloud (Just (CandidateId 1))
  , NodeChosen (NodeId 2) (Just (NodeId 1)) "moon" Branch Nothing
  , SourceFound (Source (SourceId 1) (NodeId 2) Paper "Moon, tides and climate" (Just "Nature") "https://doi.org/10.1038/35015639" Nothing (decode "{\"type\":\"article-journal\",\"title\":\"Moon, tides and climate\",\"author\":[{\"family\":\"Wunsch\",\"given\":\"Carl\"}],\"container-title\":\"Nature\",\"issued\":{\"date-parts\":[[2000]]}}"))
  , EntryWritten (Entry (EntryId 1) (NodeId 2) "Tides follow the moon" "The moon pulls the sea." [SourceId 1])
  , EntryPromoted (EntryId 1) 1
  ]

seed :: Store -> SessionId -> [Event] -> IO ()
seed store sid evs = createSession store sid (zipWith (\n e -> Stamped n 1700000000000 e) [1 ..] evs)

-- | Reads messages until an 'OutputsReady' arrives, returning every event seen.
untilOutputs :: Subscription -> IO [Event]
untilOutputs sub = go []
  where
    go seen = do
      msg <- bounded (receive sub)
      case msg of
        Events batch ->
          let new = map (.event) batch
              all' = seen <> new
           in if any isOutputs new then pure all' else go all'
        _ -> go seen
    isOutputs = \case OutputsReady {} -> True; _ -> False

bounded :: IO a -> IO a
bounded action = timeout 5000000 action >>= maybe (fail "Timed out") pure

connected :: Manager -> SessionId -> IO Subscription
connected manager sid = bounded (subscribeSession manager sid) >>= \case
  Left rejection -> fail (show rejection)
  Right sub -> pure sub

drain :: Subscription -> IO [Event]
drain sub = do
  r <- timeout 300000 (receive sub)
  case r of
    Just (Events batch) -> ((map (.event) batch) <>) <$> drain sub
    Just _ -> drain sub
    Nothing -> pure []

withDatabase :: (FilePath -> IO a) -> IO a
withDatabase action = bracket acquire removeFile action
  where
    acquire = do
      directory <- getTemporaryDirectory
      (path, handle) <- openTempFile directory "drift-outputs-test.sqlite"
      hClose handle
      removeFile path
      pure path

withOutputs :: OutputsGenerator -> (Store -> Manager -> IO ()) -> IO ()
withOutputs generator action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
  bracket (newManagerWithOutputs store quiet generator) stopManager (action store)

spec :: Spec
spec = describe "Wrap-up outputs" $ do
  describe "the session actor" $ do
    it "builds the outputs from the whole log after wrap-up, commits them and broadcasts them" $ do
      seen <- newIORef []
      withOutputs (\log' -> writeIORef seen (map (.event) log') >> pure fakeOutputs) $ \store manager -> do
        sid <- createManagedSession manager En
        sub <- connected manager sid
        _ <- bounded (receive sub)
        submit sub (ClientMsg 1 (StartWithWord "tide"))
        _ <- drain sub
        submit sub (ClientMsg 2 WrapUp)
        events' <- untilOutputs sub
        take 1 [e | e@WrappedUp <- events'] `shouldBe` [WrappedUp]
        [o | OutputsReady o <- events'] `shouldBe` [fakeOutputs]
        -- The generator saw everything up to and including the wrap-up.
        logSeen <- readIORef seen
        last logSeen `shouldBe` WrappedUp
        length [() | NodeChosen {} <- logSeen] `shouldBe` 1
        -- And it is durable.
        Just stored <- loadEvents store sid
        [o | Stamped {event = OutputsReady o} <- stored] `shouldBe` [fakeOutputs]

    it "does not build them again for a second wrap-up" $ do
      calls <- newMVar (0 :: Int)
      withOutputs (\_ -> modifyMVar_ calls (pure . (+ 1)) >> pure fakeOutputs) $ \_ manager -> do
        sid <- createManagedSession manager En
        sub <- connected manager sid
        _ <- bounded (receive sub)
        submit sub (ClientMsg 1 WrapUp)
        _ <- untilOutputs sub
        submit sub (ClientMsg 2 WrapUp)
        drain sub `shouldReturn` []
        readMVar calls `shouldReturn` 1

    it "reports a failing generator and keeps the session usable" $ do
      withOutputs (\_ -> throwIO (userError "disk on fire")) $ \store manager -> do
        sid <- createManagedSession manager En
        sub <- connected manager sid
        _ <- bounded (receive sub)
        submit sub (ClientMsg 1 WrapUp)
        msgs <- collectDiagnostic sub
        case msgs of
          Just (Diagnostic level why) -> do
            level `shouldBe` LevelError
            Text.unpack why `shouldContain` "disk on fire"
          other -> expectationFailure ("expected a diagnostic, got " <> show other)
        storedOutputs manager sid `shouldReturn` OutputsNotReady
        Just stored <- loadEvents store sid
        [() | Stamped {event = OutputsReady {}} <- stored] `shouldBe` []

    it "makes the outputs of a wrapped-up session that was stopped before it had them" $
      withDatabase $ \path -> do
        sid <- bracket (openStore path) closeStore $ \store ->
          -- Without a generator: wrap-up commits only WrappedUp, like a server that went down mid-way.
          bracket (newManager store quiet) stopManager $ \manager -> do
            sid <- createManagedSession manager En
            sub <- connected manager sid
            _ <- bounded (receive sub)
            submit sub (ClientMsg 1 WrapUp)
            drain sub `shouldReturn` [WrappedUp]
            pure sid
        bracket (openStore path) closeStore $ \store ->
          bracket (newManagerWithOutputs store quiet (\_ -> pure fakeOutputs)) stopManager $ \manager -> do
            sub <- connected manager sid
            events' <- untilOutputs sub
            [o | OutputsReady o <- events'] `shouldBe` [fakeOutputs]
            storedOutputs manager sid `shouldReturn` OutputsStored fakeOutputs

    it "adds nothing for a manager without a generator" $
      withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
        bracket (newManager store quiet) stopManager $ \manager -> do
          sid <- createManagedSession manager En
          sub <- connected manager sid
          _ <- bounded (receive sub)
          submit sub (ClientMsg 1 WrapUp)
          drain sub `shouldReturn` [WrappedUp]

    it "tells a missing session from one without outputs yet" $
      withOutputs (\_ -> pure fakeOutputs) $ \_ manager -> do
        storedOutputs manager (SessionId "nope") `shouldReturn` NoSuchSession
        sid <- createManagedSession manager En
        storedOutputs manager sid `shouldReturn` OutputsNotReady

  describe "with the real outputs" $ do
    it "turns a seeded session into the three documents" $ do
      generator <- either (fail . Text.unpack) pure (modelOutputs Nothing (\_ -> pure ()))
      withOutputs generator $ \store manager -> do
        let sid = SessionId "seeded"
        seed store sid seededLog
        sub <- connected manager sid
        _ <- bounded (receive sub)
        submit sub (ClientMsg 1 WrapUp)
        events' <- untilOutputs sub
        case [o | OutputsReady o <- events'] of
          [o] -> do
            Text.unpack o.decisionTree `shouldContain` "flowchart TD"
            Text.unpack o.decisionTree `shouldContain` "n1[tide] --> n2[moon]"
            Text.unpack o.draft `shouldContain` "# Draft: from tide to moon"
            Text.unpack o.draft `shouldContain` "(Wunsch, 2000)"
            Text.unpack o.final `shouldContain` "# From tide to moon"
            Text.unpack o.final `shouldContain` "Tides follow the moon."
            Text.unpack o.final `shouldContain` "## References"
          other -> expectationFailure ("expected one OutputsReady, got " <> show other)

  describe "the export route" $ do
    it "serves each output in each format once the session has them" $ do
      generator <- either (fail . Text.unpack) pure (modelOutputs Nothing (\_ -> pure ()))
      withBackend generator $ \port store manager -> do
        let sid = SessionId "seeded"
        seed store sid seededLog
        sub <- connected manager sid
        _ <- bounded (receive sub)
        submit sub (ClientMsg 1 WrapUp)
        _ <- untilOutputs sub
        Just stored <- loadEvents store sid
        o <- case [x | Stamped {event = OutputsReady x} <- stored] of { x : _ -> pure x; [] -> fail "no outputs were stored" }
        md <- get port "/api/sessions/seeded/export/draft/md"
        statusCode (responseStatus md) `shouldBe` 200
        responseBody md `shouldBe` LBS.fromStrict (encodeText o.draft)
        lookup "Content-Disposition" (responseHeaders md) `shouldBe` Just "attachment; filename=\"draft.md\""
        html <- get port "/api/sessions/seeded/export/final/html"
        statusCode (responseStatus html) `shouldBe` 200
        lookup "Content-Type" (responseHeaders html) `shouldBe` Just "text/html; charset=utf-8"
        LBS8.unpack (responseBody html) `shouldContain` "<h1>From tide to moon</h1>"
        docx <- get port "/api/sessions/seeded/export/final/docx"
        statusCode (responseStatus docx) `shouldBe` 200
        LBS.take 2 (responseBody docx) `shouldBe` "PK"
        lookup "Content-Disposition" (responseHeaders docx) `shouldBe` Just "attachment; filename=\"final.docx\""
        tree <- get port "/api/sessions/seeded/export/tree/docx"
        statusCode (responseStatus tree) `shouldBe` 200

    it "answers 404 for a missing session or outputs not ready, and 400 for an unknown file" $
      withBackend (\_ -> pure fakeOutputs) $ \port _ manager -> do
        missing <- get port "/api/sessions/nope/export/final/md"
        statusCode (responseStatus missing) `shouldBe` 404
        SessionId sid <- createManagedSession manager En
        notReady <- get port ("/api/sessions/" <> Text.unpack sid <> "/export/final/md")
        statusCode (responseStatus notReady) `shouldBe` 404
        bad <- get port ("/api/sessions/" <> Text.unpack sid <> "/export/final/pdf")
        statusCode (responseStatus bad) `shouldBe` 400
        worse <- get port ("/api/sessions/" <> Text.unpack sid <> "/export/everything/md")
        statusCode (responseStatus worse) `shouldBe` 400
  where
    collectDiagnostic sub = do
      r <- timeout 3000000 (receive sub)
      case r of
        Just d@Diagnostic {} -> pure (Just d)
        Just _ -> collectDiagnostic sub
        Nothing -> pure Nothing
    encodeText = TE.encodeUtf8
    withBackend generator action = withDatabase $ \path -> bracket (openStore path) closeStore $ \store ->
      bracket (newManagerWithOutputs store quiet generator) stopManager $ \manager ->
        testWithApplication
          (pure (websocketsOr defaultConnectionOptions (webSocketApp manager) (serve api (server manager))))
          (\port -> action port store manager)
    get port path = do
      http <- Client.newManager defaultManagerSettings
      request <- parseRequest ("http://127.0.0.1:" <> show port <> path)
      httpLbs request {Client.checkResponse = \_ _ -> pure ()} http
