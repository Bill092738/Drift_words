{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module EntriesSpec (spec) where

import Data.Either (isLeft)
import qualified Data.Map.Strict as Map
import Drift.Domain.Entries
import Drift.Protocol
import Test.Hspec
import Test.QuickCheck

mkEntry :: Int -> Entry
mkEntry n =
  Entry {entryId = EntryId n, node = NodeId (n + 1), relation = "r", explanation = "e", cites = []}

written :: [Int] -> Entries
written ns = foldl (\acc (sq, n) -> applyEntryEvent sq (EntryWritten {entry = mkEntry n}) acc) emptyEntries (zip [1 ..] ns)

-- | Runs commands through decide and apply, keeping only accepted events.
run :: Entries -> [Command] -> (Entries, [Event])
run start = foldl step (start, [])
  where
    step (s, evs) c = case decideCuration s c of
      Just (Right new) -> (foldl (flip (applyEntryEvent 0)) s new, evs <> new)
      _ -> (s, evs)

newtype Curation = Curation Command deriving stock (Show)

instance Arbitrary Curation where
  arbitrary = do
    i <- EntryId <$> choose (1, 4)
    Curation
      <$> oneof
        [ (\n -> Promote {entryId = i, levels = n}) <$> choose (-1, 3)
        , pure (Strike {entryId = i})
        , pure (Restore {entryId = i})
        ]

spec :: Spec
spec = do
  describe "decideCuration" $ do
    let s = written [1]

    it "ignores commands that are not curation" $
      decideCuration s WrapUp `shouldBe` Nothing

    it "promotes by several levels at once" $
      decideCuration s (Promote {entryId = EntryId 1, levels = 3})
        `shouldBe` Just (Right [EntryPromoted {entryId = EntryId 1, levels = 3}])

    it "rejects promotions of less than one level" $
      fmap isLeft (decideCuration s (Promote {entryId = EntryId 1, levels = 0})) `shouldBe` Just True

    it "rejects unknown entries" $
      decideCuration s (Strike {entryId = EntryId 9}) `shouldBe` Just (Left "unknown entry")

    it "strikes, then restores" $ do
      let (s', evs) = run s [Strike {entryId = EntryId 1}, Strike {entryId = EntryId 1}, Restore {entryId = EntryId 1}]
      evs `shouldBe` [EntryStruck {entryId = EntryId 1}, EntryRestored {entryId = EntryId 1}]
      fmap (.struck) (Map.lookup (EntryId 1) s') `shouldBe` Just False

    it "lets struck entries be promoted" $
      fst (run s [Strike {entryId = EntryId 1}, Promote {entryId = EntryId 1, levels = 2}])
        `shouldSatisfy` (\t -> fmap (\e -> (e.struck, e.priority)) (Map.lookup (EntryId 1) t) == Just (True, 2))

  describe "applyEntryEvent" $ do
    it "keeps priority and strike state when an entry is revised" $ do
      let s = fst (run (written [1]) [Promote {entryId = EntryId 1, levels = 2}, Strike {entryId = EntryId 1}])
          revised = (mkEntry 1) {cites = [SourceId 4]}
          t = applyEntryEvent 9 (EntryRevised {entry = revised}) s
      Map.lookup (EntryId 1) t
        `shouldBe` Just EntryState {entry = revised, priority = 2, struck = True, writtenSeq = 1}

    it "ignores events for unknown entries" $
      applyEntryEvent 1 (EntryStruck {entryId = EntryId 5}) (written [1]) `shouldBe` written [1]

  describe "properties" $ do
    it "priority is the sum of accepted promotions and never negative" $
      property $ \(cs :: [Curation]) ->
        let cmds = [c | Curation c <- cs]
            (s, evs) = run (written [1, 2, 3]) cmds
         in conjoin
              [ fmap (.priority) (Map.lookup i s)
                  === Just (sum [n | EntryPromoted {entryId = j, levels = n} <- evs, j == i])
              | i <- map EntryId [1, 2, 3]
              ]

    it "strike and restore alternate for every entry" $
      property $ \(cs :: [Curation]) ->
        let (_, evs) = run (written [1, 2, 3]) [c | Curation c <- cs]
            toggles i = [b | e <- evs, Just (j, b) <- [toggle e], j == i]
            toggle = \case
              EntryStruck {entryId = j} -> Just (j, True)
              EntryRestored {entryId = j} -> Just (j, False)
              _ -> Nothing
         in conjoin [and (zipWith (/=) ts (drop 1 ts)) && take 1 ts `elem` [[], [True]] | i <- map EntryId [1, 2, 3], let ts = toggles i]

    it "replaying the log gives the live table" $
      property $ \(cs :: [Curation]) ->
        let start = written [1, 2, 3]
            (live, evs) = run start [c | Curation c <- cs]
            writes = [EntryWritten {entry = mkEntry n} | n <- [1, 2, 3]]
            logged = zipWith (\n e -> Stamped {seq = n, atMs = 0, event = e}) [1 ..] (writes <> evs)
         in replayEntries logged === live
