{-# LANGUAGE OverloadedRecordDot #-}

-- | The starting word cloud from the model (idea.md: "a cloud of random words
-- drifts across the desktop").
--
-- A model asked the same question gives much the same answer (Gemini starts
-- most lists with "anchor" and "tide"), so each prompt names a few domains
-- drawn at random, asks for three times as many words as needed, and the cloud
-- is a random sample of them. The words go through the same parsing and
-- normalization as branch words. When the model fails, is slow, or returns too few words, the
-- offline vocabulary is used, so a session can always start.
module Drift.Pipeline.Cloud
  ( cloudSize
  , buildCloudPrompt
  , parseCloud
  , modelCloud
  ) where

import Control.Exception (SomeException, try)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import Drift.Model.Provider (GenRequest (..), ModelProvider (..))
import Drift.Model.SessionMock (mockCloud)
import Drift.Pipeline.Branches
import Drift.Protocol (Lang (..))
import GHC.Clock (getMonotonicTimeNSec)
import System.Timeout (timeout)

-- | Words in the starting cloud, as in the frontend's offline mock.
cloudSize :: Int
cloudSize = 12

-- | The prompt for one cloud. @domains@ steer the model away from giving
-- every session the same words.
buildCloudPrompt :: Lang -> [Text] -> Text
buildCloudPrompt lang domains =
  T.unlines
    [ "List " <> T.pack (show (cloudSize * 3)) <> " single words to start a free-association game."
    , "Mix concrete nouns, verbs and abstract ideas. Spread them widely: draw some from " <> T.intercalate ", " domains <> ", and the rest from anywhere."
    , "Prefer evocative, common words over rare or technical ones. No names of people, brands or places."
    , "Return one word per line, with no numbering or explanation."
    , case lang of
        En -> "Write in English."
        Zh -> "Write in Simplified Chinese."
    ]

-- | The words of a reply, normalized and without repeats, in reply order.
parseCloud :: Text -> [Text]
parseCloud raw =
  let (parser, complete) = feedCandidateChunk emptyStreamParser raw
      parsed = complete <> finishCandidateStream parser
   in filterCandidates anyWord parsed
  where
    anyWord =
      BranchContext
        { currentWord = ""
        , pathToRoot = []
        , divergence = 0.5
        , chosenWords = Set.empty
        , appearanceCounts = Map.empty
        , branchCount = cloudSize * 3
        }

-- | A cloud from the model, or the offline vocabulary when the model fails,
-- takes longer than @seconds@, or gives fewer than half the words. The text
-- passed to @report@ says which happened, for the server log.
modelCloud :: (Text -> IO ()) -> Int -> ModelProvider -> Text -> Lang -> IO [Text]
modelCloud report seconds provider model lang = do
  seed <- getMonotonicTimeNSec
  let request = GenRequest (buildCloudPrompt lang (pickDomains seed)) model 1 0
  result <- try @SomeException (timeout (seconds * 1000000) (provider.generate request (const (pure ()))))
  case fmap (fmap parseCloud) result of
    Right (Just ws) | length ws >= cloudSize `div` 2 -> pure (take cloudSize (shuffle seed ws))
    Right (Just ws) -> fallback ("the model gave only " <> T.pack (show (length ws)) <> " usable words")
    Right Nothing -> fallback ("the model took longer than " <> T.pack (show seconds) <> " s")
    Left e -> fallback (T.take 200 (T.pack (show e)))
  where
    fallback why = do
      report ("cloud: using the offline words, because " <> why)
      pure (mockCloud lang)

-- | A permutation of @xs@ chosen by @seed@ (a linear congruential generator;
-- good enough to vary a word cloud).
shuffle :: Word64 -> [a] -> [a]
shuffle seed xs = map snd (sortOn fst (zip keys xs))
  where
    keys = drop 1 (iterate (\k -> k * 6364136223846793005 + 1442695040888963407) seed)

-- | Three different domains, chosen from the clock.
pickDomains :: Word64 -> [Text]
pickDomains seed =
  let n = fromIntegral (length domainList) :: Word64
      pick k = fromIntegral ((seed `div` (7919 ^ k)) `mod` n)
      indices = take 3 (dedupe (map pick [1 .. 12 :: Int]))
   in map (domainList !!) indices
  where
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) [] . reverse

domainList :: [Text]
domainList =
  [ "the sea", "cooking", "the night sky", "music", "weather", "machines", "gardens", "cities"
  , "the body", "childhood", "travel", "money", "language", "games", "light and colour", "animals"
  , "tools", "time", "memory", "work", "rivers and mountains", "dreams", "trade", "medicine"
  , "architecture", "rituals", "insects", "winter", "the forest", "the kitchen", "maps", "letters"
  ]
