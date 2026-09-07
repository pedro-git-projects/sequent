-- | The semantic BPMN graph (@SG@) — SPEC §0.
--
-- This is BPMN /meaning/: elements, flows, containment, conditions, boundary
-- attachment. It contains no @x@, no @y@, no waypoint and no XML. The layout
-- engine reads it and never modifies it; the serialiser reads it alongside the
-- rendered geometry. Storing a coordinate here "because serialisation needs it
-- eventually" is the specific mistake §0 exists to prevent.
--
-- Two structural decisions carry weight:
--
--   * __Ordered lists, never hash containers.__ Every collection is a list in
--     document order, and every derived map is a "Data.Map.Strict" keyed by an
--     'Ord' id. Nothing observable may depend on hash iteration order
--     (LAYOUT-027).
--   * __Scopes nest, names do not.__ A process and each expanded subprocess is
--     a 'Scope' with its own flow nodes and sequence flows, which is what makes
--     the recursive formatter of LAYOUT-019 possible. Symbolic names, however,
--     are unique across a whole process, so ids stay short and stable.
module Sequent.Bpmn.Semantic
  ( -- * Identifiers
    NodeId (..)
  , FlowId (..)
  , ProcessId (..)
  , ParticipantId (..)
  , LaneId (..)
  , ArtifactId (..)
  , ScopeId (..)
  , ElementRef (..)
  , refText
    -- * The graph
  , SemanticGraph (..)
  , Collaboration (..)
  , Participant (..)
  , BpmnProcess (..)
  , Scope (..)
  , emptyScope
    -- * Flow nodes
  , FlowNode (..)
  , NodeKind (..)
  , EventSpec (..)
  , EventFlavour (..)
  , EventDefinition (..)
  , TimerDef (..)
  , Activity (..)
  , ActivityKind (..)
  , TaskType (..)
  , GatewayKind (..)
  , BoundaryAttachment (..)
    -- * Connections
  , SequenceFlow (..)
  , FlowCondition (..)
  , MessageFlow (..)
  , Association (..)
  , AssociationDirection (..)
    -- * Containers and artifacts
  , Lane (..)
  , Artifact (..)
  , ArtifactKind (..)
    -- * Root elements
  , MessageDef (..)
  , SignalDef (..)
  , ErrorDef (..)
  , EscalationDef (..)
    -- * Provenance
  , Provenance (..)
  , emptyProvenance
  , spanOfNode
  , spanOfFlow
    -- * Queries
  , scopeNodeMap
  , scopeFlowMap
  , allScopes
  , childScopes
  , nodeIsGateway
  , nodeIsEvent
  , nodeIsActivity
  , nodeIsBoundary
  , boundaryHost
  , isStartEvent
  , isEndEvent
  , isTerminating
  , gatewayKindOf
  , outgoingOf
  , incomingOf
  , defaultFlowOf
  , nodeSizeHint
  , canonicalise
  ) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Sequent.Camunda.Model (ExecutionMeta, FeelExpr, LoopSpec)
import Sequent.Diagnostic (Span)

-- Identifiers ---------------------------------------------------------------

-- | A flow node: activity, event or gateway.
newtype NodeId = NodeId {unNodeId :: Text}
  deriving (Eq, Ord, Show)

-- | A sequence flow, message flow or association.
newtype FlowId = FlowId {unFlowId :: Text}
  deriving (Eq, Ord, Show)

newtype ProcessId = ProcessId {unProcessId :: Text}
  deriving (Eq, Ord, Show)

newtype ParticipantId = ParticipantId {unParticipantId :: Text}
  deriving (Eq, Ord, Show)

newtype LaneId = LaneId {unLaneId :: Text}
  deriving (Eq, Ord, Show)

newtype ArtifactId = ArtifactId {unArtifactId :: Text}
  deriving (Eq, Ord, Show)

-- | The identity of a layout scope: a process, or an expanded subprocess.
data ScopeId
  = ScopeProcess ProcessId
  | ScopeSubprocess NodeId
  deriving (Eq, Ord, Show)

-- | Anything the geometry can be attached to. Keeps the rendered-geometry maps
-- from needing one key type per element class.
data ElementRef
  = RefNode NodeId
  | RefFlow FlowId
  | RefLane LaneId
  | RefParticipant ParticipantId
  | RefArtifact ArtifactId
  deriving (Eq, Ord, Show)

refText :: ElementRef -> Text
refText r = case r of
  RefNode i -> unNodeId i
  RefFlow i -> unFlowId i
  RefLane i -> unLaneId i
  RefParticipant i -> unParticipantId i
  RefArtifact i -> unArtifactId i

-- The graph -----------------------------------------------------------------

-- | A whole compilation unit.
data SemanticGraph = SemanticGraph
  { sgCollaboration :: Maybe Collaboration
  -- ^ Present exactly when the source declared pools.
  , sgProcesses     :: [BpmnProcess]
  , sgMessages      :: [MessageDef]
  , sgSignals       :: [SignalDef]
  , sgErrors        :: [ErrorDef]
  , sgEscalations   :: [EscalationDef]
  }
  deriving (Eq, Show)

data Collaboration = Collaboration
  { colId           :: Text
  , colParticipants :: [Participant]
  , colMessageFlows :: [MessageFlow]
  }
  deriving (Eq, Show)

-- | A pool. A participant with no process is a black box (LANE-014).
data Participant = Participant
  { partId      :: ParticipantId
  , partName    :: Maybe Text
  , partProcess :: Maybe ProcessId
  , partOrder   :: Int
  }
  deriving (Eq, Show)

data BpmnProcess = BpmnProcess
  { procId       :: ProcessId
  , procName     :: Maybe Text
  , procDoc      :: Maybe Text
  , procExecutable :: Bool
  , procLanes    :: [Lane]
  , procScope    :: Scope
  }
  deriving (Eq, Show)

-- | One layout scope: the flow elements directly inside a process or an
-- expanded subprocess.
data Scope = Scope
  { scId        :: ScopeId
  , scNodes     :: [FlowNode]
  -- ^ Document order. Boundary events are included here, and are flow nodes
  -- like any other; layering contracts them into their host (LAYOUT-016).
  , scFlows     :: [SequenceFlow]
  , scArtifacts :: [Artifact]
  , scAssociations :: [Association]
  }
  deriving (Eq, Show)

emptyScope :: ScopeId -> Scope
emptyScope i = Scope i [] [] [] []

-- Flow nodes ----------------------------------------------------------------

data FlowNode = FlowNode
  { fnId       :: NodeId
  , fnName     :: Maybe Text
  -- ^ Presentation text. Never identity — see "Sequent.Bpmn.Id".
  , fnDoc      :: Maybe Text
  , fnKind     :: NodeKind
  , fnLane     :: Maybe LaneId
  , fnDocOrder :: !Int
  -- ^ Position in the source document. Half of the canonical ordering key
  -- @(documentOrder, id)@ that every deterministic tie-break ends in.
  , fnExec     :: ExecutionMeta
  -- ^ Camunda metadata, opaque to everything but the Camunda backend.
  }
  deriving (Eq, Show)

data NodeKind
  = NkEvent EventSpec
  | NkActivity Activity
  | NkGateway GatewayKind
  deriving (Eq, Show)

data EventSpec = EventSpec
  { evFlavour    :: EventFlavour
  , evDefinition :: Maybe EventDefinition
  }
  deriving (Eq, Show)

data EventFlavour
  = EvStart
  | EvEnd
  | EvIntermediateCatch
  | EvIntermediateThrow
  | EvBoundary BoundaryAttachment
  deriving (Eq, Show)

-- | Which activity a boundary event hangs on, and whether it interrupts it.
data BoundaryAttachment = BoundaryAttachment
  { baHost        :: NodeId
  , baInterrupting :: Bool
  }
  deriving (Eq, Show)

data EventDefinition
  = EdMessage NodeId
  -- ^ Reference to a 'MessageDef' by its allocated id.
  | EdSignal NodeId
  | EdError (Maybe NodeId)
  | EdEscalation (Maybe NodeId)
  | EdTimer TimerDef
  | EdTerminate
  | EdLink Text
  | EdCompensation
  deriving (Eq, Show)

data TimerDef
  = TimerDuration Text
  | TimerCycle Text
  | TimerDate Text
  deriving (Eq, Show)

data Activity = Activity
  { acKind  :: ActivityKind
  , acLoop  :: Maybe LoopSpec
  }
  deriving (Eq, Show)

data ActivityKind
  = AkTask TaskType
  | AkSubprocess Scope
  -- ^ An expanded subprocess. Its scope is laid out by a recursive invocation
  -- of the whole formatter (LAYOUT-019).
  | AkCallActivity
  deriving (Eq, Show)

data TaskType
  = TtAbstract
  | TtService
  | TtUser
  | TtManual
  | TtScript
  | TtBusinessRule
  | TtSend
  | TtReceive (Maybe NodeId)
  -- ^ Reference to the message the task waits for.
  deriving (Eq, Show)

data GatewayKind
  = GwExclusive
  | GwParallel
  | GwInclusive
  | GwEventBased
  | GwComplex
  deriving (Eq, Ord, Show)

-- Connections ---------------------------------------------------------------

data SequenceFlow = SequenceFlow
  { sfId        :: FlowId
  , sfSource    :: NodeId
  , sfTarget    :: NodeId
  , sfName      :: Maybe Text
  , sfCondition :: Maybe FlowCondition
  , sfDocOrder  :: !Int
  , sfPriority  :: Maybe Int
  -- ^ Explicit branch priority; feeds key component 1 of BRANCH-007.
  }
  deriving (Eq, Show)

-- | A conditional flow carries an expression; a default flow carries the
-- gateway's @default@ marker instead. Making these one type keeps "a flow is
-- conditional or default, never both" unrepresentable.
data FlowCondition
  = FcExpression FeelExpr
  | FcDefault
  deriving (Eq, Show)

data MessageFlow = MessageFlow
  { mfId      :: FlowId
  , mfSource  :: ElementRef
  , mfTarget  :: ElementRef
  , mfName    :: Maybe Text
  , mfMessage :: Maybe NodeId
  , mfDocOrder :: !Int
  }
  deriving (Eq, Show)

data Association = Association
  { asId        :: FlowId
  , asSource    :: ElementRef
  , asTarget    :: ElementRef
  , asDirection :: AssociationDirection
  , asDocOrder  :: !Int
  }
  deriving (Eq, Show)

data AssociationDirection = AdNone | AdOne | AdBoth
  deriving (Eq, Show)

-- Containers and artifacts --------------------------------------------------

data Lane = Lane
  { laneId       :: LaneId
  , laneName     :: Maybe Text
  , laneOrder    :: !Int
  , laneChildren :: [LaneId]
  -- ^ Nested lanes (LANE-011), in order.
  }
  deriving (Eq, Show)

data Artifact = Artifact
  { artId       :: ArtifactId
  , artKind     :: ArtifactKind
  , artName     :: Maybe Text
  , artText     :: Maybe Text
  , artDocOrder :: !Int
  , artLane     :: Maybe LaneId
  }
  deriving (Eq, Show)

data ArtifactKind
  = AkDataObject
  | AkDataStore
  | AkTextAnnotation
  deriving (Eq, Ord, Show)

-- Root elements -------------------------------------------------------------

data MessageDef = MessageDef
  { msgId          :: NodeId
  , msgName        :: Text
  , msgCorrelation :: Maybe FeelExpr
  }
  deriving (Eq, Show)

data SignalDef = SignalDef
  { sigId   :: NodeId
  , sigName :: Text
  }
  deriving (Eq, Show)

data ErrorDef = ErrorDef
  { errId   :: NodeId
  , errCode :: Text
  , errName :: Text
  }
  deriving (Eq, Show)

data EscalationDef = EscalationDef
  { escId   :: NodeId
  , escCode :: Text
  , escName :: Text
  }
  deriving (Eq, Show)

-- Provenance ----------------------------------------------------------------

-- | Where each element came from in the source.
--
-- Kept beside the graph rather than inside it: a span is not BPMN meaning, and
-- putting it in 'FlowNode' would make two structurally identical graphs
-- compare unequal, which the determinism tests rely on. Validation and layout
-- diagnostics look elements up here so an error can point at the construct
-- that caused it.
data Provenance = Provenance
  { provNodes :: Map NodeId Span
  , provFlows :: Map FlowId Span
  }
  deriving (Eq, Show)

emptyProvenance :: Provenance
emptyProvenance = Provenance Map.empty Map.empty

spanOfNode :: Provenance -> NodeId -> Maybe Span
spanOfNode p i = Map.lookup i (provNodes p)

spanOfFlow :: Provenance -> FlowId -> Maybe Span
spanOfFlow p i = Map.lookup i (provFlows p)

-- Queries -------------------------------------------------------------------

scopeNodeMap :: Scope -> Map NodeId FlowNode
scopeNodeMap s = Map.fromList [(fnId n, n) | n <- scNodes s]

scopeFlowMap :: Scope -> Map FlowId SequenceFlow
scopeFlowMap s = Map.fromList [(sfId f, f) | f <- scFlows s]

-- | Every scope in a process, outermost first, in document order. Used by the
-- recursive formatter and by validation passes that must visit subprocesses.
allScopes :: Scope -> [Scope]
allScopes s = s : concatMap allScopes (childScopes s)

childScopes :: Scope -> [Scope]
childScopes s =
  [ inner
  | n <- scNodes s
  , NkActivity (Activity {acKind = AkSubprocess inner}) <- [fnKind n]
  ]

nodeIsGateway :: FlowNode -> Bool
nodeIsGateway n = case fnKind n of
  NkGateway _ -> True
  _ -> False

nodeIsEvent :: FlowNode -> Bool
nodeIsEvent n = case fnKind n of
  NkEvent _ -> True
  _ -> False

nodeIsActivity :: FlowNode -> Bool
nodeIsActivity n = case fnKind n of
  NkActivity _ -> True
  _ -> False

nodeIsBoundary :: FlowNode -> Bool
nodeIsBoundary n = case fnKind n of
  NkEvent (EventSpec (EvBoundary _) _) -> True
  _ -> False

boundaryHost :: FlowNode -> Maybe BoundaryAttachment
boundaryHost n = case fnKind n of
  NkEvent (EventSpec (EvBoundary a) _) -> Just a
  _ -> Nothing

isStartEvent :: FlowNode -> Bool
isStartEvent n = case fnKind n of
  NkEvent (EventSpec EvStart _) -> True
  _ -> False

isEndEvent :: FlowNode -> Bool
isEndEvent n = case fnKind n of
  NkEvent (EventSpec EvEnd _) -> True
  _ -> False

-- | An end event that stops the branch for good — including the error,
-- escalation, cancel and terminate flavours BRANCH-007 classifies as
-- @EXCEPTION@.
isTerminating :: FlowNode -> Bool
isTerminating n = case fnKind n of
  NkEvent (EventSpec EvEnd _) -> True
  _ -> False

gatewayKindOf :: FlowNode -> Maybe GatewayKind
gatewayKindOf n = case fnKind n of
  NkGateway k -> Just k
  _ -> Nothing

outgoingOf :: Scope -> NodeId -> [SequenceFlow]
outgoingOf s i = [f | f <- scFlows s, sfSource f == i]

incomingOf :: Scope -> NodeId -> [SequenceFlow]
incomingOf s i = [f | f <- scFlows s, sfTarget f == i]

defaultFlowOf :: Scope -> NodeId -> Maybe FlowId
defaultFlowOf s i =
  case [sfId f | f <- outgoingOf s i, sfCondition f == Just FcDefault] of
    (x : _) -> Just x
    [] -> Nothing

-- | Canonical element size before any label-driven growth (LAYOUT-003).
-- Returned as a pair so the layout engine can start from it and apply the
-- growth ladder; the semantic graph itself stores no geometry.
nodeSizeHint :: FlowNode -> (Int, Int)
nodeSizeHint n = case fnKind n of
  NkEvent _ -> (36, 36)
  NkGateway _ -> (50, 50)
  NkActivity a -> case acKind a of
    AkSubprocess _ -> (240, 160)
    _ -> (100, 80)

-- | Sort every collection by the canonical key @(documentOrder, id)@
-- (LAYOUT-027 rule 1). Applied once, before any traversal; afterwards list
-- order /is/ canonical order and no phase needs to sort again.
canonicalise :: SemanticGraph -> SemanticGraph
canonicalise g =
  g
    { sgProcesses = map canonProcess (sortOn (unProcessId . procId) (sgProcesses g))
    , sgMessages = sortOn (unNodeId . msgId) (sgMessages g)
    , sgSignals = sortOn (unNodeId . sigId) (sgSignals g)
    , sgErrors = sortOn (unNodeId . errId) (sgErrors g)
    , sgEscalations = sortOn (unNodeId . escId) (sgEscalations g)
    , sgCollaboration = fmap canonCollab (sgCollaboration g)
    }
  where
    canonCollab c =
      c
        { colParticipants = sortOn (\p -> (partOrder p, unParticipantId (partId p))) (colParticipants c)
        , colMessageFlows = sortOn (\m -> (mfDocOrder m, unFlowId (mfId m))) (colMessageFlows c)
        }
    canonProcess p =
      p
        { procLanes = sortOn (\l -> (laneOrder l, unLaneId (laneId l))) (procLanes p)
        , procScope = canonScope (procScope p)
        }
    canonScope s =
      s
        { scNodes = map canonNode (sortOn (\n -> (fnDocOrder n, unNodeId (fnId n))) (scNodes s))
        , scFlows = sortOn (\f -> (sfDocOrder f, unFlowId (sfId f))) (scFlows s)
        , scArtifacts = sortOn (\a -> (artDocOrder a, unArtifactId (artId a))) (scArtifacts s)
        , scAssociations = sortOn (\a -> (asDocOrder a, unFlowId (asId a))) (scAssociations s)
        }
    canonNode n = case fnKind n of
      NkActivity a@Activity {acKind = AkSubprocess inner} ->
        n {fnKind = NkActivity a {acKind = AkSubprocess (canonScope inner)}}
      _ -> n
