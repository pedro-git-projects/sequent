module Sequent.ResolveSpec (spec) where

import Data.List (isInfixOf)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Test.Hspec

import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model
import Sequent.Compiler
import Sequent.Diagnostic
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "implicit chaining" $ do
    it "connects consecutive steps without an edge list" $
      flowPairs "start s\ntask a\ntask b\nend e"
        `shouldBe` [("StartEvent_s", "Activity_a"), ("Activity_a", "Activity_b"), ("Activity_b", "Event_e")]

    it "opens a branch from the split and closes it at the derived merge" $
      flowPairs "start s\nxor g { branch \"y\" otherwise { task a } branch \"n\" when \"=n\" { task b } }\nend e"
        `shouldSatisfy` \fs ->
          ("Gateway_g", "Activity_a") `elem` fs
            && ("Activity_a", "Gateway_g_join") `elem` fs
            && ("Gateway_g_join", "Event_e") `elem` fs

    it "stops a path without connecting it to the next step" $
      -- The whole reason 'stop' exists: without it the two branches both
      -- reach the end of the block, which is what the resolver derives a merge
      -- from, and the second path is joined to the first.
      flowPairs "start s\nxor g { branch \"y\" when \"=y\" { task a\nstop } branch \"n\" otherwise { task b\nstop } }"
        `shouldBe` [("StartEvent_s", "Gateway_g"), ("Gateway_g", "Activity_a"), ("Gateway_g", "Activity_b")]

    it "creates no merge when both branches stop" $
      nodeIds "start s\nxor g { branch \"y\" when \"=y\" { task a\nstop } branch \"n\" otherwise { task b\nstop } }"
        `shouldNotContain` ["Gateway_g_join"]

    it "says so when a 'stop' ends nothing" $
      messagesOf (diagsOf "start s\nend e\nstop") `shouldSatisfy` any (isInfixOf "ends nothing")

  describe "event subprocesses" $ do
    let handler body = "error e \"E\"\nmessage m \"w\"\nprocess p { start s\ntask t\nend fin\n" <> body <> " }"

    it "builds a handler as a subprocess nothing flows into" $
      flowPairs (handler "handler h { start c { error e }\ntask u\nend f }")
        `shouldBe` [("StartEvent_s", "Activity_t"), ("Activity_t", "Event_fin")]

    it "leaves the steps around it connected to each other" $
      -- A handler written between two steps must not break the chain: it is
      -- not on the chain.
      flowPairs (handler "handler h { start c { error e }\nend f }")
        `shouldSatisfy` elem ("Activity_t", "Event_fin")

    it "is not reported as unreachable" $
      -- It is reachable, by its trigger. Reporting it would make every handler
      -- an error.
      messagesOf (errorsOf' (handler "handler h { start c { error e }\ntask u\nend f }")) `shouldBe` []

    it "requires its start event to wait for something" $
      messagesOf (errorsOf' (handler "handler h { start c\ntask u\nend f }"))
        `shouldSatisfy` any (isInfixOf "waits for nothing")

    it "rejects an error start event outside one" $
      messagesOf (errorsOf' "error e \"E\"\nprocess p { start s { error e }\nend fin }")
        `shouldSatisfy` any (isInfixOf "only the start of an event subprocess")

    it "rejects 'noninterrupting' outside one" $
      messagesOf (errorsOf' "message m \"w\"\nprocess p { start s { message m\nnoninterrupting }\nend fin }")
        `shouldSatisfy` any (isInfixOf "no enclosing scope")

    it "refuses a boundary event on one" $
      messagesOf (errorsOf' (handler "handler h { start c { error e }\nend f }\non h catch timer \"PT1M\" as late { end l }"))
        `shouldSatisfy` any (isInfixOf "an event subprocess")

  describe "groups" $ do
    it "records its members and makes no association" $
      let sc = scopeOf "start s\ntask a\ntask b\nend e\ngroup g \"G\" { a b }"
       in ( [map unNodeId (artMembers x) | x <- scArtifacts sc, artKind x == AkGroup]
          , length (scAssociations sc)
          )
            `shouldBe` ([["Activity_a", "Activity_b"]], 0)

    it "rejects a member in another scope" $
      messagesOf (errorsOf' "start s\nsubprocess sub { start i\ntask inner\nend o }\nend e\ngroup g { inner }")
        `shouldSatisfy` any (isInfixOf "outside its scope")

    it "rejects a member that is not a step" $
      messagesOf (errorsOf' "start s\ntask a\nend e\nnote n \"hi\" on a\ngroup g { n }")
        `shouldSatisfy` any (isInfixOf "not a step")

    it "warns when it holds nothing" $
      messagesOf (diagsOf "start s\ntask a\nend e\ngroup g { }")
        `shouldSatisfy` any (isInfixOf "has no members")

    it "creates no merge when only one branch continues" $
      nodeIds "start s\nxor g { branch \"y\" otherwise { task a } branch \"n\" when \"=n\" { end halt } }\nend e"
        `shouldNotContain` ["Gateway_g_join"]

    it "creates the merge anyway when the author names the join" $
      nodeIds "start s\nxor g join later { branch \"y\" otherwise { task a } branch \"n\" when \"=n\" { end halt } }\nend e"
        `shouldContain` ["Gateway_later"]

    it "routes goto back to an earlier step" $
      flowPairs "start s\ntask a\nxor g { branch \"y\" otherwise\nbranch \"n\" when \"=n\" { goto a } }\nend e"
        `shouldSatisfy` elem ("Gateway_g", "Activity_a")

    it "carries the branch label and condition onto the flow it opens" $
      let src = "start s\nxor g { branch \"yes\" otherwise { task a } branch \"no\" when \"=n\" { task b } }\nend e"
       in [(sfName f, sfCondition f) | f <- flowsOf src, sfSource f == NodeId "Gateway_g"]
            `shouldBe` [(Just "yes", Just FcDefault), (Just "no", Just (FcExpression (FeelExpr "=n")))]

  describe "name resolution" $ do
    it "rejects an undefined step reference" $
      messagesOf (errorsOf' "start s\nflow s -> nowhere")
        `shouldSatisfy` any (isInfixOf "undefined step 'nowhere'")

    it "rejects a duplicate declaration" $
      messagesOf (errorsOf' "start a\nend a\nflow a -> a")
        `shouldSatisfy` any (isInfixOf "duplicate declaration of 'a'")

    it "lets a repeated lane block re-enter the same lane" $
      errorsOf' "lane l { start s }\nlane l { end e }" `shouldBe` []

    it "requires a message to be declared" $
      messagesOf (errorsOf' "start s\nreceive r { message ghost }\nend e")
        `shouldSatisfy` any (isInfixOf "undeclared message 'ghost'")

  describe "structural rules" $ do
    it "rejects a condition on a parallel branch" $
      messagesOf (errorsOf' "start s\nand g { branch when \"=x\" { task a } branch { task b } }\nend e")
        `shouldSatisfy` any (isInfixOf "only allowed on a branch of an xor")

    it "rejects a start event with an incoming flow" $
      messagesOf (errorsOf' "start s\nend e\nflow e -> s")
        `shouldSatisfy` any (isInfixOf "cannot have an incoming flow")

    it "rejects an end event with an outgoing flow" $
      messagesOf (errorsOf' "start s\nend e\nflow e -> s")
        `shouldSatisfy` any (isInfixOf "cannot have an outgoing flow")

    it "rejects a flow that restates the implicit chain" $
      -- Steps chain implicitly, so this line adds a *second* edge between the
      -- same pair. Two connectors between one pair of ports are collinear by
      -- construction, so the compiler cannot draw it either.
      messagesOf (errorsOf' "start s\ntask a\nend e\nflow s -> a")
        `shouldSatisfy` any (isInfixOf "'s' and 'a' are already connected")

    it "points a duplicate flow at the line that wrote it" $
      [(diagCategory d, fmap (posLine . spanStart) (diagSpan d))
      | d <- errorsOf' "start s\ntask a\nend e\nflow s -> a"
      ]
        `shouldBe` [(SemanticError, Just 5)]

    it "explains a decorated duplicate differently from a bare one" $
      let hintFor src = [h | d <- errorsOf' src, Just h <- [diagHint d]]
       in ( hintFor "start s\ntask a\ntask b\nend e\nflow a -> b"
          , hintFor "start s\ntask a\ntask b\nend e\nflow a -> b \"why\" when \"=x\""
          )
            `shouldSatisfy` \(bare, dec) -> bare /= dec && not (null bare) && not (null dec)

    it "rejects two branches that goto the same step" $
      messagesOf (errorsOf' "start s\ntask a\ntask x\nend e\nxor g { branch \"a\" when \"=a\" { goto x } branch \"b\" when \"=b\" { goto x } }")
        `shouldSatisfy` any (isInfixOf "are already connected")

    it "allows a flow that connects a pair the chain left unconnected" $
      errorsOf' "start s\ntask a\ntask b\nend e\nflow a -> e" `shouldBe` []

    it "rejects a repeated message flow" $
      messagesOf (errorsOf' "collaboration c { pool x { start s\ntask a\nend e } pool y { start t\ntask b\nend f } a ~> b\na ~> b \"again\" }")
        `shouldSatisfy` any (isInfixOf "already connected by a message flow")

    it "rejects an unreachable step" $
      messagesOf (errorsOf' "start s\nend e\ntask orphan")
        `shouldSatisfy` any (isInfixOf "not reachable from any start event")

    it "rejects a process with no start event" $
      messagesOf (errorsOf' "end e") `shouldSatisfy` any (isInfixOf "no start event")

    it "rejects a boundary event on a gateway" $
      messagesOf (errorsOf' "start s\nxor g { branch }\nend e\non g catch timer \"PT1M\" as late { end l }")
        `shouldSatisfy` any (isInfixOf "boundary event attaches to a task or subprocess")

    it "requires a subprocess to have exactly one start event" $
      messagesOf (errorsOf' "start s\nsubprocess sub { task a\nend done }\nend e")
        `shouldSatisfy` any (isInfixOf "subprocess needs exactly one start event")

    it "rejects an event gateway whose branch does not start with a catching event" $
      messagesOf (errorsOf' "start s\nevent g { branch { task a } branch { task b } }\nend e")
        `shouldSatisfy` any (isInfixOf "does not begin with a catching event")

  describe "properties" $ do
    it "rejects a property the step kind does not accept" $
      messagesOf (errorsOf' "start s { groups \"x\" }\nend e\nflow s -> e")
        `shouldSatisfy` any (isInfixOf "'groups' is not a property of a start step")

    it "requires a job type on a service task" $
      messagesOf (errorsOf' "start s\nservice t\nend e")
        `shouldSatisfy` any (isInfixOf "needs a 'type' property")

    it "rejects two triggers on one event" $
      messagesOf (errorsOf' "signal x \"s\"\nprocess p { start s\nend e { terminate signal x }\nflow s -> e }")
        `shouldSatisfy` any (isInfixOf "already has a trigger")

  describe "FEEL normalisation" $
    it "adds the leading '=' Camunda expects" $
      let src = "start s\nxor g { branch \"a\" when \"x > 1\" { task t } branch \"b\" otherwise { task u } }\nend e"
       in [unFeel e | f <- flowsOf src, Just (FcExpression e) <- [sfCondition f]] `shouldBe` ["=x > 1"]

  describe "lanes" $ do
    it "assigns lane membership from nesting" $
      [(unNodeId (fnId n), fmap unLaneId (fnLane n)) | n <- nodesOf "lane a \"A\" { start s }\nlane b \"B\" { end e }"]
        `shouldBe` [("StartEvent_s", Just "Lane_a"), ("Event_e", Just "Lane_b")]

    it "keeps lane order as written" $
      map (fmap unLaneId . Just . laneId) (lanesOf "lane z \"Z\" { start s }\nlane a \"A\" { end e }")
        `shouldBe` [Just "Lane_z", Just "Lane_a"]

  describe "Camunda metadata" $ do
    it "keeps the job type, retries, mappings and headers" $
      execOf "start s\nservice t { type \"job\" retries 4 input a = \"=x\" output b = \"=y\" header k = \"v\" }\nend e"
        `shouldBe` Just
          ( ExService
              ZeebeTask
                { ztType = "job"
                , ztRetries = Just 4
                , ztInputs = [Mapping "a" (FeelExpr "=x")]
                , ztOutputs = [Mapping "b" (FeelExpr "=y")]
                , ztHeaders = [Header "k" "v"]
                }
          )

    it "warns about a caught message with no correlation key" $
      messagesOf (diagsOf "message m \"wire\"\nprocess p { start s\nreceive r { message m }\nend e }")
        `shouldSatisfy` any (isInfixOf "no correlation key")

    it "rejects a non-positive retry count" $
      messagesOf (errorsOf' "start s\nservice t { type \"j\" retries 0 }\nend e")
        `shouldSatisfy` any (isInfixOf "non-positive retry count")

    it "rejects a malformed timer" $
      messagesOf (errorsOf' "start s\ntask t\nend e\non t catch timer \"15m\" as late { end l }")
        `shouldSatisfy` any (isInfixOf "malformed timer")

    it "gives a throwing message event the job Camunda runs it as" $
      -- Camunda 8 implements a message throw or end event as a job: the broker
      -- creates one and a worker publishes the message. So the event carries
      -- the same task definition a service task does.
      execOfNode "Event_done" "message m \"wire\"\nprocess p { start s\ntask a\nend done \"Done\" { message m\ntype \"publish\" retries 3 header k = \"v\" } }"
        `shouldBe` Just
          ( ExService
              ZeebeTask
                { ztType = "publish"
                , ztRetries = Just 3
                , ztInputs = []
                , ztOutputs = []
                , ztHeaders = [Header "k" "v"]
                }
          )

    it "warns when a thrown message has no job type" $
      -- Valid BPMN, undeployable process: Zeebe rejects it with "must have
      -- exactly one 'zeebe:taskDefinition' extension element".
      messagesOf (diagsOf "message m \"wire\"\nprocess p { start s\ntask a\nend done \"Done\" { message m } }")
        `shouldSatisfy` any (isInfixOf "throws a message but has no job type")

    it "rejects a job type on an event that throws nothing" $
      messagesOf (errorsOf' "start s\ntask a\nend done \"Done\" { type \"nope\" }")
        `shouldSatisfy` any (isInfixOf "does not throw a message")

    it "lets a script task be implemented by a job worker" $
      -- Camunda 8 runs a script task either in the broker, from a FEEL
      -- expression, or on a worker, from a task definition. The second form is
      -- the one a modeller gets by picking \"job worker\" in the properties
      -- panel, and a language that only had the first could not read it back.
      execOfNode "Activity_t" "start s\nscript t { type \"js\" retries 2 }\nend e"
        `shouldBe` Just (ExService (emptyZeebeTask "js") {ztRetries = Just 2})

    it "lets a business-rule task be implemented by a job worker" $
      execOfNode "Activity_t" "start s\nbusiness t { type \"rules\" }\nend e"
        `shouldBe` Just (ExService (emptyZeebeTask "rules"))

    it "rejects a step that names both implementations" $
      -- Only one of them reaches the XML, so accepting both would make the
      -- source say something the output does not.
      messagesOf (errorsOf' "start s\nscript t { expression \"=1\" type \"js\" }\nend e")
        `shouldSatisfy` any (isInfixOf "implemented by 'expression' or by 'type', not both")

  describe "the result" $ do
    it "emits no BPMN when anything is an error" $
      crXml (compileOk "end e") `shouldSatisfy` isNothing

    it "withholds the graph when a name cannot be resolved" $
      crGraph (compileOk "start s\nflow s -> nowhere") `shouldSatisfy` isNothing

    it "returns the graph when only warnings remain" $
      crGraph (compileOk "message m \"w\"\nprocess p { start s\nreceive r { message m }\nend e }")
        `shouldSatisfy` isJust

-- Helpers --------------------------------------------------------------------

scopeOf :: Text -> Scope
scopeOf src = case sgProcesses (graphOf src) of
  (p : _) -> procScope p
  [] -> error "no process"

nodesOf :: Text -> [FlowNode]
nodesOf = scNodes . scopeOf

nodeIds :: Text -> [Text]
nodeIds src = [unNodeId (fnId n) | n <- nodesOf src]

flowsOf :: Text -> [SequenceFlow]
flowsOf = scFlows . scopeOf

flowPairs :: Text -> [(Text, Text)]
flowPairs src = [(unNodeId (sfSource f), unNodeId (sfTarget f)) | f <- flowsOf src]

lanesOf :: Text -> [Lane]
lanesOf src = case sgProcesses (graphOf src) of
  (p : _) -> procLanes p
  [] -> []

execOf :: Text -> Maybe ExecutionMeta
execOf src = case [fnExec n | n <- nodesOf src, nodeIsActivity n] of
  (e : _) -> Just e
  [] -> Nothing

execOfNode :: Text -> Text -> Maybe ExecutionMeta
execOfNode i src = case [fnExec n | n <- nodesOf src, unNodeId (fnId n) == i] of
  (e : _) -> Just e
  [] -> Nothing
