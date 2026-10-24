{-# LANGUAGE OverloadedRecordDot #-}

-- | Exact reference metadata for a DOI, by content negotiation on doi.org
-- (@Accept: application\/vnd.citationstyles.csl+json@). doi.org answers 200
-- with the record, 204 when it has no metadata, 404 for an unknown DOI.
module Drift.Sources.Doi
  ( fetchCsl
  ) where

import Data.Aeson (Value, decode)
import Data.Text (Text)
import Drift.Search.Http (Fetch (..), HttpRequest (..), HttpResponse (..))
import Drift.Search.Text (doiUrl)
import Drift.Sources.Csl (normalizeCrossrefCsl)

-- | The cleaned CSL-JSON for a normalized DOI, or Nothing for any failure:
-- the caller falls back to the metadata it already has.
fetchCsl :: Fetch -> Text -> IO (Maybe Value)
fetchCsl fetch doi = do
  r <- fetch.runFetch (HttpRequest (doiUrl doi) [] [("Accept", "application/vnd.citationstyles.csl+json")])
  pure $ case r of
    Right resp | resp.respStatus == 200 -> decode resp.respBody >>= normalizeCrossrefCsl
    _ -> Nothing
