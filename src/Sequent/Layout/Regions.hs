-- | Phase 2 — structural region detection. @LLS → LLS@.
--
-- Decomposes the acyclic skeleton into single-entry\/single-exit regions
-- (BRANCH-001), nests them into a tree, classifies each branch (BRANCH-007)
-- and identifies the spine (LAYOUT-006).
--
-- This is the phase that makes the rest of the engine simple. Once the region
-- tree exists, vertical placement is a post-order recursion over it
-- (BRANCH-015) and sibling branches cannot collide /by construction/, with no
-- collision test at all. Where the decomposition fails, the damage is confined
-- to one region (LAYOUT-033) instead of degrading the whole diagram.
--
-- Ownership model: a region owns the nodes strictly between its split and its
-- merge that no nested region owns. A nested region's split and merge are
-- therefore owned by the /parent/ branch — which is exactly right, because
-- they sit on that branch's axis — while the nested region contributes only
-- its off-axis content to the parent's extent. That is what stops the split
-- and merge being counted twice in BRANCH-002's bounding box.
--
-- Two documented fallbacks, both from SPEC §I.2:
--
--   * __Branches sharing a node.__ The node is assigned to the highest-ranked
--     branch that reaches it; its other incoming edges become cross-band edges
--     routed in channels. The region stays structured.
--   * __Irreducible loops.__ An SCC entered at more than one vertex has no
--     loop header, so it becomes an 'RkUnstructured' block laid out by the
--     local fallback and treated as opaque from outside.
module Sequent.Layout.Regions
  ( RegionResult (..)
  , detectRegions
  , branchAxisNodes
  , regionOf
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set

import Sequent.Bpmn.Graph
import Sequent.Bpmn.Semantic
import Sequent.Layout.Analysis
import Sequent.Layout.Branches
import Sequent.Layout.Layering (byLayer, layerSpanOf)
import Sequent.Layout.Types

data RegionResult = RegionResult
  { rrRegions      :: Map RegionId Region
  , rrRoot         :: RegionId
  , rrNodeRegion   :: Map NodeId RegionId
  , rrNodeBranch   :: Map NodeId (RegionId, BranchId)
  , rrUnstructured :: [NodeId]
  , rrSpine        :: [NodeId]
  , rrChildren     :: Map RegionId [RegionId]
  }
  deriving (Eq, Show)

-- | A raw SESE candidate, before nesting and classification.
data Cand = Cand
  { cdSplit   :: !Vtx
  , cdMerge   :: Maybe Vtx
  , cdMembers :: IS.IntSet
  , cdSeeds   :: [(FlowId, Vtx)]
  }

detectRegions :: Bool -> Analysis -> Map NodeId Int -> RegionResult
detectRegions large a layers =
  RegionResult
    { rrRegions = regions
    , rrRoot = rootId
    , rrNodeRegion = nodeRegion
    , rrNodeBranch = nodeBranch
    , rrUnstructured = unstructuredNodes
    , rrSpine = spine
    , rrChildren = Map.insert rootId topLevel childrenOf
    }
  where
    fg = anGraph a
    sc = anScope a
    byId = scopeNodeMap sc
    flowById = scopeFlowMap sc

    acycOut = IM.fromListWith (flip (++)) [(uu, [v]) | (uu, v) <- anAcyclic a]
    acycIn = IM.fromListWith (flip (++)) [(v, [uu]) | (uu, v) <- anAcyclic a]

    -- Irreducible SCCs (SPEC §I.2 "Cycles involving multiple gateways"): an SCC
    -- entered at more than one vertex has no loop header, so it cannot be a
    -- loop region and goes to the local fallback.
    irreducible =
      IS.unions
        [ IS.fromList comp
        | comp <- anSccs a
        , length comp > 1
        , let inSet = IS.fromList comp
        , length [v | v <- comp, any (\p -> not (IS.member p inSet)) (predsOf fg v)] > 1
        ]

    candidates =
      sortOn (\c -> (IS.size (cdMembers c), cdSplit c))
        [ c
        | v <- fgOrder fg
        , length (IM.findWithDefault [] v acycOut) >= 2
        , not (IS.member v irreducible)
        , Just c <- [candidateFor v]
        ]

    candidateFor v =
      let m = case IM.lookup v (anIpdom a) of
            Just w | w >= 0 -> Just w
            _ -> Nothing
          members = IS.filter (\w -> w /= v && Just w /= m) (reachWithin v)
          entersOk =
            all
              (\w -> all (\pp -> pp == v || IS.member pp members) (IM.findWithDefault [] w acycIn))
              (IS.toAscList members)
          leavesOk =
            all
              (\w -> all (\s -> IS.member s members || Just s == m) (IM.findWithDefault [] w acycOut))
              (IS.toAscList members)
          succsOk = all (\s -> IS.member s members || Just s == m) (IM.findWithDefault [] v acycOut)
          seeds = [(f, s) | (uu, s, f) <- fgEdges fg, uu == v, not (isBackFlow a f)]
       in if IS.null members || not entersOk || not leavesOk || not succsOk
            then Nothing
            else Just (Cand v m members seeds)

    reachWithin v = go IS.empty (IM.findWithDefault [] v acycOut)
      where
        stop = case IM.lookup v (anIpdom a) of
          Just w | w >= 0 -> Just w
          _ -> Nothing
        go seen [] = seen
        go seen (w : ws)
          | IS.member w seen = go seen ws
          | Just w == stop = go seen ws
          | otherwise = go (IS.insert w seen) (IM.findWithDefault [] w acycOut ++ ws)

    -- Innermost regions get the lowest ids, so a child is always numbered
    -- before its parent and nesting is a single scan.
    numbered = zip (map RegionId [1 ..]) candidates
    candMap = Map.fromList numbered
    rootId = RegionId 0

    parentOf rid = case Map.lookup rid candMap of
      Nothing -> Nothing
      Just c ->
        case [ p
             | (p, pc) <- numbered
             , p /= rid
             , IS.isSubsetOf (cdMembers c) (cdMembers pc)
             , IS.member (cdSplit c) (cdMembers pc)
             ] of
          (p : _) -> Just p
          [] -> Nothing

    childrenOf =
      Map.fromListWith
        (flip (++))
        [(fromMaybe rootId (parentOf rid), [rid]) | (rid, _) <- numbered]

    childrenIds rid = Map.findWithDefault [] rid childrenOf

    -- Nodes a region owns directly: its members minus everything a nested
    -- region owns. A nested split and merge fall out here, which is what puts
    -- them on the parent branch's axis.
    directOf rid = case Map.lookup rid candMap of
      Nothing -> IS.empty
      Just c -> IS.difference (cdMembers c) (IS.unions (map membersOf (childrenIds rid)))

    membersOf rid = maybe IS.empty cdMembers (Map.lookup rid candMap)

    topLevel = [rid | (rid, _) <- numbered, parentOf rid == Nothing]

    -- Branches ---------------------------------------------------------------

    branchesOf rid = case Map.lookup rid candMap of
      Nothing -> []
      Just c ->
        let raw = [(f, seedMembers c s) | (f, s) <- cdSeeds c]
            shared = sharedVertices (map snd raw)
            best = bestBranch raw
            resolved =
              [ (f, if Just f == best then IS.union ms shared else IS.difference ms shared)
              | (f, ms) <- raw
              ]
         in [mkBranch c rid k f ms | (k, (f, ms)) <- zip [0 ..] resolved]

    -- The branch a shared node is given to: lowest document order, then most
    -- content, then id. Deterministic, and consistent with the comparator's
    -- own final tie-breaks.
    bestBranch raw = case sortOn key raw of
      ((f, _) : _) -> Just f
      [] -> Nothing
      where
        key (f, ms) =
          ( maybe maxBound sfDocOrder (Map.lookup f flowById)
          , negate (IS.size ms)
          , unFlowId f
          )

    sharedVertices mss =
      IS.fromList [v | v <- IS.toAscList (IS.unions mss), length (filter (IS.member v) mss) > 1]

    seedMembers c s
      | Just s == cdMerge c = IS.empty
      | otherwise = go IS.empty [s]
      where
        go seen [] = seen
        go seen (w : ws)
          | IS.member w seen = go seen ws
          | not (IS.member w (cdMembers c)) = go seen ws
          | otherwise = go (IS.insert w seen) (IM.findWithDefault [] w acycOut ++ ws)

    mkBranch c rid k f ms =
      Branch
        { brId = BranchId k
        , brEntry = Just f
        , brNodes = byLayer layers directIds
        , brRegions = [kid | kid <- childrenIds rid, IS.member (splitVtx kid) ms]
        , brRank = 0
        , brSide = SideAbove
        , brPolarity = classifyPolarity byId entry allIds
        , brTerminates = terminates
        , brSpanLayers = layerSpanOf layers allIds
        , brNodeCount = length allIds
        , brPriority = entry >>= sfPriority
        , brExtent = Map.empty
        }
      where
        entry = Map.lookup f flowById
        allIds = map (idOf fg) (IS.toAscList ms)
        directIds =
          [ i
          | i <- map (idOf fg) (IS.toAscList (IS.intersection ms (directOf rid)))
          , maybe True (not . nodeIsBoundary) (Map.lookup i byId)
          ]
        splitVtx kid = maybe (-9) cdSplit (Map.lookup kid candMap)
        -- BRANCH-014: a branch terminates when no node in it flows to the
        -- region's merge. With no merge at all (an open region, BRANCH-019)
        -- every branch that reaches an end event terminates.
        terminates = case cdMerge c of
          Just m -> not (any (\w -> m `elem` IM.findWithDefault [] w acycOut) (IS.toAscList ms))
          Nothing -> any (\i -> maybe False isEndEvent (Map.lookup i byId)) allIds

    -- Assembly ---------------------------------------------------------------

    buildRegion rid c =
      Region
        { rgId = rid
        , rgKind = RkSplit (idOf fg (cdSplit c)) (idOf fg <$> cdMerge c) gw
        , rgParent = parentOf rid
        , rgBranches = ranked
        , rgMode = mode
        , rgPeerSymmetric = peerSymmetricRegion gw primary bs
        , rgHasPrimary = primary
        , rgOpen = cdMerge c == Nothing
        , rgMembers = map (idOf fg) (IS.toAscList (cdMembers c))
        }
      where
        bs = branchesOf rid
        entryOf b = brEntry b >>= (`Map.lookup` flowById)
        primary = hasPrimaryRegion bs (map entryOf bs)
        gw = fromMaybe GwExclusive (Map.lookup (idOf fg (cdSplit c)) byId >>= gatewayKindOf)
        mode = chooseMode large gw (length bs) primary
        ranked = assignSides mode (rankBranches entryOf bs)

    claimed = IS.unions (map membersOf topLevel)
    -- Boundary events are contracted into their hosts for layering, so their
    -- vertices are isolated in the flow graph and would otherwise fall into
    -- the root branch. They are not band content: LAYOUT-016 places them on
    -- their host's border, and their vertical room is already reserved through
    -- the host's own extent.
    rootNodes =
      byLayer
        layers
        [ fnId n
        | n <- scNodes sc
        , not (nodeIsBoundary n)
        , maybe True (\v -> not (IS.member v claimed)) (vtxOf fg (fnId n))
        ]

    rootBranch =
      Branch
        { brId = BranchId 0
        , brEntry = Nothing
        , brNodes = rootNodes
        , brRegions = topLevel
        , brRank = 1
        , brSide = SideAxis
        , brPolarity = PolNeutral
        , brTerminates = False
        , brSpanLayers = layerSpanOf layers rootNodes
        , brNodeCount = length rootNodes
        , brPriority = Nothing
        , brExtent = Map.empty
        }

    rootRegion =
      Region
        { rgId = rootId
        , rgKind = RkRoot
        , rgParent = Nothing
        , rgBranches = [rootBranch]
        , rgMode = AxisLock
        , rgPeerSymmetric = False
        , rgHasPrimary = True
        , rgOpen = False
        , rgMembers = map fnId (scNodes sc)
        }

    regions = Map.insert rootId rootRegion (Map.fromList [(rid, buildRegion rid c) | (rid, c) <- numbered])

    nodeBranch =
      Map.fromList
        [ (n, (rgId r, brId b))
        | (_, r) <- Map.toAscList regions
        , b <- rgBranches r
        , n <- brNodes b
        ]

    nodeRegion = Map.map fst nodeBranch

    unstructuredNodes = sortOn unNodeId (map (idOf fg) (IS.toAscList irreducible))

    -- LAYOUT-006: the axis chain. Every node whose branch holds the axis, all
    -- the way down the region tree, sorted by layer — which is the order a
    -- reader follows it in.
    spine = byLayer layers (Set.toList (Set.fromList (collect rootBranch)))
    collect b =
      brNodes b
        ++ concat
          [ collect ab
          | r <- brRegions b
          , Just reg <- [Map.lookup r regions]
          , rgMode reg == AxisLock
          , ab <- rgBranches reg
          , brSide ab == SideAxis
          ]

-- | The nodes on a branch's own axis, in layer order.
branchAxisNodes :: Branch -> [NodeId]
branchAxisNodes = brNodes

regionOf :: RegionResult -> NodeId -> RegionId
regionOf rr n = Map.findWithDefault (rrRoot rr) n (rrNodeRegion rr)
