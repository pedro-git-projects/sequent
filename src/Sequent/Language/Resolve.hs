-- | Surface AST to semantic graph: resolve names, allocate ids, and turn the
-- language's structured control flow into the flat BPMN graph it means.
--
-- Three things happen here that nothing downstream can do:
--
--   * __Chaining.__ Consecutive steps in a body are joined by a sequence flow.
--     That is what removes the edge-list boilerplate: the author writes the
--     process, not the adjacency matrix.
--   * __Merge synthesis.__ A gateway block's merge gateway is derived, not
--     written. It exists exactly when two or more branches reach the end of the
--     block, and its symbolic name is @\<split\>_join@ unless the author named
--     it, so it has a stable id like every other element.
--   * __Id allocation.__ Every element gets its id here, through
--     "Sequent.Bpmn.Id", in a fixed class order so that adding an edge cannot
--     renumber a node.
--
-- Diagnostics are collected, never thrown: one run reports everything wrong
-- with the file rather than the first thing.
module Sequent.Language.Resolve
  ( resolveFile
  , ResolveResult (..)
  , PinSet (..)
  , emptyPins
  , pinFor
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Id
import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model
import Sequent.Diagnostic
import Sequent.Language.Syntax

-- | Manual layout pins (LAYOUT-025), kept beside the semantic graph rather
-- than inside it: a pin is a layout hint, not BPMN meaning.
newtype PinSet = PinSet {pinMap :: Map NodeId (Int, Int)}
  deriving (Eq, Show)

emptyPins :: PinSet
emptyPins = PinSet Map.empty

pinFor :: PinSet -> NodeId -> Maybe (Int, Int)
pinFor (PinSet m) i = Map.lookup i m

data ResolveResult = ResolveResult
  { rrGraph :: Maybe SemanticGraph
  , rrPins  :: PinSet
  , rrProvenance :: Provenance
  , rrDiags :: [Diagnostic]
  }

-- | Resolve a parsed file. The graph comes back only when nothing is an error;
-- warnings and advisories do not suppress it.
resolveFile :: SFile -> ResolveResult
resolveFile (SFile decls) =
  let (graph, st) = runR (buildGraph decls)
      ds = sortDiagnostics (reverse (rsDiags st))
   in ResolveResult
        { rrGraph = if hasErrors ds then Nothing else Just (canonicalise graph)
        , rrPins = PinSet (rsPins st)
        , rrProvenance = Provenance (rsNodeSpans st) (rsFlowSpans st)
        , rrDiags = ds
        }

-- The resolver monad ---------------------------------------------------------

data RState = RState
  { rsPool  :: IdPool
  , rsDiags :: [Diagnostic]
  , rsOrder :: !Int
  , rsPins  :: Map NodeId (Int, Int)
  , rsNodeSpans :: Map NodeId Span
  , rsFlowSpans :: Map FlowId Span
  }

newtype R a = R {unR :: RState -> (a, RState)}

instance Functor R where
  fmap f (R g) = R (\s -> let (a, s') = g s in (f a, s'))

instance Applicative R where
  pure a = R (\s -> (a, s))
  R f <*> R g = R (\s -> let (h, s1) = f s; (a, s2) = g s1 in (h a, s2))

instance Monad R where
  R g >>= k = R (\s -> let (a, s') = g s in unR (k a) s')

runR :: R a -> (a, RState)
runR (R f) = f (RState (reserve "Definitions_1" emptyPool) [] 0 Map.empty Map.empty Map.empty)

emit :: Diagnostic -> R ()
emit d = R (\s -> ((), s {rsDiags = d : rsDiags s}))

failAt :: DiagCategory -> Span -> Text -> R ()
failAt c sp m = emit (errorAt c sp m)

failHint :: DiagCategory -> Span -> Text -> Text -> R ()
failHint c sp m h = emit (withHint h (errorAt c sp m))

nextOrder :: R Int
nextOrder = R (\s -> (rsOrder s, s {rsOrder = rsOrder s + 1}))

freshId :: IdClass -> Text -> R Text
freshId c n = R (\s -> let (i, p) = alloc c n (rsPool s) in (i, s {rsPool = p}))

addPin :: NodeId -> (Int, Int) -> R ()
addPin i xy = R (\s -> ((), s {rsPins = Map.insert i xy (rsPins s)}))

noteNodeSpan :: NodeId -> Span -> R ()
noteNodeSpan i sp = R (\s -> ((), s {rsNodeSpans = Map.insert i sp (rsNodeSpans s)}))

noteFlowSpan :: FlowId -> Span -> R ()
noteFlowSpan i sp = R (\s -> ((), s {rsFlowSpans = Map.insert i sp (rsFlowSpans s)}))

flowSpan :: FlowId -> R (Maybe Span)
flowSpan i = R (\s -> (Map.lookup i (rsFlowSpans s), s))

-- Symbol table ---------------------------------------------------------------

-- | What a symbolic name denotes, once the declaration pass has seen it.
data Sym
  = SymNode NodeId SymNodeInfo
  | SymLane LaneId
  | SymArtifact ArtifactId
  | SymPool ParticipantId
  deriving (Eq, Show)

data SymNodeInfo = SymNodeInfo
  { sniKind  :: SymKind
  , sniSpan  :: Span
  , sniLabel :: Text
  }
  deriving (Eq, Show)

data SymKind
  = SkEvent NodeKw
  | SkTask NodeKw
  | SkSubprocess
  | SkGatewaySplit GwKw
  | SkGatewayJoin GwKw
  | SkBoundary
  deriving (Eq, Show)

type Symbols = Map Text Sym

-- | Root-level declarations, resolved by symbolic name.
data Roots = Roots
  { rootMessages :: Map Text MessageDef
  , rootSignals  :: Map Text SignalDef
  , rootErrors   :: Map Text ErrorDef
  , rootEscalations :: Map Text EscalationDef
  }

-- Top level ------------------------------------------------------------------

buildGraph :: [SDecl] -> R SemanticGraph
buildGraph decls = do
  checkDuplicateRoots decls
  roots <- buildRoots decls
  let procDecls = [p | DProcess p <- decls]
      collabDecls = [c | DCollaboration c <- decls]

  when (null procDecls && null collabDecls) $
    emit
      ( withHint
          "a file needs at least one: process name { ... }"
          (diagnostic Error SemanticError "no process or collaboration declared")
      )

  forM_ (drop 1 collabDecls) $ \c ->
    failAt SemanticError (locSpan (scName c)) "only one collaboration per file is supported"

  case collabDecls of
    (c : _) -> buildCollaboration roots c procDecls
    [] -> do
      procs <- mapM (buildProcess roots Nothing) procDecls
      pure (assemble roots Nothing (map bpProcess procs))

assemble :: Roots -> Maybe Collaboration -> [BpmnProcess] -> SemanticGraph
assemble roots col procs =
  SemanticGraph
    { sgCollaboration = col
    , sgProcesses = procs
    , sgMessages = Map.elems (rootMessages roots)
    , sgSignals = Map.elems (rootSignals roots)
    , sgErrors = Map.elems (rootErrors roots)
    , sgEscalations = Map.elems (rootEscalations roots)
    }

checkDuplicateRoots :: [SDecl] -> R ()
checkDuplicateRoots decls = go Set.empty (mapMaybe declName decls)
  where
    declName d = case d of
      DMessage n _ _ _ -> Just n
      DSignal n _ _ -> Just n
      DError n _ _ _ -> Just n
      DEscalation n _ _ _ -> Just n
      DProcess p -> Just (spName p)
      DCollaboration c -> Just (scName c)
      DComment _ -> Nothing
    go _ [] = pure ()
    go seen (n : ns)
      | Set.member (unLoc n) seen = do
          failAt NameResolutionError (locSpan n) ("duplicate declaration of '" <> unLoc n <> "'")
          go seen ns
      | otherwise = go (Set.insert (unLoc n) seen) ns

buildRoots :: [SDecl] -> R Roots
buildRoots decls = do
  ms <- forM [(n, nm, c) | DMessage n nm c _ <- decls] $ \(n, nm, c) -> do
    i <- freshId IcMessage (unLoc n)
    pure (unLoc n, MessageDef (NodeId i) nm (feel <$> c))
  ss <- forM [(n, nm) | DSignal n nm _ <- decls] $ \(n, nm) -> do
    i <- freshId IcSignal (unLoc n)
    pure (unLoc n, SignalDef (NodeId i) nm)
  es <- forM [(n, code, lbl) | DError n code lbl _ <- decls] $ \(n, code, lbl) -> do
    i <- freshId IcError (unLoc n)
    pure (unLoc n, ErrorDef (NodeId i) code (fromMaybe code lbl))
  xs <- forM [(n, code, lbl) | DEscalation n code lbl _ <- decls] $ \(n, code, lbl) -> do
    i <- freshId IcEscalation (unLoc n)
    pure (unLoc n, EscalationDef (NodeId i) code (fromMaybe code lbl))
  pure (Roots (Map.fromList ms) (Map.fromList ss) (Map.fromList es) (Map.fromList xs))

-- Collaboration --------------------------------------------------------------

buildCollaboration :: Roots -> SCollab -> [SProcess] -> R SemanticGraph
buildCollaboration roots c standalone = do
  colId <- freshId IcCollaboration (unLoc (scName c))
  let pools = [p | CPool p <- scItems c]
  parts <- forM (zip [0 ..] pools) $ \(k, p) -> do
    pid <- freshId IcParticipant (unLoc (poName p))
    pure (p, ParticipantId pid, k :: Int)

  built <- forM parts $ \(p, pid, k) -> case poBody p of
    Nothing -> pure (Participant pid (poLabel p) Nothing k, Nothing, Map.empty)
    Just body -> do
      proc <- buildProcess roots (Just (poName p)) (SProcess (poName p) (poLabel p) body (poSpan p))
      let syms = Map.fromList [(nm, s) | (nm, s) <- Map.toList (procSymbols proc)]
      pure (Participant pid (poLabel p) (Just (procId (bpProcess proc))) k, Just (bpProcess proc), syms)

  standaloneProcs <- mapM (buildProcess roots Nothing) standalone

  let participants = [pt | (pt, _, _) <- built]
      procs = [pr | (_, Just pr, _) <- built] ++ map bpProcess standaloneProcs
      poolOwner =
        Map.fromList
          [ (nm, partId pt)
          | (pt, _, syms) <- built
          , (nm, _) <- Map.toList syms
          ]
      allSyms = Map.unions ([syms | (_, _, syms) <- built] ++ map procSymbols standaloneProcs)
      poolSyms =
        Map.fromList [(unLoc (poName p), SymPool pid) | (p, pid, _) <- parts]

  mflows <- buildMessageFlows (Map.union poolSyms allSyms) poolOwner [m | CMessageFlow m <- scItems c]
  pure (assemble roots (Just (Collaboration colId participants mflows)) procs)

buildMessageFlows :: Symbols -> Map Text ParticipantId -> [SMsgFlow] -> R [MessageFlow]
buildMessageFlows syms owner ms0 = do
  ms <- reportDuplicateMessageFlows ms0
  fmap concat . forM ms $ \m -> do
    let look n = case Map.lookup (unLoc n) syms of
          Just (SymNode i _) -> Just (RefNode i, Map.lookup (unLoc n) owner)
          Just (SymPool pid) -> Just (RefParticipant pid, Just pid)
          _ -> Nothing
    case (look (mfFrom m), look (mfTo m)) of
      (Nothing, _) -> undefinedRef (mfFrom m) >> pure []
      (_, Nothing) -> undefinedRef (mfTo m) >> pure []
      (Just (a, pa), Just (b, pb)) -> do
        -- HC-008: a message flow always has endpoints in two different pools.
        -- This is a semantic error, not something geometry may repair.
        when (isJust pa && pa == pb) $
          failHint
            SemanticError
            (mfSpanS m)
            "a message flow must connect two different pools"
            "sequence flow (->) connects steps inside one pool; message flow (~>) connects pools"
        o <- nextOrder
        i <- freshId IcMessageFlow (allocFlowName (unLoc (mfFrom m)) (unLoc (mfTo m)))
        noteFlowSpan (FlowId i) (mfSpanS m)
        pure [MessageFlow (FlowId i) a b (mfLabelS m) Nothing o]

-- | The same rule as 'reportDuplicateFlows', for the @~>@ arrow: a second
-- message flow between one pair of endpoints is drawn on top of the first, so
-- the author sees one connector and the file carries two.
reportDuplicateMessageFlows :: [SMsgFlow] -> R [SMsgFlow]
reportDuplicateMessageFlows = go Map.empty
  where
    go _ [] = pure []
    go seen (m : rest) =
      let k = (unLoc (mfFrom m), unLoc (mfTo m))
       in case Map.lookup k seen of
            Just () -> do
              failHint
                SemanticError
                (mfSpanS m)
                ("'" <> fst k <> "' and '" <> snd k <> "' are already connected by a message flow")
                "one message flow per pair of endpoints; delete this line, or send it to a different step"
              go seen rest
            Nothing -> (m :) <$> go (Map.insert k () seen) rest

undefinedRef :: Name -> R ()
undefinedRef n =
  failHint
    NameResolutionError
    (locSpan n)
    ("undefined step '" <> unLoc n <> "'")
    "every name in a flow must be declared as a step somewhere in the process"

-- Process --------------------------------------------------------------------

data BuiltProcess = BuiltProcess
  { bpProcess :: BpmnProcess
  , procSymbols :: Symbols
  }

buildProcess :: Roots -> Maybe Name -> SProcess -> R BuiltProcess
buildProcess roots _pool p = do
  pid <- freshId IcProcess (unLoc (spName p))
  let declared = collectDeclarations (spBody p)
  reportDuplicates declared
  syms <- allocateSymbols declared
  lanes <- buildLanes declared syms
  (scope, _) <-
    buildScope roots syms (ScopeProcess (ProcessId pid)) Nothing (spBody p)
  let proc =
        BpmnProcess
          { procId = ProcessId pid
          , procName = spLabel p
          , procDoc = firstDoc (spBody p)
          , procExecutable = True
          , procLanes = lanes
          , procScope = scope
          }
  pure (BuiltProcess (assignOrphanLanes proc) syms)

firstDoc :: [SItem] -> Maybe Text
firstDoc items = case [t | IDoc t _ <- items] of
  (t : _) -> Just t
  [] -> Nothing

-- | Every name a process body declares, in document order, with what it
-- denotes. Collected before anything is built so that a step may refer forward
-- to a step declared later — which is what makes a loop back to an earlier
-- step and a jump to a later one both writable.
data Decl = Decl
  { dclName  :: Name
  , dclKind  :: DeclKind
  , dclLabel :: Maybe Text
  }

data DeclKind
  = DkNode SymKind
  | DkLane
  | -- | 'True' for a text annotation, 'False' for a data object. The two get
    -- different id prefixes, so the distinction has to survive to allocation.
    DkArtifact Bool
  deriving (Eq, Show)

collectDeclarations :: [SItem] -> [Decl]
collectDeclarations = concatMap one
  where
    one i = case i of
      IStep s -> step s
      IBoundary b ->
        Decl (bdAs b) (DkNode SkBoundary) (bdLabel b) : collectDeclarations (bdBody b)
      ILane l -> Decl (slName l) DkLane (slLabel l) : collectDeclarations (slBody l)
      INote n -> [Decl (snoName n) (DkArtifact True) Nothing]
      IData d -> [Decl (sdName d) (DkArtifact False) (sdLabel d)]
      _ -> []

    step s = case s of
      StNode n -> [Decl (snName n) (DkNode (kindOf (unLoc (snKind n)))) (snLabel n)]
      StSubprocess sub ->
        Decl (ssName sub) (DkNode SkSubprocess) (ssLabel sub) : collectDeclarations (ssBody sub)
      StGoto _ _ -> []
      StGateway g ->
        Decl (sgName g) (DkNode (SkGatewaySplit (unLoc (sgKind g)))) (sgLabel g)
          : [ Decl (joinName g) (DkNode (SkGatewayJoin (unLoc (sgKind g)))) Nothing
            ]
          ++ concatMap (maybe [] collectDeclarations . brBody) (branchesOf g)

    kindOf k
      | k `elem` [KwStart, KwEnd, KwWait, KwThrow] = SkEvent k
      | otherwise = SkTask k

-- | The symbolic name of a gateway's derived merge. Deriving it from the split
-- keeps the merge's id as stable as everything else, and lets a @goto@ target
-- it without the author having to name it.
joinName :: SGateway -> Name
joinName g = case sgJoin g of
  Just n -> n
  Nothing -> (sgName g) {unLoc = unLoc (sgName g) <> "_join"}

-- | A repeated @lane@ block re-enters an existing lane rather than declaring a
-- new one — a process that hands work back and forth between two roles has to
-- be writable without inventing a second name for the same role. Every other
-- repeated name, including a lane name that collides with a step, is a
-- duplicate.
reportDuplicates :: [Decl] -> R ()
reportDuplicates = go Map.empty
  where
    go _ [] = pure ()
    go seen (d : ds) = case Map.lookup (unLoc (dclName d)) seen of
      Just DkLane | dclKind d == DkLane -> go seen ds
      Just _ -> do
        failAt
          NameResolutionError
          (locSpan (dclName d))
          ("duplicate declaration of '" <> unLoc (dclName d) <> "'")
        go seen ds
      Nothing -> go (Map.insert (unLoc (dclName d)) (dclKind d) seen) ds

-- | Allocate every id for a process, class by class. Within a class the order
-- is document order; across classes it is 'allocationClasses'. Adding a step of
-- one class therefore cannot perturb the ids of another.
allocateSymbols :: [Decl] -> R Symbols
allocateSymbols declared = do
  let unique = dedupe declared
      inClass c = [(k, d) | (k, d) <- zip [0 :: Int ..] unique, classOf (dclKind d) == Just c]
  entries <- fmap concat . forM allocationClasses $ \c ->
    forM (sortOn fst (inClass c)) $ \(_, d) -> do
      i <- freshId c (unLoc (dclName d))
      let sym = symFor i d
      case sym of
        SymNode nid _ -> noteNodeSpan nid (locSpan (dclName d))
        _ -> pure ()
      pure (unLoc (dclName d), sym)
  pure (Map.fromList entries)
  where
    dedupe = go Set.empty
      where
        go _ [] = []
        go seen (d : ds)
          | Set.member (unLoc (dclName d)) seen = go seen ds
          | otherwise = d : go (Set.insert (unLoc (dclName d)) seen) ds

    symFor i d = case dclKind d of
      DkLane -> SymLane (LaneId i)
      DkArtifact _ -> SymArtifact (ArtifactId i)
      DkNode k -> SymNode (NodeId i) (SymNodeInfo k (locSpan (dclName d)) (unLoc (dclName d)))

classOf :: DeclKind -> Maybe IdClass
classOf k = case k of
  DkLane -> Just IcLane
  DkArtifact True -> Just IcTextAnnotation
  DkArtifact False -> Just IcDataObjectRef
  DkNode s -> Just (nodeClass s)

nodeClass :: SymKind -> IdClass
nodeClass s = case s of
  SkEvent KwStart -> IcStartEvent
  SkEvent KwEnd -> IcEndEvent
  SkEvent _ -> IcIntermediateEvent
  SkBoundary -> IcBoundaryEvent
  SkGatewaySplit _ -> IcGateway
  SkGatewayJoin _ -> IcGateway
  SkSubprocess -> IcActivity
  SkTask _ -> IcActivity

-- | LANE-005: input order is the lane order, and it is the order of first
-- appearance in the source.
buildLanes :: [Decl] -> Symbols -> R [Lane]
buildLanes declared syms =
  pure
    [ Lane l (dclLabel d) k []
    | (k, d) <- zip [0 ..] (firstOfEach [x | x <- declared, dclKind x == DkLane])
    , Just (SymLane l) <- [Map.lookup (unLoc (dclName d)) syms]
    ]
  where
    firstOfEach = go Set.empty
      where
        go _ [] = []
        go seen (d : ds)
          | Set.member (unLoc (dclName d)) seen = go seen ds
          | otherwise = d : go (Set.insert (unLoc (dclName d)) seen) ds

-- | SPEC §I.2 "Node in no lane": assign it to the lane of its highest-ranked
-- predecessor, else the first lane, and report. Done here so the semantic graph
-- is complete before layout rather than patched during it.
assignOrphanLanes :: BpmnProcess -> BpmnProcess
assignOrphanLanes p = case procLanes p of
  [] -> p
  (l0 : _) -> p {procScope = fixScope (laneId l0) (procScope p)}
  where
    fixScope firstLane sc = sc {scNodes = reverse (fst (foldl' step ([], Map.empty) (scNodes sc)))}
      where
        preds = Map.fromListWith (++) [(sfTarget f, [sfSource f]) | f <- scFlows sc]
        hosts = Map.fromList [(fnId n, baHost a) | n <- scNodes sc, Just a <- [boundaryHost n]]
        step (acc, seen) n = case fnLane n of
          Just l -> (n : acc, Map.insert (fnId n) l seen)
          Nothing ->
            let sources = case Map.lookup (fnId n) hosts of
                  Just h -> [h]
                  Nothing -> Map.findWithDefault [] (fnId n) preds
                l = case mapMaybe (`Map.lookup` seen) sources of
                  (x : _) -> x
                  [] -> firstLane
             in (n {fnLane = Just l} : acc, Map.insert (fnId n) l seen)

-- Scope building -------------------------------------------------------------

-- | A dangling path end waiting for its next step, carrying the label and
-- guard the branch that opened it declared.
data Pending = Pending
  { pdFrom     :: NodeId
  , pdLabel    :: Maybe Text
  , pdGuard    :: Maybe FlowCondition
  , pdPriority :: Maybe Int
  , pdName     :: Text
  }

-- | Accumulated pieces of one scope while walking its body.
data Acc = Acc
  { accNodes  :: [FlowNode]
  , accFlows  :: [SequenceFlow]
  , accArts   :: [Artifact]
  , accAssocs :: [Association]
  }

emptyAcc :: Acc
emptyAcc = Acc [] [] [] []

instance Semigroup Acc where
  a <> b = Acc (accNodes a ++ accNodes b) (accFlows a ++ accFlows b) (accArts a ++ accArts b) (accAssocs a ++ accAssocs b)

instance Monoid Acc where
  mempty = emptyAcc

-- | Build one scope (a process body or a subprocess body) and return it plus
-- the path ends left dangling at the end of the body.
buildScope :: Roots -> Symbols -> ScopeId -> Maybe LaneId -> [SItem] -> R (Scope, [Pending])
buildScope roots syms sid lane body = do
  (acc, pend) <- runBody roots syms lane [] body
  reportDuplicateFlows syms (accFlows acc)
  pure
    ( Scope
        { scId = sid
        , scNodes = accNodes acc
        , scFlows = accFlows acc
        , scArtifacts = accArts acc
        , scAssociations = accAssocs acc
        }
    , pend
    )

runBody :: Roots -> Symbols -> Maybe LaneId -> [Pending] -> [SItem] -> R (Acc, [Pending])
runBody roots syms lane = go
  where
    go pend [] = pure (mempty, pend)
    go pend (i : is) = do
      (acc1, pend1) <- one pend i
      (acc2, pend2) <- go pend1 is
      pure (acc1 <> acc2, pend2)

    one pend i = case i of
      -- Comments are carried through the tree for the formatter's benefit and
      -- mean nothing here.
      IComment _ -> pure (mempty, pend)
      IDoc _ _ -> pure (mempty, pend)
      IPin pn -> do
        withNode (spinNode pn) $ \nid _ -> addPin nid (spinX pn, spinY pn)
        pure (mempty, pend)
      ILane l -> case Map.lookup (unLoc (slName l)) syms of
        Just (SymLane lid) -> runBody roots syms (Just lid) pend (slBody l)
        _ -> pure (mempty, pend)
      IFlow f -> do
        acc <- explicitFlows syms f
        pure (acc, pend)
      IBoundary b -> do
        acc <- boundaryHandler roots syms lane b
        pure (acc, pend)
      INote n -> do
        acc <- noteArtifact syms lane n
        pure (acc, pend)
      IData d -> do
        acc <- dataArtifact syms lane d
        pure (acc, pend)
      IStep s -> stepItem pend s

    stepItem pend s = case s of
      StGoto n _ -> do
        acc <- case Map.lookup (unLoc n) syms of
          Just (SymNode nid _) -> connectAll (stepSpan s) pend nid (unLoc n)
          _ -> undefinedRef n >> pure mempty
        pure (acc, [])
      StNode n -> do
        (node, acc0) <- makeNode roots syms lane n
        acc1 <- connectAll (snSpan n) pend (fnId node) (unLoc (snName n))
        let ends = if isEndEvent node then [] else [pendingOf node (unLoc (snName n))]
        pure (acc0 {accNodes = node : accNodes acc0} <> acc1, ends)
      StSubprocess sub -> do
        (node, acc0) <- makeSubprocess roots syms lane sub
        acc1 <- connectAll (ssSpan sub) pend (fnId node) (unLoc (ssName sub))
        pure (acc0 {accNodes = node : accNodes acc0} <> acc1, [pendingOf node (unLoc (ssName sub))])
      StGateway g -> gateway pend g

    gateway pend g = do
      split <- case Map.lookup (unLoc (sgName g)) syms of
        Just (SymNode nid _) -> pure nid
        _ -> pure (NodeId "")
      o <- nextOrder
      let kind = gwKindOf (unLoc (sgKind g))
          splitNode =
            FlowNode split (sgLabel g) Nothing (NkGateway kind) lane o noExecution
      accIn <- connectAll (sgSpan g) pend split (unLoc (sgName g))
      when (null (branchesOf g)) $
        failHint
          SemanticError
          (sgSpan g)
          ("gateway '" <> unLoc (sgName g) <> "' has no branches")
          "write at least two: branch \"yes\" when \"=cond\" { ... }"
      branchResults <- forM (branchesOf g) $ \b -> do
        cond <- guardCondition (unLoc (sgKind g)) g b
        let seed =
              Pending
                { pdFrom = split
                , pdLabel = brLabel b
                , pdGuard = cond
                , pdPriority = brPriority b
                , pdName = unLoc (sgName g)
                }
        runBody roots syms lane [seed] (fromMaybe [] (brBody b))
      let accBranches = mconcat (map fst branchResults)
          continuing = concatMap snd branchResults
      if length continuing >= 2 || isJust (sgJoin g)
        then do
          mo <- nextOrder
          let jn = joinName g
          case Map.lookup (unLoc jn) syms of
            Just (SymNode jid _) -> do
              let joinNode =
                    FlowNode jid Nothing Nothing (NkGateway (joinKind kind)) lane mo noExecution
              accJoin <- connectAll (sgSpan g) continuing jid (unLoc jn)
              pure
                ( accIn
                    <> mempty {accNodes = [splitNode]}
                    <> accBranches
                    <> mempty {accNodes = [joinNode]}
                    <> accJoin
                , [Pending jid Nothing Nothing Nothing (unLoc jn)]
                )
            _ -> pure (accIn <> mempty {accNodes = [splitNode]} <> accBranches, continuing)
        else pure (accIn <> mempty {accNodes = [splitNode]} <> accBranches, continuing)

    withNode n k = case Map.lookup (unLoc n) syms of
      Just (SymNode nid info) -> k nid info
      _ -> undefinedRef n

pendingOf :: FlowNode -> Text -> Pending
pendingOf n nm = Pending (fnId n) Nothing Nothing Nothing nm

-- | Connect every dangling end to a node, carrying each end's label and guard
-- onto its flow.
connectAll :: Span -> [Pending] -> NodeId -> Text -> R Acc
connectAll sp pend target tname = do
  fs <- forM pend $ \p -> do
    o <- nextOrder
    i <- freshId IcSequenceFlow (allocFlowName (pdName p) tname)
    noteFlowSpan (FlowId i) sp
    pure
      SequenceFlow
        { sfId = FlowId i
        , sfSource = pdFrom p
        , sfTarget = target
        , sfName = pdLabel p
        , sfCondition = pdGuard p
        , sfDocOrder = o
        , sfPriority = pdPriority p
        }
  pure mempty {accFlows = fs}

-- | Two sequence flows between the same pair of steps, in one scope.
--
-- Almost always the author writing a connection the language had already made:
-- steps chain implicitly, so @flow a -> b@ under @task a@ / @task b@ adds a
-- /second/ edge rather than restating the first. What makes it worth an error
-- rather than a shrug is that the second edge usually carries the intent — a
-- label, a condition — and silently having two edges means that intent lands on
-- a connector nobody sees.
--
-- The compiler also cannot draw it. Two connectors between one pair of steps
-- leave the same port and arrive at the same port, so they are collinear by
-- construction (HC-009) and no channel assignment separates them. Rejecting it
-- here, at the line that wrote it, beats a geometry violation eight phases later
-- that can only name an element id.
reportDuplicateFlows :: Symbols -> [SequenceFlow] -> R ()
reportDuplicateFlows syms fs =
  forM_ [(kept, dup) | kept : dups <- Map.elems grouped, dup <- dups] $ \(kept, dup) -> do
    sp <- flowSpan (sfId dup)
    let msg =
          "'" <> nameOf (sfSource dup) <> "' and '" <> nameOf (sfTarget dup)
            <> "' are already connected"
        hint
          | decorated kept && decorated dup =
              "combine the two conditions into one branch, or give the paths different targets"
          | decorated dup =
              "put the label or condition on the connection that already exists, or send this path to a different step"
          | otherwise =
              "consecutive steps are connected without writing a flow; delete this line"
    emit (withHint hint (maybe id (\x d -> d {diagSpan = Just x}) sp (errorAt SemanticError noSpan msg)))
  where
    grouped =
      Map.fromListWith
        (flip (++))
        [((sfSource f, sfTarget f), [f]) | f <- sortOn sfDocOrder fs]
    decorated f = isJust (sfName f) || isJust (sfCondition f)
    byNode = Map.fromList [(i, n) | (n, SymNode i _) <- Map.toList syms]
    nameOf i = Map.findWithDefault (unNodeId i) i byNode

gwKindOf :: GwKw -> GatewayKind
gwKindOf k = case k of
  KwXor -> GwExclusive
  KwAnd -> GwParallel
  KwOr -> GwInclusive
  KwEventGw -> GwEventBased
  KwComplex -> GwComplex

-- | An event-based gateway cannot join; its merge is an exclusive gateway,
-- which is what BPMN requires and what every modeller draws.
joinKind :: GatewayKind -> GatewayKind
joinKind GwEventBased = GwExclusive
joinKind k = k

-- | Turn a branch guard into a flow condition, rejecting the combinations BPMN
-- does not have.
guardCondition :: GwKw -> SGateway -> SBranch -> R (Maybe FlowCondition)
guardCondition gk g b = case brGuard b of
  Nothing -> pure Nothing
  Just lg -> case unLoc lg of
    GOtherwise
      | gk `elem` [KwXor, KwOr, KwComplex] -> pure (Just FcDefault)
      | otherwise -> do
          failHint
            SemanticError
            (locSpan lg)
            ("a default branch is only meaningful on an xor, or or complex gateway, not on "
               <> gatewayKeyword gk)
            "every branch of a parallel gateway is taken, so there is nothing to default to"
          pure Nothing
    GWhen e
      | gk `elem` [KwXor, KwOr, KwComplex] -> pure (Just (FcExpression (feel e)))
      | otherwise -> do
          failHint
            SemanticError
            (locSpan lg)
            ("a 'when' condition is only allowed on a branch of an xor, or or complex gateway, not "
               <> gatewayKeyword gk
               <> " '" <> unLoc (sgName g) <> "'")
            "an event gateway selects by which event arrives first; a parallel gateway takes every branch"
          pure Nothing

-- Explicit flows -------------------------------------------------------------

explicitFlows :: Symbols -> SFlow -> R Acc
explicitFlows syms f = do
  let names = sfNodes f
      pairs = zip names (drop 1 names)
      decorated = length names == 2
  unless (decorated || (sfLabelF f == Nothing && sfGuard f == Nothing)) $
    failHint
      SemanticError
      (sfSpan f)
      "a label or condition needs a single flow, not a chain"
      "split the chain: flow a -> b \"yes\" when \"=ok\""
  fs <- fmap concat . forM pairs $ \(a, b) ->
    case (Map.lookup (unLoc a) syms, Map.lookup (unLoc b) syms) of
      (Just (SymNode ai _), Just (SymNode bi _)) -> do
        o <- nextOrder
        i <- freshId IcSequenceFlow (allocFlowName (unLoc a) (unLoc b))
        noteFlowSpan (FlowId i) (sfSpan f)
        cond <- if decorated then explicitGuard syms a (sfGuard f) else pure Nothing
        pure
          [ SequenceFlow
              { sfId = FlowId i
              , sfSource = ai
              , sfTarget = bi
              , sfName = if decorated then sfLabelF f else Nothing
              , sfCondition = cond
              , sfDocOrder = o
              , sfPriority = Nothing
              }
          ]
      (ma, mb) -> do
        maybe (undefinedRef a) (const (pure ())) ma
        maybe (undefinedRef b) (const (pure ())) mb
        pure []
  pure mempty {accFlows = fs}

explicitGuard :: Symbols -> Name -> Maybe (Located SGuard) -> R (Maybe FlowCondition)
explicitGuard _ _ Nothing = pure Nothing
explicitGuard syms src (Just lg) = do
  let ok = case Map.lookup (unLoc src) syms of
        Just (SymNode _ info) -> case sniKind info of
          SkGatewaySplit k -> k `elem` [KwXor, KwOr, KwComplex]
          SkGatewayJoin k -> k `elem` [KwXor, KwOr, KwComplex]
          SkTask _ -> True
          _ -> False
        _ -> True
  if ok
    then pure . Just $ case unLoc lg of
      GOtherwise -> FcDefault
      GWhen e -> FcExpression (feel e)
    else do
      failAt
        SemanticError
        (locSpan lg)
        ("a condition is only allowed on a flow leaving a data-based gateway or an activity, not '"
           <> unLoc src <> "'")
      pure Nothing

-- Boundary events ------------------------------------------------------------

boundaryHandler :: Roots -> Symbols -> Maybe LaneId -> SBoundary -> R Acc
boundaryHandler roots syms lane b = do
  host <- case Map.lookup (unLoc (bdHost b)) syms of
    Just (SymNode hid info) -> do
      -- HC-006 / LAYOUT-016 presuppose a host with a border to hang on.
      case sniKind info of
        SkTask _ -> pure ()
        SkSubprocess -> pure ()
        k ->
          failHint
            SemanticError
            (locSpan (bdHost b))
            ("a boundary event attaches to a task or subprocess, not to " <> describeKind k)
            "move the catch onto the activity that can fail"
      pure (Just hid)
    _ -> undefinedRef (bdHost b) >> pure Nothing
  case (host, Map.lookup (unLoc (bdAs b)) syms) of
    (Just hid, Just (SymNode bid _)) -> do
      o <- nextOrder
      trig <- resolveTrigger roots (locSpan (bdTrigger b)) (unLoc (bdTrigger b))
      let node =
            FlowNode
              { fnId = bid
              , fnName = bdLabel b
              , fnDoc = Nothing
              , fnKind =
                  NkEvent
                    (EventSpec (EvBoundary (BoundaryAttachment hid (not (bdNonInt b)))) trig)
              , fnLane = lane
              , fnDocOrder = o
              , fnExec = noExecution
              }
      when (null (bdBody b)) $
        emit
          ( withHint
              "put the handler steps in the block: on t catch ... as e { service compensate ... }"
              (warnAt SemanticError (bdSpan b) "boundary event handler is empty")
          )
      (acc, _) <- runBody roots syms lane [pendingOf node (unLoc (bdAs b))] (bdBody b)
      pure (mempty {accNodes = [node]} <> acc)
    _ -> pure mempty

describeKind :: SymKind -> Text
describeKind k = case k of
  SkEvent kw -> "the " <> nodeKeyword kw <> " event"
  SkTask kw -> "the " <> nodeKeyword kw <> " task"
  SkSubprocess -> "a subprocess"
  SkGatewaySplit kw -> "the " <> gatewayKeyword kw <> " gateway"
  SkGatewayJoin kw -> "the merge of the " <> gatewayKeyword kw <> " gateway"
  SkBoundary -> "a boundary event"

-- Artifacts ------------------------------------------------------------------

noteArtifact :: Symbols -> Maybe LaneId -> SNote -> R Acc
noteArtifact syms lane n = case (Map.lookup (unLoc (snoName n)) syms, Map.lookup (unLoc (snoOn n)) syms) of
  (Just (SymArtifact aid), Just (SymNode host _)) -> do
    o <- nextOrder
    ao <- nextOrder
    i <- freshId IcAssociation (allocFlowName (unLoc (snoName n)) (unLoc (snoOn n)))
    pure
      mempty
        { accArts = [Artifact aid AkTextAnnotation Nothing (Just (snoText n)) o lane]
        , accAssocs = [Association (FlowId i) (RefArtifact aid) (RefNode host) AdNone ao]
        }
  (_, Nothing) -> undefinedRef (snoOn n) >> pure mempty
  _ -> pure mempty

dataArtifact :: Symbols -> Maybe LaneId -> SData -> R Acc
dataArtifact syms lane d = case (Map.lookup (unLoc (sdName d)) syms, Map.lookup (unLoc (sdOn d)) syms) of
  (Just (SymArtifact aid), Just (SymNode host _)) -> do
    o <- nextOrder
    ao <- nextOrder
    i <- freshId IcAssociation (allocFlowName (unLoc (sdName d)) (unLoc (sdOn d)))
    let (src, tgt) = case sdDir d of
          DataFrom -> (RefNode host, RefArtifact aid)
          DataTo -> (RefArtifact aid, RefNode host)
    pure
      mempty
        { accArts = [Artifact aid AkDataObject (sdLabel d) Nothing o lane]
        , accAssocs = [Association (FlowId i) src tgt AdOne ao]
        }
  (_, Nothing) -> undefinedRef (sdOn d) >> pure mempty
  _ -> pure mempty

-- Nodes ----------------------------------------------------------------------

makeSubprocess :: Roots -> Symbols -> Maybe LaneId -> SSub -> R (FlowNode, Acc)
makeSubprocess roots syms lane sub = do
  o <- nextOrder
  nid <- case Map.lookup (unLoc (ssName sub)) syms of
    Just (SymNode i _) -> pure i
    _ -> pure (NodeId "")
  (inner, _) <- buildScope roots syms (ScopeSubprocess nid) lane (ssBody sub)
  pure
    ( FlowNode
        { fnId = nid
        , fnName = ssLabel sub
        , fnDoc = firstDoc (ssBody sub)
        , fnKind = NkActivity (Activity (AkSubprocess inner) Nothing)
        , fnLane = lane
        , fnDocOrder = o
        , fnExec = noExecution
        }
    , mempty
    )

makeNode :: Roots -> Symbols -> Maybe LaneId -> SNode -> R (FlowNode, Acc)
makeNode roots syms lane n = do
  o <- nextOrder
  nid <- case Map.lookup (unLoc (snName n)) syms of
    Just (SymNode i _) -> pure i
    _ -> pure (NodeId "")
  let props = snProps n
      kw = unLoc (snKind n)
  mapM_ (checkPropAllowed kw n) props
  (kind, execMeta) <- nodeKind roots n kw props
  pure
    ( FlowNode
        { fnId = nid
        , fnName = snLabel n
        , fnDoc = firstOf [t | SProp _ (PDoc t) <- props]
        , fnKind = kind
        , fnLane = lane
        , fnDocOrder = o
        , fnExec = execMeta
        }
    , mempty
    )

firstOf :: [a] -> Maybe a
firstOf (x : _) = Just x
firstOf [] = Nothing

-- | Which properties each step keyword accepts. Rejecting a misplaced property
-- at its own span beats letting it vanish silently into the XML.
allowedProps :: NodeKw -> [Text]
allowedProps k = case k of
  KwStart -> ["message", "timer", "signal", "link", "escalation", "doc"]
  -- Camunda 8 implements a /throwing/ message event as a job: the broker
  -- creates one and a worker publishes the message. So an end or throw step
  -- carrying a message takes the job metadata a service task takes, and a
  -- deployment without it is rejected. Which events may actually use it is a
  -- Camunda rule rather than a syntactic one, and lives in
  -- "Sequent.Camunda.Validate".
  KwEnd -> ["message", "signal", "error", "escalation", "link", "terminate", "compensation", "type", "retries", "input", "output", "header", "doc"]
  KwWait -> ["message", "timer", "signal", "link", "escalation", "doc"]
  KwThrow -> ["message", "signal", "escalation", "link", "compensation", "type", "retries", "input", "output", "header", "doc"]
  KwService -> ["type", "retries", "input", "output", "header", "each", "collect", "doc"]
  KwUser -> ["form", "assignee", "groups", "users", "due", "input", "output", "each", "collect", "doc"]
  -- Camunda 8 lets a script or a business-rule task be implemented either by
  -- the broker (a FEEL expression, a DMN decision) or by a job worker, and the
  -- second form is an ordinary @zeebe:taskDefinition@. Both spellings are
  -- accepted here; 'nodeKind' rejects a step that gives both, because only one
  -- of them would reach the XML.
  KwScript -> ["expression", "result", "type", "retries", "input", "output", "header", "each", "collect", "doc"]
  KwBusiness -> ["decision", "result", "type", "retries", "input", "output", "header", "each", "collect", "doc"]
  KwSend -> ["type", "retries", "input", "output", "header", "each", "collect", "doc"]
  KwReceive -> ["message", "each", "collect", "doc"]
  KwCall -> ["calls", "propagate", "input", "output", "each", "collect", "doc"]
  KwManual -> ["each", "collect", "doc"]
  KwTask -> ["each", "collect", "doc"]

checkPropAllowed :: NodeKw -> SNode -> SProp -> R ()
checkPropAllowed _ _ (SProp _ (PComment _)) = pure ()
checkPropAllowed k n (SProp sp b)
  | propKeyword b `elem` allowedProps k = pure ()
  | otherwise =
      failHint
        SemanticError
        sp
        ("'" <> propKeyword b <> "' is not a property of a " <> nodeKeyword k <> " step")
        ( "a "
            <> nodeKeyword k
            <> " step accepts: "
            <> T.intercalate ", " (allowedProps k)
            <> " (on '"
            <> unLoc (snName n)
            <> "')"
        )

nodeKind :: Roots -> SNode -> NodeKw -> [SProp] -> R (NodeKind, ExecutionMeta)
nodeKind roots n kw props = case kw of
  KwStart -> eventOf EvStart
  KwEnd -> eventOf EvEnd
  KwWait -> eventOf EvIntermediateCatch
  KwThrow -> eventOf EvIntermediateThrow
  KwTask -> plain TtAbstract
  KwManual -> plain TtManual
  KwService -> do
    z <- serviceTask
    pure (NkActivity (Activity (AkTask TtService) loop), ExService z)
  KwSend -> do
    z <- serviceTask
    pure (NkActivity (Activity (AkTask TtSend) loop), ExService z)
  KwUser ->
    pure
      ( NkActivity (Activity (AkTask TtUser) loop)
      , ExUser
          UserTaskSpec
            { utForm = firstOf [v | SProp _ (PForm v) <- props]
            , utAssignee = feel <$> firstOf [v | SProp _ (PAssignee v) <- props]
            , utCandidateGroups = feel <$> firstOf [v | SProp _ (PGroups v) <- props]
            , utCandidateUsers = feel <$> firstOf [v | SProp _ (PUsers v) <- props]
            , utDueDate = feel <$> firstOf [v | SProp _ (PDue v) <- props]
            , utInputs = inputs
            , utOutputs = outputs
            }
      )
  KwScript -> case firstOf [(sp, v) | SProp sp (PExpression v) <- props] of
    Just (_, e) -> do
      onlyOne "expression"
      pure
        ( NkActivity (Activity (AkTask TtScript) loop)
        , ExScript (ScriptSpec (feel e) (fromMaybe "result" (firstOf [v | SProp _ (PResult v) <- props])) inputs outputs)
        )
    Nothing
      | any isType props -> do
          z <- serviceTask
          pure (NkActivity (Activity (AkTask TtScript) loop), ExService z)
      | otherwise -> do
          needs "expression" "expression \"=total * 0.2\" (or 'type' for a job worker)"
          pure (NkActivity (Activity (AkTask TtScript) loop), noExecution)
  KwBusiness -> case firstOf [(sp, v) | SProp sp (PDecision v) <- props] of
    Just (_, d) -> do
      onlyOne "decision"
      pure
        ( NkActivity (Activity (AkTask TtBusinessRule) loop)
        , ExDecision (DecisionSpec d (fromMaybe "result" (firstOf [v | SProp _ (PResult v) <- props])) inputs outputs)
        )
    Nothing
      | any isType props -> do
          z <- serviceTask
          pure (NkActivity (Activity (AkTask TtBusinessRule) loop), ExService z)
      | otherwise -> do
          needs "decision" "decision \"credit-scoring\" (or 'type' for a job worker)"
          pure (NkActivity (Activity (AkTask TtBusinessRule) loop), noExecution)
  KwCall -> case firstOf [(sp, v) | SProp sp (PCalls v) <- props] of
    Nothing -> do
      needs "calls" "calls \"shipping-process\""
      pure (NkActivity (Activity AkCallActivity loop), noExecution)
    Just (_, target) ->
      pure
        ( NkActivity (Activity AkCallActivity loop)
        , ExCall (CalledElement target (any isPropagate props) inputs outputs)
        )
  KwReceive -> do
    m <- case firstOf [(sp, v) | SProp sp (PMessage v) <- props] of
      Nothing -> do
        needs "message" "message order_placed"
        pure Nothing
      Just (sp, v) -> fmap msgId <$> lookupMessage roots sp v
    pure (NkActivity (Activity (AkTask (TtReceive m)) loop), noExecution)
  where
    plain t = pure (NkActivity (Activity (AkTask t) loop), noExecution)

    isPropagate (SProp _ PPropagate) = True
    isPropagate _ = False

    needs what example =
      failHint
        SemanticError
        (locSpan (snName n))
        ("a " <> nodeKeyword kw <> " step needs a '" <> what <> "' property")
        ("add it inside the block: " <> example)

    -- A step that names both implementations would serialise as one of them,
    -- and the reader of the source would have no way to tell which.
    onlyOne other = case firstOf [sp | SProp sp (PType _) <- props] of
      Nothing -> pure ()
      Just sp ->
        failHint
          SemanticError
          sp
          ("a " <> nodeKeyword kw <> " step is implemented by '" <> other <> "' or by 'type', not both")
          ("drop one: '" <> other <> "' runs in the broker, 'type' hands the work to a job worker")

    inputs = [Mapping t (feel src) | SProp _ (PInput t src) <- props]
    outputs = [Mapping t (feel src) | SProp _ (POutput t src) <- props]

    loop = case firstOf [(v, coll, sq) | SProp _ (PEach v coll sq) <- props] of
      Nothing -> Nothing
      Just (v, coll, sq) ->
        Just
          LoopSpec
            { lsSequential = sq
            , lsInputCollection = feel coll
            , lsInputElement = v
            , lsOutputCollection = firstOf [c | SProp _ (PCollect c _) <- props]
            , lsOutputElement = feel <$> firstOf [e | SProp _ (PCollect _ e) <- props]
            }

    serviceTask = case firstOf [(sp, v) | SProp sp (PType v) <- props] of
      Nothing -> do
        needs "type" "type \"order-validate\""
        pure (emptyZeebeTask "")
      Just (_, t) ->
        pure
          ZeebeTask
            { ztType = t
            , ztRetries = firstOf [r | SProp _ (PRetries r) <- props]
            , ztInputs = inputs
            , ztOutputs = outputs
            , ztHeaders = [Header k v | SProp _ (PHeader k v) <- props]
            }

    eventOf flavour = do
      d <- eventDefinition roots n props
      ex <-
        if any isType props
          then ExService <$> serviceTask
          else pure noExecution
      pure (NkEvent (EventSpec flavour d), ex)

    isType (SProp _ (PType _)) = True
    isType _ = False

-- | An event carries at most one definition. Which keywords are legal on which
-- event is settled by 'allowedProps'; this only turns the survivor into a
-- definition and rejects a second one.
eventDefinition :: Roots -> SNode -> [SProp] -> R (Maybe EventDefinition)
eventDefinition roots n props = case candidates of
  [] -> pure Nothing
  ((_, act) : rest) -> do
    forM_ rest $ \(sp, _) ->
      failAt SemanticError sp ("event '" <> unLoc (snName n) <> "' already has a trigger")
    act
  where
    candidates = mapMaybe pick props
    pick (SProp sp b) = case b of
      PMessage v -> Just (sp, fmap (fmap (EdMessage . msgId)) (lookupMessage roots sp v))
      PSignal v -> Just (sp, fmap (fmap (EdSignal . sigId)) (lookupSignal roots sp v))
      PError v -> Just (sp, fmap (fmap (EdError . Just . errId)) (lookupError roots sp v))
      PEscalation v -> Just (sp, fmap (fmap (EdEscalation . Just . escId)) (lookupEscalation roots sp v))
      PTimer v -> Just (sp, pure (Just (EdTimer (timerDef v))))
      PLink v -> Just (sp, pure (Just (EdLink v)))
      PTerminate -> Just (sp, pure (Just EdTerminate))
      PCompensation -> Just (sp, pure (Just EdCompensation))
      _ -> Nothing

resolveTrigger :: Roots -> Span -> STrigger -> R (Maybe EventDefinition)
resolveTrigger roots sp t = case t of
  TgMessage v -> fmap (EdMessage . msgId) <$> lookupMessage roots sp v
  TgSignal v -> fmap (EdSignal . sigId) <$> lookupSignal roots sp v
  TgError v -> fmap (EdError . Just . errId) <$> lookupError roots sp v
  TgEscalation v -> fmap (EdEscalation . Just . escId) <$> lookupEscalation roots sp v
  TgTimer v -> pure (Just (EdTimer (timerDef v)))

-- | @R…@ is an ISO-8601 repeating cycle, @P…@ a duration, anything else a date.
timerDef :: Text -> TimerDef
timerDef v
  | T.isPrefixOf "R" v = TimerCycle v
  | T.isPrefixOf "P" v = TimerDuration v
  | otherwise = TimerDate v

lookupMessage :: Roots -> Span -> Text -> R (Maybe MessageDef)
lookupMessage roots sp v = case Map.lookup v (rootMessages roots) of
  Just m -> pure (Just m)
  Nothing -> do
    failHint
      NameResolutionError
      sp
      ("undeclared message '" <> v <> "'")
      ("declare it at the top of the file: message " <> v <> " \"wire-name\" correlation \"=key\"")
    pure Nothing

lookupSignal :: Roots -> Span -> Text -> R (Maybe SignalDef)
lookupSignal roots sp v = case Map.lookup v (rootSignals roots) of
  Just m -> pure (Just m)
  Nothing -> do
    failHint
      NameResolutionError
      sp
      ("undeclared signal '" <> v <> "'")
      ("declare it at the top of the file: signal " <> v <> " \"wire-name\"")
    pure Nothing

lookupError :: Roots -> Span -> Text -> R (Maybe ErrorDef)
lookupError roots sp v = case Map.lookup v (rootErrors roots) of
  Just m -> pure (Just m)
  Nothing -> do
    failHint
      NameResolutionError
      sp
      ("undeclared error '" <> v <> "'")
      ("declare it at the top of the file: error " <> v <> " \"ERROR_CODE\"")
    pure Nothing

lookupEscalation :: Roots -> Span -> Text -> R (Maybe EscalationDef)
lookupEscalation roots sp v = case Map.lookup v (rootEscalations roots) of
  Just m -> pure (Just m)
  Nothing -> do
    failHint
      NameResolutionError
      sp
      ("undeclared escalation '" <> v <> "'")
      ("declare it at the top of the file: escalation " <> v <> " \"CODE\"")
    pure Nothing
