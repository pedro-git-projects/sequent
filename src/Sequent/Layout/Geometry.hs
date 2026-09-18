-- | Phases 6 and 7 — @x@ and @y@ assignment. @LLS → RG@.
--
-- This is where structure becomes pixels, and the two directions are computed
-- from completely different information, which is the point of SPEC A3: @x@
-- comes from layers (causality), @y@ comes from bands (role). Neither is ever
-- derived from the other, and no node is positioned relative to another node —
-- columns and band axes are the only datums.
--
-- LAYOUT-005 does the horizontal work: every layer becomes a column, columns
-- are as wide as their widest member, and nodes are /centred/ in them. Uniform
-- column pitch is the single largest contributor to output that looks
-- deliberate rather than generated.
module Sequent.Layout.Geometry
  ( Column (..)
  , GeomResult (..)
  , assignGeometry
  , columnsFor
  , applyPins
  , laneAxes
  , boundaryOrder
  ) where

import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Sequent.Bpmn.Semantic
import Sequent.Layout.Bands (BandResult (..), LaneKey)
import Sequent.Layout.Constants
import Sequent.Layout.Labels (flowLabelBox)
import Sequent.Layout.Types
import Sequent.Text.Metrics (FontMetrics, tbWidth)

-- | One column of the layout grid. Columns move as rigid units during
-- compaction (LAYOUT-021); a node never moves independently of its column.
data Column = Column
  { colIndex :: !Int
  , colLeft  :: !Int
  , colWidth :: !Int
  , colCentre :: !Int
  }
  deriving (Eq, Show)

data GeomResult = GeomResult
  { grShapes   :: Map NodeId Rect
  , grColumns  :: [Column]
  , grLaneRects :: Map LaneId Rect
  , grLaneAxis :: Map LaneKey Int
  , grContentBottom :: !Int
  , grBrokenPins :: [NodeId]
  -- ^ Pins that could not be honoured. LAYOUT-025: never silently dropped.
  }
  deriving (Eq, Show)

assignGeometry
  :: Metrics
  -> FontMetrics
  -> Scope
  -> Map NodeId Int
  -> Map NodeId (Int, Int)
  -> AxisMap
  -- ^ LAYOUT-020: where inside its box each node's connection axis runs.
  -> BandResult
  -> Map NodeId (Int, Int)
  -- ^ Manual pins (LAYOUT-025), by node.
  -> GeomResult
assignGeometry metrics font sc layers sizes axisMap bands pins =
  GeomResult
    { grShapes = shapes
    , grColumns = columns
    , grLaneRects = laneRects
    , grLaneAxis = axes
    , grContentBottom = contentBottom
    , grBrokenPins = broken
    }
  where
    nodes = scNodes sc
    byId = scopeNodeMap sc
    laneOrder = bandLaneOrder bands
    hasLanes = laneOrder /= [Nothing]

    -- LAYOUT-025: a pin creates its column, it does not sit outside one. The
    -- column containing a pinned node is moved onto the pin and everything to
    -- its right translates with it, so a forward edge into the pinned node
    -- cannot end up running backwards.
    -- LANE-004 / HC-003: a lane's contents are inset from its border by
    -- CONTAINER_PAD_X, the same as a pool's. Starting the columns at MARGIN
    -- instead put the first node against the lane's left edge and its caption
    -- outside the lane altogether — the right-hand padding was there because
    -- 'laneW' adds it, the left-hand one because nobody did.
    columns = applyPins pins layers sizes (columnsFor metrics font sc layers sizes contentLeft)
    contentLeft = if hasLanes then margin + containerPadX else margin
    colByIndex = Map.fromList [(colIndex c, c) | c <- columns]

    axes = laneAxes metrics bands

    -- Ordinary flow nodes: column centre for x, lane axis plus band offset for
    -- y. The datum for x is the box centre (LAYOUT-012); the datum for y is the
    -- node's /connection axis/, which is the box centre for everything except
    -- an expanded subprocess (LAYOUT-020). The band was stacked around the axis
    -- in phase 5, so the axis — not the centre — is what lands on @bandY@ here.
    placed =
      Map.fromList
        [ (fnId n, rectFromCenter cx (bandY - axisOffsetOf axisMap (fnId n)) w h)
        | n <- nodes
        , not (nodeIsBoundary n)
        , let (w, h) = Map.findWithDefault (taskW, taskH) (fnId n) sizes
        , let layer = Map.findWithDefault 0 (fnId n) layers
        , let cx = maybe margin colCentre (Map.lookup layer colByIndex)
        , let bp = Map.findWithDefault (BandPlacement Nothing 0) (fnId n) (bandPlacements bands)
        , let bandY = snapCenter (Map.findWithDefault margin (bpLane bp) axes + bpOffset bp)
        ]

    -- LAYOUT-025: "its column and band are created around it — @colCx@ is
    -- forced to the pin's @cx@, @bandAxisY@ to its @cy@". 'applyPins' above is
    -- the column half; this is the band half.
    --
    -- Moving the node on its own is what makes a pin dangerous rather than
    -- useful. A band is not a coincidence of y values: it is what everything
    -- else was measured against. Drag one node out of its band and the rest of
    -- the spine, the exception band its boundary handler sits in, and the
    -- corridor its loopback runs through all stay where the unpinned layout put
    -- them — so a pinned host lands on top of its own handler, and the
    -- connector between them has to double back to reach it.
    --
    -- So the pin moves the whole band, and carries whatever is stacked beyond it
    -- in the direction of travel: a band pushed down takes the bands below it
    -- down, a band pushed up takes the bands above it up. The lane stack works
    -- the same way one level out — a lane pushed down takes the lanes below it
    -- with it — because a lane boundary that stays put while its neighbour's
    -- content moves is a lane that no longer tiles (LANE-004, HC-007). Order
    -- and separation are preserved by construction, which is what "non-pinned
    -- nodes flow around it" has to mean once the thing pinned is a band axis.
    --
    -- Boundary events are placed from these shapes afterwards, so they follow
    -- their host without needing a case here.
    pinned = foldl' pinBand placed (Map.toAscList pins)

    gridAlignedY r py = snapCenter (py + rH r `div` 2) - rH r `div` 2

    bandOf i =
      let bp = Map.findWithDefault (BandPlacement Nothing 0) i (bandPlacements bands)
       in (bpLane bp, bpOffset bp)

    laneRank = Map.fromList (zip laneOrder [0 :: Int ..])
    rankOf l = Map.findWithDefault 0 l laneRank

    pinBand m (i, (_, py)) = case Map.lookup i m of
      Nothing -> m
      Just r
        | dy == 0 -> m
        | otherwise -> Map.mapWithKey move m
        where
          -- HC-011 is HARD and LAYOUT-025 is STRONG, so §2.2 settles a pin
          -- whose y would put the node's centre off the grid in favour of the
          -- grid: the pin is honoured to the nearest grid-aligned centre and
          -- reported broken, which is what LAYOUT-025's own exception clause
          -- asks for. Silently accepting the off-grid centre would take every
          -- node that rides along with the band off the grid too.
          dy = gridAlignedY r py - rY r
          (lane, off) = bandOf i
          move k rk
            | ridesAlong (bandOf k) = Rect (rX rk) (rY rk + dy) (rW rk) (rH rk)
            | otherwise = rk
          ridesAlong (l, o)
            | l == lane = o == off || beyond o off
            | otherwise = beyond (rankOf l) (rankOf lane)
          beyond a b = if dy > 0 then a > b else a < b

    -- A pin whose column could not move far enough left is broken. Columns
    -- only ever move right here (moving one left would push it through its
    -- predecessor), so a pin to the left of its derived column cannot be
    -- honoured and is reported rather than approximated.
    broken =
      [ i
      | (i, (px, py)) <- Map.toAscList pins
      , Just r <- [Map.lookup i pinned]
      , rX r /= px || rY r /= py
      ]

    shapes = Map.union (boundaryShapes metrics byId bands pinned sc) pinned

    -- LANE-004 tiling, but measured against the shapes rather than only against
    -- the band extents they came from.
    --
    -- The two agree exactly until a pin moves a band (LAYOUT-025): a shifted
    -- band still has the height the extent recorded, so a lane sized from the
    -- extent alone keeps its old box and the content slides out of the bottom
    -- of it (HC-003). Taking the maximum of the two means the lane follows its
    -- own content wherever a pin puts it, and is the identity everywhere else —
    -- a lane's content, unpinned, ends exactly where 'laneHeightOf' predicted.
    laneRects
      | not hasLanes = Map.empty
      | otherwise = Map.fromList (tileLanes laneTop0 [l | Just l <- laneOrder])

    laneTop0 = minimum (margin : [rY r - containerPadY | (_, rs) <- laneContent, r <- rs])

    laneContent =
      [ (l, [r | n <- nodes, fnLane n == Just l, Just r <- [Map.lookup (fnId n) shapes]])
      | Just l <- laneOrder
      ]

    tileLanes _ [] = []
    tileLanes y (l : rest) =
      (l, Rect laneX y laneW h) : tileLanes (y + h) rest
      where
        base = laneHeightOf metrics bands (Just l)
        h = case lookup l laneContent of
          Just rs@(_ : _) -> max base (maximum (map rectBottom rs) + containerPadY - y)
          _ -> base

    laneX = margin
    laneW = case columns of
      [] -> laneMinH
      _ -> maximum (map (\c -> colLeft c + colWidth c) columns) + containerPadX - margin

    contentBottom = case Map.elems shapes of
      [] -> margin
      rs -> maximum (map rectBottom rs)

-- Columns --------------------------------------------------------------------

-- | LAYOUT-005. Column widths come from the widest member; gaps come from what
-- sits on either side, in the fixed precedence fan-out, merge, compact,
-- default.
columnsFor
  :: Metrics
  -> FontMetrics
  -> Scope
  -> Map NodeId Int
  -> Map NodeId (Int, Int)
  -> Int
  -- ^ Left edge of the content area: MARGIN, or inset by the container padding
  -- when the scope has lanes.
  -> [Column]
columnsFor metrics font sc layers sizes left0 = go 0 left0
  where
    -- Two kinds of node claim no column width. A boundary event hangs on a
    -- host border; an event subprocess is on no path at all and LAYOUT-035
    -- moves it below the flow afterwards, so letting it set a column's width
    -- would leave a container-sized gap in a column it no longer occupies.
    members c =
      [ n
      | n <- scNodes sc
      , not (nodeIsBoundary n)
      , not (isEventSubprocess n)
      , Map.findWithDefault 0 (fnId n) layers == c
      ]
    maxLayer = maximum (0 : Map.elems layers)
    widthOf c = maximum (1 : [fst (Map.findWithDefault (taskW, taskH) (fnId n) sizes) | n <- members c])

    -- The column's left edge is the *snapped* node's left edge, not the raw
    -- accumulator. Snapping a centre can move a shape by up to U/2, and
    -- accumulating from the pre-snap position lets that drift into the next
    -- gap: the column boundaries would satisfy LAYOUT-005 while the visible
    -- node-to-node gaps drifted, which is exactly what LAYOUT-023's gap
    -- uniformity detector measures.
    --
    -- The centre is rounded /up/ to the grid rather than to the nearest unit,
    -- so the left edge never lands short of the accumulator. Rounding to the
    -- nearest could pull a shape back by up to U/2, shrinking the visible gap
    -- below the one 'gapAfter' asked for — and a gap narrower than @2 * MIN_SEG@
    -- has no room for a connector to turn in, which surfaces as HC-005 on any
    -- edge that has to jog between the two columns.
    go c x
      | c > maxLayer = []
      | otherwise =
          let w = widthOf c
              cx = ceilU (x + w `div` 2)
              left = cx - w `div` 2
              col = Column c left w cx
           in col : go (c + 1) (left + w + gapAfter c)

    gapAfter c
      | isFanOut c = fanoutGap c
      | isMergeInto (c + 1) = mergeGap
      | small c && small (c + 1) = compactGap
      | otherwise = mNodeGapX metrics

    small c = all (\n -> fst (Map.findWithDefault (taskW, taskH) (fnId n) sizes) <= 5 * u) (members c) && not (null (members c))

    isFanOut c = any (\n -> length (outgoingOf sc (fnId n)) >= 2) (members c)
    isMergeInto c = any (\n -> nodeIsGateway n && length (incomingOf sc (fnId n)) >= 2) (members c)

    -- BRANCH-010: the fan-out gap must fit the widest branch label, or the
    -- labels of a Yes/No decision collide with the branch's first node.
    --
    -- The @8U@ default of §B.2 is a floor rather than a fallback: the formula's
    -- other terms bottom out at @6U@, and every canonical example in §L uses
    -- @8U@ after a split. Taking the maximum of the two satisfies the formula
    -- and reproduces the reference coordinates.
    fanoutGap c =
      maximum
        [ fanoutGapDefault
        , mNodeGapX metrics
        , maxOutLabelWidth c + 2 * u
        , gwSize `div` 2 + minSeg + edgeClear
        ]
    maxOutLabelWidth c =
      maximum
        ( 0
            : [ tbWidth (flowLabelBox font t)
              | n <- members c
              , f <- outgoingOf sc (fnId n)
              , Just t <- [sfName f]
              ]
        )

-- | Move each column that holds a pinned node onto its pin, translating every
-- column to its right by the same amount. Columns never move left: honouring a
-- leftward pin would have to push its predecessor through it, and LAYOUT-025
-- says a pin that cannot be satisfied is broken and reported, never satisfied
-- by moving somebody else backwards.
applyPins :: Map NodeId (Int, Int) -> Map NodeId Int -> Map NodeId (Int, Int) -> [Column] -> [Column]
applyPins pins layers sizes cols
  | Map.null pins = cols
  | otherwise = go 0 cols
  where
    wanted =
      Map.fromListWith
        max
        [ (l, px + w `div` 2)
        | (i, (px, _)) <- Map.toAscList pins
        , Just l <- [Map.lookup i layers]
        , let (w, _) = Map.findWithDefault (taskW, taskH) i sizes
        ]
    go _ [] = []
    go shift (c : rest) =
      let base = colCentre c + shift
          target = max base (Map.findWithDefault base (colIndex c) wanted)
          c' = c {colCentre = target, colLeft = target - colWidth c `div` 2}
       in c' : go (target - colCentre c) rest

-- Lanes ----------------------------------------------------------------------

-- | LANE-003: lane height follows content, never a common maximum. Forcing a
-- lane with three tasks to the height of a lane with a nested region wastes an
-- enormous amount of vertical space and dilutes the lane-to-content link.
-- | LANE-004 tiles lanes from the top, so every lane top has to stay on the
-- grid or the tiling walks off it. Rounding each half of the content extent up
-- to a whole unit keeps the height, the top and the lane's own axis all grid
-- multiples, which is what lets the snapped band offsets of phase 5 land inside
-- the padding this height reserves for them (HC-003).
laneHeightOf :: Metrics -> BandResult -> LaneKey -> Int
laneHeightOf _ bands l =
  max laneMinH (ceilU (exAbove e) + ceilU (exBelow e) + 2 * containerPadY)
  where
    e = Map.findWithDefault mempty l (bandLaneExtent bands)

laneTopsOf :: Metrics -> BandResult -> Map LaneKey Int
laneTopsOf metrics bands = Map.fromList (zip order tops)
  where
    order = bandLaneOrder bands
    tops = scanl (\y l -> y + laneHeightOf metrics bands l) margin order

-- | LANE-006: each lane has its own baseline, at the vertical centre of the
-- lane's /content/ rather than of its rectangle. There is no global process
-- baseline once lanes have different heights, and pretending otherwise is what
-- makes generated collaboration diagrams drift.
laneAxes :: Metrics -> BandResult -> Map LaneKey Int
laneAxes metrics bands =
  Map.fromList
    [ (l, top + containerPadY + ceilU (exAbove (Map.findWithDefault mempty l (bandLaneExtent bands))))
    | (l, top) <- Map.toAscList (laneTopsOf metrics bands)
    ]

-- Boundary events ------------------------------------------------------------

-- | LAYOUT-016. Boundary events attach to the host's bottom edge first,
-- overflowing to the top, never to the entry or exit edge, and are distributed
-- evenly along it.
boundaryShapes
  :: Metrics
  -> Map NodeId FlowNode
  -> BandResult
  -> Map NodeId Rect
  -> Scope
  -> Map NodeId Rect
boundaryShapes _ byId bands placed sc =
  Map.fromList
    [ (bid, shape)
    | (host, evs) <- Map.toAscList grouped
    , Just hostRect <- [Map.lookup host placed]
    , let ordered = boundaryOrder byId bands sc host evs
    , let kBottom = boundaryCapacity (rW hostRect)
    , let (bottoms, tops) = splitAt kBottom ordered
    , (bid, shape) <- distribute hostRect True bottoms ++ distribute hostRect False tops
    ]
  where
    grouped =
      Map.fromListWith
        (flip (++))
        [(baHost att, [fnId n]) | n <- scNodes sc, Just att <- [boundaryHost n]]

    distribute hostRect bottom evs =
      [ (bid, rectFromCenter cx cy evSize evSize)
      | (j, bid) <- zip [1 ..] evs
      , let cx = snapCenter (rX hostRect + (rW hostRect * j) `div` (length evs + 1))
      , let cy = if bottom then rectBottom hostRect else rY hostRect
      ]

-- | The left-to-right order of a host's boundary events.
--
-- LAYOUT-016 sorts by /descending handler-band distance/, and the reason is
-- geometric rather than aesthetic: if a left event's handler band were nearer
-- the host than a right event's, the right event's downward stub would cross
-- the left event's horizontal run. Putting the farthest band leftmost makes
-- the whole exception fan crossing-free by construction.
boundaryOrder :: Map NodeId FlowNode -> BandResult -> Scope -> NodeId -> [NodeId] -> [NodeId]
boundaryOrder byId bands sc host evs = sortOn key evs
  where
    hostOffset = offsetOf host
    offsetOf n = maybe 0 bpOffset (Map.lookup n (bandPlacements bands))
    handlerDistance b =
      case [sfTarget f | f <- scFlows sc, sfSource f == b] of
        (t : _) -> abs (offsetOf t - hostOffset)
        [] -> 0
    key b =
      ( negate (handlerDistance b)
      , typePriority b
      , maybe maxBound fnDocOrder (Map.lookup b byId)
      , unNodeId b
      )
    typePriority b = case Map.lookup b byId >>= eventDefOf of
      Just (EdError _) -> 0 :: Int
      Just (EdEscalation _) -> 1
      Just EdCompensation -> 7
      Just (EdTimer _) -> 4
      Just (EdMessage _) -> 5
      Just (EdSignal _) -> 6
      _ -> 3
    eventDefOf n = case fnKind n of
      NkEvent (EventSpec _ d) -> d
      _ -> Nothing
