{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

module WritingSpec (spec) where

import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict)
import qualified Data.ByteString.Char8 as BS
import Data.List (isSuffixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Drift.Domain.Entries
import Drift.Pipeline.Writing
import Drift.Protocol
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

source :: Int -> Source
source n = mkSource (SourceId n) (NodeId 2)

sourceAt :: NodeId -> Source
sourceAt = mkSource (SourceId 3)

mkSource :: SourceId -> NodeId -> Source
mkSource i n =
  Source
    { sourceId = i
    , node = n
    , kind = WebPage
    , title = "Entropy (information theory)"
    , site = Just "Wikipedia"
    , url = "https://en.wikipedia.org/wiki/Entropy_(information_theory)"
    , thumbnailUrl = Nothing
    , csl = Nothing
    }

input :: [Source] -> WritingInput
input ss =
  WritingInput
    { node = NodeId 2
    , fromWord = "entropy"
    , toWord = "information"
    , path = ["entropy"]
    , origin = Branch
    , lang = En
    , sources = ss
    }

spec :: Spec
spec = do
  describe "buildWritingPrompt" $ do
    it "lists the sources by key" $
      buildWritingPrompt (input [source 3]) `shouldSatisfy` T.isInfixOf "[@src3] Entropy (information theory) - Wikipedia"

    it "forbids citing when there are no sources" $
      buildWritingPrompt (input []) `shouldSatisfy` T.isInfixOf "Do not cite anything."

  describe "parseWritingOutput" $ do
    it "reads the labelled format" $
      parseWritingOutput "RELATION: Entropy measures information\nEXPLANATION: Shannon used it."
        `shouldBe` Just ("Entropy measures information", "Shannon used it.")

    it "tolerates markdown, quotes and wrapped lines" $
      parseWritingOutput "Sure!\n**Relation:** \"Entropy measures information\"\n- Explanation: Shannon\nused it."
        `shouldBe` Just ("Entropy measures information", "Shannon used it.")

    it "falls back to first line, then the rest" $
      parseWritingOutput "Entropy measures information\nShannon used it."
        `shouldBe` Just ("Entropy measures information", "Shannon used it.")

    it "rejects empty replies" $
      parseWritingOutput "  \n" `shouldBe` Nothing

  describe "entryFromOutput" $ do
    it "moves known citations into cites and drops invented ones" $
      entryFromOutput (EntryId 1) (input [source 3]) "RELATION: Entropy measures information\nEXPLANATION: Shannon used it [@src3]. Others agree [@src7]."
        `shouldBe` Just
          Entry
            { entryId = EntryId 1
            , node = NodeId 2
            , relation = "Entropy measures information"
            , explanation = "Shannon used it. Others agree."
            , cites = [SourceId 3]
            }

  describe "writeEntry" $ do
    it "uses the model reply" $ do
      e <- writeEntry (const (pure "RELATION: r\nEXPLANATION: x")) (EntryId 1) (input [])
      (e.relation, e.explanation) `shouldBe` ("r", "x")

    it "falls back when the model fails" $ do
      e <- writeEntry (const (throwIO (ErrorCall "down"))) (EntryId 1) (input [])
      e `shouldBe` fallbackEntry (EntryId 1) (input [])

  describe "reviseForSource" $ do
    let base = Entry {entryId = EntryId 1, node = NodeId 2, relation = "r", explanation = "x", cites = []}
        table = applyEntryEvent 1 (EntryWritten {entry = base}) emptyEntries

    it "attaches a late source to the edge's entry" $
      reviseForSource table (source 3) `shouldBe` [EntryRevised {entry = base {cites = [SourceId 3]}}]

    it "does nothing once the source is cited" $
      let table' = foldr (applyEntryEvent 2) table (reviseForSource table (source 3))
       in reviseForSource table' (source 3) `shouldBe` []

    it "ignores sources for other edges" $
      reviseForSource table (sourceAt (NodeId 5)) `shouldBe` []

  describe "protocol fixtures" $ do
    let dir = "../protocol/fixtures"
    names <- runIO (filter (".jsonl" `isSuffixOf`) <$> listDirectory dir)
    forM_ names $ \name -> do
      ls <- runIO (filter (not . BS.null) . BS.lines <$> BS.readFile (dir </> name))
      let events = either (const []) (map (.event)) (traverse (eitherDecodeStrict @Stamped) ls)

      it (name <> ": entries cite only sources already found for their edge") $
        let check (found, ok) = \case
              SourceFound {source = s} -> (Map.insertWith (<>) s.node (Set.singleton s.sourceId) found, ok)
              EntryWritten {entry = e} -> (found, ok && grounded found e)
              EntryRevised {entry = e} -> (found, ok && grounded found e)
              _ -> (found, ok)
            grounded found e = all (`Set.member` Map.findWithDefault Set.empty e.node found) e.cites
         in snd (foldl check (Map.empty, True) events) `shouldBe` True

      it (name <> ": entries are revised only after being written") $
        let step (t, ok) (n, e) =
              let ok' = case e of
                    EntryRevised {entry = x} -> ok && Map.member x.entryId t
                    _ -> ok
               in (applyEntryEvent n e t, ok')
         in snd (foldl step (emptyEntries, True) (zip [1 ..] events)) `shouldBe` True
