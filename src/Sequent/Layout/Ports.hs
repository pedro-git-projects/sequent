-- | The port model — EDGE-002, and the port precedence of N-20.
--
-- Endpoints are not "wherever the line meets the box". Every node exposes
-- ports at the midpoints of its four sides, activities may additionally expose
-- offset ports, and every edge endpoint lands on exactly one of them (HC-005).
-- Modelling ports explicitly is what makes the fan idioms crossing-free by
-- construction rather than by luck: same-side ports are assigned in the order
-- of the other endpoints' perpendicular coordinates, which removes every local
-- fan crossing before any routing happens (EDGE-010 step 2).
--
-- N-20 settles the case where a single gateway is a merge, a split and a loop
-- header at once, and three rules claim its ports. The precedence is fixed:
-- @W@ is the forward entry, @N@ belongs to the loop back edge above all else,
-- @E@ is the axis exit, @S@ carries off-axis fan-out.
module Sequent.Layout.Ports
  ( PortMap (..)
  , assignPorts
  , portOf
  , sourcePort
  , targetPort
  ) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Sequent.Bpmn.Semantic
import Sequent.Layout.Analysis
import Sequent.Layout.Constants
import Sequent.Layout.Types

data PortMap = PortMap
  { pmSource :: Map FlowId Port
  , pmTarget :: Map FlowId Port
  }
  deriving (Eq, Show)

sourcePort :: PortMap -> FlowId -> Port
sourcePort pm f = Map.findWithDefault (Port PE 0) f (pmSource pm)

targetPort :: PortMap -> FlowId -> Port
targetPort pm f = Map.findWithDefault (Port PW 0) f (pmTarget pm)

portOf :: Map NodeId Rect -> NodeId -> Port -> Point
portOf shapes n p = portPoint (Map.findWithDefault emptyRect n shapes) p

-- | Assign a port to both ends of every sequence flow in a scope.
--
-- Runs after geometry because the choice of @N@ versus @S@ depends on which
-- side the other endpoint actually ended up on — which is a fact about bands,
-- read here through the rendered centres.
assignPorts :: Analysis -> Map NodeId Rect -> Map FlowId Bool -> AxisMap -> PortMap
assignPorts an shapes loopAbove axisMap = PortMap (withOffsets True srcRaw) (withOffsets False tgtRaw)
  where
    -- A loop whose corridor was allocated below the region leaves and enters
    -- through S; the canonical N/N pair is only right for a corridor above
    -- (EDGE-013 and its exception).
    loopSide f = if Map.findWithDefault True f loopAbove then PN else PS
    sc = anScope an
    byId = scopeNodeMap sc
    flows = scFlows sc

    -- LAYOUT-020: which side of a node another node sits on is a question
    -- about axes, not boxes. A container whose spine runs near its top edge is
    -- /above/ a handler that its box centre would put it below.
    cyOf n = maybe 0 (axisYOf axisMap n) (Map.lookup n shapes)
    cxOf n = maybe 0 rectCenterX (Map.lookup n shapes)
    isActivity n = maybe False nodeIsActivity (Map.lookup n byId)
    isBoundary n = maybe False nodeIsBoundary (Map.lookup n byId)
    boundaryOnTop n = case Map.lookup n byId >>= boundaryHost of
      Just att -> cyOf n < cyOf (baHost att)
      Nothing -> False

    outDeg n = length [f | f <- flows, sfSource f == n]
    inDeg n = length [f | f <- flows, sfTarget f == n]

    -- Target sides first: they depend only on the geometry, whereas a source
    -- side may have to give way to an incoming edge already using that side
    -- (N-20's surplus rule).
    tgtRaw = Map.fromList [(sfId f, tgtSide f) | f <- flows]
    srcRaw = Map.fromList [(sfId f, srcSide f) | f <- flows]

    -- N-20: when a node is both a merge and a split, the incoming fan keeps
    -- the side and the surplus outgoing branch takes the fan-corridor form
    -- from E (EDGE-005's 2-bend fallback). Sharing the port between an
    -- incoming and an outgoing edge would put them on the same vertical line
    -- running in opposite directions, which is the ambiguity EDGE-012 calls an
    -- overlap rather than a join.
    sideTaken n side =
      any
        (\f -> sfTarget f == n && Map.lookup (sfId f) tgtRaw == Just side)
        flows

    srcSide f
      -- N-20: the loop's back edge owns N outright.
      | isBackFlow an (sfId f) = loopSide (sfId f)
      | isBoundary (sfSource f) = if boundaryOnTop (sfSource f) then PN else PS
      | outDeg (sfSource f) >= 2 && offAxis f =
          -- EDGE-005: gateways peel off N/S into the comb trunk. An activity
          -- with an implicit split is different only because its /bottom/ edge
          -- belongs to its boundary events — so a downward branch keeps E and
          -- takes the 2-bend fan-corridor form.
          --
          -- The top edge usually carries nothing, and an upward branch that
          -- leaves through N runs straight up to its band: one bend instead of
          -- two, and it reads as leaving the task rather than squeezing east
          -- past it and doubling back over its own caption.
          let above = cyOf (sfTarget f) < cyOf (sfSource f)
              side = if above then PN else PS
           in if isActivity (sfSource f)
                then
                  if above && topEdgeClear (sfSource f) && not (sideTaken (sfSource f) PN)
                    then PN
                    else PE
                else if sideTaken (sfSource f) side then PE else side
      | otherwise = PE

    -- Whether an activity's top edge is free of boundary events. Read off the
    -- placed shapes rather than recomputed: LAYOUT-016 fills the bottom edge
    -- first and overflows to the top, and by the time ports are assigned the
    -- events are already sitting on whichever edge they got.
    topEdgeClear n = case Map.lookup n shapes of
      Nothing -> False
      Just r ->
        not
          ( any
              (\m -> maybe False ((== rY r) . rectCenterY) (Map.lookup m shapes))
              (boundariesOf n)
          )
    boundariesOf n =
      [fnId m | m <- scNodes sc, Just att <- [boundaryHost m], baHost att == n]

    tgtSide f
      | isBackFlow an (sfId f) = loopSide (sfId f)
      | inDeg (sfTarget f) >= 2 && offAxis f =
          if isActivity (sfTarget f)
            then PW
            else if cyOf (sfSource f) < cyOf (sfTarget f) then PN else PS
      | otherwise = PW

    offAxis f = cyOf (sfSource f) /= cyOf (sfTarget f)

    -- EDGE-002: when several edges share a side of an activity, they take
    -- offset ports. Gateways and events never do — the diamond and circle
    -- geometry makes offset attachment look like an error.
    --
    -- The offsets are measured from the node's own /axis/ and follow the side
    -- the other endpoint is actually on, so an edge whose far end is level with
    -- the node keeps the midpoint and the others step outward past it. Handing
    -- them out by position in the sorted list instead gives the midpoint to
    -- whichever edge sorted first: for a two-way implicit split that is the one
    -- that jogs away, and the straight branch is then left leaving 2U off the
    -- axis it is supposed to continue — which phase 12 straightens back onto
    -- the axis, putting the endpoint off its declared port (HC-005) and onto
    -- its sibling's line (HC-009).
    withOffsets isSource raw =
      Map.fromList
        [ (fid, Port side (clampToBox n side (axisFor n side + off)))
        | ((n, side), fids) <- Map.toAscList grouped
        , (fid, off) <- fanOffsets n side fids
        ]
      where
        grouped =
          Map.fromListWith
            (flip (++))
            [((endpoint f, side), [sfId f]) | f <- flows, Just side <- [Map.lookup (sfId f) raw]]
        endpoint f = if isSource then sfSource f else sfTarget f
        other fid = case [f | f <- flows, sfId f == fid] of
          (f : _) -> if isSource then sfTarget f else sfSource f
          [] -> NodeId ""

        fanOffsets n side fids
          | not (isActivity n) || length fids < 2 = [(fid, 0) | fid <- fids]
          | otherwise =
              [(fid, 0) | fid <- keepMid]
                ++ [(fid, negate (step k)) | (k, fid) <- zip [1 ..] nearSide]
                ++ [(fid, step k) | (k, fid) <- zip [1 ..] farSide]
          where
            -- How far the other endpoint lies from this node's axis, in the
            -- direction the side runs.
            away fid
              | side `elem` [PN, PS] = cxOf (other fid) - cxOf n
              | otherwise = cyOf (other fid) - cyOf n
            ordered = sortOn (\fid -> (away fid, unFlowId fid)) fids
            (keepMid, spare) = splitAt 1 [fid | fid <- ordered, away fid == 0]
            nearSide = reverse [fid | fid <- ordered, away fid < 0]
            farSide = [fid | fid <- ordered, away fid > 0] ++ spare
            step k = min k (maxSteps n side) * portOffsetMin

    -- LAYOUT-020 relocates the @W@ and @E@ midpoints of an expanded subprocess
    -- onto its internal spine. This is not an offset port in EDGE-002's sense —
    -- EDGE-002's midpoints are measured from the node's axis, and a container's
    -- axis is its spine rather than its centre — so the @k <= 2@ cap does not
    -- apply to it. The fan offsets above are then symmetric about the spine,
    -- which is what makes the whole fan enter the container level with the
    -- flow line it continues.
    axisFor n side
      | side `elem` [PN, PS] = 0
      | otherwise = axisOffsetOf axisMap n

    -- A port has to stay on the border it names, 1U clear of both corners.
    clampToBox n side off =
      let r = Map.findWithDefault emptyRect n shapes
          extent = if side `elem` [PN, PS] then rW r else rH r
          limit = max 0 (extent `div` 2 - u)
       in max (negate limit) (min limit off)

    -- EDGE-002 caps an offset port at @k <= 2@ steps and never closer than 2U
    -- to a corner, which for a canonical 100x80 activity means a single step
    -- either way.
    maxSteps n side =
      let r = Map.findWithDefault emptyRect n shapes
          extent = if side `elem` [PN, PS] then rW r else rH r
       in max 1 (min 2 ((extent `div` 2 - 2 * u) `div` portOffsetMin))
