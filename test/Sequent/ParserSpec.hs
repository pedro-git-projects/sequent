module Sequent.ParserSpec (spec) where

import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Sequent.Diagnostic
import Sequent.Language.Parser
import Sequent.Language.Syntax

spec :: Spec
spec = do
  describe "declarations" $ do
    it "parses a process with a label" $
      [(unLoc (spName p), spLabel p) | DProcess p <- decls "process p \"Label\" { start a }"]
        `shouldBe` [("p", Just "Label")]

    it "parses a root message with a correlation key" $
      [(unLoc n, nm, c) | DMessage n nm c _ <- decls "message m \"wire\" correlation \"=k\"\nprocess p { start a }"]
        `shouldBe` [("m", "wire", Just "=k")]

    it "parses an error declaration with a label" $
      [(unLoc n, code, lbl) | DError n code lbl _ <- decls "error e \"CODE\" \"Human\"\nprocess p { start a }"]
        `shouldBe` [("e", "CODE", Just "Human")]

    it "parses a collaboration with a black-box pool" $
      [ (unLoc (poName q), poBody q == Nothing)
      | DCollaboration c <- decls "collaboration c { pool a { start s } pool b \"Other\" }"
      , CPool q <- scItems c
      ]
        `shouldBe` [("a", False), ("b", True)]

  describe "handlers, groups and stop" $ do
    it "parses a handler block as an item, not a step" $
      -- An item, because an event subprocess is reached by its trigger: put it
      -- between two steps and those two steps stay connected to each other.
      [(unLoc (shName h), shLabel h, length (shBody h)) | IHandler h <- items "process p { start s\nhandler rec \"Recover\" { start c\nend f } }"]
        `shouldBe` [("rec", Just "Recover", 2)]

    it "parses a group as a list of member names" $
      [ (unLoc (sgrName g), sgrLabel g, map unLoc (membersOf g))
      | IGroup g <- items "process p { start s\ntask a\ntask b\ngroup money \"Money\" { a b } }"
      ]
        `shouldBe` [("money", Just "Money", ["a", "b"])]

    it "keeps a comment written between two group members" $
      [ length (sgrMembers g)
      | IGroup g <- items "process p { start s\ntask a\ntask b\ngroup money { a\n# and\nb } }"
      ]
        `shouldBe` [3]

    it "parses 'stop' as a step" $
      [() | IStep (StStop _) <- items "process p { start s\ntask a\nstop }"] `shouldBe` [()]

    it "parses 'noninterrupting' as a property" $
      props "start c { message m\nnoninterrupting }" `shouldBe` [PMessage "m", PNonInterrupting]

    it "rejects the new keywords as step names" $
      mapM_
        ( \w -> case parseFile "t" ("process p { task " <> w <> " }") of
            Left (d : _) -> T.unpack (diagMessage d) `shouldSatisfy` isInfixOf "reserved word"
            _ -> expectationFailure ("expected a parse error for " <> T.unpack w)
        )
        ["handler", "group", "stop"]

  describe "steps" $ do
    it "reads a step keyword and a name" $
      [(unLoc (snKind n), unLoc (snName n)) | n <- nodes "process p { service s \"Do it\" }"]
        `shouldBe` [(KwService, "s")]

    it "parses a property block" $
      props "service s { type \"t\" retries 3 input a = \"=x\" header k = \"v\" }"
        `shouldBe` [PType "t", PRetries 3, PInput "a" "=x", PHeader "k" "v"]

    it "accepts a quoted key where an identifier would not do" $
      props "service s { header \"content-type\" = \"json\" }"
        `shouldBe` [PHeader "content-type" "json"]

    it "parses a multi-instance property" $
      props "service s { type \"t\" each item in \"=xs\" sequential }"
        `shouldBe` [PType "t", PEach "item" "=xs" True]

    it "reads a trigger property as a declaration reference, not a string" $
      props "end e { error boom }" `shouldBe` [PError "boom"]

  describe "control flow" $ do
    it "nests branches inside a gateway" $
      gatewayShape "xor g \"Q?\" { branch \"yes\" otherwise { task a } branch \"no\" when \"=n\" }"
        `shouldBe` (KwXor, "g", Just "Q?", [(Just "yes", Just GOtherwise, True), (Just "no", Just (GWhen "=n"), False)])

    it "distinguishes the gateway keywords" $
      map (\k -> gatewayKw (k <> " g { branch }")) ["xor", "and", "or", "event", "complex"]
        `shouldBe` [KwXor, KwAnd, KwOr, KwEventGw, KwComplex]

    it "carries an explicit branch priority" $
      [brPriority b | g <- gateways "xor g { branch priority 2 }", b <- branchesOf g]
        `shouldBe` [Just 2]

    it "names an explicit join" $
      [fmap unLoc (sgJoin g) | g <- gateways "xor g join later { branch }"] `shouldBe` [Just "later"]

    it "parses goto" $
      [unLoc n | IStep (StGoto n _) <- items "process p { goto x }"] `shouldBe` ["x"]

    it "parses an explicit flow chain" $
      [map unLoc (sfNodes f) | IFlow f <- items "process p { flow a -> b -> c }"]
        `shouldBe` [["a", "b", "c"]]

    it "parses a message flow with the ~> arrow" $
      [(unLoc (mfFrom m), unLoc (mfTo m)) | DCollaboration c <- decls "collaboration c { a ~> b }", CMessageFlow m <- scItems c]
        `shouldBe` [("a", "b")]

  describe "attachments" $ do
    it "parses a boundary handler block" $
      [ (unLoc (bdHost b), unLoc (bdTrigger b), bdNonInt b, unLoc (bdAs b), length (bdBody b))
      | IBoundary b <- items "process p { on t catch timer \"PT5M\" noninterrupting as late { task h } }"
      ]
        `shouldBe` [("t", TgTimer "PT5M", True, "late", 1)]

    it "parses a note and a data object" $
      length [() | INote _ <- items "process p { note n \"text\" on t }"] `shouldBe` 1

    it "parses a layout pin, the only place a coordinate may appear" $
      [(unLoc (spinNode q), spinX q, spinY q) | IPin q <- items "process p { pin t at 320 170 }"]
        `shouldBe` [("t", 320, 170)]

  describe "comments" $ do
    it "keeps a standalone comment as an item of the body it was written in" $
      [cmText c | IComment c <- items "process p { # why\nstart s }"]
        `shouldBe` ["# why"]

    it "marks a comment that followed code on its line as trailing" $
      [(cmText c, cmTrailing c) | IComment c <- items "process p { start s  # go\nend e }"]
        `shouldBe` [("# go", True)]

    it "marks a comment on a line of its own as not trailing" $
      [(cmText c, cmTrailing c) | IComment c <- items "process p { start s\n# go\nend e }"]
        `shouldBe` [("# go", False)]

    it "keeps a file heading as a top-level declaration" $
      [cmText c | DComment c <- decls "# heading\nprocess p { start s }"]
        `shouldBe` ["# heading"]

    it "keeps a block comment whole, newlines included" $
      [cmText c | IComment c <- items "process p { /* one\n   two */\nstart s }"]
        `shouldBe` ["/* one\n   two */"]

    it "keeps comments between branches and inside property blocks" $
      let src = "process p { service a { # p\ntype \"t\" }\nxor g { # b\nbranch } }"
       in ( [cmText c | IStep (StNode n) <- items src, SProp _ (PComment c) <- snProps n]
          , [cmText c | IStep (StGateway g) <- items src, BComment c <- sgBranches g]
          )
            `shouldBe` (["# p"], ["# b"])

  describe "lexing" $ do
    it "understands all three comment syntaxes" $
      map (unLoc . snName) (nodes "process p { # one\n// two\n/* three */ start a }")
        `shouldBe` ["a"]

    it "unescapes string literals" $
      labels "process p { start a \"a \\\"b\\\" c\" }" `shouldBe` [Just "a \"b\" c"]

    it "refuses to read a reserved word as a step name" $
      case parseFile "t" "process p { start branch }" of
        Left (d : _) -> T.unpack (diagMessage d) `shouldSatisfy` isInfixOf "reserved word"
        _ -> expectationFailure "expected a parse error"

    it "points the caret at the reserved word itself" $
      case parseFile "t" "process p {\n  xor decision \"Q\" { branch }\n}" of
        Left (d : _) -> fmap spanStart (diagSpan d) `shouldBe` Just (Pos 2 7)
        _ -> expectationFailure "expected a parse error"

    it "reports the position of a syntax error" $
      case parseFile "t" "process p {\n  start\n}" of
        Left (d : _) -> fmap (posLine . spanStart) (diagSpan d) `shouldBe` Just 3
        _ -> expectationFailure "expected a parse error"

    it "categorises parse failures as ParseError" $
      case parseFile "t" "process" of
        Left (d : _) -> diagCategory d `shouldBe` ParseError
        _ -> expectationFailure "expected a parse error"

-- Helpers --------------------------------------------------------------------

parseOk :: Text -> SFile
parseOk t = either (error . show . map diagMessage) id (parseFile "test" t)

decls :: Text -> [SDecl]
decls = sfDecls . parseOk

items :: Text -> [SItem]
items t = concat [spBody p | DProcess p <- decls t]

nodes :: Text -> [SNode]
nodes t = [n | IStep (StNode n) <- items t]

gateways :: Text -> [SGateway]
gateways t = [g | IStep (StGateway g) <- items ("process p { " <> t <> " }")]

gatewayShape :: Text -> (GwKw, Text, Maybe Text, [(Maybe Text, Maybe SGuard, Bool)])
gatewayShape t = case gateways t of
  (g : _) ->
    ( unLoc (sgKind g)
    , unLoc (sgName g)
    , sgLabel g
    , [(brLabel b, unLoc <$> brGuard b, brBody b /= Nothing) | b <- branchesOf g]
    )
  [] -> error "no gateway"

gatewayKw :: Text -> GwKw
gatewayKw t = case gateways t of
  (g : _) -> unLoc (sgKind g)
  [] -> error "no gateway"

props :: Text -> [SPropBody]
props n = concat [map prBody (snProps x) | x <- nodes ("process p { " <> n <> " }")]

labels :: Text -> [Maybe Text]
labels t = map snLabel (nodes t)
