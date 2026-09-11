-- | Phase 4 — branch ordering and side assignment. @LLS → LLS@.
--
-- The whole of §BRANCH rests on one idea: the vertical arrangement of a split
-- is /derived/ from stable properties of the semantic graph, never from
-- traversal order. BRANCH-007's comparator is the derivation, and every one of
-- its nine components is a property of @SG@ — a name, a flow attribute, a node
-- count — so two structurally equal processes produce the same picture (A9).
--
-- Side assignment then fixes the meaning of vertical space (A5): above the
-- axis is neutral or positive, below is negative, terminating and exceptional.
-- That is why an error path is always beneath the happy path, in every diagram
-- this compiler produces.
module Sequent.Layout.Branches
  ( -- * Classification
    classifyPolarity
  , polarityOfText
  , branchSideFor
    -- * Ordering
  , BranchKey (..)
  , branchKey
  , rankBranches
    -- * Slots
  , assignSides
  , rebalanceSides
  , terminatesAgainstPeers
  , chooseMode
  , hasPrimaryRegion
  , peerSymmetricRegion
  , fanColumnThreshold
  , slotOrder
  ) where

import Data.Char (isAlphaNum, toLower)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Semantic
import Sequent.Layout.Constants (spanTol, symTol)
import Sequent.Layout.Types

-- Polarity -------------------------------------------------------------------

-- | BRANCH-007's polarity lexicon. Matching is case-insensitive and ignores
-- punctuation, so @"Yes"@, @"yes!"@ and @"YES"@ all classify alike, and it is
-- applied to the flow's name first and then to the first node's name.
--
-- The lexicon is a layout heuristic over presentation text, which looks like a
-- violation of "labels are not identity" — it is not: nothing here affects an
-- id, a flow, or any semantic property. It only decides which side of the
-- spine a branch is drawn on, and a wrong guess costs a mirrored diagram, not
-- a wrong process.
positiveWords :: [Text]
positiveWords =
  [ "yes", "true", "ok", "okay", "approve", "approved", "accept", "accepted"
  , "valid", "success", "successful", "granted", "complete", "completed"
  , "in stock", "instock", "eligible", "pass", "passed", "confirmed"
  ]

negativeWords :: [Text]
negativeWords =
  [ "no", "false", "reject", "rejected", "deny", "denied", "invalid"
  , "fail", "failed", "failure", "timeout", "expired", "cancel", "cancelled"
  , "canceled", "out of stock", "outofstock", "ineligible", "insufficient"
  , "error", "declined", "refused"
  ]

-- | Normalise for lexicon matching: lower-case, and collapse anything that is
-- not alphanumeric to a single space.
normalise :: Text -> Text
normalise = T.unwords . T.words . T.map keep . T.toLower
  where
    keep c
      | isAlphaNum c = toLower c
      | otherwise = ' '

polarityOfText :: Text -> Maybe Polarity
polarityOfText raw
  | any (`matches` n) positiveWords = Just PolPositive
  | any (`matches` n) negativeWords = Just PolNegative
  | otherwise = Nothing
  where
    n = normalise raw
    matches w t = t == w || T.isPrefixOf (w <> " ") t || T.isSuffixOf (" " <> w) t

-- | Classify one branch. @EXCEPTION@ wins over the lexicon: a branch that
-- starts at a boundary event, or whose every outcome is an exceptional one, is
-- exceptional whatever it is called.
--
-- \"Every outcome\", not \"any node\". BRANCH-007 phrases the test as \"contains
-- an error/escalation/cancel end event\", and read literally over the branch's
-- transitive members that swallows whole processes: a main path that reaches
-- ten normal steps and one escalation end is classified as an exception path
-- and pushed below the axis, leaving the spine to whichever short branch
-- happened to be neutral. The signal the rule is reaching for is a branch whose
-- /purpose/ is to fail, and a branch that also ends normally somewhere does not
-- have it.
--
-- A boundary event among the members is not an outcome either. The rule says
-- the branch /originates at/ a boundary event; a task inside the branch
-- carrying a handler of its own says nothing about this branch's polarity.
classifyPolarity :: Map NodeId FlowNode -> Maybe SequenceFlow -> [NodeId] -> Polarity
classifyPolarity byId entryFlow members
  | isException = PolException
  | Just p <- entryFlow >>= sfName >>= polarityOfText = p
  | Just p <- firstName >>= polarityOfText = p
  | otherwise = PolNeutral
  where
    memberNodes = mapMaybe (`Map.lookup` byId) members
    firstName = case memberNodes of
      (n : _) -> fnName n
      [] -> Nothing
    sourceIsBoundary = case entryFlow of
      Nothing -> False
      Just f -> maybe False nodeIsBoundary (Map.lookup (sfSource f) byId)
    isException = sourceIsBoundary || (not (null outcomes) && all exceptional outcomes)
    outcomes = [d | n <- memberNodes, NkEvent (EventSpec EvEnd d) <- [fnKind n]]
    exceptional d = case d of
      Just (EdError _) -> True
      Just (EdEscalation _) -> True
      Just EdTerminate -> True
      _ -> False

-- | BRANCH-007 side map, before rebalancing.
branchSideFor :: Polarity -> Bool -> Side
branchSideFor p terminates
  | terminates = SideBelow
  | otherwise = case p of
      PolPositive -> SideAbove
      PolNeutral -> SideAbove
      PolNegative -> SideBelow
      PolException -> SideBelow

-- Ordering -------------------------------------------------------------------

-- | The BRANCH-007 comparator, as a tuple whose natural 'Ord' is the rule.
-- Lower is better: rank 1 is closest to the axis. Every component is a stable
-- property of @SG@, and the last two guarantee totality, so the order never
-- depends on how the graph was walked.
data BranchKey = BranchKey
  { bkUserPriority :: !Int
  -- ^ Absent priorities sort last ('maxBound'), per BRANCH-007's @+∞@.
  , bkNotDefault   :: !Int
  , bkPolarity     :: !Int
  , bkTerminates   :: !Int
  , bkNegSpan      :: !Int
  , bkNegNodeCount :: !Int
  , bkDocOrder     :: !Int
  , bkFlowId       :: Text
  }
  deriving (Eq, Ord, Show)

branchKey :: Branch -> Maybe SequenceFlow -> BranchKey
branchKey b entry =
  BranchKey
    { bkUserPriority = maybe maxBound id (brPriority b)
    , bkNotDefault = if isDefault then 0 else 1
    , bkPolarity = fromEnum (brPolarity b)
    , bkTerminates = if brTerminates b then 1 else 0
    , bkNegSpan = negate (brSpanLayers b)
    , bkNegNodeCount = negate (brNodeCount b)
    , bkDocOrder = maybe maxBound sfDocOrder entry
    , bkFlowId = maybe "" (unFlowId . sfId) entry
    }
  where
    isDefault = maybe False ((== Just FcDefault) . sfCondition) entry

-- | Rank a region's branches. Stable sort on the comparator, then the rank is
-- the position.
rankBranches :: (Branch -> Maybe SequenceFlow) -> [Branch] -> [Branch]
rankBranches entryOf bs =
  [b {brRank = k} | (k, b) <- zip [1 ..] (sortOn (\b -> branchKey b (entryOf b)) bs)]

-- Slots ----------------------------------------------------------------------

-- | BRANCH-014's \"terminating\", as a property that can actually decide a side.
--
-- The rule is about a branch that /stops while another continues/ — \"the
-- process must not visibly deviate because one branch stopped\". In an open
-- region (BRANCH-019) every branch stops, so the property is true of all of
-- them and distinguishes none: using it there sends every branch below the
-- axis at once, and a whole subprocess ends up hanging under a spine that runs
-- along its top edge with nothing above it.
--
-- So it discriminates only when it discriminates. Polarity still decides the
-- rest: an exception or negative branch goes below whether or not it stops.
terminatesAgainstPeers :: [Branch] -> Branch -> Bool
terminatesAgainstPeers bs b = brTerminates b && not (all brTerminates bs)

-- | BRANCH-006 step 3: keep the two sides within one slot of each other by
-- moving the lowest-ranked movable neutral across. Exception-class branches
-- never move up — an error path above the happy path (AP-021) is worse than
-- imbalance.
rebalanceSides :: [Branch] -> [Branch]
rebalanceSides bs = go bs
  where
    go xs
      | ups - downs > 1
      , Just victim <- lastMovable SideAbove xs =
          go (setSide victim SideBelow xs)
      | downs - ups > 1
      , Just victim <- lastMovable SideBelow xs =
          go (setSide victim SideAbove xs)
      | otherwise = xs
      where
        ups = length [b | b <- xs, brSide b == SideAbove]
        downs = length [b | b <- xs, brSide b == SideBelow]

    lastMovable side xs = case reverse (sortOn brRank [b | b <- xs, brSide b == side, movable b]) of
      (b : _) -> Just (brId b)
      [] -> Nothing

    movable b = brPolarity b == PolNeutral && not (terminatesAgainstPeers bs b)

    setSide bid side = map (\b -> if brId b == bid then b {brSide = side} else b)

-- | BRANCH-003/004/005/006: give each ranked branch a side, with the rank-1
-- branch taking the axis when the region is axis-locked.
assignSides :: StackMode -> [Branch] -> [Branch]
assignSides mode bs = case mode of
  AxisLock -> rebalanceSides (map axisOrSide bs)
  BBoxCenter -> rebalanceSides (map plainSide bs)
  where
    axisOrSide b
      | brRank b == 1 = b {brSide = SideAxis}
      | otherwise = plainSide b
    plainSide b = b {brSide = branchSideFor (brPolarity b) (terminatesAgainstPeers bs b)}

-- | BRANCH-008. @AXIS_LOCK@ exactly when one branch is genuinely primary and
-- the split is data-based, when an odd peer fan has a primary, or in large
-- mode where structural stability beats symmetry (LAYOUT-028 point 3).
chooseMode :: Bool -> GatewayKind -> Int -> Bool -> StackMode
chooseMode large gw n primary
  | large = AxisLock
  | primary && gw `elem` [GwExclusive, GwInclusive, GwComplex] = AxisLock
  | primary && odd n && gw `elem` [GwParallel, GwEventBased] = AxisLock
  | otherwise = BBoxCenter

-- | BRANCH-003's @hasPrimary@ test: is one branch genuinely the main one?
hasPrimaryRegion :: [Branch] -> [Maybe SequenceFlow] -> Bool
hasPrimaryRegion bs entries =
  any isDefaultFlow entries
    || not (allSame (map brPolarity bs))
    || any ((/= Nothing) . brPriority) bs
    || spread heights > symTol
    || spread spansOf > spanTol
  where
    isDefaultFlow = maybe False ((== Just FcDefault) . sfCondition)
    heights = [maximum (1 : map extentH (Map.elems (brExtent b))) | b <- bs]
    spansOf = map brSpanLayers bs
    spread [] = 0
    spread xs = maximum xs - minimum xs
    allSame [] = True
    allSame (x : xs) = all (== x) xs

-- | BRANCH-020 eligibility. Only eligible regions are penalised for asymmetry
-- and only they have congruence enforced; forcing symmetry anywhere else
-- produces AP-007 and signals a false equivalence.
peerSymmetricRegion :: GatewayKind -> Bool -> [Branch] -> Bool
peerSymmetricRegion gw primary bs =
  (gw `elem` [GwParallel, GwEventBased] || (gw `elem` [GwExclusive, GwInclusive] && not primary))
    && spread heights <= symTol
    && spread (map brSpanLayers bs) <= spanTol
    && all ((/= PolException) . brPolarity) bs
  where
    heights = [maximum (1 : map extentH (Map.elems (brExtent b))) | b <- bs]
    spread [] = 0
    spread xs = maximum xs - minimum xs

-- | BRANCH-006: at seven branches a flat fan is 980 px tall for trivial
-- content, so it becomes sub-fans instead. Event-based gateways are exempt —
-- the visual equivalence of the waiting alternatives is the point.
fanColumnThreshold :: Int
fanColumnThreshold = 7

-- | Top-to-bottom slot order for a ranked, sided branch list.
--
-- Above-axis branches are emitted with the /best/ rank nearest the axis
-- (BRANCH-004/005: the most important alternatives sit next to the reader's
-- eye line, not at the extremes), so the above group is reversed.
slotOrder :: [Branch] -> [Branch]
slotOrder bs = reverse (sortOn brRank aboves) ++ axis ++ sortOn brRank belows
  where
    aboves = [b | b <- bs, brSide b == SideAbove]
    axis = sortOn brRank [b | b <- bs, brSide b == SideAxis]
    belows = [b | b <- bs, brSide b == SideBelow]
