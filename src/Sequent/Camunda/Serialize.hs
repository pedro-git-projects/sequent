-- | The Camunda 8 BPMN serialiser: semantic graph + rendered geometry → XML.
--
-- Strictly downstream. The serialiser reads @SG@ and @RG@ and writes bytes; it
-- makes no decision that could have been made earlier, and nothing upstream is
-- shaped by XML element order or namespace prefixes. That direction of
-- dependency is what keeps "what Camunda wants in the file" from becoming the
-- compiler's architecture.
--
-- Determinism is structural rather than enforced: every collection walked here
-- is a list in canonical order or a "Data.Map.Strict" keyed by an ordered id,
-- attribute order is list order, and every id comes from "Sequent.Bpmn.Id". The
-- same graph and geometry therefore produce the same bytes (HC-016).
module Sequent.Camunda.Serialize
  ( serialize
  , serializeNoDi
  , definitionsElement
  , exporterName
  , exporterVersion
  , executionPlatformVersion
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (maybeToList)
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Id (dataObjectIdFor, defId, diId)
import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model
import Sequent.Camunda.Xml
import Sequent.Layout.Types

exporterName :: Text
exporterName = "sequent"

exporterVersion :: Text
exporterVersion = "0.2.0"

-- | The Camunda 8 minor version the generated attributes target.
executionPlatformVersion :: Text
executionPlatformVersion = "8.6.0"

serialize :: SemanticGraph -> Geometry -> Text
serialize g geo = renderDocument (definitionsElement g (Just geo))

-- | Semantics only, no @BPMNDiagram@. Useful when reading the structural
-- output by eye and when asserting that geometry cannot influence semantics.
serializeNoDi :: SemanticGraph -> Text
serializeNoDi g = renderDocument (definitionsElement g Nothing)

definitionsElement :: SemanticGraph -> Maybe Geometry -> Element
definitionsElement g mgeo =
  elem_
    "bpmn:definitions"
    [ ("xmlns:bpmn", "http://www.omg.org/spec/BPMN/20100524/MODEL")
    , ("xmlns:bpmndi", "http://www.omg.org/spec/BPMN/20100524/DI")
    , ("xmlns:dc", "http://www.omg.org/spec/DD/20100524/DC")
    , ("xmlns:di", "http://www.omg.org/spec/DD/20100524/DI")
    , ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance")
    , ("xmlns:zeebe", "http://camunda.org/schema/zeebe/1.0")
    , ("xmlns:modeler", "http://camunda.org/schema/modeler/1.0")
    , ("id", "Definitions_1")
    , ("targetNamespace", "http://bpmn.io/schema/bpmn")
    , ("exporter", exporterName)
    , ("exporterVersion", exporterVersion)
    , ("modeler:executionPlatform", "Camunda Cloud")
    , ("modeler:executionPlatformVersion", executionPlatformVersion)
    ]
    ( rootElements g
        ++ maybeToList (collaborationElement <$> sgCollaboration g)
        ++ map processElement (sgProcesses g)
        ++ maybeToList (diagramElement g <$> mgeo)
    )

-- Root elements ----------------------------------------------------------------

-- | BPMN requires root elements before the processes that reference them.
rootElements :: SemanticGraph -> [Element]
rootElements g =
  map messageElement (sgMessages g)
    ++ map signalElement (sgSignals g)
    ++ map errorElement (sgErrors g)
    ++ map escalationElement (sgEscalations g)

messageElement :: MessageDef -> Element
messageElement m =
  Element
    "bpmn:message"
    [("id", unNodeId (msgId m)), ("name", msgName m)]
    [ CElem
        ( elem_
            "bpmn:extensionElements"
            []
            [leaf "zeebe:subscription" [("correlationKey", unFeel c)]]
        )
    | Just c <- [msgCorrelation m]
    ]

signalElement :: SignalDef -> Element
signalElement s = leaf "bpmn:signal" [("id", unNodeId (sigId s)), ("name", sigName s)]

errorElement :: ErrorDef -> Element
errorElement e =
  leaf "bpmn:error" [("id", unNodeId (errId e)), ("name", errName e), ("errorCode", errCode e)]

escalationElement :: EscalationDef -> Element
escalationElement e =
  leaf
    "bpmn:escalation"
    [("id", unNodeId (escId e)), ("name", escName e), ("escalationCode", escCode e)]

collaborationElement :: Collaboration -> Element
collaborationElement c =
  elem_
    "bpmn:collaboration"
    [("id", colId c)]
    ( map participantElement (colParticipants c)
        ++ map messageFlowElement (colMessageFlows c)
    )

participantElement :: Participant -> Element
participantElement p =
  leaf
    "bpmn:participant"
    ( [("id", unParticipantId (partId p))]
        ++ [("name", n) | Just n <- [partName p]]
        ++ [("processRef", unProcessId pr) | Just pr <- [partProcess p]]
    )

messageFlowElement :: MessageFlow -> Element
messageFlowElement m =
  leaf
    "bpmn:messageFlow"
    ( [("id", unFlowId (mfId m))]
        ++ [("name", n) | Just n <- [mfName m]]
        ++ [("sourceRef", refText (mfSource m)), ("targetRef", refText (mfTarget m))]
    )

-- Process ------------------------------------------------------------------------

processElement :: BpmnProcess -> Element
processElement p =
  elem_
    "bpmn:process"
    ( [("id", unProcessId (procId p))]
        ++ [("name", n) | Just n <- [procName p]]
        ++ [("isExecutable", if procExecutable p then "true" else "false")]
    )
    ( maybeToList (documentation <$> procDoc p)
        ++ laneSetElements p
        ++ scopeChildren (procScope p)
    )

documentation :: Text -> Element
documentation = textElem "bpmn:documentation" []

laneSetElements :: BpmnProcess -> [Element]
laneSetElements p
  | null (procLanes p) = []
  | otherwise =
      [ elem_
          "bpmn:laneSet"
          [("id", "LaneSet_" <> unProcessId (procId p))]
          [laneElement p l | l <- procLanes p]
      ]

laneElement :: BpmnProcess -> Lane -> Element
laneElement p l =
  elem_
    "bpmn:lane"
    ([("id", unLaneId (laneId l))] ++ [("name", n) | Just n <- [laneName l]])
    [ textElem "bpmn:flowNodeRef" [] (unNodeId (fnId n))
    | n <- scNodes (procScope p)
    , fnLane n == Just (laneId l)
    ]

-- | A scope's children, in the order the BPMN 2.0 schema requires.
--
-- @tProcess@ and @tSubProcess@ both sequence @flowElement*@ before
-- @artifact*@, and that distinction cuts across the source's notion of an
-- "artifact": a data object is a /flow element/, while a text annotation and an
-- association are artifacts. Emitting them in source order would interleave the
-- two groups and produce a document that a schema-validating reader rejects.
scopeChildren :: Scope -> [Element]
scopeChildren sc =
  map (nodeElement sc) (scNodes sc)
    ++ map flowElement (scFlows sc)
    ++ concatMap dataElements [a | a <- scArtifacts sc, artKind a /= AkTextAnnotation]
    ++ map annotationElement [a | a <- scArtifacts sc, artKind a == AkTextAnnotation]
    ++ map associationElement (annotationAssociations sc)

nodeElement :: Scope -> FlowNode -> Element
nodeElement sc n =
  elem_
    (tagFor (fnKind n))
    (identity (unNodeId (fnId n)) (fnName n) ++ kindAttrs sc n)
    -- @tActivity@ sequences documentation, extensionElements, incoming,
    -- outgoing, dataInputAssociation*, dataOutputAssociation*,
    -- loopCharacteristics?; @tSubProcess@ appends laneSet*, flowElement*,
    -- artifact* after that. @tCatchEvent@ and @tThrowEvent@ put
    -- eventDefinition* last. Following the schema here is what makes the
    -- output loadable by a validating reader and not merely by bpmn-js.
    ( maybeToList (documentation <$> fnDoc n)
        ++ maybeToList (extensionElements n)
        ++ flowRefs sc (fnId n)
        ++ dataAssociations sc (fnId n)
        ++ loopElements n
        ++ subprocessChildren (fnKind n)
        ++ eventDefinitions n
    )

identity :: Text -> Maybe Text -> [Attr]
identity i mn = ("id", i) : [("name", nm) | Just nm <- [mn]]

tagFor :: NodeKind -> Text
tagFor k = case k of
  NkGateway GwExclusive -> "bpmn:exclusiveGateway"
  NkGateway GwParallel -> "bpmn:parallelGateway"
  NkGateway GwInclusive -> "bpmn:inclusiveGateway"
  NkGateway GwEventBased -> "bpmn:eventBasedGateway"
  NkGateway GwComplex -> "bpmn:complexGateway"
  NkEvent (EventSpec fl _) -> case fl of
    EvStart -> "bpmn:startEvent"
    EvEnd -> "bpmn:endEvent"
    EvIntermediateCatch -> "bpmn:intermediateCatchEvent"
    EvIntermediateThrow -> "bpmn:intermediateThrowEvent"
    EvBoundary _ -> "bpmn:boundaryEvent"
  NkActivity a -> case acKind a of
    AkSubprocess _ -> "bpmn:subProcess"
    AkCallActivity -> "bpmn:callActivity"
    AkTask t -> case t of
      TtAbstract -> "bpmn:task"
      TtService -> "bpmn:serviceTask"
      TtUser -> "bpmn:userTask"
      TtManual -> "bpmn:manualTask"
      TtScript -> "bpmn:scriptTask"
      TtBusinessRule -> "bpmn:businessRuleTask"
      TtSend -> "bpmn:sendTask"
      TtReceive _ -> "bpmn:receiveTask"

kindAttrs :: Scope -> FlowNode -> [Attr]
kindAttrs sc n = case fnKind n of
  NkEvent (EventSpec (EvBoundary att) _) ->
    [("attachedToRef", unNodeId (baHost att))]
      ++ [("cancelActivity", "false") | not (baInterrupting att)]
  NkActivity (Activity (AkTask (TtReceive (Just m))) _) -> [("messageRef", unNodeId m)]
  NkGateway k
    | k `elem` [GwExclusive, GwInclusive, GwComplex]
    , Just d <- defaultFlowOf sc (fnId n) ->
        [("default", unFlowId d)]
  _ -> []

-- | Regenerate @incoming@ and @outgoing@ from the flow list. The source never
-- writes them, so they cannot drift out of step with the flows.
flowRefs :: Scope -> NodeId -> [Element]
flowRefs sc i =
  [textElem "bpmn:incoming" [] (unFlowId (sfId f)) | f <- scFlows sc, sfTarget f == i]
    ++ [textElem "bpmn:outgoing" [] (unFlowId (sfId f)) | f <- scFlows sc, sfSource f == i]

subprocessChildren :: NodeKind -> [Element]
subprocessChildren (NkActivity (Activity (AkSubprocess inner) _)) = scopeChildren inner
subprocessChildren _ = []

eventDefinitions :: FlowNode -> [Element]
eventDefinitions n = case fnKind n of
  NkEvent (EventSpec _ (Just d)) -> [eventDefinitionElement (unNodeId (fnId n)) d]
  _ -> []

eventDefinitionElement :: Text -> EventDefinition -> Element
eventDefinitionElement owner d = case d of
  EdMessage m -> leaf "bpmn:messageEventDefinition" [oid, ("messageRef", unNodeId m)]
  EdSignal s -> leaf "bpmn:signalEventDefinition" [oid, ("signalRef", unNodeId s)]
  EdError me -> leaf "bpmn:errorEventDefinition" (oid : [("errorRef", unNodeId e) | Just e <- [me]])
  EdEscalation me ->
    leaf "bpmn:escalationEventDefinition" (oid : [("escalationRef", unNodeId e) | Just e <- [me]])
  EdTerminate -> leaf "bpmn:terminateEventDefinition" [oid]
  EdCompensation -> leaf "bpmn:compensateEventDefinition" [oid]
  EdLink nm -> leaf "bpmn:linkEventDefinition" [oid, ("name", nm)]
  EdTimer t -> elem_ "bpmn:timerEventDefinition" [oid] [timerBody t]
  where
    oid = ("id", defId owner)

timerBody :: TimerDef -> Element
timerBody d = case d of
  TimerDuration v -> formal "bpmn:timeDuration" v
  TimerCycle v -> formal "bpmn:timeCycle" v
  TimerDate v -> formal "bpmn:timeDate" v
  where
    formal tag = textElem tag [("xsi:type", "bpmn:tFormalExpression")]

-- | @bpmn:multiInstanceLoopCharacteristics@ with its Zeebe extension. The
-- outer element is plain BPMN; only the input collection is Camunda-specific.
loopElements :: FlowNode -> [Element]
loopElements n = case fnKind n of
  NkActivity (Activity _ (Just ls)) ->
    [ elem_
        "bpmn:multiInstanceLoopCharacteristics"
        [("isSequential", if lsSequential ls then "true" else "false")]
        [ elem_
            "bpmn:extensionElements"
            []
            [ leaf
                "zeebe:loopCharacteristics"
                ( [ ("inputCollection", unFeel (lsInputCollection ls))
                  , ("inputElement", lsInputElement ls)
                  ]
                    ++ [("outputCollection", c) | Just c <- [lsOutputCollection ls]]
                    ++ [("outputElement", unFeel e) | Just e <- [lsOutputElement ls]]
                )
            ]
        ]
    ]
  _ -> []

-- Zeebe extension elements ---------------------------------------------------

extensionElements :: FlowNode -> Maybe Element
extensionElements n = case children of
  [] -> Nothing
  cs -> Just (elem_ "bpmn:extensionElements" [] cs)
  where
    children = case fnExec n of
      ExNone -> []
      ExService z ->
        leaf
          "zeebe:taskDefinition"
          (("type", ztType z) : [("retries", tshow r) | Just r <- [ztRetries z]])
          : ioMapping (ztInputs z) (ztOutputs z)
          ++ taskHeaders (ztHeaders z)
      ExUser uu ->
        leaf "zeebe:userTask" []
          : [leaf "zeebe:formDefinition" [("formId", f)] | Just f <- [utForm uu]]
          ++ [ leaf
                 "zeebe:assignmentDefinition"
                 ( [("assignee", unFeel a) | Just a <- [utAssignee uu]]
                     ++ [("candidateGroups", unFeel gr) | Just gr <- [utCandidateGroups uu]]
                     ++ [("candidateUsers", unFeel usr) | Just usr <- [utCandidateUsers uu]]
                 )
             | any (/= Nothing) [utAssignee uu, utCandidateGroups uu, utCandidateUsers uu]
             ]
          ++ [leaf "zeebe:taskSchedule" [("dueDate", unFeel dd)] | Just dd <- [utDueDate uu]]
          ++ ioMapping (utInputs uu) (utOutputs uu)
      ExScript s ->
        leaf "zeebe:script" [("expression", unFeel (scExpression s)), ("resultVariable", scResult s)]
          : ioMapping (scInputs s) (scOutputs s)
      ExDecision d ->
        leaf "zeebe:calledDecision" [("decisionId", dsDecisionId d), ("resultVariable", dsResult d)]
          : ioMapping (dsInputs d) (dsOutputs d)
      ExCall c ->
        leaf
          "zeebe:calledElement"
          [ ("processId", ceProcessId c)
          , ("propagateAllChildVariables", if cePropagateAllChildVariables c then "true" else "false")
          ]
          : ioMapping (ceInputs c) (ceOutputs c)

ioMapping :: [Mapping] -> [Mapping] -> [Element]
ioMapping [] [] = []
ioMapping ins outs =
  [ elem_
      "zeebe:ioMapping"
      []
      (map (mapEl "zeebe:input") ins ++ map (mapEl "zeebe:output") outs)
  ]
  where
    mapEl tag m = leaf tag [("source", unFeel (mapSource m)), ("target", mapTarget m)]

taskHeaders :: [Header] -> [Element]
taskHeaders [] = []
taskHeaders hs =
  [elem_ "zeebe:taskHeaders" [] [leaf "zeebe:header" [("key", hdrKey h), ("value", hdrValue h)] | h <- hs]]

-- Flows, artifacts and associations --------------------------------------------

flowElement :: SequenceFlow -> Element
flowElement f =
  elem_
    "bpmn:sequenceFlow"
    ( identity (unFlowId (sfId f)) (sfName f)
        ++ [("sourceRef", unNodeId (sfSource f)), ("targetRef", unNodeId (sfTarget f))]
    )
    [ textElem "bpmn:conditionExpression" [("xsi:type", "bpmn:tFormalExpression")] (unFeel e)
    | Just (FcExpression e) <- [sfCondition f]
    ]

-- | A text annotation: one element, and a BPMN @artifact@.
annotationElement :: Artifact -> Element
annotationElement a =
  elem_
    "bpmn:textAnnotation"
    [("id", unArtifactId (artId a))]
    [textElem "bpmn:text" [] (maybe "" id (artText a))]

-- | A data object becomes a reference plus the object it refers to. Both are
-- BPMN @flowElement@s, not artifacts, which is why they are emitted with the
-- sequence flows rather than after them.
dataElements :: Artifact -> [Element]
dataElements a = case artKind a of
  AkTextAnnotation -> []
  AkDataObject ->
    [ leaf
        "bpmn:dataObjectReference"
        ( [("id", unArtifactId (artId a))]
            ++ [("name", n) | Just n <- [artName a]]
            ++ [("dataObjectRef", dataObjectIdFor (unArtifactId (artId a)))]
        )
    , leaf "bpmn:dataObject" [("id", dataObjectIdFor (unArtifactId (artId a)))]
    ]
  AkDataStore ->
    [ leaf
        "bpmn:dataStoreReference"
        ([("id", unArtifactId (artId a))] ++ [("name", n) | Just n <- [artName a]])
    ]

-- | Data associations live inside the activity they belong to, which is where
-- BPMN puts them; text-annotation associations are process-level artifacts.
dataAssociations :: Scope -> NodeId -> [Element]
dataAssociations sc i =
  [ elem_
      "bpmn:dataInputAssociation"
      [("id", unFlowId (asId a))]
      [textElem "bpmn:sourceRef" [] (refText (asSource a))]
  | a <- scAssociations sc
  , asTarget a == RefNode i
  , isDataRef (asSource a)
  ]
    ++ [ elem_
           "bpmn:dataOutputAssociation"
           [("id", unFlowId (asId a))]
           [textElem "bpmn:targetRef" [] (refText (asTarget a))]
       | a <- scAssociations sc
       , asSource a == RefNode i
       , isDataRef (asTarget a)
       ]
  where
    dataArtifacts = [artId x | x <- scArtifacts sc, artKind x /= AkTextAnnotation]
    isDataRef (RefArtifact aid) = aid `elem` dataArtifacts
    isDataRef _ = False

-- | Only text-annotation associations are process-level artifacts. A data
-- object is connected by a @dataInputAssociation@ or @dataOutputAssociation@
-- inside the activity, which is where BPMN puts it; emitting both would
-- connect the same pair twice.
annotationAssociations :: Scope -> [Association]
annotationAssociations sc =
  [a | a <- scAssociations sc, touchesAnnotation a]
  where
    annotations = [artId x | x <- scArtifacts sc, artKind x == AkTextAnnotation]
    touchesAnnotation a = isAnn (asSource a) || isAnn (asTarget a)
    isAnn (RefArtifact aid) = aid `elem` annotations
    isAnn _ = False

associationElement :: Association -> Element
associationElement a =
  leaf
    "bpmn:association"
    [ ("id", unFlowId (asId a))
    , ("sourceRef", refText (asSource a))
    , ("targetRef", refText (asTarget a))
    ]

-- Diagram interchange ------------------------------------------------------------

-- | BPMN DI, emitted in a fixed order: pools, lanes, flow nodes, artifacts,
-- then edges. Shapes before edges is what every modeller writes and what makes
-- a hand-edited file and a generated one diff cleanly against each other.
diagramElement :: SemanticGraph -> Geometry -> Element
diagramElement g geo =
  elem_
    "bpmndi:BPMNDiagram"
    [("id", "BPMNDiagram_1")]
    [ elem_
        "bpmndi:BPMNPlane"
        [("id", "BPMNPlane_1"), ("bpmnElement", planeElement)]
        (poolShapes ++ laneShapes ++ nodeShapes ++ artifactShapes ++ edgeShapes)
    ]
  where
    planeElement = case sgCollaboration g of
      Just c -> colId c
      Nothing -> case sgProcesses g of
        (p : _) -> unProcessId (procId p)
        [] -> "Process_1"

    poolShapes =
      [ shape (unParticipantId pid) r [("isHorizontal", "true")]
      | (pid, r) <- Map.toAscList (geoPools geo)
      ]

    laneShapes =
      [ shape (unLaneId l) r [("isHorizontal", "true")]
      | (l, r) <- sortOn fst (Map.toList (geoLanes geo))
      ]

    -- Nodes in document order, scope by scope, so the DI order matches the
    -- semantic order and a diff shows an insertion rather than a shuffle.
    orderedNodes =
      [ n
      | p <- sgProcesses g
      , sc <- allScopes (procScope p)
      , n <- scNodes sc
      ]

    nodeShapes =
      [ shape (unNodeId (fnId n)) r (markerAttrs n) `withLabel` Map.lookup (LkNode (fnId n)) (geoLabels geo)
      | n <- orderedNodes
      , Just r <- [Map.lookup (fnId n) (geoShapes geo)]
      ]

    artifactShapes =
      [ shape (unArtifactId aid) r []
      | (aid, r) <- Map.toAscList (geoArtifacts geo)
      ]

    orderedFlows =
      [ sfId f
      | p <- sgProcesses g
      , sc <- allScopes (procScope p)
      , f <- scFlows sc
      ]
        ++ [asId a | p <- sgProcesses g, sc <- allScopes (procScope p), a <- scAssociations sc]
        ++ maybe [] (map mfId . colMessageFlows) (sgCollaboration g)

    edgeShapes =
      [ edge (unFlowId fid) r `withEdgeLabel` Map.lookup (LkFlow fid) (geoLabels geo)
      | fid <- orderedFlows
      , Just r <- [Map.lookup fid (geoRoutes geo)]
      ]

    markerAttrs n = case fnKind n of
      NkGateway GwExclusive -> [("isMarkerVisible", "true")]
      NkActivity (Activity (AkSubprocess _) _) -> [("isExpanded", "true")]
      _ -> []

    shape i r extra =
      elem_
        "bpmndi:BPMNShape"
        ([("id", diId i), ("bpmnElement", i)] ++ extra)
        [bounds r]

    edge i r =
      elem_
        "bpmndi:BPMNEdge"
        [("id", diId i), ("bpmnElement", i)]
        [leaf "di:waypoint" [("x", tshow (ptX p)), ("y", tshow (ptY p))] | p <- rtPoints r]

    -- LABEL-011: an external label has a rectangle in RG, so it gets a
    -- @BPMNLabel@ in DI. A modeller that re-lays out the file then starts from
    -- the position the engine chose rather than from its own guess.
    withLabel el Nothing = el
    withLabel el (Just lb) = el {elChildren = elChildren el ++ [CElem (labelElement (lbRect lb))]}
    withEdgeLabel = withLabel

    labelElement r = elem_ "bpmndi:BPMNLabel" [] [bounds r]

    bounds r =
      leaf
        "dc:Bounds"
        [("x", tshow (rX r)), ("y", tshow (rY r)), ("width", tshow (rW r)), ("height", tshow (rH r))]

tshow :: Show a => a -> Text
tshow = T.pack . show
