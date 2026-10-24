module TextSpec (spec) where

import Drift.Search.Text
import Test.Hspec

spec :: Spec
spec = describe "Drift.Search.Text" $ do
  describe "plainText" $ do
    it "removes the search-match markup Wikipedia puts in excerpts" $
      plainText "<span class=\"searchmatch\">Tides</span> are the rise and fall"
        `shouldBe` "Tides are the rise and fall"
    it "decodes named and numeric entities" $
      plainText "the Moon&#039;s pull &amp; the Sun&#x2019;s &lt;3 &quot;x&quot;"
        `shouldBe` "the Moon's pull & the Sun\8217s <3 \"x\""
    it "does not turn an encoded tag back into markup" $
      plainText "a &lt;b&gt;bold&lt;/b&gt; claim" `shouldBe` "a <b>bold</b> claim"
    it "leaves a stray ampersand and an unclosed tag alone" $ do
      plainText "Tom & Jerry" `shouldBe` "Tom & Jerry"
      plainText "a < b" `shouldBe` "a < b"
    it "ignores invalid numeric entities" $
      plainText "x &#99999999; y &#xD800; z" `shouldBe` "x &#99999999; y &#xD800; z"
    it "collapses white space" $
      plainText "  a \n\t b  " `shouldBe` "a b"

  describe "normalizeDoi" $ do
    it "strips resolver prefixes and lower-cases" $ do
      normalizeDoi "https://doi.org/10.1038/35015639" `shouldBe` Just "10.1038/35015639"
      normalizeDoi "http://dx.doi.org/10.1002/2014JE004755" `shouldBe` Just "10.1002/2014je004755"
      normalizeDoi "doi:10.1000/XYZ" `shouldBe` Just "10.1000/xyz"
    it "rejects what is not a DOI" $ do
      normalizeDoi "" `shouldBe` Nothing
      normalizeDoi "https://example.org/10.1/x" `shouldBe` Nothing
      normalizeDoi "10.1234" `shouldBe` Nothing
      normalizeDoi "10.1234/has space" `shouldBe` Nothing

  describe "tokens and stem" $ do
    it "splits on punctuation and folds case" $
      tokens "Tide, MOON & climate-change" `shouldBe` ["tide", "moon", "climate", "change"]
    it "matches simple plurals" $ do
      stem "tides" `shouldBe` stem "tide"
      stem "moons" `shouldBe` "moon"
    it "does not damage short words or double s" $ do
      stem "gas" `shouldBe` "gas"
      stem "mass" `shouldBe` "mass"

  describe "isWebUrl" $ do
    it "allows only http and https" $ do
      isWebUrl "https://en.wikipedia.org/wiki/Tide" `shouldBe` True
      isWebUrl "HTTP://example.org" `shouldBe` True
      isWebUrl "javascript:alert(1)" `shouldBe` False
      isWebUrl "file:///etc/passwd" `shouldBe` False
      isWebUrl "https://exa mple.org" `shouldBe` False
