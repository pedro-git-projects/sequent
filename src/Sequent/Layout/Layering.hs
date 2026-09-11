-- | Phase 3 — layer assignment. @LLS → LLS@.
--
-- ASAP (as-soon-as-possible) longest-path layering over the acyclic skeleton,
-- exactly as LAYOUT-004 specifies. ASAP is not one option among several: it is
-- what produces the three properties the branching rules assume —
--
--   1. every branch of a split starts in the same column (BRANCH-013 rule 1);
--   2. a merge lands immediately after the longest branch (BRANCH-011);
--   3. an early-ending branch stops early instead of stretching to the right
--      edge (BRANCH-014 rule 3).
--
-- Layering runs before region detection even though §J numbers it after,
-- because BRANCH-007's @span@ component — which P2 needs in order to classify
-- branches — is defined in terms of layers. The two phases are independent:
-- layering reads only the acyclic skeleton.
module Sequent.Layout.Layering
  ( asapLayers
  , applyPinConstraints
  , VirtualChain (..)
  , virtualChains
  , layerSpanOf
  , byLayer
  ) where

import qualified Data.IntMap.Strict as IM
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)

import Sequent.Bpmn.Graph
import Sequent.Bpmn.Semantic
import Sequent.Layout.Analysis

-- | ASAP layers, keyed by node.
--
-- Boundary events are contracted into their hosts by 'buildFlowGraph', so a
-- boundary event shares its host's layer and its outgoing flow is ranked as
-- though it left the host — which is what puts the handler downstream of the
-- activity that can fail rather than beside it.
asapLayers :: Analysis -> Map NodeId Int
asapLayers a =
  Map.fromList
    [ (idOf fg v, IM.findWithDefault 0 v raw)
    | v <- fgOrder fg
    ]
  where
    fg = anGraph a
    raw = longestPathLayers fg (anAcyclic a)

-- | LAYOUT-025: a pin fixes a node's @x@, which is a constraint on its layer,
-- not a licence to move it out of the grid. The pinned node's column is forced
-- to the pin, and every node is pushed right far enough that no forward edge
-- runs backwards.
--
-- Pins are applied by raising layers only. Lowering a layer could invalidate
-- the longest-path property for an unrelated predecessor, and LAYOUT-025 says
-- a pin that cannot be honoured is broken and reported, never silently
-- satisfied by moving somebody else backwards.
applyPinConstraints :: Analysis -> Map NodeId Int -> Map NodeId Int -> Map NodeId Int
applyPinConstraints a pinnedLayers layers0 = settle (Map.union pinnedLayers layers0) (0 :: Int)
  where
    fg = anGraph a
    settle ls n
      | n > Map.size ls + 1 = ls
      | otherwise =
          let ls' = foldl' bump ls (anTopo a)
           in if ls' == ls then ls else settle ls' (n + 1)
    bump ls v =
      let i = idOf fg v
          need = maximum (0 : [Map.findWithDefault 0 (idOf fg u) ls + 1 | u <- predsOf fg v, isAcyclic (u, v)])
       in Map.insertWith max i need ls
    acycSet = Map.fromList [(e, ()) | e <- anAcyclic a]
    isAcyclic e = Map.member e acycSet

-- | LAYOUT-009: a chain of zero-size virtual nodes for an edge that spans more
-- than one layer. Dummies take part in band assignment and crossing reduction
-- exactly like real nodes; without them a long edge is invisible to the
-- ordering heuristic and gets routed through a node (HC-004).
data VirtualChain = VirtualChain
  { vcFlow    :: FlowId
  , vcLayers  :: [Int]
  -- ^ The intermediate layers the edge passes through, ascending.
  , vcSource  :: NodeId
  , vcTarget  :: NodeId
  }
  deriving (Eq, Show)

virtualChains :: Analysis -> Map NodeId Int -> [VirtualChain]
virtualChains a layers =
  [ VirtualChain (sfId f) [ls + 1 .. lt - 1] (sfSource f) (sfTarget f)
  | f <- scFlows (anScope a)
  , not (isBackFlow a (sfId f))
  , Just ls <- [Map.lookup (sfSource f) layers]
  , Just lt <- [Map.lookup (sfTarget f) layers]
  , lt - ls > 1
  ]

-- | @span(b)@ of BRANCH-007: how many layers a set of nodes covers.
layerSpanOf :: Map NodeId Int -> [NodeId] -> Int
layerSpanOf layers ns = case mapMaybe (`Map.lookup` layers) ns of
  [] -> 0
  ls -> maximum ls - minimum ls + 1
-- | Order nodes the way every geometry phase reads them: by layer, then by the
-- canonical id tie-break.
byLayer :: Map NodeId Int -> [NodeId] -> [NodeId]
byLayer layers = sortOn (\n -> (fromMaybe 0 (Map.lookup n layers), unNodeId n))
