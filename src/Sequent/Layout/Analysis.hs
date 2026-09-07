-- | Phase 1 — graph analysis. @SG → LLS@.
--
-- Reads the semantic graph and produces the derived relations every later
-- phase needs: back edges, the acyclic skeleton, a topological order,
-- dominators, post-dominators and strongly connected components. It writes no
-- structure of its own; it is the input to phases 2 and 3.
--
-- Multiple start events and disconnected components are handled by a single
-- virtual source (LAYOUT-034): giving the graph one entry makes dominance
-- total, which is what lets region detection treat "the whole scope" as an
-- ordinary region instead of a special case.
module Sequent.Layout.Analysis
  ( Analysis (..)
  , analyse
  , virtualSource
  , isBackFlow
  , flowVertices
  , outFlowsOf
  , inFlowsOf
  ) where

import Data.IntMap.Strict (IntMap)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

import Sequent.Bpmn.Graph
import Sequent.Bpmn.Semantic

-- | The virtual entry all sources hang off. Negative so it cannot collide with
-- a real dense index; @-1@ is reserved by 'postDominators' for the sink.
virtualSource :: Vtx
virtualSource = -2

data Analysis = Analysis
  { anScope     :: Scope
  , anGraph     :: FlowGraph
  , anBackEdges :: [(Vtx, Vtx)]
  , anBackFlows :: Set FlowId
  -- ^ The sequence flows classified as back edges. Kept by 'FlowId' as well as
  -- by vertex pair because routing needs to ask the question per edge.
  , anAcyclic   :: [(Vtx, Vtx)]
  , anTopo      :: [Vtx]
  , anIdom      :: IntMap Vtx
  , anIpdom     :: IntMap Vtx
  , anSccs      :: [[Vtx]]
  , anEntries   :: [Vtx]
  , anFlowEnds  :: Map FlowId (Vtx, Vtx)
  }

analyse :: Scope -> Analysis
analyse sc =
  Analysis
    { anScope = sc
    , anGraph = fg
    , anBackEdges = backs
    , anBackFlows = backFlows
    , anAcyclic = acyclic
    , anTopo = topoOrder fg acyclic
    , anIdom = dominators fg virtualSource (acyclic ++ virtualEdges)
    , anIpdom = postDominators fg acyclic
    , anSccs = sccs fg
    , anEntries = entries
    , anFlowEnds = Map.fromList [(f, (a, b)) | (a, b, f) <- fgEdges fg]
    }
  where
    fg = buildFlowGraph sc
    backs = dfsBackEdges fg
    backSet = Set.fromList backs
    acyclic = [(a, b) | (a, b, _) <- fgEdges fg, not (Set.member (a, b) backSet)]
    backFlows = Set.fromList [f | (a, b, f) <- fgEdges fg, Set.member (a, b) backSet]
    -- Every source, and then every vertex that is still unreachable, so that
    -- disconnected components are dominated too (LAYOUT-034).
    entries = fgEntries fg ++ [v | v <- fgOrder fg, null (predsOf fg v), v `notElem` fgEntries fg]
    virtualEdges = [(virtualSource, e) | e <- entries]

isBackFlow :: Analysis -> FlowId -> Bool
isBackFlow a f = Set.member f (anBackFlows a)

flowVertices :: Analysis -> FlowId -> Maybe (Vtx, Vtx)
flowVertices a f = Map.lookup f (anFlowEnds a)

-- | Outgoing flows of a node in canonical order, back edges included.
outFlowsOf :: Analysis -> NodeId -> [SequenceFlow]
outFlowsOf a i = [f | f <- scFlows (anScope a), sfSource f == i]

inFlowsOf :: Analysis -> NodeId -> [SequenceFlow]
inFlowsOf a i = [f | f <- scFlows (anScope a), sfTarget f == i]
