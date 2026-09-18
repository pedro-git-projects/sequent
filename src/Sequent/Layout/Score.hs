-- | Phase 13 — scoring and anti-pattern detection. @RG → report@.
--
-- SPEC §K turns "is this a good diagram?" into a number, and the weights are
-- normative rather than tuned. The three ratios worth remembering, because
-- every trade-off in the engine follows from them:
--
--   * one crossing (@40@) ≈ 6.7 bends ≈ 2000 px of edge length ≈ 5
--     misalignments — crossings are expensive, length is cheap;
--   * a bend on the spine (@60@) costs more than a crossing (@40@), so bending
--     the spine to avoid a crossing is never worth it;
--   * area is a /ratio/ with a @2.5×@ free allowance, so a legitimately
--     spread-out diagram is not punished — only waste is.
--
-- Penalties are computed per region and summed, so a large diagram cannot hide
-- one badly laid-out region behind a good global average.
module Sequent.Layout.Score
  ( Score (..)
  , ScoreInput (..)
  , scoreGeometry
  , antiPatterns
  , countCrossings
  ) where

import Data.List (sortOn, tails)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)

import Sequent.Bpmn.Semantic
import Sequent.Diagnostic (RuleId (..))
import Sequent.Layout.Constants
import Sequent.Layout.Geometry (Column (..))
import Sequent.Layout.Ports
import Sequent.Layout.Types

data ScoreInput = ScoreInput
  { siScope     :: Scope
  , siShapes    :: Map NodeId Rect
  , siRoutes    :: Map FlowId Route
  , siLabels    :: Map LabelKey LabelBox
  , siColumns   :: [Column]
  , siSpine     :: [NodeId]
  , siAxis      :: AxisMap
  , siBackFlows :: Set FlowId
  , siPorts     :: PortMap
  , siRegions   :: [Region]
  , siLayers    :: Map NodeId Int
  , siMetrics   :: Metrics
  }

data Score = Score
  { scTotal :: !Double
  , scTerms :: [(Text, Double)]
  -- ^ Named contributions, in a fixed order, so a regression can be attributed
  -- to a term rather than to a number that moved.
  , scTierTotals :: Map Tier Double
  }
  deriving (Eq, Show)

scoreGeometry :: ScoreInput -> Score
scoreGeometry si =
  Score
    { scTotal = sum (map snd terms)
    , scTerms = terms
    , scTierTotals =
        Map.fromListWith
          (+)
          [ (tierOf name, val)
          | (name, val) <- terms
          ]
    }
  where
    terms =
      [ ("crossingPenalty", 40 * fromIntegral crossings)
      , ("spineBendPenalty", 60 * fromIntegral spineBends)
      , ("bendPenalty", 6 * fromIntegral overBudget + 2 * fromIntegral totalBends)
      , ("proximityPenalty", 12 * fromIntegral proximity)
      , ("labelCollision", 30 * fromIntegral labelPairs + 20 * fromIntegral labelsCrossed)
      , ("tinySegmentPenalty", 8 * fromIntegral tinySegments)
      , ("alignmentPenalty", 2 * fromIntegral offAxis + 10 * fromIntegral misalignedPairs)
      , ("gapUniformity", 25 * max 0 (columnGapCV - 0.10))
      , ("asymmetryPenalty", mSymmetryWeight (siMetrics si) * asymmetry)
      , ("sizeUniformity", 15 * max 0 (widthCV - 0.05))
      , ("labelStackPenalty", 5 * fromIntegral unstackedGateways)
      , ("areaPenalty", 8 * max 0 (areaRatio - 2.5))
      , ("edgeLengthPenalty", 0.02 * fromIntegral totalLength / fromIntegral u)
      , ("aspectPenalty", 5 * max 0 (aspect - 6.0) + 5 * max 0 (0.8 - aspect))
      ]

    tierOf n
      | n `elem` (["crossingPenalty", "spineBendPenalty", "bendPenalty", "proximityPenalty", "labelCollision", "tinySegmentPenalty"] :: [Text]) = T2
      | n `elem` (["alignmentPenalty", "gapUniformity", "asymmetryPenalty", "sizeUniformity", "labelStackPenalty"] :: [Text]) = T3
      | otherwise = T4

    sc = siScope si
    shapes = siShapes si
    routes = siRoutes si
    byId = scopeNodeMap sc
    flowById = scopeFlowMap sc

    crossings = countCrossings (siPorts si) flowById routes
    spineSet = Set.fromList (siSpine si)
    -- N-1: a spine that crosses lanes cannot have one y. The spine is defined
    -- per lane segment, and the transition edge is the sole permitted bent
    -- spine edge, so it is excluded from the penalty rather than counted.
    spineBends =
      sum
        [ routeBends r
        | (fid, r) <- Map.toAscList routes
        , Just fl <- [Map.lookup fid flowById]
        , Set.member (sfSource fl) spineSet && Set.member (sfTarget fl) spineSet
        , laneOf (sfSource fl) == laneOf (sfTarget fl)
        , not (Set.member fid (siBackFlows si))
        ]
    overBudget = sum [max 0 (routeBends r - rtBudget r) | r <- Map.elems routes]
    totalBends = sum (map routeBends (Map.elems routes))
    totalLength = sum (map routeLength (Map.elems routes))

    proximity =
      length
        [ ()
        | (fid, r) <- Map.toAscList routes
        , Just fl <- [Map.lookup fid flowById]
        , let rb = inflate (2 * edgeClear) (routeBox r)
        , (n, rect) <- Map.toAscList shapes
        , rectsOverlap rb rect
        , n /= sfSource fl && n /= sfTarget fl
        , any (\s -> segIntersectsRect s (inflate (2 * edgeClear) rect) && not (segIntersectsRect s (inflate edgeClear rect))) (routeSegments (rtPoints r))
        ]

    labelPairs =
      length
        [ ()
        | (_, a) : rest <- tails (Map.toAscList (siLabels si))
        , (_, b) <- rest
        , rectsOverlap (lbRect a) (lbRect b)
        ]

    -- §K's second label term. LABEL-011 already rejects a diagram that reaches
    -- here with either count above zero, so this is a gradient rather than a
    -- gate: it ranks the candidates phase 14 is choosing between, and a
    -- candidate that puts a connector through a caption should lose.
    labelsCrossed =
      length
        [ ()
        | (k, lb) <- Map.toAscList (siLabels si)
        , (fid, r) <- Map.toAscList routes
        , LkFlow fid /= k
        , any (`segIntersectsRect` lbRect lb) (routeSegments (rtPoints r))
        ]

    tinySegments =
      length
        [ ()
        | r <- Map.elems routes
        , s <- routeSegments (rtPoints r)
        , let l = segLength s
        , l > 0 && l < minSeg
        ]

    -- T3 --------------------------------------------------------------------
    -- LAYOUT-011: every node's centre lies on a column guide. Measured against
    -- the layer's own agreed centre rather than a precomputed column table,
    -- because the diagram is translated to the margin after the columns were
    -- built and a stale table would report every node as off-guide.
    layerCentres =
      Map.fromListWith
        (\_ old -> old)
        [ (l, rectCenterX r)
        | n <- scNodes sc
        , not (nodeIsBoundary n)
        , Just l <- [Map.lookup (fnId n) (siLayers si)]
        , Just r <- [Map.lookup (fnId n) shapes]
        ]
    offAxis =
      length
        [ ()
        | n <- scNodes sc
        , not (nodeIsBoundary n)
        , Just l <- [Map.lookup (fnId n) (siLayers si)]
        , Just r <- [Map.lookup (fnId n) shapes]
        , Map.lookup l layerCentres /= Just (rectCenterX r)
        ]

    misalignedPairs =
      length
        [ ()
        | reg <- siRegions si
        , RkSplit s (Just m) _ <- [rgKind reg]
        , Just sr <- [Map.lookup s shapes]
        , Just mr <- [Map.lookup m shapes]
        , laneOf s == laneOf m
        , abs (rectCenterY sr - rectCenterY mr) > alignTol
        ]
    laneOf n = Map.lookup n byId >>= fnLane

    uniformitySized n = case fnKind n of
      NkActivity a -> case acKind a of
        AkSubprocess _ _ -> False
        _ -> not (hasBoundary (fnId n))
      _ -> False
    hasBoundary h = any (\x -> fmap baHost (boundaryHost x) == Just h) (scNodes sc)

    columnGaps =
      [ colLeft b - (colLeft a + colWidth a)
      | (a, b) <- zip (sortOn colIndex (siColumns si)) (drop 1 (sortOn colIndex (siColumns si)))
      ]
    columnGapCV = coefficientOfVariation (map fromIntegral columnGaps)

    -- N-6: the uniformity detector excludes activities whose width was forced
    -- by something else — a boundary-event fan, label growth, or a recursive
    -- subprocess layout — or it would fire permanently on every diagram that
    -- legitimately contains one.
    activityWidths =
      [ fromIntegral (rW r)
      | n <- scNodes sc
      , uniformitySized n
      , Just r <- [Map.lookup (fnId n) shapes]
      ]
    widthCV = coefficientOfVariation activityWidths

    asymmetry = sum [max 0 (symmetryDefect reg - 0.15) | reg <- siRegions si, rgPeerSymmetric reg]
    symmetryDefect reg =
      let s = case rgKind reg of
            RkSplit sp _ _ -> Map.lookup sp shapes
            _ -> Nothing
       in case s of
            Nothing -> 0
            Just sr ->
              let axis = rectCenterY sr
                  members = mapMaybe (`Map.lookup` shapes) (rgMembers reg)
                  up = maximum (0 : [axis - rY r | r <- members])
                  down = maximum (0 : [rectBottom r - axis | r <- members])
               in if up + down == 0 then 0 else abs (fromIntegral up - fromIntegral down) / fromIntegral (up + down)

    unstackedGateways =
      length
        [ ()
        | n <- scNodes sc
        , nodeIsGateway n
        , let outs = [sfId f | f <- outgoingOf sc (fnId n), sfName f /= Nothing]
        , length outs > 1
        , let xs = [rX (lbRect b) | f <- outs, Just b <- [Map.lookup (LkFlow f) (siLabels si)]]
        , length (Set.toList (Set.fromList xs)) > 1
        ]

    -- T4 --------------------------------------------------------------------
    bbox = unionRects (Map.elems shapes)
    contentArea = sum (map rectArea (Map.elems shapes))
    areaRatio
      | contentArea == 0 = 0
      | otherwise = fromIntegral (rectArea bbox) / fromIntegral contentArea
    aspect
      | rH bbox == 0 = 1
      | otherwise = fromIntegral (rW bbox) / fromIntegral (rH bbox)

coefficientOfVariation :: [Double] -> Double
coefficientOfVariation [] = 0
coefficientOfVariation xs
  | mean == 0 = 0
  | otherwise = sqrt variance / mean
  where
    n = fromIntegral (length xs)
    mean = sum xs / n
    variance = sum [(x - mean) ^ (2 :: Int) | x <- xs] / n

-- | Transversal crossings between distinct edges, excluding bundle junctions
-- (two edges that share a port are joining, not crossing — EDGE-012).
countCrossings :: PortMap -> Map FlowId SequenceFlow -> Map FlowId Route -> Int
countCrossings ports flowById routes =
  length
    [ ()
    | (fa, ra, ba) : rest <- tails withBoxes
    , (fb, rb, bb) <- rest
    -- Two routes whose bounding boxes are disjoint cannot cross. The filter is
    -- exact (it never hides a crossing) and removes almost every pair on a
    -- diagram of any size, which is what keeps scoring off the quadratic path.
    , rectsOverlap ba bb
    , not (sharePort fa fb)
    , s1 <- routeSegments (rtPoints ra)
    , s2 <- routeSegments (rtPoints rb)
    , Just _ <- [segIntersection s1 s2]
    ]
  where
    withBoxes = [(f, r, routeBox r) | (f, r) <- Map.toAscList routes]
    sharePort a b = case (Map.lookup a flowById, Map.lookup b flowById) of
      (Just fa, Just fb) ->
        (sfSource fa == sfSource fb && sourcePort ports a == sourcePort ports b)
          || (sfTarget fa == sfTarget fb && targetPort ports a == targetPort ports b)
          || sfSource fa == sfTarget fb
          || sfTarget fa == sfSource fb
      _ -> False

-- | The computable anti-pattern detectors of §I.1. Each is reported with its
-- @AP-@ id so a diagram's problems can be named, not just scored.
antiPatterns :: ScoreInput -> [Violation]
antiPatterns si = orderViolations (concat [ap001, ap003, ap005, ap008, ap010, ap011, ap015, ap016, ap017, ap021])
  where
    sc = siScope si
    shapes = siShapes si
    routes = siRoutes si
    byId = scopeNodeMap sc
    flowById = scopeFlowMap sc
    -- LAYOUT-020: near-miss alignment and staircases are judged between
    -- connection axes. An expanded subprocess whose box centre happens to sit
    -- 3 px from a neighbour's is not a near miss — its spine is what the reader
    -- follows, and that is exactly on the line.
    axisY n r = axisYOf (siAxis si) n r
    ap rule tier msg el hint = Violation (RuleId rule) tier msg (Just hint) (Just el)

    ap001 =
      [ ap "AP-001" T0 "diagonal connector" (RefFlow fid) "re-route per EDGE-005/EDGE-015"
      | (fid, r) <- Map.toAscList routes
      , any (not . segIsOrthogonal) (routeSegments (rtPoints r))
      ]

    ap003 =
      [ ap "AP-003" T3 "split and merge are not aligned" (RefNode s) "set the merge cy to the split cy (BRANCH-012)"
      | reg <- siRegions si
      , RkSplit s (Just m) _ <- [rgKind reg]
      , Just sr <- [Map.lookup s shapes]
      , Just mr <- [Map.lookup m shapes]
      , (Map.lookup s byId >>= fnLane) == (Map.lookup m byId >>= fnLane)
      , abs (rectCenterY sr - rectCenterY mr) > alignTol
      ]

    ap005 =
      [ ap "AP-005" T3 ("near-miss alignment: " <> unNodeId a <> " and " <> unNodeId b) (RefNode a) "snap both to the band axis"
      | (a, ra) : rest <- tails (Map.toAscList shapes)
      , (b, rb) <- rest
      , let d = abs (axisY a ra - axisY b rb)
      , d > 0 && d <= alignTol
      ]

    ap008 =
      [ ap "AP-008" T2 "loopback cuts through the main flow" (RefFlow fid) "re-allocate the loop corridor (LAYOUT-018)"
      | (fid, r) <- Map.toAscList routes
      , rtClass r == EcLoopback
      , Just fl <- [Map.lookup fid flowById]
      , (n, rect) <- Map.toAscList shapes
      , n /= sfSource fl && n /= sfTarget fl
      , any (\s -> segIntersectsRect s rect) (routeSegments (rtPoints r))
      ]

    ap010 =
      [ ap "AP-010" T1 "unjustified backward movement on a forward connector" (RefFlow fid) "re-layer"
      | (fid, r) <- Map.toAscList routes
      , not (Set.member fid (siBackFlows si))
      , rtClass r /= EcSelfLoop
      , any (\(Segment a b) -> ptX b < ptX a - minSeg) (routeSegments (rtPoints r))
      ]

    ap011 =
      [ ap "AP-011" T3 "activity widths vary without cause" (RefNode (fnId n)) "reset to the canonical 100x80 (LAYOUT-003)"
      | n <- take 1 eligible
      , widthCV > 0.05
      ]
      where
        -- N-6 again: only activities whose width is genuinely free are
        -- compared.
        eligible =
          [ x
          | x <- scNodes sc
          , NkActivity a <- [fnKind x]
          , case acKind a of
              AkSubprocess _ _ -> False
              _ -> True
          , not (any (\b -> fmap baHost (boundaryHost b) == Just (fnId x)) (scNodes sc))
          ]
        ws = [fromIntegral (rW r) | x <- eligible, Just r <- [Map.lookup (fnId x) shapes]]
        widthCV = coefficientOfVariation ws

    ap015 =
      [ ap "AP-015" T2 "two gateways are too close to read as separate" (RefNode (fnId a)) "widen to COMPACT_GAP (LAYOUT-032)"
      | a <- scNodes sc
      , nodeIsGateway a
      , b <- scNodes sc
      , nodeIsGateway b
      , fnId a < fnId b
      , Just ra <- [Map.lookup (fnId a) shapes]
      , Just rb <- [Map.lookup (fnId b) shapes]
      , rectCenterY ra == rectCenterY rb
      , let gap = max (rX rb - rectRight ra) (rX ra - rectRight rb)
      , gap >= 0 && gap < compactGap
      ]

    ap016 =
      [ ap "AP-016" T3 "staircase: consecutive nodes at slightly different heights" (RefNode (fnId a)) "assign them to one band"
      | (a, b, c) <- triples (scNodes sc)
      , Just ra <- [Map.lookup (fnId a) shapes]
      , Just rb <- [Map.lookup (fnId b) shapes]
      , Just rc <- [Map.lookup (fnId c) shapes]
      , let ys = [axisY (fnId a) ra, axisY (fnId b) rb, axisY (fnId c) rc]
      , length (Set.toList (Set.fromList ys)) == 3
      , all (\(p, q) -> abs (p - q) < taskH) (zip ys (drop 1 ys))
      , chained a b && chained b c
      ]
      where
        triples xs = zip3 xs (drop 1 xs) (drop 2 xs)
        chained x y = any (\f -> sfSource f == fnId x && sfTarget f == fnId y) (scFlows sc)

    ap017 =
      [ ap "AP-017" T2 "connector has many tiny bends" (RefFlow fid) "simplify the waypoints, then re-route"
      | (fid, r) <- Map.toAscList routes
      , length [s | s <- routeSegments (rtPoints r), let l = segLength s, l > 0 && l < minSeg] >= 2
      ]

    ap021 =
      [ ap "AP-021" T2 "exception path sits above the spine while a normal branch is below" (RefNode (fnId n)) "swap the side assignment (BRANCH-007)"
      | reg <- siRegions si
      , RkSplit s _ _ <- [rgKind reg]
      , Just sr <- [Map.lookup s shapes]
      , b <- rgBranches reg
      , brPolarity b == PolException
      , brSide b == SideAbove
      , n <- take 1 [x | x <- scNodes sc, fnId x `elem` brNodes b]
      , any (\o -> brPolarity o `elem` [PolNeutral, PolPositive] && brSide o == SideBelow) (rgBranches reg)
      , rectCenterY sr > 0
      ]
