{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The only place that touches the network. Everything else takes a 'Fetch',
-- so providers are tested against saved responses and a fake 'Fetch'.
--
-- The real 'Fetch' adds what every polite client needs: a User-Agent that says
-- who is calling, a timeout, a minimum gap between requests to one host, a
-- short cache of bounded size, and a pause when a host answers HTTP 429.
module Drift.Search.Http
  ( Fetch (..)
  , HttpRequest (..)
  , HttpResponse (..)
  , FetchError (..)
  , HttpConfig (..)
  , defaultHttpConfig
  , newFetch
  , rateLimitWait
  , storeInCache
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (try)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.CaseInsensitive as CI
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
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
  , cacheMaxEntries :: Int
  -- ^ the cache never holds more than this many responses
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
    , cacheMaxEntries = 512
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
    Left (e :: HC.HttpException) -> pure (Left (Network (redactApiKeys (T.pack (show e)))))
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
                  atomicModifyIORef' shared.cache (\m -> (storeInCache cfg.cacheMaxEntries stamp key (expires, resp) m, ()))
                  pure (Right resp)
                else
                  if status == 429
                    then do
                      let wait = rateLimitWait resp.respHeaders
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
  e -> Network (redactApiKeys (T.pack (show e)))

-- | HTTP exceptions include the request URL or a quoted query string. Keep
-- that diagnostic context, but hide API key values regardless of key casing.
-- A quote only ends the shown string when it is not escaped; apostrophes,
-- whitespace and escaped characters can all be part of the credential.
redactApiKeys :: Text -> Text
redactApiKeys input
  | T.toCaseFold (T.take 8 input) == "api_key=" =
      T.take 8 input <> "[REDACTED]" <> redactApiKeys (dropValue (T.drop 8 input))
  | Just (c, rest) <- T.uncons input = T.cons c (redactApiKeys rest)
  | otherwise = ""
  where
    dropValue value = case T.uncons value of
      Just ('\\', rest) -> dropValue (T.drop 1 rest)
      Just (c, rest)
        | c `elem` ['&', '#', '"'] -> value
        | otherwise -> dropValue rest
      Nothing -> ""

-- | Adds a response to the cache. Expired entries are dropped on every
-- insert, and if the cache is still over @limit@ the entries that expire
-- first go, so memory stays bounded in a long-running server.
storeInCache :: Int -> Word64 -> Text -> (Word64, HttpResponse) -> Map Text (Word64, HttpResponse) -> Map Text (Word64, HttpResponse)
storeInCache limit now key entry m
  | Map.size live <= limit = live
  | otherwise = Map.fromList (drop (Map.size live - max 0 limit) (sortOn (fst . snd) (Map.toList live)))
  where
    live = Map.insert key entry (Map.filter (\(expires, _) -> expires > now) m)

-- | Seconds to leave a host alone after it answered 429, from the response's
-- lower-cased headers. Capped at a day.
--
-- OpenAlex answers 429 in two cases: the daily budget is spent, or the client
-- went over its per-second limit. Only the first is worth waiting out until
-- the reset (midnight UTC), and @x-ratelimit-reset@ is on every response, so
-- it is used only when @x-ratelimit-remaining@ says the budget is gone. A
-- per-second 429 with budget left gets a short pause. Without any of these
-- headers (other hosts), the wait is a minute.
rateLimitWait :: [(Text, Text)] -> Int
rateLimitWait headers =
  min 86400 . max 1 $ case (number "retry-after", number "x-ratelimit-remaining") of
    (Just seconds, _) -> ceiling seconds
    (Nothing, Just remaining)
      | remaining <= 0 -> maybe 60 ceiling (number "x-ratelimit-reset")
      | otherwise -> 2
    (Nothing, Nothing) -> 60
  where
    number :: Text -> Maybe Double
    number name = lookup name headers >>= readMaybe . T.unpack . T.strip

secondsBetween :: Word64 -> Word64 -> Int
secondsBetween from to = fromIntegral ((to - from) `div` 1000000000) + 1
