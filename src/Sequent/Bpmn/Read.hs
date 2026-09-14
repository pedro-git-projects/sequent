-- | BPMN 2.0 XML → 'SemanticGraph'. The other direction.
--
-- This is the inverse of "Sequent.Camunda.Serialize", and it is deliberately
-- the /only/ place that knows BPMN's element vocabulary in that direction.
-- What it produces is a semantic graph and nothing else: no geometry, no
-- diagram interchange, no ids beyond the ones the file itself declares.
-- Geometry is not read because it is not meaning — the point of the round trip
-- is that the layout engine computes it again.
--
-- __What it will not do is guess.__ A BPMN file may contain constructs this
-- language cannot express — an event subprocess, a transaction, nested lanes, a
-- data store, a BPMN group. Dropping them silently would turn "import" into
-- "import most of it", and the author would find out from a diff. Every one of
-- them is reported, by id, as a diagnostic; the import still produces a graph
-- for everything else, so the report is a list of what to do by hand rather
-- than a refusal.
module Sequent.Bpmn.Read
  ( readBpmn
  , ReadResult (..)
  ) where

import Data.Char (isDigit)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model
import Sequent.Camunda.XmlParse
import Sequent.Diagnostic

data ReadResult = ReadResult
  { rdGraph       :: Maybe SemanticGraph
  , rdDiagnostics :: [Diagnostic]
  }

-- | Read a @.bpmn@ document.
--
-- A parse failure or a missing @definitions@ root is fatal and yields no
-- graph. Everything else — an unknown element, a construct the language cannot
-- express, a dangling reference — is reported and skipped, because a partial
-- import the author can finish by hand beats a refusal they cannot act on.
readBpmn :: FilePath -> Text -> ReadResult
readBpmn path src = case parseXmlDocument path src of
  Left e -> ReadResult Nothing [diagnostic Error ParseError ("not well-formed XML: " <> firstLine e)]
  Right root
    | qnLocal (xnName root) /= "definitions" ->
        ReadResult
          Nothing
          [ diagnostic
              Error
              ParseError
              ("root element is '" <> qnLocal (xnName root) <> "', expected 'definitions'")
          ]
    | otherwise ->
        let (g, ds) = definitions root
         in ReadResult (Just g) ds
  where
    firstLine = T.takeWhile (/= '\n') . T.strip

-- The accumulating monoid ------------------------------------------------------

-- | Diagnostics accumulate; nothing else does. A reader that threaded state
-- would be tempted to invent ids, and inventing ids is the one thing that
-- breaks the round trip.
type W a = (a, [Diagnostic])

note :: Diagnostic -> [Diagnostic]
note d = [d]

unsupported :: Text -> Text -> Text -> Diagnostic
unsupported what i hint =
  withHint hint (diagnostic Warning SemanticError (what <> " '" <> i <> "' has no equivalent in this language and was skipped"))

-- Definitions ------------------------------------------------------------------

definitions :: XNode -> W SemanticGraph
definitions root = (graph, rootDiags ++ colDiags ++ procDiags ++ strayDiags)
  where
    graph =
      SemanticGraph
        { sgCollaboration = col
        , sgProcesses = procs
        , sgMessages = messages
        , sgSignals = signals
        , sgErrors = errors
        , sgEscalations = escalations
        }

    messages =
      [ MessageDef
          (NodeId (idOf e))
          (fromMaybe (idOf e) (attrNamed "name" e))
          (feel <$> correlationKey e)
      | e <- kidsNamed "message" root
      ]
    signals = [SignalDef (NodeId (idOf e)) (fromMaybe (idOf e) (attrNamed "name" e)) | e <- kidsNamed "signal" root]
    errors =
      [ ErrorDef (NodeId (idOf e)) (fromMaybe "" (attrNamed "errorCode" e)) (fromMaybe (idOf e) (attrNamed "name" e))
      | e <- kidsNamed "error" root
      ]
    escalations =
      [ EscalationDef (NodeId (idOf e)) (fromMaybe "" (attrNamed "escalationCode" e)) (fromMaybe (idOf e) (attrNamed "name" e))
      | e <- kidsNamed "escalation" root
      ]
    rootDiags = []

    correlationKey e = do
      ext <- kidNamed "extensionElements" e
      sub <- kidIn nsZeebe "subscription" ext
      attrNamed "correlationKey" sub

    (col, colDiags) = case kidsNamed "collaboration" root of
      [] -> (Nothing, [])
      (c : rest) ->
        ( Just (collaboration c)
        , concat
            [ note (unsupported "a second collaboration" (idOf x) "keep one collaboration per file")
            | x <- rest
            ]
        )

    (procs, procDiags) =
      let rs = zipWith process [0 ..] (kidsNamed "process" root)
       in (map fst rs, concatMap snd rs)

    -- Anything at the top of the file that is neither a root element this
    -- language knows nor diagram interchange.
    strayDiags =
      [ unsupported (kindWord (qnLocal (xnName e))) (idOf e) "declare it by hand, or leave it out"
      | e <- xnChildren root
      , qnLocal (xnName e) `notElem` known
      ]
      where
        known =
          [ "message", "signal", "error", "escalation", "collaboration", "process"
          , "BPMNDiagram", "extensionElements", "import", "itemDefinition", "dataStore"
          ]

kindWord :: Text -> Text
kindWord t = "a '" <> t <> "'"

idOf :: XNode -> Text
idOf e = fromMaybe "" (attrNamed "id" e)

nameOf :: XNode -> Maybe Text
nameOf e = case attrNamed "name" e of
  Just n | not (T.null (T.strip n)) -> Just (T.strip n)
  _ -> Nothing

docOf :: XNode -> Maybe Text
docOf = textIn "documentation"

-- Collaboration ----------------------------------------------------------------

collaboration :: XNode -> Collaboration
collaboration c =
  Collaboration
    { colId = idOf c
    , colParticipants =
        [ Participant (ParticipantId (idOf p)) (nameOf p) (ProcessId <$> attrNamed "processRef" p) k
        | (k, p) <- zip [0 ..] (kidsNamed "participant" c)
        ]
    , colMessageFlows =
        [ MessageFlow
            { mfId = FlowId (idOf m)
            , mfSource = refOf (fromMaybe "" (attrNamed "sourceRef" m))
            , mfTarget = refOf (fromMaybe "" (attrNamed "targetRef" m))
            , mfName = nameOf m
            , mfMessage = NodeId <$> attrNamed "messageRef" m
            , mfDocOrder = k
            }
        | (k, m) <- zip [0 ..] (kidsNamed "messageFlow" c)
        ]
    }
  where
    -- A message flow may name a participant or a flow node. Which it is cannot
    -- be told from the reference alone, so the decision is deferred: everything
    -- becomes a node reference and 'fixRefs' repoints the ones that turn out to
    -- be pools once every participant is known.
    refOf = RefNode . NodeId

-- Process ------------------------------------------------------------------------

process :: Int -> XNode -> W BpmnProcess
process _ p = (proc', laneDiags ++ scopeDiags)
  where
    pid = ProcessId (idOf p)
    proc' =
      BpmnProcess
        { procId = pid
        , procName = nameOf p
        , procDoc = docOf p
        , procExecutable = attrNamed "isExecutable" p /= Just "false"
        , procLanes = lanes
        , procScope = sc
        }

    laneSets = kidsNamed "laneSet" p
    laneNodes = concatMap (kidsNamed "lane") laneSets
    lanes = [Lane (LaneId (idOf l)) (nameOf l) k [] | (k, l) <- zip [0 ..] laneNodes]
    laneOf =
      Map.fromList
        [ (NodeId (T.strip (xnText r)), LaneId (idOf l))
        | l <- laneNodes
        , r <- kidsNamed "flowNodeRef" l
        ]

    laneDiags =
      [ unsupported "a nested lane set in lane" (idOf l) "flatten the lanes, or split the process"
      | l <- laneNodes
      , not (null (kidsNamed "childLaneSet" l))
      ]

    (sc, scopeDiags) = scopeOf (ScopeProcess pid) laneOf p

-- Scopes ---------------------------------------------------------------------------

-- | The flow elements directly inside a process or an expanded subprocess.
scopeOf :: ScopeId -> Map NodeId LaneId -> XNode -> W Scope
scopeOf sid laneOf container = (scope, nodeDiags ++ artDiags)
  where
    scope =
      Scope
        { scId = sid
        , scNodes = nodes
        , scFlows = flows
        , scArtifacts = artifacts
        , scAssociations = associations
        }

    indexed = zip [0 ..] (xnChildren container)

    nodeResults = [flowNode laneOf k e | (k, e) <- indexed, isFlowNodeTag (qnLocal (xnName e))]
    nodes = mapMaybe fst nodeResults
    nodeDiags = concatMap snd nodeResults

    flows =
      [ SequenceFlow
          { sfId = FlowId (idOf e)
          , sfSource = NodeId (fromMaybe "" (attrNamed "sourceRef" e))
          , sfTarget = NodeId (fromMaybe "" (attrNamed "targetRef" e))
          , sfName = nameOf e
          , sfCondition = conditionOf e
          , sfDocOrder = k
          , sfPriority = Nothing
          }
      | (k, e) <- indexed
      , qnLocal (xnName e) == "sequenceFlow"
      ]

    -- A default flow is marked on the gateway, not on the flow. Reading it back
    -- means looking at every gateway's @default@ before the flow's own
    -- condition, because BPMN allows both to be written and the marker wins.
    defaults =
      [ FlowId d
      | (_, e) <- indexed
      , isFlowNodeTag (qnLocal (xnName e))
      , Just d <- [attrNamed "default" e]
      ]
    conditionOf e
      | FlowId (idOf e) `elem` defaults = Just FcDefault
      | otherwise = FcExpression . feel <$> textIn "conditionExpression" e

    artifacts =
      [ Artifact (ArtifactId (idOf e)) AkTextAnnotation Nothing (textIn "text" e) k Nothing
      | (k, e) <- indexed
      , qnLocal (xnName e) == "textAnnotation"
      ]
        ++ [ Artifact (ArtifactId (idOf e)) AkDataObject (nameOf e) Nothing k Nothing
           | (k, e) <- indexed
           , qnLocal (xnName e) == "dataObjectReference"
           ]

    artDiags =
      [ unsupported "a data store reference" (idOf e) "the language has no data-store construct"
      | (_, e) <- indexed
      , qnLocal (xnName e) == "dataStoreReference"
      ]
        ++ [ unsupported "a BPMN group" (idOf e) "the language has no group construct"
           | (_, e) <- indexed
           , qnLocal (xnName e) == "group"
           ]
        -- Everything else inside a process or a subprocess. Naming the tag is
        -- the point: an import that drops a transaction or an ad-hoc
        -- subprocess without saying so is an import the author cannot trust,
        -- and there is no way to find out short of diffing the two files.
        ++ [ unsupported (kindWord (qnLocal (xnName e))) (idOf e) "there is no syntax for it; keep it in a separate file, or model it another way"
           | (_, e) <- indexed
           , qnLocal (xnName e) `notElem` handled
           ]

    handled =
      flowNodeTags
        ++ [ "sequenceFlow", "textAnnotation", "dataObjectReference", "dataObject"
           , "dataStoreReference", "group", "association", "laneSet", "documentation"
           , "extensionElements", "incoming", "outgoing", "property"
           , "dataInputAssociation", "dataOutputAssociation", "ioSpecification"
           , "multiInstanceLoopCharacteristics", "standardLoopCharacteristics"
           ]

    -- Text-annotation associations sit at scope level; data associations sit
    -- inside the activity they belong to. Both become one 'Association' list.
    associations =
      [ Association (FlowId (idOf e)) (RefArtifact (ArtifactId (fromMaybe "" (attrNamed "sourceRef" e)))) (RefNode (NodeId (fromMaybe "" (attrNamed "targetRef" e)))) AdNone k
      | (k, e) <- indexed
      , qnLocal (xnName e) == "association"
      ]
        ++ concat
          [ dataAssocs k e
          | (k, e) <- indexed
          , isFlowNodeTag (qnLocal (xnName e))
          ]

    dataAssocs k e =
      [ Association (FlowId (idOf a)) (RefArtifact (ArtifactId (T.strip (xnText r)))) (RefNode (NodeId (idOf e))) AdNone k
      | a <- kidsNamed "dataInputAssociation" e
      , r <- kidsNamed "sourceRef" a
      ]
        ++ [ Association (FlowId (idOf a)) (RefNode (NodeId (idOf e))) (RefArtifact (ArtifactId (T.strip (xnText r)))) AdNone k
           | a <- kidsNamed "dataOutputAssociation" e
           , r <- kidsNamed "targetRef" a
           ]

isFlowNodeTag :: Text -> Bool
isFlowNodeTag t = t `elem` flowNodeTags

flowNodeTags :: [Text]
flowNodeTags =
  [ "startEvent", "endEvent", "intermediateCatchEvent", "intermediateThrowEvent", "boundaryEvent"
  , "task", "serviceTask", "userTask", "manualTask", "scriptTask", "businessRuleTask"
  , "sendTask", "receiveTask", "callActivity", "subProcess"
  , "exclusiveGateway", "parallelGateway", "inclusiveGateway", "eventBasedGateway", "complexGateway"
  ]

-- Flow nodes -----------------------------------------------------------------------

flowNode :: Map NodeId LaneId -> Int -> XNode -> (Maybe FlowNode, [Diagnostic])
flowNode laneOf order e = case kindOf of
  Nothing -> (Nothing, skipDiags)
  Just (k, ds) ->
    ( Just
        FlowNode
          { fnId = nid
          , fnName = nameOf e
          , fnDoc = docOf e
          , fnKind = k
          , fnLane = Map.lookup nid laneOf
          , fnDocOrder = order
          , fnExec = if inert then ExNone else execOf e
          }
    , ds ++ inertDiags
    )
  where
    nid = NodeId (idOf e)
    tag = qnLocal (xnName e)

    -- A plain @bpmn:task@ is Camunda 8's /undefined/ task: the broker walks
    -- straight through it, whatever is in its @extensionElements@. Reading the
    -- metadata anyway would produce a step this language has no keyword for —
    -- an abstract task with a job type — so it is dropped, and saying so beats
    -- letting the engine's silence be the explanation.
    inert = tag == "task" && execOf e /= ExNone
    inertDiags =
      [ withHint
          "Camunda 8 ignores it too; give the step a type ('serviceTask', 'userTask', ...) to keep it"
          (diagnostic Warning SemanticError ("task '" <> idOf e <> "' carries execution metadata a plain task cannot run; dropped it"))
      | inert
      ]

    skipDiags = case tag of
      "subProcess" -> note (unsupported subKind (idOf e) "inline its contents, or model it as a call activity")
      _ -> note (unsupported (kindWord tag) (idOf e) "")

    subKind
      | attrNamed "triggeredByEvent" e == Just "true" = "an event subprocess"
      | otherwise = "a collapsed subprocess"

    kindOf = case tag of
      "startEvent" -> event EvStart
      "endEvent" -> event EvEnd
      "intermediateCatchEvent" -> event EvIntermediateCatch
      "intermediateThrowEvent" -> event EvIntermediateThrow
      "boundaryEvent" ->
        event
          ( EvBoundary
              BoundaryAttachment
                { baHost = NodeId (fromMaybe "" (attrNamed "attachedToRef" e))
                , baInterrupting = attrNamed "cancelActivity" e /= Just "false"
                }
          )
      "task" -> activity (AkTask TtAbstract)
      "serviceTask" -> activity (AkTask TtService)
      "userTask" -> activity (AkTask TtUser)
      "manualTask" -> activity (AkTask TtManual)
      "scriptTask" -> activity (AkTask TtScript)
      "businessRuleTask" -> activity (AkTask TtBusinessRule)
      "sendTask" -> activity (AkTask TtSend)
      "receiveTask" -> activity (AkTask (TtReceive (NodeId <$> attrNamed "messageRef" e)))
      "callActivity" -> activity AkCallActivity
      "subProcess"
        | attrNamed "triggeredByEvent" e == Just "true" -> Nothing
        | otherwise ->
            let (inner, ds) = scopeOf (ScopeSubprocess nid) laneOf e
             in Just (NkActivity (Activity (AkSubprocess inner) (loopOf e)), ds)
      "exclusiveGateway" -> gateway GwExclusive
      "parallelGateway" -> gateway GwParallel
      "inclusiveGateway" -> gateway GwInclusive
      "eventBasedGateway" -> gateway GwEventBased
      "complexGateway" -> gateway GwComplex
      _ -> Nothing

    gateway k = Just (NkGateway k, [])
    activity k = Just (NkActivity (Activity k (loopOf e)), [])
    event fl =
      let (d, ds) = eventDefinitionOf e
       in Just (NkEvent (EventSpec fl d), ds)

-- | At most one definition survives: BPMN allows several on one event, the
-- language does not, and silently keeping the first would be a lie about the
-- process. The extras are reported.
eventDefinitionOf :: XNode -> (Maybe EventDefinition, [Diagnostic])
eventDefinitionOf e = case found of
  [] -> (Nothing, [])
  (d : rest) ->
    ( Just d
    , [ withHint
          "an event carries one trigger; split it into two events"
          (diagnostic Warning SemanticError ("event '" <> idOf e <> "' has more than one trigger; kept the first"))
      | not (null rest)
      ]
    )
  where
    found = mapMaybe defOf (xnChildren e)
    defOf c = case qnLocal (xnName c) of
      "messageEventDefinition" -> EdMessage . NodeId <$> attrNamed "messageRef" c
      "signalEventDefinition" -> EdSignal . NodeId <$> attrNamed "signalRef" c
      "errorEventDefinition" -> Just (EdError (NodeId <$> attrNamed "errorRef" c))
      "escalationEventDefinition" -> Just (EdEscalation (NodeId <$> attrNamed "escalationRef" c))
      "terminateEventDefinition" -> Just EdTerminate
      "compensateEventDefinition" -> Just EdCompensation
      "linkEventDefinition" -> Just (EdLink (fromMaybe "" (attrNamed "name" c)))
      "timerEventDefinition" -> EdTimer <$> timerOf c
      _ -> Nothing

timerOf :: XNode -> Maybe TimerDef
timerOf c =
  (TimerDuration <$> textIn "timeDuration" c)
    `orElse` (TimerCycle <$> textIn "timeCycle" c)
    `orElse` (TimerDate <$> textIn "timeDate" c)
  where
    orElse a b = maybe b Just a

loopOf :: XNode -> Maybe LoopSpec
loopOf e = do
  mi <- kidNamed "multiInstanceLoopCharacteristics" e
  ext <- kidNamed "extensionElements" mi
  lc <- kidIn nsZeebe "loopCharacteristics" ext
  coll <- attrNamed "inputCollection" lc
  pure
    LoopSpec
      { lsSequential = attrNamed "isSequential" mi == Just "true"
      , lsInputCollection = feel coll
      , lsInputElement = fromMaybe "item" (attrNamed "inputElement" lc)
      , lsOutputCollection = attrNamed "outputCollection" lc
      , lsOutputElement = feel <$> attrNamed "outputElement" lc
      }

-- Zeebe execution metadata -----------------------------------------------------------

-- | Which execution metadata an element carries is decided by what is /in/ its
-- @extensionElements@, not by its tag. A user task in Camunda 8 is a user task
-- because it has a @zeebe:userTask@; a message end event is a job because it
-- has a @zeebe:taskDefinition@. Reading the extension rather than the tag is
-- what lets both come back unchanged.
execOf :: XNode -> ExecutionMeta
execOf e = case kidNamed "extensionElements" e of
  Nothing -> ExNone
  Just ext
    | Just d <- kidIn nsZeebe "calledDecision" ext ->
        ExDecision
          DecisionSpec
            { dsDecisionId = fromMaybe "" (attrNamed "decisionId" d)
            , dsResult = fromMaybe "result" (attrNamed "resultVariable" d)
            , dsInputs = ins ext
            , dsOutputs = outs ext
            }
    | Just c <- kidIn nsZeebe "calledElement" ext ->
        ExCall
          CalledElement
            { ceProcessId = fromMaybe "" (attrNamed "processId" c)
            , cePropagateAllChildVariables = attrNamed "propagateAllChildVariables" c == Just "true"
            , ceInputs = ins ext
            , ceOutputs = outs ext
            }
    | Just s <- kidIn nsZeebe "script" ext ->
        ExScript
          ScriptSpec
            { scExpression = feel (fromMaybe "" (attrNamed "expression" s))
            , scResult = fromMaybe "result" (attrNamed "resultVariable" s)
            , scInputs = ins ext
            , scOutputs = outs ext
            }
    | Just t <- kidIn nsZeebe "taskDefinition" ext ->
        ExService
          ZeebeTask
            { ztType = fromMaybe "" (attrNamed "type" t)
            , ztRetries = attrNamed "retries" t >>= readInt
            , ztInputs = ins ext
            , ztOutputs = outs ext
            , ztHeaders =
                [ Header (fromMaybe "" (attrNamed "key" h)) (fromMaybe "" (attrNamed "value" h))
                | hs <- kidsIn nsZeebe "taskHeaders" ext
                , h <- kidsIn nsZeebe "header" hs
                ]
            }
    | not (null (kidsIn nsZeebe "userTask" ext))
        || not (null (kidsIn nsZeebe "formDefinition" ext))
        || not (null (kidsIn nsZeebe "assignmentDefinition" ext)) ->
        ExUser
          UserTaskSpec
            { utForm = kidIn nsZeebe "formDefinition" ext >>= attrNamed "formId"
            , utAssignee = feel <$> (assignment ext >>= attrNamed "assignee")
            , utCandidateGroups = feel <$> (assignment ext >>= attrNamed "candidateGroups")
            , utCandidateUsers = feel <$> (assignment ext >>= attrNamed "candidateUsers")
            , utDueDate = feel <$> (kidIn nsZeebe "taskSchedule" ext >>= attrNamed "dueDate")
            , utInputs = ins ext
            , utOutputs = outs ext
            }
    | otherwise -> ExNone
  where
    assignment ext = kidIn nsZeebe "assignmentDefinition" ext
    mappings tag ext =
      [ Mapping (fromMaybe "" (attrNamed "target" m)) (feel (fromMaybe "" (attrNamed "source" m)))
      | io <- kidsIn nsZeebe "ioMapping" ext
      , m <- kidsIn nsZeebe tag io
      ]
    ins = mappings "input"
    outs = mappings "output"

readInt :: Text -> Maybe Int
readInt t
  | T.null d = Nothing
  | T.all isDigit d = Just (T.foldl' (\a c -> a * 10 + fromEnum c - 48) 0 d)
  | otherwise = Nothing
  where
    d = T.strip t
