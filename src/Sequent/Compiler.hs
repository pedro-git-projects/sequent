-- | The compiler pipeline, end to end.
--
-- @
-- Source text
--     -> Parser        (Language.Parser)
--     -> Surface AST   (Language.Syntax)
--     -> Resolve       (Language.Resolve)      names, ids, implicit flows
--     -> Semantic graph (Bpmn.Semantic)        BPMN meaning, no geometry
--     -> Validate      (Bpmn.Validate, Camunda.Validate)
--     -> Layout        (Layout)                LLS, then RG
--     -> Serialize     (Camunda.Serialize)     BPMN 2.0 + BPMN DI
--     -> Camunda 8 BPMN XML
-- @
--
-- Each arrow is a total function returning diagnostics rather than throwing.
-- The compiler stops at the first stage that produced an error, so a file with
-- a parse error does not also report every name it could not resolve — but
-- within a stage, everything is reported at once.
--
-- The quality gates of SPEC §K are applied here rather than inside the layout
-- engine: the engine reports what it found, and the compiler decides that a T0
-- or T1 violation means "this is not a layout" and fails the build.
module Sequent.Compiler
  ( CompileOptions (..)
  , defaultOptions
  , CompileResult (..)
  , compileText
  , compileGraph
  , formatText
  , checkText
  , ImportResult (..)
  , importText
  , succeeded
  ) where

import Data.Text (Text)
import Data.List (sortOn)
import qualified Data.Text as T

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Sequent.Bpmn.Id (allocationClasses, classPrefix)
import Sequent.Bpmn.Read (ReadResult (..), readBpmn)
import Sequent.Bpmn.Semantic
import qualified Sequent.Bpmn.Validate as BpmnValidate
import qualified Sequent.Camunda.Serialize as Serialize
import qualified Sequent.Camunda.Validate as CamundaValidate
import Sequent.Diagnostic
import Sequent.Language.Emit (EmitResult (..), emitFile)
import Sequent.Language.Parser (parseFile)
import qualified Sequent.Language.Pretty as Pretty
import Sequent.Language.Resolve
import Sequent.Language.Syntax (SFile)
import Sequent.Layout
import Sequent.Text.Metrics (FontMetrics, helvetica12)

data CompileOptions = CompileOptions
  { coFont      :: FontMetrics
  , coImprove   :: Bool
  -- ^ Run phase 14. On by default; off makes the pipeline strictly
  -- derivational, which is what the golden tests pin.
  , coEmitDi    :: Bool
  -- ^ Emit @BPMNDiagram@. Off produces semantics-only output, useful for
  -- asserting that geometry cannot influence semantics.
  , coStrictLayout :: Bool
  -- ^ Treat T0\/T1 layout violations as errors (SPEC §K quality gates).
  , coPrevious :: Maybe PreviousGeometry
  -- ^ Geometry from a previous run, for the incremental stability of
  -- LAYOUT-024. Absent means "lay this out from scratch".
  }

defaultOptions :: CompileOptions
defaultOptions =
  CompileOptions
    { coFont = helvetica12
    , coImprove = True
    , coEmitDi = True
    , coStrictLayout = True
    , coPrevious = Nothing
    }

data CompileResult = CompileResult
  { crXml         :: Maybe Text
  , crGraph       :: Maybe SemanticGraph
  , crDiagnostics :: [Diagnostic]
  , crLayout      :: Maybe LayoutResult
  }

succeeded :: CompileResult -> Bool
succeeded = not . hasErrors . crDiagnostics

-- | Compile source text to Camunda 8 BPMN.
compileText :: CompileOptions -> FilePath -> Text -> CompileResult
compileText opts path src = case parseFile path src of
  Left ds -> CompileResult Nothing Nothing ds Nothing
  Right ast -> compileAst opts ast

compileAst :: CompileOptions -> SFile -> CompileResult
compileAst opts ast =
  let res = resolveFile ast
   in case rrGraph res of
        Nothing -> CompileResult Nothing Nothing (rrDiags res) Nothing
        Just g ->
          let semantic = BpmnValidate.validateGraph (rrProvenance res) g
              camunda = CamundaValidate.validateCamunda (rrProvenance res) g
              earlier = rrDiags res ++ semantic ++ camunda
           in if hasErrors earlier
                then CompileResult Nothing (Just g) (sortDiagnostics earlier) Nothing
                else
                  let out = compileGraph opts (rrPins res) g
                   in out {crDiagnostics = sortDiagnostics (earlier ++ crDiagnostics out)}

-- | Lay out and serialise an already-validated graph. Exposed separately so a
-- caller that built a graph by other means gets the same guarantees.
compileGraph :: CompileOptions -> PinSet -> SemanticGraph -> CompileResult
compileGraph opts pins g0 =
  CompileResult
    { crXml =
        if hasErrors layoutDiags
          then Nothing
          else
            Just
              ( if coEmitDi opts
                  then Serialize.serialize g (lrGeometry res)
                  else Serialize.serializeNoDi g
              )
    , crGraph = Just g
    , crDiagnostics = layoutDiags
    , crLayout = Just res
    }
  where
    -- LAYOUT-027 rule 1, applied once for the whole backend: the layout engine
    -- canonicalises its own input, and the serialiser walks the same
    -- canonicalised graph, so element order in the XML is a property of the
    -- document rather than of how the graph was assembled.
    g = canonicalise g0
    cfg =
      defaultConfig
        { lcFont = coFont opts
        , lcPins = pinMap pins
        , lcImprove = coImprove opts
        }
    res = format cfg g (coPrevious opts)
    -- SPEC §K: any T0 or T1 penalty fails the build. Everything else is
    -- reported at its own severity so the caller still gets a diagram.
    layoutDiags =
      sortDiagnostics
        ( map violationDiag (gate (lrViolations res))
            ++ lrDiagnostics res
        )
    gate vs
      | coStrictLayout opts = vs
      | otherwise = [v {vTier = max T2 (vTier v)} | v <- vs]

-- The other direction ----------------------------------------------------------

data ImportResult = ImportResult
  { irSource      :: Maybe Text
  -- ^ The @.sq@ source, in canonical form. Absent only when the BPMN could not
  -- be read at all.
  , irGraph       :: Maybe SemanticGraph
  , irDiagnostics :: [Diagnostic]
  }

-- | BPMN → @.sq@.
--
-- Read the file into a semantic graph, emit the surface syntax that produces
-- that graph, and print it with the same formatter every other @.sq@ goes
-- through. Geometry is discarded on the way in: the point of the round trip is
-- that the layout engine computes it again, so a file that came from a
-- modeller comes back laid out by the rules in @SPEC.md@ rather than by hand.
--
-- __The import checks its own work.__ Emitting surface syntax means re-deriving
-- structure the language leaves implicit — consecutive steps chain, gateways
-- nest, merges are derived — and the failure mode is an edge the language
-- /invents/, not one it drops. So the result is compiled back to a semantic
-- graph and compared with the one that was read, element by element. A
-- mismatch is reported as an error with the difference named, because a
-- silently wrong import is worse than a refused one.
importText :: FilePath -> Text -> ImportResult
importText path src = case rdGraph raw of
  Nothing -> ImportResult Nothing Nothing (sortDiagnostics (rdDiagnostics raw))
  Just g ->
    let out = emitFile g
        text = Pretty.format (emFile out)
     in ImportResult
          (Just text)
          (Just g)
          (sortDiagnostics (rdDiagnostics raw ++ emDiagnostics out ++ verify path (emSymbols out) g text))
  where
    raw = readBpmn path src

-- | Compile the emitted source and compare the graph it produces with the one
-- that was imported.
--
-- Document order is normalised away first. It is a real part of the graph — the
-- canonical ordering key ends in it — but its /absolute/ values are an artefact
-- of how many elements a parser happened to count past, and the emitted file
-- counts differently from the XML. What has to match is the order after
-- canonicalisation, which is what comparing the ranks checks.
verify :: FilePath -> Map Text Text -> SemanticGraph -> Text -> [Diagnostic]
verify path syms original text = case parseFile path text of
  Left ds -> map reframe ds
  Right ast -> case rrGraph (resolveFile ast) of
    Nothing -> map reframe (rrDiags (resolveFile ast))
    Just g'
      | before == after -> []
      | otherwise -> [mismatch (difference before after)]
      where
        before = normalise (relabel (\i -> Map.findWithDefault i i syms) original)
        after = normalise (relabel stripClassPrefix g')
  where
    reframe d =
      d
        { diagMessage = "the imported source does not compile: " <> diagMessage d
        , diagSeverity = Error
        }
    mismatch what =
      withHint
        "this is a defect in the importer, not in the file: please report it with the input"
        ( diagnostic
            Error
            InternalCompilerError
            ("the imported source does not reproduce the original process (" <> what <> ")")
        )

-- | Compare on symbolic names, not on ids.
--
-- An id survives the round trip only when it /is/ a name — @Activity_charge@
-- becomes @charge@ and comes back as @Activity_charge@. A file written in a
-- modeller has ids like @Activity_1x9k2df@, and the language has no syntax for
-- \"this step's id is that string\", so those change by construction. What must
-- not change is everything else, and rewriting both sides to the names the
-- import chose is what lets the check say so.
--
-- Flow ids go further: the resolver derives them from their endpoints, so they
-- cannot match either. Their identity is the pair they connect, which is what
-- they are keyed and sorted on here.
stripClassPrefix :: Text -> Text
stripClassPrefix i = case [r | c <- allocationClasses, Just r <- [T.stripPrefix (classPrefix c) i]] of
  (r : _) -> r
  [] -> i

relabel :: (Text -> Text) -> SemanticGraph -> SemanticGraph
relabel f g =
  g
    { sgMessages = [m {msgId = node (msgId m)} | m <- sgMessages g]
    , sgSignals = [x {sigId = node (sigId x)} | x <- sgSignals g]
    , sgErrors = [x {errId = node (errId x)} | x <- sgErrors g]
    , sgEscalations = [x {escId = node (escId x)} | x <- sgEscalations g]
    , sgCollaboration = col <$> sgCollaboration g
    , sgProcesses = map proc' (sgProcesses g)
    }
  where
    node (NodeId i) = NodeId (f i)
    flow (FlowId i) = FlowId (f i)
    lane (LaneId i) = LaneId (f i)
    art (ArtifactId i) = ArtifactId (f i)
    part (ParticipantId i) = ParticipantId (f i)
    ref r = case r of
      RefNode i -> RefNode (node i)
      RefFlow i -> RefFlow (flow i)
      RefLane i -> RefLane (lane i)
      RefParticipant i -> RefParticipant (part i)
      RefArtifact i -> RefArtifact (art i)

    col c =
      c
        { colId = f (colId c)
        , colParticipants = [p {partId = part (partId p), partProcess = ProcessId . f . unProcessId <$> partProcess p} | p <- colParticipants c]
        , colMessageFlows =
            [ m {mfId = flow (mfId m), mfSource = ref (mfSource m), mfTarget = ref (mfTarget m), mfMessage = node <$> mfMessage m}
            | m <- colMessageFlows c
            ]
        }

    proc' p =
      p
        { procId = ProcessId (f (unProcessId (procId p)))
        , procLanes = [l {laneId = lane (laneId l), laneChildren = map lane (laneChildren l)} | l <- procLanes p]
        , procScope = scope (procScope p)
        }

    scope sc =
      sc
        { scId = case scId sc of
            ScopeProcess i -> ScopeProcess (ProcessId (f (unProcessId i)))
            ScopeSubprocess i -> ScopeSubprocess (node i)
        , scNodes = map fnode (scNodes sc)
        , scFlows =
            [ x {sfId = flow (sfId x), sfSource = node (sfSource x), sfTarget = node (sfTarget x)}
            | x <- scFlows sc
            ]
        , scArtifacts = [a {artId = art (artId a), artLane = lane <$> artLane a} | a <- scArtifacts sc]
        , scAssociations = [a {asId = flow (asId a), asSource = ref (asSource a), asTarget = ref (asTarget a)} | a <- scAssociations sc]
        }

    fnode n = n {fnId = node (fnId n), fnLane = lane <$> fnLane n, fnKind = kind (fnKind n)}
    kind k = case k of
      NkEvent (EventSpec fl d) -> NkEvent (EventSpec (flav fl) (def <$> d))
      NkActivity (Activity (AkSubprocess inner) l) -> NkActivity (Activity (AkSubprocess (scope inner)) l)
      NkActivity (Activity (AkTask (TtReceive m)) l) -> NkActivity (Activity (AkTask (TtReceive (node <$> m))) l)
      other -> other
    flav fl = case fl of
      EvBoundary att -> EvBoundary att {baHost = node (baHost att)}
      other -> other
    def d = case d of
      EdMessage i -> EdMessage (node i)
      EdSignal i -> EdSignal (node i)
      EdError i -> EdError (node <$> i)
      EdEscalation i -> EdEscalation (node <$> i)
      other -> other

-- | Rewrite every document-order counter to zero and sort by identity.
--
-- Document order is a real part of the graph — the canonical ordering key ends
-- in it — but its values are a property of how a file was /written/, not of the
-- process. The emitted source legitimately reorders: a boundary handler moves
-- next to the step it hangs on, which is the idiomatic form and not the order
-- the XML happened to use.
normalise :: SemanticGraph -> SemanticGraph
normalise g0 = g {sgProcesses = map proc' (sgProcesses g), sgCollaboration = col}
  where
    g = canonicalise g0
    col = (\c -> c {colMessageFlows = [m {mfDocOrder = 0, mfId = FlowId ""} | m <- sortOn (\x -> (refKey (mfSource x), refKey (mfTarget x))) (colMessageFlows c)]}) <$> sgCollaboration g
    refKey r = case r of
      RefNode i -> unNodeId i
      RefParticipant i -> unParticipantId i
      RefArtifact i -> unArtifactId i
      RefFlow i -> unFlowId i
      RefLane i -> unLaneId i
    proc' p = p {procScope = scope (procScope p)}
    scope sc =
      sc
        { scNodes = [(n {fnDocOrder = 0}) {fnKind = kind (fnKind n)} | n <- sortOn fnId (scNodes sc)]
        , scFlows = [f {sfDocOrder = 0, sfId = FlowId ""} | f <- sortOn (\x -> (sfSource x, sfTarget x)) (scFlows sc)]
        , scArtifacts = [a {artDocOrder = 0} | a <- sortOn artId (scArtifacts sc)]
        , scAssociations = [a {asDocOrder = 0, asId = FlowId ""} | a <- sortOn (\x -> (show (asSource x), show (asTarget x))) (scAssociations sc)]
        }
    kind (NkActivity (Activity (AkSubprocess inner) l)) = NkActivity (Activity (AkSubprocess (scope inner)) l)
    kind other = other

-- | The first concrete thing that differs, so the report names something the
-- reader can look at rather than "graphs differ".
difference :: SemanticGraph -> SemanticGraph -> Text
difference a b =
  headOr "no difference found" $
    [ "processes: " <> tshow (map (unProcessId . procId) (sgProcesses a))
        <> " became " <> tshow (map (unProcessId . procId) (sgProcesses b))
    | map procId (sgProcesses a) /= map procId (sgProcesses b)
    ]
      ++ concat (zipWith scopeDiff (map procScope (sgProcesses a)) (map procScope (sgProcesses b)))
      ++ ["declarations differ" | (sgMessages a, sgSignals a, sgErrors a, sgEscalations a) /= (sgMessages b, sgSignals b, sgErrors b, sgEscalations b)]
      ++ ["the collaboration differs" | sgCollaboration a /= sgCollaboration b]
  where
    scopeDiff x y =
      [ "nodes: " <> tshow (map (unNodeId . fnId) (scNodes x)) <> " became " <> tshow (map (unNodeId . fnId) (scNodes y))
      | map fnId (scNodes x) /= map fnId (scNodes y)
      ]
        ++ [ "connections: " <> tshow (edges x) <> " became " <> tshow (edges y)
           | edges x /= edges y
           ]
        ++ [ "step '" <> unNodeId (fnId n) <> "' changed"
           | (n, m) <- zip (scNodes x) (scNodes y)
           , n /= m
           ]
        ++ [ "the connection " <> tshow (unNodeId (sfSource f), unNodeId (sfTarget f)) <> " changed"
           | (f, h) <- zip (scFlows x) (scFlows y)
           , f /= h
           ]
        ++ ["artifacts differ" | scArtifacts x /= scArtifacts y]
        ++ ["associations differ" | scAssociations x /= scAssociations y]
    edges sc = [(unNodeId (sfSource f), unNodeId (sfTarget f)) | f <- scFlows sc]
    headOr d xs = case xs of
      (x : _) -> x
      [] -> d

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Parse and re-print in canonical form.
formatText :: FilePath -> Text -> Either [Diagnostic] Text
formatText path src = Pretty.format <$> parseFile path src

-- | Diagnostics only: parse, resolve and validate without laying anything out.
checkText :: FilePath -> Text -> [Diagnostic]
checkText path src = case parseFile path src of
  Left ds -> ds
  Right ast ->
    let res = resolveFile ast
     in case rrGraph res of
          Nothing -> rrDiags res
          Just g ->
            sortDiagnostics
              ( rrDiags res
                  ++ BpmnValidate.validateGraph (rrProvenance res) g
                  ++ CamundaValidate.validateCamunda (rrProvenance res) g
              )
