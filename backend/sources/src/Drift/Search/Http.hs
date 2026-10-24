{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The only place that touches the network. Everything else takes a 'Fetch',
-- so providers are tested against saved responses and a fake 'Fetch'.
--
-- The real 'Fetch' adds what every polite client needs: a User-Agent that says
-- who is calling, a timeout, a minimum gap between requests to one host, a
-- short cache, and a stop when a host says it is out of budget (HTTP 429).
module Drift.Search.Http
  ( Fetch (..)
  , HttpRequest (..)
  , HttpResponse (..)
  , FetchError (..)
  , HttpConfig (..)
  , defaultHttpConfig
  , newFetch
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (try)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.CaseInsensitive as CI
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Network.HTTP.Client as HC
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (HeaderName)
import Network.HTTP.Types.Status (statusCode)
import Text.Read (readMaybe)

data HttpRequest = HttpRequest
  { reqUrl :: Text
  , reqQuery :: [(Text, Text)]
  , reqHeaders :: [(Text, Text)]
  }
  deriving stock (Eq, Show)

data HttpResponse = HttpResponse
  { respStatus :: Int
  , respHeaders :: [(Text, Text)]
  -- ^ header names lower-cased
  , respBody :: LBS.ByteString
  }
  deriving stock (Eq, Show)

data FetchError
  = Timeout
  | Network Text
  | BadStatus Int
  | RateLimited Int
  -- ^ the host refused, or is known to be out of budget; seconds until it may be tried again
  deriving stock (Eq, Show)

newtype Fetch = Fetch {runFetch :: HttpRequest -> IO (Either FetchError HttpResponse)}

data HttpConfig = HttpConfig
  { userAgent :: Text
  -- ^ should identify the project and where to reach it
  , timeoutSeconds :: Int
  , minGapMillis :: Text -> Int
  -- ^ minimum time between requests to a host
  , cacheSeconds :: Int
  }

defaultHttpConfig :: HttpConfig
defaultHttpConfig =
  HttpConfig
    { userAgent = "Driftwords/0.1 (hackathon project; https://github.com/Bill092738/Drift_words)"
    , timeoutSeconds = 10
    , minGapMillis = \case
        "api.openalex.org" -> 150 -- the keyless limit is 10 requests per second
        "doi.org" -> 100
        _ -> 100
    , cacheSeconds = 3600
    }

-- | Per-host state, shared by every call of one 'Fetch'.
data Shared = Shared
  { nextSlot :: MVar (Map Text Word64)
  -- ^ monotonic nanoseconds before which the host is not called again
  , blockedUntil :: IORef (Map Text Word64)
  , cache :: IORef (Map Text (Word64, HttpResponse))
  }

newFetch :: HttpConfig -> IO Fetch
newFetch cfg = do
  manager <-
    HC.newManager
      tlsManagerSettings {HC.managerResponseTimeout = HC.responseTimeoutMicro (cfg.timeoutSeconds * 1000000)}
  shared <- Shared <$> newMVar Map.empty <*> newIORef Map.empty <*> newIORef Map.empty
  pure (Fetch (perform cfg manager shared))

perform :: HttpConfig -> HC.Manager -> Shared -> HttpRequest -> IO (Either FetchError HttpResponse)
perform cfg manager shared rq = do
  parsed <- try (HC.parseRequest (T.unpack rq.reqUrl))
  case parsed of
    Left (e :: HC.HttpException) -> pure (Left (Network (T.pack (show e))))
    Right base -> do
      let host = TE.decodeUtf8 (HC.host base)
          built =
            HC.setQueryString [(TE.encodeUtf8 k, Just (TE.encodeUtf8 v)) | (k, v) <- rq.reqQuery] $
              base
                { HC.requestHeaders =
                    ("User-Agent", TE.encodeUtf8 cfg.userAgent)
                      : [(headerName k, TE.encodeUtf8 v) | (k, v) <- rq.reqHeaders]
                }
          key = rq.reqUrl <> "?" <> T.intercalate "&" [k <> "=" <> v | (k, v) <- rq.reqQuery] <> accept
          accept = T.concat [v | (k, v) <- rq.reqHeaders, T.toLower k == "accept"]
      now <- getMonotonicTimeNSec
      cached <- Map.lookup key <$> readIORef shared.cache
      blocked <- Map.lookup host <$> readIORef shared.blockedUntil
      case (cached, blocked) of
        (Just (expires, resp), _) | expires > now -> pure (Right resp)
        (_, Just until') | until' > now -> pure (Left (RateLimited (secondsBetween now until')))
        _ -> do
          waitForSlot cfg shared host
          result <- try (HC.httpLbs built manager)
          case result of
            Left e -> pure (Left (classify e))
            Right r -> do
              let status = statusCode (HC.responseStatus r)
                  resp =
                    HttpResponse
                      status
                      [(TE.decodeUtf8 (CI.foldedCase n), TE.decodeUtf8 v) | (n, v) <- HC.responseHeaders r]
                      (HC.responseBody r)
              if status >= 200 && status < 300
                then do
                  stamp <- getMonotonicTimeNSec
                  let expires = stamp + fromIntegral cfg.cacheSeconds * 1000000000
                  atomicModifyIORef' shared.cache (\m -> (Map.insert key (expires, resp) m, ()))
                  pure (Right resp)
                else
                  if status == 429
                    then do
                      let wait = retryAfterSeconds resp
                      stamp <- getMonotonicTimeNSec
                      atomicModifyIORef'
                        shared.blockedUntil
                        (\m -> (Map.insert host (stamp + fromIntegral wait * 1000000000) m, ()))
                      pure (Left (RateLimited wait))
                    else pure (Left (BadStatus status))
  where
    headerName :: Text -> HeaderName
    headerName = fromString . T.unpack

-- | Reserves the host's next slot under the lock, then sleeps outside it.
waitForSlot :: HttpConfig -> Shared -> Text -> IO ()
waitForSlot cfg shared host = do
  now <- getMonotonicTimeNSec
  let gap = fromIntegral (cfg.minGapMillis host) * 1000000 :: Word64
  slot <-
    modifyMVar shared.nextSlot $ \m ->
      let mine = max now (Map.findWithDefault 0 host m)
       in pure (Map.insert host (mine + gap) m, mine)
  if slot > now then threadDelay (fromIntegral ((slot - now) `div` 1000)) else pure ()

classify :: HC.HttpException -> FetchError
classify = \case
  HC.HttpExceptionRequest _ HC.ResponseTimeout -> Timeout
  HC.HttpExceptionRequest _ HC.ConnectionTimeout -> Timeout
  e -> Network (T.pack (show e))

-- | OpenAlex sends the seconds until its budget resets in @x-ratelimit-reset@;
-- other hosts use @retry-after@. Capped at a day, defaulting to a minute.
retryAfterSeconds :: HttpResponse -> Int
retryAfterSeconds resp =
  let find name = lookup name resp.respHeaders >>= readMaybe . T.unpack
   in min 86400 (max 1 (maybe 60 id (find "retry-after" `orElse` find "x-ratelimit-reset")))
  where
    orElse a b = maybe b Just a

secondsBetween :: Word64 -> Word64 -> Int
secondsBetween from to = fromIntegral ((to - from) `div` 1000000000) + 1
