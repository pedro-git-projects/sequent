-- | Phase 11 — compaction. @RG → RG@.
--
-- LAYOUT-021 compacts __columns, not nodes__: a column may move left until the
-- first of four things binds, and it moves as a rigid unit. Node-wise
-- compaction destroys column alignment, which costs more than the space it
-- saves.
--
-- Compaction is also the last objective, never the first (SPEC A10). Two rules
-- keep it honest here:
--
--   * it may only beat regularity (T3) when the recovered area exceeds
--     @12U × 12U@ (§2.1), so a tall diagram can be tightened and a small one
--     cannot;
--   * it is applied /uniformly/ to every ordinary gap, because tightening one
--     gap and not its neighbour breaks gap uniformity (LAYOUT-023, @CV ≤
--     0.10@) for a handful of pixels.
--
-- N-14: channel demand is converted into an explicit constraint /before/
-- compaction runs, so compaction can never squeeze out a corridor that routing
-- then has to re-widen — the oscillation cannot start.
module Sequent.Layout.Compact
  ( CompactionPlan (..)
  , planCompaction
  , requiredGapAfter
  , emptyStrips
  ) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Sequent.Bpmn.Semantic
import Sequent.Layout.Constants
import Sequent.Layout.Geometry (Column (..))
import Sequent.Layout.Types

data CompactionPlan = CompactionPlan
  { cpColumns  :: [Column]
  , cpApplied  :: !Bool
  , cpRecovered :: !Int
  -- ^ Area, in px², the plan would recover. Reported so the tier trade of
  -- §2.1 is visible rather than implicit.
  }
  deriving (Eq, Show)

-- | The constraint graph of LAYOUT-021, solved by the longest path over column
-- left edges.
--
-- Compaction is /triggered by its detector/, not run unconditionally: the rule
-- looks for "an empty vertical strip of width > 2·NODE_GAP_X spanning the full
-- content height and containing no label or corridor". Because LAYOUT-005
-- derives every gap from content in the first place, a strip that wide cannot
-- normally occur, and this phase correctly does nothing — which is the point.
-- Running it unconditionally would pull every gap down to @NODE_GAP_X_MIN@,
-- destroying the uniform column pitch that LAYOUT-005 calls "the single largest
-- contributor to a machine-formatted, deliberate look" and contradicting the
-- canonical examples of §L, for at most @20 px@ a gap.
planCompaction
  :: Metrics
  -> Scope
  -> Map NodeId Int
  -> Map Int Int
  -- ^ Channels actually used in the gap after each column (N-14).
  -> Set Int
  -- ^ Columns holding a pinned node (LAYOUT-025). These never move.
  -> Int
  -- ^ Content height, for the area trade of §2.1.
  -> [Column]
  -> CompactionPlan
planCompaction metrics sc layers channels pinnedColumns contentH cols
  | null strips || not worthwhile = CompactionPlan cols False recovered
  | otherwise = CompactionPlan tightened True recovered
  where
    designed = [requiredGapAfter metrics sc layers channels cols c | c <- cols]
    actual = map currentGap cols
    -- LAYOUT-021's detector. Only a genuinely unused strip is compacted away.
    -- LAYOUT-025 is STRONG and compaction is T4: a gap a pin deliberately
    -- opened is not waste, so a column holding a pin, and the gap in front of
    -- it, are excluded from the detector.
    strips =
      [ i
      | (i, (a, d)) <- zip [0 :: Int ..] (zip actual designed)
      , a - d > 2 * mNodeGapX metrics
      , not (Set.member i pinnedColumns)
      , not (Set.member (i + 1) pinnedColumns)
      ]
    slack = sum [a - d | (i, (a, d)) <- zip [0 :: Int ..] (zip actual designed), i `elem` strips]
    recovered = slack * contentH
    -- §2.1: compaction may only beat regularity when it recovers more than
    -- 12U x 12U of area.
    worthwhile = slack > 0 && recovered > (12 * u) * (12 * u)

    currentGap c = case drop 1 (dropWhile ((/= colIndex c) . colIndex) cols) of
      (nxt : _) -> colLeft nxt - (colLeft c + colWidth c)
      [] -> 0

    gaps = [if i `elem` strips then d else a | (i, (a, d)) <- zip [0 :: Int ..] (zip actual designed)]
    tightened = go margin (zip cols gaps)
    go _ [] = []
    go x ((c, g) : rest)
      | Set.member (colIndex c) pinnedColumns = c : go (colLeft c + colWidth c + g) rest
      | otherwise =
          let cx = snapCenter (x + colWidth c `div` 2)
              left = cx - colWidth c `div` 2
           in c {colLeft = left, colCentre = cx} : go (left + colWidth c + g) rest

-- | What must fit in the gap after a column: the designed pitch of LAYOUT-005,
-- and the corridors that have to pass through it (N-14).
requiredGapAfter :: Metrics -> Scope -> Map NodeId Int -> Map Int Int -> [Column] -> Column -> Int
requiredGapAfter metrics sc layers channels cols c = max designedGap channelDemand
  where
    idx = colIndex c
    members k = [n | n <- scNodes sc, not (nodeIsBoundary n), Map.findWithDefault 0 (fnId n) layers == k]
    hasNext = any ((== idx + 1) . colIndex) cols
    isFanOut = any (\n -> length (outgoingOf sc (fnId n)) >= 2) (members idx)
    isMergeNext = any (\n -> nodeIsGateway n && length (incomingOf sc (fnId n)) >= 2) (members (idx + 1))
    small k = not (null (members k)) && all (\n -> canonicalWidth n <= 5 * u) (members k)
    canonicalWidth n = case fnKind n of
      NkGateway _ -> gwSize
      NkEvent _ -> evSize
      _ -> taskW
    designedGap
      | not hasNext = 0
      | isFanOut = maximum [fanoutGapDefault, mNodeGapX metrics, gwSize `div` 2 + minSeg + edgeClear]
      | isMergeNext = mergeGap
      | small idx && small (idx + 1) = compactGap
      | otherwise = mNodeGapX metrics
    channelDemand = case Map.findWithDefault 0 idx channels of
      0 -> 0
      k -> 2 * edgeClear + (k - 1) * corridorPitch

-- | LAYOUT-023's detector: a maximal empty axis-aligned rectangle inside the
-- content box that is at least @3·NODE_GAP_X@ wide and @2·TASK_H@ tall and
-- carries no corridor or label. Reported as an advisory rather than repaired,
-- because the repair is compaction and compaction is tier-gated.
emptyStrips :: Metrics -> [Column] -> Map NodeId Rect -> [(Int, Int)]
emptyStrips metrics cols shapes =
  [ (colLeft c + colWidth c, gap)
  | (c, nxt) <- zip sorted (drop 1 sorted)
  , let gap = colLeft nxt - (colLeft c + colWidth c)
  , gap >= 3 * mNodeGapX metrics
  , not (any (\r -> rX r < colLeft nxt && rectRight r > colLeft c + colWidth c) (Map.elems shapes))
  ]
  where
    sorted = sortOn colIndex cols
