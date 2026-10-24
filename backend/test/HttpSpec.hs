module HttpSpec (spec) where

import qualified Data.Text as T
import Drift.Search.Http (Fetch (..), FetchError (..), HttpRequest (..), defaultHttpConfig, newFetch)
import Test.Hspec

spec :: Spec
spec = describe "Drift.Search.Http" $ do
  it "redacts API key values in HTTP errors while preserving request context" $ do
    fetch <- newFetch defaultHttpConfig
    result <- runFetch fetch (HttpRequest "invalid://example.org/works?api_key=secret-value&search=moon" [] [])
    case result of
      Left (Network message) -> do
        message `shouldSatisfy` (not . T.isInfixOf "secret-value")
        message `shouldSatisfy` T.isInfixOf "example.org/works"
        message `shouldSatisfy` T.isInfixOf "search=moon"
      other -> expectationFailure ("expected a diagnostic network error, got " <> show other)

  it "redacts API key names case-insensitively" $ do
    fetch <- newFetch defaultHttpConfig
    result <- runFetch fetch (HttpRequest "invalid://example.org/works?ApI_KeY=mixed-secret&search=moon" [] [])
    case result of
      Left (Network message) -> do
        message `shouldSatisfy` (not . T.isInfixOf "mixed-secret")
        message `shouldSatisfy` T.isInfixOf "search=moon"
      other -> expectationFailure ("expected a diagnostic network error, got " <> show other)

  it "redacts API keys when sending a parsed request fails" $ do
    fetch <- newFetch defaultHttpConfig
    result <- runFetch fetch (HttpRequest "http://127.0.0.1:0/works" [("api_key", "connection-secret"), ("search", "moon")] [])
    case result of
      Left (Network message) -> do
        message `shouldSatisfy` (not . T.isInfixOf "connection-secret")
        message `shouldSatisfy` T.isInfixOf "127.0.0.1"
        message `shouldSatisfy` T.isInfixOf "search=moon"
      other -> expectationFailure ("expected a diagnostic network error, got " <> show other)
