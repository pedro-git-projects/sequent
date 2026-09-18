-- | Hard-constraint and positional-semantics validation of rendered geometry.
--
-- SPEC §C: "Never violated. If a candidate layout violates one of these, it is
-- not a layout." Every detector here is the one named in the rule's __Detect__
-- clause, and every violation carries its rule id so a failure names the rule
-- it broke rather than describing a symptom.
--
-- Tier matters as much as the check. T0 and T1 violations fail the build (SPEC
-- §K "absolute quality gates"); T2 and below are advisories that still return a
-- diagram. That distinction is the difference between "this file is wrong" and
-- "this file could be prettier", and callers are entitled to both.
module Sequent.Layout.Validate
  ( ValidationInput (..)
  , validateGeometry
  , hardConstraints
  , positionalConstraints
  ) where

import Data.List (sortOn, tails)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Semantic
import Sequent.Diagnostic (RuleId (..))
import Sequent.Layout.Constants
import Sequent.Layout.Labels (internalLabel, labelledSegment, nodeHasMarker)
import Sequent.Layout.Ports
import Sequent.Layout.Types
import Sequent.Text.Metrics (FontMetrics, tbHeight, tbWidth)

data ValidationInput = ValidationInput
  { viScope     :: Scope
  , viShapes    :: Map NodeId Rect
  , viRoutes    :: Map FlowId Route
  , viLabels    :: Map LabelKey LabelBox
  , viLanes     :: Map LaneId Rect
  , viArtifacts :: Map ArtifactId Rect
  , viPorts     :: PortMap
  , viSpine     :: [NodeId]
  , viAxis      :: AxisMap
  , viBackFlows :: Set FlowId
  , viFont      :: FontMetrics
  }

validateGeometry :: ValidationInput -> [Violation]
validateGeometry vi = orderViolations (hardConstraints vi ++ positionalConstraints vi)

-- Hard constraints (T0) ------------------------------------------------------

hardConstraints :: ValidationInput -> [Violation]
hardConstraints vi =
  concat
    [ hc001, hc002, hc003, hc004, hc005, hc006, hc007
    , hc009, hc010, hc011, hc012, hc013, hc014
    ]
  where
    sc = viScope vi
    shapes = viShapes vi
    routes = viRoutes vi
    byId = scopeNodeMap sc

    v rule msg el hint = Violation (RuleId rule) T0 msg hint (Just el)

    -- HC-001 — every segment is axis-parallel.
    hc001 =
      [ v "HC-001" "connector segment is not axis-parallel" (RefFlow fid) (Just "re-route (phase 8)")
      | (fid, r) <- Map.toAscList routes
      , any (not . segIsOrthogonal) (routeSegments (rtPoints r))
      ]

    -- HC-002 — no two node boxes overlap; clearance >= 2U in at least one axis.
    -- A boundary event overlapping its host is the sole exception (HC-006), and
    -- a container overlapping its children is containment, not collision.
    hc002 =
      [ v "HC-002" ("node boxes overlap: " <> unNodeId a <> " and " <> unNodeId b) (RefNode a) (Just "push apart along the axis of smaller displacement")
      | (a, ra) : rest <- tails (Map.toAscList shapes)
      , (b, rb) <- rest
      , not (isBoundaryOf a b || isBoundaryOf b a)
      , not (rectContains ra rb || rectContains rb ra)
      , if siblingBoundaries a b
          then rectsOverlap ra rb
          else gapX ra rb < 2 * u && gapY ra rb < 2 * u
      ]
      where
        gapX ra rb = max (rX ra - rectRight rb) (rX rb - rectRight ra)
        gapY ra rb = max (rY ra - rectBottom rb) (rY rb - rectBottom ra)
        isBoundaryOf x y = case Map.lookup x byId >>= boundaryHost of
          Just att -> baHost att == y
          Nothing -> False
        -- Two boundary events on one host are spaced by BE_GAP (1U) and
        -- distributed by LAYOUT-016's formula, so the 2U clearance of HC-002
        -- does not apply between them; what is prohibited is overlap.
        siblingBoundaries x y = case (hostOfNode x, hostOfNode y) of
          (Just hx, Just hy) -> hx == hy
          _ -> False
        hostOfNode x = baHost <$> (Map.lookup x byId >>= boundaryHost)

    -- HC-003 — every node lies inside its lane, inset by the container padding.
    hc003 =
      [ v "HC-003" ("node escapes its lane: " <> unNodeId (fnId n)) (RefNode (fnId n)) (Just "grow the lane, else move the node")
      | n <- scNodes sc
      , Just l <- [fnLane n]
      , Just laneR <- [Map.lookup l (viLanes vi)]
      , Just r <- [Map.lookup (fnId n) shapes]
      , not (rectContains (shrinkY containerPadY laneR) r)
      ]
      where
        shrinkY d r = Rect (rX r) (rY r + d) (rW r) (max 0 (rH r - 2 * d))

    -- HC-004 — no edge segment passes within EDGE_CLEAR of a node it is not
    -- incident to. Two nodes get a reduced clearance rather than a blanket
    -- exemption, because both are legitimate /overlaps/ in BPMN and neither is
    -- a licence to draw through the shape:
    --
    --   * a node's container, which every route inside it necessarily crosses;
    --   * the host of a boundary event the flow is incident to. The stub starts
    --     on the host's border and so is inside EDGE_CLEAR of it before it has
    --     moved at all (EDGE-014), and running close under the host on the way
    --     to the handler band is the canonical picture. Entering the box is
    --     not: exempting the host outright is what let a @goto@ from a boundary
    --     event draw a line straight across the task it hangs from.
    hc004 =
      [ v "HC-004" ("connector passes through " <> unNodeId n) (RefFlow fid) (Just "re-route, or insert a corridor by increasing band spacing")
      | (fid, r) <- Map.toAscList routes
      , Just fl <- [Map.lookup fid flowById]
      , let rb = inflate edgeClear (routeBox r)
      , (n, rect) <- Map.toAscList shapes
      , rectsOverlap rb rect
      , not (incidentTo fl n)
      , not (containerOf n)
      , let clearance = if hostOfEndpoint fl n then 0 else edgeClear
      , any (\s -> segIntersectsRect s (inflate clearance rect)) (routeSegments (rtPoints r))
      ]
      where
        flowById = scopeFlowMap sc
        incidentTo fl n = sfSource fl == n || sfTarget fl == n
        hostOfEndpoint fl n = hostOf (sfSource fl) == Just n || hostOf (sfTarget fl) == Just n
        hostOf x = baHost <$> (Map.lookup x byId >>= boundaryHost)
        containerOf n = case Map.lookup n byId of
          Just fn -> case fnKind fn of
            NkActivity (Activity (AkSubprocess _ _) _) -> True
            _ -> False
          Nothing -> False

    -- HC-005 — endpoints on declared ports, with a perpendicular stub of at
    -- least MIN_SEG (relaxed to 1U for a boundary-event stub).
    hc005 =
      concat
        [ endpointChecks fid r fl
        | (fid, r) <- Map.toAscList routes
        , Just fl <- [Map.lookup fid (scopeFlowMap sc)]
        ]
      where
        endpointChecks fid r fl = case rtPoints r of
          (p0 : _) ->
            let ps = rtPoints r
                pn = last ps
                srcR = Map.findWithDefault emptyRect (sfSource fl) shapes
                tgtR = Map.findWithDefault emptyRect (sfTarget fl) shapes
                expectedSrc = portPoint srcR (sourcePort (viPorts vi) fid)
                expectedTgt = portPoint tgtR (targetPort (viPorts vi) fid)
                minStub = if isBoundary (sfSource fl) then u else minSeg
                segs = routeSegments ps
                firstLen = case segs of
                  (s : _) -> segLength s
                  [] -> 0
                lastLen = case reverse segs of
                  (s : _) -> segLength s
                  [] -> 0
             in [ v "HC-005" "connector does not start on its source port" (RefFlow fid) (Just "re-anchor")
                | p0 /= expectedSrc
                ]
                  ++ [ v "HC-005" "connector does not end on its target port" (RefFlow fid) (Just "re-anchor")
                     | pn /= expectedTgt
                     ]
                  ++ [ v "HC-005" "connector stub is shorter than the minimum segment" (RefFlow fid) (Just "extend the stub and move the first bend outward")
                     | firstLen > 0 && firstLen < minStub
                     ]
                  ++ [ v "HC-005" "connector approach is shorter than the minimum segment" (RefFlow fid) (Just "extend the stub")
                     | lastLen > 0 && lastLen < minStub
                     ]
          [] -> [v "HC-005" "connector has no waypoints" (RefFlow fid) Nothing]
        isBoundary n = maybe False nodeIsBoundary (Map.lookup n byId)

    -- HC-006 — a boundary event's centre lies exactly on its host's border.
    hc006 =
      [ v "HC-006" ("boundary event is detached from its host: " <> unNodeId (fnId n)) (RefNode (fnId n)) (Just "re-attach per LAYOUT-016")
      | n <- scNodes sc
      , Just att <- [boundaryHost n]
      , Just r <- [Map.lookup (fnId n) shapes]
      , Just hr <- [Map.lookup (baHost att) shapes]
      , not (onBorder hr r)
      ]
      where
        onBorder hr r =
          let cx = rectCenterX r
              cy = rectCenterY r
              onH = cx >= rX hr && cx <= rectRight hr
              onV = cy >= rY hr && cy <= rectBottom hr
           in (onH && (cy == rY hr || cy == rectBottom hr)) || (onV && (cx == rX hr || cx == rectRight hr))

    -- HC-007 — lanes tile their pool exactly.
    hc007 =
      [ v "HC-007" "lanes do not tile their pool" (RefLane l) (Just "recompute lane geometry (LANE-003)")
      | (l, r) <- Map.toAscList (viLanes vi)
      , rW r /= laneW || rX r /= laneX
      ]
        ++ [ v "HC-007" "lanes leave a gap or overlap" (RefLane (fst b)) (Just "recompute lane geometry")
           | (a, b) <- zip sorted (drop 1 sorted)
           , rectBottom (snd a) /= rY (snd b)
           ]
      where
        -- Ordered by position, not by id: HC-007 is about geometric tiling,
        -- and lane ids sort lexicographically, which has nothing to do with
        -- which lane is above which.
        sorted = sortOn (rY . snd) (Map.toAscList (viLanes vi))
        laneW = case sorted of
          ((_, r) : _) -> rW r
          [] -> 0
        laneX = case sorted of
          ((_, r) : _) -> rX r
          [] -> 0

    -- HC-009 — no collinear overlap of two edges outside a bundle. Bundling is
    -- legal only when both edges share a port and the overlap is contiguous
    -- with it; everything else makes multiplicity invisible.
    hc009 =
      [ v "HC-009" ("connectors overlap collinearly: " <> unFlowId a <> " and " <> unFlowId b) (RefFlow a) (Just "offset one edge to the next free corridor")
      | (a, ra) : rest <- tails (Map.toAscList routes)
      , (b, rb) <- rest
      , rectsOverlap (inflate 1 (routeBox ra)) (inflate 1 (routeBox rb))
      , not (sharePort a b)
      , any (> 0) [collinearOverlap s1 s2 | s1 <- routeSegments (rtPoints ra), s2 <- routeSegments (rtPoints rb)]
      ]
      where
        flowById = scopeFlowMap sc
        sharePort a b = case (Map.lookup a flowById, Map.lookup b flowById) of
          (Just fa, Just fb) ->
            (sfSource fa == sfSource fb && sourcePort (viPorts vi) a == sourcePort (viPorts vi) b)
              || (sfTarget fa == sfTarget fb && targetPort (viPorts vi) a == targetPort (viPorts vi) b)
          _ -> False

    -- HC-010 — no duplicate consecutive or collinear intermediate waypoints.
    hc010 =
      [ v "HC-010" "connector has a degenerate waypoint" (RefFlow fid) (Just "simplify the waypoint list")
      | (fid, r) <- Map.toAscList routes
      , degenerate (rtPoints r)
      ]
      where
        degenerate ps =
          or (zipWith (==) ps (drop 1 ps))
            || or
              [ (ptX a == ptX b && ptX b == ptX c) || (ptY a == ptY b && ptY b == ptY c)
              | (a, b, c) <- zip3 ps (drop 1 ps) (drop 2 ps)
              ]

    -- HC-011 — non-negative integers, shape centres on the U grid.
    hc011 =
      [ v "HC-011" ("node coordinate is negative: " <> unNodeId n) (RefNode n) (Just "translate the diagram")
      | (n, r) <- Map.toAscList shapes
      , rX r < 0 || rY r < 0
      ]
        ++ [ v "HC-011" ("node centre is off the grid: " <> unNodeId n) (RefNode n) (Just "snap to the U grid")
           | (n, r) <- Map.toAscList shapes
           , rectCenterX r `mod` grid /= 0 || rectCenterY r `mod` grid /= 0
           ]
        ++ [ v "HC-011" "waypoint coordinate is negative" (RefFlow fid) (Just "translate the diagram")
           | (fid, r) <- Map.toAscList routes
           , any (\p -> ptX p < 0 || ptY p < 0) (rtPoints r)
           ]

    -- HC-012 — an activity's text never overflows its shape.
    hc012 =
      [ v "HC-012" ("label overflows its activity: " <> unNodeId (fnId n)) (RefNode (fnId n)) (Just "apply the LAYOUT-029 growth ladder")
      | n <- scNodes sc
      , nodeIsActivity n
      , Just r <- [Map.lookup (fnId n) shapes]
      , Just t <- [fnName n]
      , let box = internalLabel (viFont vi) r (nodeHasMarker n) t
      , tbWidth box > rW r - 2 * labelPad || tbHeight box > rH r - 2 * labelPad
      ]

    -- HC-013 — no node overlaps a lane divider or a pool border.
    hc013 =
      [ v "HC-013" ("node crosses a lane divider: " <> unNodeId (fnId n)) (RefNode (fnId n)) (Just "move the node into the lane interior")
      | n <- scNodes sc
      , Just r <- [Map.lookup (fnId n) shapes]
      , (l, laneR) <- Map.toAscList (viLanes vi)
      , Just l /= fnLane n
      , rectsOverlap r laneR
      ]

    -- HC-014 — an expanded subprocess contains its children plus padding.
    hc014 =
      [ v "HC-014" ("subprocess does not contain its children: " <> unNodeId (fnId n)) (RefNode (fnId n)) (Just "resize outward, bottom-up")
      | n <- scNodes sc
      , NkActivity (Activity (AkSubprocess _ inner) _) <- [fnKind n]
      , Just r <- [Map.lookup (fnId n) shapes]
      , child <- scNodes inner
      , Just cr <- [Map.lookup (fnId child) shapes]
      , not (rectContains r cr)
      ]

-- Positional semantics (T1) --------------------------------------------------

positionalConstraints :: ValidationInput -> [Violation]
positionalConstraints vi = layout001 ++ edge021 ++ layout007 ++ edge007 ++ label011 ++ layout035 ++ art005
  where
    sc = viScope vi
    shapes = viShapes vi
    routes = viRoutes vi
    byId = scopeNodeMap sc
    flowById = scopeFlowMap sc

    v1 rule msg el hint = Violation (RuleId rule) T1 msg hint (Just el)
    v2 rule msg el hint = Violation (RuleId rule) T2 msg hint (Just el)

    isBack f = Set.member f (viBackFlows vi)

    -- LAYOUT-001 — every forward flow makes non-decreasing x progress.
    layout001 =
      [ v1 "LAYOUT-001" ("forward flow runs backwards: " <> unFlowId fid) (RefFlow fid) (Just "re-run layering with this edge's constraint added")
      | (fid, fl) <- Map.toAscList flowById
      , not (isBack fid)
      , sfSource fl /= sfTarget fl
      , Just sr <- [Map.lookup (sfSource fl) shapes]
      , Just tr <- [Map.lookup (sfTarget fl) shapes]
      , rX tr < rectRight sr
      , not (isBoundarySrc fl)
      ]
      where
        isBoundarySrc fl = maybe False nodeIsBoundary (Map.lookup (sfSource fl) byId)

    -- LAYOUT-035 — an event subprocess sits below the flow, never inside it.
    -- Nothing connects one, so the layering pass treats it as a disconnected
    -- component and would otherwise leave it wherever the ordering reached it.
    --
    -- "The flow" is the handler's own lane's flow. A handler in the first of
    -- two lanes is above the second lane's content and has to be: it belongs
    -- to the first lane, and HC-003 keeps it there.
    layout035 =
      [ v2 "LAYOUT-035" ("event subprocess overlaps the flow: " <> unNodeId (fnId n)) (RefNode (fnId n)) (Just "stack it below its lane's content")
      | n <- scNodes sc
      , isEventSubprocess n
      , Just r <- [Map.lookup (fnId n) shapes]
      , Just box <- [flowBox (fnLane n)]
      , rY r < rectBottom box
      ]
      where
        handlers = Set.fromList [fnId n | n <- scNodes sc, isEventSubprocess n]
        contained = Set.fromList [fnId c | n <- scNodes sc, isEventSubprocess n, Just inner <- [subprocessScope n], c <- scNodes inner]
        flowBox l = case rects of
          [] -> Nothing
          rs -> Just (unionRects rs)
          where
            rects =
              [ r
              | n <- scNodes sc
              , fnLane n == l
              , not (Set.member (fnId n) handlers)
              , not (Set.member (fnId n) contained)
              , Just r <- [Map.lookup (fnId n) shapes]
              ]

    -- ART-005 — a group encloses its members and nothing else. Advisory: a
    -- group is an annotation, and moving a node to satisfy one would distort
    -- the diagram for no semantic gain.
    art005 =
      [ v2 "ART-005" ("group encloses a step that is not a member: " <> unArtifactId aid) (RefArtifact aid) (Just "advisory only; the members are not contiguous")
      | a <- scArtifacts sc
      , artKind a == AkGroup
      , let aid = artId a
      , Just box <- [Map.lookup aid (viArtifacts vi)]
      , let members = Set.fromList (artMembers a)
      , (i, r) <- Map.toAscList shapes
      , not (Set.member i members)
      , rectContains box r
      ]

    -- EDGE-021 — a forward edge's route never moves backwards.
    edge021 =
      [ v1 "EDGE-021" ("forward connector contains a backward segment: " <> unFlowId fid) (RefFlow fid) (Just "re-layer; a backward segment always indicates a layering fault")
      | (fid, r) <- Map.toAscList routes
      , not (isBack fid)
      , rtClass r /= EcSelfLoop
      , any (\(Segment a b) -> ptX b < ptX a - minSeg) (routeSegments (rtPoints r))
      ]

    -- LAYOUT-007 — the spine is straight: one centre y within a lane segment,
    -- and no bends on a spine-to-spine flow.
    layout007 =
      [ Violation (RuleId "LAYOUT-007") T2 ("spine node is off the spine axis: " <> unNodeId n) (Just "set cy to the spine y and re-stack the surrounding bands") (Just (RefNode n))
      | (n, cy) <- spineCentres
      , Just expected <- [Map.lookup (laneOf n) spineYByLane]
      , cy /= expected
      ]
        ++ [ Violation (RuleId "LAYOUT-007") T2 ("spine connector is bent: " <> unFlowId fid) (Just "reroute or move the non-spine endpoint; never bend the spine") (Just (RefFlow fid))
           | (fid, r) <- Map.toAscList routes
           , Just fl <- [Map.lookup fid flowById]
           , Set.member (sfSource fl) spineSet
           , Set.member (sfTarget fl) spineSet
           , laneOf (sfSource fl) == laneOf (sfTarget fl)
           , not (isBack fid)
           , routeBends r > 0
           ]
      where
        spineSet = Set.fromList (viSpine vi)
        -- LAYOUT-020: the spine of a scope containing an expanded subprocess
        -- runs through the container's internal spine, not through its box
        -- centre. Measuring centres here would report every such diagram as
        -- having a crooked spine — the one arrangement LAYOUT-020 exists to
        -- produce.
        spineCentres = [(n, axisYOf (viAxis vi) n r) | n <- viSpine vi, Just r <- [Map.lookup n shapes]]
        laneOf n = Map.lookup n byId >>= fnLane
        spineYByLane =
          Map.fromListWith (\_ old -> old) [(laneOf n, cy) | (n, cy) <- spineCentres]

    -- LABEL-011 — a label is geometry, so text that lands on a shape, on
    -- another label or on a connector is a layout fault and not a cosmetic
    -- one. LABEL-006 says the remedy is always more room and never an
    -- overlap, so reaching the end of the anchor ladder with nowhere free is
    -- the compiler failing to make room, which is worth an error rather than
    -- a score point a collaboration diagram would not even print.
    --
    -- The exemptions are exactly the ones placement works to: a label may
    -- overlap the element it names, and a flow label may overlap its own
    -- endpoints and its own connector (EDGE-018 — it is drawn offset from the
    -- segment it annotates).
    label011 =
      [ Violation (RuleId "LABEL-011") T1 ("label overlaps " <> what <> ": " <> describe k) (Just "move the label to a free anchor, or open the band or column it needs") (Just (refOf k))
      | (k, lb) <- Map.toAscList (viLabels vi)
      , let r = lbRect lb
      , what <- take 1 (obstructions k r)
      ]
      where
        refOf k = case k of
          LkNode n -> RefNode n
          LkFlow f -> RefFlow f
          LkArtifact a -> RefArtifact a
        describe k = case k of
          LkNode n -> unNodeId n
          LkFlow f -> unFlowId f
          LkArtifact a -> unArtifactId a

        owners k = case k of
          LkNode n -> [n]
          LkArtifact _ -> []
          LkFlow f -> case Map.lookup f flowById of
            Just fl -> [sfSource fl, sfTarget fl]
            Nothing -> []
        -- EDGE-018 exempts a flow label from its own connector only along the
        -- segment it annotates. The other segments of that edge are obstacles.
        exemptSegments k route = case k of
          LkFlow _ -> maybe [] pure (labelledSegment route)
          _ -> []

        obstructions k r =
          [ "node " <> unNodeId n
          | (n, rect) <- Map.toAscList shapes
          , n `notElem` owners k
          , rectsOverlap r rect
          ]
            ++ [ "label of " <> describe k2
               | (k2, lb2) <- Map.toAscList (viLabels vi)
               , k2 /= k
               , rectsOverlap r (lbRect lb2)
               ]
            ++ [ "connector " <> unFlowId fid
               | (fid, route) <- Map.toAscList routes
               , let exempt = if LkFlow fid == k then exemptSegments k route else []
               , any (\sg -> sg `notElem` exempt && segIntersectsRect sg r) (routeSegments (rtPoints route))
               ]

    -- EDGE-007 — the bend budget is a constraint, not a preference.
    edge007 =
      [ v2 "EDGE-007" ("connector exceeds its bend budget: " <> unFlowId fid <> " has " <> tshow (routeBends r) <> " bends, budget " <> tshow (rtBudget r)) (RefFlow fid) (Just "re-route; if the budget is still exceeded, the band assignment upstream is wrong")
      | (fid, r) <- Map.toAscList routes
      , routeBends r > rtBudget r
      ]
        ++ [ Violation (RuleId "EDGE-007") T1 ("connector exceeds the absolute bend limit of 6: " <> unFlowId fid) (Just "re-run band assignment for the enclosing region") (Just (RefFlow fid))
           | (fid, r) <- Map.toAscList routes
           , routeBends r > 6
           ]

tshow :: Show a => a -> Text
tshow = T.pack . show
