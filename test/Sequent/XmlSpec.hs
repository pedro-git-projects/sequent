module Sequent.XmlSpec (spec) where

import Test.Hspec

import Sequent.Camunda.Xml

spec :: Spec
spec = do
  describe "escaping" $ do
    it "escapes the five attribute-hostile characters" $
      escapeAttr "a&b<c>d\"e" `shouldBe` "a&amp;b&lt;c&gt;d&quot;e"

    it "writes attribute whitespace as numeric references" $
      -- XML attribute-value normalisation would otherwise rewrite these on the
      -- way back in, silently changing a FEEL expression.
      escapeAttr "a\nb\rc\td" `shouldBe` "a&#10;b&#13;c&#9;d"

    it "leaves quotes alone in character data" $
      escapeText "a&b<c>d\"e" `shouldBe` "a&amp;b&lt;c&gt;d\"e"

  describe "serialising" $ do
    it "self-closes an empty element" $
      render (leaf "a" [("x", "1")]) `shouldBe` "<a x=\"1\" />"

    it "keeps a text element on one line" $
      render (textElem "a" [] "hi") `shouldBe` "<a>hi</a>"

    it "indents nested elements by two spaces" $
      render (elem_ "a" [] [leaf "b" [], elem_ "c" [] [leaf "d" []]])
        `shouldBe` "<a>\n  <b />\n  <c>\n    <d />\n  </c>\n</a>"

    it "preserves attribute order" $
      render (leaf "a" [("z", "1"), ("y", "2")]) `shouldBe` "<a z=\"1\" y=\"2\" />"

    it "prefixes a document with the XML declaration" $
      renderDocument (leaf "a" [])
        `shouldBe` "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a />\n"
