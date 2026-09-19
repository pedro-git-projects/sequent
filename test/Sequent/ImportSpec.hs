-- | The other direction: @.bpmn@ → @.sq@.
--
-- The property that matters is a round trip, and it is asserted the only way
-- that means anything: compile every committed example, import the result, and
-- check that the source that comes back describes the same process. Geometry is
-- not part of that — the layout engine computes it again — but everything else
-- is, element by element.
--
-- 'importText' already verifies itself, so most of these tests read as \"the
-- import reported nothing\". That is the point: the check is in the compiler,
-- where a user gets it, rather than only here.
module Sequent.ImportSpec (spec) where

import Control.Monad (forM_)
import Data.List (isInfixOf, sort)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (listDirectory)
import System.FilePath (replaceExtension, takeExtension, (</>))
import Test.Hspec

import Sequent.Bpmn.Read
import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model
import Sequent.Camunda.XmlParse
import Sequent.Compiler
import Sequent.Diagnostic
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "the XML reader" $ do
    it "resolves prefixes to namespaces, not to the spelling" $
      -- The same document under three spellings: a prefix, a different prefix,
      -- and a default namespace. A reader that matched on the prefix would see
      -- three different vocabularies.
      let shapes =
            [ "<bpmn:definitions xmlns:bpmn=\"http://www.omg.org/spec/BPMN/20100524/MODEL\"><bpmn:process id=\"p\"/></bpmn:definitions>"
            , "<b2:definitions xmlns:b2=\"http://www.omg.org/spec/BPMN/20100524/MODEL\"><b2:process id=\"p\"/></b2:definitions>"
            , "<definitions xmlns=\"http://www.omg.org/spec/BPMN/20100524/MODEL\"><process id=\"p\"/></definitions>"
            ]
       in map (fmap (xnName . head . xnChildren) . parseXmlDocument "t.bpmn") shapes
            `shouldBe` replicate 3 (Right (QName nsBpmn "process"))

    it "decodes the predefined entities and character references" $
      let doc = "<a xmlns=\"u\" t=\"a&amp;b&#65;\">x &lt; y &#x42;</a>"
       in fmap (\e -> (attrNamed "t" e, T.strip (xnText e))) (parseXmlDocument "t.xml" doc)
            `shouldBe` Right (Just "a&bA", "x < y B")

    it "skips comments, processing instructions and a DOCTYPE" $
      -- A DOCTYPE is skipped rather than honoured: an importer that expands
      -- entities from a DTD is an XXE waiting to happen.
      let doc = "<?xml version=\"1.0\"?><!DOCTYPE a [ <!ENTITY x \"y\"> ]><!-- note --><a xmlns=\"u\"><?pi go?><b/></a>"
       in fmap (map (qnLocal . xnName) . xnChildren) (parseXmlDocument "t.xml" doc) `shouldBe` Right ["b"]

    it "refuses a document that is not well formed" $
      parseXmlDocument "t.xml" "<a><b></a>" `shouldSatisfy` either (const True) (const False)

  describe "reading BPMN" $ do
    it "rejects a root that is not definitions" $
      messagesOfD (rdDiagnostics (readBpmn "t.bpmn" "<html xmlns=\"h\"/>"))
        `shouldSatisfy` any (isInfixOf "expected 'definitions'")

    it "reads Zeebe metadata from the extension, not from the tag" $
      -- A Camunda 8 user task is a user task because it carries a
      -- @zeebe:userTask@; a message end event is a job because it carries a
      -- @zeebe:taskDefinition@. Reading the tag instead loses both.
      let x = compileXml "start s\nuser u \"U\" { form \"f\" }\nend e"
       in fmap (fmap fnExec . lookupNode "Activity_u") (rdGraph (readBpmn "t.bpmn" x))
            `shouldSatisfy` \r -> case r of
              Just (Just (ExUser uu)) -> utForm uu == Just "f"
              _ -> False

    it "takes the task type from the extension when the tag is generic" $ do
      -- Camunda 8 runs a script or business-rule task either in the broker or
      -- on a worker, and the worker form is an ordinary task definition. The
      -- tag alone does not say which, so reading the tag alone loses one of
      -- them.
      taskExec "scriptTask" "<zeebe:taskDefinition type=\"js\"/>" `shouldBe` Just (ExService (emptyZeebeTask "js"))
      taskExec "businessRuleTask" "<zeebe:taskDefinition type=\"rules\"/>" `shouldBe` Just (ExService (emptyZeebeTask "rules"))

    it "drops metadata a plain task cannot run, and says so" $ do
      -- A @bpmn:task@ is Camunda 8's undefined task: the broker walks through
      -- it whatever the extension says. Keeping the metadata would build a step
      -- the language has no keyword for.
      taskExec "task" "<zeebe:taskDefinition type=\"js\"/>" `shouldBe` Just ExNone
      messagesOfD (rdDiagnostics (readBpmn "t.bpmn" (taskDoc "task" "<zeebe:taskDefinition type=\"js\"/>")))
        `shouldSatisfy` any (isInfixOf "a plain task cannot run")

    it "names every construct it cannot express" $
      messagesOfD (rdDiagnostics (readBpmn "t.bpmn" oddBpmn))
        `shouldSatisfy` \ms ->
          all (\w -> any (isInfixOf w) ms) ["data store", "nested lane set", "transaction"]

    it "reads an event subprocess rather than skipping it" $
      -- It used to be reported as having no equivalent. It has one now, and a
      -- skipped handler is a process that silently stops handling something.
      fmap (fmap isEventSubprocess . lookupNode "Activity_es") (rdGraph (readBpmn "t.bpmn" oddBpmn))
        `shouldBe` Just (Just True)

    it "keeps a non-interrupting start event non-interrupting" $
      let x = compileXml "message m \"m\"\nprocess p { start s\ntask t\nend e\nhandler h { start c { message m\nnoninterrupting }\ntask u\nend f } }"
       in fmap (fmap fnKind . lookupNode "StartEvent_c") (rdGraph (readBpmn "t.bpmn" x))
            `shouldSatisfy` \r -> case r of
              Just (Just (NkEvent (EventSpec (EvStart NonInterrupting) _))) -> True
              _ -> False

    it "recovers a group's members from the rectangle it was drawn as" $ do
      -- BPMN records a rectangle and no membership relation, so the members
      -- have to come from the geometry. This is the one place the importer
      -- reads diagram interchange, and it reads it only for this.
      let x = compileXml "start s\ntask a\ntask b\nend e\ngroup g \"G\" { a }"
          members = concatMap artMembers . concatMap scArtifacts . maybe [] (map procScope . sgProcesses)
      members (rdGraph (readBpmn "t.bpmn" x)) `shouldBe` [NodeId "Activity_a"]

    it "takes a group's text from the category value it points at" $
      let x = compileXml "start s\ntask a\nend e\ngroup g \"Money moves\" { a }"
          names = concatMap (map artName . scArtifacts) . maybe [] (map procScope . sgProcesses)
       in names (rdGraph (readBpmn "t.bpmn" x)) `shouldBe` [Just "Money moves"]

    it "says so when a group encloses nothing" $
      -- A group drawn round empty space is not an error in the file, but it is
      -- a group that will come back with no members, and that is worth saying.
      messagesOfD (rdDiagnostics (readBpmn "t.bpmn" oddBpmn))
        `shouldSatisfy` any (isInfixOf "encloses no step")

  describe "importing" $ do
    it "recovers a name from an id this compiler allocated" $
      importedSource "start begin \"Started\"\ntask greet \"Say hello\"\nend done \"Finished\""
        `shouldSatisfy` \s -> all (`T.isInfixOf` s) ["start begin \"Started\"", "task greet \"Say hello\"", "end done \"Finished\""]

    it "slugifies the label when the id is not a name" $
      -- A modeller writes @Activity_1x9k2df@, which nobody named. The label is
      -- the only thing left to make a readable identifier from, and the id will
      -- change on the way back out — the one thing the round trip cannot keep.
      let x = T.replace "Activity_greet" "Activity_1x9k2df" (compileXml "start s\ntask greet \"Say hello\"\nend e")
       in irSource (importText "t.bpmn" x) `shouldSatisfy` maybe False (T.isInfixOf "task say_hello \"Say hello\"")

    it "closes every dangling path with 'stop'" $ do
      -- Two branches that both dead-end. Before 'stop' existed the emitter
      -- could write only one of them: two steps written next to each other are
      -- connected by the resolver, so the second path swallowed the first, and
      -- the import warned that it had dropped one.
      let src = importedSource danglingBranches
      T.count "stop" src `shouldBe` 2
      messagesOfD (irDiagnostics (importText "t.bpmn" (compileXml danglingBranches)))
        `shouldSatisfy` all (not . isInfixOf "only one of them can be written")

    it "does not invent a merge for two branches that both dead-end" $
      -- Two branches left open are two branches the resolver counts as
      -- reaching the end of the block, and it derives a merge from that. The
      -- merge is not in the file, so the round-trip check in 'importText'
      -- rejects it; this pins the source shape that avoids it.
      importedSource danglingBranches `shouldSatisfy` \src -> not ("g_join" `T.isInfixOf` src)

    it "round-trips a subprocess inside a lane" $
      -- BPMN lists only a process's own flow nodes in a @flowNodeRef@, never a
      -- subprocess's, so the lane of a step inside a subprocess is not in the
      -- file. Both directions have to infer it the same way or the graphs
      -- cannot match.
      importDiags "process p { lane ops \"Ops\" { start s\nsubprocess sub { start i\ntask inner\nend o }\nend e } }"
        `shouldBe` []

    it "round-trips an event subprocess inside a lane" $
      importDiags
        ( "error boom \"BOOM\"\nprocess p { lane ops \"Ops\" { start s\ntask t\nend e\n"
            <> "handler h { start c { error boom }\ntask u\nend f } } }"
        )
        `shouldBe` []

    it "round-trips a user task with no zeebe extension" $ do
      -- A BPMN 2.0 file, or one written for Camunda 7, has a bare
      -- @bpmn:userTask@. The tag is what makes it a user task, so reading it as
      -- "no execution semantics" would make the round trip fail on a file that
      -- is not wrong.
      let doc =
            T.unlines
              [ "<bpmn:definitions xmlns:bpmn=\"http://www.omg.org/spec/BPMN/20100524/MODEL\" id=\"D\">"
              , "<bpmn:process id=\"Process_p\" name=\"P\">"
              , "<bpmn:startEvent id=\"StartEvent_s\"/>"
              , "<bpmn:userTask id=\"Activity_u\" name=\"U\"/>"
              , "<bpmn:endEvent id=\"Event_e\"/>"
              , "<bpmn:sequenceFlow id=\"Flow_1\" sourceRef=\"StartEvent_s\" targetRef=\"Activity_u\"/>"
              , "<bpmn:sequenceFlow id=\"Flow_2\" sourceRef=\"Activity_u\" targetRef=\"Event_e\"/>"
              , "</bpmn:process>"
              , "</bpmn:definitions>"
              ]
          r = importText "t.bpmn" doc
      messagesOfD [d | d <- irDiagnostics r, diagSeverity d == Error] `shouldBe` []
      messagesOfD (irDiagnostics r) `shouldSatisfy` any (isInfixOf "will come back with one")

    it "writes a loop back as a goto" $
      importedSource "start s\ntask a\nxor g { branch \"again\" when \"=r\" { goto a } branch \"on\" otherwise { end e } }"
        `shouldSatisfy` T.isInfixOf "goto a"

    it "leaves a derived merge to be derived" $
      -- The resolver makes the merge from two branches that reach the end of
      -- the block. Writing the node out instead would declare a second one.
      importedSource "start s\nand g { branch { task p } branch { task q } }\ntask r\nend e"
        `shouldSatisfy` \s -> not ("g_join" `T.isInfixOf` s)

    it "names a merge whose id is not the derived one" $
      -- @join@ exists for exactly this: the merge has to keep an id the
      -- resolver would not have chosen.
      let x = T.replace "Gateway_g_join" "Gateway_rejoin" (compileXml "start s\nand g { branch { task p } branch { task q } }\ntask r\nend e")
       in irSource (importText "t.bpmn" x) `shouldSatisfy` maybe False (T.isInfixOf "join rejoin")

    it "keeps a step in its own lane, wherever the step sits" $
      -- A branch that hands work to another role is the case lanes exist for.
      -- Partitioning only the top level files that step under whichever lane
      -- the gateway happened to be in.
      importedSource
        "lane one \"One\" { start s\nxor g { branch \"a\" otherwise { task p } branch \"b\" when \"=b\" { task q } } }\nlane two \"Two\" { end e }"
        `shouldSatisfy` \s -> T.isInfixOf "lane one" s && T.isInfixOf "lane two" s

  describe "a pool and the process behind it" $ do
    -- Three shapes a modeller leaves behind that the language could not write
    -- until the pool learned to name its process: a process named differently
    -- from its participant, a process nobody named, and a pool that is not
    -- executed. Each used to come back as the pool's own label, executable,
    -- and the import rejected its own output for it.
    let collab =
          "collaboration c { pool a \"A\" { start s\ntask t\nend e } "
            <> "pool b \"B\" { start u\ntask v\nend f } t ~> v }"
        rewritten from to = T.replace from to (compileXml collab)

    it "keeps a process name the participant does not share" $ do
      let x = rewritten "id=\"Process_a\" name=\"A\"" "id=\"Process_a\" name=\"[CCS] Deal\""
          r = importText "t.bpmn" x
      messagesOfD [d | d <- irDiagnostics r, diagSeverity d == Error] `shouldBe` []
      irSource r `shouldSatisfy` maybe False (T.isInfixOf "pool a \"A\" process \"[CCS] Deal\"")

    it "keeps a process nobody named unnamed" $ do
      let x = rewritten "id=\"Process_a\" name=\"A\"" "id=\"Process_a\""
          r = importText "t.bpmn" x
      messagesOfD [d | d <- irDiagnostics r, diagSeverity d == Error] `shouldBe` []
      irSource r `shouldSatisfy` maybe False (T.isInfixOf "pool a \"A\" process \"\"")

    it "keeps a non-executable process non-executable" $ do
      let x = rewritten "id=\"Process_b\" name=\"B\" isExecutable=\"true\"" "id=\"Process_b\" name=\"B\" isExecutable=\"false\""
          r = importText "t.bpmn" x
      messagesOfD [d | d <- irDiagnostics r, diagSeverity d == Error] `shouldBe` []
      irSource r `shouldSatisfy` maybe False (T.isInfixOf "pool b \"B\" nonexecutable")

    it "reads a file that starts with a byte order mark" $
      -- A .bpmn written as "UTF-8 with signature" is a valid document with an
      -- encoding artefact in front of it, not a document with no root element.
      messagesOfD (rdDiagnostics (readBpmn "t.bpmn" ("\65279" <> compileXml collab))) `shouldBe` []

  describe "the round trip" $ do
    examples <- runIO (sort . filter ((== ".sq") . takeExtension) <$> listDirectory "examples")
    forM_ examples $ \name -> describe name $ do
      let bpmn = "examples" </> replaceExtension name ".bpmn"
      it "imports with no diagnostic of its own" $ do
        x <- TIO.readFile bpmn
        let r = importText bpmn x
        (isJust (irSource r), messagesOfD (irDiagnostics r)) `shouldBe` (True, [])

      it "recompiles to the same process" $ do
        -- The importer checks this itself, which is why the assertion above is
        -- enough; doing it again here from the outside is what makes the claim
        -- independent of the check it is claiming about.
        x <- TIO.readFile bpmn
        let r = importText bpmn x
        case irSource r of
          Nothing -> expectationFailure "no source"
          Just sq -> case crXml (compileText defaultOptions "t.sq" sq) of
            Nothing -> expectationFailure "the imported source does not compile"
            Just x' -> semanticShape x' `shouldBe` semanticShape x

lookupNode :: Text -> SemanticGraph -> Maybe FlowNode
lookupNode i g =
  case [n | p <- sgProcesses g, sc <- allScopes (procScope p), n <- scNodes sc, unNodeId (fnId n) == i] of
    (n : _) -> Just n
    [] -> Nothing

-- | Every BPMN element with its attributes, sorted. Geometry is excluded on
-- purpose: it is recomputed, and comparing it would assert something the import
-- never promised.
semanticShape :: Text -> [Text]
semanticShape = sort . filter (T.isPrefixOf "<bpmn:") . map T.strip . T.lines

importedSource :: Text -> Text
importedSource src = case irSource (importText "t.bpmn" (compileXml src)) of
  Just s -> s
  Nothing -> ""

-- | The errors an import reports, which for a file this compiler wrote should
-- be none: 'importText' compiles its own output and compares the graphs.
importDiags :: Text -> [String]
importDiags src =
  messagesOfD [d | d <- irDiagnostics (importText "t.bpmn" (compileXml src)), diagSeverity d == Error]

messagesOfD :: [Diagnostic] -> [String]
messagesOfD = map (T.unpack . diagMessage)

-- | One flow node of a given tag, carrying a given extension. Enough of a
-- document for the reader; not enough to compile, which is the point — these
-- are read-side assertions.
taskDoc :: Text -> Text -> Text
taskDoc tag ext =
  T.unlines
    [ "<bpmn:definitions xmlns:bpmn=\"http://www.omg.org/spec/BPMN/20100524/MODEL\" xmlns:zeebe=\"http://camunda.org/schema/zeebe/1.0\" id=\"D\">"
    , "<bpmn:process id=\"Process_x\">"
    , "<bpmn:" <> tag <> " id=\"Activity_step\" name=\"Step\"><bpmn:extensionElements>" <> ext <> "</bpmn:extensionElements></bpmn:" <> tag <> ">"
    , "</bpmn:process>"
    , "</bpmn:definitions>"
    ]

taskExec :: Text -> Text -> Maybe ExecutionMeta
taskExec tag ext = fmap fnExec (rdGraph (readBpmn "t.bpmn" (taskDoc tag ext)) >>= lookupNode "Activity_step")

-- | A gateway whose branches both stop without an end event.
danglingBranches :: Text
danglingBranches =
  "start s\nxor g { branch \"a\" when \"=x\" { task p\nstop } branch \"b\" otherwise { task q\nstop } }"

oddBpmn :: Text
oddBpmn =
  T.unlines
    [ "<bpmn2:definitions xmlns:bpmn2=\"http://www.omg.org/spec/BPMN/20100524/MODEL\" id=\"D\">"
    , "<bpmn2:process id=\"Process_x\">"
    , "<bpmn2:laneSet id=\"LS\"><bpmn2:lane id=\"Lane_o\">"
    , "<bpmn2:childLaneSet id=\"LS2\"><bpmn2:lane id=\"Lane_i\"/></bpmn2:childLaneSet>"
    , "</bpmn2:lane></bpmn2:laneSet>"
    , "<bpmn2:subProcess id=\"Activity_es\" triggeredByEvent=\"true\"/>"
    , "<bpmn2:dataStoreReference id=\"Store_1\"/>"
    , "<bpmn2:group id=\"Group_1\"/>"
    , "<bpmn2:transaction id=\"Activity_tx\"/>"
    , "</bpmn2:process>"
    , "</bpmn2:definitions>"
    ]
