{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

-- | The HTTP surface of the backend. The session WebSocket is added in M1.
module Drift.Api
  ( Api
  , api
  , server
  ) where

import Data.Text (Text)
import Servant

type Api = "api" :> "health" :> Get '[PlainText] Text

api :: Proxy Api
api = Proxy

server :: Server Api
server = pure "ok"
