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
  , succeeded
  ) where

import Data.Text (Text)

import Sequent.Bpmn.Semantic
import qualified Sequent.Bpmn.Validate as BpmnValidate
import qualified Sequent.Camunda.Serialize as Serialize
import qualified Sequent.Camunda.Validate as CamundaValidate
import Sequent.Diagnostic
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
