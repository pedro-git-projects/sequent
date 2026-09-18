-- | The layout engine: the fourteen phases of SPEC §J, wired together.
--
-- @
-- format :: SemanticGraph -> Maybe PreviousGeometry -> PinSet -> LayoutResult
-- @
--
-- The signature is the architecture. Layout is a pure function of the semantic
-- graph, an optional previous geometry (for the incremental stability of
-- LAYOUT-024) and a pin set (LAYOUT-025) — and of nothing else. No clock, no
-- randomness, no XML, no hash iteration. Given the same three inputs and the
-- same compiler version, it returns the same integers (HC-016).
--
-- Scopes are laid out by recursion (LAYOUT-019): an expanded subprocess is
-- formatted by a full, independent invocation of the engine on its own scope,
-- and the outer layout then treats it as one node of the resulting size. The
-- outer pass never inspects inner nodes, which is what keeps the recursion
-- clean and guarantees a subprocess is never cramped to fit a container that
-- was sized before its contents were known.
module Sequent.Layout
  ( -- * The API
    LayoutConfig (..)
  , defaultConfig
  , PreviousGeometry
  , LayoutResult (..)
  , format
  , formatProcess
    -- * Re-exports the serialiser needs
  , module Sequent.Layout.Types
  ) where

import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Sequent.Bpmn.Semantic
import Sequent.Diagnostic (Diagnostic, RuleId (..), layoutAdvisory)
import Sequent.Layout.Analysis
import Sequent.Layout.Bands
import Sequent.Layout.Collision
import Sequent.Layout.Compact
import Sequent.Layout.Constants
import Sequent.Layout.Geometry
import Sequent.Layout.Improve
import Sequent.Layout.Labels
import Sequent.Layout.Layering
import Sequent.Layout.Ports
import Sequent.Layout.Regions
import Sequent.Layout.Routing
import Sequent.Layout.Rules
import Sequent.Layout.Score
import Sequent.Layout.Snap
import Sequent.Layout.Types
import Sequent.Layout.Validate
import Sequent.Text.Metrics
import Data.Maybe (fromMaybe)
import qualified Data.Text as T

-- | Geometry from a previous run, keyed by scope. Supplying it enables the
-- structural stickiness of LAYOUT-024: a branch keeps its side and a region its
-- mode unless changing them is clearly better, so adding one task does not
-- rearrange the diagram.
type PreviousGeometry = Map ScopeId Geometry

data LayoutConfig = LayoutConfig
  { lcFont     :: FontMetrics
  , lcPins     :: Map NodeId (Int, Int)
  , lcPrevious :: Maybe PreviousGeometry
  , lcImprove  :: Bool
  -- ^ Whether to run phase 14 at all. Off makes the pipeline strictly
  -- derivational, which is what the golden tests exercise.
  }

defaultConfig :: LayoutConfig
defaultConfig =
  LayoutConfig
    { lcFont = helvetica12
    , lcPins = Map.empty
    , lcPrevious = Nothing
    , lcImprove = True
    }

data LayoutResult = LayoutResult
  { lrGeometry   :: Geometry
  , lrViolations :: [Violation]
  , lrScore      :: Score
  , lrStructure  :: Map ScopeId LayoutStructure
  , lrDiagnostics :: [Diagnostic]
  }

-- | Lay out a whole semantic graph: every process, and the pool stack of a
-- collaboration if there is one.
format :: LayoutConfig -> SemanticGraph -> Maybe PreviousGeometry -> LayoutResult
format cfg g0 prev = case sgCollaboration g of
  Nothing -> mconcatResults [formatProcess cfg' p | p <- sgProcesses g]
  Just col -> stackPools cfg' g col
  where
    -- LAYOUT-027 rule 1: canonicalise before any traversal. Doing it here
    -- rather than trusting the caller is what makes "identical canonicalised
    -- input, identical output" a property of this function rather than of the
    -- pipeline that happens to feed it.
    g = canonicalise g0
    cfg' = cfg {lcPrevious = maybe (lcPrevious cfg) Just prev}

-- | Lay out one process: its root scope, its subprocess scopes, and its lanes.
formatProcess :: LayoutConfig -> BpmnProcess -> LayoutResult
formatProcess cfg p = layoutScopeRecursive cfg laneOrder (procScope p)
  where
    laneOrder
      | null (procLanes p) = [Nothing]
      | otherwise = map (Just . laneId) (procLanes p)

-- Recursive scope layout -------------------------------------------------------

-- | LAYOUT-019: lay a scope out by first laying out every expanded subprocess
-- it contains, sizing the container from the result, and then placing the
-- container's children inside it.
layoutScopeRecursive :: LayoutConfig -> [Maybe LaneId] -> Scope -> LayoutResult
layoutScopeRecursive cfg laneOrder sc = merged
  where
    children =
      [ (fnId n, scId inner, layoutScopeRecursive cfg [Nothing] inner)
      | n <- scNodes sc
      , NkActivity (Activity (AkSubprocess _ inner) _) <- [fnKind n]
      ]
    childBoxes = Map.fromList [(i, containerBox sid r) | (i, sid, r) <- children]

    subSize i = (\(w, above, below) -> (w, above + below)) <$> Map.lookup i childBoxes
    subAxis i = (\(_, above, _) -> above) <$> Map.lookup i childBoxes

    own = layoutOneScope cfg laneOrder sc subSize subAxis

    -- LAYOUT-019 sizes the container from the child's bounding box; LAYOUT-020
    -- decides where inside that box the child sits, and the two answers are
    -- returned together because the second is not recoverable from the first.
    --
    -- The split is @(width, aboveAxis, belowAxis)@ rather than @(width,
    -- height)@ because the child's spine is almost never halfway down its own
    -- bounding box: exception bands, handler bands and below-the-axis branches
    -- all hang downward. Reporting the two halves separately is what lets phase
    -- 5 reserve the room on the side that needs it and phase 7 hang the box
    -- from the axis rather than from its own middle.
    --
    -- __The box is then centred on that axis__: both halves take the larger of
    -- the two, so the flow line enters and leaves at the container's vertical
    -- middle. Sizing it tightly instead is correct and cheaper — the container
    -- is exactly as tall as its contents — but it reads wrong: the arrow meets
    -- a tall box a third of the way down and the eye has to decide whether the
    -- box or the line is the thing that is misaligned. The cost is paid in
    -- empty space on the lighter side, and it is a real cost: a subprocess
    -- whose exception handlers all hang below its spine pays their whole depth
    -- again above it.
    --
    -- Both halves are whole grid units and equal, so the box's height is an
    -- even number of them and its top edge stays on the grid once its centre
    -- does (HC-011).
    containerBox sid r =
      let g = lrGeometry r
          b = geometryBounds g
          axis = innerSpineY sid r
          above = ceilU (axis - rY b + containerPadY)
          below = ceilU (rectBottom b - axis + containerPadY + subprocPadBottom)
          half = maximum [above, below, ceilU ((subMinH + 1) `div` 2)]
       in (ceil2U (max subMinW (rW b + 2 * containerPadX)), half, half)

    -- LAYOUT-020: the inner spine is the /first spine node's/ axis, not the
    -- middle of the child's content. A2 guarantees the spine is one straight
    -- line, so any of its members would do; taking the first makes the choice
    -- independent of how far the spine happens to run.
    innerSpineY sid r =
      case [ rectCenterY rect
           | n <- maybe [] lsSpine (Map.lookup sid (lrStructure r))
           , Just rect <- [Map.lookup n (geoShapes (lrGeometry r))]
           ] of
        (y : _) -> y
        -- A scope with no spine at all — nothing but a disconnected fragment.
        -- Snapped, because everything downstream assumes the axis is on the
        -- grid and a bounding box's midpoint need not be.
        [] -> snapCenter (rectCenterY (geometryBounds (lrGeometry r)))

    -- LAYOUT-019: children are placed at the container's padding offset, and
    -- LAYOUT-020 replaces the vertical half of that offset with the alignment
    -- the container was sized for — the child's spine lands on the axis the
    -- outer flow arrives at, so the flow line continues straight through the
    -- container border instead of stepping to the box centre.
    merged = foldl' placeChild own children
    placeChild acc (owner, sid, childResult) = case Map.lookup owner (geoShapes (lrGeometry acc)) of
      Nothing -> acc
      Just box ->
        let g = lrGeometry childResult
            b = geometryBounds g
            above = maybe (rH box `div` 2) (\(_, a, _) -> a) (Map.lookup owner childBoxes)
            -- HC-011 is HARD and reaches inside the container: a child's node
            -- centres are on the grid in its own frame, so the offset that
            -- brings that frame into the container has to be a whole number of
            -- grid units or every node inside lands between two of them. The
            -- child's bounding box starts wherever LAYOUT-031 left it — at the
            -- left edge of a 36 px event, two pixels off — so the padding is
            -- rounded /up/ to the grid, which is also the direction that keeps
            -- it at or above CONTAINER_PAD_X (LAYOUT-019). The container was
            -- sized with the room for it.
            --
            -- The vertical offset needs no rounding: it is measured to the
            -- child's spine rather than to its bounding box, and a spine node's
            -- centre is on the grid already.
            dx = ceilU (rX box + containerPadX - rX b)
            dy = rY box + above - innerSpineY sid childResult
            moved = translateGeometry dx dy g
         in acc
              { lrGeometry = mergeGeometry (lrGeometry acc) moved
              , lrViolations = lrViolations acc ++ lrViolations childResult
              , lrScore = addScores (lrScore acc) (lrScore childResult)
              , lrDiagnostics = lrDiagnostics acc ++ lrDiagnostics childResult
              , lrStructure = Map.union (lrStructure acc) (lrStructure childResult)
              }

-- | LAYOUT-035: event subprocesses are stacked below everything else.
--
-- They are relocated rather than laid out in place because no sequence flow
-- touches one. To the layering pass they are a disconnected component, and
-- LAYOUT-034 drops disconnected components wherever the ordering happened to
-- reach them — which for a handler means above the flow it handles, pushing
-- the process the reader came for off its own axis.
--
-- Moving them costs nothing and breaks nothing: an element no edge reaches
-- cannot be made to cross one, so the placement is free in the sense ART-005
-- means. Stacking runs in canonical order, left edges align with the lane's
-- (or the diagram's, with no lanes), and the gap is BRANCH_GAP_Y — the same
-- gap that separates any two bands, because that is what these are.
--
-- Ordering matters twice. It runs __before the repair pass__, so that the lane
-- a handler belongs to grows around it under LANE-003/004 rather than being
-- asked to contain a box that arrived after it was sized; and before
-- 'placeChild', which offsets each inner scope from its container's final
-- rectangle, so moving the container carries its contents with it.
relocateHandlers :: Scope -> Geometry -> Geometry
relocateHandlers sc geo
  | null handlers = geo
  | otherwise = moved {geoShapes = foldl' place (geoShapes moved) stacked}
  where
    handlers = [n | n <- scNodes sc, isEventSubprocess n]
    handlerIds = map fnId handlers
    sizes = Map.fromList [(fnId n, box) | n <- handlers, Just box <- [Map.lookup (fnId n) (geoShapes geo)]]

    -- The diagram as it reads without them, which is what they go below.
    without = geo {geoShapes = foldr Map.delete (geoShapes geo) handlerIds}
    rest = geometryBounds without
    whole = geometryBounds geo

    -- Reclaim the space the handlers were occupying above and to the left of
    -- the flow. Whole grid units only, and never more than is actually free,
    -- so HC-011 survives and nothing crosses the diagram margin.
    moved = translateGeometry (back (rX rest - rX whole)) (back (rY rest - rY whole)) without
    back free = negate (u * (max 0 free `div` u))

    -- With lanes, "below the flow" means below the flow /of the handler's own
    -- lane/: an event subprocess is listed in a @flowNodeRef@ like any other
    -- node, so it belongs to a lane and HC-003 keeps it there. The lane then
    -- grows around it, which is why this runs before the repair pass.
    movedShapes = geoShapes moved
    laneContent l =
      [ r
      | n <- scNodes sc
      , not (isEventSubprocess n)
      , fnLane n == l
      , Just r <- [Map.lookup (fnId n) movedShapes]
      ]

    baseFor l = case laneContent l of
      [] -> geometryBounds moved
      rs -> unionRects rs

    -- Left edge: the lane's own, inset by its padding, so a stack of handlers
    -- lines up with the lane rather than with whichever of its steps happens
    -- to be furthest left. Without lanes it is the diagram's left edge.
    --
    -- Rounded up to the grid: a container's width is an even number of grid
    -- units (LAYOUT-019), so a left edge on the grid puts its centre on the
    -- grid too, which is what HC-011 checks.
    leftFor l = ceilU $ case l >>= (`Map.lookup` geoLanes moved) of
      Just lane -> rX lane + containerPadX
      Nothing -> rX (baseFor l)

    -- Handlers of one lane stack under each other; each lane starts again from
    -- its own content.
    stacked = concatMap perLane (dedupLanes (map fnLane handlers))
    perLane l =
      go (leftFor l) (rectBottom (baseFor l)) [fnId n | n <- handlers, fnLane n == l]

    go _ _ [] = []
    go left top (i : is) = case Map.lookup i sizes of
      Nothing -> go left top is
      Just box ->
        let y = ceilU (top + branchGapY)
         in (i, Rect left y (rW box) (rH box)) : go left (y + rH box) is

    dedupLanes = foldr (\l acc -> if l `elem` acc then acc else l : acc) []

    place acc (i, box) = Map.insert i box acc

mergeGeometry :: Geometry -> Geometry -> Geometry
mergeGeometry a b =
  Geometry
    { geoShapes = Map.union (geoShapes a) (geoShapes b)
    , geoRoutes = Map.union (geoRoutes a) (geoRoutes b)
    , geoLabels = Map.union (geoLabels a) (geoLabels b)
    , geoLanes = Map.union (geoLanes a) (geoLanes b)
    , geoPools = Map.union (geoPools a) (geoPools b)
    , geoArtifacts = Map.union (geoArtifacts a) (geoArtifacts b)
    }

-- One scope, all fourteen phases ------------------------------------------------

layoutOneScope
  :: LayoutConfig
  -> [Maybe LaneId]
  -> Scope
  -> (NodeId -> Maybe (Int, Int))
  -> (NodeId -> Maybe Int)
  -- ^ LAYOUT-020: for an expanded subprocess, how far its internal spine lies
  -- below the top of the box 'subSize' reported.
  -> LayoutResult
layoutOneScope cfg laneOrder sc subSize subAxis
  | not (lcImprove cfg) = finalise noOverrides
  -- §J phase 14 gates its own candidates: a branch reorder is generated only
  -- for a region with crossings, and a mode toggle only for one whose symmetry
  -- is defective. When neither term is non-zero there is nothing any candidate
  -- could improve, and re-running phases 5-13 six more times to discover that
  -- is the difference between a linear pipeline and a quadratic one.
  | not worthImproving = baseRun
  | otherwise = finalise bestOverrides
  where
    font = lcFont cfg
    an = analyse sc

    -- LAYOUT-028: the mode is a property of the graph, decided once, before any
    -- geometry exists.
    metrics
      | largeDiagram = largeMetrics
      | otherwise = standardMetrics
    largeDiagram =
      length (scNodes sc) > 150
        || maxLayer > 40
        || length laneOrder > 8
        || maxBranchFactor > 6
        || density > 1.8
    maxLayer = maximum (0 : Map.elems layers)
    maxBranchFactor = maximum (0 : [length (outgoingOf sc (fnId n)) | n <- scNodes sc])
    density
      | null (scNodes sc) = 0 :: Double
      | otherwise = fromIntegral (length (scFlows sc)) / fromIntegral (length (scNodes sc))

    -- P3 first: BRANCH-007's span component, which P2 needs, is defined in
    -- layers, and layering depends only on the acyclic skeleton.
    layers0 = asapLayers an
    pinLayers =
      Map.fromList
        [ (i, columnGuess x)
        | (i, (x, _)) <- Map.toAscList (lcPins cfg)
        , Map.member i layers0
        ]
    columnGuess x = max 0 ((x - margin) `div` (taskW + nodeGapX))
    layers = applyPinConstraints an pinLayers layers0

    boundaryCount i = length [() | n <- scNodes sc, Just att <- [boundaryHost n], baHost att == i]
    sizes =
      Map.fromList [(fnId n, nodeSize font subSize (boundaryCount (fnId n)) n) | n <- scNodes sc]

    -- LAYOUT-020, expressed once for every phase that needs it: the signed
    -- distance from a node's box centre to the line its connectors run on.
    -- Empty for a scope with no expanded subprocess, which is why nothing else
    -- in the engine has to know the rule exists.
    --
    -- It is currently empty for /every/ scope, because 'containerBox' centres a
    -- container on its own axis and the two therefore coincide. The map is kept
    -- because the coincidence is a property of one arithmetic line and not of
    -- the model: "where a connector attaches" and "the middle of the box" are
    -- different questions, and the phases below read the first. Sizing a
    -- container tightly again — reclaiming the empty space centring costs — is
    -- then a change to 'containerBox' alone, rather than a silent regression in
    -- the seven places that would go back to reading the box centre.
    axisMap =
      Map.fromList
        [ (fnId n, a - h `div` 2)
        | n <- scNodes sc
        , Just a <- [subAxis (fnId n)]
        , let (_, h) = Map.findWithDefault (taskW, taskH) (fnId n) sizes
        , a - h `div` 2 /= 0
        ]

    regions0 = detectRegions largeDiagram an layers

    -- Phase 14 evaluates candidates by re-running phases 5-13 with overrides
    -- applied; nothing before phase 5 depends on them.
    -- Phase 14's budget is a fixed count, never a time limit (LAYOUT-027 rule
    -- 5). The cap scales down with graph size because each candidate costs a
    -- full re-run of phases 5-13, and at scale comprehension comes from
    -- chunking rather than from local prettiness anyway (LAYOUT-028).
    baseRun = finalise seeded
    baseScore = scTotal (lrScore baseRun)

    worthImproving =
      any
        (\n -> maybe 0 id (lookup n (scTerms (lrScore baseRun))) > 0)
        ["crossingPenalty", "asymmetryPenalty", "spineBendPenalty"]

    bestOverrides =
      improveWithin
        improveCap
        metrics
        (Map.elems (rrRegions regions0))
        baseScore
        (\ov -> let r = finalise ov in (scTotal (lrScore r), null (blocking (lrViolations r))))
        seeded

    -- LAYOUT-024: start from the structure the previous layout had, so a
    -- structural change has to beat its stability cost before the picture
    -- rearranges. Without a previous geometry the seed is empty and the layout
    -- is derived from scratch, which is the from-scratch determinism case of
    -- N-9.
    seeded = maybe noOverrides (seedFromPrevious regions0) previousForScope
    previousForScope = lcPrevious cfg >>= Map.lookup (scId sc)
    improveCap
      | largeDiagram = 6
      | length (scNodes sc) > 60 = 12
      | otherwise = 24

    blocking = filter ((<= T1) . vTier)

    finalise ov = assemble (applyOverrides ov regions0)

    assemble regions = result
      where
        bands = assignBands metrics font an regions layers sizes axisMap laneOrder
        geom0 = assignGeometry metrics font sc layers sizes axisMap bands (lcPins cfg)
        shapes0 = grShapes geom0
        loopAbove = Map.fromList [(coFlow c, coAbove c) | c <- bandCorridors bands]
        ports0 = assignPorts an shapes0 loopAbove axisMap
        routed0 = routeAll metrics an shapes0 ports0 layers (grColumns geom0) bands (grLaneAxis geom0) axisMap

        -- Phase 11: channel demand becomes an explicit compaction constraint
        -- before compaction runs (N-14), so the two cannot oscillate.
        -- LAYOUT-009: an edge spanning more than one layer reserves a corridor
        -- in every gap it crosses, not just in the one where it turns. Adding
        -- those to the channel demand is what stops compaction from squeezing
        -- a gap a long edge is already passing through (N-14).
        channelsPerGap =
          Map.fromListWith
            (+)
            ( [ (Map.findWithDefault 0 n layers, 1 :: Int)
              | (f, _) <- Map.toList (rrChannels routed0)
              , Just fl <- [Map.lookup f (scopeFlowMap sc)]
              , let n = sfSource fl
              ]
                ++ [(l, 1) | vc <- virtualChains an layers, l <- vcLayers vc]
            )
        contentH = case Map.elems shapes0 of
          [] -> 0
          rs -> maximum (map rectBottom rs) - minimum (map rY rs)
        pinnedColumns =
          Set.fromList [l | i <- Map.keys (lcPins cfg), Just l <- [Map.lookup i layers]]
        plan = planCompaction metrics sc layers channelsPerGap pinnedColumns contentH (grColumns geom0)

        (shapes1, columns1)
          | cpApplied plan =
              let newCentre = Map.fromList [(colIndex c, colCentre c) | c <- cpColumns plan]
                  moveNode n r = case Map.lookup n layers >>= (`Map.lookup` newCentre) of
                    Just cx | not (isBoundary n) -> rectFromCenter cx (rectCenterY r) (rW r) (rH r)
                    _ -> r
               in (Map.mapWithKey moveNode shapes0, cpColumns plan)
          | otherwise = (shapes0, grColumns geom0)
        isBoundary n = maybe False nodeIsBoundary (Map.lookup n (scopeNodeMap sc))

        ports = assignPorts an shapes1 loopAbove axisMap
        routed = routeAll metrics an shapes1 ports layers columns1 bands (grLaneAxis geom0) axisMap

        -- ART-001/002: artifacts sit in their host's gutter, and their
        -- associations are the 0-bend vertical that alignment buys.
        (artifacts, assocRoutes) = placeArtifacts font sc shapes1

        -- Phase 9.
        labels = placeAllLabels font sc shapes1 (rrRoutes routed) (grLaneRects geom0)

        geomA =
          Geometry
            { geoShapes = shapes1
            , geoRoutes = Map.union (rrRoutes routed) assocRoutes
            , geoLabels = labels
            , geoLanes = grLaneRects geom0
            , geoPools = Map.empty
            , geoArtifacts = artifacts
            }

        -- Phases 10 and 12. LAYOUT-035 runs first so that the lane a handler
        -- belongs to grows around it here (LANE-004) rather than being asked
        -- to contain a box that arrived after it was sized (HC-003).
        repaired = repairCollisions sc (relocateHandlers sc geomA)
        portsOf fid = (sourcePort ports fid, targetPort ports fid)
        geomB =
          anchorPins
            (lcPins cfg)
            ( translateToMargin
                ( straightenNearStraight
                    sc
                    axisMap
                    (reanchorEndpoints sc portsOf (snapGeometry (crGeometry repaired)))
                )
            )

        -- LAYOUT-025: a pin is never silently dropped. What remains unmet
        -- after re-anchoring is reported with the pinned element's id.
        brokenPins =
          [ i
          | (i, (px, py)) <- Map.toAscList (lcPins cfg)
          , Just r <- [Map.lookup i (geoShapes geomB)]
          , rX r /= px || rY r /= py
          ]

        structure =
          LayoutStructure
            { lsScope = scId sc
            , lsLayers = layers
            , lsRegions = rrRegions regions
            , lsRootRegion = rrRoot regions
            , lsNodeRegion = rrNodeRegion regions
            , lsSpine = rrSpine regions
            , lsBands = bandPlacements bands
            , lsBackEdges = Set.toList (anBackFlows an)
            , lsCorridors = bandCorridors bands
            , lsUnstructured = rrUnstructured regions
            , lsLaneOrder = laneOrder
            , lsLaneExtent = bandLaneExtent bands
            , lsColumnOf = layers
            , lsMaxLayer = maxLayer
            , lsLarge = largeDiagram
            }

        vi =
          ValidationInput
            { viScope = sc
            , viShapes = geoShapes geomB
            , viRoutes = geoRoutes geomB
            , viLabels = geoLabels geomB
            , viLanes = geoLanes geomB
            , viArtifacts = geoArtifacts geomB
            , viPorts = ports
            , viSpine = rrSpine regions
            , viAxis = axisMap
            , viBackFlows = anBackFlows an
            , viFont = font
            }
        si =
          ScoreInput
            { siScope = sc
            , siShapes = geoShapes geomB
            , siRoutes = geoRoutes geomB
            , siLabels = geoLabels geomB
            , siColumns = columns1
            , siSpine = rrSpine regions
            , siAxis = axisMap
            , siBackFlows = anBackFlows an
            , siPorts = ports
            , siRegions = Map.elems (rrRegions regions)
            , siLayers = layers
            , siMetrics = metrics
            }
        st = LayoutState vi si

        result =
          LayoutResult
            { lrGeometry = geomB
            , lrViolations = runRules st
            , lrScore = scoreGeometry si
            , lrStructure = Map.singleton (scId sc) structure
            , lrDiagnostics =
                advisories
                  metrics
                  sc
                  structure
                  (emptyStrips metrics columns1 (geoShapes geomB))
                  (crConverged repaired)
                  brokenPins
            }

-- | LAYOUT-024's structural stickiness: recover each branch's side from a
-- previous layout, so a re-run keeps the arrangement the reader already knows
-- unless changing it is clearly better.
--
-- The side is read off the previous geometry rather than stored, which means
-- the caller can hand back a diagram edited in a modeller and still get
-- stability — there is nothing to keep in sync.
seedFromPrevious :: RegionResult -> Geometry -> Overrides
seedFromPrevious regions prev =
  Overrides
    Map.empty
    ( Map.fromList
        [ ((rgId reg, brId b), side)
        | reg <- Map.elems (rrRegions regions)
        , RkSplit sp _ _ <- [rgKind reg]
        , Just splitRect <- [Map.lookup sp (geoShapes prev)]
        , b <- rgBranches reg
        , brPolarity b == PolNeutral
        , Just side <- [sideOf (rectCenterY splitRect) b]
        ]
    )
  where
    sideOf axis b = case [r | n <- brNodes b, Just r <- [Map.lookup n (geoShapes prev)]] of
      [] -> Nothing
      (r : _)
        | rectCenterY r < axis -> Just SideAbove
        | rectCenterY r > axis -> Just SideBelow
        | otherwise -> Just SideAxis

-- | Phase 14's overrides are applied to the region tree before phase 5 reads
-- it, so a candidate changes structure rather than nudging geometry.
applyOverrides :: Overrides -> RegionResult -> RegionResult
applyOverrides ov rr
  | Map.null (ovModes ov) && Map.null (ovSides ov) = rr
  | otherwise = rr {rrRegions = Map.mapWithKey fixRegion (rrRegions rr)}
  where
    fixRegion rid reg =
      reg
        { rgMode = Map.findWithDefault (rgMode reg) rid (ovModes ov)
        , rgBranches = [b {brSide = Map.findWithDefault (brSide b) (rid, brId b) (ovSides ov)} | b <- rgBranches reg]
        }

-- Phase 9 ---------------------------------------------------------------------

-- | Place every label, external and flow, at the first anchor in its ladder
-- whose box is clear (LABEL-006). Deterministic by construction: the ladder is
-- fixed and nodes are visited in canonical order.
-- Flow labels are placed before node labels: LABEL-005 is STRONG and anchors
-- a flow label to a specific segment, while LABEL-002 and LABEL-003 are MEDIUM
-- and come with an anchor ladder. Placing the movable ones second is what lets
-- the ladder do its job.
placeAllLabels
  :: FontMetrics
  -> Scope
  -> Map NodeId Rect
  -> Map FlowId Route
  -> Map LaneId Rect
  -- ^ LANE-004: a label belongs to its node's lane as much as the node does.
  -> Map LabelKey LabelBox
placeAllLabels font sc shapes routes laneRects = foldl' addNode flowLabels (scNodes sc)
  where
    flowLabels = foldl' addFlow Map.empty (Map.toAscList routes)

    allSegments = concatMap (routeSegments . rtPoints) (Map.elems routes)

    addNode acc n = case fnName n of
      Nothing -> acc
      Just "" -> acc
      Just t
        | nodeIsActivity n -> acc -- LABEL-001: activity text is inside the shape.
        | otherwise -> case Map.lookup (fnId n) shapes of
            Nothing -> acc
            Just r ->
              let box = externalLabelBox font t
                  candidates = ladderWithRoom r box (anchorLadder n)
                  -- A label sits LABEL_GAP from its own shape's border, so
                  -- inflating by LABEL_CLEAR always overlaps that shape. Its
                  -- own node is therefore not an obstacle; if it were, every
                  -- anchor would be rejected and the ladder would collapse to
                  -- its first entry (LABEL-002/003).
                  obstacles = Map.delete (fnId n) shapes
                  chosen = firstFree acc obstacles allSegments (within (fnLane n)) candidates
               in Map.insert (LkNode (fnId n)) (LabelBox chosen (tbLines box)) acc

    -- LABEL-006's last rung: "if none is free, widen the owning gap by
    -- @labelH + 2·LABEL_CLEAR@ and retry from the first anchor".
    --
    -- Widening a band gap after the bands are built would mean running phase 5
    -- again from phase 9, so the room is taken where it is free instead: the
    -- whole ladder is retried a step further out, and again a step beyond that.
    -- The two are the same move seen from opposite ends — a label is part of
    -- the diagram bounds (LABEL-011), so a label that steps past the last band
    -- grows the diagram to hold it. What is never done is the thing the rule
    -- forbids: keeping the label where it is and letting it overlap.
    ladderWithRoom r box ladder =
      [ translateRect (dx * k * stepX) (dy * k * stepY) (placeExternalLabel r box a)
      | k <- [0 .. labelPushSteps]
      , a <- ladder
      , let (dx, dy) = anchorAway a
      ]
      where
        stepX = u
        stepY = u

    addFlow acc (fid, route) = case Map.lookup fid flowById >>= sfName of
      Nothing -> acc
      Just "" -> acc
      Just t ->
        let box = flowLabelBox font t
            -- LABEL-006's ordered anchor fallback: above the segment start,
            -- below it, then the segment middle, then its end. Never solved by
            -- shrinking the font, rotating the text, or hiding the label.
            primary = (placeFlowLabel (stackXFor fid) route box) {rX = leftEdgeFor fid route box}
            below = translateRect 0 (tbHeight box + 2 * flowLabelOffset) primary
            segs = routeSegments (rtPoints route)
            horiz = [s' | s' <- segs, ptY (segA s') == ptY (segB s'), segLength s' > 0]
            atMiddle sgn = case horiz of
              (s' : _) ->
                let mx = (ptX (segA s') + ptX (segB s')) `div` 2
                 in Rect mx (ptY (segA s') + sgn * (flowLabelOffset + tbHeight box)) (max 1 (tbWidth box)) (max 1 (tbHeight box))
              [] -> primary
            -- The same last rung as a node label: retry the whole ladder one
            -- line further from the segment, on the side the anchor chose,
            -- before accepting an overlap (LABEL-006).
            fallbacks =
              [ translateRect 0 (k * u * away) c
              | k <- [0 .. labelPushSteps]
              , (away, c) <- [(-1, primary), (1, below), (-1, atMiddle (-1)), (1, atMiddle 1)]
              ]
            -- A flow label belongs to its own edge, and LABEL-005 anchors it at
            -- the gateway's centre x. The corners of a diamond's bounding box
            -- are empty ink, so overlapping the endpoint shapes' boxes is
            -- expected — SPEC §L pattern B places both branch labels exactly
            -- there. Foreign shapes are still obstacles.
            own = maybe [] endpointsOf (Map.lookup fid flowById)
            endpointsOf fl = [sfSource fl, sfTarget fl]
            obstacles = Map.filterWithKey (\k _ -> k `notElem` own) shapes
            -- EDGE-018: an edge may pass through its own label only along the
            -- segment the label annotates, which it is drawn offset from. The
            -- rest of that edge is an obstacle like anyone else's — a label
            -- that overhangs the end of its own segment and lands on the very
            -- next turn of the same connector is text with a line through it.
            obstacleSegs =
              concatMap (routeSegments . rtPoints) (Map.elems (Map.delete fid routes))
                ++ [s | s <- routeSegments (rtPoints route), Just s /= labelledSegment route]
            chosen = firstFree acc obstacles obstacleSegs (const True) fallbacks
         in Map.insert (LkFlow fid) (LabelBox chosen (tbLines box)) acc

    flowById = scopeFlowMap sc

    -- LABEL-005: every outgoing label of one split shares the trunk x, so the
    -- labels form one vertical stack instead of stepping with the branches.
    stackXFor fid = do
      fl <- Map.lookup fid flowById
      let src = sfSource fl
      if length (namedOut src) < 2
        then Nothing
        else rectCenterX <$> Map.lookup src shapes

    namedOut src = [f | f <- scFlows sc, sfSource f == src, sfName f /= Nothing]

    -- LABEL-005, plus the clause the trunk alignment needs to survive contact
    -- with the glyph it is aligned to.
    --
    -- The stack sits at @cx(split) + 1U@ so that a Yes\/No pair reads as one
    -- column. For the peel branches that is empty space beside the trunk; for
    -- the /axis/ branch the label sits just above the split's own centre line,
    -- and at 1U from centre a 50 px diamond is still solid ink — so the label
    -- is drawn across the X. The corners of a gateway's bounding box are empty,
    -- which is why the box alone is not the test; the band beside its centre
    -- line is not empty at all.
    --
    -- So the whole stack moves right by however much its worst member needs.
    -- Moving one label would break the alignment that is the point of the rule;
    -- moving all of them keeps the column and costs a few pixels of run.
    leftEdgeFor fid route box
      -- A label anchored to a segment that travels right-to-left is mirrored:
      -- it hangs off the segment's start toward its target, which is leftward.
      -- Neither the stack nor the clearance below applies to it. The stack is a
      -- property of a split comb, whose peel segments all run out of the trunk
      -- rightward; and a backward segment belongs to a loopback, which leaves
      -- through N or S (EDGE-013) and is therefore never level with the glyph
      -- it left.
      | not (travelsRight route) = rX (placeFlowLabel Nothing route box)
      | otherwise = maximum (base : map inkClear mates)
      where
        src = maybe (NodeId "") sfSource (Map.lookup fid flowById)
        stacked = length (namedOut src) >= 2
        base = case stackXFor fid of
          Just cx -> cx + u
          Nothing -> rX (placeFlowLabel Nothing route box)
        mates
          | stacked = [(sfId f, flowLabelBox font (fromMaybe "" (sfName f))) | f <- namedOut src]
          | otherwise = [(fid, box)]

        inkClear (f, b) = case (Map.lookup f routes, Map.lookup src shapes) of
          (Just r, Just gw)
            | reach > 0 -> rectCenterX gw + reach + labelClear
            where
              lb = placeFlowLabel Nothing r b
              reach = inkReachRight (Map.lookup src (scopeNodeMap sc)) gw (rY lb) (rectBottom lb)
          _ -> 0

    -- Which way the segment a label is anchored to runs. Everything LABEL-005
    -- says about anchoring and overhang is in terms of travel, not of the page.
    travelsRight route = case labelledSegment route of
      Just (Segment a b) -> ptX b >= ptX a
      Nothing -> True

    -- How far right of its centre a shape's ink reaches, over a horizontal band
    -- @[y0, y1]@. A gateway is a diamond, so its reach shrinks with distance
    -- from its centre line; everything else is measured as its box.
    inkReachRight kind gw y0 y1
      | y1 <= rY gw || y0 >= rectBottom gw = 0
      | isGateway = max 0 (halfW - dFromAxis)
      | otherwise = halfW
      where
        halfW = rW gw `div` 2
        cy = rectCenterY gw
        dFromAxis
          | y0 <= cy && cy <= y1 = 0
          | otherwise = min (abs (y0 - cy)) (abs (y1 - cy))
        isGateway = maybe False nodeIsGateway kind

    -- LANE-004: a node's caption sits in the node's own lane. A lane is sized
    -- from the shapes it holds and from the column grid, neither of which knows
    -- how wide a caption is, so a label centred under a node near the lane's
    -- edge hangs outside it — text belonging to a lane, drawn in the next one
    -- or in no lane at all.
    within lane r = case lane >>= (`Map.lookup` laneRects) of
      Nothing -> True
      Just lr -> rectContains lr r

    firstFree placed shapes' segs inside cands = case [c | c <- cands, inside c, clear placed shapes' segs c] of
      (c : _) -> c
      [] -> case [c | c <- cands, clear placed shapes' segs c] ++ cands of
        (c : _) -> c
        [] -> emptyRect

    -- LABEL-011: a label collides with shapes, with other labels, and with
    -- connectors. Leaving connectors out of this test is what put a boundary
    -- event's caption across the exception line of its sibling — the text was
    -- clear of every box and still unreadable.
    clear placed shapes' segs r =
      not (any (rectsOverlap (inflate labelClear r)) (Map.elems shapes'))
        && not (any (rectsOverlap r . lbRect) (Map.elems placed))
        && not (any (`segIntersectsRect` r) segs)

-- | ART-001 \/ ART-002 \/ EDGE-017: place a host's artifacts in its gutter and
-- draw the association.
--
-- Data objects go above, annotations and data stores below. A single artifact
-- takes its host's centre x, which makes the association a straight vertical
-- with zero bends; a group is laid out left to right, spaced @2U@ and centred
-- on the host, and each member attaches to its own offset port so the
-- associations cannot cross.
placeArtifacts
  :: FontMetrics
  -> Scope
  -> Map NodeId Rect
  -> (Map ArtifactId Rect, Map FlowId Route)
placeArtifacts font sc shapes = (Map.fromList rects, Map.fromList routes)
  where
    byArt = Map.fromList [(artId a, a) | a <- scArtifacts sc]
    pairs =
      [ (host, art, a)
      | a <- scAssociations sc
      , (art, host) <- endpointsOf a
      ]
    endpointsOf a = case (asSource a, asTarget a) of
      (RefArtifact ai, RefNode h) -> [(art, h) | Just art <- [Map.lookup ai byArt]]
      (RefNode h, RefArtifact ai) -> [(art, h) | Just art <- [Map.lookup ai byArt]]
      _ -> []

    grouped =
      Map.fromListWith
        (flip (++))
        [((host, gutterAbove host (artKind art)), [(art, a)]) | (host, art, a) <- pairs]

    -- ART-001 puts data objects above and annotations and data stores below;
    -- ART-006 moves an annotation above when the below gutter is occupied. A
    -- host with boundary events owns the space below it — the exception stub
    -- leaves downward at its centre x, exactly where a below-gutter
    -- association would run — so annotations on such a host go above.
    gutterAbove host k = case k of
      AkDataObject -> True
      _ -> hasBoundary host
    hasBoundary host =
      any (\n -> fmap baHost (boundaryHost n) == Just host) (scNodes sc)

    placements =
      [ (art, a, rect, hostRect, isAbove)
      | ((host, isAbove), members) <- Map.toAscList grouped
      , Just hostRect <- [Map.lookup host shapes]
      , let sized = [(art, a, sizeOf art) | (art, a) <- members]
      , let groupW = sum [w | (_, _, (w, _)) <- sized] + 2 * u * max 0 (length sized - 1)
      , let x0 = rectCenterX hostRect - groupW `div` 2
      , (art, a, rect) <- layoutRow isAbove hostRect x0 sized
      ]

    layoutRow isAbove hostRect x0 sized = go x0 sized
      where
        go _ [] = []
        go x ((art, a, (w, h)) : rest) =
          let y =
                if isAbove
                  then rY hostRect - artifactGap - h
                  else rectBottom hostRect + artifactGap
           in (art, a, Rect x y w h) : go (x + w + 2 * u) rest

    rects = [(artId art, r) | (art, _, r, _, _) <- placements] ++ groupRects

    -- ART-005: a group is the bounding box of its members plus CONTAINER_PAD_Y
    -- on every side, computed after placement and constraining nothing. It is
    -- the one artifact with no host and no association: it is drawn round its
    -- members rather than attached to one of them, so it takes no gutter and
    -- joins no row.
    --
    -- A group whose members were all laid out elsewhere — in a subprocess, say
    -- — has no box here and is dropped rather than drawn round nothing.
    groupRects =
      [ (artId a, inflate containerPadY (unionRects ms))
      | a <- scArtifacts sc
      , artKind a == AkGroup
      , let ms = [r | m <- artMembers a, Just r <- [Map.lookup m shapes]]
      , not (null ms)
      ]

    routes =
      [ ( asId a
        , Route
            [ Point (rectCenterX r) (if isAbove then rectBottom r else rY r)
            , Point (rectCenterX r) (if isAbove then rY hostRect else rectBottom hostRect)
            ]
            EcAssociation
            (edgeBendBudget EcAssociation)
        )
      | (_, a, r, hostRect, isAbove) <- placements
      ]

    sizeOf art = case artKind art of
      AkDataObject -> (dataW, dataH)
      AkDataStore -> (storeW, storeH)
      -- A group has no association, so it never reaches a gutter row and never
      -- asks for a size: 'groupRects' derives its rectangle from its members.
      -- The case exists so that a group which somehow acquired one would be
      -- given a harmless box rather than crash the formatter.
      AkGroup -> (dataW, dataH)
      -- LABEL-010: the text sits inside the annotation with LABEL_PAD around it
      -- and a bracket band down the left. Two separate things have to fit: the
      -- width comes from the text, and the height from the text re-wrapped at
      -- the width the /renderer/ will have — a unit narrower again, because it
      -- supplies its own padding and need not use ours. Measuring the height at
      -- our own usable width is how a line that fits here spills past the
      -- bracket there.
      AkTextAnnotation ->
        let text = fromMaybe "" (artText art)
            usable = annotWMax - 2 * labelPad - annotBracket
            box = wrapText font usable 4 text
            w = max annotWMin (min annotWMax (tbWidth box + 2 * labelPad + annotBracket))
            drawn = wrapText font (w - 2 * labelPad - annotBracket - u) 4 text
         in (w, max (2 * u) (tbHeight drawn + 2 * labelPad))

-- Advisories --------------------------------------------------------------------

advisories
  :: Metrics
  -> Scope
  -> LayoutStructure
  -> [(Int, Int)]
  -- ^ Empty vertical strips found by LAYOUT-023's detector.
  -> Bool
  -> [NodeId]
  -> [Diagnostic]
advisories metrics sc structure strips converged brokenPins =
  concat
    [ [ layoutAdvisory (RuleId "LAYOUT-025") ("layout pin could not be honoured: " <> unNodeId n)
      | n <- brokenPins
      ]
    , [ layoutAdvisory
          (RuleId "LAYOUT-023")
          ("unused vertical strip of " <> tshow w <> " px at x=" <> tshow x)
      | (x, w) <- strips
      ]
    , [ layoutAdvisory (RuleId "LAYOUT-010") "diagram is wider than one screen row; consider link events or a subprocess"
      | lsMaxLayer structure * (taskW + mNodeGapX metrics) > maxRowW
      ]
    , [ layoutAdvisory (RuleId "LAYOUT-028") "large-diagram mode: spacing increased and symmetry disabled"
      | lsLarge structure
      ]
    , [ layoutAdvisory (RuleId "LAYOUT-033") "part of this process is not reducible to single-entry/single-exit regions; that part used the local fallback"
      | not (null (lsUnstructured structure))
      ]
    , [ layoutAdvisory (RuleId "BRANCH-006") "a gateway has seven or more branches; consider a subprocess or a decision table"
      | any (\n -> length (outgoingOf sc (fnId n)) >= 7) (scNodes sc)
      ]
    , [ layoutAdvisory (RuleId "HC-002") "collision repair did not converge within its iteration budget"
      | not converged
      ]
    ]

-- Collaboration -----------------------------------------------------------------

-- | LANE-012: pools stack vertically, left-aligned, all the same width so their
-- right edges line up — a strong regularity cue in collaboration diagrams.
stackPools :: LayoutConfig -> SemanticGraph -> Collaboration -> LayoutResult
stackPools cfg g col = withMessageFlows (lcFont cfg) nodesById col (foldl' step emptyResult (zip [0 ..] participants))
  where
    participants = sortOn partOrder (colParticipants col)
    procById = Map.fromList [(procId p, p) | p <- sgProcesses g]
    nodesById = Map.unions [scopeNodeMap (procScope p) | p <- sgProcesses g]

    laid =
      [ (pt, maybe Nothing (`Map.lookup` procById) (partProcess pt))
      | pt <- participants
      ]

    results =
      Map.fromList
        [ (partId pt, formatProcess cfg pr)
        | (pt, Just pr) <- laid
        ]

    poolWidth =
      maximum
        ( subMinW
            : [ rW (geometryBounds (lrGeometry r)) + 2 * containerPadX + poolLabelBand
              | r <- Map.elems results
              ]
        )

    heights =
      Map.fromList
        [ ( partId pt
          , case Map.lookup (partId pt) results of
              Nothing -> blackboxH
              Just r -> max laneMinH (rH (geometryBounds (lrGeometry r)) + 2 * containerPadY)
          )
        | pt <- participants
        ]

    tops = scanl (\y pt -> y + Map.findWithDefault blackboxH (partId pt) heights + poolGapY) margin participants

    step acc (k, pt) =
      let top = tops !! k
          h = Map.findWithDefault blackboxH (partId pt) heights
          poolRect = Rect margin top poolWidth h
       in case Map.lookup (partId pt) results of
            Nothing -> acc {lrGeometry = (lrGeometry acc) {geoPools = Map.insert (partId pt) poolRect (geoPools (lrGeometry acc))}}
            Just r ->
              let b = geometryBounds (lrGeometry r)
                  -- Whole grid units, for the reason a subprocess's children
                  -- need them (HC-011): the pool's contents are on the grid in
                  -- the process's own frame, and a fractional offset would take
                  -- every one of them off it. Rounding up keeps the padding at
                  -- or above CONTAINER_PAD, and the pool box was sized with the
                  -- room for it.
                  dx = ceilU (margin + poolLabelBand + containerPadX - rX b)
                  dy = ceilU (top + containerPadY - rY b)
                  moved = translateGeometry dx dy (lrGeometry r)
               in LayoutResult
                    { lrGeometry = (mergeGeometry (lrGeometry acc) moved) {geoPools = Map.insert (partId pt) poolRect (geoPools (mergeGeometry (lrGeometry acc) moved))}
                    , lrViolations = lrViolations acc ++ lrViolations r
                    , lrScore = addScores (lrScore acc) (lrScore r)
                    , lrStructure = Map.union (lrStructure acc) (lrStructure r)
                    , lrDiagnostics = lrDiagnostics acc ++ lrDiagnostics r
                    }

-- | EDGE-016: message flows run perpendicular to the pool stack.
--
-- A message flow always leaves the @S@ port of the upper element and enters
-- the @N@ port of the lower one; it never attaches to @E@ or @W@, which would
-- compete with sequence flow. When the two centres line up the route is a
-- single vertical with no bends; otherwise the horizontal jog lies in the
-- inter-pool gap and never inside a pool.
--
-- Message flows are the one class of connector routed after phase 9, because
-- they belong to the collaboration and not to any one process scope. So this
-- is also where EDGE-018's repair is applied: a message flow entering an
-- element's @S@ port runs up the same centre line an event's label sits on
-- (LABEL-003), and the label placer could not have known. The obstacle is
-- introduced here and the label is moved here, by the same ladder phase 9
-- would have used.
withMessageFlows :: FontMetrics -> Map NodeId FlowNode -> Collaboration -> LayoutResult -> LayoutResult
withMessageFlows font byId col res =
  res
    { lrGeometry = geo {geoRoutes = Map.union routes (geoRoutes geo), geoLabels = withMessageLabels labels'}
    , lrViolations = lrViolations res ++ stillCrossed
    }
  where
    geo = lrGeometry res
    routes = Map.fromList [(mfId m, r) | m <- colMessageFlows col, Just r <- [route m]]

    -- LABEL-009. Placed here for the same reason the routes are: a message flow
    -- belongs to the collaboration, so no scope's phase 9 ever saw it. Leaving
    -- it unplaced does not mean unlabelled — the name is still serialised, and
    -- a modeller with no DI bounds to go on drops the text at the middle of the
    -- flow, which for a route crossing the inter-pool gap is squarely on a pool
    -- border.
    withMessageLabels acc = foldl' addMessageLabel acc (Map.toAscList routes)

    nameOf fid = case [mfName m | m <- colMessageFlows col, mfId m == fid] of
      (Just t : _) | not (T.null t) -> Just t
      _ -> Nothing

    addMessageLabel acc (fid, r) = case nameOf fid of
      Nothing -> acc
      Just t ->
        let box = flowLabelBox font t
            cands = messageAnchors r (max 1 (tbWidth box)) (max 1 (tbHeight box))
            placed = case [c | c <- cands, freeFor acc c] of
              (c : _) -> c
              [] -> case cands of
                (c : _) -> c
                [] -> emptyRect
         in Map.insert (LkFlow fid) (LabelBox placed (tbLines box)) acc

    -- The longest segment carries the label: for the canonical message flow
    -- that is the vertical run in the inter-pool gap, which is the one stretch
    -- of the route that belongs to neither pool.
    messageAnchors r w h = case longest of
      Just (Segment a b)
        | ptX a == ptX b ->
            [ Rect (ptX a + flowLabelOffset) (mid (ptY a) (ptY b) - h `div` 2) w h
            , Rect (ptX a - flowLabelOffset - w) (mid (ptY a) (ptY b) - h `div` 2) w h
            ]
        | otherwise ->
            [ Rect (mid (ptX a) (ptX b) - w `div` 2) (ptY a - flowLabelOffset - h) w h
            , Rect (mid (ptX a) (ptX b) - w `div` 2) (ptY a + flowLabelOffset) w h
            ]
      Nothing -> []
      where
        longest = case sortOn (negate . segLength) (routeSegments (rtPoints r)) of
          (s : _) -> Just s
          [] -> Nothing
        mid p q = (p + q) `div` 2

    -- A label may sit inside a pool or outside every pool. What it may not do
    -- is straddle a border, which is exactly where the default placement put it.
    freeFor acc c =
      not (any straddles (Map.elems (geoPools geo)))
        && not (any (rectsOverlap c) (Map.elems (geoShapes geo)))
        && not (any (rectsOverlap c . lbRect) (Map.elems acc))
      where
        straddles p = rectsOverlap c p && not (rectContains p c)

    -- LABEL-006's ladder, re-run against the geometry the message flows are
    -- part of. A label that was already clear is left exactly where it was.
    labels' = Map.mapWithKey reanchor (geoLabels geo)
    reanchor k lb = case k of
      LkNode n
        | crossed (lbRect lb)
        , Just r <- Map.lookup n (geoShapes geo)
        , Just node <- Map.lookup n byId ->
            let size = (rW (lbRect lb), rH (lbRect lb))
                cands = [placeExternalLabelSized r size a | a <- anchorLadder node]
             in case [c | c <- cands, not (crossed c), free k c] of
                  (c : _) -> lb {lbRect = c}
                  [] -> lb
      _ -> lb

    crossed r = any (\rt -> any (`segIntersectsRect` r) (routeSegments (rtPoints rt))) (Map.elems routes)
    free k r =
      not (any (rectsOverlap r) [rect | (n, rect) <- Map.toAscList (geoShapes geo), Just n /= nodeOf k])
        && not (any (rectsOverlap r . lbRect) (Map.elems (Map.delete k (geoLabels geo))))
    nodeOf k = case k of
      LkNode n -> Just n
      _ -> Nothing

    -- EDGE-016 has no further remedy: the pools and their contents are already
    -- placed. What could not be moved is reported rather than drawn over.
    stillCrossed =
      [ Violation (RuleId "LABEL-011") T1 ("message flow crosses the label of " <> unNodeId n) (Just "move the element, or give the message flow a different endpoint") (Just (RefNode n))
      | (LkNode n, lb) <- Map.toAscList labels'
      , crossed (lbRect lb)
      ]

    rectFor ref = case ref of
      RefNode n -> Map.lookup n (geoShapes geo)
      RefParticipant p -> Map.lookup p (geoPools geo)
      _ -> Nothing

    route m = do
      a <- rectFor (mfSource m)
      b <- rectFor (mfTarget m)
      let (upper, lower) = if rectCenterY a <= rectCenterY b then (a, b) else (b, a)
          ax = rectCenterX a
          bx = rectCenterX b
          top = rectBottom upper
          bottom = rY lower
          ym = snapCenter ((top + bottom) `div` 2)
          pts
            | abs (ax - bx) <= alignTol =
                [Point ax (if a == upper then top else bottom), Point ax (if a == upper then bottom else top)]
            | otherwise =
                [ Point ax (if a == upper then top else bottom)
                , Point ax ym
                , Point bx ym
                , Point bx (if a == upper then bottom else top)
                ]
      pure (Route pts EcMessage (edgeBendBudget EcMessage))

tshow :: Show a => a -> T.Text
tshow = T.pack . show

emptyResult :: LayoutResult
emptyResult =
  LayoutResult
    { lrGeometry = emptyGeometry
    , lrViolations = []
    , lrScore = Score 0 [] Map.empty
    , lrStructure = Map.empty
    , lrDiagnostics = []
    }

-- | The score of a diagram made of several independently scored parts — the
-- pools of a collaboration, a process and the subprocesses inside it.
--
-- Term names and their order are the same in every 'scoreGeometry' result, so
-- adding a part to the accumulator adds its terms rather than replacing them.
-- Dropping the parts instead is what made @report@ print @score 0@ for every
-- collaboration: the number was the empty accumulator, not a verdict.
addScores :: Score -> Score -> Score
addScores a b
  | null (scTerms a) = b
  | null (scTerms b) = a
  | otherwise =
      Score
        { scTotal = scTotal a + scTotal b
        , scTerms = [(n, v + Map.findWithDefault 0 n bTerms) | (n, v) <- scTerms a]
        , scTierTotals = Map.unionWith (+) (scTierTotals a) (scTierTotals b)
        }
  where
    bTerms = Map.fromList (scTerms b)

mconcatResults :: [LayoutResult] -> LayoutResult
mconcatResults = foldl' step emptyResult
  where
    step acc r =
      LayoutResult
        { lrGeometry = mergeGeometry (lrGeometry acc) (lrGeometry r)
        , lrViolations = lrViolations acc ++ lrViolations r
        , lrScore = addScores (lrScore acc) (lrScore r)
        , lrStructure = Map.union (lrStructure acc) (lrStructure r)
        , lrDiagnostics = lrDiagnostics acc ++ lrDiagnostics r
        }
