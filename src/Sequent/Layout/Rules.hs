-- | The normative rule registry.
--
-- SPEC A8: "Every rule is a triple (predicate, detector, repair). A rule with
-- no computable detector is not a rule; it is advice." This module makes that
-- literal — each entry names its priority class, its tier, the module that
-- implements it, and a detector that reports exactly the violations attributed
-- to that rule.
--
-- The registry is what makes spec compliance checkable rather than claimed. A
-- test can walk it, run every detector against a diagram, and assert that a
-- rule marked complete has both an implementation reference and a test; the
-- compliance table in @docs\/spec-compliance.md@ is generated from these
-- entries rather than maintained by hand.
module Sequent.Layout.Rules
  ( Priority (..)
  , Rule (..)
  , LayoutState (..)
  , ruleRegistry
  , lookupRule
  , runRules
  , rulesForTier
  ) where

import Data.Text (Text)

import Sequent.Diagnostic (RuleId (..))
import Sequent.Layout.Score
import Sequent.Layout.Types
import Sequent.Layout.Validate

-- | SPEC §2.2 conflict resolution compares priority class first: higher wins
-- outright, regardless of tier.
data Priority = Weak | Medium | Strong | Hard
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Everything a detector may read. Bundling the two inputs keeps every
-- detector the same shape, which is what lets the registry hold them uniformly.
data LayoutState = LayoutState
  { lstValidation :: ValidationInput
  , lstScore      :: ScoreInput
  }

data Rule = Rule
  { ruleId       :: RuleId
  , rulePriority :: !Priority
  , ruleTier     :: !Tier
  , ruleSummary  :: Text
  , ruleImpl     :: Text
  -- ^ Where the rule is implemented, as @Module.function@.
  , ruleDetect   :: LayoutState -> [Violation]
  }

-- | Detect by filtering the shared detectors, so there is exactly one
-- implementation of each check and the per-rule view is a projection of it
-- rather than a second copy that can drift.
byId :: Text -> LayoutState -> [Violation]
byId rid st = [v | v <- allViolations st, unRuleId (vRule v) == rid]

rule :: Text -> Priority -> Tier -> Text -> Text -> Rule
rule rid prio tier summary impl = Rule (RuleId rid) prio tier summary impl (byId rid)

ruleRegistry :: [Rule]
ruleRegistry =
  [ rule "HC-001" Hard T0 "every connector is an orthogonal polyline" "Layout.Routing.routeOne"
  , rule "HC-002" Hard T0 "no two node boxes overlap; clearance >= 2U in one axis" "Layout.Collision.separateNodes"
  , rule "HC-003" Hard T0 "every node lies inside its container, inset by the padding" "Layout.Collision.growContainers"
  , rule "HC-004" Hard T0 "no connector passes within EDGE_CLEAR of a non-incident node" "Layout.Routing + Layout.Bands"
  , rule "HC-005" Hard T0 "endpoints lie on declared ports with a perpendicular stub" "Layout.Ports.assignPorts"
  , rule "HC-006" Hard T0 "a boundary event's centre lies on its host's border" "Layout.Geometry.boundaryShapes"
  , rule "HC-007" Hard T0 "lanes tile their pool exactly" "Layout.Geometry.laneHeightOf"
  , rule "HC-009" Hard T0 "no collinear overlap of two connectors outside a bundle" "Layout.Routing.takeChannel"
  , rule "HC-010" Hard T0 "no degenerate or collinear waypoints" "Layout.Snap.simplifyPoints"
  , rule "HC-011" Hard T0 "coordinates are non-negative; centres are on the U grid" "Layout.Snap.snapGeometry"
  , rule "HC-012" Hard T0 "an activity's text never overflows its shape" "Layout.Labels.activityGrowthLadder"
  , rule "HC-013" Hard T0 "no node overlaps a lane divider" "Layout.Geometry.assignGeometry"
  , rule "HC-014" Hard T0 "an expanded subprocess contains its children" "Layout.Collision.growContainers"
  , rule "LAYOUT-001" Strong T1 "forward flows make non-decreasing x progress" "Layout.Layering.asapLayers"
  , rule "LAYOUT-007" Strong T2 "the spine is straight and bend-free" "Layout.Regions.detectRegions + Layout.Bands"
  , rule "EDGE-007" Medium T2 "each connector class has a bend budget" "Layout.Routing.routeOne"
  , rule "EDGE-021" Strong T1 "a forward connector never moves backwards" "Layout.Routing.routeOne"
  , rule "AP-001" Hard T0 "no diagonal connector" "Layout.Routing.routeOne"
  , rule "AP-003" Medium T3 "split and merge share a centre y" "Layout.Bands.stackLane"
  , rule "AP-005" Medium T3 "no near-miss alignment" "Layout.Snap.snapGeometry"
  , rule "AP-008" Strong T2 "a loopback never cuts through the main flow" "Layout.Bands.corridorsOf"
  , rule "AP-010" Strong T1 "no unjustified backward movement" "Layout.Routing.routeOne"
  , rule "AP-011" Weak T3 "activity widths do not vary without cause" "Layout.Labels.activityGrowthLadder"
  , rule "AP-015" Medium T2 "gateways are never closer than COMPACT_GAP" "Layout.Geometry.columnsFor"
  , rule "AP-016" Medium T3 "no staircase of slightly offset nodes" "Layout.Bands.assignBands"
  , rule "AP-017" Medium T2 "no accumulation of tiny bends" "Layout.Routing.simplify"
  , rule "AP-021" Strong T2 "no exception path above a normal branch" "Layout.Branches.branchSideFor"
  ]

lookupRule :: Text -> Maybe Rule
lookupRule rid = case [r | r <- ruleRegistry, unRuleId (ruleId r) == rid] of
  (r : _) -> Just r
  [] -> Nothing

rulesForTier :: Tier -> [Rule]
rulesForTier t = [r | r <- ruleRegistry, ruleTier r == t]

-- | Every violation the detectors found, in a deterministic order.
--
-- The shared detectors run /once/ here, not once per registered rule. Calling
-- 'ruleDetect' for each entry would re-run the whole suite twenty-eight times,
-- which turns a linear pipeline into a quadratic one; the per-rule projection
-- exists for tests, where running one detector at a time is the point.
runRules :: LayoutState -> [Violation]
runRules st = orderViolations (allViolations st)

allViolations :: LayoutState -> [Violation]
allViolations st = validateGeometry (lstValidation st) ++ antiPatterns (lstScore st)
