{-# LANGUAGE OverloadedRecordDot #-}

-- | Exports of the three outputs as Markdown, HTML and DOCX (TECH_ROADMAP.md
-- 4.8). The documents are the Markdown that "Drift.Output.Draft",
-- "Drift.Output.Final" and "Drift.Output.Tree" produce, a small subset (headings,
-- paragraphs, bold, italic, strike-through, links, a code block), so a small
-- reader of that subset replaces a general converter. Everything is escaped on
-- the way out and only http and https links are kept.
module Drift.Output.Export
  ( DocKind (..)
  , Format (..)
  , Block (..)
  , Inline (..)
  , Exported (..)
  , parseMarkdown
  , renderHtml
  , renderDocx
  , exportDocument
  , docKindFromText
  , formatFromText
  ) where

import qualified Codec.Archive.Zip as Zip
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isDigit, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Drift.Protocol (Outputs (..))

-- | Which of the three outputs.
data DocKind = KindTree | KindDraft | KindFinal
  deriving stock (Eq, Show, Enum, Bounded)

data Format = FormatMarkdown | FormatHtml | FormatDocx
  deriving stock (Eq, Show, Enum, Bounded)

docKindFromText :: Text -> Maybe DocKind
docKindFromText = \case
  "tree" -> Just KindTree
  "draft" -> Just KindDraft
  "final" -> Just KindFinal
  _ -> Nothing

formatFromText :: Text -> Maybe Format
formatFromText = \case
  "md" -> Just FormatMarkdown
  "html" -> Just FormatHtml
  "docx" -> Just FormatDocx
  _ -> Nothing

data Block
  = Heading Int [Inline]
  | Para [Inline]
  | Code Text
  deriving stock (Eq, Show)

data Inline
  = Txt Text
  | Bold [Inline]
  | Emph [Inline]
  | Strike [Inline]
  | Link Text
  -- ^ an autolink: the text is its address
  deriving stock (Eq, Show)

-- | A file to send: its content type, a file name and its bytes.
data Exported = Exported
  { contentType :: Text
  , fileName :: Text
  , bytes :: LBS.ByteString
  }

------------------------------------------------------------------------------
-- Reading the Markdown subset

parseMarkdown :: Text -> [Block]
parseMarkdown = blocks . T.lines
  where
    blocks [] = []
    blocks (l : ls)
      | "```" `T.isPrefixOf` l =
          let (code, rest) = break ("```" `T.isPrefixOf`) ls
           in Code (T.intercalate "\n" code) : blocks (drop 1 rest)
      | T.null (T.strip l) = blocks ls
      | otherwise =
          let (chunk, rest) = break (\x -> T.null (T.strip x) || "```" `T.isPrefixOf` x) (l : ls)
           in chunkBlocks chunk <> blocks rest

    -- Headings and numbered lines stand alone; other lines of a chunk join into one paragraph.
    chunkBlocks [] = []
    chunkBlocks ls = case span plain ls of
      ([], x : xs) -> single x : chunkBlocks xs
      (ps, xs) -> Para (inlines (T.unwords (map T.strip ps))) : chunkBlocks xs
    plain x = not (isHeading x || isNumbered x)
    single x
      | Just (n, t) <- heading x = Heading n (inlines t)
      | otherwise = Para (inlines (T.strip x))

    isHeading = maybe False (const True) . heading
    heading x =
      let (hashes, rest) = T.span (== '#') x
          n = T.length hashes
       in if n >= 1 && n <= 3 && " " `T.isPrefixOf` rest then Just (n, T.strip rest) else Nothing
    isNumbered x = case T.span isDigit x of
      (ds, rest) -> not (T.null ds) && ". " `T.isPrefixOf` rest

-- | Inline text: backslash escapes, @**bold**@, @*italic*@, @_italic_@, @~~strike~~@ and
-- @<https://...>@ links. Our own writers escape every literal marker, so an
-- unescaped marker is meant; an unmatched one stays text.
inlines :: Text -> [Inline]
inlines = mergeText . inlinesGo

-- | Joins neighbouring plain runs, so escapes and stray markers do not split a sentence.
mergeText :: [Inline] -> [Inline]
mergeText = \case
  Txt a : Txt b : rest -> mergeText (Txt (a <> b) : rest)
  x : rest -> x : mergeText rest
  [] -> []

inlinesGo :: Text -> [Inline]
inlinesGo t
  | T.null t = []
  | otherwise = case T.uncons t of
      Just ('\\', rest) | Just (c, after) <- T.uncons rest -> Txt (T.singleton c) : inlinesGo after
      _
        | Just r <- T.stripPrefix "**" t, Just (inner, after) <- closing "**" r -> Bold (inlines inner) : inlinesGo after
        | Just r <- T.stripPrefix "~~" t, Just (inner, after) <- closing "~~" r -> Strike (inlines inner) : inlinesGo after
        | Just r <- T.stripPrefix "*" t, Just (inner, after) <- closing "*" r, not (T.null inner) -> Emph (inlines inner) : inlinesGo after
        | Just r <- T.stripPrefix "_" t, Just (inner, after) <- closing "_" r, not (T.null inner) -> Emph (inlines inner) : inlinesGo after
        | Just r <- T.stripPrefix "<" t
        , (url, after) <- T.breakOn ">" r
        , not (T.null after)
        , isWeb url ->
            Link url : inlinesGo (T.drop 1 after)
        | otherwise ->
            let (run, rest) = T.span (`notElem` ("\\*_~<" :: String)) t
             in if T.null run
                  then Txt (T.take 1 t) : inlinesGo (T.drop 1 t)
                  else Txt run : inlinesGo rest

-- | The text up to the next unescaped marker, and what follows it.
closing :: Text -> Text -> Maybe (Text, Text)
closing marker t0 = case go "" t0 of
  Just (inner, after) | tight inner -> Just (inner, after)
  _ -> Nothing
  where
    -- As in CommonMark, an emphasis run does not start or end with a space.
    tight inner = not (T.null inner) && not (isSpace (T.head inner)) && not (isSpace (T.last inner))
    go acc t = case T.uncons t of
      Nothing -> Nothing
      Just ('\\', rest) | Just (c, after) <- T.uncons rest -> go (acc <> "\\" <> T.singleton c) after
      _
        | Just after <- T.stripPrefix marker t -> Just (acc, after)
        | otherwise -> go (acc <> T.take 1 t) (T.drop 1 t)

isWeb :: Text -> Bool
isWeb u = any (`T.isPrefixOf` T.toLower u) ["https://", "http://"] && not (T.any (`elem` (" \"<>" :: String)) u)

------------------------------------------------------------------------------
-- HTML

renderHtml :: Text -> [Block] -> Text
renderHtml title bs =
  T.concat
    [ "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>"
    , escapeXml title
    , "</title>\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<style>\n"
    , "body{max-width:42rem;margin:2rem auto;padding:0 1rem;font:16px/1.6 Georgia,serif;color:#1d1d1f}\n"
    , "h1,h2,h3{font-family:system-ui,sans-serif;line-height:1.25}\n"
    , "pre{background:#f4f3f0;padding:.75rem;overflow:auto;font-size:.85rem}\n"
    , "del{color:#6e6e73}\n"
    , "</style>\n</head>\n<body>\n"
    , T.concat (map block bs)
    , "</body>\n</html>\n"
    ]
  where
    block = \case
      Heading n xs -> tag ("h" <> T.pack (show n)) (T.concat (map inline xs))
      Para xs -> tag "p" (T.concat (map inline xs))
      Code c -> "<pre><code>" <> escapeXml c <> "</code></pre>\n"
    tag name inner = "<" <> name <> ">" <> inner <> "</" <> name <> ">\n"
    inline = \case
      Txt x -> escapeXml x
      Bold xs -> "<strong>" <> T.concat (map inline xs) <> "</strong>"
      Emph xs -> "<em>" <> T.concat (map inline xs) <> "</em>"
      Strike xs -> "<del>" <> T.concat (map inline xs) <> "</del>"
      Link u -> "<a href=\"" <> escapeXml u <> "\" rel=\"noopener noreferrer\">" <> escapeXml u <> "</a>"

------------------------------------------------------------------------------
-- DOCX: a minimal WordprocessingML package

renderDocx :: [Block] -> LBS.ByteString
renderDocx bs =
  Zip.fromArchive $
    foldr
      Zip.addEntryToArchive
      Zip.emptyArchive
      [ part "[Content_Types].xml" contentTypes
      , part "_rels/.rels" packageRels
      , part "word/document.xml" documentXml
      , part "word/styles.xml" stylesXml
      , part "word/_rels/document.xml.rels" documentRels
      ]
  where
    part name body = Zip.toEntry name 1700000000 (LBS.fromStrict (TE.encodeUtf8 body))
    links = zip [1 :: Int ..] (uniqueLinks bs)
    linkId u = maybe "" (\n -> "rId" <> T.pack (show (n + 10))) (lookup u [(url, n) | (n, url) <- links])

    documentXml =
      T.concat
        [ "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        , "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
        , "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body>"
        , T.concat (map block bs)
        , "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>"
        , "</w:body></w:document>"
        ]

    block = \case
      Heading n xs -> para (Just ("Heading" <> T.pack (show (min 3 n)))) (T.concat (map (run noStyle) xs))
      Para xs -> para Nothing (T.concat (map (run noStyle) xs))
      Code c -> T.concat [para (Just "Code") (textRun noStyle {mono = True} l) | l <- T.lines c]
    para style inner =
      "<w:p>"
        <> maybe "" (\s -> "<w:pPr><w:pStyle w:val=\"" <> s <> "\"/></w:pPr>") style
        <> inner
        <> "</w:p>"

    run st = \case
      Txt x -> textRun st x
      Bold xs -> T.concat (map (run st {bold = True}) xs)
      Emph xs -> T.concat (map (run st {italic = True}) xs)
      Strike xs -> T.concat (map (run st {strike = True}) xs)
      Link u -> "<w:hyperlink r:id=\"" <> linkId u <> "\">" <> textRun st {link = True} u <> "</w:hyperlink>"

    textRun st x
      | T.null x = ""
      | otherwise = "<w:r>" <> props st <> "<w:t xml:space=\"preserve\">" <> escapeXml x <> "</w:t></w:r>"
    props st =
      let ps =
            [ "<w:b/>" | st.bold ]
              <> [ "<w:i/>" | st.italic ]
              <> [ "<w:strike/>" | st.strike ]
              <> [ "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" | st.mono ]
              <> [ "<w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/>" | st.link ]
       in if null ps then "" else "<w:rPr>" <> T.concat ps <> "</w:rPr>"

    documentRels =
      T.concat
        ( [ "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
          , "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
          , "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
          ]
            <> [ "<Relationship Id=\"rId" <> T.pack (show (n + 10)) <> "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\""
                   <> escapeXml u <> "\" TargetMode=\"External\"/>"
               | (n, u) <- links
               ]
            <> ["</Relationships>"]
        )

data RunStyle = RunStyle {bold :: Bool, italic :: Bool, strike :: Bool, mono :: Bool, link :: Bool}

noStyle :: RunStyle
noStyle = RunStyle False False False False False

uniqueLinks :: [Block] -> [Text]
uniqueLinks bs = foldr (\u acc -> if u `elem` acc then acc else u : acc) [] (reverse (concatMap blockLinks bs))
  where
    blockLinks = \case
      Heading _ xs -> concatMap inlineLinks xs
      Para xs -> concatMap inlineLinks xs
      Code _ -> []
    inlineLinks = \case
      Txt _ -> []
      Bold xs -> concatMap inlineLinks xs
      Emph xs -> concatMap inlineLinks xs
      Strike xs -> concatMap inlineLinks xs
      Link u -> [u]

contentTypes, packageRels, stylesXml :: Text
contentTypes =
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
  \<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\
  \<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\
  \<Default Extension=\"xml\" ContentType=\"application/xml\"/>\
  \<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>\
  \<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>\
  \</Types>"
packageRels =
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
  \<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\
  \<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>\
  \</Relationships>"
stylesXml =
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
  \<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\
  \<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\" w:cs=\"Georgia\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault>\
  \<w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"300\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>\
  \<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>\
  \<w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"360\" w:after=\"120\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/><w:b/><w:sz w:val=\"40\"/></w:rPr></w:style>\
  \<w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"280\" w:after=\"100\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/><w:b/><w:sz w:val=\"30\"/></w:rPr></w:style>\
  \<w:style w:type=\"paragraph\" w:styleId=\"Heading3\"><w:name w:val=\"heading 3\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/></w:pPr><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/><w:b/><w:sz w:val=\"26\"/></w:rPr></w:style>\
  \<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\"/><w:sz w:val=\"18\"/></w:rPr></w:style>\
  \</w:styles>"

-- | Escapes for XML and HTML text and attributes, and drops the control
-- characters XML 1.0 cannot carry.
escapeXml :: Text -> Text
escapeXml = T.concatMap esc . T.filter valid
  where
    valid c = c == '\t' || c == '\n' || c == '\r' || c >= ' '
    esc = \case
      '&' -> "&amp;"
      '<' -> "&lt;"
      '>' -> "&gt;"
      '"' -> "&quot;"
      '\'' -> "&#39;"
      c -> T.singleton c

------------------------------------------------------------------------------
-- One call per download

-- | The chosen output in the chosen format. The decision tree is a code block
-- and gets a heading; the draft and the final document have their own.
exportDocument :: DocKind -> Format -> Outputs -> Exported
exportDocument kind format outputs =
  case format of
    FormatMarkdown -> Exported "text/markdown; charset=utf-8" (base <> ".md") (utf8 source)
    FormatHtml -> Exported "text/html; charset=utf-8" (base <> ".html") (utf8 (renderHtml title blocks))
    FormatDocx -> Exported "application/vnd.openxmlformats-officedocument.wordprocessingml.document" (base <> ".docx") (renderDocx blocks)
  where
    (base, fallbackTitle, raw) = case kind of
      KindTree -> ("decision-tree", "Decision tree", outputs.decisionTree)
      KindDraft -> ("draft", "Draft", outputs.draft)
      KindFinal -> ("final", "Final", outputs.final)
    source = raw
    blocks = case kind of
      KindTree -> Heading 1 [Txt "Decision tree"] : parseMarkdown raw
      _ -> parseMarkdown raw
    title = case [T.concat [t | Txt t <- xs] | Heading 1 xs <- blocks] of
      t : _ | not (T.null (T.strip t)) -> t
      _ -> fallbackTitle
    utf8 = LBS.fromStrict . TE.encodeUtf8
