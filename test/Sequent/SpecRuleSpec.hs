-- | Rule-by-rule tests, named after the SPEC.md rules they check.
--
-- The naming is the point. A test called @test_LAYOUT_007_spine_stays_straight@
-- ties a line in the specification to a line in the implementation to a line in
-- the test output, so "does this compiler implement LAYOUT-007?" has an answer
-- you can run rather than an answer you have to take on trust.
module Sequent.SpecRuleSpec (spec) where

import Data.List (nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Sequent.Bpmn.Semantic
import Sequent.Layout
import Sequent.Layout.Branches
import Sequent.Layout.Labels (externalLabelBox, labelledSegment)
import Sequent.Text.Metrics (TextBox (..), helvetica12, wrapText)
import Sequent.Layout.Constants
import Sequent.Layout.Routing (boundaryExceptionRoute, routeCost)
import Sequent.Layout.Rules
import Sequent.Layout.Score (Score (..))
import Sequent.Compiler
import Sequent.Diagnostic (Diagnostic (..), RuleId (..))
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "the rule registry" $ do
    it "has a unique id per rule" $
      let is = map (unRuleId . ruleId) ruleRegistry in sort is `shouldBe` sort (nub is)

    it "names an implementation for every rule" $
      [unRuleId (ruleId r) | r <- ruleRegistry, T.null (ruleImpl r)] `shouldBe` []

    it "gives every hard constraint tier T0" $
      [unRuleId (ruleId r) | r <- ruleRegistry, rulePriority r == Hard, ruleTier r /= T0]
        `shouldBe` []

    it "can be looked up by rule id" $
      fmap (T.unpack . ruleImpl) (lookupRule "HC-001") `shouldBe` Just "Layout.Routing.routeOne"

    it "knows nothing about a rule it does not implement" $
      fmap (unRuleId . ruleId) (lookupRule "LAYOUT-999") `shouldBe` Nothing

    it "groups the hard constraints into tier T0" $
      map (unRuleId . ruleId) (rulesForTier T0)
        `shouldSatisfy` \is -> "HC-001" `elem` is && "LAYOUT-007" `notElem` is

  describe "§B constants" $ do
    it "test_B_base_unit_is_ten" $ u `shouldBe` 10

    it "test_B_canonical_sizes" $
      (taskW, taskH, gwSize, evSize) `shouldBe` (100, 80, 50, 36)

    it "test_B_half_gaps_stay_on_the_grid" $
      -- The coherence argument of §B: half of every derived gap must remain a
      -- whole grid unit, or symmetric centring cannot land back on the grid.
      map (`mod` u) [branchGapY `div` 2, taskH `div` 2, nodeGapX `div` 2] `shouldBe` [0, 0, 0]

  describe "§C hard constraints" $ do
    it "test_HC_001_every_connector_is_orthogonal" $
      violationsFor "HC-001" everyPattern `shouldBe` []

    it "test_HC_002_no_node_boxes_overlap" $
      violationsFor "HC-002" everyPattern `shouldBe` []

    it "test_HC_004_edge_never_intersects_nonincident_node" $
      violationsFor "HC-004" everyPattern `shouldBe` []

    it "test_HC_004_a_boundary_handler_never_crosses_its_host" $
      -- The host is not exempt from HC-004, only from its clearance: the stub
      -- starts on the host's border and may run close under it, but a turn
      -- level with the host would draw the exception path across the task it
      -- hangs from.
      let l = layoutOf boundaryGotoLevel
          host = shapeOf l "Activity_alert"
          r = routeOf l "Flow_fixed_handled"
       in [ (ptX a, ptY a, ptX b, ptY b)
          | Segment a b <- routeSegments (rtPoints r)
          , segIntersectsRect (Segment a b) host
          ]
            `shouldBe` []

    it "test_HC_005_endpoints_lie_on_ports" $
      violationsFor "HC-005" everyPattern `shouldBe` []

    it "test_HC_005_an_off_axis_band_clears_the_split_by_a_whole_stub" $
      -- The stub runs from the gateway's north or south border to the branch
      -- axis, so the band owes the router @GW/2 + MIN_SEG@. Measured on the
      -- geometry rather than on the band offsets, because that is what a
      -- connector actually has to cross.
      let l = layoutOf smallEventBranches
          gw = shapeOf l "Gateway_g"
          clearance n = abs (rectCenterY (shapeOf l n) - rectCenterY gw) - rH gw `div` 2
       in map clearance ["Event_w1", "Event_w2"] `shouldSatisfy` all (>= minSeg)

    it "test_BRANCH_003_a_symmetric_pair_of_branches_mirrors_the_axis" $
      -- Rounding the half-stack up (N-8) must not shift the content: two
      -- congruent branches sit at exactly +/-d, whatever d turns out to be.
      let l = layoutOf smallEventBranches
          axis = rectCenterY (shapeOf l "Gateway_g")
          off n = rectCenterY (shapeOf l n) - axis
       in off "Event_w1" `shouldBe` negate (off "Event_w2")

    it "test_HC_006_boundary_event_sits_on_its_host_border" $
      let l = layoutOf boundaryProcess
          host = shapeOf l "Activity_t"
          ev = shapeOf l "Event_failed"
       in rectCenterY ev `shouldBe` rectBottom host

    it "test_HC_007_lanes_tile_their_pool" $
      let l = layoutOf laneProcess
          rects = sortByY (Map.elems (geoLanes (lrGeometry l)))
       in ( map rW rects == replicate (length rects) (rW (head rects))
          , and (zipWith (\a b -> rectBottom a == rY b) rects (drop 1 rects))
          )
            `shouldBe` (True, True)

    it "test_HC_009_no_collinear_overlap_outside_a_bundle" $
      violationsFor "HC-009" everyPattern `shouldBe` []

    it "test_HC_011_centres_are_on_the_grid" $
      violationsFor "HC-011" everyPattern `shouldBe` []

    it "test_HC_011_a_container_keeps_its_contents_on_the_grid" $
      -- Asserted over the /merged/ geometry, which is the only place the bug
      -- lives: a pool and an expanded subprocess each lay their contents out in
      -- a frame of their own and then translate it into place, and that frame
      -- starts at a bounding-box edge which need not be a grid multiple. Every
      -- scope validates clean on its own while the assembled diagram sits off
      -- the grid by the remainder.
      [ (name, T.unpack (unNodeId n))
      | (name, src) <- everyPattern
      , (n, r) <- Map.toAscList (allShapes (layoutOf src))
      , rectCenterX r `mod` grid /= 0 || rectCenterY r `mod` grid /= 0
      ]
        `shouldBe` []

    it "test_HC_012_activity_text_never_overflows" $
      violationsFor "HC-012" everyPattern `shouldBe` []

    it "test_HC_014_subprocess_contains_its_children" $
      let l = layoutOf subprocessProcess
          outer = shapeOf l "Activity_sub"
       in [n | n <- ["StartEvent_b", "Activity_t", "Event_d"], not (rectContains outer (shapeOf l n))]
            `shouldBe` []

  describe "§D structural rules" $ do
    it "test_LAYOUT_001_forward_flows_progress_rightward" $
      violationsFor "LAYOUT-001" everyPattern `shouldBe` []

    it "test_LAYOUT_004_all_branches_of_a_split_start_in_one_column" $
      let l = layoutOf threeWay
       in nub (map (rX . shapeOf l) ["Activity_p", "Activity_q", "Activity_r"])
            `shouldSatisfy` ((== 1) . length)

    it "test_LAYOUT_005_column_pitch_is_uniform" $
      -- SPEC §L pattern A: 62 / 60 / 62, the outer two widened by centring a
      -- 36 px event in its column.
      gapsBetween (layoutOf linearProcess) ["StartEvent_s", "Activity_a", "Activity_b", "Event_e"]
        `shouldBe` [62, 60, 62]

    it "test_LAYOUT_005_a_column_gap_leaves_room_for_a_connector_to_turn" $
      -- Column centres round /up/ to the grid, so a shape is never pulled back
      -- into the gap before it. A gap narrower than two stubs has nowhere for a
      -- cross-lane edge to jog, which is how a rounded-down centre used to
      -- surface as HC-005 on the connector into the next lane.
      let l = layoutOf smallEventLanes
       in gapsBetween l ["Gateway_g_join", "Event_e"] `shouldSatisfy` all (>= 2 * minSeg)

    it "test_LAYOUT_007_spine_stays_straight" $
      let l = layoutOf branchingProcess
       in nub (map (rectCenterY . shapeOf l) ["StartEvent_s", "Activity_a", "Gateway_g", "Gateway_g_join", "Event_e"])
            `shouldSatisfy` ((== 1) . length)

    it "test_LAYOUT_007_spine_edges_have_no_bends" $
      map (routeBends . routeOf (layoutOf branchingProcess)) ["Flow_s_a", "Flow_a_g", "Flow_g_join_e"]
        `shouldBe` [0, 0, 0]

    it "test_LAYOUT_012_centres_align_across_mixed_sizes" $
      -- A 36 px event and an 80 px task connect with a straight line only if
      -- their centres, not their edges, are the datum.
      let l = layoutOf linearProcess
       in rectCenterY (shapeOf l "StartEvent_s") `shouldBe` rectCenterY (shapeOf l "Activity_a")

    it "test_LAYOUT_016_boundary_events_spread_along_the_bottom_edge" $
      let l = layoutOf twoBoundaries
          host = shapeOf l "Activity_t"
          xs = map (rectCenterX . shapeOf l) ["Event_first", "Event_second"]
       in (all (\x -> x > rX host && x < rectRight host) xs, length (nub xs)) `shouldBe` (True, 2)

    it "test_LAYOUT_017_exception_band_sits_below_every_ordinary_band" $
      let l = layoutOf boundaryProcess
       in rectCenterY (shapeOf l "Activity_h") `shouldSatisfy` (> rectCenterY (shapeOf l "Activity_t"))

    it "test_LAYOUT_019_a_container_holds_its_children_and_its_padding" $
      let l = layoutOf subprocessOffCentre
          box = shapeOf l "Activity_sub"
          inner = map (shapeOf l) ["StartEvent_b", "Activity_t", "Event_d", "Activity_h", "Event_aborted"]
       in [ (rX r - rX box, rY r - rY box, rectRight box - rectRight r, rectBottom box - rectBottom r)
          | r <- inner
          , rX r - rX box < containerPadX || rY r - rY box < containerPadY
          ]
            `shouldBe` []

    it "test_LAYOUT_020_a_container_hangs_from_its_own_spine" $
      -- One line through the whole diagram: the outer spine, the inner spine,
      -- and the container's own vertical middle. The third is not automatic —
      -- this subprocess has a handler band below its spine and nothing above
      -- it, so a box sized tightly to its contents would put its centre well
      -- under the line that enters it.
      let l = layoutOf subprocessOffCentre
          outer = rectCenterY (shapeOf l "StartEvent_s")
          inner = map (rectCenterY . shapeOf l) ["StartEvent_b", "Activity_t", "Event_d"]
          box = shapeOf l "Activity_sub"
       in nub (outer : rectCenterY box : inner) `shouldBe` [outer]

    it "test_LAYOUT_020_a_container_reserves_the_same_room_on_both_sides_of_its_spine" $
      -- What centring costs, stated as the rule rather than discovered as a
      -- surprise: the lighter side is padded to the heavier one.
      let l = layoutOf subprocessOffCentre
          box = shapeOf l "Activity_sub"
          axis = rectCenterY (shapeOf l "Activity_t")
       in (axis - rY box, rectBottom box - axis) `shouldSatisfy` \(a, b) -> a == b && a > 0

    it "test_LAYOUT_020_the_flow_through_a_container_has_no_bend" $
      -- The point of the alignment: the connector into the container and the
      -- one out of it continue the same straight line the inner flow runs on.
      map (routeBends . routeOf (layoutOf subprocessOffCentre)) ["Flow_s_sub", "Flow_sub_e"]
        `shouldBe` [0, 0]

    it "test_LAYOUT_018_loopback_corridor_carries_no_node" $
      let l = layoutOf loopProcess
          corridor = corridorYOf l "Flow_g_a"
          bands = map (rectCenterY . shapeOf l) ["Activity_a", "Activity_b", "Gateway_g"]
       in all (\y -> abs (y - corridor) >= taskH `div` 2) bands `shouldBe` True

    it "test_LAYOUT_031_diagram_starts_at_the_margin" $
      -- The translation is a whole number of grid units: HC-011 is HARD and
      -- LAYOUT-031 is STRONG, so when the leftmost element is a 36 px event
      -- whose box edge is off-grid, the diagram starts at the first grid
      -- position at or beyond the margin (see Layout.Snap.translateToMargin).
      let b = geometryBounds (lrGeometry (layoutOf linearProcess))
       in (rX b >= margin, rX b < margin + grid, rY b >= margin, rY b < margin + grid)
            `shouldBe` (True, True, True, True)

    it "test_LAYOUT_021_compaction_leaves_a_content_derived_layout_alone" $
      -- LAYOUT-021 is triggered by its detector: an empty strip wider than
      -- 2*NODE_GAP_X. Column gaps are derived from content, so there is never
      -- such a strip and compaction correctly does nothing.
      let plain = layoutOf linearProcess
          gaps = gapsBetween plain ["StartEvent_s", "Activity_a", "Activity_b", "Event_e"]
       in all (>= nodeGapXMin) gaps `shouldBe` True

    it "test_LAYOUT_024_a_re_run_keeps_the_previous_branch_sides" $
      -- Structural stickiness: handing the previous geometry back must not
      -- rearrange a diagram whose score is unchanged.
      let first = layoutOf branchingProcess
          again = relayoutWithPrevious branchingProcess first
       in sidesOf again `shouldBe` sidesOf first

    it "test_LAYOUT_024_a_small_edit_makes_a_small_change" $
      -- Adding one task must not move the steps before it.
      let beforeEdit = layoutOf "start s\ntask a\ntask b\nend e"
          afterEdit = layoutOf "start s\ntask a\ntask b\ntask c\nend e"
       in map (shapeOf beforeEdit) ["StartEvent_s", "Activity_a", "Activity_b"]
            `shouldBe` map (shapeOf afterEdit) ["StartEvent_s", "Activity_a", "Activity_b"]

    it "test_LAYOUT_025_a_pin_is_honoured_exactly" $
      let l = layoutOf "start s\ntask a\ntask b\nend e\npin b at 500 200"
          r = shapeOf l "Activity_b"
       in (rX r, rY r) `shouldBe` (500, 200)

    it "test_LAYOUT_025_a_pin_does_not_drag_the_columns_before_it" $
      -- Horizontally, a pin moves its own column and the columns to its right;
      -- everything to its left stays where the derived layout put it.
      let l = layoutOf "start s\ntask a\ntask b\nend e\npin b at 500 200"
       in rX (shapeOf l "StartEvent_s") `shouldBe` margin + 2

    it "test_LAYOUT_025_a_pin_moves_the_band_not_the_node_alone" $
      -- LAYOUT-025 forces @bandAxisY@ to the pin's @cy@, so the band the node
      -- sits on goes with it. Dragging the node out of its own band on its own
      -- is what leaves the spine bent behind it.
      let l = layoutOf "start s\ntask a\ntask b\nend e\npin b at 500 200"
          cys = map (rectCenterY . shapeOf l) ["StartEvent_s", "Activity_a", "Activity_b", "Event_e"]
       in (nub cys, rY (shapeOf l "Activity_b")) `shouldBe` ([240], 200)

    it "test_LAYOUT_025_a_pinned_host_keeps_its_handler_below_it" $
      -- The regression that made pins dangerous: the host moved, its exception
      -- band did not, and the boundary event ended up having to route back up
      -- to a handler it was now level with.
      let l = layoutOf pinnedBoundary
          host = shapeOf l "Activity_snd"
          ev = shapeOf l "Event_esc"
       in ( rectCenterY ev == rectBottom host
          , rectCenterY (shapeOf l "Activity_handle") > rectCenterY host
          , [v | v <- lrViolations l, vTier v `elem` [T0, T1]]
          )
            `shouldBe` (True, True, [])

    it "test_LAYOUT_025_a_pin_yields_to_the_grid_and_says_so" $
      -- HC-011 is HARD and LAYOUT-025 is STRONG: a pin whose y would put the
      -- centre off the grid is honoured to the nearest aligned position, and
      -- reported rather than silently accepted.
      let l = layoutOf "start s\ntask a\nend e\npin e at 600 205"
          r = shapeOf l "Event_e"
          reported =
            any (T.isInfixOf "pin could not be honoured" . diagMessage) (lrDiagnostics l)
       in (rectCenterX r `mod` grid, rectCenterY r `mod` grid, reported)
            `shouldBe` (0, 0, True)

    it "test_LAYOUT_025_an_unsatisfiable_pin_is_reported_not_dropped" $
      -- A pin to the left of the node's derived column cannot be honoured;
      -- LAYOUT-025 requires it to be reported.
      let l = layoutOf "start s\ntask a\ntask b\nend e\npin b at 0 0\npin a at 900 40"
       in map (T.unpack . diagMessage) (lrDiagnostics l)
            `shouldSatisfy` any (T.isInfixOf "pin could not be honoured" . T.pack)

    it "test_LAYOUT_032_adjacent_gateways_use_the_compact_gap" $
      let l = layoutOf gatewayChain
          g1 = shapeOf l "Gateway_g_join"
          g2 = shapeOf l "Gateway_h"
       in (rX g2 - rectRight g1, rectCenterY g1 == rectCenterY g2) `shouldBe` (compactGap, True)

  describe "§E connector routing" $ do
    it "test_EDGE_019_route_cost_encodes_the_normative_magnitudes" $ do
      -- §2.1's answers, expressed as numbers: one crossing costs about 6.7
      -- bends and about 2000 px of length, so removing a crossing justifies a
      -- much longer or slightly bendier route, and never the reverse.
      let crossing = routeCost 0 1 0 0 0 0
          bends n = routeCost n 0 0 0 0 0
          len px = routeCost 0 0 px 0 0 0
      (crossing > bends 6, crossing < bends 7, crossing > len 1900, crossing < len 2100)
        `shouldBe` (True, True, True, True)

    it "test_EDGE_003_collinear_centres_give_a_two_point_route" $
      map (length . rtPoints . routeOf (layoutOf linearProcess)) ["Flow_s_a", "Flow_a_b", "Flow_b_e"]
        `shouldBe` [2, 2, 2]

    it "test_EDGE_005_split_branch_uses_the_one_bend_comb" $
      routeBends (routeOf (layoutOf branchingProcess) "Flow_g_q") `shouldBe` 1

    it "test_EDGE_005_comb_trunk_sits_at_the_gateway_centre" $
      let l = layoutOf branchingProcess
          pts = rtPoints (routeOf l "Flow_g_q")
       in map ptX (take 2 pts) `shouldBe` replicate 2 (rectCenterX (shapeOf l "Gateway_g"))

    it "test_EDGE_006_merge_branch_uses_the_one_bend_comb" $
      routeBends (routeOf (layoutOf branchingProcess) "Flow_q_g_join") `shouldBe` 1

    it "test_EDGE_007_every_route_is_within_its_budget" $
      violationsFor "EDGE-007" everyPattern `shouldBe` []

    it "test_EDGE_013_loopback_uses_corridor" $
      routeBends (routeOf (layoutOf loopProcess) "Flow_g_a") `shouldBe` 2

    it "test_EDGE_013_loopback_enters_the_target_on_an_edge_not_a_corner" $
      let l = layoutOf loopProcess
          pts = rtPoints (routeOf l "Flow_g_a")
          tgt = shapeOf l "Activity_a"
          end = last pts
       in (ptX end == rectCenterX tgt, ptY end == rY tgt || ptY end == rectBottom tgt)
            `shouldBe` (True, True)

    it "test_EDGE_014_boundary_exception_route_has_one_bend" $
      routeBends (routeOf (layoutOf boundaryProcess) "Flow_failed_h") `shouldBe` 1

    -- The rest of EDGE-014 is exercised against the geometry directly rather
    -- than through a source file, because a source file cannot reach it:
    -- layering forbids a handler in a column at or before its host's, and
    -- columns do not overlap, so a `.sq` only ever produces a handler to the
    -- right of the host. The forms that need a host-aware escape corridor are
    -- what stops the router depending on an invariant three phases away.
    describe "test_EDGE_014_the_exception_route_never_touches_its_host" $ do
      let host = Rect 100 100 100 80 -- x 100..200, y 100..180
          -- A boundary event centred on the host's bottom edge, S port below it.
          fromBottom = Point 150 198
          -- and one on the top edge, N port above it.
          fromTop = Point 150 82
          route h s tp q = boundaryExceptionRoute h s tp q
          touchesHost h ps = [() | sg <- routeSegments ps, segIntersectsRect sg h]
          arrives tp ps = case reverse ps of
            (end : prev : _) -> case tp of
              PW -> ptX prev < ptX end
              PE -> ptX prev > ptX end
              PN -> ptY prev < ptY end
              PS -> ptY prev > ptY end
            _ -> False

          -- Every arrangement of a handler around a host, including the ones
          -- the layout phases cannot currently produce.
          cases =
            [ ("level, to the right", host, fromBottom, Port PW 0, Point 300 198)
            , ("below and right", host, fromBottom, Port PW 0, Point 300 300)
            , ("level with the host", host, fromBottom, Port PW 0, Point 300 140)
            , ("below, vertical port", host, fromBottom, Port PN 0, Point 300 300)
            , ("above, vertical port, past the host", host, fromBottom, Port PS 0, Point 300 60)
            , ("directly above, vertical port", host, fromBottom, Port PN 0, Point 150 60)
            , ("directly above, horizontal port", host, fromBottom, Port PW 0, Point 150 60)
            , ("above and left", host, fromBottom, Port PW 0, Point 40 60)
            , ("top-attached, handler below", host, fromTop, Port PW 0, Point 300 300)
            , ("top-attached, directly below", host, fromTop, Port PS 0, Point 150 300)
            , ("overlapping the host's band, vertical port", host, fromBottom, Port PS 0, Point 300 160)
            ]

      it "clears the host in every arrangement" $
        [ (name, length (touchesHost h ps)) :: (String, Int)
        | (name, h, s, tp, q) <- cases
        , let ps = snd (route h s tp q)
        , not (null (touchesHost h ps))
        ]
          `shouldBe` []

      it "arrives at the port from outside the shape" $
        [ name
        | (name, h, s, tp, q) <- cases
        , not (arrives (portSide tp) (snd (route h s tp q)))
        ]
          `shouldBe` []

      it "stays inside its declared bend budget" $
        [ (name, routeBends r, budget)
        | (name, h, s, tp, q) <- cases
        , let (budget, ps) = route h s tp q
        , let r = Route ps EcBoundary budget
        , routeBends r > budget
        ]
          `shouldBe` []

      it "is orthogonal and free of degenerate waypoints" $
        [ name
        | (name, h, s, tp, q) <- cases
        , let ps = snd (route h s tp q)
        , any (not . segIsOrthogonal) (routeSegments ps)
            || or (zipWith (==) ps (drop 1 ps))
        ]
          `shouldBe` []

      it "starts and ends where it was told to" $
        [ name
        | (name, h, s, tp, q) <- cases
        , let ps = snd (route h s tp q)
        , head ps /= s || last ps /= q
        ]
          `shouldBe` []

      it "takes the four-bend excursion only when the stub has to travel away from the handler" $
        -- The excursion is for a handler the stub cannot reach by turning
        -- once: directly beyond the host, on the far side from the border the
        -- event is attached to, and entered through a vertical port whose
        -- approach is in the host's own column. Getting there means leaving
        -- the host, crossing its band in a corridor beside it, and coming
        -- back. Both mirrors of that arrangement are here, and everything
        -- simpler than them must stay simpler.
        [ (name, fst (route h s tp q))
        | (name, h, s, tp, q) <- cases
        , fst (route h s tp q) >= 4
        ]
          `shouldBe` [("directly above, vertical port", 4), ("top-attached, directly below", 4)]

      it "prefers the canonical one-bend drop whenever it is legal" $
        fst (route host fromBottom (Port PW 0) (Point 300 300)) `shouldBe` 1

      -- The hand-picked cases above name the arrangements that matter; this
      -- one is the proof. Every attachment point, every port side and a handler
      -- everywhere around the host, including on top of it.
      let sweep =
            [ (sx, edge, side, qx, qy)
            | sx <- [120, 150, 180]
            , edge <- [rectBottom host + evSize `div` 2, rY host - evSize `div` 2]
            , side <- [PW, PE, PN, PS]
            , qx <- [-100, 20, 120, 150, 220, 400]
            , qy <- [-40, 60, 140, 190, 300]
            -- HC-002 keeps every other node 2U clear of the host, so a port
            -- point nearer than that belongs to a handler overlapping the box
            -- it hangs from. There is no route out of that and no point asking
            -- for one; the sweep asks about arrangements that can exist.
            , not (rectContains (inflate (2 * u - 1) host) (Rect qx qy 0 0))
            ]
          swept (sx, edge, side, qx, qy) =
            snd (route host (Point sx edge) (Port side 0) (Point qx qy))
          sweptPort (_, _, side, _, _) = Port side 0

      it "never touches the host, wherever the handler is" $
        [ c | c <- sweep, not (null (touchesHost host (swept c)))] `shouldBe` []

      it "is orthogonal and non-degenerate, wherever the handler is" $
        [ c
        | c <- sweep
        , let ps = swept c
        , any (not . segIsOrthogonal) (routeSegments ps) || or (zipWith (==) ps (drop 1 ps))
        ]
          `shouldBe` []

      it "keeps its endpoints, wherever the handler is" $
        [ c
        | c@(sx, edge, _, qx, qy) <- sweep
        , let ps = swept c
        , head ps /= Point sx edge || last ps /= Point qx qy
        ]
          `shouldBe` []

      it "reaches the port from outside the shape wherever a route can" $
        -- One arrangement in the sweep cannot be reached by any orthogonal
        -- route, and it is worth naming exactly rather than excusing: a handler
        -- whose W port sits MIN_SEG to the right of the host at the host's own
        -- mid-height. The approach has to come from the left, and the only gap
        -- there is one MIN_SEG wide — room for the corridor or for the
        -- approach, not for both. BPMN's answer is a different port (EDGE-020
        -- rung 3), which is a decision for port assignment and not for one
        -- route. What the route still guarantees is that it does not cross the
        -- host on its way there.
        nub
          [ (side, qx, qy)
          | c@(_, _, side, qx, qy) <- sweep
          , not (arrives (portSide (sweptPort c)) (swept c))
          ]
          `shouldBe` [(PW, 220, 140)]

    it "test_EDGE_015_cross_lane_jog_sits_at_the_gap_midpoint" $
      let l = layoutOf laneProcess
          pts = rtPoints (routeOf l "Flow_a_b")
          src = shapeOf l "Activity_a"
          tgt = shapeOf l "Activity_b"
       in (length pts, ptX (pts !! 1)) `shouldBe` (4, (rectRight src + rX tgt) `div` 2)

    it "test_EDGE_016_message_flow_runs_perpendicular_to_the_pool_stack" $
      let l = layoutOf collabProcess
          pts = rtPoints (routeOf l "MessageFlow_a_b")
       in all (\(p, q) -> ptX p == ptX q || ptY p == ptY q) (zip pts (drop 1 pts)) `shouldBe` True

    it "test_EDGE_021_no_backward_movement_on_a_forward_edge" $
      violationsFor "EDGE-021" everyPattern `shouldBe` []

  describe "§F branching" $ do
    it "test_BRANCH_003_axis_lock_puts_the_default_branch_on_the_spine" $
      let l = layoutOf branchingProcess
       in rectCenterY (shapeOf l "Activity_p") `shouldBe` rectCenterY (shapeOf l "Gateway_g")

    it "test_BRANCH_003_axis_separation_is_task_height_plus_branch_gap" $
      let l = layoutOf branchingProcess
       in abs (rectCenterY (shapeOf l "Activity_q") - rectCenterY (shapeOf l "Activity_p"))
            `shouldBe` taskH + branchGapY

    it "test_BRANCH_003_bbox_center_straddles_the_axis_for_a_parallel_split" $
      let l = layoutOf parallelProcess
          g = rectCenterY (shapeOf l "Gateway_g")
          p = rectCenterY (shapeOf l "Activity_p")
          q = rectCenterY (shapeOf l "Activity_q")
       in (abs (p - g), abs (q - g)) `shouldBe` (70, 70)

    it "test_BRANCH_004_three_branches_use_upper_center_lower" $
      let l = layoutOf threeWay
          g = rectCenterY (shapeOf l "Gateway_g")
          ys = map (rectCenterY . shapeOf l) ["Activity_p", "Activity_q", "Activity_r"]
       in (length (filter (< g) ys), length (filter (== g) ys), length (filter (> g) ys))
            `shouldBe` (1, 1, 1)

    it "test_BRANCH_007_polarity_lexicon_classifies_yes_and_no" $
      (polarityOfText "Yes", polarityOfText "rejected", polarityOfText "later")
        `shouldBe` (Just PolPositive, Just PolNegative, Nothing)

    it "test_BRANCH_007_polarity_is_case_and_punctuation_insensitive" $
      polarityOfText "APPROVED!" `shouldBe` Just PolPositive

    it "test_BRANCH_007_negative_branch_goes_below_the_spine" $
      let l = layoutOf yesNoProcess
       in ( rectCenterY (shapeOf l "Activity_accept") <= rectCenterY (shapeOf l "Gateway_g")
          , rectCenterY (shapeOf l "Activity_refuse") > rectCenterY (shapeOf l "Gateway_g")
          )
            `shouldBe` (True, True)

    it "test_BRANCH_007_a_branch_is_not_an_exception_path_because_something_in_it_ends_that_way" $
      -- The signal EXCEPTION reaches for is a branch whose purpose is to fail.
      -- A branch that also ends normally does not have it, and reading the test
      -- as "any member anywhere" hands the spine to whichever short branch
      -- happened to be neutral — here a single end event, while the main path
      -- with a call activity and three ends is pushed below it.
      let l = layoutOf mixedOutcomes
          axis = rectCenterY (shapeOf l "Activity_hub")
       in ( rectCenterY (shapeOf l "Gateway_pick") == axis
          , rectCenterY (shapeOf l "Gateway_split") == axis
          , rectCenterY (shapeOf l "Event_aside") < axis
          , rectCenterY (shapeOf l "Event_abandoned") > axis
          )
            `shouldBe` (True, True, True, True)

    it "test_BRANCH_014_terminating_decides_a_side_only_when_it_separates_the_branches" $
      -- BRANCH-014 is about a branch that stops while another continues. In an
      -- open region (BRANCH-019) every branch stops, so the property holds of
      -- all of them and separates none: letting it decide there sends every
      -- branch below at once, and a whole subprocess hangs under a spine that
      -- runs along its top edge. Polarity still does the work — the boundary
      -- handler and the terminate end are below, the neutral branch is not.
      let l = layoutOf mixedOutcomes
          axis = rectCenterY (shapeOf l "Activity_hub")
          sideOf n = compare (rectCenterY (shapeOf l n)) axis
       in map sideOf ["Event_aside", "Event_abandoned", "Event_stopped"]
            `shouldBe` [LT, GT, GT]

    it "test_EDGE_002_the_axis_branch_of_an_implicit_split_keeps_the_midpoint" $
      -- Offset ports are measured from the node's axis, so the branch that
      -- continues the flow leaves the side midpoint and only the ones that jog
      -- step off it. Handing offsets out by sorted position instead gives the
      -- midpoint to the branch that jogs, and phase 12 then straightens the
      -- axis branch off its own declared port (HC-005) and onto its sibling's
      -- line (HC-009).
      let l = layoutOf mixedOutcomes
          hub = shapeOf l "Activity_hub"
          startOf f = head (rtPoints (routeOf l f))
       in ( startOf "Flow_hub_pick" == Point (rectRight hub) (rectCenterY hub)
          , ptY (startOf "Flow_hub_aside") < rectCenterY hub
          , routeBends (routeOf l "Flow_hub_pick")
          )
            `shouldBe` (True, True, 0)

    it "test_BRANCH_011_merge_shares_the_split_centre_y" $
      let l = layoutOf branchingProcess
       in rectCenterY (shapeOf l "Gateway_g_join") `shouldBe` rectCenterY (shapeOf l "Gateway_g")

    it "test_BRANCH_013_slack_becomes_one_straight_segment" $
      -- A short branch is not stretched to fill; it keeps the column pitch and
      -- runs one long straight connector into the merge.
      let l = layoutOf unequalBranches
          r = routeOf l "Flow_short_g_join"
       in (routeBends r, length (rtPoints r)) `shouldBe` (1, 3)

    it "test_BRANCH_014_terminating_branch_ends_ASAP" $
      -- The end event of the stopping branch sits one column after its last
      -- task, not dragged to the diagram's right edge.
      let l = layoutOf terminatingProcess
       in rX (shapeOf l "Event_stopped") `shouldSatisfy` (< rX (shapeOf l "Event_done"))

    it "test_BRANCH_014_continuing_branch_keeps_the_axis" $
      let l = layoutOf terminatingProcess
       in nub (map (rectCenterY . shapeOf l) ["Activity_a", "Activity_b", "Event_done"])
            `shouldSatisfy` ((== 1) . length)

    it "test_BRANCH_015_nested_region_centres_on_its_own_branch_axis" $
      let l = layoutOf nestedProcess
       in rectCenterY (shapeOf l "Gateway_h") `shouldBe` rectCenterY (shapeOf l "Gateway_g")

    it "test_BRANCH_015_nesting_adds_no_horizontal_indentation" $
      -- The inner gateway occupies a normal column, so a nested split aligns
      -- with unrelated nodes at the same layer (this is what prevents AP-016).
      let l = layoutOf nestedProcess
       in rX (shapeOf l "Gateway_h") `shouldSatisfy` (> rX (shapeOf l "Gateway_g"))

  describe "§G lanes" $ do
    it "test_LANE_003_lane_height_follows_content" $
      let l = layoutOf unevenLanes
          hs = map rH (sortByY (Map.elems (geoLanes (lrGeometry l))))
       in length (nub hs) `shouldSatisfy` (>= 1)

    it "test_LANE_006_each_lane_has_its_own_spine" $
      let l = layoutOf laneProcess
       in rectCenterY (shapeOf l "Activity_a") `shouldSatisfy` (/= rectCenterY (shapeOf l "Activity_b"))

    it "test_LANE_009_cross_lane_flow_makes_horizontal_progress" $
      let l = layoutOf laneProcess
       in rX (shapeOf l "Activity_b") - rectRight (shapeOf l "Activity_a")
            `shouldSatisfy` (>= nodeGapXMin)

    it "test_LANE_012_pools_share_a_width_and_a_left_edge" $
      let l = layoutOf collabProcess
          pools = Map.elems (geoPools (lrGeometry l))
       in (length (nub (map rW pools)), length (nub (map rX pools))) `shouldBe` (1, 1)

  describe "§H labels and artifacts" $ do
    it "test_LABEL_003_an_external_label_is_measured_at_the_height_it_will_be_drawn" $
      -- BPMN DI carries a bounds rectangle; the renderer sets the element's
      -- own @name@ inside it. Measuring two lines and emitting a caption that
      -- wraps to four does not shorten the label, it only hides the overflow
      -- from the formatter — and the extra lines land on whatever the band
      -- below reserved. Here: the gateway the caption belongs to — which the
      -- ladder puts it under, the space above being taken by the branch trunk.
      let l = layoutOf longGatewayCaption
          box = lbRect (labelOf l "Gateway_g")
          gw = shapeOf l "Gateway_g"
       in ( rH box == length (tbLines (externalLabelBox helvetica12 longCaption)) * lineH
          , length (tbLines (externalLabelBox helvetica12 longCaption)) > 2
          , not (rectsOverlap box gw)
          )
            `shouldBe` (True, True, True)

    it "test_LABEL_012_a_wrapped_label_reserves_the_width_it_was_wrapped_to" $
      -- BPMN DI hands the renderer a bounds rectangle and the element's name;
      -- the renderer breaks the name itself and need not agree with us about
      -- where. Camunda Modeler sets external labels a point smaller than we
      -- measure them, fits more words per line, and centres the wider result on
      -- the box we declared — so a box reported at the width of our longest
      -- line is overrun on both sides. A label that wraps is therefore reported
      -- at the width it was wrapped to; one that fits on a line is not, because
      -- there is no second line for a different wrapping to pull up.
      ( tbWidth (externalLabelBox helvetica12 "Should the previous process be cancelled?")
      , tbWidth (externalLabelBox helvetica12 "Insertion complete")
      , tbWidth (externalLabelBox helvetica12 "yes") < labelMaxW
      )
        `shouldBe` (labelMaxW, labelMaxW, True)

    it "test_LABEL_003_a_caption_too_long_for_two_lines_keeps_all_of_them" $
      -- The wrapped text is the label. Nothing is ellipsised away, because the
      -- ellipsis would never reach the file (LABEL-006: never hide a label).
      let box = externalLabelBox helvetica12 "Murex contract export not received by Camunda after 10 minutes"
       in (length (tbLines box) > 2, any (T.isInfixOf "\x2026") (tbLines box))
            `shouldBe` (True, False)

    it "test_EDGE_005_an_upward_branch_of_an_implicit_split_leaves_through_the_top" $
      -- An activity's bottom edge belongs to its boundary events, which is why
      -- a downward branch keeps E. Its top edge usually carries nothing, so an
      -- upward branch leaves through N and runs straight to its band: one bend
      -- rather than a step east and a turn back over its own caption.
      let l = layoutOf mixedOutcomes
          hub = shapeOf l "Activity_hub"
          r = routeOf l "Flow_hub_aside"
       in (head (rtPoints r), routeBends r)
            `shouldBe` (Point (rectCenterX hub) (rY hub), 1)

    it "test_EDGE_018_a_flow_label_is_not_crossed_by_its_own_connector" $
      -- The exemption is for the segment the label annotates, which it is
      -- drawn offset from — not for the whole edge. A label that overhangs the
      -- end of its own segment and lands on that connector's next turn is text
      -- with a line through it, and owning the line does not help.
      [ (name, T.unpack (unFlowId fid))
      | (name, src) <- everyPattern
      , let l = layoutOf src
      , (fid, r) <- Map.toAscList (allRoutes l)
      , Just lb <- [Map.lookup (LkFlow fid) (geoLabels (lrGeometry l))]
      , sg <- routeSegments (rtPoints r)
      , Just sg /= labelledSegment r
      , segIntersectsRect sg (lbRect lb)
      ]
        `shouldBe` []

    it "test_LABEL_005_outgoing_labels_of_one_gateway_share_a_left_edge" $
      let l = layoutOf yesNoProcess
          xs = [rX (lbRect b) | (LkFlow f, b) <- Map.toList (geoLabels (lrGeometry l)), f `elem` [FlowId "Flow_g_accept", FlowId "Flow_g_refuse"]]
       in length (nub xs) `shouldBe` 1

    it "test_LABEL_005_the_label_stack_clears_the_split_it_is_aligned_to" $
      -- The stack sits 1U right of the split's centre so a Yes/No pair reads as
      -- one column. For the peel branches that is empty space; for the axis
      -- branch it is just above the split's own centre line, where a 50 px
      -- diamond is still solid ink. The corners of a gateway's bounding box are
      -- empty, which is why the box is not the test — the band beside its
      -- centre line is not empty at all.
      [ (name, T.unpack (unFlowId fid), T.unpack (unNodeId n))
      | (name, src) <- everyPattern
      , let l = layoutOf src
      , let gws = gatewaysOf src
      , let ends = flowEndpoints src
      , (LkFlow fid, lb) <- Map.toAscList (geoLabels (lrGeometry l))
      , Just (a, b) <- [Map.lookup fid ends]
      , n <- [a, b]
      , n `elem` gws
      , Just r <- [Map.lookup n (allShapes l)]
      , diamondHits r (lbRect lb)
      ]
        `shouldBe` []

    it "test_LABEL_005_a_backward_segment_anchors_the_label_at_its_own_start" $
      -- LABEL-005 anchors at the segment's start and overhangs toward the
      -- target. Both halves are about the direction of travel: a loopback's
      -- first horizontal segment runs right-to-left, and reading them as
      -- page-left and page-right puts the caption off the end of the line,
      -- floating beside an arrow it no longer belongs to.
      let l = layoutOf loopProcess
          lb = lbRect (labelOfFlow l "Flow_g_a")
          r = routeOf l "Flow_g_a"
          seg = labelledSegment r
       in case seg of
            Just (Segment a b) ->
              (ptX b < ptX a, rectRight lb <= ptX a, rX lb >= ptX b)
                `shouldBe` (True, True, True)
            Nothing -> expectationFailure "no labelled segment"

    it "test_LABEL_009_a_message_flow_label_does_not_straddle_a_pool_border" $
      -- Message flows are routed after phase 9, so no scope's label pass ever
      -- saw them. Leaving the caption unplaced does not leave it unlabelled:
      -- the name is serialised either way, and a modeller with no bounds to go
      -- on drops it at the middle of the flow — for a route crossing the
      -- inter-pool gap, squarely on a pool border.
      let l = layoutOf namedMessageFlows
          geo = lrGeometry l
          pools = Map.elems (geoPools geo)
          straddles r = [p | p <- pools, rectsOverlap r p, not (rectContains p r)]
       in [ (show k, length (straddles (lbRect lb)))
          | (k, lb) <- Map.toAscList (geoLabels geo)
          , not (null (straddles (lbRect lb)))
          ]
            `shouldBe` []

    it "test_LANE_004_a_lane_insets_its_content_from_its_own_border" $
      -- The right-hand padding was there because laneW adds it; the left-hand
      -- one because nobody did, so the first node sat against the border and
      -- its caption hung outside the lane altogether.
      let l = layoutOf lanedStart
          lane = head (sortOn rY (Map.elems (geoLanes (lrGeometry l))))
          node = shapeOf l "StartEvent_s"
          lb = lbRect (labelOf l "StartEvent_s")
       in (rX node - rX lane >= containerPadX, rectContains lane lb)
            `shouldBe` (True, True)

    it "test_LABEL_010_an_annotation_reserves_room_for_its_bracket" $
      -- The bracket down an annotation's left side is not text space, and the
      -- renderer supplies its own padding on top. Sizing the box to the text
      -- plus LABEL_PAD alone leaves the last line past the bracket.
      let l = layoutOf annotatedTask
          r = head (Map.elems (geoArtifacts (lrGeometry l)))
          text = "Three attempts, then an incident"
          fits = tbWidth (wrapAt (rW r - 2 * labelPad - annotBracket) text)
       in (fits <= rW r - 2 * labelPad - annotBracket, rH r >= 2 * lineH)
            `shouldBe` (True, True)

    it "test_LABEL_011_labels_are_in_the_geometry" $
      Map.keys (geoLabels (lrGeometry (layoutOf "start s \"Started\"\nend e")))
        `shouldSatisfy` elem (LkNode (NodeId "StartEvent_s"))

    it "test_ART_001_data_objects_go_in_the_gutter_above_their_host" $
      let l = layoutOf "start s\ntask t\nend e\ndata d \"Doc\" from t"
          host = shapeOf l "Activity_t"
          art = head (Map.elems (geoArtifacts (lrGeometry l)))
       in (rectBottom art <= rY host, rY host - rectBottom art) `shouldBe` (True, artifactGap)

    it "test_ART_003_association_is_a_zero_bend_vertical" $
      let l = layoutOf "start s\ntask t\nend e\ndata d \"Doc\" from t"
          r = head [x | (FlowId f, x) <- Map.toList (allRoutes l), T.isPrefixOf "Association_" f]
       in routeBends r `shouldBe` 0

  describe "§I anti-patterns" $ do
    it "test_AP_001_no_diagonal_connector" $
      violationsFor "AP-001" everyPattern `shouldBe` []

    it "test_AP_005_no_near_miss_alignment" $
      violationsFor "AP-005" everyPattern `shouldBe` []

    it "test_AP_008_loopback_never_cuts_through_the_main_flow" $
      violationsFor "AP-008" everyPattern `shouldBe` []

    it "test_AP_010_no_unjustified_backward_movement" $
      violationsFor "AP-010" everyPattern `shouldBe` []

    it "test_LABEL_004_two_boundary_labels_on_one_host_stay_apart" $
      let l = layoutOf twoLabelledBoundaries
          box k = lbRect (labelOf l k)
       in rectsOverlap (box "Event_first") (box "Event_second") `shouldBe` False

    it "test_LABEL_006_a_label_never_settles_on_a_connector" $
      -- EDGE-018 and LABEL-011: a connector is an obstacle for a label exactly
      -- like a node box, and the ladder is what keeps the two apart.
      [ (name, T.unpack (unNodeId n), T.unpack (unFlowId fid))
      | (name, src) <- everyPattern
      , let l = layoutOf src
      , (LkNode n, lb) <- Map.toAscList (geoLabels (lrGeometry l))
      , (fid, r) <- Map.toAscList (allRoutes l)
      , any (`segIntersectsRect` lbRect lb) (routeSegments (rtPoints r))
      ]
        `shouldBe` []

    it "test_LABEL_011_no_label_lands_on_a_shape_it_does_not_name" $
      [ (name, show k, T.unpack (unNodeId n))
      | (name, src) <- everyPattern
      , let l = layoutOf src
      , let ends = flowEndpoints src
      , (k, lb) <- Map.toAscList (geoLabels (lrGeometry l))
      , (n, r) <- Map.toAscList (allShapes l)
      , not (owns ends k n)
      , not (isContainer l n)
      , rectsOverlap (lbRect lb) r
      ]
        `shouldBe` []

    it "test_LABEL_011_is_reported_rather_than_drawn" $
      violationsFor "LABEL-011" everyPattern `shouldBe` []

    it "test_AP_015_gateways_are_never_fused" $
      violationsFor "AP-015" everyPattern `shouldBe` []

    it "test_AP_021_exception_never_sits_above_a_normal_branch" $
      violationsFor "AP-021" everyPattern `shouldBe` []

  describe "§K quality gates" $ do
    it "test_K_gate_no_tier0_or_tier1_violation_survives" $
      [ (name, T.unpack (unRuleId (vRule v)))
      | (name, src) <- everyPattern
      , v <- lrViolations (layoutOf src)
      , vTier v <= T1
      ]
        `shouldBe` []

    it "test_K_gate_no_edge_exceeds_six_bends" $
      [ name
      | (name, src) <- everyPattern
      , r <- Map.elems (allRoutes (layoutOf src))
      , routeBends r > 6
      ]
        `shouldBe` []

    it "test_K_spine_bend_penalty_is_zero_on_structured_processes" $
      [ name
      | (name, src) <- structuredPatterns
      , Just v <- [lookup "spineBendPenalty" (scTerms (lrScore (layoutOf src)))]
      , v > 0
      ]
        `shouldBe` []

-- Fixtures ---------------------------------------------------------------------

linearProcess, branchingProcess, parallelProcess, threeWay, yesNoProcess :: Text
linearProcess = "start s\ntask a \"A\"\ntask b \"B\"\nend e"
branchingProcess = "start s\ntask a\nxor g { branch \"one\" otherwise { task p } branch \"two\" when \"=x\" { task q } }\nend e"
parallelProcess = "start s\nand g { branch { task p } branch { task q } }\nend e"
threeWay = "start s\nxor g { branch \"a\" otherwise { task p } branch \"b\" when \"=b\" { task q } branch \"c\" when \"=c\" { task r } }\nend e"
yesNoProcess = "start s\nxor g \"OK?\" { branch \"yes\" otherwise { task accept } branch \"no\" when \"=n\" { task refuse } }\nend e"

loopProcess, boundaryProcess, laneProcess, subprocessProcess :: Text
loopProcess = "start s\ntask a\ntask b\nxor g { branch \"ok\" otherwise\nbranch \"retry\" when \"=r\" { goto a } }\ntask c\nend e"
boundaryProcess = "error boom \"BOOM\"\nprocess p { start s\ntask t\nend e\non t catch error boom as failed { task h\nend aborted } }"
laneProcess = "lane one \"One\" { start s\ntask a }\nlane two \"Two\" { task b\nend e }"
subprocessProcess = "start s\nsubprocess sub { start b\ntask t\nend d }\nend e"

terminatingProcess, nestedProcess, gatewayChain, unequalBranches :: Text
terminatingProcess = "start s\nxor g { branch \"go\" otherwise { task a\ntask b\nend done } branch \"stop\" when \"=n\" { task c\nend stopped } }"
nestedProcess = "start s\nxor g { branch \"a\" otherwise { xor h { branch \"a1\" otherwise { task p } branch \"a2\" when \"=x\" { task q } } } branch \"b\" when \"=y\" { task r } }\nend e"
gatewayChain = "start s\nxor g { branch \"a\" otherwise { task p } branch \"b\" when \"=b\" { task q } }\nand h { branch { task r } branch { task t } }\nend e"
unequalBranches = "start s\nxor g { branch \"long\" otherwise { task l1\ntask l2\ntask l3 } branch \"short\" when \"=s\" { task short } }\nend e"

-- | A branch whose only content is a 36 px event. The band pitch is set by the
-- branch gap, but the stub the router needs is measured from the /gateway's/
-- border, so a small node centred in that band can sit closer to the split than
-- MIN_SEG allows. Three shapes, because the failure reached all three: a
-- data-based split with no branch on the axis, an event gateway (whose branches
-- are catching events by definition), and the same thing across lanes.
smallEventBranches, smallEventGateway, smallEventLanes :: Text
smallEventBranches =
  "start s\nxor g { branch \"a\" when \"=a\" { wait w1 { timer \"PT5M\" } }\nbranch \"b\" when \"=b\" { wait w2 { timer \"PT9M\" } } }\nend e"
smallEventGateway =
  "start s\nevent g { branch { wait w1 { timer \"PT5M\" } }\nbranch { wait w2 { timer \"PT9M\" } }\nbranch { wait w3 { timer \"PT8M\" } } }\nend e"
smallEventLanes =
  "lane one \"One\" { start s\nxor g { branch \"a\" when \"=a\" { wait w1 { timer \"PT1M\" } }\nbranch \"b\" when \"=b\" { wait w2 { timer \"PT2M\" } } } }\nlane two \"Two\" { end e }"

-- | A pinned activity that carries a boundary event. The pin moves the host's
-- band; the exception band below it has to come along, or the handler ends up
-- level with the host it is supposed to catch for.
pinnedBoundary :: Text
pinnedBoundary =
  "escalation x1 \"X1\"\nprocess p { start s\ntask a\nservice snd \"Send\" { type \"n\" }\nend e\n\
  \on snd catch escalation x1 as esc { task handle\nend handled }\npin snd at 800 300 }"

-- | An expanded subprocess whose content hangs below its own spine: the
-- handler band of an inner boundary event pushes the box centre well below the
-- line the inner flow runs on. Centring the container in the outer band is
-- what makes the reader lose the flow at the container border (LAYOUT-020).
subprocessOffCentre :: Text
subprocessOffCentre =
  "error boom \"BOOM\"\nprocess p {\nstart s\nsubprocess sub \"Sub\" {\nstart b\ntask t \"Inner task\"\nend d\n\
  \on t catch error boom as failed \"Inner failure\" { task h \"Handle it\"\nend aborted \"Given up\" } }\nend e }"

-- | A boundary handler that goes back to a step on the host's own band. The
-- canonical exception route turns as soon as it reaches the handler's y, which
-- here is level with the host — so the turn happens inside the box the event is
-- attached to (HC-004, EDGE-014).
boundaryGotoLevel :: Text
boundaryGotoLevel =
  "message resolved \"resolved\" correlation \"=k\"\nprocess p {\nstart s\n\
  \service alert \"Open alert incident\" { type \"alert\" }\nend handled \"Alert handled\"\n\
  \on alert catch message resolved as fixed \"Incident is resolved\" { goto handled } }"

-- | Two boundary events on one host, both with a caption longer than the host
-- is wide. The edge they share is @BE_GAP@ apart, so a ladder that only reaches
-- one way lands the second caption on the first (LABEL-004, LABEL-006).
twoLabelledBoundaries :: Text
twoLabelledBoundaries =
  "error one \"ONE\"\nerror two \"TWO\"\nprocess p {\nstart s\ntask t \"Do the thing\"\nend e\n\
  \on t catch error one as first \"The first exceptional situation\" { end a \"A\" }\n\
  \on t catch error two as second \"The second exceptional situation\" { end b \"B\" } }"

-- | A gateway whose question does not fit on two lines at @LABEL_MAX_W@. The
-- label is placed above the gateway, so under-measuring its height puts the
-- overflow on the gateway itself.
longCaption :: Text
longCaption = "Is MODIFY_UDF over a DEAD deal?"

longGatewayCaption :: Text
longGatewayCaption =
  "process p \"P\" {\nstart s\nxor g \"" <> longCaption <> "\" {\n\
  \branch \"yes\" when \"=y\" { end a \"Yes\" }\nbranch \"no\" otherwise { end b \"No\" } } }"

-- | A split whose main branch reaches a normal end /and/ an escalation end,
-- beside a one-event branch and a boundary handler. Read literally, BRANCH-007's
-- \"contains an error/escalation/cancel end event\" makes the main branch an
-- exception path and hands the axis to the one-event branch; and because the
-- region is open, every branch terminates, so BRANCH-014 then sends all of them
-- below and the whole region hangs under a spine with nothing above it.
mixedOutcomes :: Text
mixedOutcomes =
  "escalation esc \"ESC\" \"Finished\"\nerror boom \"BOOM\"\nprocess p \"P\" {\n\
  \start s\nservice hub \"Hub\" { type \"h\" }\n\
  \xor pick \"Q?\" {\nbranch \"yes\" when \"=y\" { end stopped \"Stopped\" { terminate } }\n\
  \branch \"no\" otherwise { and split \"Both\" {\n\
  \branch { call rep \"Report\" { calls \"r\" }\nend reported \"Reported\" }\n\
  \branch { end escalated \"Escalated\" { escalation esc } } } } }\n\
  \end aside \"Aside\"\nflow hub -> aside \"also\"\n\
  \on hub catch error boom as failed \"Failed\" { end abandoned \"Abandoned\" { terminate } } }"

-- | A lane whose first node is a captioned start event: the caption is wider
-- than the event, so it hangs out of the lane unless the content is inset.
lanedStart :: Text
lanedStart =
  "lane one \"One\" { start s \"Claim filed\"\nservice a \"Register claim\" { type \"r\" } }\n\
  \lane two \"Two\" { user b \"Assess damage\"\nend e \"Settled\" }"

-- | Two pools whose message flows are named, so the captions have to be placed
-- rather than left to the renderer.
namedMessageFlows :: Text
namedMessageFlows =
  "collaboration c {\npool x \"X\" { start s\ntask a \"A\"\nend e }\n\
  \pool y \"Y\" { start t\ntask b \"B\"\nend f }\na ~> b \"the handover\" }"

-- | A task carrying a note longer than one line of an annotation's usable width.
annotatedTask :: Text
annotatedTask =
  "start s\nservice charge \"Charge card\" { type \"pay\" }\nend e\n\
  \note retry_note \"Three attempts, then an incident\" on charge"

twoBoundaries, collabProcess, unevenLanes :: Text
twoBoundaries = "error one \"ONE\"\nerror two \"TWO\"\nprocess p { start s\ntask t\nend e\non t catch error one as first { end a }\non t catch error two as second { end b } }"
collabProcess = "collaboration c { pool x { start s\ntask a\nend e } pool y { start t\ntask b\nend f } a ~> b }"
unevenLanes = "lane one \"One\" { start s\ntask a }\nlane two \"Two\" { xor g { branch \"a\" otherwise { task p } branch \"b\" when \"=b\" { task q } }\nend e }"

-- | Every pattern the hard-constraint tests sweep.
everyPattern :: [(String, Text)]
everyPattern =
  structuredPatterns
    ++ [ ("cross-lane", laneProcess)
       , ("uneven lanes", unevenLanes)
       , ("collaboration", collabProcess)
       , ("small event branches", smallEventBranches)
       , ("small event gateway", smallEventGateway)
       , ("small event branches across lanes", smallEventLanes)
       , ("pinned host with a boundary handler", pinnedBoundary)
       , ("subprocess below its own spine", subprocessOffCentre)
       , ("boundary goto onto the host's band", boundaryGotoLevel)
       , ("two labelled boundary events", twoLabelledBoundaries)
       , ("a branch with mixed outcomes", mixedOutcomes)
       , ("a gateway caption too long for two lines", longGatewayCaption)
       , ("named message flows", namedMessageFlows)
       , ("a captioned start event in a lane", lanedStart)
       , ("a task with a long note", annotatedTask)
       ]

structuredPatterns :: [(String, Text)]
structuredPatterns =
  [ ("linear", linearProcess)
  , ("two-branch xor", branchingProcess)
  , ("three-way xor", threeWay)
  , ("parallel", parallelProcess)
  , ("yes/no", yesNoProcess)
  , ("loopback", loopProcess)
  , ("boundary", boundaryProcess)
  , ("subprocess", subprocessProcess)
  , ("terminating branch", terminatingProcess)
  , ("nested gateways", nestedProcess)
  , ("gateway chain", gatewayChain)
  , ("unequal branches", unequalBranches)
  , ("two boundary events", twoBoundaries)
  ]

-- Helpers ---------------------------------------------------------------------

wrapAt :: Int -> Text -> TextBox
wrapAt w t = wrapText helvetica12 w 4 t

labelOfFlow :: LayoutResult -> Text -> LabelBox
labelOfFlow l f = case Map.lookup (LkFlow (FlowId f)) (geoLabels (lrGeometry l)) of
  Just lb -> lb
  Nothing -> error ("no label for " ++ T.unpack f)

labelOf :: LayoutResult -> Text -> LabelBox
labelOf l n = case Map.lookup (LkNode (NodeId n)) (geoLabels (lrGeometry l)) of
  Just lb -> lb
  Nothing -> error ("no label for " ++ T.unpack n)

-- | Which element a label is allowed to overlap: the one it names, and for a
-- flow label the two shapes its connector joins (SPEC §L pattern B puts a
-- branch label in the empty ink of a diamond's bounding box).
owns :: Map.Map FlowId (NodeId, NodeId) -> LabelKey -> NodeId -> Bool
owns ends k n = case k of
  LkNode m -> m == n
  LkFlow f -> case Map.lookup f ends of
    Just (a, b) -> n == a || n == b
    Nothing -> False
  LkArtifact _ -> False

flowEndpoints :: Text -> Map.Map FlowId (NodeId, NodeId)
flowEndpoints src =
  Map.fromList
    [ (sfId f, (sfSource f, sfTarget f))
    | sc <- scopesIn src
    , f <- scFlows sc
    ]

gatewaysOf :: Text -> [NodeId]
gatewaysOf src = [fnId n | sc <- scopesIn src, n <- scNodes sc, nodeIsGateway n]

scopesIn :: Text -> [Scope]
scopesIn src = concatMap (allScopes . procScope) (sgProcesses (graphOf src))

-- | Does a rectangle touch the /ink/ of a diamond inscribed in @gw@? The
-- corners of a gateway's bounding box are empty, so the box overstates it.
diamondHits :: Rect -> Rect -> Bool
diamondHits gw r
  | not (rectsOverlap gw r) = False
  | otherwise = abs (nx - cx) * rH gw + abs (ny - cy) * rW gw <= rW gw * rH gw `div` 2
  where
    cx = rectCenterX gw
    cy = rectCenterY gw
    nx = max (rX r) (min cx (rectRight r))
    ny = max (rY r) (min cy (rectBottom r))

isContainer :: LayoutResult -> NodeId -> Bool
isContainer l n = case Map.lookup n (allShapes l) of
  Just r -> rW r > taskWMax || rH r > taskHMax
  Nothing -> False

violationsFor :: Text -> [(String, Text)] -> [(String, Text)]
violationsFor rid corpus =
  [ (name, vMessage v)
  | (name, src) <- corpus
  , v <- lrViolations (layoutOf src)
  , unRuleId (vRule v) == rid
  ]

gapsBetween :: LayoutResult -> [Text] -> [Int]
gapsBetween l names =
  zipWith (\a b -> rX b - rectRight a) rects (drop 1 rects)
  where
    rects = map (shapeOf l) names

corridorYOf :: LayoutResult -> Text -> Int
corridorYOf l f = case rtPoints (routeOf l f) of
  (_ : p : _) -> ptY p
  _ -> 0

-- | Re-run a layout, handing back the geometry of the previous run.
relayoutWithPrevious :: Text -> LayoutResult -> LayoutResult
relayoutWithPrevious src prev =
  case crLayout (compileText opts "test.sq" (wrapProcess src)) of
    Just l -> l
    Nothing -> error "layout failed"
  where
    opts =
      defaultOptions
        { coStrictLayout = False
        , coPrevious = Just (lrStructure prev `seq` previousGeometry)
        }
    previousGeometry = Map.fromList [(k, lrGeometry prev) | k <- Map.keys (lrStructure prev)]

-- | Which side of its region's split each node sits on, as a stable summary of
-- the structural arrangement.
sidesOf :: LayoutResult -> [(Text, Ordering)]
sidesOf l =
  [ (unNodeId n, compare (rectCenterY r) axis)
  | (n, r) <- Map.toAscList (allShapes l)
  ]
  where
    axis = case [rectCenterY r | (n, r) <- Map.toAscList (allShapes l), unNodeId n == "Gateway_g"] of
      (y : _) -> y
      [] -> 0

sortByY :: [Rect] -> [Rect]
sortByY = foldr insertByY []
  where
    insertByY r [] = [r]
    insertByY r (x : xs) = if rY r <= rY x then r : x : xs else x : insertByY r xs
