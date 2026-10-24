{-# LANGUAGE OverloadedRecordDot #-}

-- | Tries the source search by hand:
--
-- > drift-sources --live tide moon
--
-- Prints each accepted source as the @SourceFound@ event the session would
-- send, one JSON object per line, and logs what each provider did on stderr.
-- It uses the network only with @--live@, so nothing calls the free public
-- APIs by accident. Set @OPENALEX_API_KEY@ to use a free OpenAlex key.
module Main (main) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Pipeline.Sources (SourceEnv (..), defaultSourceEnv, findSources)
import Drift.Protocol (Event (SourceFound), Lang (En), NodeId (NodeId), SourceId (SourceId))
import Drift.Search.Http (defaultHttpConfig, newFetch)
import Drift.Search.Types (SourceRequest (..), toSource)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitWith, ExitCode (ExitFailure))
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

data Options = Options
  { live :: Bool
  , maxPerEdge :: Int
  , resolveDoi :: Bool
  , words' :: [Text]
  }

parse :: [String] -> Either String Options
parse = go (Options False 2 True [])
  where
    go o = \case
      [] -> Right o {words' = reverse o.words'}
      "--live" : rest -> go o {live = True} rest
      "--no-doi" : rest -> go o {resolveDoi = False} rest
      "--max" : n : rest | Just k <- readMaybe n, k > 0 -> go o {maxPerEdge = k} rest
      "--max" : _ -> Left "--max needs a positive number"
      flag@('-' : '-' : _) : _ -> Left ("unknown option " <> flag)
      w : rest -> go o {words' = T.pack w : o.words'} rest

usage :: String
usage = "usage: drift-sources --live [--max N] [--no-doi] FROM TO   (or one word for a root node)"

main :: IO ()
main = do
  parsed <- parse <$> getArgs
  case parsed of
    Left err -> failWith (err <> "\n" <> usage)
    Right opts
      | not opts.live -> failWith ("refusing to use the network without --live\n" <> usage)
      | otherwise -> case opts.words' of
          [to] -> run opts (SourceRequest Nothing to [] En)
          [from, to] -> run opts (SourceRequest (Just from) to [from] En)
          _ -> failWith usage
  where
    failWith msg = hPutStrLn stderr msg >> exitWith (ExitFailure 2)

run :: Options -> SourceRequest -> IO ()
run opts req = do
  key <- fmap T.pack <$> lookupEnv "OPENALEX_API_KEY"
  fetch <- newFetch defaultHttpConfig
  next <- newIORef (1 :: Int)
  let env =
        (defaultSourceEnv fetch)
          { envOpenAlexKey = key
          , envMaxPerEdge = opts.maxPerEdge
          , envResolveCsl = opts.resolveDoi
          , envLog = hPutStrLn stderr . T.unpack
          }
  findSources env req $ \draft -> do
    n <- atomicModifyIORef' next (\i -> (i + 1, i))
    LBS.putStrLn (encode (SourceFound (toSource (SourceId n) (NodeId 1) draft)))
