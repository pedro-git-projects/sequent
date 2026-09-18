# SPEC.md compliance

Every rule below has an implementation and at least one test. A rule is marked
**complete** only when both exist; **partial** means the rule is implemented for
the cases the compiler can produce but not in full generality, and the gap is
named. Rules the compiler does not implement keep their row, with the reason in
the status column.

As of this writing: 10 rows are **partial** and 3 rows (4 rules, since
EDGE-022/023 share a row) are **not implemented**. Everything else is complete.

The rows for `HC-*`, `LAYOUT-001/007/035`, `EDGE-007/021`, `ART-005` and `AP-*`
correspond to entries in `Sequent.Layout.Rules.ruleRegistry`, which carries a
detector per rule; `sequent rules` prints it. Tests named `test_<RULE>_*` live in
`test/Sequent/SpecRuleSpec.hs`.

## §B — base geometry

| Rule | Implementation | Tests | Status |
|---|---|---|---|
| §B.1–B.5 constants | `Layout.Constants` | `test_B_base_unit_is_ten`, `test_B_canonical_sizes`, `test_B_half_gaps_stay_on_the_grid` | complete |
| §B.6 `snapCenter`, `ceilU`, `colGap`, `requiredHostW` | `Layout.Constants` | `test_B_half_gaps_stay_on_the_grid`, `test_LAYOUT_016_*`, layout invariants | complete |

## §C — hard constraints

| Rule | Implementation | Tests | Status |
|---|---|---|---|
| HC-001 orthogonality | `Layout.Routing.routeOne` | `test_HC_001_every_connector_is_orthogonal`, `HC-001` invariant over the corpus | complete |
| HC-002 node overlap | `Layout.Collision.separateNodes`, detector in `Layout.Validate` | `test_HC_002_no_node_boxes_overlap` | complete |
| HC-003 containment | `Layout.Collision.growContainers` | `HC-003` detector over the lane corpus | complete |
| HC-004 edge–node clearance | `Layout.Bands` (band allocation) + `Layout.Routing`, `Layout.Validate.hc004` | `test_HC_004_edge_never_intersects_nonincident_node`, `test_HC_004_a_boundary_handler_never_crosses_its_host` | complete — a container and an incident boundary host get clearance `0` rather than an exemption, so a connector may run close to them but never through them |
| HC-005 ports and stubs | `Layout.Ports.assignPorts`, `Layout.Snap.reanchorEndpoints`; the room for the stub is reserved upstream by `Layout.Bands.stackLane` (band clearance) and `Layout.Geometry.columnsFor` (gap never rounds shut) | `test_HC_005_endpoints_lie_on_ports`, `test_HC_005_an_off_axis_band_clears_the_split_by_a_whole_stub`, `test_LAYOUT_005_a_column_gap_leaves_room_for_a_connector_to_turn` | complete |
| HC-006 boundary attachment | `Layout.Geometry.boundaryShapes` | `test_HC_006_boundary_event_sits_on_its_host_border`, corpus invariant | complete |
| HC-007 lanes tile their pool | `Layout.Geometry.laneHeightOf`, `Layout.Collision` re-tiling | `test_HC_007_lanes_tile_their_pool` | complete |
| HC-008 flows stay in their pool | `Bpmn.Validate` (semantic, not geometric) | `rejects a message flow that does not cross a pool`, `flow connects steps in different scopes` | complete |
| HC-009 bundling vs overlap | `Layout.Routing.takeChannel`, `Layout.Ports` (N-20 surplus rule); the one case no channel can separate — two flows between the same pair of endpoints — is rejected in `Language.Resolve.reportDuplicateFlows` at the line that wrote it | `test_HC_009_no_collinear_overlap_outside_a_bundle`, `rejects a flow that restates the implicit chain`, `rejects a repeated message flow` | complete |
| HC-010 degenerate waypoints | `Layout.Routing.simplify`, `Layout.Snap.simplifyPoints` | `HC-010` corpus invariant | complete |
| HC-011 grid and non-negativity | `Layout.Geometry` (snap at placement), `Layout.Snap`, `Layout.layoutScopeRecursive` and `Layout.stackPools` (whole-unit container offsets) | `test_HC_011_centres_are_on_the_grid`, `test_HC_011_a_container_keeps_its_contents_on_the_grid`, corpus invariants | complete — including the merged geometry, which is where a per-scope check cannot see the fault |
| HC-012 text fits its shape | `Layout.Labels.activityGrowthLadder` | `test_HC_012_activity_text_never_overflows`, metrics tests | complete |
| HC-013 lane dividers | `Layout.Geometry.assignGeometry` | `HC-013` detector over the lane corpus | complete |
| HC-014 subprocess containment | `Layout.Collision.growContainers`, `Layout.layoutScopeRecursive` | `test_HC_014_subprocess_contains_its_children` | complete |
| HC-015 pool crossing | `Layout.stackPools` + `withMessageFlows` | `test_EDGE_016_*` | partial — message flows are routed through the inter-pool gap by construction; the crossing angle is not separately re-validated |
| HC-016 determinism | `Bpmn.Semantic.canonicalise`, `Compiler.compileGraph`, `Layout.format` | whole of `DeterminismSpec` | complete |

## §D — structural layout

| Rule | Implementation | Tests | Status |
|---|---|---|---|
| LAYOUT-001 primary direction | `Layout.Layering.asapLayers` | `test_LAYOUT_001_forward_flows_progress_rightward` | complete |
| LAYOUT-002 grid and snapping | `Layout.Constants.snapCenter`, `Layout.Snap` | `test_HC_011_centres_are_on_the_grid` | complete |
| LAYOUT-003 canonical sizes | `Layout.Labels.nodeSize` | `LAYOUT-003` corpus invariant, `test_B_canonical_sizes` | complete |
| LAYOUT-004 ASAP layering | `Layout.Layering.asapLayers` | `test_LAYOUT_004_all_branches_of_a_split_start_in_one_column` | complete |
| LAYOUT-005 column geometry | `Layout.Geometry.columnsFor` | `test_LAYOUT_005_column_pitch_is_uniform`, golden pattern A | complete |
| LAYOUT-006 spine identification | `Layout.Regions.detectRegions` | `test_LAYOUT_007_spine_stays_straight` | complete |
| LAYOUT-007 spine straightness | `Layout.Regions` + `Layout.Bands`, detector in `Layout.Validate` | `test_LAYOUT_007_spine_stays_straight`, `test_LAYOUT_007_spine_edges_have_no_bends` | complete |
| LAYOUT-008 vertical centring of non-spine content | `Layout.Bands.stackLane` | `test_BRANCH_003_*` | complete |
| LAYOUT-009 virtual nodes | `Layout.Layering.virtualChains` | `test_LAYOUT_021_*` (channel demand) | partial — a multi-layer edge reserves a corridor in every gap it crosses, which is what the dummy chain exists to guarantee; the dummies themselves are not materialised as band members |
| LAYOUT-010 row wrapping | advisory in `Layout.advisories` | `PerformanceSpec` large-mode advisory | complete — wrapping is prohibited, the advisory is emitted |
| LAYOUT-011 alignment tracks | `Layout.Geometry.columnsFor`, `Layout.Score` (`alignmentPenalty`) | `test_LAYOUT_004_*` | complete |
| LAYOUT-012 centre alignment | `Layout.Types.rectFromCenter`, `Layout.Geometry` | `test_LAYOUT_012_centres_align_across_mixed_sizes` | complete |
| LAYOUT-013 band model | `Layout.Bands` | `test_LAYOUT_017_*`, `test_LAYOUT_018_*`, `test_ART_001_*` | complete |
| LAYOUT-014 events on the spine | `Layout.Geometry.columnsFor` (`COMPACT_GAP`) | golden pattern A | complete |
| LAYOUT-015 multiple end events | `Layout.Layering.asapLayers` | `multiple ends` corpus entry, `test_BRANCH_014_terminating_branch_ends_ASAP` | complete |
| LAYOUT-016 boundary distribution | `Layout.Geometry.boundaryShapes`, `Layout.Labels.hostWidthForBoundaries`, `Layout.Bands.nodeExtent` (band reservation), `Layout.Constants.boundaryCapacity` | `test_LAYOUT_016_boundary_events_spread_along_the_bottom_edge`, `test_HC_006_*`, metrics tests | complete — the band reserves the events' captions as well as the events, on whichever edge each one attaches to |
| LAYOUT-017 exception band | `Layout.Bands.stackLane` (`EXC_GAP_Y`), `Layout.Branches.branchSideFor` | `test_LAYOUT_017_exception_band_sits_below_every_ordinary_band` | complete |
| LAYOUT-018 loopback corridors | `Layout.Bands.corridorsOf` | `test_LAYOUT_018_loopback_corridor_carries_no_node`, `test_EDGE_013_*` | complete |
| LAYOUT-019 subprocess sizing | `Layout.layoutScopeRecursive` (`containerBox`) | `test_HC_014_subprocess_contains_its_children`, `test_LAYOUT_019_a_container_holds_its_children_and_its_padding`, `test_LAYOUT_020_a_container_reserves_the_same_room_on_both_sides_of_its_spine` | complete — measured as `(above, below)` about the child's spine so LAYOUT-020 needs no second pass, then squared to `2·max(above, below)` so the box is centred on that spine |
| LAYOUT-020 subprocess spine continuity | `Layout.layoutScopeRecursive` (`innerSpineY`, `placeChild`), `Layout.Types.AxisMap` threaded through `Bands`, `Geometry`, `Ports`, `Routing`, `Snap`, `Score`, `Validate` | `test_LAYOUT_020_a_container_hangs_from_its_own_spine`, `test_LAYOUT_020_the_flow_through_a_container_has_no_bend`, corpus entry "subprocess below its own spine" | complete — outer spine, inner spine and box centre are one line. The axis is carried separately from the box centre even though LAYOUT-019's sizing makes them equal, so the phases that read it stay correct if the sizing is ever tightened |
| LAYOUT-021 horizontal compaction | `Layout.Compact.planCompaction` | `test_LAYOUT_021_compaction_leaves_a_content_derived_layout_alone` | complete |
| LAYOUT-022 vertical compaction | `Layout.Bands` (content-derived extents) | `test_LAYOUT_021_*` | complete — band gaps are derived from content, so there is nothing to compact; the detector for an unjustified gap is `Layout.Compact.emptyStrips` |
| LAYOUT-023 whitespace quality | `Layout.Score` (`gapUniformity`, `areaPenalty`), `Layout.Compact.emptyStrips` advisory | score terms exercised by `report`; `test_LAYOUT_021_*` | complete |
| LAYOUT-024 incremental stability | `Layout.seedFromPrevious`, `Layout.Improve.stabilityCost` | `test_LAYOUT_024_a_re_run_keeps_the_previous_branch_sides`, `test_LAYOUT_024_a_small_edit_makes_a_small_change` | complete |
| LAYOUT-025 manual pins | `Layout.Geometry.applyPins` (column, `colCx`), `Layout.Geometry.pinBand` (band, `bandAxisY`), `Layout.Snap.anchorPins` | `test_LAYOUT_025_a_pin_is_honoured_exactly`, `…_does_not_drag_the_columns_before_it`, `…_a_pin_moves_the_band_not_the_node_alone`, `…_a_pinned_host_keeps_its_handler_below_it`, `…_a_pin_yields_to_the_grid_and_says_so`, `…_an_unsatisfiable_pin_is_reported_not_dropped` | complete — both halves of the rule; the HARD-beats-STRONG exception is resolved toward HC-011 and the pin reported |
| LAYOUT-026 symmetry preference | `Layout.Score` (`asymmetryPenalty`), `Layout.Branches.peerSymmetricRegion` | `test_BRANCH_003_bbox_center_straddles_the_axis_for_a_parallel_split` | complete |
| LAYOUT-027 determinism | `Bpmn.Semantic.canonicalise`, `Bpmn.Graph` | whole of `DeterminismSpec` | complete |
| LAYOUT-028 large-diagram mode | `Layout.Constants.largeMetrics`, mode switch in `Layout` | `LAYOUT-028 large-diagram mode` in `PerformanceSpec` | complete |
| LAYOUT-029 growth ladder | `Layout.Labels.activityGrowthLadder` | `the growth ladder (LAYOUT-029)` in `MetricsSpec` | complete |
| LAYOUT-030 marker clearance | `Layout.Labels.nodeHasMarker`, `internalLabel` | `reserves the marker band when a marker is present` | complete |
| LAYOUT-031 diagram bounds | `Layout.Snap.translateToMargin` | `test_LAYOUT_031_diagram_starts_at_the_margin`, corpus invariant | complete — with the documented HC-011 resolution: the translation is a whole grid unit |
| LAYOUT-032 gateway chains | `Layout.Geometry.columnsFor` | `test_LAYOUT_032_adjacent_gateways_use_the_compact_gap` | complete |
| LAYOUT-033 unstructured residue | `Layout.Regions` (irreducible SCCs), `Layout.Bands.resolveBandCollisions` | `LAYOUT-033` advisory | partial — irreducible loops are isolated and laid out by the local fallback; the fallback is a monotone band spread rather than a full Sugiyama pass |
| LAYOUT-034 multiple components | `Layout.Bands.separateComponents` | corpus invariants | complete |
| LAYOUT-035 event subprocess placement | `Layout.relocateHandlers`, `Layout.Geometry.columnsFor` (no column width), `Layout.Regions.detectRegions` (not on the spine), detector in `Layout.Validate` | `test_LAYOUT_035_an_event_subprocess_is_stacked_below_the_flow`, `test_LAYOUT_035_two_handlers_stack_in_canonical_order`, `test_LAYOUT_035_an_event_subprocess_claims_no_column_width`, `test_LAYOUT_035_a_handler_stays_inside_its_lane`, `test_LAYOUT_035_a_handler_in_an_upper_lane_stays_in_it`, `test_LAYOUT_006_an_event_subprocess_is_not_on_the_spine` | complete |

## §E — connector routing

| Rule | Implementation | Tests | Status |
|---|---|---|---|
| EDGE-001 orthogonality | `Layout.Routing` | `test_AP_001_no_diagonal_connector` | complete |
| EDGE-002 port model | `Layout.Ports` (`fanOffsets`) | `test_HC_005_*`, `test_EDGE_002_the_axis_branch_of_an_implicit_split_keeps_the_midpoint` | complete — midpoints measured from the node's axis (LAYOUT-020), and fan offsets handed out from that axis outward on the side the far endpoint is on, so the branch that continues the flow keeps the midpoint |
| EDGE-003 straight-through | `Layout.Routing`, `Layout.Snap.straightenNearStraight` | `test_EDGE_003_collinear_centres_give_a_two_point_route` | complete |
| EDGE-004 stub rule | `Layout.Routing.channelX` | `test_HC_005_*` | complete |
| EDGE-005 fan-out comb | `Layout.Routing.routeOne` | `test_EDGE_005_split_branch_uses_the_one_bend_comb`, `…_comb_trunk_sits_at_the_gateway_centre` | complete, with the documented activity fallback |
| EDGE-006 fan-in comb | `Layout.Routing.routeOne` | `test_EDGE_006_merge_branch_uses_the_one_bend_comb` | complete |
| EDGE-007 bend budget | `Layout.Types.edgeBendBudget`, `Route.rtBudget` | `test_EDGE_007_every_route_is_within_its_budget`, `test_K_gate_no_edge_exceeds_six_bends` | complete |
| EDGE-008 channels | `Layout.Routing.channelX`, `takeChannel` | `test_EDGE_015_*` | complete |
| EDGE-009 bundling | `Layout.Validate` detector, `Layout.Ports` surplus rule | `test_HC_009_*` | complete |
| EDGE-010 crossing minimisation | `Layout.Branches` (band order), `Layout.Ports` (port order), `Layout.Routing` (channel order) | `crossingPenalty` in the score | complete for the structured path; the numeric fallback of step 4 is not implemented |
| EDGE-011 clean crossings | `Layout.Score.countCrossings` | score term | partial — crossings are counted and penalised; the five geometric predicates on a crossing point are not separately enforced |
| EDGE-012 crossing vs joining | `Layout.Validate` HC-009 detector | `test_HC_009_*` | complete |
| EDGE-013 loopback routing | `Layout.Routing.routeOne`, `Layout.Bands.corridorsOf` | `test_EDGE_013_loopback_uses_corridor`, `…_enters_the_target_on_an_edge_not_a_corner` | complete, with the documented below-corridor exception |
| EDGE-014 boundary exception routing | `Layout.Routing.boundaryExceptionRoute` | `test_EDGE_014_boundary_exception_route_has_one_bend`, `test_EDGE_014_the_exception_route_never_touches_its_host` (11 named arrangements and a 624-configuration sweep), `test_HC_004_a_boundary_handler_never_crosses_its_host` | complete — five forms generated in order and filtered, so no route that touches the host can be chosen; the one arrangement with no legal route (a `W` port `MIN_SEG` past the host at its mid-height) is named by the test and left to EDGE-020 rung 3 |
| EDGE-015 cross-lane Z | `Layout.Routing.routeOne`, `channelX` | `test_EDGE_015_cross_lane_jog_sits_at_the_gap_midpoint` | complete |
| EDGE-016 message flows | `Layout.withMessageFlows` | `test_EDGE_016_message_flow_runs_perpendicular_to_the_pool_stack` | complete |
| EDGE-017 association routing | `Layout.placeArtifacts` | `test_ART_003_association_is_a_zero_bend_vertical` | complete |
| EDGE-018 label reservation | `Layout.placeAllLabels`, `Layout.Labels.labelledSegment`, `Layout.withMessageFlows` (the post-phase-9 repair) | `test_LABEL_005_*`, `test_LABEL_006_a_label_never_settles_on_a_connector`, `test_EDGE_018_a_flow_label_is_not_crossed_by_its_own_connector`, corpus invariant "no label sits on a connector" | complete — connectors are obstacles for labels, the own-edge exemption covers only the annotated segment, and a message flow, routed after phase 9, re-runs the ladder for the captions it crosses |
| EDGE-019 route cost | `Layout.Routing.routeCost` | `test_EDGE_019_route_cost_encodes_the_normative_magnitudes` | partial — the cost function is implemented and its normative magnitudes are asserted; the router generates one canonical route per class rather than a candidate set to choose among |
| EDGE-020 clearance repair ladder | `Layout.Collision`, `Layout.Routing` | `test_HC_004_*` | partial — rungs 1, 2 and 5 are implemented; port reassignment and node displacement are not |
| EDGE-021 backward movement | `Layout.Routing`, detector in `Layout.Validate` | `test_EDGE_021_no_backward_movement_on_a_forward_edge` | complete |
| EDGE-022/023 marker clearance | — | — | not implemented — the tick and diamond markers are rendered by the modeller, not by this compiler |
| EDGE-024 arrowhead legibility | `Layout.Routing`, HC-005 stub check | `test_HC_005_*` | complete |
| EDGE-025 pattern catalogue | `Layout.Types.EdgeClass`, `Layout.Routing.classifyEdge` | the `test_EDGE_*` group | complete |

## §F — branching

| Rule | Implementation | Tests | Status |
|---|---|---|---|
| BRANCH-001 region detection | `Layout.Regions.detectRegions` | `test_BRANCH_015_*`, corpus invariants | complete |
| BRANCH-002 branch bounding box | `Layout.Bands.branchExtent` | `test_BRANCH_003_axis_separation_*`, `test_LAYOUT_017_*` | complete |
| BRANCH-003 two branches | `Layout.Bands.stackLane` | `test_BRANCH_003_axis_lock_*`, `…_bbox_center_*` | complete |
| BRANCH-004 three branches | `Layout.Branches.slotOrder`, `Layout.Bands.stackLane` | `test_BRANCH_004_three_branches_use_upper_center_lower` | complete |
| BRANCH-005 four branches | `Layout.Branches.assignSides`, `rebalanceSides` | `test_BRANCH_004_*` | complete |
| BRANCH-006 five or more | `Layout.Branches.rebalanceSides`, `fanColumnThreshold` | advisory test | partial — ranking, polarity partition and rebalancing are implemented; `FAN_COLUMN` sub-fans are advised rather than constructed |
| BRANCH-007 branch comparator | `Layout.Branches.branchKey`, `classifyPolarity` | `test_BRANCH_007_polarity_lexicon_*`, `…_negative_branch_goes_below_the_spine`, `…_a_branch_is_not_an_exception_path_because_something_in_it_ends_that_way` | complete — EXCEPTION is classified over the branch's /outcomes/, not over any member: a branch that also ends normally is not an exception path |
| BRANCH-008 axis occupancy | `Layout.Branches.chooseMode` | `test_BRANCH_003_*` | complete |
| BRANCH-009 gateway-type specifics | `Layout.Branches.chooseMode`, `peerSymmetricRegion`, `Layout.Ports.srcSide` | `test_BRANCH_003_bbox_center_*`, `test_EDGE_005_an_upward_branch_of_an_implicit_split_leaves_through_the_top` | complete — an activity's implicit split leaves downward through `E` (its bottom edge belongs to its boundary events) and upward through `N` when the top edge is clear |
| BRANCH-010 fan-out gap | `Layout.Geometry.columnsFor` | golden pattern B | complete |
| BRANCH-011 merge placement | `Layout.Layering`, `Layout.Bands.stackLane` | `test_BRANCH_011_merge_shares_the_split_centre_y` | complete |
| BRANCH-012 split/merge alignment | `Layout.Bands.stackLane` | `test_BRANCH_011_*`, `test_AP_003_*` | complete |
| BRANCH-013 unequal branch lengths | `Layout.Layering.asapLayers` | `test_BRANCH_013_slack_becomes_one_straight_segment` | complete |
| BRANCH-014 early-ending branches | `Layout.Regions` (`terminates`), `Layout.Branches.terminatesAgainstPeers`, `branchSideFor` | `test_BRANCH_014_terminating_branch_ends_ASAP`, `…_continuing_branch_keeps_the_axis`, `…_terminating_decides_a_side_only_when_it_separates_the_branches` | complete — the property decides a side only where it separates the branches; in an open region every branch terminates and polarity decides alone (BRANCH-019) |
| BRANCH-015 nested branches | `Layout.Bands` post-order recursion | `test_BRANCH_015_nested_region_centres_on_its_own_branch_axis`, `…_adds_no_horizontal_indentation` | complete |
| BRANCH-016 nesting-induced spacing | `Layout.Bands.stackLane` | golden pattern J | complete |
| BRANCH-017 loop regions | `Layout.Analysis`, `Layout.Bands.corridorOwners` | `test_EDGE_013_*` | complete |
| BRANCH-018 implicit merges | `Layout.Regions`, `Layout.Ports` | `nested gateways` corpus entry | complete |
| BRANCH-019 open regions | `Layout.Regions` (`rgOpen`), `Layout.Branches.terminatesAgainstPeers` | `multiple ends` and `a branch with mixed outcomes` corpus entries | complete — including the consequence for BRANCH-014: every branch of an open region terminates, so the property cannot decide sides there |
| BRANCH-020 symmetry classification | `Layout.Branches.peerSymmetricRegion` | `test_BRANCH_003_bbox_center_*` | complete |
| BRANCH-021 split after split | `Layout.Geometry.columnsFor`, `Layout.Bands` | `test_BRANCH_015_*` | complete |
| BRANCH-022 merge then split | `Layout.Geometry.columnsFor` | `test_LAYOUT_032_*` | complete |
| BRANCH-023 branches crossing lanes | `Layout.Bands.stackRegionUsing` (per-lane stacking) | `test_LANE_006_*`, `uneven lanes` corpus entry | complete |

## §G — pools and lanes

| Rule | Implementation | Tests | Status |
|---|---|---|---|
| LANE-001 pool geometry | `Layout.stackPools` | `test_LANE_012_*` | complete |
| LANE-002 lane tiling | `Layout.Geometry.laneTopsOf`, `Layout.Collision.growContainers` (shared width) | `test_HC_007_*`, `test_LANE_002_lanes_share_one_width_wide_enough_for_all_of_them` | complete |
| LANE-003 lane height | `Layout.Geometry.laneHeightOf`, `Layout.Collision.growContainers` (`reach`) | `test_LANE_003_lane_height_follows_content`, `test_LANE_003_a_lane_reaches_below_its_lowest_member` | complete |
| LANE-004 growth propagation | `Layout.Collision.growContainers` (re-tiling), `Layout.Geometry.columnsFor` (horizontal inset), `Layout.placeAllLabels` (`within`) | `test_HC_007_*`, `test_LANE_004_a_lane_insets_its_content_from_its_own_border` | complete — including the horizontal inset: the column grid starts at the lane's left border plus `CONTAINER_PAD_X`, and a node's caption is kept inside its own lane |
| LANE-005 lane ordering | `Language.Resolve.buildLanes` | `keeps lane order as written` | complete |
| LANE-006 lane spine | `Layout.Geometry.laneAxes` | `test_LANE_006_each_lane_has_its_own_spine` | complete |
| LANE-007 global column grid | `Layout.Geometry.columnsFor` | `test_LANE_009_*` | complete |
| LANE-008 per-lane bands | `Layout.Bands.stackRegionUsing` | `uneven lanes` corpus entry | complete |
| LANE-009 cross-lane progress | `Layout.Layering`, `Layout.Geometry` | `test_LANE_009_cross_lane_flow_makes_horizontal_progress` | complete |
| LANE-010 ping-pong staircase | `Layout.Routing.channelX` (identical jog geometry) | `test_EDGE_015_*` | partial — every transition uses the same gap-midpoint jog, which is the staircase normalisation; the alternation-count advisory is not emitted |
| LANE-011 nested lanes | `Bpmn.Semantic.Lane` (`laneChildren`) | — | not implemented — the model carries nesting; the DSL does not yet expose it |
| LANE-012 pool stacking | `Layout.stackPools` | `test_LANE_012_pools_share_a_width_and_a_left_edge` | complete |
| LANE-013 pool ordering | `Layout.stackPools` (input order) | — | partial — explicit user order is honoured, which is the first and highest-precedence clause; barycentre reordering is not implemented |
| LANE-014 black-box pools | `Layout.stackPools`, `Language.Resolve` | `parses a collaboration with a black-box pool` | complete |
| LANE-015 lane whitespace | `Layout.Geometry.laneHeightOf` | `test_LANE_003_*` | complete |

## §H — labels and artifacts

| Rule | Implementation | Tests | Status |
|---|---|---|---|
| LABEL-001 activity labels | `Layout.Labels.internalLabel` | `wrapping (LABEL-001)` group | complete |
| LABEL-002 gateway labels | `Layout.Labels.anchorLadder`, `externalLabelBox`, `Layout.placeAllLabels` | lane example score, `test_LABEL_003_an_external_label_is_measured_at_the_height_it_will_be_drawn` | complete — the box is measured at the height it will be drawn, so a caption needing more than two lines does not overflow onto the gateway |
| LABEL-003 event labels | `Layout.Labels.anchorLadder`, `externalLabelBox` | `test_LABEL_011_*`, `test_LABEL_003_a_caption_too_long_for_two_lines_keeps_all_of_them` | complete — as above: no line cap on the measured box |
| LABEL-004 boundary event labels | `Layout.Labels.anchorLadder` | golden pattern F, `test_LABEL_004_two_boundary_labels_on_one_host_stay_apart` | complete — the ladder carries the mirror, so two events one `BE_GAP` apart caption to opposite sides |
| LABEL-005 flow labels | `Layout.Labels.placeFlowLabel` (`anchorX`), `Layout.placeAllLabels` (`leftEdgeFor`, `inkReachRight`, `travelsRight`) | `test_LABEL_005_outgoing_labels_of_one_gateway_share_a_left_edge`, `test_LABEL_005_the_label_stack_clears_the_split_it_is_aligned_to`, `test_LABEL_005_a_backward_segment_anchors_the_label_at_its_own_start` | complete — including the clause that keeps the stack off the split's glyph: the shared `x` is `cx + 1U` raised until every label in the stack clears the diamond's ink |
| LABEL-006 collision fallback | `Layout.placeAllLabels` (`ladderWithRoom`, `firstFree`) | `labelCollision` score term, `test_LABEL_006_a_label_never_settles_on_a_connector`, corpus invariant | complete — with the documented variant: the ladder is retried a grid unit further out, up to `LABEL_PUSH_STEPS`, rather than the band gap being widened and phase 5 re-run |
| LABEL-007 default/conditional labels | `Language.Resolve`, `Camunda.Serialize` | `marks the default flow on the gateway that owns it` | complete |
| LABEL-008 pool and lane labels | `Camunda.Serialize`, `Layout.stackPools` | `test_LANE_012_*` | partial — the header band is reserved in the pool width; label wrapping inside the band is left to the modeller |
| LABEL-009 message-flow labels | `Layout.withMessageFlows` (`withMessageLabels`), `Camunda.Serialize` | `test_LABEL_009_a_message_flow_label_does_not_straddle_a_pool_border`, `emits participants and message flows` | complete — placed by the formatter after the message flows are routed, on the longest segment, and never straddling a pool border |
| LABEL-010 artifact labels | `Layout.placeArtifacts` (`sizeOf`), `Camunda.Serialize` | `test_LABEL_010_an_annotation_reserves_room_for_its_bracket`, `test_ART_001_*` | complete — the bracket band is reserved and the height is measured at the width the renderer is left with |
| LABEL-011 labels as geometry | `Layout.Types.Geometry`, `geometryBounds`, `Layout.Validate.label011` | `test_LABEL_011_labels_are_in_the_geometry`, `test_LABEL_011_no_label_lands_on_a_shape_it_does_not_name`, `test_LABEL_011_is_reported_rather_than_drawn` | complete — a residual overlap is a tier-1 violation and fails the build, so text over another element is an error rather than a score point |
| LABEL-012 text measurement | `Text.Metrics`, `Layout.Labels.wrappedBox` | whole of `MetricsSpec`, `test_LABEL_012_a_wrapped_label_reserves_the_width_it_was_wrapped_to` | complete — a wrapped label's box is as wide as `LABEL_MAX_W` and as tall as its wrapped text: the renderer breaks the name itself and need not agree with us about where, so the widest line we produced is not the width it occupies. The two-line figure is a design target, not a cap |
| ART-001 data object placement | `Layout.placeArtifacts` | `test_ART_001_data_objects_go_in_the_gutter_above_their_host` | complete |
| ART-002 multiple artifacts | `Layout.placeArtifacts` | `artifacts` corpus entry | complete |
| ART-003 association routing | `Layout.placeArtifacts` | `test_ART_003_association_is_a_zero_bend_vertical` | complete |
| ART-004 artifacts must not dominate | — | — | not implemented — a scoring term only, with no repair; omitted rather than reported without a remedy |
| ART-005 groups | `Layout.placeArtifacts` (`groupRects`), detector in `Layout.Validate` | `test_ART_005_a_group_is_its_members_bounding_box_plus_padding`, `test_ART_005_a_group_does_not_move_a_node` | complete |
| ART-006 text annotations | `Layout.placeArtifacts` (gutter choice) | `artifacts` corpus entry | complete |
| ART-007 artifact–corridor precedence | `Layout.Bands.branchExtent` (gutters before corridors) | `artifacts` corpus entry | complete |

## §I — anti-patterns

Implemented detectors, all in `Layout.Score.antiPatterns`, all asserted over the
corpus in `SpecRuleSpec`: `AP-001`, `AP-003`, `AP-005`, `AP-008`, `AP-010`,
`AP-011`, `AP-015`, `AP-016`, `AP-017`, `AP-021`.

Not implemented, with reasons: `AP-002` (subsumed by the port model, which
cannot produce a non-canonical fan), `AP-004`, `AP-007`, `AP-012`, `AP-013`,
`AP-014`, `AP-018`, `AP-019`, `AP-020`, `AP-022`, `AP-023`, `AP-024`, `AP-025` —
each is either structurally impossible given the band and column model, or
requires a repair the engine does not implement, and SPEC A8 says a rule without
a computable detector *and* a repair is advice rather than a rule.

## §J — the pipeline

All fourteen phases are present and are named in `Sequent.Layout`, in the order
§J gives, with the documented exception that P3's layering runs before P2 because
BRANCH-007's `span` component — which P2 needs — is defined in layers, and
layering depends only on the acyclic skeleton.

## §K — quality function and gates

`Layout.Score.scoreGeometry` implements every term of §K except the T0 and T5
groups: T0 terms are reported as violations rather than as `10^6` penalties (the
engine does not use a numeric solver, so an infinite penalty has nothing to feed),
and T5 instability is expressed as `Layout.Improve.stabilityCost` at the point
the decision is made. The gates — any T0 or T1 penalty, and any edge over six
bends — are enforced in `Sequent.Compiler` and tested by
`test_K_gate_no_tier0_or_tier1_violation_survives` and
`test_K_gate_no_edge_exceeds_six_bends`.

## §L — canonical examples

Patterns A–J are executable golden tests in `test/Sequent/GoldenSpec.hs`.
Pattern A is pinned to the exact coordinates SPEC.md prints; the rest are pinned
to the structural facts each pattern demonstrates (axis separation, bend counts,
side assignment, corridor placement, jog position, pool orientation, nesting).

## §N — conflicts and pathological cases

| Case | Resolution in this compiler |
|---|---|
| N-1 spine vs lane containment | `Layout.Score.spineBends` excludes lane-transition edges |
| N-2 axis lock vs symmetry | `Layout.Branches.chooseMode` and `peerSymmetricRegion` are disjoint by construction |
| N-3 branch starts vs compaction | compaction moves columns, never nodes (`Layout.Compact`) |
| N-4 exception band vs branch bands | exception bands are allocated outside all ordinary bands (`Layout.Bands.stackLane`) |
| N-5 corridors vs artifacts vs labels | artifact gutters are folded into the branch extent before corridors (`Layout.Bands.branchExtent`) |
| N-6 host growth vs width uniformity | `Layout.Score` excludes boundary-widened and subprocess activities from `sizeUniformity` |
| N-7 bundling vs overlap | one predicate implements both (`Layout.Validate` HC-009) |
| N-8 snapping vs symmetry | `ceilU` on the half-stack before centring (`Layout.Bands.stackLane`) |
| N-9 stability vs determinism | determinism is defined over `(SG, previousRG)`; `format` takes both |
| N-14 compaction vs channels | channel demand becomes a compaction constraint before compaction runs |
| N-15 repair loops | the repair ladder is monotone and capped at 8 iterations |
| N-18 lane sizing feedback | content heights are fixed in P5 and lane heights derived in P7; nothing feeds back |
| N-20 gateway port precedence | `Layout.Ports.sideTaken` implements the surplus rule |
