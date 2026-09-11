-- | Phase 5 — bounding boxes and band assignment. @LLS → LLS@.
--
-- A post-order recursion over the region tree (BRANCH-015). Each branch reports
-- how far it reaches above and below its own axis; a region stacks its branches
-- from those reports; a parent branch then treats the whole region as one block.
--
-- Three rules do most of the work here and are worth naming, because getting
-- any of them wrong produces a recognisable class of bad diagram:
--
--   * __BRANCH-002__: a branch's box includes /everything it owns/ — nested
--     regions, exception bands, loop corridors, artifact gutters and external
--     labels. And it is reported as a signed pair, not as a height: @A[i] ≠
--     H[i]/2@ whenever a branch has an exception band below it, and collapsing
--     the two is, per the spec, "the single most common implementation error in
--     BPMN formatters".
--   * __BRANCH-015__: no per-level padding. Nesting depth adds nothing; only
--     genuine content height does. Adding @k·U@ per level is what produces the
--     vertical explosion of AP-014.
--   * __BRANCH-023__: with lanes, stacking happens lane by lane. A branch that
--     lives in another lane is placed around /that/ lane's axis, not by the
--     region's global formula.
--
-- The output is structural: a lane and a signed offset per node. No @y@ exists
-- until phase 7 turns lanes into rectangles.
module Sequent.Layout.Bands
  ( BandResult (..)
  , assignBands
  , LaneKey
  ) where

import Data.List (foldl', sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Set as Set

import Sequent.Bpmn.Graph (weaklyConnectedComponents, idOf, vtxOf)
import Sequent.Bpmn.Semantic
import Sequent.Layout.Analysis
import Sequent.Layout.Constants
import Sequent.Layout.Labels
import Sequent.Layout.Regions
import Sequent.Layout.Types
import Sequent.Text.Metrics (FontMetrics, tbHeight)

-- | Bands are allocated per lane; a scope without lanes has the single lane
-- 'Nothing'.
type LaneKey = Maybe LaneId

data BandResult = BandResult
  { bandPlacements :: Map NodeId BandPlacement
  , bandLaneExtent :: Map LaneKey Extent
  , bandLaneOrder  :: [LaneKey]
  , bandCorridors  :: [Corridor]
  , bandRegionExtent :: Map RegionId (Map LaneKey Extent)
  }
  deriving (Eq, Show)

data Env = Env
  { evScope    :: Scope
  , evRegions  :: RegionResult
  , evLayers   :: Map NodeId Int
  , evSizes    :: Map NodeId (Int, Int)
  , evAxis     :: AxisMap
  , evFont     :: FontMetrics
  , evMetrics  :: Metrics
  , evNodes    :: Map NodeId FlowNode
  , evBoundaries :: Map NodeId [NodeId]
  , evArtifacts :: Map NodeId ([Artifact], [Artifact])
  -- ^ Host to (above-gutter artifacts, below-gutter artifacts) — ART-001.
  , evCorridorsOf :: Map (RegionId, BranchId) [(FlowId, Int)]
  -- ^ Back edges owned by a branch, paired with their layer span.
  , evAnalysis :: Analysis
  }

-- | Every region's stack, computed once. The recursion of BRANCH-015 visits a
-- child once per parent branch and once again during assignment; without
-- memoisation a depth-@d@ region tree would be walked @2^d@ times. Building it
-- bottom-up in an explicit post-order keeps the pass linear (SPEC §J's
-- complexity note for P5) without depending on how lazily a container happens
-- to hold its values.
type Stacks = Map RegionId (Map LaneKey (Extent, Map BranchId Int))

assignBands
  :: Metrics
  -> FontMetrics
  -> Analysis
  -> RegionResult
  -> Map NodeId Int
  -> Map NodeId (Int, Int)
  -> AxisMap
  -> [LaneKey]
  -> BandResult
assignBands metrics font an regions layers sizes axes laneOrder =
  BandResult
    { bandPlacements = placements
    , bandLaneExtent = laneExtents
    , bandLaneOrder = laneOrder
    , bandCorridors = corridors
    , bandRegionExtent = Map.map (Map.map fst) stacks
    }
  where
    sc = anScope an
    env =
      Env
        { evScope = sc
        , evRegions = regions
        , evLayers = layers
        , evSizes = sizes
        , evAxis = axes
        , evFont = font
        , evMetrics = metrics
        , evNodes = scopeNodeMap sc
        , evBoundaries = boundaryIndex sc
        , evArtifacts = artifactIndex sc
        , evCorridorsOf = corridorOwners an regions
        , evAnalysis = an
        }

    stacks = buildStacks env

    raw = assignRegion env stacks (rrRoot regions) (Map.fromList [(l, 0) | l <- laneOrder])
    componentAdjusted = separateComponents env laneOrder raw
    -- HC-011 + HC-003. Phase 7 snaps every centre to the grid, so a band whose
    -- offset is not already a grid multiple ends up somewhere this phase never
    -- measured — and a lane sized from the unsnapped offsets can then be a few
    -- pixels too short for its own padding. Committing to the snapped offset
    -- here makes the number this phase reports the number the diagram draws.
    placements = Map.map snapPlacement (resolveBandCollisions env componentAdjusted)
    snapPlacement bp = bp {bpOffset = snapCenter (bpOffset bp)}
    laneExtents = laneExtentsOf env placements
    corridors = corridorsOf env placements

-- Indices --------------------------------------------------------------------

boundaryIndex :: Scope -> Map NodeId [NodeId]
boundaryIndex sc =
  Map.fromListWith
    (flip (++))
    [(baHost att, [fnId n]) | n <- scNodes sc, Just att <- [boundaryHost n]]

-- | ART-001: data objects live in the gutter above their host, annotations and
-- data stores in the gutter below.
artifactIndex :: Scope -> Map NodeId ([Artifact], [Artifact])
artifactIndex sc =
  Map.fromListWith
    (\(a1, b1) (a2, b2) -> (a1 ++ a2, b1 ++ b2))
    [ (host, if aboveGutter art then ([art], []) else ([], [art]))
    | as <- [scAssociations sc]
    , a <- as
    , (art, host) <- pairsOf a
    ]
  where
    byArt = Map.fromList [(artId art, art) | art <- scArtifacts sc]
    pairsOf a = case (asSource a, asTarget a) of
      (RefArtifact ai, RefNode h) -> [(art, h) | Just art <- [Map.lookup ai byArt]]
      (RefNode h, RefArtifact ai) -> [(art, h) | Just art <- [Map.lookup ai byArt]]
      _ -> []
    aboveGutter art = artKind art == AkDataObject

-- | LAYOUT-018: which branch owns each back edge's corridor. A loop entirely
-- inside one branch uses that branch's box as its base; a loop that straddles
-- branches is hoisted to the nearest common ancestor, which is what makes
-- nested loops non-crossing by construction.
corridorOwners :: Analysis -> RegionResult -> Map (RegionId, BranchId) [(FlowId, Int)]
corridorOwners an rr =
  Map.fromListWith
    (flip (++))
    [ (owner, [(sfId f, spanOf f)])
    | f <- scFlows (anScope an)
    , isBackFlow an (sfId f)
    , sfSource f /= sfTarget f
    , let owner = commonOwner (sfSource f) (sfTarget f)
    ]
  where
    fg = anGraph an
    spanOf f = case (vtxOf fg (sfSource f), vtxOf fg (sfTarget f)) of
      (Just a, Just b) -> abs (a - b)
      _ -> 0
    chainOf n = case Map.lookup n (rrNodeBranch rr) of
      Nothing -> [(rrRoot rr, BranchId 0)]
      Just rb -> walk rb
    walk rb@(rid, _)
      | rid == rrRoot rr = [rb]
      | otherwise = case Map.lookup rid (rrRegions rr) >>= rgParent of
          Nothing -> [rb, (rrRoot rr, BranchId 0)]
          Just pid -> rb : walk (pid, branchHolding pid rid)
    branchHolding pid rid = case Map.lookup pid (rrRegions rr) of
      Just reg -> case [brId b | b <- rgBranches reg, rid `elem` brRegions b] of
        (b : _) -> b
        [] -> BranchId 0
      Nothing -> BranchId 0
    commonOwner a b =
      let ca = reverse (chainOf a)
          cb = reverse (chainOf b)
          shared = map fst (takeWhile (uncurry (==)) (zip ca cb))
       in case reverse shared of
            (x : _) -> x
            [] -> (rrRoot rr, BranchId 0)

-- Extents --------------------------------------------------------------------

-- | The vertical room a single node claims about its own axis, including the
-- decorations it owns: external label, boundary events, artifact gutters.
nodeExtent :: Env -> NodeId -> Extent
nodeExtent env n = base <> labelE <> boundaryE <> artifactE
  where
    (w, h) = Map.findWithDefault (taskW, taskH) n (evSizes env)
    -- LAYOUT-020: measured about the node's /axis/, which is its box centre
    -- for everything except an expanded subprocess. Reporting @h/2@ on both
    -- sides of a container whose spine is 70 px from its top would reserve the
    -- room in the wrong place and the band below would be laid over its
    -- bottom half.
    d = axisOffsetOf (evAxis env) n
    base = Extent (h `div` 2 + d) (h `div` 2 - d)
    node = Map.lookup n (evNodes env)
    labelE = maybe mempty (externalLabelExtent (evFont env)) node
    -- LAYOUT-016 + LABEL-004: a boundary event claims half its own height past
    -- the host border and then its label below that. Reserving only the event
    -- was what let two boundary labels of one host land on top of each other:
    -- phase 9 was asked to find room that phase 5 had never set aside.
    boundaryE = case Map.findWithDefault [] n (evBoundaries env) of
      [] -> mempty
      bs ->
        let (bottoms, tops) = splitAt (boundaryCapacity w) (sortOn unNodeId bs)
         in Extent (reserve tops) (reserve bottoms)
    reserve [] = 0
    reserve bs = evSize `div` 2 + labelGap + maximum (0 : map boundaryLabelH bs)
    boundaryLabelH b =
      case Map.lookup b (evNodes env) >>= fnName of
        Just t | not (T.null t) -> tbHeight (externalLabelBox (evFont env) t)
        _ -> 0
    artifactE = case Map.lookup n (evArtifacts env) of
      Nothing -> mempty
      Just (aboveArts, belowArts) ->
        Extent
          (if null aboveArts then 0 else artifactGap + dataH + labelGap + lineH)
          (if null belowArts then 0 else artifactGap + dataH + labelGap + lineH)

laneOfNode :: Env -> NodeId -> LaneKey
laneOfNode env n = Map.lookup n (evNodes env) >>= fnLane

-- | Compute every region's stack bottom-up, children before parents.
buildStacks :: Env -> Stacks
buildStacks env = go (rrRoot (evRegions env)) Map.empty
  where
    go rid acc =
      let acc' = foldl' (flip go) acc (Map.findWithDefault [] rid (rrChildren (evRegions env)))
       in Map.insert rid (stackRegionUsing env acc' rid) acc'

-- | BRANCH-002. Everything the branch owns, per lane.
branchExtent :: Env -> Stacks -> RegionId -> Branch -> Map LaneKey Extent
branchExtent env stacks rid b =
  Map.unionsWith mergeExtent (nodeParts ++ childParts ++ [corridorPart])
  where
    nodeParts = [Map.singleton (laneOfNode env n) (nodeExtent env n) | n <- brNodes b]
    childParts = [regionExtent stacks r | r <- brRegions b]
    -- LAYOUT-018: corridors sit outside the branch box, so they are added on
    -- top of everything the branch already claims above its axis.
    corridorPart = case Map.lookup (rid, brId b) (evCorridorsOf env) of
      Nothing -> Map.empty
      Just [] -> Map.empty
      Just fs ->
        let above = maximum (0 : [exAbove e | e <- Map.elems (Map.unionsWith mergeExtent (nodeParts ++ childParts))])
            depth = above + loopClear + length fs * corridorPitch
            lane = case brNodes b of
              (n : _) -> laneOfNode env n
              [] -> Nothing
         in Map.singleton lane (Extent depth 0)

-- | A region's extent per lane: its branches stacked around the region axis.
regionExtent :: Stacks -> RegionId -> Map LaneKey Extent
regionExtent stacks rid = Map.map fst (Map.findWithDefault Map.empty rid stacks)

-- | Stack a region's branches, lane by lane (BRANCH-023). Returns, per lane,
-- the region's own extent and each branch's axis offset within it.
stackRegionUsing :: Env -> Stacks -> RegionId -> Map LaneKey (Extent, Map BranchId Int)
stackRegionUsing env stacks rid = case Map.lookup rid (rrRegions (evRegions env)) of
  Nothing -> Map.empty
  Just reg ->
    let bs = rgBranches reg
        -- An empty branch — one that runs straight from the split to the
        -- merge — has no content and therefore no lane of its own. It must
        -- still occupy a slot, or the branch that holds the axis can drop out
        -- of the stack entirely and the region loses its axis (BRANCH-008).
        splitLane = case rgKind reg of
          RkSplit sp _ _ -> laneOfNode env sp
          _ -> Nothing
        ensure m = if Map.member splitLane m then m else Map.insert splitLane mempty m
        exts = [(b, ensure (branchExtent env stacks rid b)) | b <- bs]
        lanes = Set.toList (Set.fromList (concatMap (Map.keys . snd) exts))
     in Map.fromList [(l, stackLane (evMetrics env) (evSizes env) reg (inLane l exts)) | l <- lanes]
  where
    inLane l exts = [(b, e) | (b, m) <- exts, Just e <- [Map.lookup l m]]

-- | The stacking formulas of BRANCH-003…006, applied to one lane's worth of a
-- region's branches.
stackLane
  :: Metrics
  -> Map NodeId (Int, Int)
  -> Region
  -> [(Branch, Extent)]
  -> (Extent, Map BranchId Int)
stackLane metrics sizes reg entries
  | null entries = (mempty, Map.empty)
  | otherwise = withSplitClearance $ case axisEntry of
      Just axisB | rgMode reg == AxisLock -> axisLock axisB
      _ -> bboxCenter
  where
    ordered = [(b, e) | b <- slotOrderOf (map fst entries), Just e <- [lookup' b]]
      where
        lookup' b = lookup (brId b) [(brId x, e) | (x, e) <- entries]
    slotOrderOf bs = slotOrderLocal bs
    axisEntry = case [be | be@(b, _) <- ordered, brSide b == SideAxis] of
      (be : _) -> Just be
      [] -> Nothing

    gap = mBranchGapY metrics

    -- LAYOUT-017: exception content is separated from ordinary branch content
    -- by EXC_GAP_Y and lives outside every ordinary band.
    gapBetween prev nxt
      | brPolarity nxt == PolException && brPolarity prev /= PolException = excGapY
      | otherwise = gap

    -- HC-005. A connector to an off-axis branch leaves the split through its
    -- north or south port and runs perpendicular to the branch axis before it
    -- turns, so that stub is exactly the distance from the gateway's border to
    -- the band. A band closer than @MIN_SEG@ to that border cannot be routed at
    -- all, and discovering it in phase 8 is too late: the router can choose a
    -- channel, but it cannot move a band. So the band allocator owes the router
    -- a slot it can reach, and pays here.
    --
    -- The same distance covers the approach into the merge, which is the mirror
    -- of the stub, hence the maximum over both gateways.
    splitClear = case rgKind reg of
      RkSplit sp mm _ -> ceilU (maximum (map halfOf (sp : maybe [] pure mm)) + minSeg)
      _ -> 0

    halfOf n = maybe 0 (\(_, h) -> h `div` 2) (Map.lookup n sizes)

    -- Push any band that is too close straight out to the clearance, leaving
    -- everything already clear where it is. Applied to the magnitude, so a
    -- symmetric pair stays symmetric and no gap ever shrinks.
    withSplitClearance (ext, offs)
      | splitClear <= 0 = (ext, offs)
      | offs' == offs = (ext, offs)
      | otherwise = (extentFrom offs', offs')
      where
        offs' = Map.map push offs
        push o
          | o == 0 = 0
          | o < 0 = min o (negate splitClear)
          | otherwise = max o splitClear

    -- Re-derive the region's own extent from the offsets it ended up with,
    -- rather than adjusting the one the stacking formula reported: after a push
    -- the two are no longer the same number.
    extentFrom offs =
      Extent
        (maximum (0 : [exAbove e - o | (b, e) <- ordered, Just o <- [Map.lookup (brId b) offs]]))
        (maximum (0 : [exBelow e + o | (b, e) <- ordered, Just o <- [Map.lookup (brId b) offs]]))

    axisLock (axisB, axisE) =
      let aboves = reverse [be | be <- takeWhile (not . isAxis) ordered]
          belows = drop 1 (dropWhile (not . isAxis) ordered)
          isAxis (b, _) = brSide b == SideAxis
          (topExtent, upOffsets) = walkUp (exAbove axisE) axisB aboves
          (botExtent, downOffsets) = walkDown (exBelow axisE) axisB belows
       in ( Extent topExtent botExtent
          , Map.fromList ((brId axisB, 0) : upOffsets ++ downOffsets)
          )

    walkUp top0 _ [] = (top0, [])
    walkUp top0 prev ((b, e) : rest) =
      let g = gapBetween prev b
          off = negate (top0 + g + exBelow e)
          top' = top0 + g + extentH e
          (t, os) = walkUp top' b rest
       in (t, (brId b, off) : os)

    walkDown bot0 _ [] = (bot0, [])
    walkDown bot0 prev ((b, e) : rest) =
      let g = gapBetween prev b
          off = bot0 + g + exAbove e
          bot' = bot0 + g + extentH e
          (bt, os) = walkDown bot' b rest
       in (bt, (brId b, off) : os)

    -- BRANCH-003(b). N-8: round the half-stack up to a whole grid unit, so
    -- snapping cannot break the mirror afterwards.
    --
    -- The rounding belongs to the extent the region /reports/, not to where the
    -- content sits. Starting the walk at the rounded edge shifts the whole stack
    -- up by the remainder and lands a symmetric pair of branches at -52 and +44
    -- instead of +/-48 — destroying the very symmetry the rounding exists to
    -- protect, and leaving the lower band close enough to the split to break
    -- HC-005. Content is centred on the axis; the slack stays in the extent.
    bboxCenter =
      let hs = map (extentH . snd) ordered
          gaps = zipWith (\(a, _) (c, _) -> gapBetween a c) ordered (drop 1 ordered)
          total = sum hs + sum gaps
          half = ceilU ((total + 1) `div` 2)
          start = negate ((total + 1) `div` 2)
          go _ [] = []
          go cur ((b, e) : rest) =
            let off = cur + exAbove e
                nextGap = case rest of
                  ((b', _) : _) -> gapBetween b b'
                  [] -> 0
             in (brId b, off) : go (off + exBelow e + nextGap) rest
       in (Extent half half, Map.fromList (go start ordered))

-- | Local copy of the slot ordering so this module does not depend on the
-- ordering phase's export list changing shape.
slotOrderLocal :: [Branch] -> [Branch]
slotOrderLocal bs = reverse (sortOn brRank aboves) ++ axis ++ sortOn brRank belows
  where
    aboves = [b | b <- bs, brSide b == SideAbove]
    axis = sortOn brRank [b | b <- bs, brSide b == SideAxis]
    belows = [b | b <- bs, brSide b == SideBelow]

-- Assignment -----------------------------------------------------------------

-- | Top-down pass: turn the stacking offsets into an absolute offset per node.
assignRegion :: Env -> Stacks -> RegionId -> Map LaneKey Int -> Map NodeId BandPlacement
assignRegion env stacks rid base = case Map.lookup rid (rrRegions (evRegions env)) of
  Nothing -> Map.empty
  Just reg ->
    let stacked = Map.findWithDefault Map.empty rid stacks
        branchBase b =
          Map.mapWithKey
            (\l b0 -> b0 + maybe 0 (fromMaybe 0 . Map.lookup (brId b) . snd) (Map.lookup l stacked))
            base
     in Map.unions
          [ Map.unions
              ( [ Map.singleton n (BandPlacement lane (Map.findWithDefault 0 lane (branchBase b)))
                | n <- brNodes b
                , let lane = laneOfNode env n
                ]
                  ++ [assignRegion env stacks child (branchBase b) | child <- brRegions b]
              )
          | b <- rgBranches reg
          ]

-- | LAYOUT-034: weakly connected components never interleave. Each is laid out
-- independently and then stacked, in @(minLayer, id)@ order, with
-- @2·BRANCH_GAP_Y@ between their boxes.
separateComponents :: Env -> [LaneKey] -> Map NodeId BandPlacement -> Map NodeId BandPlacement
separateComponents env _ placements
  | length comps <= 1 = placements
  | otherwise = foldl' shift placements (zip [0 ..] (drop 1 orderedComps))
  where
    fg = anGraph (evAnalysis env)
    comps = map (map (idOf fg)) (weaklyConnectedComponents fg)
    minLayerOf c = minimum (maxBound : mapMaybe (`Map.lookup` evLayers env) c)
    orderedComps = sortOn (\c -> (minLayerOf c, map unNodeId c)) comps
    heightOf c =
      let os = [bpOffset (Map.findWithDefault (BandPlacement Nothing 0) n placements) | n <- c]
          es = [nodeExtent env n | n <- c]
          tops = zipWith (\o e -> o - exAbove e) os es
          bots = zipWith (\o e -> o + exBelow e) os es
       in if null os then 0 else maximum bots - minimum tops
    shift acc (k, c) =
      let dy = sum (map (\c' -> heightOf c' + 2 * mBranchGapY (evMetrics env)) (take (k + 1) orderedComps))
       in foldl' (\m n -> Map.adjust (\bp -> bp {bpOffset = bpOffset bp + dy}) n m) acc c

-- | The local fallback of LAYOUT-033, applied where structure ran out.
--
-- Structured regions cannot collide — sibling branch boxes are disjoint by
-- construction — so anything colliding here comes from an unstructured
-- residue, a shared node reached from two branches, or two components of a
-- disconnected graph. Nodes keep their relative order and only the overlapping
-- ones move, which keeps the repair local and monotone (it can only increase
-- separation, so it terminates).
resolveBandCollisions :: Env -> Map NodeId BandPlacement -> Map NodeId BandPlacement
resolveBandCollisions env placements = foldl' fixGroup placements groups
  where
    groups =
      Map.elems $
        Map.fromListWith
          (flip (++))
          [ ((laneOfNode env n, layer), [n])
          | n <- map fnId (scNodes (evScope env))
          , not (isBoundaryNode n)
          , Just layer <- [Map.lookup n (evLayers env)]
          ]
    isBoundaryNode n = maybe False nodeIsBoundary (Map.lookup n (evNodes env))

    fixGroup acc ns
      | length ns < 2 = acc
      | otherwise = snd (foldl' place (Nothing, acc) ordered)
      where
        ordered = sortOn (\n -> (offsetOf acc n, unNodeId n)) ns
        place (Nothing, m) n = (Just (bottomOf m n), m)
        place (Just prevBottom, m) n
          -- Only a genuine overlap is a collision. Enforcing a full
          -- BRANCH_GAP_Y here would fight the band allocator, which uses
          -- smaller gaps on purpose: an exception band is separated by
          -- EXC_GAP_Y (LAYOUT-017), and pushing it further would put the
          -- handler off the axis its route was planned around.
          | top >= prevBottom = (Just (bottomOf m n), m)
          | otherwise =
              let dy = ceilU (prevBottom + branchGapYMin - top)
                  m' = Map.adjust (\bp -> bp {bpOffset = bpOffset bp + dy}) n m
               in (Just (bottomOf m' n), m')
          where
            top = topOf m n
        offsetOf m n = bpOffset (Map.findWithDefault (BandPlacement Nothing 0) n m)
        topOf m n = offsetOf m n - exAbove (nodeExtent env n)
        bottomOf m n = offsetOf m n + exBelow (nodeExtent env n)

-- Lane extents and corridors -------------------------------------------------

laneExtentsOf :: Env -> Map NodeId BandPlacement -> Map LaneKey Extent
laneExtentsOf env placements =
  Map.fromListWith
    mergeExtent
    [ (bpLane bp, Extent (negate (min 0 top)) (max 0 bottom))
    | (n, bp) <- Map.toAscList placements
    , let e = nodeExtent env n
    , let top = bpOffset bp - exAbove e
    , let bottom = bpOffset bp + exBelow e
    ]

-- | LAYOUT-018: corridors ordered by span descending, so the outermost loop
-- gets the largest offset and nested loops cannot cross.
--
-- Side selection is EDGE-013's exception, decided per owning branch and
-- all-or-nothing: a loop whose latch sits below the spine routes /below/. The
-- canonical corridor is above, but reaching it from a below-spine latch means
-- a vertical run straight through the latch's own column — which is where the
-- spine is, so the loopback would cut through the main flow (AP-008, "the most
-- damaging single defect"). Going the other way is clear by construction,
-- because nothing is allocated outside the region on that side.
corridorsOf :: Env -> Map NodeId BandPlacement -> [Corridor]
corridorsOf env placements =
  concat
    [ [ Corridor
          { coFlow = f
          , coIndex = k
          , coLane = lane
          , coSpan = sp
          , coAbove = above
          , coOffset =
              if above
                then top - loopClear - k * corridorPitch
                else bottom + loopClear + k * corridorPitch
          }
      | (k, (f, sp)) <- zip [0 ..] (sortOn (\(f, sp) -> (negate sp, unFlowId f)) fs)
      ]
    | ((rid, bid), fs) <- Map.toAscList (evCorridorsOf env)
    , let (lane, top, bottom) = ownerBox rid bid
    , let above = not (any (latchBelow . fst) fs)
    ]
  where
    latchBelow f = case [sfSource fl | fl <- scFlows (evScope env), sfId fl == f] of
      (n : _) -> maybe False ((> 0) . bpOffset) (Map.lookup n placements)
      [] -> False

    ownerBox rid bid = case Map.lookup rid (rrRegions (evRegions env)) of
      Nothing -> (Nothing, 0, 0)
      Just reg -> case [b | b <- rgBranches reg, brId b == bid] of
        (b : _) ->
          let ns = allNodesOf b
              spans =
                [ (bpOffset bp - exAbove (nodeExtent env n), bpOffset bp + exBelow (nodeExtent env n))
                | n <- ns
                , Just bp <- [Map.lookup n placements]
                ]
              lane = case ns of
                (n : _) -> maybe Nothing bpLane (Map.lookup n placements)
                [] -> Nothing
           in ( lane
              , if null spans then 0 else minimum (map fst spans)
              , if null spans then 0 else maximum (map snd spans)
              )
        [] -> (Nothing, 0, 0)
    allNodesOf b =
      brNodes b
        ++ concat
          [ concatMap allNodesOf (rgBranches reg)
          | r <- brRegions b
          , Just reg <- [Map.lookup r (rrRegions (evRegions env))]
          ]
