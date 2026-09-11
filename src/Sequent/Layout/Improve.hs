-- | Phase 14 — bounded deterministic improvement. @RG → RG@.
--
-- Everything about this phase is constrained by SPEC A1: the layout is
-- /derived/, and phase 14 only perturbs an already-valid structure. It is not
-- an optimiser that finds a layout; it is a fixed, small set of structural
-- moves evaluated in a fixed order against a fixed budget.
--
-- Three prohibitions, all of them load-bearing:
--
--   * __No randomness.__ Candidates are generated and ordered deterministically
--     by @(regionId, candidateType, elementId)@ (LAYOUT-027).
--   * __No time limit.__ Termination is a fixed iteration count, never elapsed
--     time, or two runs on different machines would disagree.
--   * __No near-tie churn.__ A structural change is accepted only when it beats
--     its stability cost (LAYOUT-024), so two arrangements that score almost
--     equally never swap between runs or between edits.
module Sequent.Layout.Improve
  ( Candidate (..)
  , Overrides (..)
  , noOverrides
  , candidateRegion
  , candidatesFor
  , improve
  , improveWithin
  , stabilityCost
  ) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Sequent.Layout.Constants (Metrics (..))
import Sequent.Layout.Types

-- | The structural decisions phase 14 is allowed to revisit. Everything else
-- about the layout is derived and stays derived.
data Overrides = Overrides
  { ovModes :: Map RegionId StackMode
  , ovSides :: Map (RegionId, BranchId) Side
  }
  deriving (Eq, Show)

noOverrides :: Overrides
noOverrides = Overrides Map.empty Map.empty

data Candidate
  = -- | Flip a neutral branch to the other side of the axis.
    SideFlip RegionId BranchId Side
  | -- | Toggle a region between @AXIS_LOCK@ and @BBOX_CENTER@.
    AxisModeToggle RegionId StackMode
  deriving (Eq, Ord, Show)

-- | Which region a candidate belongs to. Phase 14 works on the worst-scoring
-- region first, and ties break by region id.
candidateRegion :: Candidate -> RegionId
candidateRegion c = case c of
  SideFlip r _ _ -> r
  AxisModeToggle r _ -> r

candidateKey :: Candidate -> (Int, Int, Int)
candidateKey c = case c of
  SideFlip (RegionId r) (BranchId b) _ -> (r, 0, b)
  AxisModeToggle (RegionId r) _ -> (r, 1, 0)

-- | LAYOUT-024's displacement cost for a structural change. A side flip costs
-- @40@ and a branch reorder @30@; the numbers exist so that a change has to be
-- clearly better, not marginally better, before the picture rearranges.
stabilityCost :: Candidate -> Double
stabilityCost c = case c of
  SideFlip {} -> 40
  AxisModeToggle {} -> 30

-- | Deterministic candidate generation: only neutral branches may flip (an
-- exception path never moves above the spine, AP-021), and only a region whose
-- symmetry is defective is worth re-moding.
candidatesFor :: [Region] -> [Candidate]
candidatesFor regions =
  sortOn candidateKey $
    [ SideFlip (rgId r) (brId b) (opposite (brSide b))
    | r <- regions
    , rgKind r /= RkRoot
    , b <- rgBranches r
    , brPolarity b == PolNeutral
    , not (brTerminates b)
    , brSide b /= SideAxis
    ]
      ++ [ AxisModeToggle (rgId r) (toggle (rgMode r))
         | r <- regions
         , rgKind r /= RkRoot
         , length (rgBranches r) >= 2
         ]
  where
    opposite SideAbove = SideBelow
    opposite SideBelow = SideAbove
    opposite SideAxis = SideAxis
    toggle AxisLock = BBoxCenter
    toggle BBoxCenter = AxisLock

-- | Try candidates in order against a fixed budget, keeping a change only when
-- it beats its stability cost. @rerun@ re-runs phases 5–13 with the overrides
-- applied; the caller supplies it so this module stays independent of the
-- pipeline's shape.
improve
  :: Metrics
  -> [Region]
  -> Double
  -> (Overrides -> (Double, Bool))
  -- ^ Re-run and report @(score, valid)@.
  -> Overrides
  -> Overrides
improve = improveWithin 24

-- | 'improve' with an explicit cap on candidate evaluations, so a caller that
-- knows the graph is large can bound the work without changing the rule.
improveWithin
  :: Int
  -> Metrics
  -> [Region]
  -> Double
  -- ^ The score of the starting overrides, already computed by the caller.
  -> (Overrides -> (Double, Bool))
  -> Overrides
  -> Overrides
improveWithin cap metrics regions baseScore rerun base = go budget base baseScore (candidatesFor regions)
  where
    -- LAYOUT-028 point 5 and §J phase 14: a fixed budget of candidate moves,
    -- with an absolute cap so a large diagram cannot turn this into a search.
    budget = min cap (mImproveBudget metrics * max 1 (length regions))

    go 0 acc _ _ = acc
    go _ acc _ [] = acc
    go n acc best (c : cs) =
      let trial = apply c acc
          (s, ok) = rerun trial
       in if ok && s < best - stabilityCost c
            then go (n - 1) trial s cs
            else go (n - 1) acc best cs

    apply c ov = case c of
      SideFlip r b side -> ov {ovSides = Map.insert (r, b) side (ovSides ov)}
      AxisModeToggle r m -> ov {ovModes = Map.insert r m (ovModes ov)}
