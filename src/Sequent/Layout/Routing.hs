-- | Phase 8 — connector routing. @RG → RG.waypoints@.
--
-- Routing is a subsystem, not a post-processing step. EDGE-008 makes the point
-- that routable space is /modelled/ rather than searched: vertical channels
-- live in the gaps between columns, horizontal channels between bands, trunk
-- channels at a split or merge node's centre, and loop corridors outside a
-- region's box. Every non-straight edge is assigned specific channels before
-- any waypoint exists, so routing reduces to connecting two ports through
-- channels that are known to be free.
--
-- The route classes are the catalogue of EDGE-025, and each is generated in its
-- canonical form first. Where more than one legal route exists, EDGE-019's cost
-- function chooses — crossings at @40@, bends at @6@, length at @0.02@ per
-- pixel, which encodes the normative answer of §2.1: a long straight connector
-- is far more readable than a short bendy one.
module Sequent.Layout.Routing
  ( RouteResult (..)
  , routeAll
  , classifyEdge
  , boundaryExceptionRoute
  , routeCost
  , channelX
  ) where

import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Sequent.Bpmn.Semantic
import Sequent.Layout.Analysis
import Sequent.Layout.Bands (BandResult (..))
import Sequent.Layout.Constants
import Sequent.Layout.Geometry (Column (..))
import Sequent.Layout.Ports
import Sequent.Layout.Types

data RouteResult = RouteResult
  { rrRoutes   :: Map FlowId Route
  , rrChannels :: Map FlowId Int
  -- ^ Which channel index each jogging edge was given, for diagnostics and for
  -- the compaction constraints of N-14.
  }
  deriving (Eq, Show)

data RCtx = RCtx
  { rcScope    :: Scope
  , rcAnalysis :: Analysis
  , rcShapes   :: Map NodeId Rect
  , rcPorts    :: PortMap
  , rcLayers   :: Map NodeId Int
  , rcColumns  :: Map Int Column
  , rcMetrics  :: Metrics
  , rcCorridor :: Map FlowId (Int, Bool)
  -- ^ Absolute @y@ of each back edge's reserved loop corridor, and whether it
  -- was allocated above the region.
  , rcNodes    :: Map NodeId FlowNode
  , rcAxis     :: AxisMap
  }

routeAll
  :: Metrics
  -> Analysis
  -> Map NodeId Rect
  -> PortMap
  -> Map NodeId Int
  -> [Column]
  -> BandResult
  -> Map (Maybe LaneId) Int
  -> AxisMap
  -> RouteResult
routeAll metrics an shapes ports layers columns bands laneAxes0 axisMap =
  RouteResult
    { rrRoutes = Map.fromList [(sfId f, r) | (f, r, _) <- routed]
    , rrChannels = Map.fromList [(sfId f, c) | (f, _, Just c) <- routed]
    }
  where
    ctx =
      RCtx
        { rcScope = anScope an
        , rcAnalysis = an
        , rcShapes = shapes
        , rcPorts = ports
        , rcLayers = layers
        , rcColumns = Map.fromList [(colIndex c, c) | c <- columns]
        , rcMetrics = metrics
        , rcCorridor = corridorY
        , rcNodes = scopeNodeMap (anScope an)
        , rcAxis = axisMap
        }

    corridorY =
      Map.fromList
        [ (coFlow c, (Map.findWithDefault margin (coLane c) laneAxes0 + coOffset c, coAbove c))
        | c <- bandCorridors bands
        ]

    -- EDGE-008: channel assignment order is fixed, so two runs hand out the
    -- same channels in the same order.
    ordered =
      sortOn
        (\f -> (layerOf (sfSource f), bandOf (sfSource f), bandOf (sfTarget f), unFlowId (sfId f)))
        (scFlows (anScope an))
    layerOf n = Map.findWithDefault 0 n layers
    bandOf n = maybe 0 bpOffset (Map.lookup n (bandPlacements bands))

    routed = go Map.empty ordered
    go _ [] = []
    go used (f : fs) =
      let (r, mch, used') = routeOne ctx used f
       in (f, r, mch) : go used' fs

-- Classification ---------------------------------------------------------------

-- | EDGE-025's catalogue. Classification happens once and decides both the
-- canonical route shape and the bend budget it is checked against.
classifyEdge :: RCtx -> SequenceFlow -> EdgeClass
classifyEdge ctx f
  | sfSource f == sfTarget f = EcSelfLoop
  | isBackFlow (rcAnalysis ctx) (sfId f) = EcLoopback
  | isBoundary (sfSource f) = EcBoundary
  | crossesLane = EcCrossLane
  | outDeg (sfSource f) >= 2 && offAxis = EcSplit
  | inDeg (sfTarget f) >= 2 && offAxis = EcMerge
  | not offAxis = EcStraight
  | otherwise = EcUnstructured
  where
    sc = rcScope ctx
    byId = rcNodes ctx
    isBoundary n = maybe False nodeIsBoundary (Map.lookup n byId)
    laneOf n = Map.lookup n byId >>= fnLane
    crossesLane = laneOf (sfSource f) /= laneOf (sfTarget f)
    outDeg n = length (outgoingOf sc n)
    inDeg n = length (incomingOf sc n)
    offAxis = cy (sfSource f) /= cy (sfTarget f)
    -- LAYOUT-020: "same line" is a question about connection axes. Comparing
    -- box centres would classify a straight run into an expanded subprocess as
    -- off-axis and send it through a channel it does not need.
    cy n = maybe 0 (axisYOf (rcAxis ctx) n) (Map.lookup n (rcShapes ctx))

-- Routing --------------------------------------------------------------------

routeOne :: RCtx -> Map (Int, Int) Int -> SequenceFlow -> (Route, Maybe Int, Map (Int, Int) Int)
routeOne ctx used f = case cls of
  EcStraight -> (mk EcStraight 0 [srcPt, tgtPt], Nothing, used)
  EcSplit -> splitRoute
  EcMerge -> (mk EcMerge (edgeBendBudget EcMerge) (mergeComb), Nothing, used)
  EcCrossLane -> zRoute EcCrossLane
  EcLoopback -> (mk EcLoopback (edgeBendBudget EcLoopback) loopRoute, Nothing, used)
  EcSelfLoop -> (mk EcSelfLoop (edgeBendBudget EcSelfLoop) selfRoute, Nothing, used)
  EcBoundary -> let (budget, ps) = boundaryRoute in (Route ps EcBoundary budget, Nothing, used)
  _ -> zRoute EcUnstructured
  where
    cls = classifyEdge ctx f
    shapes = rcShapes ctx
    srcR = Map.findWithDefault emptyRect (sfSource f) shapes
    tgtR = Map.findWithDefault emptyRect (sfTarget f) shapes
    sp = sourcePort (rcPorts ctx) (sfId f)
    tp = targetPort (rcPorts ctx) (sfId f)
    srcPt = portPoint srcR sp
    tgtPt = portPoint tgtR tp

    mk c budget ps = Route (simplify ps) c budget

    -- EDGE-005: the comb. The axis branch leaves straight east; every other
    -- branch leaves through N or S, runs vertically to its branch axis, then
    -- east into the target's W port. One bend, and the vertical segments of
    -- same-side siblings are bundle-collinear at the trunk, which is legal
    -- under EDGE-009 because they share a port.
    splitRoute
      | portSide sp == PE =
          -- The activity fallback of EDGE-005: a 2-bend fan corridor, because
          -- an activity's bottom edge belongs to its boundary events.
          let (x, used') = takeChannel ctx used (sfSource f)
           in (mk EcSplit 2 [srcPt, Point x (ptY srcPt), Point x (ptY tgtPt), tgtPt], Just x, used')
      | otherwise =
          ( mk EcSplit (edgeBendBudget EcSplit)
              [srcPt, Point (ptX srcPt) (ptY tgtPt), tgtPt]
          , Nothing
          , used
          )

    -- EDGE-006: the mirror. Each non-axis branch runs east along its own axis
    -- to the merge's centre x, then turns vertically into its N or S port.
    mergeComb
      | portSide tp == PW = [srcPt, Point (ptX tgtPt) (ptY srcPt), tgtPt]
      | otherwise = [srcPt, Point (ptX tgtPt) (ptY srcPt), tgtPt]

    -- EDGE-015: the Z. East progress first, the lane divider crossed in empty
    -- inter-column space, two bends — the theoretical minimum for a lane
    -- change with distinct y.
    zRoute c
      | ptY srcPt == ptY tgtPt = (mk c (edgeBendBudget c) [srcPt, tgtPt], Nothing, used)
      | otherwise =
          let (x, used') = takeChannel ctx used (sfSource f)
           in (mk c (edgeBendBudget c) [srcPt, Point x (ptY srcPt), Point x (ptY tgtPt), tgtPt], Just x, used')

    -- EDGE-013: out of the source's N port, along a reserved corridor, down
    -- into the target's N port. The downward arrowhead into the top is what
    -- makes "return here" unmistakable.
    loopRoute =
      let (y0, above) =
            Map.findWithDefault (min (rY srcR) (rY tgtR) - loopClear, True) (sfId f) (rcCorridor ctx)
          y
            | above = min y0 (min (rY srcR) (rY tgtR) - loopClear)
            | otherwise = max y0 (max (rectBottom srcR) (rectBottom tgtR) + loopClear)
          edgeOf r = if above then rY r else rectBottom r
       in [ Point (rectCenterX srcR) (edgeOf srcR)
          , Point (rectCenterX srcR) y
          , Point (rectCenterX tgtR) y
          , Point (rectCenterX tgtR) (edgeOf tgtR)
          ]

    -- EDGE-013's exception: the compact self-loop.
    selfRoute =
      let cx = rectCenterX srcR
          top = rY srcR
          y = top - 3 * u
          x = rectRight srcR + 3 * u
          ay = axisYOf (rcAxis ctx) (sfSource f) srcR
       in [Point cx top, Point cx y, Point x y, Point x ay, Point (rectRight srcR) ay]

    -- EDGE-014, delegated to 'boundaryExceptionRoute' so the geometry can be
    -- exercised directly. A boundary event with no host is not a thing the
    -- resolver can produce; treating the source's own box as the host is the
    -- degenerate answer and yields the canonical L.
    boundaryRoute =
      boundaryExceptionRoute
        (fromMaybe srcR hostRect)
        srcPt
        tp
        tgtPt
      where
        hostRect = case Map.lookup (sfSource f) (rcNodes ctx) >>= boundaryHost of
          Just att -> Map.lookup (baHost att) shapes
          Nothing -> Nothing

-- | EDGE-014 — the exception route of a boundary event, as a function of the
-- geometry alone.
--
-- The rule is one sentence: __no segment of an exception route touches the
-- host__. The stub starts on the host's border, so it is already the one
-- connector in the diagram that begins inside the shape it must not cross, and
-- every form below is a different answer to the same question — where can this
-- line turn without going back into the box it came out of?
--
-- The forms are generated in order of preference and the first one clear of the
-- host wins. Generating and filtering, rather than deciding by cases, is what
-- makes the property hold by construction: a form that would cut through the
-- host cannot be selected however the geometry is arranged. When every form
-- hits the host — a handler that can only be entered through a side the host
-- itself blocks, which needs a different port rather than a different route
-- (EDGE-020 rung 3) — the last is emitted and HC-004 names it, instead of the
-- router quietly drawing a line through a task.
--
-- Taking the geometry as arguments rather than reading it out of 'RCtx' is
-- deliberate. Layering and column separation currently keep a handler to the
-- right of its host, so a @.sq@ file can only ever reach the first two forms;
-- the ones that need a host-aware escape corridor are reachable only by
-- constructing the geometry, which is exactly what the tests do.
boundaryExceptionRoute
  :: Rect
  -- ^ The host the boundary event is attached to.
  -> Point
  -- ^ The source port point, on the boundary event's border.
  -> Port
  -- ^ The target's port; the approach has to be perpendicular to its side.
  -> Point
  -- ^ The target port point.
  -> (Int, [Point])
  -- ^ Bend budget for the chosen form, and its waypoints.
boundaryExceptionRoute host s tp q =
  case ([c | c <- candidates, legal (snd c)], [c | c <- candidates, clearOfHost (snd c)]) of
    (c : _, _) -> c
    -- Graded, because the two conditions are not equally negotiable. A handler
    -- whose port faces a side the host itself blocks — 2U to the right of the
    -- host, entered through @W@ at the host's own mid-height — cannot be
    -- reached legally by any route; it needs a different port (EDGE-020 rung 3)
    -- or more room. Given that, arriving at the port from an odd angle is
    -- HC-005's business and gets reported; drawing a line through a task is
    -- never the better answer.
    ([], c : _) -> c
    ([], []) -> last candidates
  where
    candidates = [(b, simplify ps) | (b, ps) <- forms]

    -- Two conditions, and both have to be checked on the /simplified/ points,
    -- because dropping a collinear waypoint can turn an excursion back into
    -- the straight line it was built to avoid.
    legal ps = clearOfHost ps && entersCorrectly ps
    clearOfHost ps = not (any (`segIntersectsRect` host) (routeSegments ps))

    -- EDGE-024: the arrowhead has to arrive at the port from outside the shape.
    -- A route can be perfectly clear of the host and still reach a @W@ port
    -- from the right, which draws an arrow pointing back into the diagram.
    entersCorrectly ps = case reverse ps of
      (end : prev : _) -> case portSide tp of
        PW -> ptX prev < ptX end
        PE -> ptX prev > ptX end
        PN -> ptY prev < ptY end
        PS -> ptY prev > ptY end
      _ -> True

    forms
      | vertical = [(0, [s, q]) | ptX s == ptX q] ++ [verticalTurn] ++ map excursion corridors
      | otherwise = [(0, [s, q]) | ptY s == ptY q] ++ [canonicalL] ++ map detour corridors

    -- The canonical form of EDGE-014: drop to the handler band, then east into
    -- the handler's W port. One bend.
    canonicalL = (1, [s, Point (ptX s) (ptY q), q])

    -- A vertical port is entered along a vertical run. Turning east at the
    -- handler's y and arriving along its bottom edge is what draws an
    -- arrowhead sliding into the side of a shape.
    verticalTurn = (2, [s, Point (ptX s) turnY, Point (ptX q) turnY, q])

    -- The handler is level with the host, so the canonical L would turn inside
    -- it: run past the host first, then come back to the handler's y.
    detour jx = (3, [s, Point (ptX s) awayY, Point jx awayY, Point jx (ptY q), q])

    -- The handler is on the far side of the host from the stub, and is entered
    -- through a vertical port: leave the host, cross its band in a corridor
    -- beside it, and come back along the approach. Four bends is the price of a
    -- handler the stub has to travel away from before it can reach it.
    excursion jx =
      ( 4
      , [ s
        , Point (ptX s) awayY
        , Point jx awayY
        , Point jx approachY
        , Point (ptX q) approachY
        , q
        ]
      )

    vertical = portSide tp `elem` [PN, PS]
    -- Which way the stub leaves: away from the border it is attached to.
    down = ptY s >= rectCenterY host
    -- The first y at which the stub may turn: past its own MIN_SEG, and 1U
    -- clear of the host border it started on (EDGE-014).
    awayY
      | down = max (ptY s + minSeg) (rectBottom host + u)
      | otherwise = min (ptY s - minSeg) (rY host - u)

    -- The last horizontal run before a vertical port, on the side that port is
    -- approached from and MIN_SEG clear of it.
    fromBelow = portSide tp == PS
    approachY
      | fromBelow = ptY q + minSeg
      | otherwise = ptY q - minSeg

    -- 'verticalTurn' turns there directly out of the stub, so its run also has
    -- to be a whole MIN_SEG away from the source and on the side the stub
    -- leaves by. 'excursion' has already turned at @awayY@ and is under no such
    -- obligation — which is the whole point of it: it can put its run on the
    -- far side of the host, where the stub could never have reached alone.
    turnY
      | down = max approachY (ptY s + minSeg)
      | otherwise = min approachY (ptY s - minSeg)

    -- The escape corridors: the x values at which a vertical may cross the
    -- host's band. Offered in order of preference and filtered like everything
    -- else, so the choice is "the nearest one that works" rather than a case
    -- analysis of which one ought to.
    --
    -- The first two are the useful ones: as close to the target as the host
    -- allows, on each side, right first so a route only reaches backwards when
    -- the target genuinely lies that way. Then the two that hug the host, for a
    -- target whose approach room the first pair overshot. Then the two beyond
    -- the target, which are what a vertical port directly past the host needs —
    -- the corridor cannot share the target's own @x@, or the run into the port
    -- doubles back along the line it arrived on and simplifies away to nothing.
    corridors =
      [ max (rectRight host + minSeg) approachX
      , min (rX host - minSeg) approachX
      , rectRight host + minSeg
      , rX host - minSeg
      , ptX q + minSeg
      , ptX q - minSeg
      ]
    approachX = case portSide tp of
      PW -> ptX q - minSeg
      PE -> ptX q + minSeg
      _ -> ptX q

-- | EDGE-008 \/ EDGE-015: a vertical channel in the gap between two columns.
--
-- Channel zero is the gap midpoint, which is where EDGE-015 puts the jog of a
-- cross-lane Z; further channels step outward by @CORRIDOR_PITCH@. The result
-- is clamped so both stubs keep their @MIN_SEG@ length (HC-005) — a jog placed
-- at @EDGE_CLEAR@ from the column edge would leave a 15 px stub and read as a
-- bend against the shape border.
channelX :: Column -> Maybe Column -> Int -> Int
channelX col mnext j = case mnext of
  Nothing -> right + minSeg + j * corridorPitch
  Just nxt ->
    let lo = right + minSeg
        hi = colLeft nxt - minSeg
        mid = snapCenter ((right + colLeft nxt) `div` 2)
     in max lo (min (max lo hi) (mid + j * corridorPitch))
  where
    right = colLeft col + colWidth col

takeChannel :: RCtx -> Map (Int, Int) Int -> NodeId -> (Int, Map (Int, Int) Int)
takeChannel ctx used src = (channelX col nxt j, Map.insert key (j + 1) used)
  where
    layer = Map.findWithDefault 0 src (rcLayers ctx)
    col = Map.findWithDefault (Column layer margin taskW margin) layer (rcColumns ctx)
    nxt = Map.lookup (layer + 1) (rcColumns ctx)
    key = (layer, 0)
    j = min (mMaxChannels (rcMetrics ctx) - 1) (Map.findWithDefault 0 key used)

-- | HC-010: no duplicate consecutive points and no collinear intermediate
-- point. Applied to every route as it is built, so a degenerate waypoint never
-- reaches the validator.
simplify :: [Point] -> [Point]
simplify = dropCollinear . dropDuplicates
  where
    dropDuplicates (a : b : rest)
      | a == b = dropDuplicates (a : rest)
      | otherwise = a : dropDuplicates (b : rest)
    dropDuplicates ps = ps

    dropCollinear (a : b : c : rest)
      | (ptX a == ptX b && ptX b == ptX c) || (ptY a == ptY b && ptY b == ptY c) =
          dropCollinear (a : c : rest)
      | otherwise = a : dropCollinear (b : c : rest)
    dropCollinear ps = ps

-- | EDGE-019. Used to choose among candidate routes; the relative magnitudes
-- are normative, not tuned: one crossing is worth about 6.7 bends or 2000 px
-- of length.
routeCost :: Int -> Int -> Int -> Int -> Int -> Int -> Double
routeCost bends crossings lengthPx proximity backwardU channelIndex =
  6.0 * fromIntegral bends
    + 40.0 * fromIntegral crossings
    + 0.02 * fromIntegral lengthPx
    + 12.0 * fromIntegral proximity
    + 25.0 * fromIntegral backwardU
    + 8.0 * fromIntegral channelIndex
