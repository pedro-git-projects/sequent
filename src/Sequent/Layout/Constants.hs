-- | Base geometry constants — SPEC §B, verbatim.
--
-- Everything the layout engine measures is derived from the base unit @U = 10@.
-- The numbers are not tunable knobs: the spec's coherence argument (§1 "Why
-- these ratios cohere") depends on the exact ratios, so they live here as
-- named constants and nowhere else. A magic number anywhere else in
-- "Sequent.Layout.*" is a bug.
--
-- Large-diagram mode (LAYOUT-028) changes exactly five things; rather than
-- shadowing the constants it is threaded through as a 'Metrics' record so that
-- the mode is visible in every signature that depends on it.
module Sequent.Layout.Constants
  ( -- * Base unit
    u
  , grid
    -- * Element sizes (§B.1)
  , taskW
  , taskH
  , taskWMax
  , taskHMax
  , gwSize
  , evSize
  , subMinW
  , subMinH
  , dataW
  , dataH
  , storeW
  , storeH
  , annotWMin
  , annotWMax
  , annotBracket
    -- * Spacing (§B.2)
  , nodeGapX
  , nodeGapXMin
  , compactGap
  , fanoutGapDefault
  , mergeGap
  , branchGapY
  , branchGapYMin
  , excGapY
  , loopClear
  , corridorPitch
  , edgeClear
  , edgeSep
  , minSeg
  , portOffsetMin
  , artifactGap
  , beGap
  , margin
    -- * Containers (§B.3)
  , containerPadX
  , containerPadY
  , subprocPadBottom
  , poolLabelBand
  , laneLabelBand
  , laneMinH
  , poolGapY
  , blackboxH
    -- * Text and labels (§B.4)
  , fontSize
  , lineH
  , labelPad
  , labelGap
  , labelMaxW
  , taskMaxLines
  , flowLabelOffset
  , labelClear
  , labelPushSteps
  , markerBand
    -- * Tolerances (§B.5)
  , alignTol
  , symTol
  , spanTol
  , imbalanceTol
  , stretchThreshold
  , densityLow
  , densityHigh
  , maxRowW
    -- * Mode-dependent metrics (LAYOUT-028)
  , Metrics (..)
  , standardMetrics
  , largeMetrics
    -- * Derived formulas (§B.6)
  , colGap
  , axisSpacing
  , snapCenter
  , ceilU
  , ceil2U
  , corridorAt
  , requiredHostW
  , boundaryCapacity
  ) where

-- | @U@ — the base spacing unit. Everything else is a multiple of it.
u :: Int
u = 10

-- | Center snap grid (LAYOUT-002). Identical to 'u' by definition.
grid :: Int
grid = u

-- Element sizes -------------------------------------------------------------

taskW, taskH, taskWMax, taskHMax, gwSize, evSize :: Int
taskW = 10 * u
taskH = 8 * u
taskWMax = 16 * u
taskHMax = 12 * u
gwSize = 5 * u
evSize = 36

subMinW, subMinH :: Int
subMinW = 24 * u
subMinH = 16 * u

-- | LABEL-010: a text annotation is drawn as a bracket down its left side,
-- and the bracket is not text space. Reserving a unit for it is what keeps the
-- renderer's own wrapping inside the box we sized — without it the usable width
-- we measured against is wider than the one the renderer has, and the last line
-- spills past the bracket.
annotBracket :: Int
annotBracket = u

dataW, dataH, storeW, storeH, annotWMin, annotWMax :: Int
dataW = 36
dataH = 5 * u
storeW = 5 * u
storeH = 5 * u
annotWMin = 10 * u
annotWMax = 20 * u

-- Spacing -------------------------------------------------------------------

nodeGapX, nodeGapXMin, compactGap, fanoutGapDefault, mergeGap :: Int
nodeGapX = 6 * u
nodeGapXMin = 4 * u
compactGap = 4 * u
fanoutGapDefault = 8 * u
mergeGap = 6 * u

branchGapY, branchGapYMin, excGapY, loopClear, corridorPitch :: Int
branchGapY = 6 * u
branchGapYMin = 4 * u
excGapY = 5 * u
loopClear = 3 * u
corridorPitch = 2 * u

edgeClear, edgeSep, minSeg, portOffsetMin :: Int
edgeClear = 15
edgeSep = u
minSeg = 2 * u
portOffsetMin = 2 * u

artifactGap, beGap, margin :: Int
artifactGap = 3 * u
beGap = u
margin = 4 * u

-- Containers ----------------------------------------------------------------

containerPadX, containerPadY, subprocPadBottom :: Int
containerPadX = 4 * u
containerPadY = 3 * u
subprocPadBottom = 2 * u

poolLabelBand, laneLabelBand, laneMinH, poolGapY, blackboxH :: Int
poolLabelBand = 3 * u
laneLabelBand = 3 * u
laneMinH = 14 * u
poolGapY = 6 * u
blackboxH = 6 * u

-- Text and labels -----------------------------------------------------------

fontSize, lineH, labelPad, labelGap, labelMaxW :: Int
fontSize = 12
lineH = 14
labelPad = 5
labelGap = 5
labelMaxW = 9 * u

-- | LABEL-001's cap on an activity's internal text. It is a real cap because
-- an activity's box grows to meet it (LAYOUT-029) and HC-012 checks the result;
-- there is no equivalent for an /external/ label, whose box is whatever the
-- wrapped text needs — capping the measurement there would only hide the
-- overflow from the formatter (see 'Sequent.Layout.Labels.externalLabelBox').
taskMaxLines :: Int
taskMaxLines = 4

flowLabelOffset, labelClear :: Int
flowLabelOffset = 5
labelClear = u

-- | LABEL-006: how many times the anchor ladder is retried a grid unit further
-- from the element before a label is allowed to overlap anything.
--
-- The rule asks for the /gap/ to be widened by a label height and the ladder
-- retried; searching outward one unit at a time is the same move made from the
-- other end, and a finer step matters — the first free position is the one the
-- label takes, so a step of a whole label height can walk a caption past the
-- shape it names when a position 10 px further out was free. Eight units is
-- about a task height: past that the label has left the element it belongs to
-- and the honest answer is the LABEL-011 violation.
labelPushSteps :: Int
labelPushSteps = 8

-- | LAYOUT-030: the band reserved at the bottom of an activity for markers.
markerBand :: Int
markerBand = 20

-- Tolerances ----------------------------------------------------------------

alignTol, symTol, spanTol, imbalanceTol, stretchThreshold :: Int
alignTol = 5
symTol = 2 * u
spanTol = 1
imbalanceTol = 1
stretchThreshold = 3

densityLow, densityHigh :: Double
densityLow = 0.08
densityHigh = 0.40

-- | LAYOUT-010: width beyond which a one-row layout draws an advisory.
maxRowW :: Int
maxRowW = 320 * u

-- Mode-dependent metrics ----------------------------------------------------

-- | The five things LAYOUT-028 changes, and nothing else. Carrying them in a
-- record rather than shadowing the module-level constants keeps "which mode am
-- I in" visible in the type of every function that cares.
data Metrics = Metrics
  { mNodeGapX      :: !Int
  , mBranchGapY    :: !Int
  , mSymmetryWeight :: !Double
  , mMaxChannels   :: !Int
  , mLargeMode     :: !Bool
  , mImproveBudget :: !Int
  -- ^ Phase-14 candidate budget per region (@6@ normally, @2@ in large mode).
  }
  deriving (Eq, Show)

standardMetrics :: Metrics
standardMetrics =
  Metrics
    { mNodeGapX = nodeGapX
    , mBranchGapY = branchGapY
    , mSymmetryWeight = 20
    , mMaxChannels = 2
    , mLargeMode = False
    , mImproveBudget = 6
    }

-- | LAYOUT-028: large diagrams get /more/ spacing, not less.
largeMetrics :: Metrics
largeMetrics =
  Metrics
    { mNodeGapX = 7 * u
    , mBranchGapY = 8 * u
    , mSymmetryWeight = 0
    , mMaxChannels = 4
    , mLargeMode = True
    , mImproveBudget = 2
    }

-- Derived formulas ----------------------------------------------------------

-- | @colGap(a,b)@ — SPEC §B.6. Two small elements (event, gateway) sit closer
-- together so that optical density stays constant regardless of element size
-- (LAYOUT-014).
colGap :: Metrics -> Int -> Int -> Int
colGap m wa wb
  | wa <= 5 * u && wb <= 5 * u = compactGap
  | otherwise = mNodeGapX m

-- | Distance between the axes of two vertically adjacent branches.
axisSpacing :: Int -> Int -> Int -> Int
axisSpacing hi gap hj = hi `div` 2 + gap + hj `div` 2

-- | @snapCenter@ — round to the grid, half-up toward @+∞@ (LAYOUT-027 rule 4).
-- Defined for negative inputs too, because intermediate band arithmetic is
-- signed even though final coordinates never are.
snapCenter :: Int -> Int
snapCenter c = ((c * 2 + grid) `divFloor` (2 * grid)) * grid
  where
    divFloor a b = if a < 0 && a `mod` b /= 0 then a `div` b else a `quot` b

-- | Round up to a whole number of grid units. Used by N-8 so that centering an
-- odd-height stack cannot land the axis on a half-grid.
ceilU :: Int -> Int
ceilU n = ((n + grid - 1) `div` grid) * grid

-- | Round up to an even number of grid units. A box whose width and height are
-- both even in units keeps its /left and top edges/ on the grid as well as its
-- centre, which is what a container has to do: everything inside it is placed
-- from those edges, and HC-011 applies to the children too (LAYOUT-019).
ceil2U :: Int -> Int
ceil2U n = ((n + 2 * grid - 1) `div` (2 * grid)) * (2 * grid)

-- | @corridor(k)@ — the @k@-th routing corridor outside a region edge.
corridorAt :: Int -> Int -> Int
corridorAt base k = base - (loopClear + k * corridorPitch)

-- | @requiredHostW(k)@ — LAYOUT-016. Width a host needs for @k@ boundary
-- events on one edge.
requiredHostW :: Int -> Int
requiredHostW k = k * evSize + (k + 1) * beGap

-- | @boundaryCapacity(w)@ — LAYOUT-016. How many boundary events fit along one
-- edge of a host @w@ wide. The overflow goes to the opposite edge, so this is
-- also what decides which of a host's events label downward and which upward,
-- and phase 5 has to agree with phase 7 about it or the band reserves room on
-- the wrong side.
boundaryCapacity :: Int -> Int
boundaryCapacity w = max 1 ((w - beGap) `div` (evSize + beGap))
