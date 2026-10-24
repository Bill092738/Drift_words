{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Checks the wire contract: every fixture the frontend replays must decode
-- into the Haskell protocol types, and encoding must round-trip.
module ProtocolSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict, encode, decode)
import qualified Data.ByteString.Char8 as BS
import Data.List (isSuffixOf, sort)
import Drift.Protocol
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

fixturesDir :: FilePath
fixturesDir = "../protocol/fixtures"

roundTrips :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
roundTrips v = decode (encode v) `shouldBe` Just v

spec :: Spec
spec = do
  describe "encoding" $ do
    it "tags sum types with a \"type\" field" $
      encode (Pick {candidateId = CandidateId 3})
        `shouldBe` "{\"type\":\"Pick\",\"candidateId\":3}"

    it "encodes nullary constructors as tagged objects" $
      encode WrapUp `shouldBe` "{\"type\":\"WrapUp\"}"

    it "encodes enums as camelCase strings" $ do
      encode [En, Zh] `shouldBe` "[\"en\",\"zh\"]"
      encode [StartWord, Insert] `shouldBe` "[\"startWord\",\"insert\"]"
      encode WebPage `shouldBe` "\"webPage\""

    it "round-trips client messages" $
      roundTrips (ClientMsg {req = 7, command = PlaceNode {node = NodeId 2, pos = Vec2 1.5 (-3), angle = 0.2}})

    it "round-trips server messages" $ do
      roundTrips (Rejected {req = 7, reason = "unknown candidate"})
      roundTrips (Diagnostic {level = LevelWarning, message = "retrying"})

    it "encodes diagnostics with plain level names" $
      encode (Diagnostic {level = LevelError, message = "model down"})
        `shouldBe` "{\"type\":\"Diagnostic\",\"level\":\"error\",\"message\":\"model down\"}"

  fixtures <- runIO (sort . filter (".jsonl" `isSuffixOf`) <$> listDirectory fixturesDir)

  describe "protocol fixtures" $ do
    it "exist" $ fixtures `shouldNotBe` []

    forM_ fixtures $ \name -> describe name $ do
      ls <- runIO (filter (not . BS.null) . BS.lines <$> BS.readFile (fixturesDir </> name))
      let decoded = traverse (eitherDecodeStrict @Stamped) ls

      it "decodes every line as a Stamped event" $
        either expectationFailure (const (pure ())) decoded

      forM_ decoded $ \events -> do
        it "numbers events 1, 2, 3, ..." $
          map (.seq) events `shouldBe` [1 .. length events]

        it "has non-decreasing timestamps" $
          let ts = map (.atMs) events in and (zipWith (<=) ts (drop 1 ts)) `shouldBe` True

        it "round-trips through JSON" $
          forM_ events roundTrips
