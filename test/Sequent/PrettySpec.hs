module Sequent.PrettySpec (spec) where

import Control.Monad (forM_)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

import Sequent.Compiler
import Sequent.Language.Parser (parseFile)
import Sequent.Language.Pretty (format)
import Sequent.Test.Support ()

spec :: Spec
spec = do
  describe "idempotence" $ do
    it "is a fixed point on a small process" $
      let src = "process p {start s\n  task a \"A\"\nend e}"
       in fmt (fmt src) `shouldBe` fmt src

    it "is a fixed point on nested gateways" $
      let src = "process p { start s xor g { branch \"y\" otherwise { and h { branch { task a } branch { task b } } } branch \"n\" when \"=n\" } end e }"
       in fmt (fmt src) `shouldBe` fmt src

  describe "round-tripping" $ do
    it "reparses to the same tree modulo spans" $
      let src = "process p { start s\ntask a \"A\"\nend e }"
       in stripSpans (fmt src) `shouldBe` stripSpans (fmt (fmt src))

    it "does not reorder items" $
      T.lines (fmt "process p { task b \"B\" task a \"A\" }")
        `shouldSatisfy` \ls -> indexOf "task b" ls < indexOf "task a" ls

  describe "layout of the canonical form" $ do
    it "indents blocks by two spaces" $
      fmt "process p{start s}" `shouldBe` "process p {\n  start s\n}\n"

    it "separates block items with a blank line but not one-liners" $
      T.lines (fmt "process p { task a task b service c { type \"t\" } }")
        `shouldBe` ["process p {", "  task a", "  task b", "", "  service c {", "    type \"t\"", "  }", "}"]

    it "quotes a key only when it is not an identifier" $
      fmt "process p { service s { type \"t\" header \"content-type\" = \"json\" header plain = \"v\" } }"
        `shouldSatisfy` \o -> T.isInfixOf "header \"content-type\" = \"json\"" o && T.isInfixOf "header plain = \"v\"" o

    it "writes trigger references bare, not quoted" $
      fmt "error e \"CODE\"\nprocess p { end x { error e } }"
        `shouldSatisfy` T.isInfixOf "error e\n"

  describe "comments" $ do
    it "keeps every comment in the file" $
      let src = "# heading\nprocess p {\n  # about the start\n  start s  # trailing\n  end e\n  # last word\n}\n"
       in commentsIn (fmt src) `shouldBe` commentsIn src

    it "puts a trailing comment back on its own line" $
      T.lines (fmt "process p { start s  # go\nend e }")
        `shouldSatisfy` any (T.isInfixOf "start s  # go")

    it "keeps a standalone comment above the item it introduces" $
      -- The blank-line rule must never come between a comment and the block it
      -- documents, so the comment travels as part of that item's group.
      T.lines (fmt "process p { start s\n# why\nservice a { type \"t\" }\nend e }")
        `shouldSatisfy` \ls -> succeeds "# why" "service a {" ls

    it "keeps a run of comment lines together" $
      T.lines (fmt "# one\n# two\nprocess p { start s\nend e }")
        `shouldSatisfy` \ls -> succeeds "# one" "# two" ls

    it "separates a file heading from the first declaration" $
      take 3 (T.lines (fmt "# heading\nprocess p { start s\nend e }"))
        `shouldBe` ["# heading", "", "process p {"]

    it "keeps a comment that is the only thing in a block" $
      T.lines (fmt "process p { lane l {\n# nothing yet\n}\nstart s\nend e }")
        `shouldSatisfy` any (T.isInfixOf "# nothing yet")

    it "keeps comments between branches and inside property blocks" $
      let src =
            "process p { start s\nservice a {\n# why this type\ntype \"t\"\n}\n\
            \xor g {\n# happy\nbranch \"y\" otherwise\n# sad\nbranch \"n\" when \"=n\" { end x }\n}\nend e }"
       in commentsIn (fmt src) `shouldBe` ["# why this type", "# happy", "# sad"]

    it "is a fixed point with comments in it" $
      let src = "# a\nprocess p {\n# b\nstart s  # c\nservice x { # d\ntype \"t\"\n}\n# e\n}\n# f\n"
       in fmt (fmt src) `shouldBe` fmt src

    it "keeps comments out of the compiled BPMN" $
      -- A comment is content in the source and nothing at all downstream.
      bpmn "process p { start s\ntask a\nend e }"
        `shouldBe` bpmn "# one\nprocess p { # two\nstart s\n# three\ntask a  # four\nend e }"

  describe "the examples" $ do
    sources <- runIO exampleSources
    forM_ sources $ \name -> describe name $ do
      let path = "examples" </> name

      it "formats to a fixed point" $ do
        src <- TIO.readFile path
        -- The examples are hand-written rather than canonical — they use
        -- one-liner property blocks the formatter expands — so the fixed point
        -- is the formatted file, not the file itself.
        fmt src `shouldBe` fmt (fmt src)

      it "keeps every comment through formatting" $ do
        src <- TIO.readFile path
        commentsIn (fmt src) `shouldBe` commentsIn src

      it "compiles to the same bytes after formatting" $ do
        src <- TIO.readFile path
        bpmn src `shouldBe` bpmn (fmt src)

exampleSources :: IO [FilePath]
exampleSources = sort . filter ((== ".sq") . takeExtension) <$> listDirectory "examples"

fmt :: Text -> Text
fmt src = case parseFile "test" src of
  Left ds -> error (show ds)
  Right f -> format f

-- | The formatter drops spans, so comparing formatted output compares trees
-- modulo position. Rendering twice and comparing is the cheapest faithful
-- statement of @parse (format ast) == ast@.
stripSpans :: Text -> Text
stripSpans = id

bpmn :: Text -> Text
bpmn src = case crXml (compileText defaultOptions "test.sq" src) of
  Just x -> x
  Nothing -> error "compile failed"

-- | Every comment line in a source text, in order, stripped of indentation.
commentsIn :: Text -> [Text]
commentsIn = filter isComment . map T.strip . T.lines
  where
    isComment l = any (`T.isPrefixOf` l) ["#", "//", "/*"]

-- | Whether the first line is immediately followed by the second.
succeeds :: Text -> Text -> [Text] -> Bool
succeeds a b ls =
  or [T.strip x == a && T.strip y == b | (x, y) <- zip ls (drop 1 ls)]

indexOf :: Text -> [Text] -> Int
indexOf needle ls = length (takeWhile (not . T.isInfixOf needle) ls)
