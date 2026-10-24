{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module FinalSpec (spec) where

import Citeproc (Style)
import Citeproc.CslJson (CslJson)
import Control.Exception (AsyncException (ThreadKilled), throwIO)
import Data.Aeson (decode)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Drift.Domain.Entries (EntryState (..))
import Drift.Output.Cite (Rendered (..), apaStyle, renderCitations)
import Drift.Output.Draft (orderedEntries, sourcesOf)
import Drift.Output.Final
import Drift.Pipeline.Citations (Grounded (..), groundCitations, sourceKey)
import Drift.Protocol
import Test.Hspec
import Test.QuickCheck (Positive (..), conjoin, ioProperty, property, (===))

style' :: IO (Style (CslJson Text))
style' = either (\e -> fail ("APA style does not parse: " <> T.unpack e)) pure apaStyle

fixtureLog :: IO [Stamped]
fixtureLog = do
  raw <- LBS.readFile "../protocol/fixtures/exploration.jsonl"
  pure [s | l <- LBS8.lines raw, Just s <- [decode l :: Maybe Stamped]]

-- | Entries 1, 4 and 5 were promoted, entry 3 was struck, entry 2 was left alone.
-- Entry 2 is the only one that cites source 3.
retainedIds :: [Int]
retainedIds = [1, 4, 5]

idOf :: EntryState -> Int
idOf st = let EntryId n = st.entry.entryId in n

textOf :: [Stamped] -> Int -> (Text, Text)
textOf evs n = case [(st.entry.relation, st.entry.explanation) | st <- orderedEntries evs, idOf st == n] of
  x : _ -> x
  [] -> ("", "")

sourceIds :: [SourceId] -> [Int]
sourceIds ids = [n | SourceId n <- ids]

-- | A model that answers by section topic, and remembers every prompt.
cannedModel :: IO (Generate, IO [Text])
cannedModel = do
  seen <- newIORef []
  let model prompt = do
        modifyIORef' seen (prompt :)
        pure $
          if "Passage topic: information" `T.isInfixOf` prompt
            then "Entropy measures how surprising a message is [@src1], and a less predictable source carries more information [@src2].\n\nThat is why information is the thing being counted."
            else "Attention is the scarce resource when information is abundant [@src4]. Flow is attention fully absorbed [@src5], and noise is unrelated [@src3]."
  pure (model, reverse <$> readIORef seen)

-- | The sources the draft cites: every entry, struck or not.
draftRefs :: Style (CslJson Text) -> [Stamped] -> Set.Set SourceId
draftRefs st evs = Set.fromList (map fst (renderCitations st (sourcesOf evs) (map (\e -> e.entry.cites) (orderedEntries evs))).bibliography)

keptCites :: [Stamped] -> Set.Set SourceId
keptCites evs = Set.fromList [i | st <- retainedEntries defaultFinalOptions evs, i <- st.entry.cites, i `Map.member` sourcesOf evs]

stamped :: [Event] -> [Stamped]
stamped = zipWith (\n e -> Stamped n 1700000000000 e) [1 ..]

spec :: Spec
spec = describe "Drift.Output.Final" $ do
  describe "which entries are kept" $ do
    it "keeps the promoted, un-struck entries of the fixture, in order" $ do
      evs <- fixtureLog
      map idOf (retainedEntries defaultFinalOptions evs) `shouldBe` retainedIds

    it "raises the bar with the minimum priority" $ do
      evs <- fixtureLog
      -- entries 1 and 5 were promoted by two levels, entry 4 by one
      map idOf (retainedEntries defaultFinalOptions {minPriority = 2} evs) `shouldBe` [1, 5]
      map idOf (retainedEntries defaultFinalOptions {minPriority = 3} evs) `shouldBe` []

    it "splits the walk at the backtrack into the two sections the fixture shows" $ do
      evs <- fixtureLog
      let secs = sectionsOf evs (retainedEntries defaultFinalOptions evs)
      map (.sectionWord) secs `shouldBe` ["information", "attention"]
      map (map idOf . (.sectionEntries)) secs `shouldBe` [[1], [4, 5]]

  describe "with a model" $ do
    it "writes sections under headings, with the title of the walk" $ do
      st <- style'
      evs <- fixtureLog
      (model, _) <- cannedModel
      doc <- finalMarkdown (Just model) defaultFinalOptions st evs
      take 1 (T.lines doc.finalText) `shouldBe` ["# From entropy to flow"]
      let headings = [l | l <- T.lines doc.finalText, "## " `T.isPrefixOf` l]
      headings `shouldBe` ["## Information", "## Attention", "## References"]
      T.unpack doc.finalText `shouldContain` "Entropy measures how surprising a message is"
      T.unpack doc.finalText `shouldContain` "That is why information is the thing being counted."

    it "never shows the model entries that were struck or left at priority 0" $ do
      st <- style'
      evs <- fixtureLog
      (model, prompts) <- cannedModel
      doc <- finalMarkdown (Just model) defaultFinalOptions st evs
      ps <- T.concat <$> prompts
      length (T.splitOn "Passage topic:" ps) `shouldBe` 3 -- two sections
      let (excludedRel, excludedExp) = (textOf evs 2, textOf evs 3)
      mapM_ (\t -> T.unpack ps `shouldNotContain` T.unpack t) [fst excludedRel, fst excludedExp]
      T.unpack ps `shouldNotContain` ("[@" <> T.unpack (sourceKey (SourceId 3)) <> "]")
      T.unpack doc.finalText `shouldNotContain` T.unpack (fst excludedExp)

    it "drops a citation of a source that no kept entry cites, and says so" $ do
      st <- style'
      evs <- fixtureLog
      (model, _) <- cannedModel
      doc <- finalMarkdown (Just model) defaultFinalOptions st evs
      -- The model cited src3, which only the un-kept entry 2 cites.
      sourceIds doc.finalReferences `shouldMatchList` [1, 2, 4, 5]
      any ("src3" `T.isInfixOf`) doc.finalWarnings `shouldBe` True

    it "lists exactly the sources the text cites, a subset of what the draft cites" $ do
      st <- style'
      evs <- fixtureLog
      (model, _) <- cannedModel
      doc <- finalMarkdown (Just model) defaultFinalOptions st evs
      let refs = Set.fromList doc.finalReferences
      refs `shouldSatisfy` (`Set.isSubsetOf` draftRefs st evs)
      refs `shouldSatisfy` (`Set.isSubsetOf` keptCites evs)
      length doc.finalReferences `shouldBe` Set.size refs
      T.unpack doc.finalText `shouldNotContain` "[@src"

    it "drops the references of sources the model did not cite" $ do
      st <- style'
      evs <- fixtureLog
      -- A model that cites only src1; src2, src4 and src5 are kept entries' sources but are not cited.
      let model _ = pure "Entropy measures how surprising a message is, as Shannon put it [@src1]."
      doc <- finalMarkdown (Just model) defaultFinalOptions st evs
      sourceIds doc.finalReferences `shouldBe` [1]

  describe "without a usable model" $ do
    it "falls back to the kept entries' own text, with their citations, when there is no model" $ do
      st <- style'
      evs <- fixtureLog
      doc <- finalMarkdown Nothing defaultFinalOptions st evs
      let (rel1, _) = textOf evs 1
      T.unpack doc.finalText `shouldContain` T.unpack (T.dropWhileEnd (== '.') rel1)
      sourceIds doc.finalReferences `shouldMatchList` [1, 2, 4, 5]
      doc.finalWarnings `shouldBe` []
      mapM_ (\n -> T.unpack doc.finalText `shouldNotContain` T.unpack (fst (textOf evs n))) [2, 3]

    it "falls back, and says so, when the model fails" $ do
      st <- style'
      evs <- fixtureLog
      doc <- finalMarkdown (Just (\_ -> ioError (userError "provider down"))) defaultFinalOptions st evs
      sourceIds doc.finalReferences `shouldMatchList` [1, 2, 4, 5]
      length (filter ("the model failed" `T.isInfixOf`) doc.finalWarnings) `shouldBe` 2

    it "falls back when the reply is empty or too short to be a passage" $ do
      st <- style'
      evs <- fixtureLog
      mapM_
        ( \reply -> do
            doc <- finalMarkdown (Just (\_ -> pure reply)) defaultFinalOptions st evs
            sourceIds doc.finalReferences `shouldMatchList` [1, 2, 4, 5]
            any ("unusable" `T.isInfixOf`) doc.finalWarnings `shouldBe` True
        )
        ["", "   \n\n ", "ok", "[@src1]"]

    it "does not swallow the cancellation of the job" $ do
      st <- style'
      evs <- fixtureLog
      finalMarkdown (Just (\_ -> throwIO ThreadKilled)) defaultFinalOptions st evs `shouldThrow` (== ThreadKilled)

  describe "whatever the model answers" $ do
    it "cannot add markup, headings or links of its own" $ do
      st <- style'
      evs <- fixtureLog
      let hostile = "# Pwned\n\n<script>alert(1)</script> and [click here](http://evil.example) with enough words to count [@src1].\n\n- a list item that goes on and on\n\n1. another one that goes on and on"
      doc <- finalMarkdown (Just (\_ -> pure hostile)) defaultFinalOptions st evs
      let ls = T.lines doc.finalText
      T.unpack doc.finalText `shouldNotContain` "<script>"
      T.unpack doc.finalText `shouldNotContain` "[click here]"
      [l | l <- ls, "# Pwned" `T.isPrefixOf` l] `shouldBe` []
      [l | l <- ls, "- a list" `T.isPrefixOf` l] `shouldBe` []
      [l | l <- ls, "1. another" `T.isPrefixOf` l] `shouldBe` []
      T.unpack doc.finalText `shouldContain` "\\# Pwned"

    it "cuts a runaway reply" $ do
      st <- style'
      evs <- fixtureLog
      let reply = T.replicate 100000 "word "
      doc <- finalMarkdown (Just (\_ -> pure reply)) defaultFinalOptions st evs
      T.length doc.finalText `shouldSatisfy` (< 20000)

    (st, evs) <- runIO ((,) <$> style' <*> fixtureLog)
    let allowed = keptCites evs
        draft = draftRefs st evs
    it "keeps invariants 5 and 6 for any citations in the reply" $
      property $ \(ks :: [Positive Int]) -> ioProperty $ do
        let keys = [n `mod` 9 | Positive n <- ks]
            reply = "A sentence long enough to be a passage of its own. " <> T.concat ["See [@src" <> T.pack (show k) <> "]. " | k <- keys]
            expected = Set.fromList (groundedCites (groundCitations allowed reply))
        doc <- finalMarkdown (Just (\_ -> pure reply)) defaultFinalOptions st evs
        let refs = Set.fromList doc.finalReferences
        pure . conjoin $
          [ refs === expected
          , property (refs `Set.isSubsetOf` draft)
          , property (refs `Set.isSubsetOf` allowed)
          , property (not ("[@src" `T.isInfixOf` doc.finalText))
          ]

  describe "small sessions" $ do
    it "has no headings when the walk was never backtracked" $ do
      st <- style'
      let evs =
            stamped
              [ NodeChosen (NodeId 1) Nothing "tide" Cloud Nothing
              , NodeChosen (NodeId 2) (Just (NodeId 1)) "moon" Branch Nothing
              , EntryWritten (Entry (EntryId 1) (NodeId 2) "Tides follow the moon" "The moon pulls the sea." [])
              , EntryPromoted (EntryId 1) 1
              ]
      doc <- finalMarkdown Nothing defaultFinalOptions st evs
      doc.finalText `shouldBe` "# From tide to moon\n\nTides follow the moon. The moon pulls the sea."

    it "says so when no entry was kept, and lists no references" $ do
      st <- style'
      evs <- fixtureLog
      let nothingKept = [s | s <- evs, case s.event of EntryPromoted {} -> False; _ -> True]
      doc <- finalMarkdown (Just (\_ -> pure "never asked")) defaultFinalOptions st nothingKept
      doc.finalText `shouldBe` "# From entropy to flow\n\n_No entries were kept at high priority._"
      doc.finalReferences `shouldBe` []

  describe "citationPieces" $ do
    it "separates text from citation groups" $
      citationPieces "a [@src1; @src2] b [@src3]." `shouldBe` [Plain "a ", Cite [SourceId 1, SourceId 2], Plain " b ", Cite [SourceId 3], Plain "."]
    it "leaves an unfinished marker as text" $
      citationPieces "broken [@src1 and on" `shouldBe` [Plain "broken [@src1 and on"]
