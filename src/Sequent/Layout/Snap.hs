-- | Phase 12 — alignment refinement. @RG → RG@.
--
-- LAYOUT-002 snaps /centres/, not corners. For elements with even-multiple
-- dimensions that puts the corners on the grid too; for the 36 px event the
-- corner lands on @…2@ or @…8@, which is correct and intentional — snapping
-- corners instead is what makes an event's connector meet its neighbour two
-- pixels off centre.
--
-- Snapping is the last geometric operation before scoring, and never runs
-- before collision repair (§1.3): a repaired layout that is then snapped is
-- fine, a snapped layout that is then repaired is not.
module Sequent.Layout.Snap
  ( snapGeometry
  , straightenNearStraight
  , reanchorEndpoints
  , translateToMargin
  , anchorPins
  ) where

import qualified Data.Map.Strict as Map

import Sequent.Bpmn.Semantic
import Sequent.Layout.Constants
import Sequent.Layout.Types

-- | Snap shape centres to the grid and waypoints in the axis perpendicular to
-- their segment, then simplify. Snapping never moves a shape by more than
-- @U\/2@ (LAYOUT-002).
snapGeometry :: Geometry -> Geometry
snapGeometry g =
  g
    { geoShapes = Map.map snapRect (geoShapes g)
    , geoRoutes = Map.map snapRoute (geoRoutes g)
    }

snapRect :: Rect -> Rect
snapRect r = rectFromCenter (snapCenter (rectCenterX r)) (snapCenter (rectCenterY r)) (rW r) (rH r)

-- | A waypoint is snapped in the coordinate perpendicular to the segment it
-- lies on; snapping it along the segment would shorten stubs and could break
-- HC-005.
snapRoute :: Route -> Route
snapRoute r = r {rtPoints = simplifyPoints (go (rtPoints r))}
  where
    go ps = zipWith3 fix (Nothing : map Just ps) ps (drop 1 (map Just ps) ++ [Nothing])
    fix prev p nxt =
      let horizontalNeighbour = any (\q -> maybe False ((== ptY p) . ptY) q) [prev, nxt]
          verticalNeighbour = any (\q -> maybe False ((== ptX p) . ptX) q) [prev, nxt]
       in case (prev, nxt) of
            (Nothing, _) -> p
            (_, Nothing) -> p
            _
              | horizontalNeighbour && not verticalNeighbour -> p {ptY = snapCenter (ptY p)}
              | verticalNeighbour && not horizontalNeighbour -> p {ptX = snapCenter (ptX p)}
              | otherwise -> p

simplifyPoints :: [Point] -> [Point]
simplifyPoints = dropCollinear . dropDup
  where
    dropDup (a : b : rest)
      | a == b = dropDup (a : rest)
      | otherwise = a : dropDup (b : rest)
    dropDup ps = ps
    dropCollinear (a : b : c : rest)
      | (ptX a == ptX b && ptX b == ptX c) || (ptY a == ptY b && ptY b == ptY c) =
          dropCollinear (a : c : rest)
      | otherwise = a : dropCollinear (b : c : rest)
    dropCollinear ps = ps

-- | EDGE-003 \/ AP-005: a pair whose centres differ by no more than
-- @ALIGN_TOL@ is not "nearly aligned", it is misaligned. Both go on the band
-- axis and the route becomes the zero-bend form.
straightenNearStraight :: Scope -> AxisMap -> Geometry -> Geometry
straightenNearStraight sc axisMap g = g {geoRoutes = Map.mapWithKey fix (geoRoutes g)}
  where
    flowById = scopeFlowMap sc
    fix fid r = case Map.lookup fid flowById of
      Nothing -> r
      Just fl ->
        let sy = axisYOf axisMap (sfSource fl)
            ty = axisYOf axisMap (sfTarget fl)
         in case (Map.lookup (sfSource fl) (geoShapes g), Map.lookup (sfTarget fl) (geoShapes g)) of
              (Just sr, Just tr)
                | rtClass r `elem` [EcStraight, EcSplit, EcMerge, EcCrossLane]
                , abs (sy sr - ty tr) <= alignTol
                , sy sr == ty tr
                , rX tr >= rectRight sr ->
                    r {rtPoints = [Point (rectRight sr) (sy sr), Point (rX tr) (ty tr)]}
              _ -> r

-- | HC-005's repair: put every route's first and last waypoint back on its
-- declared port.
--
-- Collision repair (phase 10) and snapping (phase 12) both move shapes, and a
-- route planned against the pre-repair position then ends a few pixels off its
-- port — visible in a modeller as a connector that stops short of the shape.
-- Re-anchoring is the repair the rule itself prescribes, and it is safe to do
-- last because it only moves the two endpoints, along the axis their stub
-- already runs on.
reanchorEndpoints :: Scope -> (FlowId -> (Port, Port)) -> Geometry -> Geometry
reanchorEndpoints sc portsOf g = g {geoRoutes = Map.mapWithKey fix (geoRoutes g)}
  where
    flowById = scopeFlowMap sc
    fix fid r = case Map.lookup fid flowById of
      Nothing -> r
      Just fl ->
        let (sp, tp) = portsOf fid
            src = portPoint (Map.findWithDefault emptyRect (sfSource fl) (geoShapes g)) sp
            tgt = portPoint (Map.findWithDefault emptyRect (sfTarget fl) (geoShapes g)) tp
         in r {rtPoints = simplifyPoints (retarget src tgt (rtPoints r))}

    -- Move the endpoint, and carry the adjacent bend with it when that bend
    -- shares the endpoint's stub axis; otherwise the stub would go diagonal.
    retarget src tgt ps = case ps of
      [] -> [src, tgt]
      [_] -> [src, tgt]
      (oldSrc : rest) ->
        let oldTgt = lastOr oldSrc rest
            mid = dropLast rest
            firstBend = case mid of
              (b : _) -> [alignTo src oldSrc b]
              [] -> []
            lastBend = case reverse mid of
              (b : _) | length mid > 1 -> [alignTo tgt oldTgt b]
              _ -> []
            inner = drop (length firstBend) (take (length mid - length lastBend) mid)
         in [src] ++ firstBend ++ inner ++ lastBend ++ [tgt]

    lastOr d [] = d
    lastOr _ xs = xs !! (length xs - 1)
    dropLast [] = []
    dropLast xs = take (length xs - 1) xs

    alignTo newEnd oldEnd bend
      | ptX bend == ptX oldEnd = bend {ptX = ptX newEnd}
      | ptY bend == ptY oldEnd = bend {ptY = ptY newEnd}
      | otherwise = bend

-- | LAYOUT-025: honour manual pins in the /final/ coordinate frame.
--
-- A pin exists so that a human's refinement survives re-formatting, which
-- means the coordinates come out of a modeller and have to mean the same thing
-- on the way back in. Everything else in the pipeline works in a floating
-- frame that LAYOUT-031 then slides to the margin, so the pins are re-anchored
-- afterwards: the diagram is translated so the first pin lands exactly, and
-- the remaining pins were already accounted for by moving their columns
-- (Layout.Geometry.applyPins).
--
-- §2.2 rule 5 settles the clash with LAYOUT-031 — both are STRONG, and the
-- lower rule id wins — except that a translation producing negative
-- coordinates would violate HC-011, which is HARD; in that case the pin is
-- left broken and reported.
anchorPins :: Map.Map NodeId (Int, Int) -> Geometry -> Geometry
anchorPins pins g = case anchor of
  Nothing -> g
  Just (px, py, r)
    | rX b >= 0 && rY b >= 0 -> moved
    | otherwise -> g
    where
      -- The translation is a whole number of grid units in both axes, for the
      -- same reason 'translateToMargin' is: HC-011 is HARD and LAYOUT-025 is
      -- STRONG, so a pin that would carry every centre off the grid is honoured
      -- to the nearest aligned position and reported broken instead. Phase 7
      -- has already resolved the pin the same way, so this normally moves
      -- nothing at all.
      moved = translateGeometry (align (px - rX r)) (align (py - rY r)) g
      b = geometryBounds moved
  where
    align d = snapCenter d
    anchor = case Map.toAscList pins of
      [] -> Nothing
      ((i, (px, py)) : _) -> (\r -> (px, py, r)) <$> Map.lookup i (geoShapes g)

-- | LAYOUT-031: translate so the union of all rendered geometry — labels and
-- waypoints included — starts at @(MARGIN, MARGIN)@.
--
-- The translation is a whole number of grid units. LAYOUT-031 asks for the
-- top-left to land exactly on the margin, but the leftmost element is often a
-- 36 px event whose left edge sits at @cx − 18@ and therefore two pixels off
-- the grid; translating by that amount would take every shape centre off the
-- grid with it. HC-011 is HARD and LAYOUT-031 is STRONG, so §2.2's priority
-- comparison settles it in favour of the grid: the diagram starts at the first
-- grid position at or beyond the margin.
translateToMargin :: Geometry -> Geometry
translateToMargin g =
  let b = geometryBounds g
   in translateGeometry (gridDelta (rX b)) (gridDelta (rY b)) g
  where
    gridDelta lo = ceilGrid (margin - lo)
    ceilGrid n =
      let q = n `div` grid
       in (if n `mod` grid == 0 then q else q + 1) * grid
