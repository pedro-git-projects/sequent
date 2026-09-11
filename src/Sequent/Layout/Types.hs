-- | The two layout representations, and the vocabulary shared by the phases.
--
-- SPEC §0 keeps three models apart, and so does this module:
--
--   * @SG@ is "Sequent.Bpmn.Semantic" and is never touched here;
--   * @LLS@ — 'LayoutStructure' — is /structure/: regions, layers, bands,
--     branch order, ports, corridors. It has no pixels;
--   * @RG@ — 'Geometry' — is pixels: rectangles, waypoints, label boxes.
--
-- The separation is not bookkeeping. Phases 1–5 may only write @LLS@, so a bug
-- that tries to "just nudge a node" in the region phase does not typecheck.
-- Phases 6–12 write @RG@ from @LLS@, so every coordinate is traceable to a
-- structural decision rather than to an accumulated adjustment.
module Sequent.Layout.Types
  ( -- * Rendered geometry primitives
    Point (..)
  , Rect (..)
  , rectRight
  , rectBottom
  , rectCenterX
  , rectCenterY
  , rectFromCenter
  , inflate
  , translateRect
  , rectsOverlap
  , rectContains
  , unionRect
  , unionRects
  , emptyRect
  , rectArea
    -- * Segments
  , Segment (..)
  , routeSegments
  , segIsOrthogonal
  , segIntersectsRect
  , segIntersection
  , segLength
  , collinearOverlap
    -- * Ports
  , PortSide (..)
  , Port (..)
  , portPoint
  , oppositeSide
  , sideNormal
    -- * Connection axes
  , AxisMap
  , axisOffsetOf
  , axisYOf
    -- * Edges
  , EdgeClass (..)
  , edgeBendBudget
  , Route (..)
  , routeBends
  , routeLength
  , routeBox
    -- * Labels
  , LabelKey (..)
  , LabelBox (..)
    -- * Structural vocabulary (LLS)
  , Side (..)
  , Polarity (..)
  , StackMode (..)
  , BranchId (..)
  , RegionId (..)
  , RegionKind (..)
  , Region (..)
  , Branch (..)
  , Extent (..)
  , extentH
  , mergeExtent
  , Corridor (..)
  , BandPlacement (..)
  , LayoutStructure (..)
    -- * Rendered geometry (RG)
  , Geometry (..)
  , emptyGeometry
  , geometryBounds
  , translateGeometry
    -- * Diagnostics
  , Violation (..)
  , Tier (..)
  , violationDiag
  , orderViolations
  ) where

import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Sequent.Bpmn.Semantic
import Sequent.Diagnostic (Diagnostic, RuleId (..), layoutAdvisory, layoutViolation, withHint)

-- Geometry primitives --------------------------------------------------------

data Point = Point
  { ptX :: !Int
  , ptY :: !Int
  }
  deriving (Eq, Ord, Show)

data Rect = Rect
  { rX :: !Int
  , rY :: !Int
  , rW :: !Int
  , rH :: !Int
  }
  deriving (Eq, Ord, Show)

rectRight, rectBottom, rectCenterX, rectCenterY :: Rect -> Int
rectRight r = rX r + rW r
rectBottom r = rY r + rH r
rectCenterX r = rX r + rW r `div` 2
rectCenterY r = rY r + rH r `div` 2

-- | Build a rectangle from its centre. Centres are the datum for every
-- vertical relationship (LAYOUT-012), so this is the constructor the geometry
-- phases use; @x@ and @y@ are derived, never assigned.
rectFromCenter :: Int -> Int -> Int -> Int -> Rect
rectFromCenter cx cy w h = Rect (cx - w `div` 2) (cy - h `div` 2) w h

inflate :: Int -> Rect -> Rect
inflate d (Rect x y w h) = Rect (x - d) (y - d) (w + 2 * d) (h + 2 * d)

translateRect :: Int -> Int -> Rect -> Rect
translateRect dx dy (Rect x y w h) = Rect (x + dx) (y + dy) w h

-- | Strict overlap: touching edges do not overlap.
rectsOverlap :: Rect -> Rect -> Bool
rectsOverlap a b =
  rX a < rectRight b && rX b < rectRight a && rY a < rectBottom b && rY b < rectBottom a

rectContains :: Rect -> Rect -> Bool
rectContains outer inner =
  rX inner >= rX outer
    && rY inner >= rY outer
    && rectRight inner <= rectRight outer
    && rectBottom inner <= rectBottom outer

unionRect :: Rect -> Rect -> Rect
unionRect a b = Rect x y (x' - x) (y' - y)
  where
    x = min (rX a) (rX b)
    y = min (rY a) (rY b)
    x' = max (rectRight a) (rectRight b)
    y' = max (rectBottom a) (rectBottom b)

unionRects :: [Rect] -> Rect
unionRects [] = emptyRect
unionRects (r : rs) = foldl' unionRect r rs

emptyRect :: Rect
emptyRect = Rect 0 0 0 0

rectArea :: Rect -> Int
rectArea r = rW r * rH r

-- Segments -------------------------------------------------------------------

data Segment = Segment
  { segA :: !Point
  , segB :: !Point
  }
  deriving (Eq, Ord, Show)

routeSegments :: [Point] -> [Segment]
routeSegments ps = zipWith Segment ps (drop 1 ps)

segIsOrthogonal :: Segment -> Bool
segIsOrthogonal (Segment a b) = ptX a == ptX b || ptY a == ptY b

segLength :: Segment -> Int
segLength (Segment a b) = abs (ptX a - ptX b) + abs (ptY a - ptY b)

-- | Does an axis-parallel segment touch a rectangle? Used with an inflated
-- rectangle to implement the @EDGE_CLEAR@ test of HC-004.
segIntersectsRect :: Segment -> Rect -> Bool
segIntersectsRect (Segment a b) r =
  lo1 <= rectRight r && rX r <= hi1 && lo2 <= rectBottom r && rY r <= hi2
  where
    lo1 = min (ptX a) (ptX b)
    hi1 = max (ptX a) (ptX b)
    lo2 = min (ptY a) (ptY b)
    hi2 = max (ptY a) (ptY b)

-- | The transversal intersection point of a horizontal and a vertical segment,
-- if they genuinely cross (endpoints touching do not count as a crossing).
segIntersection :: Segment -> Segment -> Maybe Point
segIntersection s1 s2
  | isH s1 && isV s2 = cross s1 s2
  | isV s1 && isH s2 = cross s2 s1
  | otherwise = Nothing
  where
    isH (Segment a b) = ptY a == ptY b && ptX a /= ptX b
    isV (Segment a b) = ptX a == ptX b && ptY a /= ptY b
    cross (Segment ha hb) (Segment va vb) =
      let y = ptY ha
          x = ptX va
          xlo = min (ptX ha) (ptX hb)
          xhi = max (ptX ha) (ptX hb)
          ylo = min (ptY va) (ptY vb)
          yhi = max (ptY va) (ptY vb)
       in if xlo < x && x < xhi && ylo < y && y < yhi
            then Just (Point x y)
            else Nothing

-- | Length of the collinear overlap of two parallel segments at zero distance.
-- HC-009 prohibits any such overlap outside a bundle.
collinearOverlap :: Segment -> Segment -> Int
collinearOverlap (Segment a1 b1) (Segment a2 b2)
  | ptY a1 == ptY b1 && ptY a2 == ptY b2 && ptY a1 == ptY a2 =
      overlap (ptX a1) (ptX b1) (ptX a2) (ptX b2)
  | ptX a1 == ptX b1 && ptX a2 == ptX b2 && ptX a1 == ptX a2 =
      overlap (ptY a1) (ptY b1) (ptY a2) (ptY b2)
  | otherwise = 0
  where
    overlap p q r s = max 0 (min (max p q) (max r s) - max (min p q) (min r s))

-- Ports ----------------------------------------------------------------------

data PortSide = PN | PE | PS | PW
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A port is a side plus an offset along it (EDGE-002). Gateways and events
-- only ever use offset @0@: the diamond and circle geometry makes an offset
-- attachment look like a mistake.
data Port = Port
  { portSide   :: !PortSide
  , portOffset :: !Int
  }
  deriving (Eq, Ord, Show)

portPoint :: Rect -> Port -> Point
portPoint r (Port side off) = case side of
  PN -> Point (rectCenterX r + off) (rY r)
  PS -> Point (rectCenterX r + off) (rectBottom r)
  PW -> Point (rX r) (rectCenterY r + off)
  PE -> Point (rectRight r) (rectCenterY r + off)

-- | LAYOUT-020: a node's __connection axis__ — the @y@ its connectors leave
-- and enter on, and the @y@ its band was stacked around.
--
-- For every node the axis is 'rectCenterY' (LAYOUT-012), with one exception:
-- an expanded subprocess hangs from its own /internal spine/ so that the flow
-- line continues straight through the container instead of stepping to its box
-- centre. The offset is carried beside the shape rather than derived from it
-- because it is a fact about the child's layout — the outer pass sizes the
-- container from the child's bounding box and can no longer see where inside
-- that box the child's spine ran.
--
-- Absent means zero, so every node that has no opinion is centred and the map
-- is empty for a diagram without an expanded subprocess.
type AxisMap = Map NodeId Int

axisOffsetOf :: AxisMap -> NodeId -> Int
axisOffsetOf ax n = Map.findWithDefault 0 n ax

-- | The absolute axis @y@ of a node, given its box.
axisYOf :: AxisMap -> NodeId -> Rect -> Int
axisYOf ax n r = rectCenterY r + axisOffsetOf ax n

oppositeSide :: PortSide -> PortSide
oppositeSide s = case s of
  PN -> PS
  PS -> PN
  PE -> PW
  PW -> PE

-- | Unit outward normal of a port side, as a @(dx, dy)@ pair.
sideNormal :: PortSide -> (Int, Int)
sideNormal s = case s of
  PN -> (0, -1)
  PS -> (0, 1)
  PW -> (-1, 0)
  PE -> (1, 0)

-- Edges ----------------------------------------------------------------------

-- | The canonical route classes of EDGE-025. Classification happens once, in
-- phase 8, and drives both the route shape and the bend budget.
data EdgeClass
  = EcStraight
  | EcSplit
  | EcMerge
  | EcCrossLane
  | EcLoopback
  | EcSelfLoop
  | EcBoundary
  | EcMessage
  | EcAssociation
  | EcUnstructured
  deriving (Eq, Ord, Show)

-- | EDGE-007. Exceeding the budget is a violation, not a preference: an edge
-- that needs four bends almost always means a wrong band or column upstream.
edgeBendBudget :: EdgeClass -> Int
edgeBendBudget c = case c of
  EcStraight -> 0
  EcSplit -> 1
  EcMerge -> 1
  EcCrossLane -> 2
  EcLoopback -> 2
  EcSelfLoop -> 4
  EcBoundary -> 2
  EcMessage -> 2
  EcAssociation -> 1
  EcUnstructured -> 4

data Route = Route
  { rtPoints :: [Point]
  , rtClass  :: !EdgeClass
  , rtBudget :: !Int
  -- ^ The bend budget the router committed to for this edge. Normally
  -- 'edgeBendBudget' of the class, but a documented fallback (EDGE-005's
  -- fan-corridor form, say) records the larger budget it chose, so the
  -- validator checks against what was actually promised instead of guessing.
  }
  deriving (Eq, Show)

routeBends :: Route -> Int
routeBends r = max 0 (length (rtPoints r) - 2)

routeLength :: Route -> Int
routeLength = sum . map segLength . routeSegments . rtPoints

-- | The bounding box of a route. Used as an exact pre-filter by the pairwise
-- detectors: two routes whose boxes are disjoint cannot cross or overlap, and
-- a route whose box misses a node cannot come near it.
routeBox :: Route -> Rect
routeBox r = unionRects [Rect (ptX p) (ptY p) 0 0 | p <- rtPoints r]

-- Labels ---------------------------------------------------------------------

-- | What a label rectangle belongs to. Labels are geometry (LABEL-011), so
-- they are keyed and stored exactly like shapes.
data LabelKey
  = LkNode NodeId
  | LkFlow FlowId
  | LkArtifact ArtifactId
  deriving (Eq, Ord, Show)

data LabelBox = LabelBox
  { lbRect  :: Rect
  , lbLines :: [Text]
  }
  deriving (Eq, Show)

-- Structural vocabulary ------------------------------------------------------

-- | Which side of the region axis a branch occupies (SPEC A5). The meaning is
-- fixed so the same construct lands in the same place in every diagram: above
-- is neutral or positive, below is negative, terminating and exceptional.
data Side = SideAbove | SideAxis | SideBelow
  deriving (Eq, Ord, Show)

data Polarity = PolPositive | PolNeutral | PolNegative | PolException
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | BRANCH-008. @AXIS_LOCK@ gives the rank-1 branch a bend-free straight line
-- through the whole region; @BBOX_CENTER@ straddles the axis symmetrically.
data StackMode = AxisLock | BBoxCenter
  deriving (Eq, Ord, Show)

newtype BranchId = BranchId Int
  deriving (Eq, Ord, Show)

newtype RegionId = RegionId Int
  deriving (Eq, Ord, Show)

data RegionKind
  = -- | The whole scope: one implicit branch holding the spine.
    RkRoot
  | -- | A split, its merge if it has one, and the gateway type that drives
    -- BRANCH-009.
    RkSplit NodeId (Maybe NodeId) GatewayKind
  | -- | A maximal subgraph SESE decomposition could not describe
    -- (LAYOUT-033). Laid out by the local fallback and treated as one opaque
    -- block by everything outside it.
    RkUnstructured
  deriving (Eq, Show)

-- | Vertical extent of something, measured from its own axis. Kept as a pair
-- rather than as @(height, axisOffset)@ because every stacking formula in
-- §BRANCH needs the two halves separately — @A[i] /= H[i]/2@ in general, and
-- collapsing them is, per BRANCH-002, "the single most common implementation
-- error in BPMN formatters".
data Extent = Extent
  { exAbove :: !Int
  , exBelow :: !Int
  }
  deriving (Eq, Ord, Show)

extentH :: Extent -> Int
extentH e = exAbove e + exBelow e

mergeExtent :: Extent -> Extent -> Extent
mergeExtent a b = Extent (max (exAbove a) (exAbove b)) (max (exBelow a) (exBelow b))

instance Semigroup Extent where
  (<>) = mergeExtent

instance Monoid Extent where
  mempty = Extent 0 0

data Branch = Branch
  { brId        :: !BranchId
  , brEntry     :: Maybe FlowId
  -- ^ The outgoing flow of the split that opens this branch.
  , brNodes     :: [NodeId]
  -- ^ Nodes sitting directly on this branch's own axis, in layer order.
  , brRegions   :: [RegionId]
  , brRank      :: !Int
  , brSide      :: !Side
  , brPolarity  :: !Polarity
  , brTerminates :: !Bool
  , brSpanLayers :: !Int
  , brNodeCount :: !Int
  , brPriority  :: Maybe Int
  , brExtent    :: Map (Maybe LaneId) Extent
  -- ^ BRANCH-002/BRANCH-023: extents per lane, because a region whose branches
  -- live in different lanes stacks lane by lane rather than globally.
  }
  deriving (Eq, Show)

data Region = Region
  { rgId       :: !RegionId
  , rgKind     :: RegionKind
  , rgParent   :: Maybe RegionId
  , rgBranches :: [Branch]
  , rgMode     :: !StackMode
  , rgPeerSymmetric :: !Bool
  , rgHasPrimary :: !Bool
  , rgOpen     :: !Bool
  -- ^ BRANCH-019: no merge; branches never reconverge.
  , rgMembers  :: [NodeId]
  }
  deriving (Eq, Show)

-- | A reserved horizontal routing lane outside a region's bounding box
-- (LAYOUT-018). Corridors carry edges and never nodes.
data Corridor = Corridor
  { coFlow   :: FlowId
  , coIndex  :: !Int
  , coLane   :: Maybe LaneId
  , coSpan   :: !Int
  , coAbove  :: !Bool
  , coOffset :: !Int
  -- ^ Signed offset from the lane axis, in the same frame as 'BandPlacement'.
  }
  deriving (Eq, Show)

-- | Where a node sits vertically, in structural terms: which lane, and how far
-- from that lane's axis. Converted to a @y@ in phase 7 and not before.
data BandPlacement = BandPlacement
  { bpLane   :: Maybe LaneId
  , bpOffset :: !Int
  -- ^ Signed offset from the lane axis; negative is above.
  }
  deriving (Eq, Ord, Show)

-- | The complete logical layout structure of one scope. No pixels.
data LayoutStructure = LayoutStructure
  { lsScope       :: ScopeId
  , lsLayers      :: Map NodeId Int
  , lsRegions     :: Map RegionId Region
  , lsRootRegion  :: RegionId
  , lsNodeRegion  :: Map NodeId RegionId
  , lsSpine       :: [NodeId]
  , lsBands       :: Map NodeId BandPlacement
  , lsBackEdges   :: [FlowId]
  , lsCorridors   :: [Corridor]
  , lsUnstructured :: [NodeId]
  , lsLaneOrder   :: [Maybe LaneId]
  , lsLaneExtent  :: Map (Maybe LaneId) Extent
  , lsColumnOf    :: Map NodeId Int
  , lsMaxLayer    :: !Int
  , lsLarge       :: !Bool
  }
  deriving (Eq, Show)

-- Rendered geometry ----------------------------------------------------------

-- | Integer pixel geometry. Every map is a "Data.Map.Strict" keyed by an
-- ordered id, so serialisation order is a property of the ids rather than of a
-- hash (HC-016).
data Geometry = Geometry
  { geoShapes    :: Map NodeId Rect
  , geoRoutes    :: Map FlowId Route
  , geoLabels    :: Map LabelKey LabelBox
  , geoLanes     :: Map LaneId Rect
  , geoPools     :: Map ParticipantId Rect
  , geoArtifacts :: Map ArtifactId Rect
  }
  deriving (Eq, Show)

emptyGeometry :: Geometry
emptyGeometry = Geometry Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty

-- | The union of everything rendered, labels and waypoints included
-- (LAYOUT-031).
geometryBounds :: Geometry -> Rect
geometryBounds g = case rects of
  [] -> emptyRect
  _ -> unionRects rects
  where
    rects =
      Map.elems (geoShapes g)
        ++ map lbRect (Map.elems (geoLabels g))
        ++ Map.elems (geoLanes g)
        ++ Map.elems (geoPools g)
        ++ Map.elems (geoArtifacts g)
        ++ [Rect (ptX p) (ptY p) 0 0 | r <- Map.elems (geoRoutes g), p <- rtPoints r]

translateGeometry :: Int -> Int -> Geometry -> Geometry
translateGeometry dx dy g =
  Geometry
    { geoShapes = Map.map (translateRect dx dy) (geoShapes g)
    , geoRoutes = Map.map tr (geoRoutes g)
    , geoLabels = Map.map (\l -> l {lbRect = translateRect dx dy (lbRect l)}) (geoLabels g)
    , geoLanes = Map.map (translateRect dx dy) (geoLanes g)
    , geoPools = Map.map (translateRect dx dy) (geoPools g)
    , geoArtifacts = Map.map (translateRect dx dy) (geoArtifacts g)
    }
  where
    tr r = r {rtPoints = [Point (ptX p + dx) (ptY p + dy) | p <- rtPoints r]}

-- Diagnostics ----------------------------------------------------------------

-- | The constraint tiers of SPEC §2. Lexicographic: no gain in a lower tier
-- justifies any loss in a higher one, which is why the tier is carried on the
-- violation rather than inferred from the weight.
data Tier = T0 | T1 | T2 | T3 | T4 | T5
  deriving (Eq, Ord, Show, Enum, Bounded)

data Violation = Violation
  { vRule    :: RuleId
  , vTier    :: !Tier
  , vMessage :: Text
  , vHint    :: Maybe Text
  , vElement :: Maybe ElementRef
  }
  deriving (Eq, Show)

-- | T0 and T1 violations fail the build (SPEC §K "absolute quality gates");
-- everything else is reported as an advisory so the caller still gets a
-- diagram.
violationDiag :: Violation -> Diagnostic
violationDiag v = maybe base (`withHint` base) (vHint v)
  where
    base
      | vTier v <= T1 = layoutViolation (vRule v) msg
      | otherwise = layoutAdvisory (vRule v) msg
    msg = vMessage v <> maybe "" (\e -> " (" <> refText e <> ")") (vElement v)
-- | Total order on violations, so a report is reproducible: worst tier first,
-- then rule id, then message.
orderViolations :: [Violation] -> [Violation]
orderViolations = sortOn (\v -> (vTier v, unRuleId (vRule v), vMessage v))
