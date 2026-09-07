-- | Graph algorithms over a scope's flow graph.
--
-- SPEC §BRANCH-001 names exactly what is needed and nothing more: a DFS
-- spanning tree with back edges (loops), Tarjan's SCC (irreducible loops),
-- dominators and post-dominators (regions and spine), topological order and
-- longest paths (layering). Planarity testing and ILP crossing minimisation are
-- deliberately excluded.
--
-- Everything here is indexed by a dense 'Int' assigned in canonical
-- @(documentOrder, id)@ order, and every adjacency list is stored in that same
-- order. That is what makes traversal order a property of the input rather than
-- of a hash function (LAYOUT-027 rule 2). No function in this module iterates a
-- 'Data.HashMap' or a set whose order is not the canonical one.
--
-- Dominators use the iterative Cooper–Harvey–Kennedy formulation rather than
-- Lengauer–Tarjan. It computes the identical immediate-dominator relation, is
-- near-linear on the reducible graphs BPMN produces, and is a third of the
-- code; the choice is an implementation detail, not a deviation from §BRANCH-001.
module Sequent.Bpmn.Graph
  ( -- * Construction
    FlowGraph (..)
  , buildFlowGraph
  , Vtx
  , vtxOf
  , idOf
  , vertices
  , succsOf
  , predsOf
    -- * Analysis
  , dfsBackEdges
  , acyclicEdges
  , topoOrder
  , sccs
  , dominators
  , postDominators
  , immediateDominator
  , immediatePostDominator
  , dominates
  , postDominates
  , reachableFrom
  , longestPathLayers
  , weaklyConnectedComponents
  ) where

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)

import Sequent.Bpmn.Semantic

-- | A dense vertex index. Assigned in canonical order, so @compare@ on 'Vtx'
-- /is/ the canonical order and every tie-break can end there.
type Vtx = Int

-- | The flow graph of one scope.
--
-- Boundary events are contracted into their hosts for the purpose of layering
-- and dominance: a boundary event has no incoming sequence flow, so leaving it
-- as a source would make it a spurious graph root, and its outgoing flow has to
-- be ranked as though it left the host or the handler would land in the wrong
-- column. 'fgLift' records that contraction; 'fgNodes' still lists every real
-- node, boundary events included, because geometry needs them.
data FlowGraph = FlowGraph
  { fgOrder  :: [Vtx]
  -- ^ All vertices in canonical order.
  , fgIndex  :: Map NodeId Vtx
  , fgLabel  :: IntMap NodeId
  , fgSuccs  :: IntMap [Vtx]
  , fgPreds  :: IntMap [Vtx]
  , fgEdges  :: [(Vtx, Vtx, FlowId)]
  -- ^ Contracted edges in canonical order.
  , fgLift   :: IntMap Vtx
  -- ^ Boundary vertex to host vertex.
  , fgEntries :: [Vtx]
  -- ^ Vertices with no incoming edge, in canonical order. Start events first.
  , fgExits  :: [Vtx]
  }

vertices :: FlowGraph -> [Vtx]
vertices = fgOrder

vtxOf :: FlowGraph -> NodeId -> Maybe Vtx
vtxOf g i = Map.lookup i (fgIndex g)

idOf :: FlowGraph -> Vtx -> NodeId
idOf g v = fromMaybe (NodeId "?") (IM.lookup v (fgLabel g))

succsOf :: FlowGraph -> Vtx -> [Vtx]
succsOf g v = IM.findWithDefault [] v (fgSuccs g)

predsOf :: FlowGraph -> Vtx -> [Vtx]
predsOf g v = IM.findWithDefault [] v (fgPreds g)

-- | Build the flow graph of a scope. @scNodes@ and @scFlows@ are assumed to be
-- in canonical order already ('canonicalise'), so index assignment is a zip.
buildFlowGraph :: Scope -> FlowGraph
buildFlowGraph sc =
  FlowGraph
    { fgOrder = order
    , fgIndex = index
    , fgLabel = IM.fromList (zip order (map fnId nodes))
    , fgSuccs = adj [(a, b) | (a, b, _) <- edges]
    , fgPreds = adj [(b, a) | (a, b, _) <- edges]
    , fgEdges = edges
    , fgLift = liftMap
    , fgEntries = entries
    , fgExits = exits
    }
  where
    nodes = scNodes sc
    order = [0 .. length nodes - 1]
    index = Map.fromList (zip (map fnId nodes) order)

    ix i = Map.lookup i index

    liftMap =
      IM.fromList
        [ (v, h)
        | n <- nodes
        , Just att <- [boundaryHost n]
        , Just v <- [ix (fnId n)]
        , Just h <- [ix (baHost att)]
        ]

    lift v = IM.findWithDefault v v liftMap

    edges =
      [ (lift a, b, sfId f)
      | f <- scFlows sc
      , Just a <- [ix (sfSource f)]
      , Just b <- [ix (sfTarget f)]
      , lift a /= b
      ]

    adj ps = IM.fromListWith (flip (++)) [(a, [b]) | (a, b) <- ps]

    hasIn = IS.fromList [b | (_, b, _) <- edges]
    -- Boundary vertices are never graph roots: they are contracted away.
    isBoundaryV v = IM.member v liftMap
    entries =
      [v | v <- order, not (IS.member v hasIn), not (isBoundaryV v)]
    hasOut = IS.fromList [a | (a, _, _) <- edges]
    exits = [v | v <- order, not (IS.member v hasOut), not (isBoundaryV v)]

-- Depth-first analysis ------------------------------------------------------

-- | Back edges of a DFS spanning tree, rooted at the canonical entries and
-- then at any remaining unvisited vertex in canonical order. The set is a
-- function of the canonical order alone, which is what makes loop
-- classification reproducible.
dfsBackEdges :: FlowGraph -> [(Vtx, Vtx)]
dfsBackEdges g = reverse backs
  where
    (_, _, backs) = foldl' root (IS.empty, IS.empty, []) (fgEntries g ++ fgOrder g)

    root st@(seen, _, _) v
      | IS.member v seen = st
      | otherwise = go st v

    go (seen, stack, bs) v =
      let seen' = IS.insert v seen
          stack' = IS.insert v stack
          step (sn, sk, b) w
            | IS.member w sk = (sn, sk, (v, w) : b)
            | IS.member w sn = (sn, sk, b)
            | otherwise = go (sn, sk, b) w
          (seen'', stack'', bs') = foldl' step (seen', stack', bs) (succsOf g v)
       in (seen'', IS.delete v stack'', bs')

-- | The acyclic skeleton: every edge except the back edges.
acyclicEdges :: FlowGraph -> [(Vtx, Vtx)]
acyclicEdges g = [(a, b) | (a, b, _) <- fgEdges g, not (isBack (a, b))]
  where
    backSet = Map.fromList [(e, ()) | e <- dfsBackEdges g]
    isBack e = Map.member e backSet

-- | Kahn's algorithm over the acyclic skeleton, taking ready vertices in
-- canonical order. Any vertex left over (only possible if the caller passed a
-- cyclic edge set) is appended in canonical order rather than dropped.
topoOrder :: FlowGraph -> [(Vtx, Vtx)] -> [Vtx]
topoOrder g es = go ready0 deg0
  where
    succs = IM.fromListWith (flip (++)) [(a, [b]) | (a, b) <- es]
    deg0 = IM.fromListWith (+) ([(b, 1 :: Int) | (_, b) <- es] ++ [(v, 0) | v <- fgOrder g])
    ready0 = [v | v <- fgOrder g, IM.findWithDefault 0 v deg0 == 0]

    go [] deg = [v | v <- fgOrder g, IM.findWithDefault 0 v deg > 0]
    go (v : rest) deg =
      let (freed, deg') = foldl' dec ([], deg) (IM.findWithDefault [] v succs)
          dec (fs, d) w =
            let n = IM.findWithDefault 0 w d - 1
             in (if n == 0 then fs ++ [w] else fs, IM.insert w n d)
       in v : go (rest ++ freed) (IM.insert v 0 deg')

-- | Strongly connected components, Tarjan's algorithm, in canonical discovery
-- order. Components are returned with their members in canonical order, and
-- the component list itself sorted by smallest member.
sccs :: FlowGraph -> [[Vtx]]
sccs g = sortOn minimum (map (sortOn id) (comps final))
  where
    final = foldl' visitRoot st0 (fgOrder g)
    st0 = TS 0 IM.empty IM.empty [] IS.empty []

    visitRoot st v
      | IM.member v (idx st) = st
      | otherwise = strong st v

    strong st v =
      let n = counter st
          st1 =
            st
              { counter = n + 1
              , idx = IM.insert v n (idx st)
              , low = IM.insert v n (low st)
              , stk = v : stk st
              , onStk = IS.insert v (onStk st)
              }
          st2 = foldl' (edge v) st1 (succsOf g v)
       in if IM.findWithDefault 0 v (low st2) == n
            then pop st2 v
            else st2

    edge v st w
      | not (IM.member w (idx st)) =
          let st' = strong st w
              lw = IM.findWithDefault 0 w (low st')
           in st' {low = IM.adjust (min lw) v (low st')}
      | IS.member w (onStk st) =
          let iw = IM.findWithDefault 0 w (idx st)
           in st {low = IM.adjust (min iw) v (low st)}
      | otherwise = st

    pop st v =
      let (comp, rest) = break (== v) (stk st)
          members = comp ++ take 1 rest
       in st
            { stk = drop 1 rest
            , onStk = foldl' (flip IS.delete) (onStk st) members
            , comps = members : comps st
            }

data TarjanState = TS
  { counter :: !Int
  , idx     :: IntMap Int
  , low     :: IntMap Int
  , stk     :: [Vtx]
  , onStk   :: IntSet
  , comps   :: [[Vtx]]
  }

-- Dominance -----------------------------------------------------------------

-- | Immediate dominators over the given edge set, rooted at @entry@.
-- Unreachable vertices are absent from the result.
dominators :: FlowGraph -> Vtx -> [(Vtx, Vtx)] -> IntMap Vtx
dominators g entry es = iterateDom entry rpo preds
  where
    succs = IM.fromListWith (flip (++)) [(a, [b]) | (a, b) <- es]
    preds = IM.fromListWith (flip (++)) [(b, [a]) | (a, b) <- es]
    rpo = reversePostorder g entry succs

-- | Immediate post-dominators: dominators of the reversed edge set from a
-- virtual sink. The sink is the vertex @-1@, which cannot collide with a real
-- index; callers see it only if they ask about a vertex whose only
-- post-dominator is the scope exit.
postDominators :: FlowGraph -> [(Vtx, Vtx)] -> IntMap Vtx
postDominators g es = iterateDom sink rpo preds
  where
    sink = -1
    exitEdges = [(v, sink) | v <- fgOrder g, null (IM.findWithDefault [] v fwd)]
    fwd = IM.fromListWith (flip (++)) [(a, [b]) | (a, b) <- es]
    revEs = [(b, a) | (a, b) <- es ++ exitEdges]
    succs = IM.fromListWith (flip (++)) [(a, [b]) | (a, b) <- revEs]
    preds = IM.fromListWith (flip (++)) [(b, [a]) | (a, b) <- revEs]
    rpo = sink : filter (/= sink) (reversePostorderFrom sink succs)

-- | Cooper–Harvey–Kennedy: walk reverse postorder repeatedly, intersecting the
-- dominator chains of already-processed predecessors, until nothing changes.
-- Iteration is over a fixed list, so the fixpoint is reached in a fixed number
-- of passes for a given input (LAYOUT-027 rule 5).
iterateDom :: Vtx -> [Vtx] -> IntMap [Vtx] -> IntMap Vtx
iterateDom entry rpo preds = go (IM.singleton entry entry)
  where
    order = IM.fromList (zip rpo [0 :: Int ..])
    body = filter (/= entry) rpo

    go doms =
      let doms' = foldl' step doms body
       in if doms' == doms then doms else go doms'

    step doms v =
      case mapMaybe (\p -> if IM.member p doms then Just p else Nothing) (IM.findWithDefault [] v preds) of
        [] -> doms
        (p0 : ps) ->
          let new = foldl' (intersect doms) p0 ps
           in if IM.lookup v doms == Just new then doms else IM.insert v new doms

    intersect doms a b = walk a b
      where
        walk x y
          | x == y = x
          | otherwise =
              let nx = IM.findWithDefault maxBound x order
                  ny = IM.findWithDefault maxBound y order
               in if nx > ny
                    then walk (IM.findWithDefault x x doms) y
                    else walk x (IM.findWithDefault y y doms)

reversePostorder :: FlowGraph -> Vtx -> IntMap [Vtx] -> [Vtx]
reversePostorder g entry succs = ordered ++ [v | v <- fgOrder g, not (IS.member v seenSet)]
  where
    ordered = reversePostorderFrom entry succs
    seenSet = IS.fromList ordered

-- | Reverse postorder from an entry vertex.
--
-- The accumulator prepends each vertex /after/ its descendants have been
-- pushed, so the list is already in reverse postorder — entry first, then every
-- vertex before its own successors. Reversing it here would yield postorder and
-- silently invert every comparison in 'iterateDom', whose @intersect@ walks the
-- dominator chain by comparing these indices.
reversePostorderFrom :: Vtx -> IntMap [Vtx] -> [Vtx]
reversePostorderFrom entry succs = post
  where
    (_, post) = go (IS.empty, []) entry
    go (seen, acc) v
      | IS.member v seen = (seen, acc)
      | otherwise =
          let (seen', acc') = foldl' go (IS.insert v seen, acc) (IM.findWithDefault [] v succs)
           in (seen', v : acc')

immediateDominator :: IntMap Vtx -> Vtx -> Maybe Vtx
immediateDominator d v = case IM.lookup v d of
  Just w | w /= v -> Just w
  _ -> Nothing

immediatePostDominator :: IntMap Vtx -> Vtx -> Maybe Vtx
immediatePostDominator = immediateDominator

-- | Does @a@ dominate @b@? Walks the immediate-dominator chain; the chain is
-- at most as long as the graph is deep, and BPMN graphs are shallow.
dominates :: IntMap Vtx -> Vtx -> Vtx -> Bool
dominates d a b = go b (0 :: Int)
  where
    go v n
      | n > IM.size d + 1 = False
      | v == a = True
      | otherwise = case IM.lookup v d of
          Just w | w /= v -> go w (n + 1)
          _ -> False

postDominates :: IntMap Vtx -> Vtx -> Vtx -> Bool
postDominates = dominates

reachableFrom :: FlowGraph -> [Vtx] -> IntSet
reachableFrom g = go IS.empty
  where
    go seen [] = seen
    go seen (v : vs)
      | IS.member v seen = go seen vs
      | otherwise = go (IS.insert v seen) (succsOf g v ++ vs)

-- | ASAP longest-path layering over an acyclic edge set (LAYOUT-004).
-- @layer(v) = 0@ for sources, @max(layer(u)+1)@ otherwise.
longestPathLayers :: FlowGraph -> [(Vtx, Vtx)] -> IntMap Int
longestPathLayers g es = foldl' assign IM.empty (topoOrder g es)
  where
    preds = IM.fromListWith (flip (++)) [(b, [a]) | (a, b) <- es]
    assign acc v =
      let ps = mapMaybe (`IM.lookup` acc) (IM.findWithDefault [] v preds)
       in IM.insert v (if null ps then 0 else 1 + maximum ps) acc

-- | Weakly connected components, each in canonical order, ordered by their
-- smallest member (LAYOUT-034).
weaklyConnectedComponents :: FlowGraph -> [[Vtx]]
weaklyConnectedComponents g = sortOn minimum (go IS.empty (fgOrder g))
  where
    go _ [] = []
    go seen (v : vs)
      | IS.member v seen = go seen vs
      | otherwise =
          let comp = flood (IS.singleton v) [v]
           in sortOn id (IS.toAscList comp) : go (IS.union seen comp) vs
    flood seen [] = seen
    flood seen (v : vs) =
      let nbrs = [w | w <- succsOf g v ++ predsOf g v, not (IS.member w seen)]
       in flood (foldl' (flip IS.insert) seen nbrs) (nbrs ++ vs)
