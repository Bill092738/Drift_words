{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module DraftSpec (spec) where

import Citeproc (Style)
import Citeproc.CslJson (CslJson)
import Data.Aeson (Value, decode)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Maybe (fromJust)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Domain.Entries (EntryState (..))
import Drift.Output.Cite (Rendered (..), apaStyle, renderCitations)
import Drift.Output.Draft
import Drift.Protocol
import Test.Hspec

style' :: IO (Style (CslJson Text))
style' = either (\e -> fail ("APA style does not parse: " <> T.unpack e)) pure apaStyle

stamped :: [Event] -> [Stamped]
stamped = zipWith (\n e -> Stamped n 1700000000000 e) [1 ..]

fixtureLog :: FilePath -> IO [Stamped]
fixtureLog name = do
  raw <- LBS.readFile ("../protocol/fixtures/" <> name)
  pure [s | l <- LBS8.lines raw, Just s <- [decode l :: Maybe Stamped]]

csl :: FilePath -> IO Value
csl name = fromJust . decode <$> LBS.readFile ("test/fixtures/" <> name)

paperSource :: Int -> Int -> Text -> Value -> Source
paperSource sid node title c =
  Source (SourceId sid) (NodeId node) Paper title (Just "Journal") ("https://doi.org/10.1/p" <> T.pack (show sid)) Nothing (Just c)

written :: Int -> Int -> Text -> Text -> [Int] -> Event
written eid node relation explanation cites =
  EntryWritten (Entry (EntryId eid) (NodeId node) relation explanation (map SourceId cites))

root, child :: Event
root = NodeChosen (NodeId 1) Nothing "tide" Cloud Nothing
child = NodeChosen (NodeId 2) (Just (NodeId 1)) "moon" Branch Nothing

spec :: Spec
spec = describe "Drift.Output.Draft" $ do
  describe "from the exploration fixture" $ do
    it "lists every entry in order, with the struck one crossed out" $ do
      st <- style'
      evs <- fixtureLog "exploration.jsonl"
      let md = draftMarkdown st evs
          numbered = [l | l <- T.lines md, any (\n -> T.pack (show (n :: Int) <> ". ") `T.isPrefixOf` l) [1 .. 5]]
      length numbered `shouldBe` 5
      take 1 (T.lines md) `shouldBe` ["# Draft: from entropy to flow"]
      case [l | l <- numbered, "~~" `T.isInfixOf` l] of
        [struck] -> do
          struck `shouldSatisfy` T.isPrefixOf "3. ~~"
          struck `shouldSatisfy` T.isSuffixOf "~~"
        other -> expectationFailure ("expected one struck line, got " <> show other)

    it "never shows a raw citation key" $ do
      st <- style'
      evs <- fixtureLog "exploration.jsonl"
      T.unpack (draftMarkdown st evs) `shouldNotContain` "[@src"
      T.unpack (draftMarkdown st evs) `shouldNotContain` "@src"

    it "references exactly the sources the entries cite (invariant 6)" $ do
      st <- style'
      evs <- fixtureLog "exploration.jsonl"
      let entries = orderedEntries evs
          cited = Set.fromList [sid | e <- entries, sid <- e.entry.cites, sid `Map.member` sourcesOf evs]
          r = renderCitations st (sourcesOf evs) (map (\e -> e.entry.cites) entries)
      Set.fromList (map fst r.bibliography) `shouldBe` cited
      length r.bibliography `shouldBe` Set.size cited
      Set.size cited `shouldBe` 5
      T.unpack (draftMarkdown st evs) `shouldContain` "## References"

    it "keeps the sources of struck entries in the reference list" $ do
      st <- style'
      n <- csl "csl-nature.json"
      let evs =
            stamped
              [ root
              , child
              , SourceFound (paperSource 1 2 "Moon, tides and climate" n)
              , written 1 2 "tide pulls on moon" "A struck thought." [1]
              , EntryStruck (EntryId 1)
              ]
          md = draftMarkdown st evs
      T.unpack md `shouldContain` "~~"
      T.unpack md `shouldContain` "Wunsch, C. (2000)"

  describe "entries" $ do
    it "puts the citation before the closing full stop" $ do
      st <- style'
      n <- csl "csl-nature.json"
      let evs = stamped [root, child, SourceFound (paperSource 1 2 "t" n), written 1 2 "Tides follow the moon" "The moon pulls the sea." [1]]
      T.lines (draftMarkdown st evs) !! 2
        `shouldBe` "1. **Tides follow the moon.** The moon pulls the sea (Wunsch, 2000)."

    it "adds a full stop when the explanation has none, and handles an empty explanation" $ do
      st <- style'
      n <- csl "csl-nature.json"
      let evs =
            stamped
              [ root
              , child
              , SourceFound (paperSource 1 2 "t" n)
              , written 1 2 "Tides follow the moon" "The moon pulls the sea" [1]
              , written 2 2 "Only a relation" "" [1]
              ]
          ls = T.lines (draftMarkdown st evs)
      ls !! 2 `shouldBe` "1. **Tides follow the moon.** The moon pulls the sea (Wunsch, 2000)."
      ls !! 3 `shouldBe` "2. **Only a relation.** (Wunsch, 2000)"

    it "leaves out citations of sources that were never retrieved" $ do
      st <- style'
      let evs = stamped [root, child, written 1 2 "A claim" "Said without support." [9]]
          md = draftMarkdown st evs
      T.lines md !! 2 `shouldBe` "1. **A claim.** Said without support."
      T.unpack md `shouldNotContain` "References"

    it "escapes markup in entry text" $ do
      st <- style'
      let evs = stamped [root, child, written 1 2 "A *bold* [link](http://evil.example)" "<script>x</script> and _more_" []]
          md = draftMarkdown st evs
      T.unpack md `shouldNotContain` "<script>"
      T.unpack md `shouldNotContain` "[link]"
      T.unpack md `shouldContain` "\\*bold\\*"

    it "keeps entries in the order they were written, not the order of their ids" $ do
      st <- style'
      let evs = stamped [root, child, written 7 2 "Second id, first written" "A." [], written 3 2 "First id, second written" "B." []]
          ls = T.lines (draftMarkdown st evs)
      ls !! 2 `shouldBe` "1. **Second id, first written.** A."
      ls !! 3 `shouldBe` "2. **First id, second written.** B."

    it "shows a revised entry once, with its latest text" $ do
      st <- style'
      n <- csl "csl-nature.json"
      let evs =
            stamped
              [ root
              , child
              , written 1 2 "Tides follow the moon" "Before." []
              , SourceFound (paperSource 1 2 "t" n)
              , EntryRevised (Entry (EntryId 1) (NodeId 2) "Tides follow the moon" "Before." [SourceId 1])
              ]
          ls = T.lines (draftMarkdown st evs)
      length [l | l <- ls, "**Tides follow the moon.**" `T.isInfixOf` l] `shouldBe` 1
      ls !! 2 `shouldBe` "1. **Tides follow the moon.** Before (Wunsch, 2000)."

  describe "small sessions" $ do
    it "has a title and a note when nothing is written yet" $ do
      st <- style'
      draftMarkdown st [] `shouldBe` "# Draft\n\n_No entries yet._"
      draftMarkdown st (stamped [root]) `shouldBe` "# Draft: tide\n\n_No entries yet._"
    it "titles a path from its first word to its last" $
      pathTitle (stamped [root, child]) `shouldBe` Just "from tide to moon"
    it "ends the final title at the last word the user kept" $ do
      let grandchild = NodeChosen (NodeId 3) (Just (NodeId 2)) "gravity" Branch Nothing
          note n i = EntryWritten (Entry (EntryId i) (NodeId n) "r" "" [])
          evs = [root, child, note 2 1, grandchild, note 3 2]
      keptPathTitle (stamped evs) `shouldBe` Just "from tide to gravity"
      keptPathTitle (stamped (evs <> [EntryStruck (EntryId 2)])) `shouldBe` Just "from tide to moon"
      pathTitle (stamped (evs <> [EntryStruck (EntryId 2)])) `shouldBe` Just "from tide to gravity"
