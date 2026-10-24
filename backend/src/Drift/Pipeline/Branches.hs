{-# LANGUAGE OverloadedRecordDot #-}

-- | Pure candidate parsing, normalization, filtering, and semantic selection.
-- Provider IO deliberately lives outside this module so streaming adapters and
-- speculative caches can share the same deterministic policy.
module Drift.Pipeline.Branches
  ( Embedding
  , BranchContext (..)
  , StreamParser
  , emptyStreamParser
  , feedCandidateChunk
  , finishCandidateStream
  , normalizeWord
  , filterCandidates
  , repeatCap
  , cosineDistance
  , divergenceBand
  , selectCandidates
  , buildBranchPrompt
  ) where

import Data.Char (GeneralCategory (..), generalCategory, isAlphaNum, isDigit, isSpace)
import Data.List (maximumBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Normalize (NormalizationMode (NFKC), normalize)

type Embedding = [Double]

data BranchContext = BranchContext
  { currentWord :: Text
  , pathToRoot :: [Text]
  , divergence :: Double
  , chosenWords :: Set.Set Text
  , appearanceCounts :: Map.Map Text Int
  , branchCount :: Int
  }
  deriving stock (Eq, Show)

newtype StreamParser = StreamParser Text
  deriving stock (Eq, Show)

emptyStreamParser :: StreamParser
emptyStreamParser = StreamParser T.empty

-- | Feed an arbitrary model-output fragment. A token is emitted only after a
-- delimiter arrives, so a chunk boundary can never truncate a word.
feedCandidateChunk :: StreamParser -> Text -> (StreamParser, [Text])
feedCandidateChunk (StreamParser pending) chunk =
  let (complete, remainder) = splitComplete (pending <> chunk)
   in (StreamParser remainder, mapMaybe cleanCandidate complete)

finishCandidateStream :: StreamParser -> [Text]
finishCandidateStream (StreamParser pending) = maybe [] pure (cleanCandidate pending)

splitComplete :: Text -> ([Text], Text)
splitComplete = go []
 where
  go complete input =
    let (candidate, rest) = T.break isDelimiter input
     in if T.null rest
          then (reverse complete, candidate)
          else go (candidate : complete) (T.drop 1 rest)

  isDelimiter c = c == ',' || c == ';' || c == '\n' || c == '\r' || c == '|'

cleanCandidate :: Text -> Maybe Text
cleanCandidate raw =
  let candidate = stripBoundaryPunctuation (stripNumberPrefix (stripBoundaryPunctuation raw))
   in if validCandidate candidate then Just candidate else Nothing

stripNumberPrefix :: Text -> Text
stripNumberPrefix text =
  let (digits, rest) = T.span isDigit text
   in if not (T.null digits) && maybe False (`elem` ['.', ')', ':']) (fst <$> T.uncons rest)
        then T.drop 1 rest
        else text

stripBoundaryPunctuation :: Text -> Text
stripBoundaryPunctuation = T.dropAround (not . isWordEdge) . T.strip
 where
  isWordEdge c = isAlphaNum c || isMark c

validCandidate :: Text -> Bool
validCandidate candidate =
  not (T.null candidate)
    && not (T.any isSpace candidate)
    && T.all isWordCharacter candidate
 where
  isWordCharacter c = isAlphaNum c || isMark c || c `elem` ['-', '\'', '’']

isMark :: Char -> Bool
isMark c = generalCategory c `elem` [NonSpacingMark, SpacingCombiningMark, EnclosingMark]

normalizeWord :: Text -> Text
normalizeWord = T.toCaseFold . normalize NFKC . T.strip

-- | Apply loop prevention and stable per-batch de-duplication. Returned words
-- are normalized keys, which keeps downstream IDs and counts deterministic.
filterCandidates :: BranchContext -> [Text] -> [Text]
filterCandidates context candidates = reverse accepted
 where
  normalizedChosen = Set.insert (normalizeWord context.currentWord) (Set.map normalizeWord context.chosenWords)
  normalizedCounts = Map.fromListWith (+) [(normalizeWord word, count) | (word, count) <- Map.toList context.appearanceCounts]
  cap = repeatCap context.divergence
  (_, accepted) = foldl' step (Set.empty, []) candidates

  step (seen, result) candidate =
    let key = normalizeWord candidate
        permitted =
          not (T.null key)
            && validCandidate key
            && Set.notMember key normalizedChosen
            && Map.findWithDefault 0 key normalizedCounts < cap
            && Set.notMember key seen
     in if permitted then (Set.insert key seen, key : result) else (seen, result)

-- | Offered-but-unchosen words may recur four times at minimum divergence and
-- only once at maximum divergence. Clamping makes the pure helper total while
-- external command/config boundaries remain responsible for rejecting bad input.
repeatCap :: Double -> Int
repeatCap value = 1 + floor (3 * (1 - clamp01 value))

cosineDistance :: Embedding -> Embedding -> Maybe Double
cosineDistance left right
  | null left || length left /= length right = Nothing
  | any invalidNumber left || any invalidNumber right = Nothing
  | leftNorm <= 0 || rightNorm <= 0 = Nothing
  | otherwise = Just (clamp 0 2 (1 - dot / (sqrt leftNorm * sqrt rightNorm)))
 where
  dot = sum (zipWith (*) left right)
  leftNorm = sum (map (\x -> x * x) left)
  rightNorm = sum (map (\x -> x * x) right)
  invalidNumber x = isNaN x || isInfinite x

-- | Map the UI slider to a narrow cosine-distance target. Low and high slider
-- settings have disjoint bands, making semantic divergence observable.
divergenceBand :: Double -> (Double, Double)
divergenceBand value =
  let center = 0.1 + 0.8 * clamp01 value
      halfWidth = 0.18
   in (max 0 (center - halfWidth), min 2 (center + halfWidth))

-- | Select in-band embeddings with deterministic Maximal Marginal Relevance.
-- If any embedding is unavailable, zero length, or dimensionally incompatible,
-- preserve provider order instead of returning a partial or surprising result.
selectCandidates :: Int -> Double -> Maybe Embedding -> [(Text, Maybe Embedding)] -> [Text]
selectCandidates wanted divergenceValue maybeAnchor candidates
  | wanted <= 0 = []
  | otherwise = case validEmbeddingSet maybeAnchor candidates of
      Nothing -> promptOrder
      Just (anchor, embedded) ->
        let (bandMin, bandMax) = divergenceBand divergenceValue
            target = (bandMin + bandMax) / 2
            inBand =
              [ EmbeddedCandidate index word vector distance
              | (index, (word, vector)) <- zip [0 ..] embedded
              , Just distance <- [cosineDistance anchor vector]
              , distance >= bandMin
              , distance <= bandMax
              ]
         in if null inBand then promptOrder else map candidateWord (mmr wanted target inBand)
 where
  promptOrder = take wanted (map fst candidates)
data EmbeddedCandidate = EmbeddedCandidate
  { candidateIndex :: Int
  , candidateWord :: Text
  , candidateVector :: Embedding
  , candidateDistance :: Double
  }

validEmbeddingSet :: Maybe Embedding -> [(Text, Maybe Embedding)] -> Maybe (Embedding, [(Text, Embedding)])
validEmbeddingSet maybeAnchor candidates = do
  anchor <- maybeAnchor
  if usable anchor then pure () else Nothing
  embedded <- traverse requireEmbedding candidates
  if all ((== length anchor) . length . snd) embedded then Just (anchor, embedded) else Nothing
 where
  requireEmbedding (word, maybeVector) = do
    vector <- maybeVector
    if usable vector then Just (word, vector) else Nothing
  usable vector = not (null vector) && all (\x -> not (isNaN x || isInfinite x)) vector && sum (map (\x -> x * x) vector) > 0

mmr :: Int -> Double -> [EmbeddedCandidate] -> [EmbeddedCandidate]
mmr wanted target = go []
 where
  go selected remaining
    | length selected >= wanted || null remaining = selected
    | otherwise =
        let best = maximumBy (compareCandidate selected) remaining
         in go (selected <> [best]) (filter ((/= best.candidateIndex) . candidateIndex) remaining)

  compareCandidate selected left right =
    compare (score selected left, negate left.candidateIndex) (score selected right, negate right.candidateIndex)

  score selected candidate =
    let relevance = 1 - abs (candidate.candidateDistance - target) / 2
        diversity = case selected of
          [] -> 0
          _ -> minimum (mapMaybe (cosineDistance candidate.candidateVector . candidateVector) selected)
     in 0.65 * relevance + 0.35 * diversity

buildBranchPrompt :: BranchContext -> Text
buildBranchPrompt context =
  T.unlines
    [ "Generate " <> showText (max 1 (context.branchCount * 2)) <> " candidate branches for the current word."
    , "Current word: " <> context.currentWord
    , "Path from root: " <> T.intercalate " -> " context.pathToRoot
    , "Divergence: " <> showText context.divergence
    , "Return concrete associations as one word per line, with no numbering or explanation."
    ]

showText :: Show a => a -> Text
showText = T.pack . show

clamp01 :: Double -> Double
clamp01 = clamp 0 1

clamp :: Ord a => a -> a -> a -> a
clamp lower upper = max lower . min upper

