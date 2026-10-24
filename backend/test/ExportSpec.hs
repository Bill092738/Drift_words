{-# LANGUAGE OverloadedRecordDot #-}

module ExportSpec (spec) where

import qualified Codec.Archive.Zip as Zip
import qualified Data.ByteString.Lazy as LBS
import Data.Default (def)
import Data.Either (isRight)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Drift.Output.Export
import Drift.Protocol (Outputs (..))
import Test.Hspec
import Test.QuickCheck (property)
import qualified Text.XML as XML

draftSample :: Text
draftSample =
  T.intercalate
    "\n"
    [ "# Draft: from entropy to flow"
    , ""
    , "1. **Entropy measures information.** Shannon borrowed the word (Shannon, 1948)."
    , "2. ~~**Noise as a source.** A struck thought.~~"
    , ""
    , "## References"
    , ""
    , "Shannon, C. E. (1948). A Mathematical Theory of Communication. *Bell System Technical Journal*, *27*(3), 379\8211\&423. <https://doi.org/10.1002/j.1538-7305.1948.tb01338.x>"
    ]

treeSample :: Text
treeSample = "```mermaid\nflowchart TD\n  n1[entropy] --> n2[information]\n```"

outputs :: Outputs
outputs = Outputs {decisionTree = treeSample, draft = draftSample, final = "# From a to b\n\nA paragraph with *emphasis* & more."}

-- | The XML parts of a DOCX, by name.
parts :: LBS.ByteString -> [(FilePath, LBS.ByteString)]
parts docx = [(Zip.eRelativePath e, Zip.fromEntry e) | e <- Zip.zEntries (Zip.toArchive docx)]

wellFormed :: LBS.ByteString -> Bool
wellFormed = isRight . XML.parseLBS def

spec :: Spec
spec = describe "Drift.Output.Export" $ do
  describe "parseMarkdown" $ do
    it "reads headings, numbered lines, paragraphs and a code block" $ do
      let bs = parseMarkdown (draftSample <> "\n\n" <> treeSample)
      [n | Heading n _ <- bs] `shouldBe` [1, 2]
      length [() | Para _ <- bs] `shouldBe` 3 -- two numbered entries and the reference
      [c | Code c <- bs] `shouldBe` ["flowchart TD\n  n1[entropy] --> n2[information]"]

    it "keeps each numbered line as its own paragraph" $
      length [() | Para _ <- parseMarkdown "1. one\n2. two\n3. three"] `shouldBe` 3

    it "joins the lines of a wrapped paragraph" $
      parseMarkdown "one\ntwo\n\nthree" `shouldBe` [Para [Txt "one two"], Para [Txt "three"]]

    it "reads emphasis, strike-through, escapes and links" $ do
      parseMarkdown "a **b** *c* _d_ ~~e~~ \\*f\\* <https://x.org/a_b>"
        `shouldBe` [ Para
                       [ Txt "a "
                       , Bold [Txt "b"]
                       , Txt " "
                       , Emph [Txt "c"]
                       , Txt " "
                       , Emph [Txt "d"]
                       , Txt " "
                       , Strike [Txt "e"]
                       , Txt " *f* "
                       , Link "https://x.org/a_b"
                       ]
                   ]

    it "leaves unmatched markers and non-web links as plain text" $ do
      let texts bs = T.concat [t | Para xs <- bs, Txt t <- xs]
      texts (parseMarkdown "5 * 3 and **open") `shouldBe` "5 * 3 and **open"
      [() | Para xs <- parseMarkdown "<javascript:alert(1)>", Link _ <- xs] `shouldBe` []

  describe "renderHtml" $ do
    it "makes a complete page with the formatting kept" $ do
      let html = renderHtml "Draft" (parseMarkdown draftSample)
      T.unpack html `shouldContain` "<!doctype html>"
      T.unpack html `shouldContain` "<title>Draft</title>"
      T.unpack html `shouldContain` "<h1>Draft: from entropy to flow</h1>"
      T.unpack html `shouldContain` "<strong>Entropy measures information.</strong>"
      T.unpack html `shouldContain` "<del>"
      T.unpack html `shouldContain` "<em>Bell System Technical Journal</em>"
      T.unpack html `shouldContain` "<a href=\"https://doi.org/10.1002/j.1538-7305.1948.tb01338.x\""

    it "escapes everything it did not write itself" $ do
      let html = renderHtml "T" (parseMarkdown "# <script>alert(1)</script>\n\nA & B <img src=x onerror=alert(1)>")
      T.unpack html `shouldNotContain` "<script>"
      T.unpack html `shouldNotContain` "<img"
      T.unpack html `shouldContain` "&lt;script&gt;"
      T.unpack html `shouldContain` "A &amp; B"

    it "never makes a link from a non-web address" $
      T.unpack (renderHtml "T" (parseMarkdown "<javascript:alert(1)> and <file:///etc/passwd>")) `shouldNotContain` "href="

  describe "renderDocx" $ do
    it "is a zip with the parts Word needs, all well-formed XML" $ do
      let docx = renderDocx (parseMarkdown draftSample)
          names = map fst (parts docx)
      names `shouldMatchList` ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/_rels/document.xml.rels"]
      mapM_ (\(n, b) -> (n, wellFormed b) `shouldBe` (n, True)) (parts docx)

    it "carries headings, bold, strike-through, italics and the link" $ do
      let docx = renderDocx (parseMarkdown draftSample)
          doc = maybe "" (TE.decodeUtf8 . LBS.toStrict) (lookup "word/document.xml" (parts docx))
          rels = maybe "" (TE.decodeUtf8 . LBS.toStrict) (lookup "word/_rels/document.xml.rels" (parts docx))
      T.unpack doc `shouldContain` "<w:pStyle w:val=\"Heading1\"/>"
      T.unpack doc `shouldContain` "<w:b/>"
      T.unpack doc `shouldContain` "<w:strike/>"
      T.unpack doc `shouldContain` "<w:i/>"
      T.unpack doc `shouldContain` "<w:hyperlink r:id=\"rId11\">"
      T.unpack rels `shouldContain` "Target=\"https://doi.org/10.1002/j.1538-7305.1948.tb01338.x\" TargetMode=\"External\""
      T.unpack doc `shouldContain` "Entropy measures information."

    it "puts a code block in monospace paragraphs, one per line" $ do
      let docx = renderDocx (parseMarkdown treeSample)
          doc = maybe "" (TE.decodeUtf8 . LBS.toStrict) (lookup "word/document.xml" (parts docx))
      length (T.splitOn "w:val=\"Code\"" doc) `shouldBe` 3
      T.unpack doc `shouldContain` "Consolas"
      T.unpack doc `shouldContain` "n1[entropy] --&gt; n2[information]"

    it "escapes text and drops characters XML cannot carry" $ do
      let docx = renderDocx (parseMarkdown "<tag> & \"quotes\" \1 \8 end")
          doc = maybe "" (TE.decodeUtf8 . LBS.toStrict) (lookup "word/document.xml" (parts docx))
      T.unpack doc `shouldContain` "&lt;tag&gt; &amp; &quot;quotes&quot;"
      wellFormed (LBS.fromStrict (TE.encodeUtf8 doc)) `shouldBe` True

    it "is well-formed XML and a readable zip for any text" $
      property $ \(t :: String) ->
        let docx = renderDocx (parseMarkdown (T.pack t))
         in all (wellFormed . snd) (parts docx) && length (parts docx) == 5

    it "never lets text become HTML for any input" $
      property $ \(t :: String) ->
        let html = renderHtml "T" (parseMarkdown (T.pack ("x " <> t)))
            body = T.drop 1 (snd (T.breakOn "<body>" html))
         in not ("<script" `T.isInfixOf` T.toLower body)

  describe "exportDocument" $ do
    it "names and types each file" $ do
      let e = exportDocument KindFinal FormatDocx outputs
      e.fileName `shouldBe` "final.docx"
      e.contentType `shouldBe` "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      LBS.take 2 e.bytes `shouldBe` "PK"
      (exportDocument KindDraft FormatHtml outputs).fileName `shouldBe` "draft.html"
      (exportDocument KindTree FormatMarkdown outputs).fileName `shouldBe` "decision-tree.md"

    it "gives the Markdown as it is" $
      TE.decodeUtf8 (LBS.toStrict (exportDocument KindDraft FormatMarkdown outputs).bytes) `shouldBe` draftSample

    it "titles the HTML page by its first heading, and the tree page as a decision tree" $ do
      let html k = TE.decodeUtf8 (LBS.toStrict (exportDocument k FormatHtml outputs).bytes)
      T.unpack (html KindFinal) `shouldContain` "<title>From a to b</title>"
      T.unpack (html KindTree) `shouldContain` "<title>Decision tree</title>"
      T.unpack (html KindTree) `shouldContain` "<pre><code>flowchart TD"

    it "reads kind and format names" $ do
      docKindFromText "final" `shouldBe` Just KindFinal
      formatFromText "docx" `shouldBe` Just FormatDocx
      isJust (docKindFromText "nope") `shouldBe` False
      isJust (formatFromText "pdf") `shouldBe` False
