-- | 'SemanticGraph' → surface AST. The inverse of "Sequent.Language.Resolve".
--
-- This is the harder half of the import, and the reason is structural rather
-- than clerical. The semantic graph is flat — nodes and the flows between them
-- — while the surface language is nested, and most of its edges are never
-- written down at all: consecutive steps chain implicitly, a gateway's branches
-- are blocks, and a merge gateway is derived from how many branches reach the
-- end of one. Emitting a graph therefore means /re-deriving the structure the
-- author would have written/, not printing a node list.
--
-- Getting that wrong is silent, because the failure mode is an edge the
-- language invents rather than one it drops: put two unrelated steps next to
-- each other and the resolver connects them. So the discipline here is to emit
-- only structure whose implicit edges are known to exist, and to fall back to
-- @goto@ and explicit @flow@ for everything else. What the emitter cannot
-- express it reports.
--
-- The output is an AST, not text. "Sequent.Language.Pretty" turns it into
-- source, which means the import lands in canonical form for free and the
-- formatter stays the only thing that knows how the language is laid out.
module Sequent.Language.Emit
  ( emitFile
  , EmitResult (..)
  ) where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Id (classPrefix, IdClass (..))
import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model
import Sequent.Diagnostic
import Sequent.Language.Parser (reservedWords)
import Sequent.Language.Syntax

data EmitResult = EmitResult
  { emFile        :: SFile
  , emSymbols     :: Map Text Text
  -- ^ The symbolic name chosen for every id. The caller needs it to check its
  -- own work: a file whose ids are not names — @Activity_1x9k2df@ — cannot keep
  -- them, so the two graphs are compared on the names instead.
  , emDiagnostics :: [Diagnostic]
  }

-- Symbolic names ------------------------------------------------------------------

-- | Every declared thing's symbolic name, keyed by the id it came from.
--
-- A name is recovered from the id where the id looks like one this compiler
-- allocated — @Activity_charge@ becomes @charge@ — so a file this compiler
-- wrote imports back to the names it was written with, and a second compile
-- reproduces the same ids. A file from a modeller has ids like
-- @Activity_1x9k2df@, which is not a name anybody wrote; there the label is
-- slugified instead, and the ids will change on the way back out. That is the
-- one thing the round trip does not preserve, and it is unavoidable: the
-- language has no syntax for \"this step's id is that string\".
type Symbols = Map Text Text

data Naming = Naming
  { nmTaken :: Set Text
  , nmMap   :: Symbols
  }

emptyNaming :: Naming
emptyNaming = Naming Set.empty Map.empty

-- | Claim a name for an id. Idempotent: asking twice returns the first answer.
claim :: IdClass -> Text -> Maybe Text -> Naming -> Naming
claim cls i label nm
  | Map.member i (nmMap nm) = nm
  | otherwise =
      let base = candidate cls i label
          final = uniquify (nmTaken nm) base
       in Naming (Set.insert final (nmTaken nm)) (Map.insert i final (nmMap nm))

-- | Point one id at the name another already claimed.
bind :: Text -> Text -> Naming -> Naming
bind i other nm = case Map.lookup other (nmMap nm) of
  Just s -> nm {nmMap = Map.insert i s (nmMap nm)}
  Nothing -> nm

candidate :: IdClass -> Text -> Maybe Text -> Text
candidate cls i label
  | Just s <- stripped, valid s = s
  | Just l <- label, valid (slug l) = slug l
  | valid (slug i) = slug i
  | otherwise = "n"
  where
    stripped = T.stripPrefix (classPrefix cls) i
    valid s = not (T.null s) && startOk (T.head s) && T.all identOk s && not (Set.member s reservedWords)
    startOk c = isAlpha c || c == '_'
    identOk c = isAlphaNum c || c == '_'

-- | Turn presentation text into an identifier: lower-cased words joined by
-- underscores, anything else dropped. Leading digits get an underscore rather
-- than being thrown away, because @3ds_check@ reads better than @ds_check@.
slug :: Text -> Text
slug t
  | T.null cleaned = ""
  | isDigit (T.head cleaned) = T.cons '_' cleaned
  | otherwise = cleaned
  where
    cleaned =
      T.intercalate "_"
        . filter (not . T.null)
        . T.split (== ' ')
        . T.map keep
        $ T.toLower t
    keep c
      | isAlphaNum c = c
      | otherwise = ' '

uniquify :: Set Text -> Text -> Text
uniquify taken base
  | not (Set.member base taken) = base
  | otherwise = go (2 :: Int)
  where
    go k
      | not (Set.member c taken) = c
      | otherwise = go (k + 1)
      where
        c = base <> "_" <> T.pack (show k)

nameOfId :: Symbols -> Text -> Text
nameOfId syms i = Map.findWithDefault i i syms

-- Entry point -----------------------------------------------------------------------

emitFile :: SemanticGraph -> EmitResult
emitFile g = EmitResult (SFile decls) syms diags
  where
    syms = nmMap (naming g)

    decls =
      map (messageDecl syms) (sgMessages g)
        ++ map (signalDecl syms) (sgSignals g)
        ++ map (errorDecl syms) (sgErrors g)
        ++ map (escalationDecl syms) (sgEscalations g)
        ++ bodyDecls

    (bodyDecls, diags) = case sgCollaboration g of
      Just col -> collaborationDecl syms g col
      Nothing ->
        let rs = map (processDecl syms) (sgProcesses g)
         in (map (DProcess . fst) rs, concatMap snd rs)

-- | Claim a name for everything that can be referred to, in one pass, so that
-- the order names are handed out in is a property of the graph rather than of
-- the traversal that happened to reach them first.
naming :: SemanticGraph -> Naming
naming g =
  foldl' (\nm f -> f nm) emptyNaming $
    [claim IcCollaboration (colId col) Nothing | Just col <- [sgCollaboration g]]
      ++ [claim IcMessage (unNodeId (msgId m)) (Just (msgName m)) | m <- sgMessages g]
      ++ [claim IcSignal (unNodeId (sigId s)) (Just (sigName s)) | s <- sgSignals g]
      ++ [claim IcError (unNodeId (errId e)) (Just (errName e)) | e <- sgErrors g]
      ++ [claim IcEscalation (unNodeId (escId e)) (Just (escName e)) | e <- sgEscalations g]
      ++ [ claim IcParticipant (unParticipantId (partId p)) (partName p)
         | Just col <- [sgCollaboration g]
         , p <- colParticipants col
         ]
      -- A pool and the process it holds are one declaration in this language:
      -- @pool buyer@ allocates both @Participant_buyer@ and @Process_buyer@.
      -- Letting the process claim a name of its own would hand it @buyer_2@ and
      -- put a name in the file that nothing refers to.
      ++ [ bind (unProcessId pr) (unParticipantId (partId p))
         | Just col <- [sgCollaboration g]
         , p <- colParticipants col
         , Just pr <- [partProcess p]
         ]
      ++ concatMap processNames (sgProcesses g)
  where
    processNames p =
      [claim IcProcess (unProcessId (procId p)) (procName p)]
        ++ [claim IcLane (unLaneId (laneId l)) (laneName l) | l <- procLanes p]
        ++ concatMap scopeNames (allScopes (procScope p))
    scopeNames sc =
      [claim (classOf n) (unNodeId (fnId n)) (fnName n) | n <- scNodes sc]
        ++ [claim IcTextAnnotation (unArtifactId (artId a)) (artName a) | a <- scArtifacts sc]
    classOf n = case fnKind n of
      NkEvent (EventSpec EvStart _) -> IcStartEvent
      NkEvent _ -> IcEndEvent -- the same "Event_" prefix
      NkGateway _ -> IcGateway
      NkActivity _ -> IcActivity

-- Root declarations --------------------------------------------------------------

messageDecl :: Symbols -> MessageDef -> SDecl
messageDecl syms m =
  DMessage (loc (nameOfId syms (unNodeId (msgId m)))) (msgName m) (unFeel <$> msgCorrelation m) noSpan

signalDecl :: Symbols -> SignalDef -> SDecl
signalDecl syms s = DSignal (loc (nameOfId syms (unNodeId (sigId s)))) (sigName s) noSpan

errorDecl :: Symbols -> ErrorDef -> SDecl
errorDecl syms e =
  DError (loc (nameOfId syms (unNodeId (errId e)))) (errCode e) (labelUnless (errCode e) (errName e)) noSpan

escalationDecl :: Symbols -> EscalationDef -> SDecl
escalationDecl syms e =
  DEscalation (loc (nameOfId syms (unNodeId (escId e)))) (escCode e) (labelUnless (escCode e) (escName e)) noSpan

-- | The resolver defaults an omitted label to the code, so writing it back is
-- noise when the two agree.
labelUnless :: Text -> Text -> Maybe Text
labelUnless code nm
  | nm == code = Nothing
  | otherwise = Just nm

loc :: a -> Located a
loc = Located noSpan

-- Collaboration and processes ----------------------------------------------------

collaborationDecl :: Symbols -> SemanticGraph -> Collaboration -> ([SDecl], [Diagnostic])
collaborationDecl syms g col = ([DCollaboration (SCollab (loc cname) Nothing items noSpan)], diags)
  where
    cname = nameOfId syms (colId col)
    procById = Map.fromList [(procId p, p) | p <- sgProcesses g]

    (pools, diags) =
      let rs =
            [ poolOf syms p (partProcess p >>= (`Map.lookup` procById))
            | p <- sortOn partOrder (colParticipants col)
            ]
       in (map fst rs, concatMap snd rs)

    items = map CPool pools ++ map (CMessageFlow . msgFlowOf syms) (colMessageFlows col)

poolOf :: Symbols -> Participant -> Maybe BpmnProcess -> (SPool, [Diagnostic])
poolOf syms p mproc =
  ( SPool (loc (nameOfId syms (unParticipantId (partId p)))) (partName p) body noSpan
  , ds
  )
  where
    (body, ds) = case mproc of
      -- LANE-014: a participant with no process is a black box, written as a
      -- pool with no body.
      Nothing -> (Nothing, [])
      Just pr -> let (is, d) = processBody syms pr in (Just is, d)

msgFlowOf :: Symbols -> MessageFlow -> SMsgFlow
msgFlowOf syms m =
  SMsgFlow (loc (refName syms (mfSource m))) (loc (refName syms (mfTarget m))) (mfName m) noSpan

refName :: Symbols -> ElementRef -> Text
refName syms r = case r of
  RefNode i -> nameOfId syms (unNodeId i)
  RefParticipant i -> nameOfId syms (unParticipantId i)
  RefArtifact i -> nameOfId syms (unArtifactId i)
  RefFlow i -> unFlowId i
  RefLane i -> nameOfId syms (unLaneId i)

processDecl :: Symbols -> BpmnProcess -> (SProcess, [Diagnostic])
processDecl syms p = (SProcess (loc (nameOfId syms (unProcessId (procId p)))) (procName p) items noSpan, ds)
  where
    (items, ds) = processBody syms p

-- | A process body: its documentation, then its lanes or its bare scope.
processBody :: Symbols -> BpmnProcess -> ([SItem], [Diagnostic])
processBody syms p = (docItems ++ items, ds)
  where
    docItems = [IDoc d noSpan | Just d <- [procDoc p]]
    sc = procScope p
    (items, ds)
      | null (procLanes p) = emitScope syms sc
      | otherwise = laneItems syms p sc

-- | With lanes, the body is a sequence of @lane@ blocks.
--
-- The scope is emitted once and then partitioned, rather than emitted per lane,
-- because the chain structure is a property of the flow and not of who owns
-- each step. Partitioning has to reach inside gateway branches and boundary
-- handlers: a branch that hands work to another role is exactly the case lanes
-- exist for, and a block that only looked at the top level would file that
-- step under whichever lane the gateway happened to be in.
--
-- Nesting is how the language says it. A @lane@ block inside a branch re-enters
-- that lane for the run it wraps and hands the chain straight back, so wrapping
-- a run costs nothing structurally.
laneItems :: Symbols -> BpmnProcess -> Scope -> ([SItem], [Diagnostic])
laneItems syms p sc = (relane Nothing items, ds)
  where
    (items, ds) = emitScope syms sc

    byId = Map.fromList [(fnId n, n) | s <- allScopes sc, n <- scNodes s]
    laneOfNode = Map.fromList [(fnId n, l) | n <- Map.elems byId, Just l <- [fnLane n]]
    nodeByName = Map.fromList [(nameOfId syms (unNodeId i), i) | i <- Map.keys byId]

    laneOfItem i = case i of
      IStep (StNode n) -> byName (unLoc (snName n))
      IStep (StGateway gw) -> byName (unLoc (sgName gw))
      IStep (StSubprocess s') -> byName (unLoc (ssName s'))
      IBoundary b -> byName (unLoc (bdAs b))
      _ -> Nothing
    byName nm = Map.lookup nm nodeByName >>= (`Map.lookup` laneOfNode)

    relane inh = wrap inh . map (descend inh)

    descend inh i = case i of
      IStep (StGateway gw) ->
        IStep (StGateway gw {sgBranches = map inBranch (sgBranches gw)})
      IStep (StSubprocess s') -> IStep (StSubprocess s' {ssBody = relane own (ssBody s')})
      IBoundary b -> IBoundary b {bdBody = relane own (bdBody b)}
      _ -> i
      where
        own = maybe inh Just (laneOfItem i)
        inBranch (BBranch br) = BBranch br {brBody = relane own <$> brBody br}
        inBranch other = other

    wrap inh = go
      where
        go [] = []
        go (i : is) = case laneOfItem i of
          Just l
            | Just l /= inh ->
                let (run, rest) = span ((== Just l) . laneOfItem) (i : is)
                 in ILane (SLane (loc (nameOfId syms (unLaneId l))) (laneLabel l) run noSpan) : go rest
          _ -> i : go is

    laneLabel l = case [laneName x | x <- procLanes p, laneId x == l] of
      (nm : _) -> nm
      [] -> Nothing

-- Scope emission ---------------------------------------------------------------------

-- | What the walk has already produced, so that nothing is emitted twice and
-- every flow is accounted for exactly once.
data Emitted = Emitted
  { emNodes :: Set NodeId
  , emFlows :: Set FlowId
  }

data Ctx = Ctx
  { cxSyms  :: Symbols
  , cxScope :: Scope
  , cxOut   :: Map NodeId [SequenceFlow]
  , cxIn    :: Map NodeId [SequenceFlow]
  , cxNodes :: Map NodeId FlowNode
  , cxHosts :: Map NodeId [FlowNode]
  -- ^ Boundary events by the node they hang on. They are never steps.
  , cxBoundaries :: Set NodeId
  }

mkCtx :: Symbols -> Scope -> Ctx
mkCtx syms sc =
  Ctx
    { cxSyms = syms
    , cxScope = sc
    , cxOut = Map.fromListWith (flip (++)) [(sfSource f, [f]) | f <- scFlows sc]
    , cxIn = Map.fromListWith (flip (++)) [(sfTarget f, [f]) | f <- scFlows sc]
    , cxNodes = Map.fromList [(fnId n, n) | n <- scNodes sc]
    , cxHosts =
        Map.fromListWith
          (flip (++))
          [(baHost att, [n]) | n <- scNodes sc, Just att <- [boundaryHost n]]
    , cxBoundaries = Set.fromList [fnId n | n <- scNodes sc, Just _ <- [boundaryHost n]]
    }

outOf :: Ctx -> NodeId -> [SequenceFlow]
outOf cx i = sortOn sfDocOrder (Map.findWithDefault [] i (cxOut cx))

inOf :: Ctx -> NodeId -> [SequenceFlow]
inOf cx i = sortOn sfDocOrder (Map.findWithDefault [] i (cxIn cx))

symOf :: Ctx -> NodeId -> Text
symOf cx i = nameOfId (cxSyms cx) (unNodeId i)

emitScope :: Symbols -> Scope -> ([SItem], [Diagnostic])
emitScope syms sc = (closed ++ open ++ leftovers ++ artefactItems cx, ds ++ openDiag)
  where
    cx = mkCtx syms sc

    roots =
      [ fnId n
      | n <- scNodes sc
      , not (Set.member (fnId n) (cxBoundaries cx))
      , isStartEvent n || null (inOf cx (fnId n))
      ]
        ++ [fnId n | n <- scNodes sc, not (Set.member (fnId n) (cxBoundaries cx))]

    (chains, st) = runRoots cx roots
    closed = concatMap chItems (filter chClosed chains)
    open = concatMap chItems (filter (not . chClosed) chains)
    ds = concatMap chDiags chains

    -- Anything the structure did not create has to be said outright.
    leftovers =
      [ flowItem cx f
      | f <- sortOn sfDocOrder (scFlows sc)
      , not (Set.member (sfId f) (emFlows st))
      ]

    openDiag =
      [ withHint
          "a step that leads nowhere and is not an end event cannot be followed by another step: the language would connect the two"
          ( diagnostic
              Warning
              SemanticError
              ( "this scope has "
                  <> T.pack (show (length (filter (not . chClosed) chains)))
                  <> " paths that stop without an end event; only one of them can be written"
              )
          )
      | length (filter (not . chClosed) chains) > 1
      ]

-- | A chain of steps, and what it leaves behind.
data Chain = Chain
  { chItems :: [SItem]
  , chTail  :: Maybe NodeId
  -- ^ The node left pending. 'Nothing' means the chain is closed — an end event
  -- or a @goto@ finished it, so the next step in the block is not joined to it.
  -- That distinction is the whole difficulty of emitting this language: put two
  -- steps next to each other and the resolver connects them.
  , chDiags :: [Diagnostic]
  }

chClosed :: Chain -> Bool
chClosed = (== Nothing) . chTail

runRoots :: Ctx -> [NodeId] -> ([Chain], Emitted)
runRoots cx = go (Emitted Set.empty Set.empty)
  where
    go st [] = ([], st)
    go st (r : rs)
      | Set.member r (emNodes st) || Set.member r (cxBoundaries cx) = go st rs
      | otherwise =
          let (ch, st') = chainFrom cx Set.empty st r
              (chs, st'') = go st' rs
           in (ch : chs, st'')

-- | Walk one maximal chain, following the implicit connection wherever it
-- exists. @stop@ holds the nodes an enclosing construct has claimed — a
-- gateway's merge above all — so the chain ends before them instead of
-- swallowing them into a branch.
chainFrom :: Ctx -> Set NodeId -> Emitted -> NodeId -> (Chain, Emitted)
chainFrom cx stop st0 start = step st0 start
  where
    step st i = case Map.lookup i (cxNodes cx) of
      Nothing -> (Chain [] Nothing [], st)
      Just n ->
        let st1 = st {emNodes = Set.insert i (emNodes st)}
            (attachItems, stA) = boundaryItems cx stop st1 i
            (thisItems, stB, dsB, mNext) = stepFor cx stop stA n
            -- A gateway whose merge the resolver derives leaves that merge
            -- pending, so the chain goes on from there rather than from the
            -- split. Continuing from the split instead strands everything past
            -- the merge in a second, disconnected chain.
            (rest, stC) = case mNext >>= (`Map.lookup` cxNodes cx) of
              Just mn -> continue stB mn
              Nothing -> continue stB n
         in ( Chain (thisItems ++ attachItems ++ chItems rest) (chTail rest) (dsB ++ chDiags rest)
            , stC
            )

    continue st n
      | isEndEvent n = (Chain [] Nothing [], st)
      | otherwise = case pickImplicit cx stop st n of
          Just f ->
            let st' = st {emFlows = Set.insert (sfId f) (emFlows st)}
             in step st' (sfTarget f)
          Nothing -> case pickGoto cx stop st n of
            Just f ->
              ( Chain [IStep (StGoto (loc (symOf cx (sfTarget f))) noSpan)] Nothing []
              , st {emFlows = Set.insert (sfId f) (emFlows st)}
              )
            Nothing -> (Chain [] (Just (fnId n)) [], st)

-- | The flow this chain follows without writing anything: unlabelled,
-- unconditional, and into a node nothing else has claimed yet.
pickImplicit :: Ctx -> Set NodeId -> Emitted -> FlowNode -> Maybe SequenceFlow
pickImplicit cx stop st n = case candidates of
  (f : _) -> Just f
  [] -> Nothing
  where
    candidates =
      [ f
      | f <- outOf cx (fnId n)
      , not (Set.member (sfId f) (emFlows st))
      , sfName f == Nothing
      , sfCondition f == Nothing
      , not (Set.member (sfTarget f) (emNodes st))
      , not (Set.member (sfTarget f) (cxBoundaries cx))
      , not (Set.member (sfTarget f) stop)
      , Map.member (sfTarget f) (cxNodes cx)
      ]

-- | The flow a @goto@ can carry: the last unwritten one, unlabelled and
-- unconditional, since @goto@ has nowhere to put a label. Writing it both makes
-- the edge and closes the chain, which is the only way to stop a path short of
-- an end event.
pickGoto :: Ctx -> Set NodeId -> Emitted -> FlowNode -> Maybe SequenceFlow
pickGoto cx stop st n = case left of
  [f]
    | sfName f == Nothing
    , sfCondition f == Nothing
    , -- Never into a node an enclosing construct has claimed. A branch that
      -- closes itself with a @goto@ into its own gateway's merge is a branch
      -- that has stopped continuing, and the merge the resolver would have
      -- derived from it never appears.
      not (Set.member (sfTarget f) stop) ->
        Just f
  _ -> Nothing
  where
    left = [f | f <- outOf cx (fnId n), not (Set.member (sfId f) (emFlows st))]

-- One step ---------------------------------------------------------------------------

-- | One step, and the node the chain is left pending on if it is not the step
-- itself.
stepFor :: Ctx -> Set NodeId -> Emitted -> FlowNode -> ([SItem], Emitted, [Diagnostic], Maybe NodeId)
stepFor cx stop st n = case fnKind n of
  NkGateway k -> gatewayFor cx stop st n k
  NkActivity (Activity (AkSubprocess inner) _) ->
    let (is, ds) = emitScope (cxSyms cx) inner
     in ( [IStep (StSubprocess (SSub (loc (symOf cx (fnId n))) (fnName n) (docItems ++ is) noSpan))]
        , st
        , ds
        , Nothing
        )
  _ -> ([IStep (StNode (nodeFor cx n))], st, [], Nothing)
  where
    docItems = [IDoc d noSpan | Just d <- [fnDoc n]]

nodeFor :: Ctx -> FlowNode -> SNode
nodeFor cx n = SNode (loc kw) (loc (symOf cx (fnId n))) (fnName n) props noSpan
  where
    (kw, kindProps) = keywordFor cx n
    props =
      map (SProp noSpan) $
        kindProps
          ++ execProps (fnExec n)
          ++ loopProps n
          ++ [PDoc d | Just d <- [fnDoc n]]

keywordFor :: Ctx -> FlowNode -> (NodeKw, [SPropBody])
keywordFor cx n = case fnKind n of
  NkEvent (EventSpec fl d) -> (eventKw fl, triggerProps cx d)
  NkActivity (Activity k _) -> case k of
    AkCallActivity -> (KwCall, [])
    AkSubprocess _ -> (KwTask, [])
    AkTask t -> case t of
      TtAbstract -> (KwTask, [])
      TtService -> (KwService, [])
      TtUser -> (KwUser, [])
      TtManual -> (KwManual, [])
      TtScript -> (KwScript, [])
      TtBusinessRule -> (KwBusiness, [])
      TtSend -> (KwSend, [])
      TtReceive m -> (KwReceive, [PMessage (symOf cx i) | Just i <- [m]])
  NkGateway _ -> (KwTask, [])
  where
    eventKw fl = case fl of
      EvStart -> KwStart
      EvEnd -> KwEnd
      EvIntermediateCatch -> KwWait
      EvIntermediateThrow -> KwThrow
      EvBoundary _ -> KwWait

triggerProps :: Ctx -> Maybe EventDefinition -> [SPropBody]
triggerProps cx d = case d of
  Nothing -> []
  Just (EdMessage i) -> [PMessage (symOf cx i)]
  Just (EdSignal i) -> [PSignal (symOf cx i)]
  Just (EdError mi) -> [PError (symOf cx i) | Just i <- [mi]]
  Just (EdEscalation mi) -> [PEscalation (symOf cx i) | Just i <- [mi]]
  Just (EdTimer t) -> [PTimer (timerText t)]
  Just EdTerminate -> [PTerminate]
  Just EdCompensation -> [PCompensation]
  Just (EdLink nm) -> [PLink nm]

timerText :: TimerDef -> Text
timerText t = case t of
  TimerDuration v -> v
  TimerCycle v -> v
  TimerDate v -> v

execProps :: ExecutionMeta -> [SPropBody]
execProps m = case m of
  ExNone -> []
  ExService z ->
    [PType (ztType z)]
      ++ [PRetries r | Just r <- [ztRetries z]]
      ++ mappingProps (ztInputs z) (ztOutputs z)
      ++ [PHeader (hdrKey h) (hdrValue h) | h <- ztHeaders z]
  ExUser u ->
    [PForm f | Just f <- [utForm u]]
      ++ [PAssignee (unFeel a) | Just a <- [utAssignee u]]
      ++ [PGroups (unFeel a) | Just a <- [utCandidateGroups u]]
      ++ [PUsers (unFeel a) | Just a <- [utCandidateUsers u]]
      ++ [PDue (unFeel a) | Just a <- [utDueDate u]]
      ++ mappingProps (utInputs u) (utOutputs u)
  ExScript s ->
    [PExpression (unFeel (scExpression s)), PResult (scResult s)]
      ++ mappingProps (scInputs s) (scOutputs s)
  ExDecision d ->
    [PDecision (dsDecisionId d), PResult (dsResult d)]
      ++ mappingProps (dsInputs d) (dsOutputs d)
  ExCall c ->
    [PCalls (ceProcessId c)]
      ++ [PPropagate | cePropagateAllChildVariables c]
      ++ mappingProps (ceInputs c) (ceOutputs c)

mappingProps :: [Mapping] -> [Mapping] -> [SPropBody]
mappingProps ins outs =
  [PInput (mapTarget m) (unFeel (mapSource m)) | m <- ins]
    ++ [POutput (mapTarget m) (unFeel (mapSource m)) | m <- outs]

loopProps :: FlowNode -> [SPropBody]
loopProps n = case fnKind n of
  NkActivity (Activity _ (Just ls)) ->
    [PEach (lsInputElement ls) (unFeel (lsInputCollection ls)) (lsSequential ls)]
      ++ [PCollect c (unFeel e) | Just c <- [lsOutputCollection ls], Just e <- [lsOutputElement ls]]
  _ -> []

-- Gateways -------------------------------------------------------------------------

gatewayFor :: Ctx -> Set NodeId -> Emitted -> FlowNode -> GatewayKind -> ([SItem], Emitted, [Diagnostic], Maybe NodeId)
gatewayFor cx stop st n k
  | null branchFlows = ([IStep (StNode (nodeFor cx n))], st, [bareGatewayDiag], Nothing)
  | otherwise = ([IStep (StGateway gw)], stFinal, ds, if useDerived then merge else Nothing)
  where
    branchFlows = [f | f <- outOf cx (fnId n), not (Set.member (sfId f) (emFlows st))]

    -- The merge is found in the /graph/, before any branch is walked, because a
    -- branch that walks into it swallows it: the merge becomes an ordinary step
    -- inside the first branch, and every other branch then points at a node
    -- nested somewhere it cannot reach.
    merge = mergeOf cx st n branchFlows
    innerStop = maybe stop (`Set.insert` stop) merge

    (branches, stAfter, ds0) = foldl' oneBranch ([], st, []) branchFlows

    oneBranch (acc, s, d) f
      -- A branch that runs straight into the merge is written as an empty
      -- body. The resolver seeds a pending from the split, nothing consumes it,
      -- and the edge it eventually makes into the derived merge is this very
      -- flow — label, condition and all.
      | Just m <- merge, sfTarget f == m = (acc ++ [(f, emptyChain, Just [])], s1, d)
      | Set.member (sfTarget f) (emNodes s1)
          || Set.member (sfTarget f) (cxBoundaries cx)
          || Set.member (sfTarget f) innerStop =
          (acc ++ [(f, gotoChain (sfTarget f), Nothing)], s1, d)
      | otherwise =
          let (ch, s2) = chainFrom cx innerStop s1 (sfTarget f)
           in (acc ++ [(f, ch, landing s2 ch)], s2, d ++ chDiags ch)
      where
        s1 = s {emFlows = Set.insert (sfId f) (emFlows s)}

    emptyChain = Chain [] Nothing []
    gotoChain t = Chain [IStep (StGoto (loc (symOf cx t)) noSpan)] Nothing []

    -- A branch lands on the merge when its chain stopped one plain step short
    -- of it. That is what leaves the branch \"continuing\", which is the only
    -- thing the resolver derives a merge from.
    landing s ch = do
      m <- merge
      t <- chTail ch
      case [x | x <- outOf cx t, not (Set.member (sfId x) (emFlows s)), sfTarget x == m] of
        [] -> Nothing
        fs | all (\x -> sfName x == Nothing && sfCondition x == Nothing) fs -> Just (map sfId fs)
        _ -> Nothing

    landings = [fs | (_, _, Just fs) <- branches]

    -- Deriving the merge is right only when every branch accounts for itself:
    -- the ones that reach it are open, the ones that do not are closed, and
    -- nothing outside the region flows in. Otherwise the node the resolver
    -- invents is not the node the process has.
    useDerived = case merge of
      Just m ->
        length landings >= 2
          && length landings == length (inOf cx m)
          && all (\(_, ch, l) -> l /= Nothing || chClosed ch) branches
      Nothing -> False

    finalBranches
      | useDerived = [(f, chItems ch) | (f, ch, _) <- branches]
      | otherwise = [(f, chItems ch ++ closer ch) | (f, ch, _) <- branches]

    closer ch = case chTail ch of
      Just t
        | (x : _) <- closable t -> [IStep (StGoto (loc (symOf cx (sfTarget x))) noSpan)]
      _ -> []

    closable t =
      [ x
      | x <- outOf cx t
      , not (Set.member (sfId x) (emFlows stAfter))
      , sfName x == Nothing
      , sfCondition x == Nothing
      , length [y | y <- outOf cx t, not (Set.member (sfId y) (emFlows stAfter))] == 1
      ]

    stFinal
      | useDerived =
          stAfter
            { emNodes = maybe id Set.insert merge (emNodes stAfter)
            , emFlows = foldl' (flip Set.insert) (emFlows stAfter) (concat landings)
            }
      | otherwise =
          stAfter
            { emFlows =
                foldl'
                  (flip Set.insert)
                  (emFlows stAfter)
                  [sfId x | (_, ch, _) <- branches, Just t <- [chTail ch], x <- take 1 (closable t)]
            }

    -- The resolver names a derived merge @<gateway>_join@ and allocates
    -- @Gateway_<that>@ for it. Where the file already agrees, the clause is
    -- noise; where it does not, it is the only way to keep the id.
    joinClause = case merge of
      Just m
        | useDerived, symOf cx m /= symOf cx (fnId n) <> "_join" -> Just (loc (symOf cx m))
      _ -> Nothing

    gw =
      SGateway
        { sgKind = loc (gwKw k)
        , sgName = loc (symOf cx (fnId n))
        , sgLabel = fnName n
        , sgJoin = joinClause
        , sgBranches = [BBranch (branchOf f body) | (f, body) <- finalBranches]
        , sgSpan = noSpan
        }

    branchOf f body =
      SBranch
        { brLabel = sfName f
        , brGuard = guardOf (sfCondition f)
        , brPriority = sfPriority f
        , brBody = if null body then Nothing else Just body
        , brSpan = noSpan
        }

    ds = ds0

    bareGatewayDiag =
      withHint
        "a gateway needs at least one branch; this one has no outgoing flow"
        (diagnostic Warning SemanticError ("gateway '" <> unNodeId (fnId n) <> "' has no outgoing flow and was written as a task"))

guardOf :: Maybe FlowCondition -> Maybe (Located SGuard)
guardOf c = case c of
  Nothing -> Nothing
  Just FcDefault -> Just (loc GOtherwise)
  Just (FcExpression e) -> Just (loc (GWhen (unFeel e)))

-- | The node a gateway's branches converge on, if the language can express it
-- as a derived merge: an unnamed gateway of the matching kind whose every
-- incoming edge is plain.
mergeOf :: Ctx -> Emitted -> FlowNode -> [SequenceFlow] -> Maybe NodeId
mergeOf cx st g branchFlows = case candidates of
  [m] -> Just m
  _ -> Nothing
  where
    candidates =
      [ m
      | m <- dedup (concatMap reach branchFlows)
      , m /= fnId g
      , not (Set.member m (emNodes st))
      , Just mn <- [Map.lookup m (cxNodes cx)]
      , fnKind mn == NkGateway (joinKindOf (kindOf g))
      , fnName mn == Nothing
      , fnDoc mn == Nothing
      , fnExec mn == ExNone
      , length (inOf cx m) >= 2
      , all plainEnough (inOf cx m)
      ]
    -- The edges a derived merge makes carry whatever the pending carried. A
    -- pending seeded by a branch and never consumed — an empty branch, running
    -- straight to the merge — still carries that branch's label and condition,
    -- so an edge coming directly from the split is allowed to have them. One
    -- coming from a step is not: a plain chain pending carries nothing.
    plainEnough f =
      sfSource f == fnId g
        || (sfName f == Nothing && sfCondition f == Nothing)
    kindOf x = case fnKind x of
      NkGateway kk -> kk
      _ -> GwExclusive

    -- Follow each branch forward along its plain chain and report where it
    -- lands. A merge is a node every branch can see; anything else is not one.
    reach f = walk Set.empty (sfTarget f)
    walk seen i
      | Set.member i seen = []
      | length (inOf cx i) >= 2 = [i]
      | otherwise = case outOf cx i of
          [x] -> walk (Set.insert i seen) (sfTarget x)
          _ -> []

-- | Which gateway the resolver derives for a merge. Mirrors
-- @Sequent.Language.Resolve.joinKind@.
joinKindOf :: GatewayKind -> GatewayKind
joinKindOf k = case k of
  GwEventBased -> GwExclusive
  other -> other

gwKw :: GatewayKind -> GwKw
gwKw k = case k of
  GwExclusive -> KwXor
  GwParallel -> KwAnd
  GwInclusive -> KwOr
  GwEventBased -> KwEventGw
  GwComplex -> KwComplex

dedup :: Ord a => [a] -> [a]
dedup = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs

-- Boundary events, notes and data ------------------------------------------------------

boundaryItems :: Ctx -> Set NodeId -> Emitted -> NodeId -> ([SItem], Emitted)
boundaryItems cx boundaries st host = foldl' one ([], st) (Map.findWithDefault [] host (cxHosts cx))
  where
    one (acc, s) b =
      let s1 = s {emNodes = Set.insert (fnId b) (emNodes s)}
          (body, s2) = case outOf cx (fnId b) of
            [] -> ([], s1)
            (f : _)
              | Set.member (sfTarget f) (emNodes s1) ->
                  ( [IStep (StGoto (loc (symOf cx (sfTarget f))) noSpan)]
                  , s1 {emFlows = Set.insert (sfId f) (emFlows s1)}
                  )
              | otherwise ->
                  let s' = s1 {emFlows = Set.insert (sfId f) (emFlows s1)}
                      (ch, s'') = chainFrom cx boundaries s' (sfTarget f)
                   in (chItems ch, s'')
       in (acc ++ [IBoundary (boundaryOf cx b body)], s2)

boundaryOf :: Ctx -> FlowNode -> [SItem] -> SBoundary
boundaryOf cx b body =
  SBoundary
    { bdHost = loc (symOf cx host)
    , bdTrigger = loc trigger
    , bdNonInt = not interrupting
    , bdAs = loc (symOf cx (fnId b))
    , bdLabel = fnName b
    , bdBody = body
    , bdSpan = noSpan
    }
  where
    (host, interrupting) = case fnKind b of
      NkEvent (EventSpec (EvBoundary att) _) -> (baHost att, baInterrupting att)
      _ -> (fnId b, True)
    trigger = case fnKind b of
      NkEvent (EventSpec _ (Just (EdMessage i))) -> TgMessage (symOf cx i)
      NkEvent (EventSpec _ (Just (EdSignal i))) -> TgSignal (symOf cx i)
      NkEvent (EventSpec _ (Just (EdError (Just i)))) -> TgError (symOf cx i)
      NkEvent (EventSpec _ (Just (EdEscalation (Just i)))) -> TgEscalation (symOf cx i)
      NkEvent (EventSpec _ (Just (EdTimer t))) -> TgTimer (timerText t)
      _ -> TgTimer "PT0S"

artefactItems :: Ctx -> [SItem]
artefactItems cx = mapMaybe itemOf (scArtifacts (cxScope cx))
  where
    assocs = scAssociations (cxScope cx)
    itemOf a = case artKind a of
      AkTextAnnotation -> do
        host <- hostOf (artId a)
        pure
          ( INote
              (SNote (loc (symOf' (unArtifactId (artId a)))) (fromMaybe "" (artText a)) (loc host) noSpan)
          )
      AkDataObject -> do
        (host, dir) <- hostDirOf (artId a)
        pure (IData (SData (loc (symOf' (unArtifactId (artId a)))) (artName a) dir (loc host) noSpan))
      AkDataStore -> Nothing

    symOf' = nameOfId (cxSyms cx)

    hostOf aid =
      case [ n | x <- assocs, Just n <- [pairOf aid x]] of
        (h : _) -> Just h
        [] -> Nothing
    pairOf aid x = case (asSource x, asTarget x) of
      (RefArtifact a', RefNode n) | a' == aid -> Just (symOf cx n)
      (RefNode n, RefArtifact a') | a' == aid -> Just (symOf cx n)
      _ -> Nothing

    hostDirOf aid =
      case [ p | x <- assocs, Just p <- [dirOf aid x]] of
        (h : _) -> Just h
        [] -> Nothing
    dirOf aid x = case (asSource x, asTarget x) of
      -- @data d from t@ is produced by the step: the association runs step →
      -- artifact. @… to t@ is consumed by it.
      (RefNode n, RefArtifact a') | a' == aid -> Just (symOf cx n, DataFrom)
      (RefArtifact a', RefNode n) | a' == aid -> Just (symOf cx n, DataTo)
      _ -> Nothing

flowItem :: Ctx -> SequenceFlow -> SItem
flowItem cx f =
  IFlow
    ( SFlow
        [loc (symOf cx (sfSource f)), loc (symOf cx (sfTarget f))]
        (sfName f)
        guard
        noSpan
    )
  where
    guard = case sfCondition f of
      Nothing -> Nothing
      Just FcDefault -> Just (loc GOtherwise)
      Just (FcExpression e) -> Just (loc (GWhen (unFeel e)))
