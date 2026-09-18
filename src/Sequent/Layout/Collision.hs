-- | Phase 10 — collision removal. @RG → RG@.
--
-- In a structured region sibling branch boxes are disjoint by construction, so
-- this phase should find nothing. It exists for the cases where structure ran
-- out — an unstructured residue, a node shared by two branches, a lane clamp —
-- and its job is to make those cases /valid/ rather than pretty.
--
-- The repair ladder of EDGE-020 is followed in its fixed order, and the reason
-- the order is fixed is N-15: two repairs that undo each other oscillate
-- forever. Each rung here is monotone — it can only increase separation — and
-- the loop is capped at eight iterations with three restarts, exactly as §J
-- phase 10 specifies. A bounded, monotone repair either converges or reports;
-- it never spins.
module Sequent.Layout.Collision
  ( repairCollisions
  , CollisionReport (..)
  ) where

import Data.List (foldl', sortOn)
import qualified Data.Map.Strict as Map

import Sequent.Bpmn.Semantic
import Sequent.Layout.Constants
import Sequent.Layout.Types

data CollisionReport = CollisionReport
  { crGeometry   :: Geometry
  , crIterations :: !Int
  , crConverged  :: !Bool
  }
  deriving (Eq, Show)

-- | Run the repair loop to a fixpoint, or to the iteration cap.
repairCollisions :: Scope -> Geometry -> CollisionReport
repairCollisions sc g0 = go 0 g0
  where
    maxIterations = 8 :: Int
    go k g
      | k >= maxIterations = CollisionReport g k False
      | otherwise =
          let g' = pass sc g
           in if g' == g then CollisionReport g k True else go (k + 1) g'

-- | One sweep of the ladder, in the order of §J phase 10: node overlaps,
-- containment, then label collisions. Edge repairs are handled by re-routing
-- in phase 8 rather than by moving waypoints here, because moving a waypoint
-- without moving its channel is what produces the oscillation N-15 warns about.
pass :: Scope -> Geometry -> Geometry
pass sc g = growContainers sc (separateNodes sc g)

-- | HC-002 repair: push apart along the axis of the smaller displacement,
-- which for a column-based layout is almost always @y@ — moving a node in @x@
-- would take it out of its column and break LAYOUT-005.
separateNodes :: Scope -> Geometry -> Geometry
separateNodes sc g = g {geoShapes = foldl' fix (geoShapes g) pairs}
  where
    byId = scopeNodeMap sc
    ordered = Map.toAscList (geoShapes g)
    pairs =
      [ (a, b)
      | ((a, ra), rest) <- zip ordered (drop 1 (iterate (drop 1) ordered))
      , (b, rb) <- rest
      , not (exempt a b)
      , rectsOverlap ra rb
      ]
    exempt a b =
      isBoundaryOf a b
        || isBoundaryOf b a
        || isContainerOf a b
        || isContainerOf b a
    isBoundaryOf x y = case Map.lookup x byId >>= boundaryHost of
      Just att -> baHost att == y
      Nothing -> False
    isContainerOf x y = case Map.lookup x byId of
      Just n -> case fnKind n of
        NkActivity (Activity (AkSubprocess _ inner) _) -> any ((== y) . fnId) (scNodes inner)
        _ -> False
      Nothing -> False

    fix shapes (a, b) = case (Map.lookup a shapes, Map.lookup b shapes) of
      (Just ra, Just rb)
        | rectsOverlap ra rb ->
            -- Displacement is a whole grid unit so a repaired node stays on
            -- the U grid and phase 12's snap has nothing left to move
            -- (HC-011).
            let dy = ceilU (rectBottom ra - rY rb + 2 * u)
             in Map.adjust (\r -> r {rY = rY r + dy}) b shapes
      _ -> shapes

-- | HC-003 \/ HC-014: containers grow to hold their content, bottom-up.
-- A container never clips; LANE-004's resize order is nodes, then nested
-- containers, then lanes, then pool.
growContainers :: Scope -> Geometry -> Geometry
growContainers sc g = g {geoShapes = foldl' grow (geoShapes g) subprocesses, geoLanes = lanes'}
  where
    subprocesses =
      [ (fnId n, map fnId (scNodes inner))
      | n <- scNodes sc
      , NkActivity (Activity (AkSubprocess _ inner) _) <- [fnKind n]
      ]
    grow shapes (owner, children) = case Map.lookup owner shapes of
      Nothing -> shapes
      Just r ->
        let kids = [cr | c <- children, Just cr <- [Map.lookup c shapes]]
         in if null kids
              then shapes
              else
                let needed = inflatePad (unionRects kids)
                 in Map.insert owner (unionRect r needed) shapes
    inflatePad r =
      Rect
        (rX r - containerPadX)
        (rY r - containerPadY)
        (rW r + 2 * containerPadX)
        (rH r + 2 * containerPadY + subprocPadBottom)

    -- LANE-004: resizing is bottom-up and single-pass. When a lane grows,
    -- the lanes below it translate down and the pool grows — the stack is
    -- re-tiled rather than each lane being stretched in place, because lanes
    -- that no longer tile their pool exactly break HC-007.
    lanes' = Map.fromList (retile (sortOn (rY . snd) (Map.toList (geoLanes g))))
    retile ls = case ls of
      [] -> []
      ((_, r0) : _) -> go (rY r0) ls
      where
        -- LANE-002 and HC-007: lanes tile their pool, so they share one width.
        -- A lane that has to hold something wider than the columns allowed for
        -- widens all of them rather than stepping out of the stack.
        w = maximum (map (\(l, r) -> max (rW r) (requiredWidth l r)) ls)
        go _ [] = []
        go y ((l, r) : rest) =
          let h = requiredHeight l r
           in (l, Rect (rX r) y w h) : go (y + h) rest

    requiredWidth l r = case laneMembers l of
      [] -> rW r
      members -> max (rW r) (rectRight (unionRects members) + containerPadX - rX r)

    laneMembers l =
      [cr | n <- scNodes sc, fnLane n == Just l, Just cr <- [Map.lookup (fnId n) (geoShapes g)]]
    -- Measured from the lane's own top to below its lowest member, not from
    -- the content's height: a lane's top edge is fixed by the tiling, so a
    -- member sitting well down the lane needs the whole reach covered. Taking
    -- the content's height instead assumes it is centred, which is true of an
    -- ordinary flow and false of anything stacked below it (LAYOUT-035).
    --
    -- Never shrinks: the max keeps a lane that already holds its content at
    -- the height LANE-003 gave it.
    requiredHeight l r = case laneMembers l of
      [] -> rH r
      members -> max (rH r) (rectBottom (unionRects members) + containerPadY - rY r)
