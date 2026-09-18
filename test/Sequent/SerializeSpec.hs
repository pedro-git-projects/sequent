-- | BPMN output tests.
--
-- These parse the generated XML back and query the tree rather than matching
-- strings, so they assert what a BPMN consumer sees instead of how the
-- serialiser happens to lay bytes out. The byte-exact assertions live in
-- "Sequent.GoldenSpec", where they belong.
module Sequent.SerializeSpec (spec) where

import Control.Monad (forM_)
import Data.List (sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.FilePath (takeExtension, (</>))
import System.Directory (listDirectory)
import Test.Hspec

import Sequent.Compiler
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "document shape" $ do
    it "declares the Camunda 8 namespaces and platform" $ do
      let root = xmlOf "start s\nend e"
      (attr "xmlns:zeebe" root, attr "modeler:executionPlatform" root)
        `shouldBe` (Just "http://camunda.org/schema/zeebe/1.0", Just "Camunda Cloud")

    it "puts root elements before the process that references them" $ do
      let root = xmlOf "message m \"w\" correlation \"=k\"\nprocess p { start s { message m }\nend e }"
      map xmlName (xmlChildren root)
        `shouldSatisfy` \ns -> indexOf "bpmn:message" ns < indexOf "bpmn:process" ns

    it "marks the process executable" $
      attr "isExecutable" (processOf "start s\nend e") `shouldBe` Just "true"

  describe "event subprocesses, groups and interrupting flags" $ do
    let handlerSrc =
          "error e \"E\"\nprocess p { start s\ntask t\nend fin\nhandler h \"H\" { start c { error e }\ntask u\nend f } }"
        nonIntSrc =
          "message m \"w\"\nprocess p { start s\ntask t\nend fin\nhandler h { start c { message m\nnoninterrupting }\ntask u\nend f } }"

    it "writes an event subprocess as triggeredByEvent" $
      (elementNameFor handlerSrc "Activity_h", attr "triggeredByEvent" (byId "Activity_h" handlerSrc))
        `shouldBe` ("bpmn:subProcess", Just "true")

    it "nests the handler's steps inside it" $
      map xmlName (xmlChildren (byId "Activity_h" handlerSrc))
        `shouldSatisfy` \ns -> "bpmn:startEvent" `elem` ns && "bpmn:endEvent" `elem` ns

    it "connects an event subprocess to nothing" $
      -- It runs when its start event fires. A sequence flow into or out of it
      -- would be a different construct with the same drawing.
      map (\f -> (attr "sourceRef" f, attr "targetRef" f)) (descendantsNamed "bpmn:sequenceFlow" (processOf handlerSrc))
        `shouldSatisfy` all (\(a, b) -> a /= Just "Activity_h" && b /= Just "Activity_h")

    it "omits isInterrupting when the start event interrupts" $
      -- It defaults to true. Writing it on every start event in every file
      -- would be noise in the diff of every process that has none.
      attr "isInterrupting" (byId "StartEvent_c" handlerSrc) `shouldBe` Nothing

    it "writes isInterrupting=false when it does not" $
      attr "isInterrupting" (byId "StartEvent_c" nonIntSrc) `shouldBe` Just "false"

    it "writes a group and the category value that holds its text" $ do
      let src = "start s\ntask a\nend e\ngroup money \"Money moves\" { a }"
          root = xmlOf src
          cat = head (childrenNamed "bpmn:category" root)
          val = head (childrenNamed "bpmn:categoryValue" cat)
      (attr "categoryValueRef" (byId "Group_money" src), attr "value" val)
        `shouldBe` (attr "id" val, Just "Money moves")

    it "puts the category before the process that refers to it" $
      map xmlName (xmlChildren (xmlOf "start s\ntask a\nend e\ngroup g \"G\" { a }"))
        `shouldSatisfy` \ns -> indexOf "bpmn:category" ns < indexOf "bpmn:process" ns

    it "gives the group a shape that holds its members" $ do
      -- ART-005: the rectangle is the members' bounding box plus padding, and
      -- the importer reads membership back out of exactly that.
      let src = "start s\ntask a\nend e\ngroup g \"G\" { a }"
          bounds = boundsIn (planeOf src)
      case (lookup "Group_g" bounds, lookup "Activity_a" bounds) of
        (Just (gx, gy, gw, gh), Just (ax, ay, aw, ah)) ->
          (gx < ax, gy < ay, gx + gw > ax + aw, gy + gh > ay + ah) `shouldBe` (True, True, True, True)
        _ -> expectationFailure "expected a shape for the group and its member"

  describe "flow nodes" $ do
    it "uses the right BPMN element for each step keyword" $
      map (elementNameFor "start s\nservice a { type \"t\" }\nuser b\nmanual c\nend e")
        ["Activity_a", "Activity_b", "Activity_c", "StartEvent_s", "Event_e"]
        `shouldBe` ["bpmn:serviceTask", "bpmn:userTask", "bpmn:manualTask", "bpmn:startEvent", "bpmn:endEvent"]

    it "regenerates incoming and outgoing from the flow list" $ do
      let node = fromMaybe (error "no node") (findById "Activity_a" (xmlOf "start s\ntask a\nend e"))
      ( map textOf (childrenNamed "bpmn:incoming" node)
        , map textOf (childrenNamed "bpmn:outgoing" node)
        )
        `shouldBe` (["Flow_s_a"], ["Flow_a_e"])

    it "marks the default flow on the gateway that owns it" $
      let src = "start s\nxor g { branch \"y\" otherwise { task a } branch \"n\" when \"=n\" { task b } }\nend e"
       in attr "default" (byId "Gateway_g" src) `shouldBe` Just "Flow_g_a"

  describe "Camunda extensions" $ do
    it "emits taskDefinition, ioMapping and taskHeaders" $ do
      let node = byId "Activity_t" "start s\nservice t { type \"job\" retries 4 input a = \"=x\" output b = \"=y\" header k = \"v\" }\nend e"
          ext = concatMap xmlChildren (childrenNamed "bpmn:extensionElements" node)
      map xmlName ext `shouldBe` ["zeebe:taskDefinition", "zeebe:ioMapping", "zeebe:taskHeaders"]

    it "keeps the job type and retries" $ do
      let node = byId "Activity_t" "start s\nservice t { type \"job\" retries 4 }\nend e"
          td = head (descendantsNamed "zeebe:taskDefinition" node)
      (attr "type" td, attr "retries" td) `shouldBe` (Just "job", Just "4")

    it "emits a job on a message end event, before its event definition" $ do
      -- Camunda 8 runs a throwing message event as a job, so the event carries
      -- a task definition. The BPMN sequence model for tThrowEvent puts
      -- extensionElements before eventDefinition, and a validating reader
      -- rejects the other order.
      let node =
            byId
              "Event_done"
              "message m \"wire\"\nprocess p { start s\ntask a\nend done \"Done\" { message m\ntype \"publish\" } }"
          td = descendantsNamed "zeebe:taskDefinition" node
       in ( map (attr "type") td
          , [n | n <- map xmlName (xmlChildren node), n `elem` ["bpmn:extensionElements", "bpmn:messageEventDefinition"]]
          )
            `shouldBe` ([Just "publish"], ["bpmn:extensionElements", "bpmn:messageEventDefinition"])

    it "emits a user task with its form and assignment" $ do
      let node = byId "Activity_u" "start s\nuser u { form \"f\" groups \"sales\" }\nend e"
      map xmlName (descendantsNamed "zeebe:formDefinition" node ++ descendantsNamed "zeebe:assignmentDefinition" node)
        `shouldBe` ["zeebe:formDefinition", "zeebe:assignmentDefinition"]

    it "emits a called element for a call activity" $ do
      let ce = head (descendantsNamed "zeebe:calledElement" (byId "Activity_c" "start s\ncall c { calls \"other\" propagate }\nend e"))
      (attr "processId" ce, attr "propagateAllChildVariables" ce) `shouldBe` (Just "other", Just "true")

    it "emits multi-instance loop characteristics" $ do
      let node = byId "Activity_t" "start s\nservice t { type \"j\" each line in \"=xs\" }\nend e"
          lc = head (descendantsNamed "zeebe:loopCharacteristics" node)
      (attr "inputCollection" lc, attr "inputElement" lc) `shouldBe` (Just "=xs", Just "line")

    it "emits the message subscription correlation key" $ do
      let m = byId "Message_m" "message m \"wire\" correlation \"=k\"\nprocess p { start s { message m }\nend e }"
      map (attr "correlationKey") (descendantsNamed "zeebe:subscription" m) `shouldBe` [Just "=k"]

  describe "events" $ do
    it "attaches a boundary event to its host and marks interruption" $ do
      let src = "start s\ntask t\nend e\non t catch timer \"PT1M\" noninterrupting as late { end l }"
          be = byId "Event_late" src
      (attr "attachedToRef" be, attr "cancelActivity" be) `shouldBe` (Just "Activity_t", Just "false")

    it "writes the timer as a formal expression" $ do
      let src = "start s\ntask t\nend e\non t catch timer \"PT1M\" as late { end l }"
          td = head (descendantsNamed "bpmn:timeDuration" (byId "Event_late" src))
      (attr "xsi:type" td, textOf td) `shouldBe` (Just "bpmn:tFormalExpression", "PT1M")

    it "references the declared error" $
      let src = "error boom \"BOOM\"\nprocess p { start s\nend e { error boom } }"
       in map (attr "errorRef") (descendantsNamed "bpmn:errorEventDefinition" (xmlOf src))
            `shouldBe` [Just "Error_boom"]

  describe "collaboration" $ do
    it "emits participants and message flows" $ do
      let root = xmlOf collabSrc
          col = head (childrenNamed "bpmn:collaboration" root)
      ( length (childrenNamed "bpmn:participant" col)
        , map (attr "sourceRef") (childrenNamed "bpmn:messageFlow" col)
        )
        `shouldBe` (2, [Just "Activity_a"])

    it "gives the plane the collaboration as its element" $
      attr "bpmnElement" (planeOf collabSrc) `shouldBe` Just "Collaboration_c"

  describe "diagram interchange" $ do
    it "emits a shape for every flow node and an edge for every flow" $ do
      let plane = planeOf "start s\ntask a\nend e"
      (length (childrenNamed "bpmndi:BPMNShape" plane), length (childrenNamed "bpmndi:BPMNEdge" plane))
        `shouldBe` (3, 2)

    it "emits shapes before edges" $ do
      let ns = map xmlName (xmlChildren (planeOf "start s\ntask a\nend e"))
      ns `shouldBe` replicate 3 "bpmndi:BPMNShape" ++ replicate 2 "bpmndi:BPMNEdge"

    it "gives every shape integer bounds" $
      allBounds (planeOf "start s\ntask a\nend e")
        `shouldSatisfy` all (\(x, y, w, h) -> x >= 0 && y >= 0 && w > 0 && h > 0)

    it "emits a label box for an external label" $
      length (descendantsNamed "bpmndi:BPMNLabel" (planeOf "start s \"Started\"\nend e"))
        `shouldSatisfy` (>= 1)

    it "marks an exclusive gateway's X" $
      attr "isMarkerVisible" (byIdIn (planeOf "start s\nxor g { branch }\nend e") "Gateway_g_di")
        `shouldBe` Just "true"

    it "marks an expanded subprocess" $
      attr "isExpanded" (byIdIn (planeOf "start s\nsubprocess sub { start b\ntask t\nend d }\nend e") "Activity_sub_di")
        `shouldBe` Just "true"

  describe "no-DI mode" $
    it "omits the diagram entirely" $
      length (childrenNamed "bpmndi:BPMNDiagram" (parseXml (noDi "start s\nend e"))) `shouldBe` 0

  describe "schema conformance" $ do
    -- The BPMN 2.0 schema sequences children, and a validating reader rejects
    -- a document that gets the order wrong even though bpmn-js would load it.
    -- These run over every committed example rather than over a fixture, so a
    -- new construct cannot slip past them.
    sources <- runIO exampleXml

    forM_ sources $ \(name, root) -> describe name $ do
      it "orders process children as the schema requires" $
        concatMap (outOfOrder processOrder) (childrenNamed "bpmn:process" root) `shouldBe` []

      it "orders activity children as the schema requires" $
        concatMap (outOfOrder activityOrder) (activities root) `shouldBe` []

      it "orders event children as the schema requires" $
        concatMap (outOfOrder eventOrder) (events root) `shouldBe` []

      it "puts every root element before the diagram" $
        dropWhile (/= "bpmndi:BPMNDiagram") (map xmlName (xmlChildren root))
          `shouldSatisfy` all (== "bpmndi:BPMNDiagram")

      it "resolves every reference" $
        unresolvedRefs root `shouldBe` []

      it "resolves every incoming, outgoing and flowNodeRef" $
        unresolvedTextRefs root `shouldBe` []

      it "points every DI shape and edge at a real element" $
        unresolvedDi root `shouldBe` []

-- Schema order ------------------------------------------------------------------

-- | @tProcess@: documentation?, extensionElements?, laneSet*, flowElement*,
-- artifact*.
processOrder :: [[Text]]
processOrder = [["bpmn:documentation"], ["bpmn:extensionElements"], ["bpmn:laneSet"], flowElements, artifacts]

-- | @tActivity@ then @tSubProcess@'s extension.
activityOrder :: [[Text]]
activityOrder =
  [ ["bpmn:documentation"]
  , ["bpmn:extensionElements"]
  , ["bpmn:incoming"]
  , ["bpmn:outgoing"]
  , ["bpmn:dataInputAssociation"]
  , ["bpmn:dataOutputAssociation"]
  , ["bpmn:multiInstanceLoopCharacteristics"]
  , ["bpmn:laneSet"]
  , flowElements
  , artifacts
  ]

-- | @tCatchEvent@ \/ @tThrowEvent@: event definitions come last.
eventOrder :: [[Text]]
eventOrder =
  [ ["bpmn:documentation"]
  , ["bpmn:extensionElements"]
  , ["bpmn:incoming"]
  , ["bpmn:outgoing"]
  , eventDefinitions
  ]

flowElements :: [Text]
flowElements =
  [ "bpmn:startEvent", "bpmn:endEvent", "bpmn:intermediateCatchEvent"
  , "bpmn:intermediateThrowEvent", "bpmn:boundaryEvent", "bpmn:task"
  , "bpmn:serviceTask", "bpmn:userTask", "bpmn:manualTask", "bpmn:scriptTask"
  , "bpmn:businessRuleTask", "bpmn:sendTask", "bpmn:receiveTask"
  , "bpmn:callActivity", "bpmn:subProcess", "bpmn:exclusiveGateway"
  , "bpmn:parallelGateway", "bpmn:inclusiveGateway", "bpmn:eventBasedGateway"
  , "bpmn:complexGateway", "bpmn:sequenceFlow", "bpmn:dataObject"
  , "bpmn:dataObjectReference", "bpmn:dataStoreReference"
  ]

artifacts :: [Text]
artifacts = ["bpmn:textAnnotation", "bpmn:association", "bpmn:group"]

eventDefinitions :: [Text]
eventDefinitions =
  [ "bpmn:messageEventDefinition", "bpmn:signalEventDefinition"
  , "bpmn:errorEventDefinition", "bpmn:escalationEventDefinition"
  , "bpmn:timerEventDefinition", "bpmn:terminateEventDefinition"
  , "bpmn:compensateEventDefinition", "bpmn:linkEventDefinition"
  ]

-- | The children that appear after a child from a later group, plus any child
-- the schema does not allow there at all.
outOfOrder :: [[Text]] -> Xml -> [Text]
outOfOrder groups el = go (-1) (map xmlName (xmlChildren el))
  where
    go _ [] = []
    go highest (n : rest) = case groupOf n of
      Nothing -> (xmlName el <> "/" <> n <> ": not permitted") : go highest rest
      Just g
        | g < highest -> (xmlName el <> "/" <> n <> ": out of order") : go highest rest
        | otherwise -> go (max highest g) rest
    groupOf n = case [i | (i, g) <- zip [0 :: Int ..] groups, n `elem` g] of
      (i : _) -> Just i
      [] -> Nothing

activities :: Xml -> [Xml]
activities root = [e | e <- everything root, xmlName e `elem` activityNames]
  where
    activityNames =
      [ "bpmn:task", "bpmn:serviceTask", "bpmn:userTask", "bpmn:manualTask"
      , "bpmn:scriptTask", "bpmn:businessRuleTask", "bpmn:sendTask"
      , "bpmn:receiveTask", "bpmn:callActivity", "bpmn:subProcess"
      ]

events :: Xml -> [Xml]
events root = [e | e <- everything root, xmlName e `elem` eventNames]
  where
    eventNames =
      [ "bpmn:startEvent", "bpmn:endEvent", "bpmn:intermediateCatchEvent"
      , "bpmn:intermediateThrowEvent", "bpmn:boundaryEvent"
      ]

everything :: Xml -> [Xml]
everything e = e : concatMap everything (xmlChildren e)

idsOf :: Xml -> [Text]
idsOf root = [i | e <- everything root, Just i <- [attr "id" e]]

unresolvedRefs :: Xml -> [Text]
unresolvedRefs root =
  [ xmlName e <> "/" <> k <> "=" <> v
  | e <- everything root
  , (k, v) <- xmlAttrs e
  , k `elem` refAttrs
  , v `notElem` idsOf root
  ]
  where
    refAttrs =
      [ "sourceRef", "targetRef", "attachedToRef", "messageRef", "signalRef"
      , "errorRef", "escalationRef", "processRef", "dataObjectRef", "default"
      ]

unresolvedTextRefs :: Xml -> [Text]
unresolvedTextRefs root =
  [ xmlName e <> "=" <> textOf e
  | e <- everything root
  , xmlName e `elem` ["bpmn:incoming", "bpmn:outgoing", "bpmn:flowNodeRef"]
  , textOf e `notElem` idsOf root
  ]

unresolvedDi :: Xml -> [Text]
unresolvedDi root =
  [ xmlName e <> "=" <> v
  | e <- everything root
  , xmlName e `elem` ["bpmndi:BPMNShape", "bpmndi:BPMNEdge"]
  , Just v <- [attr "bpmnElement" e]
  , v `notElem` idsOf root
  ]

exampleXml :: IO [(FilePath, Xml)]
exampleXml = do
  names <- sort . filter ((== ".sq") . takeExtension) <$> listDirectory "examples"
  mapM (\n -> (,) n . parseXml <$> readExample n) names
  where
    readExample n = do
      text <- TIO.readFile ("examples" </> n)
      case crXml (compileText defaultOptions n text) of
        Just x -> pure x
        Nothing -> fail ("could not compile " <> n)

collabSrc :: Text
collabSrc = "collaboration c { pool x { start s\ntask a\nend e } pool y { start t\ntask b\nend f } a ~> b }"

-- Helpers --------------------------------------------------------------------

xmlOf :: Text -> Xml
xmlOf = parseXml . compileXml

processOf :: Text -> Xml
processOf src = head (childrenNamed "bpmn:process" (xmlOf src))

planeOf :: Text -> Xml
planeOf src = head (descendantsNamed "bpmndi:BPMNPlane" (xmlOf src))

byId :: Text -> Text -> Xml
byId i src = fromMaybe (error ("no element " <> T.unpack i)) (findById i (xmlOf src))

byIdIn :: Xml -> Text -> Xml
byIdIn root i = fromMaybe (error ("no element " <> T.unpack i)) (findById i root)

elementNameFor :: Text -> Text -> Text
elementNameFor src i = maybe "?" xmlName (findById i (xmlOf src))

allBounds :: Xml -> [(Int, Int, Int, Int)]
allBounds plane =
  mapMaybe toTuple (descendantsNamed "dc:Bounds" plane)
  where
    toTuple e = do
      x <- num "x" e
      y <- num "y" e
      w <- num "width" e
      h <- num "height" e
      pure (x, y, w, h)
    num k e = attr k e >>= readInt
    readInt t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _ -> Nothing

-- | Each shape's element id with its bounds, so a test can compare two of them.
boundsIn :: Xml -> [(Text, (Int, Int, Int, Int))]
boundsIn plane =
  [ (el, b)
  | sh <- descendantsNamed "bpmndi:BPMNShape" plane
  , Just el <- [attr "bpmnElement" sh]
  , bnd <- childrenNamed "dc:Bounds" sh
  , Just b <- [toTuple bnd]
  ]
  where
    toTuple e = do
      x <- num "x" e
      y <- num "y" e
      w <- num "width" e
      h <- num "height" e
      pure (x, y, w, h)
    num k e = attr k e >>= readInt
    readInt t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _ -> Nothing

noDi :: Text -> Text
noDi src = case crXml (compileText (defaultOptions {coEmitDi = False}) "test.sq" (wrapProcess src)) of
  Just x -> x
  Nothing -> error "compile failed"

indexOf :: Eq a => a -> [a] -> Int
indexOf x = length . takeWhile (/= x)
