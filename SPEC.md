# BPMN Layout and Formatting Specification

**Version 1.0 :: implementation specification for an automatic BPMN 2.0 layout engine**

---

**Contents**

| § | Section |
|---|---|
| 0 | Three models: semantic graph, logical layout structure, rendered geometry |
| A | Design principles |
| B | Base geometry constants |
| 1 | Coordinate and layout model |
| 2 | Hierarchy of layout objectives and conflict resolution |
| C | Hard constraints (`HC-001…016`) |
| D | Structural layout rules (`LAYOUT-001…034`) |
| E | Connector routing rules (`EDGE-001…025`) |
| F | Branching rules (`BRANCH-001…023`) |
| G | Pool and lane rules (`LANE-001…015`) |
| H | Labels (`LABEL-001…012`) and artifacts (`ART-001…007`) |
| I | Anti-patterns (`AP-001…025`), edge cases, large-diagram behaviour |
| J | Layout algorithm (14 phases, pseudocode) |
| K | Diagram quality function |
| L | Canonical examples (patterns A–J, coordinates) |
| M | Machine-readable rule summary |
| N | Self-review: rule conflicts and pathological cases (`N-1…N-20`) |

---

Scope: geometry only. Semantic correctness of the process is assumed. The formatter receives a semantically complete BPMN graph and must produce or improve `x`, `y`, `width`, `height`, edge waypoints, lane/pool geometry, and label bounds.

---

## 0. Three models

The engine maintains three distinct representations. Every phase in §J declares which model it reads and which it writes.

| Model | Symbol | Contents | Mutable by |
|---|---|---|---|
| **Semantic graph** | `SG` | BPMN elements, sequence flows, message flows, associations, containment (process/lane/subprocess), flow conditions, default flows, boundary attachment. **Never modified by the formatter.** | nobody |
| **Logical layout structure** | `LLS` | Region tree (SESE decomposition), layer index per node, band (track) index per node, branch order, branch bounding boxes (in abstract units), port assignments, corridor assignments, dummy/virtual nodes, side classification (above/below/axis). | phases 1–7 |
| **Rendered geometry** | `RG` | Integer pixel `x,y,w,h`, orthogonal waypoint lists, label rectangles, lane/pool rectangles. | phases 6–12 |

Rules that reference "the branch" mean an `LLS` object; rules that reference "the bounding box" mean an `RG`-valued attribute of an `LLS` object. Two nodes may be adjacent in `SG`, three layers apart in `LLS`, and 400 px apart in `RG`! each statement is checked against its own model.

---

## A. Design Principles

**A1 :: Structure first, optimization second.** The layout is *derived* from a structural decomposition of the graph (regions, layers, bands), not searched for. Optimization (phase 14) only perturbs a structurally valid layout. This is what makes output predictable and repeatable. That means force-directed and pure-annealing approaches are rejected because they violate principle A9.

**A2 :: One spine.** Every process (and every expanded subprocess, and every lane) has exactly one horizontal visual spine at a constant `y`. The spine is a straight, bend-free line of nodes from entry to exit. Everything else is expressed as a displacement from the spine. A reader must be able to find "the story" of the diagram by following one straight line.

**A3 :: `x` means causality, `y` means role.** Horizontal position encodes progress in the process; it must be monotonically non-decreasing along any forward path. Vertical position encodes structural role (alternative, exception, loopback, artifact) and carries **no** temporal meaning.

**A4 :: Bands, not points.** Vertical placement is computed from complete branch bounding boxes including all descendants, exception tracks, loop corridors, artifacts and labels. A branch is never positioned from the coordinates of its first node.

**A5 :: Signed semantics of vertical displacement.** Above the spine = loopback/rework corridors and neutral or positive alternatives. Below the spine = negative alternatives, terminating branches, boundary-event exception handling. The rule is fixed so that the same construct always lands in the same place in every diagram the formatter produces.

**A6 :: Orthogonality and grid discipline.** All connectors are axis-parallel polylines. All shape centers lie on a `U`-grid. There is no such thing as "off by 3 px".

**A7 :: Lexicographic constraint tiers with weighted scoring inside a tier.** Hard constraints are never traded. Soft objectives inside a tier trade against each other through explicit weights (§K), so that questions like "is a wider diagram better than a crossing?" have numeric answers.

**A8 :: Every rule is a triple (predicate, detector, repair).** That implies that a rule with no computable detector is not a rule, it's simply advice, and is excluded from this document.

**A9 :: Determinism and stability.** Identical canonicalized input entails byte-identical output. Small input deltas then imply small geometric deltas (§LAYOUT-024).

**A10 :: Compactness is the last objective, never the first.** Whitespace is removed only where it is provably unused by nodes, corridors, labels or symmetry.

---

## B. Base Geometry Constants

The system is built on one base unit `U = 10 px`, chosen because the BPMN canonical sizes (task 100×80, gateway 50×50, event 36×36) are near-multiples of it, and because half of every derived gap (`BRANCH_GAP_Y/2 = 3U`, `TASK_H/2 = 4U`) remains an integer multiple of `U`. That property is what allows symmetric centering to land back on the grid without rounding drift. The only non-multiple, the 36 px event, is handled by snapping **centers** rather than corners (§LAYOUT-002).

### B.1 Element sizes

| Constant | Meaning | Value |
|---|---|---|
| `U` | base spacing unit | `10 px` |
| `GRID` | center snap grid | `U = 10` |
| `TASK_W` | standard activity width | `10U = 100` |
| `TASK_H` | standard activity height | `8U = 80` |
| `TASK_W_MAX` | max width from label growth | `16U = 160` |
| `TASK_H_MAX` | max height from label growth | `12U = 120` |
| `GW` | gateway bounding square | `5U = 50` |
| `EV` | event diameter | `3.6U = 36` |
| `SUB_COLLAPSED_W/H` | collapsed subprocess, call activity | `TASK_W × TASK_H` |
| `SUB_MIN_W/H` | expanded subprocess minimum | `24U × 16U = 240×160` |
| `DATA_W/H` | data object / data input / output | `3.6U × 5U = 36×50` |
| `STORE_W/H` | data store | `5U × 5U = 50×50` |
| `ANNOT_W_MIN/MAX` | text annotation | `10U / 20U = 100 / 200` |

### B.2 Spacing

| Constant | Meaning | Value |
|---|---|---|
| `NODE_GAP_X` | preferred gap between adjacent columns | `6U = 60` |
| `NODE_GAP_X_MIN` | absolute minimum column gap | `4U = 40` |
| `COMPACT_GAP` | gap when both neighbors have `w ≤ 5U` (event/gateway chains) | `4U = 40` |
| `FANOUT_GAP` | split gateway => first branch column | `max(NODE_GAP_X, maxOutLabelW + 2U)`, default `8U = 80` |
| `MERGE_GAP` | last branch node => merge gateway | `6U = 60` |
| `BRANCH_GAP_Y` | vertical gap between adjacent branch bounding boxes | `6U = 60` |
| `BRANCH_GAP_Y_MIN` | minimum, only under compaction pressure | `4U = 40` |
| `EXC_GAP_Y` | region bbox => exception (boundary-event) band | `5U = 50` |
| `LOOP_CLEAR` | region bbox => first loopback corridor | `3U = 30` |
| `CORRIDOR_PITCH` | spacing between parallel routing corridors | `2U = 20` |
| `EDGE_CLEAR` | min clearance, edge segment <=> non-incident node box | `1.5U = 15` |
| `EDGE_SEP` | min separation between parallel non-bundled edges | `1U = 10` (preferred `2U`) |
| `MIN_SEG` | min straight segment, incl. port stubs | `2U = 20` |
| `PORT_OFFSET_MIN` | spacing between offset ports on one side | `2U = 20` |
| `ARTIFACT_GAP` | activity <=> data object / annotation | `3U = 30` |
| `BE_GAP` | spacing between boundary events on one edge | `1U = 10` |
| `MARGIN` | diagram outer margin | `4U = 40` |

### B.3 Containers

| Constant | Meaning | Value |
|---|---|---|
| `CONTAINER_PAD_X` | left/right padding inside lane, pool, subprocess | `4U = 40` |
| `CONTAINER_PAD_Y` | top/bottom padding inside lane, pool, subprocess | `3U = 30` |
| `SUBPROC_PAD_BOTTOM` | extra bottom padding for markers | `+2U = +20` |
| `POOL_LABEL_BAND` | pool header band width (vertical text) | `3U = 30` |
| `LANE_LABEL_BAND` | lane header band width, per nesting level | `3U = 30` |
| `LANE_MIN_H` | minimum lane height (`TASK_H + 2·CONTAINER_PAD_Y`) | `14U = 140` |
| `POOL_GAP_Y` | vertical gap between pools | `6U = 60` |
| `BLACKBOX_H` | collapsed / black-box pool height | `6U = 60` |

### B.4 Text and labels

| Constant | Meaning | Value |
|---|---|---|
| `FONT_SIZE` | default label font | `12 px` |
| `LINE_H` | line height | `14 px` |
| `LABEL_PAD` | internal text padding inside shapes | `0.5U = 5` |
| `LABEL_GAP` | shape <=> external label | `0.5U = 5` |
| `LABEL_MAX_W` | external label max width | `9U = 90` |
| `LABEL_MAX_LINES` | external label lines a caption usually takes a design target, not a cap on the measured box (LABEL-012) | `2` |
| `TASK_MAX_LINES` | internal activity label max lines | `4` |
| `FLOW_LABEL_OFFSET` | flow label <=>  its segment | `0.5U = 5` |
| `LABEL_CLEAR` | label box <=> any other box or edge | `1U = 10` |
| `LABEL_PUSH_STEPS` | LABEL-006 outward retries, one `U` each | `8` |

### B.5 Tolerances

| Constant | Meaning | Value |
|---|---|---|
| `ALIGN_TOL` | "already aligned" tolerance; snap if below | `0.5U = 5` |
| `SYM_TOL` | branch-height difference tolerated as symmetric | `2U = 20` |
| `SPAN_TOL` | branch layer-span difference tolerated as symmetric | `1` layer |
| `IMBALANCE_TOL` | vertical imbalance triggering side rebalancing | `1` branch slot |
| `STRETCH_THRESHOLD` | slack (in columns) that triggers slack review | `3` |
| `DENSITY_LOW / HIGH` | sparse / cramped thresholds for region fill ratio | `0.08 / 0.40` |

### B.6 Derived formula reference

```
colGap(a,b)      = (w(a) ≤ 5U and w(b) ≤ 5U) ? COMPACT_GAP : NODE_GAP_X
axisSpacing(i)   = H[i]/2 + G[i] + H[i+1]/2          # distance between adjacent branch axes
stackHeight(n)   = Σ H[i] + Σ G[i]  (i=1..n, gaps i=1..n-1)
corridor(k)      = base ± (LOOP_CLEAR + k·CORRIDOR_PITCH)
snapCenter(c)    = round(c / U) · U                   # half-up, toward +∞
requiredHostW(k) = k·EV + (k+1)·BE_GAP                # k boundary events on one edge
laneH(L)         = max(LANE_MIN_H, contentH(L) + 2·CONTAINER_PAD_Y)
```

---

## 1. Coordinate and layout model

**1.1 Coordinate system.** Origin top-left, `x` right-positive, `y` **down**-positive (BPMN DI convention). All values are integers in pixels. No negative coordinates: after layout, the whole diagram is translated so that `min(x) = min(y) = MARGIN`.

**1.2 Primary flow direction.** Default **left-to-right (LR)**. Top-to-bottom (TB) is permitted only when one of the following holds, and then applies to the whole diagram:

- the pool's `isHorizontal` is `false` (vertical pool / vertical lanes);
- an explicit configuration flag `direction = TB`;
- the diagram is a pure linear chain (`maxOutDegree == 1`) with more than 30 nodes and the render target is declared portrait.

TB is implemented as a **transpose operator** `T: (x,y) -> (y,x)` applied to the LR result, with three exceptions that are not transposed: (a) text runs horizontally in both modes, (b) label anchors mirror rather than transpose (external labels stay below/right, never rotate), (c) lane bands remain perpendicular to the flow. Every rule in this document is written for LR; in TB read "above" as "left", "below" as "right", "column" as "row".

**1.3 Snapping.** Snap **centers**, not corners: `centerX, centerY ∈ U·ℤ`. For elements with even-multiple dimensions (task, gateway) this puts corners on the grid too; for 36 px events the corner lands on `…2` or `…8`, which is correct and intentional. Waypoints are snapped to `U·ℤ` in the coordinate perpendicular to their segment. Never snap after collision repair (snapping is the last geometric operation before scoring, phase 12).

**1.4 Canonical sizes** §B.1. Deviation from canonical size requires a rule that explicitly permits it (LAYOUT-029, LAYOUT-016, LAYOUT-019).

**1.5 Gaps.** Horizontal: `NODE_GAP_X` between column boundaries, reduced to `COMPACT_GAP` between two small nodes, increased to `FANOUT_GAP` after a split gateway with labelled outgoing flows. Vertical: `BRANCH_GAP_Y` between branch bounding boxes, `EXC_GAP_Y` before an exception band, `LOOP_CLEAR` before the first loop corridor.

**1.6 Clearances.** Edge <=> non-incident node: `EDGE_CLEAR`. Edge <=> edge (non-bundled, parallel): `EDGE_SEP`, corridors pitched at `CORRIDOR_PITCH`. Label ↔ anything: `LABEL_CLEAR`.

**1.7 Container padding.** `CONTAINER_PAD_X/Y` inside every lane, pool and expanded subprocess, measured from the inner edge of any label band.

**1.8 Diagram margin.** `MARGIN` on all four sides of the union of all rendered geometry including labels.

**Why these ratios cohere.** `NODE_GAP_X = 6U` is 60 % of `TASK_W`, which keeps the "object–gap–object" rhythm at roughly 5:3, dense enough to read as one chain, loose enough to insert an edge label. `BRANCH_GAP_Y = 6U` equals `NODE_GAP_X`, so branch separation reads as the same visual quantity as sequential separation, which makes 2-D scanning consistent. `BRANCH_GAP_Y = 0.75 · TASK_H` yields an axis-to-axis distance of `14U` for simple branches, comfortably more than one task height, so a branch never looks like it belongs to its neighbour. `EDGE_CLEAR = 1.5U` is just over one grid step, guaranteeing a visible white gap at 100 % zoom but not wasting a full grid cell. `CORRIDOR_PITCH = 2U` is the smallest pitch at which two parallel lines remain distinguishable at 50 % zoom.

---

## 2. Hierarchy of layout objectives

Objectives are grouped into **tiers**. Tiers are lexicographic: no amount of gain in a lower tier justifies any loss in a higher tier. Within a tier, objectives are traded through the weighted score of §K.

| Tier | Name | Objectives | Trading |
|---|---|---|---|
| **T0** | Validity | containment; no node overlap; no edge through a node; orthogonality; endpoints on ports; lanes tile their pool | none (infinite penalty) |
| **T1** | Semantics of position | forward flows progress rightward; layer order respects topological order; boundary events attached to their host; split/merge pairing preserved; branch contiguity (a branch's nodes occupy one contiguous band) | none (violation only to satisfy T0) |
| **T2** | Comprehension | spine straightness; crossings; edge-node proximity; bend count; branch ordering; corridor separation; label legibility | weighted |
| **T3** | Regularity | alignment; symmetry; gap uniformity; task size uniformity | weighted |
| **T4** | Economy | total area; edge length; whitespace reduction | weighted |
| **T5** | Stability | displacement from previous layout | weighted, but see LAYOUT-024 |

### 2.1 Answers to the standard trade-off questions

These are normative; they define the intended behaviour of the weights in §K.

- **Wider diagram vs a connector crossing?** Take the wider diagram. One sequence-flow crossing costs `W_cross = 40`; extra edge length costs `0.02` per `U`, area costs `W_area · (bboxArea/contentArea − 1)`. Removing one crossing justifies up to `~40U` of added width (400 px) on a mid-size diagram. *Exception:* if the widening pushes the diagram past `aspectRatio > 6.0`, accept the crossing instead (§28).
- **Break alignment vs a six-bend connector?** Break alignment. Alignment is T3, bends are T2. A bend beyond the pattern minimum costs `6`; a broken centerline alignment costs `2`. Six bends (≥ 24 excess) always beats one misalignment (2). *But* never break **spine** straightness (LAYOUT-007, STRONG) for bends: reroute or move the non-spine endpoint instead.
- **Asymmetry when branch complexity differs?** Yes. Symmetry is *conditional* (BRANCH-020): the symmetry penalty is only evaluated for regions classified peer-symmetric. A region with `|H_i − H_j| > SYM_TOL` or `|span_i − span_j| > SPAN_TOL` is not peer-symmetric and incurs zero symmetry penalty.
- **When is compactness sacrificed?** Whenever compaction would reduce any clearance below its `_MIN` constant, remove a routing corridor, cause a new crossing, or break spine straightness. Compaction (T4) may never win against T0–T2 and may only beat T3 when the recovered area exceeds `12U × 12U`.
- **Stability vs quality?** Reordering branches or changing a node's band during incremental layout is permitted only if it removes a T0/T1 violation, or reduces crossings by `≥ 2`, or reduces total score by `≥ 25`. Otherwise the previous structure is retained.

### 2.2 Conflict-resolution procedure

When two rules produce contradictory geometry for the same element:

1. Compare priority class: `HARD > STRONG > MEDIUM > WEAK`. Higher wins outright.
2. Same class → compare tier of the objective each rule serves. Lower tier number wins.
3. Same tier → compare **structural scope**: the rule owned by the *innermost* enclosing region wins (a nested branch's internal rule beats an outer alignment preference), except for container rules (LANE-*, LAYOUT-019), which always beat contained-content rules.
4. Still tied → apply both rules' repairs as constraints to the 1-D compaction solver (phase 11) and let the weighted score decide.
5. Still tied → the rule with the lower numeric ID wins. (Guarantees determinism.)

---

## C. Hard Constraints

Never violated. If a candidate layout violates one of these, it is not a layout; the phase that produced it must be re-run with the violated constraint added to its constraint set. All hard constraints are checked by `validate(RG)` after phases 10, 11 and 12.

| ID | Constraint | Detection | On failure |
|---|---|---|---|
| `HC-001` | Every sequence flow, message flow and association is an orthogonal polyline: for each consecutive waypoint pair, `x_i == x_{i+1}` or `y_i == y_{i+1}`. | segment scan | re-route (phase 8) |
| `HC-002` | No two non-containing, non-boundary node boxes overlap; clearance `≥ 2U` in at least one axis. | interval-tree sweep | push apart along the axis of smaller displacement; re-run compaction |
| `HC-003` | Every node lies fully inside its semantic container (lane, pool, expanded subprocess), inset by `≥ CONTAINER_PAD_*`. | rect containment | grow container, else move node |
| `HC-004` | No edge segment passes within `EDGE_CLEAR` of a node box it is not incident to. Two nodes get a **reduced clearance** rather than an exemption: a node's container, and the **host of a boundary event the edge is incident to** a boundary stub starts on that host's border, so it is inside `EDGE_CLEAR` before it has moved, and running close under the host on the way to the handler band is the canonical picture (EDGE-014). Neither may be *entered*: for those two the clearance is `0`, not infinite. | segment/rect intersection with inflation `EDGE_CLEAR`, or `0` for a container and for an incident boundary host | re-route; if no route exists, insert a corridor by increasing band spacing |
| `HC-005` | Every edge endpoint lies exactly on a declared port of its endpoint node, and the first/last segment is perpendicular to that side with length `≥ MIN_SEG` (relaxed to `≥ 1U` only for boundary-event stubs). | port table lookup | re-anchor |
| `HC-006` | A boundary event's center lies on its host's border; the event overlaps only its host. This is the sole exception to `HC-002`. | distance to host border `== 0` | re-attach per LAYOUT-016 |
| `HC-007` | Lanes tile their pool exactly: same `x` and `width` for all lanes at a nesting level, `Σ laneH == poolInnerH`, no gaps, no overlaps. | interval sum | recompute lane geometry (LANE-003) |
| `HC-008` | A sequence flow never leaves the pool of its process; a message flow always has endpoints in two different pools. | container lookup on endpoints | reject input as semantically invalid; do not attempt geometric repair |
| `HC-009` | No two distinct edges share a collinear overlapping sub-segment of length `> 0`, **unless** they are bundle siblings (EDGE-009: they share the same port on the same node and the overlap is contiguous with that port). | collinear segment overlap test | offset one edge to the next free corridor |
| `HC-010` | No waypoint list contains duplicate consecutive points or a collinear intermediate point. | waypoint simplify pass | remove degenerate points |
| `HC-011` | All coordinates are non-negative integers; all shape centers on the `U` grid **in the assembled diagram**, not only within each scope's own frame. A pool and an expanded subprocess each lay their contents out in a local frame and then translate it into place, so every such offset must be a whole number of grid units (LANE-012, LAYOUT-019). | modulo test over the merged geometry | translate / snap |
| `HC-012` | An activity's text never overflows its shape: `wrappedTextH ≤ h − 2·LABEL_PAD` and `wrappedTextW ≤ w − 2·LABEL_PAD`. | text measurement | apply LAYOUT-029 growth ladder |
| `HC-013` | No node overlaps a lane divider line or a pool border. | border-band intersection | move node into the lane interior |
| `HC-014` | An expanded subprocess fully contains all its children plus padding; nested containers are strictly nested. | rect containment, recursive | resize outward, bottom-up |
| `HC-015` | No edge crosses a pool boundary except message flows, and message flows cross pool boundaries perpendicularly. | boundary intersection angle | re-route |
| `HC-016` | The layout function is pure: `layout(canonicalize(SG)) ` is byte-identical across runs. | golden-file test | remove non-deterministic iteration (LAYOUT-027) |

---

## D. Structural Layout Rules

Template for every rule: **Priority** ∈ {HARD, STRONG, MEDIUM, WEAK}; **Applies when**; **Elements**; **Rule**; **Geometry**; **Rationale**; **Exceptions**; **Conflict**; **Detect**; **Repair**.

---

### LAYOUT-001 :: Primary flow direction
**Priority:** STRONG
**Applies when:** always, per diagram.
**Elements:** all.
**Rule:** The diagram has exactly one primary direction, LR by default. Every sequence flow that is not a back edge must satisfy `targetLeft ≥ sourceRight` i.e. non-decreasing `x` progress. Mixed-direction diagrams are prohibited.
**Geometry:** `∀ e=(u,v) ∈ E \ Back: x(v) − (x(u)+w(u)) ≥ 0`, and if `u,v` are in different lanes, `≥ NODE_GAP_X_MIN` (LANE-010).
**Rationale:** direction is the strongest single cue for reading order; violating it locally destroys global readability.
**Exceptions:** back edges (loopbacks, §BRANCH-017); message flows (direction-free); associations.
**Conflict:** beats compactness, symmetry, alignment. Yields only to HC-002/HC-003.
**Detect:** count edges with negative progress that are not classified as back edges.
**Repair:** re-run layering; if a genuine forward edge has negative progress, the layering is wrong, recompute layers with the edge's constraint added.

---

### LAYOUT-002 :: Grid and snapping
**Priority:** HARD (HC-011)
**Applies when:** at the end of geometry assignment (phase 12).
**Elements:** all shapes and waypoints.
**Rule:** shape centers snap to `U·ℤ`; waypoints snap in the axis perpendicular to the segment they lie on; snapping never moves a shape by more than `U/2`.
**Geometry:** `cx' = round(cx/U)·U`, `cy' = round(cy/U)·U`, half-up.
**Rationale:** eliminates the "off by 3 px" anti-pattern (AP-005) at zero cost.
**Exceptions:** none. Elements with odd dimensions (events) get non-grid corners by design.
**Conflict:** snapping is applied after all repairs; if snapping re-introduces an HC violation (possible for `EDGE_CLEAR` at exactly `1.5U`), the affected element is moved a full `U` away instead.
**Detect:** `cx mod U != 0`.
**Repair:** snap, then re-validate HC-002/HC-004 in the local neighbourhood only.

---

### LAYOUT-003 :: Canonical element sizes
**Priority:** STRONG
**Applies when:** always.
**Elements:** all.
**Rule:** all activities `100×80`; all gateways `50×50`; all events `36×36`; collapsed subprocess and call activity `100×80`. Size deviation is permitted only by LAYOUT-029 (label growth), LAYOUT-016 (boundary event fit) and LAYOUT-019 (expanded subprocess).
**Rationale:** uniform sizes make columns and alignment trivially computable and make size differences *meaningful* when they do occur.
**Exceptions:** the three named rules; user-pinned sizes with `preserveSize` flag.
**Conflict:** loses to HC-012 (text overflow) and LAYOUT-016.
**Detect:** `w != canonical(w)` without a permitting flag.
**Repair:** reset to canonical, then re-run the growth ladder.

---

### LAYOUT-004 :: Layer assignment (ASAP longest-path layering)
**Priority:** STRONG
**Applies when:** always, per process/subprocess scope.
**Elements:** all flow nodes.
**Rule:** remove back edges (phase 1), then assign `layer(v) = 0` for sources and `layer(v) = max_{u→v} (layer(u) + 1)` in topological order. This is ASAP (as-soon-as-possible) layering.
**Geometry:** `layer: V → ℕ`; column `c` contains `{v : layer(v) = c}`.
**Rationale:** ASAP produces exactly the three properties we want: (a) all branches of a split start in the same column (left-alignment, BRANCH-013); (b) a merge lands immediately after the longest branch; (c) an early-ending branch terminates as early as possible instead of stretching to the diagram's right edge (BRANCH-014).
**Exceptions:** `TERMINAL_ALIGN = COLUMN` mode places all end events of a process in one final column; off by default.
**Conflict:** if a lane constraint or a manual pin fixes a node's `x`, add `layer(v) ≥ k` as a constraint and re-run.
**Detect:** any edge `u→v` (non-back) with `layer(v) ≤ layer(u)`.
**Repair:** re-layer the affected weakly connected component.

---

### LAYOUT-005 :: Column geometry and x assignment
**Priority:** STRONG
**Applies when:** after layering.
**Elements:** all flow nodes.
**Rule:** each layer `c` becomes a column with `colW(c) = max{ w(v) : layer(v)=c }`. Nodes are **centered** within their column: `cx(v) = colCx(c)`. Column left edges follow:
**Geometry:**
```
colX(0)   = MARGIN
colCx(c)  = snapCenter(colX(c) + colW(c)/2)
colX(c+1) = colX(c) + colW(c) + gapBetween(c, c+1)
gapBetween(c,c+1) =
      FANOUT_GAP   if column c holds a split gateway with ≥2 outgoing branches
      MERGE_GAP    if column c+1 holds a merge gateway
      COMPACT_GAP  if max width in both columns ≤ 5U
      NODE_GAP_X   otherwise
```
**Rationale:** column centering makes gateways (50 wide) optically centered against tasks (100 wide) and keeps the vertical alignment tracks meaningful. Uniform column pitch is the single largest contributor to a "machine-formatted, deliberate" look.
**Exceptions:** cross-lane transitions may require additional horizontal progress (LANE-010) implemented as an increased gap, never as a node offset.
**Conflict:** beats compactness; loses to HC-004 when a corridor between two columns needs more width (then the gap grows).
**Detect:** `stdev(gaps)/mean(gaps) > 0.10` over the whole diagram, excluding fan-out and merge gaps.
**Repair:** recompute columns from scratch; never nudge individual nodes.

---

### LAYOUT-006 :: Spine identification
**Priority:** STRONG
**Applies when:** always, once per process/subprocess scope and once per lane segment.
**Elements:** flow nodes.
**Rule:** the spine is the unique path from the scope entry to the scope exit obtained by repeatedly selecting, at each split, the **rank-1 branch** under the BRANCH-007 ordering, and at each merge continuing on the merged path. Formally the spine is the sequence of nodes on the *dominator–post-dominator chain* (nodes that dominate and post-dominate the exit), extended through each split by its rank-1 branch.
**Geometry:** `spine = [n_0 … n_k]`, `spineY` = a single constant per scope.
**Rationale:** a diagram without an identified spine cannot have a stable baseline, and every vertical decision in §BRANCH depends on knowing which path keeps the axis.
**Exceptions:** for a scope whose entry has no dominator chain (multiple start events), pick the chain starting at the start event with the lowest `(documentOrder, id)`, and treat the other start events as branches merging into it.
**Conflict:** none: spine identification precedes all placement.
**Detect:** spine is empty or non-contiguous.
**Repair:** fall back to the longest path in the DAG (max layer span), ties by lowest total id-hash-free lexicographic id sequence.

---

### LAYOUT-007 :: Spine straightness
**Priority:** STRONG
**Applies when:** a spine exists in the scope.
**Elements:** spine nodes and the sequence flows between consecutive spine nodes.
**Rule:** all spine nodes share one `centerY`; every spine-to-spine sequence flow has **zero bends**.
**Geometry:** `∀ v ∈ spine: cy(v) = spineY`. For a lane-crossing spine, the spine is split into *lane segments*, each with its own `spineY = laneSpineY(L)` (LANE-008), and the crossing edge is the only bent spine edge (2 bends, EDGE-015).
**Rationale:** principle A2. A straight spine is the single most effective readability device in BPMN.
**Exceptions:** lane transitions; a spine node that is an expanded subprocess is centered on its own internal spine instead (LAYOUT-020).
**Conflict:** beats symmetry, compactness, alignment of non-spine elements, and bend minimization for non-spine edges. Loses only to HC-002/HC-003 and to lane containment.
**Detect:** `∃ v ∈ spine, |cy(v) − spineY| > 0` within one lane segment; or a spine edge with `|waypoints| > 2`.
**Repair:** set `cy(v) = spineY`; push the displaced content of the surrounding bands outward by the same delta (bands are re-stacked, not individually nudged).

---

### LAYOUT-008 :: Vertical centering of non-spine content
**Priority:** STRONG
**Applies when:** a region contains branches or nested regions.
**Elements:** branch bounding boxes.
**Rule:** every structural group is positioned as a **stack of bounding boxes** centered on its parent axis, using either `AXIS_LOCK` or `BBOX_CENTER` (BRANCH-008). Individual nodes are never positioned relative to each other vertically; only bounding boxes are.
**Geometry:** see BRANCH-002 / BRANCH-003.
**Rationale:** principle A4; prevents nested content from colliding with sibling branches.
**Exceptions:** none.
**Conflict:** loses to lane containment (LANE-009) which may clamp a stack.
**Detect:** any branch whose bbox overlaps a sibling branch's bbox.
**Repair:** recompute the stack bottom-up.

---

### LAYOUT-009 :: Virtual nodes for multi-layer edges
**Priority:** STRONG
**Applies when:** an edge spans more than one layer (`layer(v) − layer(u) > 1`).
**Elements:** sequence flows.
**Rule:** insert a chain of zero-width virtual nodes (`w=0, h=0`, but with a reserved corridor width of `CORRIDOR_PITCH`) in each intermediate layer. Virtual nodes participate in band assignment and crossing minimization exactly like real nodes.
**Geometry:** virtual node `d_c` at `(colCx(c), y)`; the edge route passes through all `d_c`.
**Rationale:** without dummies, long edges are invisible to the ordering heuristic and will be routed through nodes (HC-004) or produce unpredictable crossings.
**Exceptions:** back edges use corridors (EDGE-013) instead of dummies.
**Conflict:** dummy chains must stay inside their branch band; if the band is too narrow, the band grows.
**Detect:** an edge spanning `>1` layer with no dummy chain.
**Repair:** insert dummies and re-run phases 5–8 for the enclosing region.

---

### LAYOUT-010 :: Row wrapping (prohibited by default)
**Priority:** MEDIUM
**Applies when:** total diagram width exceeds `MAX_ROW_W` (default `320U = 3200 px`).
**Elements:** the whole scope.
**Rule:** geometric wrapping (serpentine layout) is **prohibited by default**. A long chain stays on one row. Two sanctioned remedies, in order: (1) advisory: report that the process should use link events or a subprocess; (2) if `WRAP_MODE = serpentine` is explicitly enabled, wrap only at a *cut vertex* of the flow graph that is not inside any region, using the canonical U-turn geometry below.
**Geometry (serpentine, only when enabled):** row `r` occupies `spineY + r·rowPitch`, `rowPitch = regionBBoxH + 8U`. The U-turn edge: exit `E` port → east `MIN_SEG` → south to the next row's `spineY` → west to `colX(0)` → east stub into the next node's `W` port (4 bends). Rows alternate direction **never**; all rows read left-to-right.
**Rationale:** serpentine layouts destroy the "x means causality" invariant (A3) and are almost always worse than horizontal scrolling. Link events are the BPMN-native solution.
**Exceptions:** printing pipelines that declare a fixed page width.
**Conflict:** if enabled, wrapping beats compactness and loses to region integrity (never wrap inside a split/merge region).
**Detect:** `diagramW > MAX_ROW_W`.
**Repair:** emit advisory; do not silently wrap.

---

### LAYOUT-011 :: Alignment tracks (invisible guides)
**Priority:** MEDIUM
**Applies when:** always.
**Elements:** all nodes.
**Rule:** the engine maintains two explicit sets of guides: **vertical guides** `Vg = { colCx(c) }` (one per column) and **horizontal guides** `Hg = { bandAxisY(b) }` (one per band). Every node's center must lie on exactly one guide of each set. No node has free coordinates.
**Geometry:** `cx(v) ∈ Vg ∧ cy(v) ∈ Hg`.
**Rationale:** converts "well aligned" into a decidable predicate and makes alignment repair a snap-to-guide operation rather than an optimization.
**Exceptions:** boundary events (attached to a host border); external labels; artifacts in gutters (they get their own derived guides).
**Conflict:** guides are recomputed, never violated; if a node cannot lie on a guide, a new guide is created and registered (which is how dynamic tracks appear, §26).
**Detect:** `cx(v) ∉ Vg ∨ cy(v) ∉ Hg`.
**Repair:** snap to nearest guide if within `2U`; otherwise create a guide and re-stack the band.

---

### LAYOUT-012 :: Center alignment across mixed sizes
**Priority:** STRONG
**Applies when:** two nodes of different sizes are adjacent in the flow or in the same band.
**Elements:** tasks (80 high), gateways (50), events (36), subprocesses (≥160).
**Rule:** align **centers**, never top edges, never bottom edges, never connection anchors independently. The center is the alignment datum for all vertical relationships and for column placement.
**Geometry:** `cy(u) = cy(v)` for flow-adjacent nodes in the same band; `cx` from LAYOUT-005.
**Rationale:** center alignment makes a `36`-high event and an `80`-high task connect with a zero-bend straight line, which top alignment cannot. It also makes the `E`/`W` ports collinear automatically.
**Exceptions:** an expanded subprocess on the spine aligns its **internal spine** to the outer spine (LAYOUT-020), which is generally not its box center.
**Conflict:** beats bbox-edge alignment aesthetics.
**Detect:** flow-adjacent same-band pair with `axisY(u) ≠ axisY(v)` and no lane change, the *axis*, which is the centre for every node but an expanded subprocess.
**Repair:** set both to `bandAxisY`.

---

### LAYOUT-013 :: Bands (visual tracks)
**Priority:** STRONG
**Applies when:** always.
**Elements:** all nodes, corridors, artifacts.
**Rule:** the vertical space of a scope is partitioned into **bands**, allocated in this fixed order outward from the spine:

| Order | Band class | Side | Allocated by |
|---|---|---|---|
| 0 | spine | axis | LAYOUT-006 |
| 1 | artifact gutter (data) | above, `ARTIFACT_GAP` | ART-001 |
| 1' | artifact gutter (annotations) | below, `ARTIFACT_GAP` | ART-006 |
| 2 | alternative branch bands | above and below, `BRANCH_GAP_Y` | BRANCH-003…006 |
| 3 | exception (boundary-event) band | below, `EXC_GAP_Y` beyond band 2 | LAYOUT-017 |
| 4 | loopback corridors | above, `LOOP_CLEAR + k·CORRIDOR_PITCH` beyond bands 1–2 | LAYOUT-018 |

Bands are allocated **per region**, recursively; a nested region's bands live inside its parent branch's bounding box.
**Geometry:** `bandAxisY(b)` computed by the stacking formula (BRANCH-002).
**Rationale:** fixes the semantics of vertical space so the same construct always appears in the same place (A5), and makes corridor allocation collision-free by construction.
**Exceptions:** if a region has no boundary events, band 3 is not allocated and band 4 moves inward. Bands are never reserved empty.
**Conflict:** artifact gutters are allocated *before* corridors so that a corridor never has to cross a data object; if an artifact would land in an already-allocated corridor, the corridor moves outward.
**Detect:** a node assigned to no band, or two bands with overlapping `y` ranges.
**Repair:** re-run band allocation for the region.

---

### LAYOUT-014 :: Events on the spine
**Priority:** STRONG
**Applies when:** start, intermediate, or end events are in the flow.
**Elements:** all event types.
**Rule:** events are ordinary layered nodes. `cy = bandAxisY` (center alignment, LAYOUT-012). The gap to an adjacent activity is `NODE_GAP_X`; the gap between two adjacent small nodes (event↔event, event↔gateway, gateway↔gateway) is `COMPACT_GAP`.
**Geometry:** start event is always the leftmost node of its scope (`layer 0`). No extra "breathing room" before an end event: the end event is a normal node at `NODE_GAP_X`.
**Rationale:** enlarging gaps around events makes small elements look unmoored; compacting chains of small elements keeps optical density constant (the ratio of ink to gap stays near 5:3 regardless of element size).
**Exceptions:** an intermediate **link** event pair used for flow continuation is laid out as a terminal (throw) and a source (catch) in separate rows; the catch starts at `colX(0)` of its row.
**Conflict:** none.
**Detect:** gap between two small nodes `> COMPACT_GAP + ALIGN_TOL`.
**Repair:** recompute column gaps.

---

### LAYOUT-015 :: Multiple end events
**Priority:** MEDIUM
**Applies when:** a scope has more than one end event.
**Elements:** end events.
**Rule:** end events terminate at their ASAP layer (LAYOUT-004), they do **not** get pushed to a common terminal column by default. Each end event sits on its own branch's axis.
**Rationale:** an end event that is dragged right to align with unrelated end events creates a long meaningless connector and implies the branch continues.
**Exceptions:** `TERMINAL_ALIGN = COLUMN` mode, used for compliance diagrams that must show a single termination column.
**Conflict:** loses to compaction (compaction may pull an end event left, never right).
**Detect:** end event whose incoming edge length `> 2 · (colW + NODE_GAP_X)` with no intervening content.
**Repair:** move the end event left to `layer(pred)+1`.

---

### LAYOUT-016 :: Boundary event attachment geometry
**Priority:** STRONG (attachment is HARD, HC-006; placement along the edge is STRONG)
**Applies when:** an activity has `k ≥ 1` boundary events.
**Elements:** boundary events, host activity.
**Rule:** boundary events attach to the host's **bottom edge** first, overflowing to the **top edge**, never to the left (entry) or right (exit) edge. Centers are distributed evenly along the edge.
**Geometry:**
```
requiredW = k·EV + (k+1)·BE_GAP                       # = 46k + 10
if requiredW > w(host):  w(host) = min(TASK_W_MAX, ceil(requiredW/(2U))·2U)
if requiredW > TASK_W_MAX:
    kBottom = floor((TASK_W_MAX − BE_GAP) / (EV + BE_GAP))
    place kBottom on the bottom edge, the remainder on the top edge
for j = 1..k on an edge:  cx_j = hostX + w(host)·j/(k+1),  cy_j = hostBottom (or hostTop)
snapCenter(cx_j)
```
**Attachment order along the edge (left → right):** sort boundary events by **descending handler-band distance**, the event whose exception path is routed *farthest* from the host goes leftmost. Ties broken by type priority `[error, escalation, cancel, conditional, timer, message, signal, compensation]`, then by `(documentOrder, id)`.
**Rationale:** the ordering rule is derived, not aesthetic: if a left event's handler band were *nearer* the host than a right event's band, the right event's downward stub would cross the left event's horizontal run. Assigning the farthest band to the leftmost event makes the whole exception fan crossing-free by construction.
**Exceptions:** non-interrupting events use the same geometry (the dashed border is a rendering difference only); a boundary event on an **expanded subprocess** attaches to the subprocess border and its handler band is allocated *outside* the subprocess.
**Band reservation (phase 5).** A host with boundary events claims, past the border they attach to, `EV/2 + LABEL_GAP + max(labelH)` over the events on that edge, the event *and* its caption. Reserving the event alone is what makes phase 9 hunt for room phase 5 never set aside, and the symptom is two boundary captions on top of each other (LABEL-004). The split between the bottom edge and the top-edge overflow is the same `kBottom` as above, so the band reserves on the side the events actually end up on.
**Conflict:** host widening beats task-width uniformity (LAYOUT-029, WEAK). Top-edge overflow beats loopback corridor placement (corridors shift outward).
**Detect:** overlapping boundary events; a boundary event on the `E` or `W` edge; a crossing between two exception stubs of the same host.
**Repair:** re-run the distribution formula and the band-order assignment.

---

### LAYOUT-017 :: Exception band
**Priority:** STRONG
**Applies when:** any boundary event exists in a region, or a branch is classified `exception` (BRANCH-007 polarity).
**Elements:** boundary events, exception handler nodes, error/escalation end events.
**Rule:** all exception handling content is placed in a dedicated band **below** every ordinary branch band of the enclosing region, separated by `EXC_GAP_Y`. Multiple exception paths stack downward at `BRANCH_GAP_Y`, ordered per LAYOUT-016.
**Geometry:**
```
excBand(0).top = regionBBox.bottom + EXC_GAP_Y
excBand(j).top = excBand(j-1).bottom + BRANCH_GAP_Y
handlerAxis(j) = excBand(j).top + H_j/2
```
**Rationale:** establishes the visual hierarchy of §16: `spine > alternative branch > exception path`, expressed as monotonically increasing distance from the spine. Exception content is thereby always skippable on a first read.
**Exceptions:** compensation handlers may be placed above if the below-region is occupied by a lane border within `EXC_GAP_Y` and the lane above is free, but then all exception paths of that host move above together (never split across sides).
**Conflict:** exception bands are included in the region bbox, so a parent's branch stacking automatically accounts for them.
**Detect:** an exception-classified node whose `cy` is between the spine and an ordinary branch band.
**Repair:** reassign the node's band and re-stack.

---

### LAYOUT-018 :: Loopback corridors
**Priority:** STRONG
**Applies when:** a back edge exists (target layer ≤ source layer).
**Elements:** back sequence flows.
**Rule:** back edges route **above** the spine, in dedicated corridors that never carry a node. Corridors are ordered so that a loop with a larger horizontal span gets a corridor farther from the spine, which makes nested loops non-crossing by construction.
**Geometry:**
```
span(l)     = x(source) − x(target)
sort loops by span descending → index k = 0,1,2…
corridorY(k)= regionBBox.top − LOOP_CLEAR − k·CORRIDOR_PITCH
```
Corridor allocation is per **region**: a loop entirely inside branch `B` uses `B`'s local bbox as the base, not the whole diagram's.
**Rationale:** backward flows must be unmistakable (they run in a reserved lane of their own) without polluting the forward reading zone.
**Exceptions:** if the loop's endpoints both lie in a band strictly below the spine and the region above them is a foreign branch, the corridor may be allocated below that band instead, decided per region, all-or-nothing.
**Conflict:** loop corridors are allocated after artifact gutters; corridors move outward, artifacts never move.
**Detect:** a back edge whose route enters the spine band or any node band.
**Repair:** re-run corridor allocation for the enclosing region; grow the region bbox upward by `CORRIDOR_PITCH`.

---

### LAYOUT-019 :: Expanded subprocess sizing
**Priority:** STRONG
**Applies when:** a subprocess is rendered expanded.
**Elements:** expanded subprocess, its children.
**Rule:** the subprocess is laid out by a **recursive invocation** of the full formatter on its internal scope, producing an internal bbox; the container is then sized to that bbox plus padding. Internal content is never squeezed to fit a predetermined container size.
**Geometry:** the container is measured about the child's **spine**, not about the middle of the child's bounding box, so that LAYOUT-020 can hang it from that spine without a second sizing pass, and it is then **centred on that spine**, by taking the larger of the two halves for both:
```
inner   = layout(childScope)                # own spine, own bands, own coordinate origin
above   = ceilU(inner.spineY − inner.top    + CONTAINER_PAD_Y)
below   = ceilU(inner.bottom  − inner.spineY + CONTAINER_PAD_Y + SUBPROC_PAD_BOTTOM)
half    = max(above, below, ceilU(SUB_MIN_H / 2))
w(sub)  = ceil2U(max(SUB_MIN_W, inner.w + 2·CONTAINER_PAD_X))
h(sub)  = 2·half
childOffset = (ceilU(subX + CONTAINER_PAD_X − inner.left), subY + half − inner.spineY)
```
Sizing the box tightly to `above + below` instead is correct and cheaper, and it reads wrong: the flow line meets a tall container a third of the way down, and the reader has to decide whether the box or the line is the thing that is misaligned. The cost of centring is paid in empty space on the lighter side, and it is a real cost, a subprocess whose exception handlers all hang below its spine pays their whole depth again above it.
`w` and `h` are both an **even** number of grid units, and the horizontal offset is a **whole** number of them. Without that, the container's own left and top edges land off the grid and every node inside it inherits the remainder: each scope validates clean in its own frame while the assembled diagram violates HC-011. The vertical offset needs no rounding, it is measured to a spine node's centre, which is on the grid already.

The subprocess then participates in the **outer** layout as a single node of size `w(sub) × h(sub)`, and per LAYOUT-020, as an **asymmetric** band extent `(above, below)` about its own axis rather than `(h/2, h/2)` about its centre.
**Rationale:** guarantees expanded subprocesses are never cramped (§20) and keeps the recursion clean: the outer layout never inspects inner nodes.
**Exceptions:** nested expansion deeper than 3 levels triggers an advisory to collapse; layout still proceeds.
**Conflict:** subprocess growth may dominate its column width and band height; both are recomputed, never clipped. If the subprocess exceeds its lane height, the lane grows (LANE-004).
**Detect:** `inner.bbox ⊄ innerArea(sub)` or padding `< CONTAINER_PAD_*`.
**Repair:** resize bottom-up (children → containers → lanes → pool), then re-run outer band stacking.

---

### LAYOUT-020 :: Subprocess spine continuity
**Priority:** MEDIUM
**Applies when:** an expanded subprocess lies on the outer spine.
**Elements:** expanded subprocess.
**Rule:** align the subprocess's **internal spine** with the outer spine, and centre the container's box on that same line, so that the outer spine, the inner spine and the container's vertical middle are one line. The container's **connection axis** is that internal spine: it is the `y` its band is stacked around (LAYOUT-019's `half`), the `y` its `W` and `E` ports sit at, and the `y` every rule that asks "are these two on the same line?" reads for it.

The axis is a distinct concept from the box centre even though LAYOUT-019's sizing makes them coincide. Two rules depend on the distinction, the lane clamp below, and any tightening of the container's height, and an implementation that reads the box centre instead is correct only for as long as the sizing rule holds.
**Geometry:** `y(sub) = outerSpineY − half`, with `half` from LAYOUT-019.
**Rationale:** a straight visual through-line across the container boundary is worth more than box-center symmetry. Centering the box instead makes the reader lose the flow exactly at the container border, which is the one place a diagram must not: the eye arrives at the left edge on the spine and the inner start event is somewhere else entirely.
**Exceptions:** if this places the subprocess outside its lane, revert to center alignment and clamp.
**Conflict:** beats LAYOUT-012 for this element specifically. It does **not** override HC-011: the axis lands on the grid, and `above`, `h/2` and the child offset are all whole grid units so that the box edges and the contents do too.
**Detect:** `|innerSpineAbsY − outerSpineY| > ALIGN_TOL` with no lane clamp active.
**Repair:** shift the subprocess vertically; re-stack the containing band.

---

### LAYOUT-021 :: Horizontal compaction
**Priority:** MEDIUM
**Applies when:** phase 11.
**Elements:** columns.
**Rule:** run a 1-D compaction on **columns**, not nodes. Column `c` may move left until the smallest of these binds: (a) `gapBetween(c−1,c) = NODE_GAP_X_MIN`; (b) an edge label between the columns needs `labelW + 2U`; (c) a vertical routing corridor between the columns needs `CORRIDOR_PITCH` per edge; (d) a fan-out or merge gap is at its minimum. Columns move as rigid units; a node never moves independently.
**Geometry:** constraint graph over column left edges, longest-path in the constraint DAG.
**Rationale:** node-wise compaction destroys column alignment, which costs more than it saves.
**Exceptions:** none.
**Conflict:** loses to every T0–T2 constraint; may not create a crossing or reduce a clearance.
**Detect:** an empty vertical strip of width `> 2·NODE_GAP_X` spanning the full content height and containing no label or corridor.
**Repair:** re-run compaction with the strip's constraints.

---

### LAYOUT-022 :: Vertical compaction
**Priority:** MEDIUM
**Applies when:** phase 11.
**Elements:** bands.
**Rule:** identical to LAYOUT-021 but over **bands**. A band may move toward the spine until `BRANCH_GAP_Y_MIN`, a corridor allocation, an artifact gutter, or a lane border binds. Bands move as rigid units.
**Additional rule (band collapse):** if band `b` is empty over the entire `x`-range of a sub-interval, that band's height is not reserved in that interval but the band's **axis** is still a single `y` (no piecewise bands; a band never bends).
**Rationale:** vertical sprawl is the dominant failure mode of naive BPMN layout, but piecewise bands look like errors.
**Exceptions:** peer-symmetric regions may not be compacted asymmetrically (see conflict).
**Conflict:** if compaction would break `symmetryDefect ≤ 0.15` in a peer-symmetric region, apply the same compaction delta to the mirrored band or skip both.
**Detect:** `gap(b, b+1) > BRANCH_GAP_Y` with no corridor, artifact or label occupying the gap.
**Repair:** re-run band compaction for the region.

---

### LAYOUT-023 :: Whitespace quality
**Priority:** WEAK (measurement) / MEDIUM (cramped detection)
**Applies when:** phase 13.
**Elements:** regions.
**Rule:** for each region compute the fill ratio `ρ = Σ nodeArea / bboxArea`. Classify: `ρ > DENSITY_HIGH (0.40)` = cramped; `0.12 ≤ ρ ≤ 0.35` = balanced; `ρ < DENSITY_LOW (0.08)` with `≥ 3` nodes = sparse. Additionally compute **gap uniformity** `CV = stdev(gaps)/mean(gaps)`; require `CV ≤ 0.10` for column gaps and `≤ 0.15` for band gaps within a region.
**Rationale:** turns "balanced" and "cramped" into decidable predicates.
**Exceptions:** regions with a single node are exempt; regions containing an expanded subprocess use the subprocess box as node area.
**Conflict:** sparse regions trigger compaction (LAYOUT-021/022) only; cramped regions trigger gap increase which beats compaction.
**Detect:** as above, plus: a maximal empty axis-aligned rectangle inside the content bbox with `w ≥ 3·NODE_GAP_X` and `h ≥ 2·TASK_H` that carries no corridor or label.
**Repair:** sparse → compaction; cramped → increase the binding gap by `1U` and re-run compaction.

---

### LAYOUT-024 :: Stability under incremental change
**Priority:** MEDIUM
**Applies when:** a previous layout `RG₀` exists for a graph `SG₀` and the new graph `SG₁` differs.
**Elements:** all.
**Rule:** compute the smallest enclosing region `R*` containing every changed element; re-layout only `R*`; translate everything to the right of `R*` by `Δx = w(R*₁) − w(R*₀)` and re-stack only the bands of ancestors of `R*` whose height changed. Preserve, in order of decreasing stickiness: (1) manual pins; (2) branch order; (3) band side assignment (above/below); (4) lane order; (5) column index.
**Displacement cost function:**
```
D = Σ_v  ω(v) · (|Δcx(v)| + |Δcy(v)|)/U
  + Σ_v  ω(v) · SIDE_FLIP · [side(v) changed]         SIDE_FLIP = 40
  + Σ_r  BRANCH_REORDER · [branch order of r changed] BRANCH_REORDER = 30
  + Σ_L  LANE_REORDER · [lane order changed]          LANE_REORDER  = 80
ω(v) = 8 if v is user-pinned, 3 if v is on the spine, 1 otherwise
```
A structural change (reorder, side flip) is accepted only if it reduces the §K score by more than its `D` contribution.
**Rationale:** the single most common complaint about auto-layout is that adding one task rearranges the diagram. Structural stickiness, not coordinate stickiness, is what users actually perceive.
**Exceptions:** a full re-layout is forced when `|changed| / |V| > 0.5`, or when a HARD constraint cannot be satisfied incrementally.
**Conflict:** stability is T5 and yields to everything above it, but the *threshold* mechanism means it wins all near-ties.
**Detect:** `D > 6·|changedNodes|` after an incremental run.
**Repair:** re-run incremental layout with structural changes forbidden; if that fails a HARD constraint, allow the smallest set of structural changes ordered by `D`.

---

### LAYOUT-025 :: Manual pins
**Priority:** STRONG (pin honoured) / yields to HARD
**Applies when:** a node carries `layoutPinned = true` (or the caller supplies a pin set).
**Elements:** any node.
**Rule:** a pinned node keeps its `x`, `y` and size. Its column and band are created around it: `colCx` is forced to the pin's `cx`, `bandAxisY` to its `cy`. Non-pinned nodes flow around it.
**Rationale:** allows human refinement to survive re-formatting, which is the difference between a usable and an unusable formatter.
**Exceptions:** a pin that violates a HARD constraint is broken, and the violation is reported with the pin's id.
**Conflict:** if two pins imply contradictory column order (`cx(u) > cx(v)` for a forward edge `u→v`), the pin on the node with lower `(documentOrder, id)` is honoured and the other is broken.
**Detect:** `pin.pos ≠ result.pos`.
**Repair:** report broken pins; never silently drop them.

---

### LAYOUT-026 :: Symmetry preference (global)
**Priority:** WEAK
**Applies when:** a region is classified peer-symmetric (BRANCH-020).
**Elements:** branch stacks, split/merge pairs.
**Rule:** maximize mirror symmetry about the region axis, measured as `symmetryDefect = |upExtent − downExtent| / (upExtent + downExtent)`; target `≤ 0.15`.
**Rationale:** symmetry conveys "these branches are peers"; forced symmetry between non-peers conveys a false equivalence and wastes space.
**Exceptions:** never force symmetry when `|H_i − H_j| > SYM_TOL` or `|span_i − span_j| > SPAN_TOL`, or when one branch is exception-classified.
**Conflict:** loses to everything except area.
**Detect:** `symmetryDefect > 0.15` on a peer-symmetric region.
**Repair:** re-center the stack in `BBOX_CENTER` mode; if branch heights differ, pad the shorter side's gap by `(H_max − H_min)/2`m padding gaps, never stretching content.

---

### LAYOUT-027 :: Determinism
**Priority:** HARD (HC-016)
**Applies when:** always.
**Elements:** all.
**Rule:** (1) canonicalize the input: sort all node and edge collections by `(documentOrder, id)` before any traversal; (2) all iteration is over sorted arrays, hash maps may store but never order; (3) all tie-breaks terminate in a total order (`id` lexicographic by Unicode code point); (4) all arithmetic on integers after snapping; rounding is half-up toward `+∞`; (5) heuristics with iteration counts use fixed counts, never time limits or convergence-on-epsilon.
**Rationale:** required for diffable output, golden-file tests, and user trust.
**Detect:** run layout twice with shuffled input collections; compare serialized output.
**Repair:** locate the unsorted iteration.

---

### LAYOUT-028 :: Large-diagram mode
**Priority:** MEDIUM
**Applies when:** any of: `|V| > 150`; `maxLayer > 40`; `lanes > 8`; `maxBranchFactor > 6`; density `|E|/|V| > 1.8`.
**Elements:** all.
**Rule:** switch to large mode, which changes exactly five things:
1. **Spacing increases, not decreases:** `NODE_GAP_X → 7U`, `BRANCH_GAP_Y → 8U`. Crowded large diagrams are unreadable; slightly sparser ones remain navigable.
2. **Modularity first:** every SESE region with `≥ 8` nodes is laid out as an independent unit with its own bbox and a `2U` reserved halo, so regions read as blocks.
3. **Layering stability beats symmetry:** disable `LAYOUT-026` (symmetry penalty weight → 0) and `BBOX_CENTER`; use `AXIS_LOCK` everywhere.
4. **More routing corridors:** allow up to `4` corridors per inter-column gap (default `2`) before widening.
5. **Bounded optimization:** phase 14 gets a fixed budget of `2·|regions|` candidate moves, evaluated in deterministic order.
**Rationale:** at scale, comprehension comes from chunking, not from local prettiness.
**Detect:** thresholds above.
**Repair:** n/a (mode switch).

---

### LAYOUT-029 :: Activity size and label growth ladder
**Priority:** MEDIUM (uniformity is WEAK; overflow prevention is HARD via HC-012)
**Applies when:** an activity's label does not fit at canonical size.
**Elements:** tasks of all types, call activities, collapsed subprocesses.
**Rule:** all activities are `100×80` unless the ladder below forces growth. Apply in strict order and stop at the first step that fits:
```
1. wrap text to w − 2·LABEL_PAD (=90 px), ≤ TASK_MAX_LINES (4) lines   → fits? stop
2. widen in 2U steps to TASK_W_MAX (160), re-wrapping each step        → fits? stop
3. heighten in 2U steps to TASK_H_MAX (120)                            → fits? stop
4. truncate with an ellipsis and emit an advisory
```
Task **type** (user/service/manual/business-rule/script/send/receive) never affects size; the marker occupies the top-left `20×20` and reduces the usable text box by `LABEL_PAD` only when the label reaches line 1's left edge, implement as a `16 px` first-line indent.
**Rationale:** width uniformity is worth preserving because column widths derive from it, but unreadable truncated labels are worse. Widening before heightening keeps center alignment and band heights untouched, which is the cheaper deformation.
**Exceptions:** LAYOUT-016 may widen a host beyond what the label requires. Call activities keep their thick border inside the same box.
**Conflict:** growth widens the column (LAYOUT-005), which is absorbed by column recomputation, not by moving neighbours individually.
**Detect:** HC-012 test; or `w != TASK_W` with a label that fits at `TASK_W`.
**Repair:** reset to `100×80` and re-run the ladder.

---

### LAYOUT-030 :: Marker and decoration clearance
**Priority:** WEAK
**Applies when:** an element carries markers (multi-instance, loop, compensation, ad-hoc, subprocess `+`).
**Elements:** activities, subprocesses.
**Rule:** reserve a `20 px` band at the bottom-center of the activity for markers; the wrapped text box is `h − 2·LABEL_PAD − 20` when markers are present. Never let a marker overlap text or a boundary event: if a boundary event's center falls within `EV/2 + BE_GAP` of the marker band's center, shift the boundary distribution by half a slot.
**Detect:** marker rect ∩ text rect ≠ ∅, or marker rect ∩ boundary event ≠ ∅.
**Repair:** reduce text box height (which may trigger LAYOUT-029 step 3).

---

### LAYOUT-031 :: Diagram bounds and margin
**Priority:** STRONG
**Applies when:** at the end of layout.
**Elements:** the diagram.
**Rule:** compute the union of all rendered geometry **including external labels and edge waypoints**; translate so the union's top-left is at `(MARGIN, MARGIN)`.
**Geometry:** `Δ = (MARGIN − minX, MARGIN − minY)` applied to every coordinate.
**Detect:** `minX ≠ MARGIN ∨ minY ≠ MARGIN`.
**Repair:** translate.

---

### LAYOUT-032 :: Gateway chains
**Priority:** MEDIUM
**Applies when:** two gateways are flow-adjacent (`gw → gw`), including merge-immediately-followed-by-split.
**Elements:** gateways.
**Rule:** adjacent gateways occupy consecutive columns with `COMPACT_GAP` between them and share `cy` (both on the region axis). A **merge→split** pair is a single structural unit: the merge closes the incoming region and the split opens a new one; the split's fan-out gap applies to *its* successors, not to the merge.
Do **not** collapse or merge gateways (that is a semantic change). Do **not** insert extra space to "explain" the pair.
**Rationale:** `40 px` between two 50-px diamonds reads as one decision cluster, which matches the semantics; `NODE_GAP_X` makes them look unrelated.
**Exceptions:** if the merge has ≥3 incoming and the split has ≥3 outgoing, increase the gap to `NODE_GAP_X` so incoming and outgoing fans do not visually merge into one comb.
**Conflict:** none.
**Detect:** gateway-adjacent pair with `gap ≠ COMPACT_GAP` (or `NODE_GAP_X` under the exception) or `cy` differing.
**Repair:** re-run column gaps and set both to the region axis.

---

### LAYOUT-033 :: Unstructured residue
**Priority:** STRONG
**Applies when:** region decomposition fails to produce a SESE region for part of the graph (branches sharing nodes, crossing dependencies, multiple entries into a branch interior, irreducible loops).
**Elements:** the residual subgraph.
**Rule:** mark the maximal residual subgraph `R_u` as **unstructured** and lay it out with the fallback pipeline: layered Sugiyama (layering already done), ordering by weighted median with 4 sweeps, then straight-line-preferring orthogonal routing. Inside `R_u`: bands are not reserved by role; the spine is the dominator path only; symmetry is disabled; crossings are minimized numerically rather than by construction. `R_u` is then treated by the outer layout as **one opaque block** with a bbox and a halo of `2U`.
**Rationale:** attempting to force structured geometry on an unstructured graph produces the worst layouts of all. Isolating the damage is the correct strategy.
**Exceptions:** none.
**Conflict:** rules that assume a region tree (BRANCH-002…016) are simply not evaluated inside `R_u`.
**Detect:** post-dominator-based region construction returns overlapping, non-nested regions.
**Repair:** n/a (this is itself the fallback).

---

### LAYOUT-034 :: Multiple start events / disconnected components
**Priority:** MEDIUM
**Applies when:** a scope has several start events or several weakly connected components.
**Elements:** components.
**Rule:** each weakly connected component is laid out independently, then stacked vertically in order of `(minLayer, documentOrder, id)` with `2·BRANCH_GAP_Y` between component bboxes, all left-aligned at `colX(0)`. Multiple start events feeding one component are treated as branches of a virtual split placed before layer 0 and are stacked per BRANCH-003…006 (the rank-1 start event holds the axis).
**Rationale:** components must not interleave; left alignment makes their independence obvious.
**Detect:** two components with overlapping bboxes or different left edges.
**Repair:** re-stack.

---

## E. Connector Routing Rules

### EDGE-001 :: Orthogonality
**Priority:** HARD (HC-001)
**Rule:** every segment is axis-parallel. Diagonals are prohibited for sequence flows, message flows and associations without exception. Corner style: sharp 90° by default; optional `cornerRadius = 0.5U = 5` applied at render time only, bend *positions* are unaffected by radius.
**Detect:** any segment with `Δx ≠ 0 ∧ Δy ≠ 0`.
**Repair:** replace the segment with an L or Z per EDGE-005/EDGE-015.

---

### EDGE-002 :: Port model
**Priority:** STRONG
**Applies when:** always.
**Rule:** every node exposes ports on the midpoints of its four sides: `N, E, S, W`. The `W` and `E` midpoints are measured from the node's **connection axis**, which is its box centre for every node except an expanded subprocess, whose axis is its internal spine (LAYOUT-020) relocating those two midpoints onto the spine is not an offset port and is not subject to the `k ≤ 2` cap below. Additional **offset ports** are allowed only on activities and expanded subprocesses, at `±k·PORT_OFFSET_MIN` from the side midpoint, `k ≤ 2`, never closer than `2U` to a corner; on a container they are symmetric about the axis, so a whole fan enters level with the flow line it continues.

Offsets are assigned **from the axis outward, on the side the other endpoint is actually on**: an edge whose far end is level with the node keeps the midpoint, and the rest step outward past it in order of distance. Handing them out by position in a sorted list gives the midpoint to whichever edge sorted first, which for a two-way implicit split is the branch that jogs away, the branch that continues the flow is then left leaving `PORT_OFFSET_MIN` off its own axis, phase 12 straightens it back onto the axis, and the endpoint is off its declared port (HC-005) and on its sibling's line (HC-009). Gateways and events expose **only** the four midpoints (the diamond and circle geometry makes offset attachment look like an error).
**Default port usage:** forward flow `W` in, `E` out. Branch fan-out: `N`/`S`. Merge fan-in: `N`/`S`. Loopback: out `N`, in `N` (or both `S` when the corridor is below). Boundary event: out `S` (or `N` if attached to the top edge). Message flow: `S`/`N` toward the other pool.
**Offset port assignment order:** when `m ≥ 2` edges use the same side of an activity, order them by the perpendicular coordinate of their other endpoint (ascending), and assign offsets in the same order. This makes same-side fans crossing-free.
**Detect:** an endpoint not on a declared port; a gateway/event endpoint off a midpoint; two edges on the same offset port.
**Repair:** re-anchor per the default table, then re-run offset assignment.

---

### EDGE-003 :: Straight-through preference
**Priority:** STRONG
**Applies when:** source and target centers are collinear in the flow axis.
**Rule:** if `cy(u) == cy(v)` (LR), the route is exactly two waypoints: `E` port of `u` → `W` port of `v`. Zero bends. No exceptions, no "aesthetic" jogs, no midpoint routing.
**Detect:** `cy(u)==cy(v)` and `|waypoints| > 2`.
**Repair:** replace with the 2-point route; if it now violates HC-004, the *nodes* are misplaced, re-run band assignment, do not bend the edge.

---

### EDGE-004 :: Stub rule
**Priority:** HARD (HC-005)
**Rule:** the first and last segments are perpendicular to their port's side, with length `≥ MIN_SEG (2U)`. Boundary-event stubs may be `≥ 1U`.
**Rationale:** a bend immediately at a shape border is illegible and hides the arrowhead direction.
**Detect:** first/last segment length `< MIN_SEG`.
**Repair:** extend the stub and move the first bend outward; if that collides, allocate the next corridor.

---

### EDGE-005 :: Canonical fan-out (split)
**Priority:** STRONG
**Applies when:** a gateway (or activity) has `≥ 2` outgoing sequence flows.
**Rule:** the canonical split route is the **comb**: an axis branch leaves straight east; every other branch leaves through the `N` or `S` port, runs vertically to its branch axis, then east into the target's `W` port. Exactly **1 bend** per non-axis branch, **0** for the axis branch.
**Geometry:** for gateway `g` at `(gx, gy)`, branch `i` with axis `y_i` and first node left edge `x_i`:
```
axis branch  : [(gx+GW/2, gy), (x_i, gy)]
upper branch : [(gx, gy−GW/2), (gx, y_i), (x_i, y_i)]        y_i < gy
lower branch : [(gx, gy+GW/2), (gx, y_i), (x_i, y_i)]        y_i > gy
require x_i − gx ≥ GW/2 + MIN_SEG   (guaranteed by FANOUT_GAP ≥ 6U)
```
The vertical segments of same-side siblings are **bundle-collinear at `x = gx`** and are legal under EDGE-009 because they share the same port. The result reads as one trunk with teeth, which is the standard and most compact split idiom.
**Rationale:** alternatives (fan corridors with distinct turn-`x`) cost 2 bends per branch and a wider fan-out gap, and produce a "staircase of stubs" that is harder to scan than a comb.
**Exceptions:** if a branch's first node is a **collapsed subprocess wider than the fan-out gap**, or the trunk would pass within `EDGE_CLEAR` of an artifact in the gutter, switch that single branch to the 2-bend fan-corridor form: `E` port → east to `gx + GW/2 + MIN_SEG + j·CORRIDOR_PITCH` → vertical → east.
**Conflict:** the comb requires that no node occupies the vertical strip `[gx − EDGE_CLEAR, gx + EDGE_CLEAR]` between the spine and the outermost branch axis. This strip is reserved by band allocation (LAYOUT-013) and must be enforced by phase 10.
**Detect:** split edge with `> 1` bend and no exception flag; or a node intersecting the trunk strip.
**Repair:** re-route to the comb; if blocked, move the blocking node one column right (it belongs to a different band by construction, so this is always possible).

---

### EDGE-006 :: Canonical fan-in (merge)
**Priority:** STRONG
**Applies when:** a gateway or activity has `≥ 2` incoming sequence flows.
**Rule:** mirror of EDGE-005. Each non-axis branch runs east along its own axis to `x = mx` (the merge node's center `x`), then turns vertically into the merge's `N` or `S` port. The axis branch enters `W` straight. 1 bend per non-axis branch.
**Geometry:**
```
axis branch  : [(xEnd_i, my), (mx−GW/2, my)]
upper branch : [(xEnd_i, y_i), (mx, y_i), (mx, my−GW/2)]
lower branch : [(xEnd_i, y_i), (mx, y_i), (mx, my+GW/2)]
require mx − xEnd_i ≥ MIN_SEG   (guaranteed by MERGE_GAP)
```
**Bundling:** incoming verticals share the `N` (or `S`) port and are bundle-collinear at `x = mx`; legal under EDGE-009.
**Exceptions:** for an **activity** with `≥ 2` incoming flows and no merge gateway, do not bundle into one port: use offset `W` ports (EDGE-002), max 3; for `> 3` incoming, insert a *junction dummy* at `(x(v) − MERGE_GAP/2, cy(v))` where all edges bundle, and route a single segment into the `W` port. (This is rendered as several edges terminating at the same point, which BPMN readers interpret correctly.)
**Detect:** merge edge with `> 1` bend; or a fan-in entering an activity at more than 3 distinct points.
**Repair:** re-route; reassign ports.

---

### EDGE-007 :: Bend budget
**Priority:** MEDIUM
**Rule:** each edge class has a **maximum bend count**; exceeding it is a violation, not a preference.

| Edge class | Max bends | Canonical |
|---|---|---|
| same-band sequential | 0 | straight |
| split branch (comb) | 1 | EDGE-005 |
| merge branch (comb) | 1 | EDGE-006 |
| cross-lane forward | 2 | Z (EDGE-015) |
| loopback | 2 | EDGE-013 |
| boundary exception | 2 | EDGE-014 |
| message flow | 2 | EDGE-016 |
| association | 1 | ART-003 |
| edge inside unstructured residue | 4 | fallback |
| absolute maximum, any edge | 6 | — |

**Rationale:** a fixed budget converts "minimize bends" into a checkable constraint and exposes layout errors: an edge that *needs* 4 bends almost always indicates a wrong band or column assignment upstream.
**Detect:** `bends(e) > budget(class(e))`.
**Repair:** first attempt re-routing; if the budget is still exceeded, **treat it as a placement error** and re-run band assignment for the enclosing region. Only if that fails, accept the route and record the penalty.

---

### EDGE-008 :: Corridors and channels
**Priority:** STRONG
**Rule:** routable space is modelled explicitly, not searched freely.
- **Vertical channels** live in the gap between two adjacent columns, at `x = colX(c)+colW(c) + j·CORRIDOR_PITCH + EDGE_CLEAR`, `j = 0,1,2…`. Max `2` channels per gap (`4` in large mode) before the gap widens.
- **Horizontal channels** live in the gap between two adjacent bands, at `y = bandBottom(b) + EDGE_CLEAR + j·CORRIDOR_PITCH`.
- **Trunk channels** are the bundle lines at a split/merge node's center `x` (EDGE-005/006).
- **Loop corridors** are horizontal channels outside the region bbox (LAYOUT-018).
Every non-straight edge is assigned specific channels before routing; routing then reduces to connecting ports through assigned channels.
**Channel assignment order:** deterministic, edges sorted by `(sourceLayer, sourceBandIndex, targetBandIndex, id)`; each takes the lowest-index free channel that does not create a crossing with an already-assigned edge sharing the same gap.
**Detect:** an edge segment not lying in a declared channel (excluding stubs and same-band straight runs).
**Repair:** assign a channel; widen the gap if none is free.

---

### EDGE-009 :: Bundling vs prohibited overlap
**Priority:** HARD (HC-009)
**Rule:** two distinct edges may share a collinear sub-segment **only if** (a) they share a port on a common endpoint node, and (b) the shared sub-segment is contiguous with that shared port. This is *bundling* and is legal. Every other collinear overlap is prohibited.
**Rationale:** at a shared port the multiplicity is recoverable from the visible teeth of the comb; elsewhere it is not, and an overlap becomes indistinguishable from a single edge (the worst possible ambiguity).
**Detect:** for each pair of parallel segments with `distance == 0` and overlapping projection, test the shared-port condition.
**Repair:** move one edge to the next channel (`+CORRIDOR_PITCH`); if no channel is free, widen the gap.

---

### EDGE-010 :: Crossing minimization by construction
**Priority:** MEDIUM
**Rule:** crossings are prevented structurally, in this order, before any numeric minimization:
1. **Band ordering:** branches are ordered so their targets' bands are monotone (BRANCH-007 produces a monotone ordering by construction for structured regions).
2. **Port ordering:** same-side ports are assigned in the order of the other endpoints' perpendicular coordinates (EDGE-002). This alone removes all local fan crossings.
3. **Channel ordering:** within one gap, edges are assigned channels in the order of their target band index; for edges going up, reverse the order. (Formally: sort by `targetBandIndex` if `Δy < 0`, descending if `Δy > 0`, this yields a planar assignment for any set of edges within one gap that has no inherent crossing.)
4. **Numeric fallback:** only inside unstructured residue (LAYOUT-033), apply weighted-median ordering with 4 sweeps.
**Detect:** count segment intersections between distinct edges (sweep line), excluding bundle junctions.
**Repair:** re-run steps 1–3 for the affected region; if crossings persist, they are inherent (§EDGE-011).

---

### EDGE-011 :: Unavoidable crossings
**Priority:** MEDIUM
**Applies when:** a crossing survives EDGE-010, i.e. the region is non-planar for the chosen band order.
**Rule:** when a crossing must occur, it must occur **cleanly**:
- exactly perpendicular (guaranteed by orthogonality, never allow a near-parallel "grazing" crossing, i.e. two segments closer than `EDGE_SEP` for a projected length `> 2U`);
- at least `2U` away from any bend of either edge;
- at least `3U` away from any port, junction, or arrowhead;
- at least `EDGE_CLEAR` away from any node border;
- never inside a label box (LABEL-009);
- never at the same point as another crossing (two crossings must be `≥ 2U` apart).
**Optional rendering:** `crossingHops = false` by default (a small arc where one edge hops the other). Enable only for diagrams with `crossings > 8`; hops are a render-time decoration and must not alter waypoints.
**Detect:** for each crossing point, evaluate the five distance predicates.
**Repair:** shift the crossing along the shared channel by `±CORRIDOR_PITCH` until all predicates hold; if impossible, move the crossing to the adjacent channel.

---

### EDGE-012 :: Crossing vs joining vs overlap (disambiguation)
**Priority:** STRONG
**Rule:** the formatter must classify every coincidence of two edges and render each distinctly:
| Case | Definition | Rendering | Legality |
|---|---|---|---|
| **Crossing** | segments of two edges intersect transversally at one point; no shared endpoint | plain intersection (or hop) | legal, penalized |
| **Joining (bundle junction)** | two edges share a port and diverge at a T-point | the T-point gets a filled junction dot of radius `0.3U` when `≥ 3` edges bundle | legal |
| **Overlap** | collinear coincidence not covered by bundling | — | **prohibited** (HC-009) |
| **Grazing** | parallel, `0 < distance < EDGE_SEP`, projected overlap `> 2U` | — | **prohibited** |
**Detect:** pairwise segment classification.
**Repair:** overlap/grazing → re-channel; ambiguous T-points → add junction dot or offset by `CORRIDOR_PITCH`.

---

### EDGE-013 :: Loopback routing
**Priority:** STRONG
**Applies when:** an edge is a back edge (`layer(v) ≤ layer(u)`).
**Rule:** canonical 2-bend route through a reserved loop corridor (LAYOUT-018), entering the target from **above**:
```
route = [ (cx(u), top(u)),            # N port of source
          (cx(u), corridorY(k)),
          (cx(v), corridorY(k)),
          (cx(v), top(v)) ]           # N port of target, arrowhead pointing down
```
**Rules of thumb enforced numerically:**
- `corridorY(k) ≤ regionTop − LOOP_CLEAR` (never inside the region bbox);
- `|corridorY(k) − corridorY(k±1)| = CORRIDOR_PITCH`;
- loops sorted by span descending get increasing `k` (outermost loop = largest corridor offset), this makes nested loops non-crossing;
- when the loop's source is a gateway that also has a forward branch, the forward branch uses `E`/`S`, the loop uses `N`; the gateway's `N` port is reserved for the loop.
**"Loop around a branch group":** if the back edge's span contains a complete split/merge region, the corridor is placed outside that region's *full* bbox (including its exception bands), not merely outside the spine.
**Rationale:** entering the target from the top rather than wrapping to its `W` port halves the bend count and produces an arrowhead whose direction (downward, into the top) unmistakably signals "return here".
**Exceptions:** a self-loop (`u == v`) uses the compact 4-bend pattern: `N` port → up `3U` → east `w/2 + 2U` → down → into `E` port... reduced form: `[(cx,top),(cx,top−3U),(right+3U,top−3U),(right+3U,cy),(right,cy)]`.
**Detect:** back edge whose route is not a 4-point corridor route, or whose corridor overlaps a node band.
**Repair:** re-allocate the corridor and re-route.

---

### EDGE-014 :: Boundary event exception routing
**Priority:** STRONG
**Applies when:** an outgoing flow from a boundary event.
**Rule:** the exception flow leaves the boundary event **perpendicular to the host border and away from the host**, and turns only once it is clear of the host box; it never re-enters that box. In the ordinary case, a handler band allocated outside the region, so the drop already travels toward it, that is the canonical 1-bend form:
```
route = [ (cx(be), cy(be)+EV/2),
          (cx(be), handlerAxisY(j)),
          (x(handler), handlerAxisY(j)) ]
```
For a **top-attached** boundary event, mirror upward. The vertical stub must clear the host by `≥ 1U` (it starts exactly on the host border).

The canonical form assumes the handler lies past the host in the direction the stub already travels, which a handler band allocated outside the region guarantees. Where it does not, the route takes one of the forms below. They are **generated in order and the first one clear of the host is taken**, rather than selected by a case analysis: the property is that no form which touches the host can be chosen, and a filter states that directly while a case analysis only approximates it.

| Form | Bends | When it is the first clear one |
|---|---|---|
| straight | 0 | the handler is already level with the stub, or lined up with it on the far side |
| canonical L | 1 | the handler is past the host in the stub's direction, entered through `W` or `E` |
| vertical approach | 2 | the handler is entered through `N` or `S`. The last run is *vertical*: turning east at the handler's `y` and arriving along its bottom edge is what draws an arrowhead sliding into the side of a shape |
| detour | 3 | the handler is level with the host, so the L would turn inside it. Run past the host, cross its band in a corridor beside it, then come back to the handler's `y` |
| excursion | 4 | the handler is on the far side of the host from the stub *and* entered through a vertical port whose approach lies in the host's own column. Leave the host, cross its band beside it, and come back along the approach, four bends is the price of a handler the stub has to travel away from before it can reach |

The **escape corridor**, the `x` at which a vertical may cross the host's band, is tried at, in order: as near the target as the host allows on the right, then on the left, then hugging each side of the host, then just beyond the target on each side. The last pair is what a vertical port directly past the host needs: a corridor sharing the target's own `x` makes the run into the port double back along the line it arrived on, and simplification then reduces it to the straight line through the host that the form existed to avoid.

A route is also rejected if it reaches the port from **inside** the shape (EDGE-024): a route can be perfectly clear of the host and still enter a `W` port from the right.

**Not every arrangement has a legal route.** A handler whose `W` port sits `MIN_SEG` to the right of the host at the host's own mid-height has one `MIN_SEG` of gap for both the corridor and the approach. The remedy is a different port (EDGE-020 rung 3), which belongs to port assignment and not to one route. Clearing the host is the condition that is never traded: the route emitted in that case reaches its port at an odd angle, which HC-005 and EDGE-024 report, and does not cross the task.

**Band index `j`** comes from LAYOUT-016 (leftmost boundary event ⇒ farthest band), which guarantees the fan is crossing-free.
**Detect:** any segment intersecting the host box (HC-004 with clearance `0` for the host); an exception route with more bends than its form allows; or one crossing another exception route of the same host.
**Repair:** re-run LAYOUT-016 ordering, then re-route through the form ladder.

---

### EDGE-015 :: Cross-lane routing
**Priority:** STRONG
**Applies when:** `lane(u) ≠ lane(v)` for a sequence flow.
**Rule:** canonical **Z route** with the vertical transition placed at the midpoint of the inter-column gap:
```
xt = snapCenter( (right(u) + left(v)) / 2 )
route = [ (right(u), cy(u)), (xt, cy(u)), (xt, cy(v)), (left(v), cy(v)) ]     # 2 bends
require right(u) + MIN_SEG ≤ xt ≤ left(v) − MIN_SEG
```
**Multiple cross-lane edges in the same gap:** assign distinct channels `xt_j = colGapStart + EDGE_CLEAR + j·CORRIDOR_PITCH`, ordered by target band (EDGE-010 step 3). Widen the gap when channels are exhausted.
**Rationale:** the Z keeps "east progress first", crosses the lane divider in empty inter-column space (never over a node), and its two bends are the theoretical minimum for a lane change with distinct `y`.
**Exceptions:** if `u` is a split gateway, the branch already leaves via `N`/`S`; then the lane change is absorbed into the comb (EDGE-005) with no extra bends, the branch axis simply lies in another lane.
**Detect:** cross-lane edge with `>2` bends, or whose vertical segment intersects a node box or lies under a lane label band.
**Repair:** re-route as Z; if `xt` cannot satisfy the `MIN_SEG` constraints, widen the column gap to `2·MIN_SEG + colGap`.

---

### EDGE-016 :: Message flow routing
**Priority:** STRONG
**Applies when:** a message flow connects elements in two pools.
**Rule:** message flows run **perpendicular to the pool stack** (vertically for horizontal pools). Canonical routes:
```
aligned   (|cx(u) − cx(v)| ≤ ALIGN_TOL):
  [ (cx(u), facingBorderY(u)), (cx(u), facingBorderY(v)) ]                # 0 bends
offset:
  ym = snapCenter( (poolBottom(Pu) + poolTop(Pv)) / 2 ) + j·CORRIDOR_PITCH
  [ (cx(u), border(u)), (cx(u), ym), (cx(v), ym), (cx(v), border(v)) ]    # 2 bends
```
The horizontal jog always lies in the **inter-pool gap**, never inside a pool. `POOL_GAP_Y` grows to `6U + (m−1)·CORRIDOR_PITCH` for `m` jogging message flows between the same pool pair.
**Anchors:** always the `S` port of the upper element and the `N` port of the lower element. Message flows never attach to `E`/`W` ports (that would compete with sequence flow).
**Deeply nested source/target:** if the element is inside an expanded subprocess or a non-adjacent lane, the flow exits vertically through all intervening containers at constant `x`; it must not jog inside any container. If a node blocks the vertical path, use an offset port on the source (activities only) or shift `cx` of the jog by `CORRIDOR_PITCH` and accept 2 bends *inside the gap only*.
**Black-box pools:** attach to the pool border directly at `x = cx(u)` (no internal element).
**Detect:** message flow with a bend inside a pool; or attached to an `E`/`W` port; or with `>2` bends.
**Repair:** re-route; if a vertical path is impossible, reorder pools (LANE-013).

---

### EDGE-017 :: Association routing
**Priority:** MEDIUM
**Applies when:** data association or text-annotation association.
**Rule:** associations are the shortest orthogonal path between the artifact's facing port and the host's facing port, with **0 bends preferred** (achieved by aligning the artifact's `cx` with a port of the host, ART-002). Max 1 bend. Associations never enter a routing channel reserved for sequence flow; they live in the artifact gutter.
**Detect:** association with `>1` bend or crossing a sequence flow.
**Repair:** re-align the artifact `cx` to the host port; only if impossible, allow the single bend.

---

### EDGE-018 :: Label reservation during routing
**Priority:** MEDIUM
**Rule:** each edge label occupies a reserved rectangle (LABEL-005). Routing treats **other** edges' label rectangles as obstacles with clearance `LABEL_CLEAR`, exactly like node boxes. An edge may pass through its **own** label rectangle only along the segment the label annotates (the label is drawn offset from that segment, so no true overlap occurs).

"Only along that segment" is the whole exemption, and it is worth stating as a prohibition too: **every other segment of the same edge is an obstacle like anyone else's.** LABEL-005 lets a label overhang the end of a short segment toward the target, so a label anchored to a 6U peel can reach past the corner and land on that same connector's next turn a line drawn through text, which owning the line does not make readable.
**Detect:** segment ∩ label rect ≠ ∅, for any segment other than the one the label annotates.
**Repair:** shift the channel; if impossible, move the label to its secondary anchor (LABEL-006).

---

### EDGE-019 :: Route cost function
**Priority:** MEDIUM (used to choose among candidate routes only)
**Rule:** when more than one legal route exists, choose the minimum-cost route:
```
routeCost = 6.0·bends
          + 40.0·crossings
          + 0.02·lengthPx
          + 12.0·proximityViolations         # segment within EDGE_CLEAR..2·EDGE_CLEAR of a node
          + 25.0·backwardLengthU             # length of segments moving −x (non-back edges)
          + 8.0·channelIndex                 # prefer channels closer to the source
          + 15.0·portDeviation               # non-default port used
Ties: lower channelIndex, then lower waypoint sequence lexicographically.
```
**Relative magnitudes rationale:** one crossing ≈ 6.7 bends ≈ 2000 px of length. Length is deliberately cheap: a long straight connector is far more readable than a short bendy one. Backward movement is expensive per unit so that even short backward jogs on forward edges are eliminated.
**Detect/Repair:** n/a (selection rule).

---

### EDGE-020 :: Edge–node clearance repair
**Priority:** HARD (HC-004)
**Rule:** when a segment violates `EDGE_CLEAR` against a non-incident node, repair in this fixed order and stop at the first success:
1. shift the segment to the next free channel in the same gap/band;
2. widen the gap/band by `CORRIDOR_PITCH` and re-route;
3. reassign the edge's port (e.g. `S` instead of `E`);
4. move the *node* to the next column (only if the node is not on the spine);
5. re-run band assignment for the enclosing region.
**Rationale:** ordering the repairs prevents oscillation between two repairs that undo each other.

---

### EDGE-021 :: Backward movement on forward edges
**Priority:** STRONG
**Applies when:** a non-back edge contains a segment with `Δx < 0`.
**Rule:** prohibited. A forward edge's `x` must be non-decreasing along the route.
**Exception:** the final approach into an offset `W` port may move backward by `≤ MIN_SEG`; and a merge fan-in whose branch overshoots (`xEnd_i > mx`, only possible after compaction errors) must be re-laid, not routed backward.
**Detect:** monotonicity scan.
**Repair:** re-layer (the backward segment always indicates a layering or compaction fault).

---

### EDGE-022 :: Default-flow marker clearance
**Priority:** WEAK
**Rule:** the default-flow tick mark is drawn on the first segment, `2U` from the source port. Reserve a `1.5U × 1.5U` clearance box around it; no label and no crossing within `2U`.
**Detect:** label or crossing inside the reserved box.
**Repair:** move the label along the segment; move the crossing to another channel.

---

### EDGE-023 :: Conditional-flow marker clearance
**Priority:** WEAK
**Rule:** identical to EDGE-022 for the conditional-flow diamond marker at the source end of a flow leaving an activity.

---

### EDGE-024 :: Arrowhead legibility
**Priority:** STRONG
**Rule:** the final segment before any arrowhead must be `≥ MIN_SEG` long and must not be crossed within `3U` of the arrowhead (EDGE-011). Two arrowheads terminating at the same port (bundled fan-in) must be exactly coincident, never `1–3 px` apart, which reads as a rendering bug.
**Detect:** distinct arrowhead points closer than `2U` but not identical.
**Repair:** snap coincident arrowheads to the exact port point.

---

### EDGE-025 :: Canonical routing pattern catalogue

| Situation | Pattern | Bends |
|---|---|---|
| Straight sequence, same band | `u.E ─────► v.W` | 0 |
| Split, axis branch | `g.E ─────► v.W` | 0 |
| Split, off-axis branch | `g.S │ then ──► v.W` | 1 |
| Merge, off-axis branch | `u.E ──► then │ into m.N/S` | 1 |
| Cross-lane forward | `u.E ── │ ── v.W` (Z, jog at gap midpoint) | 2 |
| Loopback | `u.N │ ── corridor ── │ v.N` | 2 |
| Boundary exception | `be.S │ ── handler.W` | 1–2 |
| Message flow, aligned | `u.S │ v.N` | 0 |
| Message flow, offset | `u.S │ ── gap ── │ v.N` | 2 |
| Association, aligned | `a.S │ host.N` | 0 |
| Self-loop | `u.N │ ─ ┐ │ ─ u.E` | 4 |

---

## F. Branching Rules

### BRANCH-001 :: Region detection
**Priority:** STRONG
**Applies when:** phase 2.
**Rule:** decompose the acyclic skeleton into single-entry/single-exit (SESE) regions:
```
for each node g with outDegree ≥ 2:
    m = immediatePostDominator(g)
    R = { v : g dominates v ∧ m postDominates v ∧ v ∉ {g,m} }
    if every edge entering R comes from g and every edge leaving R goes to m:
         emit region (split=g, merge=m, branches = successors(g) restricted to R)
    else: mark unstructured (LAYOUT-033)
```
Regions nest; build the region tree by containment. A region whose `m` is the scope exit and whose branches terminate independently is an **open region** (BRANCH-018). Loops are detected first (back edges via DFS on the canonicalized order) and become **loop regions** (BRANCH-017) that are removed before SESE analysis.
**Algorithms actually required:** DFS spanning tree + back edges (loops); Lengauer–Tarjan dominators and post-dominators (regions, spine); topological order (layering); Tarjan SCC (irreducible loop detection); longest path (layering). Everything else (planarity testing, ILP crossing minimization) is deliberately excluded as not cost-effective.
**Detect:** overlapping non-nested regions.
**Repair:** mark the union unstructured.

---

### BRANCH-002 :: Branch bounding box
**Priority:** STRONG
**Rule:** a branch's bounding box is computed **bottom-up** and includes everything the branch owns:
```
bbox(branch) = union(
     bbox(node) for every node in the branch,
     bbox(nested region) for every nested region,
     exceptionBands(branch),          # boundary-event handler content
     loopCorridors(branch),           # local back-edge corridors
     artifactGutters(branch),         # data objects, annotations
     externalLabelBoxes(branch),      # event/gateway labels
     flowLabelBoxes(branch)
)
H[i]     = bbox(branch_i).height
A[i]     = branchAxisY(branch_i) − bbox(branch_i).top      # axis offset within the bbox
span[i]  = maxLayer(branch_i) − minLayer(branch_i) + 1
```
Note `A[i] ≠ H[i]/2` in general: a branch with an exception band below has its axis above the bbox center. **All vertical placement uses `A[i]`, not `H[i]/2`.** This is the single most common implementation error in BPMN formatters.
**Detect:** a branch whose rendered content escapes its recorded bbox.
**Repair:** recompute bottom-up and re-stack ancestors.

---

### BRANCH-003 :: Two outgoing branches
**Priority:** STRONG
**Applies when:** `outDegree(split) == 2`.
**Rule:** two arrangements; choose by region classification.

**(a) `AXIS_LOCK`, default for exclusive (XOR) and inclusive (OR) splits.** The rank-1 branch keeps the axis and is drawn perfectly straight through both the split and the merge (0 bends). The rank-2 branch is placed on the side dictated by its polarity: `below` if negative/exception/terminating, `above` if positive or neutral.
```
axis(branch1) = gy
if side(branch2) = below:  bbox(b2).top = bbox(b1).bottom + BRANCH_GAP_Y
if side(branch2) = above:  bbox(b2).bottom = bbox(b1).top − BRANCH_GAP_Y
axis(branch2) = bbox(b2).top + A[2]
```
For two simple one-task branches this yields `Δaxis = TASK_H + BRANCH_GAP_Y = 14U = 140 px`.

**(b) `BBOX_CENTER`, default for parallel (AND) and event-based splits, and for XOR/OR splits with no distinguishable primary.** Neither branch holds the axis; the two bboxes straddle it symmetrically.
```
totalH = H[1] + BRANCH_GAP_Y + H[2]
top    = snapCenter(gy − totalH/2)
bbox(b1).top = top ;  axis(b1) = top + A[1]
bbox(b2).top = top + H[1] + BRANCH_GAP_Y ;  axis(b2) = bbox(b2).top + A[2]
```
For two one-task branches: axes at `gy ± 7U (±70 px)`.

**Classification test (`hasPrimary`):** true iff any of: one flow is the **default flow**; polarities differ; `|H[1] − H[2]| > SYM_TOL`; `|span[1] − span[2]| > SPAN_TOL`; user priority set. `AXIS_LOCK` iff `hasPrimary ∧ gatewayType ∈ {XOR, OR, activity-implicit}`.
**Rationale:** XOR decisions almost always have a happy path, and a straight happy path is the highest-value readability feature available. AND branches are true peers, and symmetry is the correct signal for concurrency an AND branch drawn on the axis falsely suggests it is "the main one".
**Exceptions:** if `AXIS_LOCK` would put the rank-2 branch outside its lane, use `BBOX_CENTER` and clamp.
**Conflict:** `AXIS_LOCK` beats LAYOUT-026 (symmetry), symmetry is not evaluated for regions with `hasPrimary`.
**Detect:** two-branch region matching neither formula within `ALIGN_TOL`.
**Repair:** re-classify and re-stack.

---

### BRANCH-004 :: Three outgoing branches
**Priority:** STRONG
**Applies when:** `outDegree(split) == 3`.
**Rule:** **upper / center / lower**, with the rank-1 branch on the center (axis) slot. This holds for all gateway types: with an odd branch count, a center slot exists and leaving it empty wastes the axis and doubles the region height.
```
order top→bottom = [ rank-A , rank-1 , rank-B ]   where {A,B} = ranks 2,3 assigned by side rules
axis(center) = gy   (AXIS_LOCK on the center branch)
bbox(upper).bottom = bbox(center).top − BRANCH_GAP_Y
bbox(lower).top    = bbox(center).bottom + BRANCH_GAP_Y
```
Side assignment for ranks 2 and 3: negatives/terminating go below; if both are neutral, rank-2 goes **above** and rank-3 below (so that reading top→bottom encounters branches in the order 2, 1, 3 the two "most important" are adjacent to the top of the group).
**Exception (all-negative):** if ranks 2 and 3 are both exception-class, both go below, stacked in rank order, and the region becomes bottom-heavy, this is correct and preferred over placing an error path above the happy path.
**Detect / Repair:** as BRANCH-003.

---

### BRANCH-005 :: Four outgoing branches
**Priority:** STRONG
**Applies when:** `outDegree(split) == 4`.
**Rule:** default **2 above / 2 below** with the axis running in the central gap (`BBOX_CENTER`), *unless* `hasPrimary` is true, in which case `AXIS_LOCK` with `[2 above, primary on axis, 2 below]` is impossible with 4 branches, instead use `[1 above, primary on axis, 2 below]` for a negative-heavy set, or `[2 above, primary, 1 below]` otherwise, keeping `| #above − #below | ≤ 1`.
```
if not hasPrimary:  stack = [r1, r3, r2, r4] top→bottom, BBOX_CENTER
                    # interleaving keeps high-rank branches adjacent to the axis
if hasPrimary:      stack = above(ranks by side rule) + [r1] + below(...), AXIS_LOCK
```
**Rationale:** placing ranks 1 and 2 adjacent to the axis (rather than at the extremes) means the two most important alternatives are the two nearest the reader's eye line.
**Detect / Repair:** as BRANCH-003.

---

### BRANCH-006 :: Five or more outgoing branches
**Priority:** STRONG
**Applies when:** `outDegree(split) ≥ 5`.
**Rule:** general algorithm:
```
1. rank branches (BRANCH-007) → r1..rn
2. partition by polarity: DOWN = {negative, exception, terminating}, UP = rest
3. rebalance: while |UP| − |DOWN| > 1 : move the lowest-ranked neutral member of UP to DOWN
              while |DOWN| − |UP| > 1 and DOWN contains a neutral member : move it to UP
              (exception-class members never move to UP)
4. if n is odd and hasPrimary: r1 takes the axis slot, remove from its set
5. order UP by rank ascending outward from the axis; same for DOWN
6. stack bboxes with BRANCH_GAP_Y; center per AXIS_LOCK or BBOX_CENTER
7. if n ≥ 7: switch to FAN_COLUMN mode (below)
```
**`FAN_COLUMN` mode (`n ≥ 7`):** the vertical extent becomes unmanageable (`7 × 14U = 98U ≈ 980 px` for trivial branches). Instead, split the fan into `ceil(n/5)` **sub-fans** using virtual pass-through columns: the gateway's comb feeds `ceil(n/5)` vertical trunk stubs at distinct channels, each serving 5 branches. Formally, insert dummy fan nodes at `layer(split)+1` and treat each as a sub-split. Total height becomes `O(5·14U)` with `O(n/5)` extra columns.
**Exception:** event-based gateways with many branches are common (a message-selection pattern), for these, `FAN_COLUMN` is disabled and all branches stay in one fan, because the visual equivalence of the alternatives matters more than height.
**Detect:** `n ≥ 7` laid out in a single fan outside the event-based exception; or `|#above − #below| > 1` with movable neutrals present.
**Repair:** re-run steps 2–7.

---

### BRANCH-007 :: Branch ordering (deterministic comparator)
**Priority:** STRONG
**Applies when:** any split.
**Rule:** rank outgoing branches by the following **strict lexicographic comparator**. Lower tuple = better rank = closer to the axis.
```
key(branch b) = (
  1. userPriority(b)                    ascending   (absent = +∞)
  2. isDefaultFlow(b) ? 0 : 1           ascending
  3. polarity(b)                        POSITIVE=0, NEUTRAL=1, NEGATIVE=2, EXCEPTION=3
  4. terminates(b) ? 1 : 0              ascending   (continuing before terminating)
  5. −span(b)                           (longer branch first)
  6. −nodeCount(b)                      (larger branch first)
  7. −probability(b)                    (if annotated)
  8. documentOrder(outgoingFlow)        ascending
  9. id(outgoingFlow)                   lexicographic
)
```
**Polarity classification** (deterministic, case- and accent-insensitive, on the flow's name then the branch's first node's name):
- `POSITIVE`: matches `yes|true|ok|approved?|accept(ed)?|valid|success|granted|complete[d]?|in stock|eligible` (localizable table).
- `NEGATIVE`: matches `no|false|reject(ed)?|denied|invalid|fail(ed|ure)?|timeout|expired|cancel(led)?|out of stock|ineligible|insufficient`.
- `EXCEPTION`: the branch originates at a boundary event, or **every** outcome it leads to is an error/escalation/cancel/terminate end event, or its first node is an error-handling subprocess.
- `NEUTRAL`: everything else.

  The classification is over the branch's **outcomes**, not over its members. "Contains an exceptional end event" read across a branch's transitive members swallows whole processes: a main path of ten normal steps that reaches one escalation end somewhere is classified as an exception path, pushed below the axis, and the spine is handed to whichever short branch happened to be neutral, typically a single end event. The signal the rule is reaching for is a branch whose *purpose* is to fail, and a branch that also ends normally does not have it. A boundary event **among** the members is not an outcome either: the rule is that the branch *originates at* one.

**Side assignment:** `POSITIVE`/`NEUTRAL` → prefer above; `NEGATIVE`/`EXCEPTION`/terminating → below. Rebalancing per BRANCH-006 step 3.

  "Terminating" decides a side only where it **separates** the branches. BRANCH-014 is about a branch that stops *while another continues*; in an open region (BRANCH-019) every branch stops, so the property is true of all of them and distinguishes none. Letting it decide there sends every branch below the axis at once, which is how a subprocess ends up hanging entirely under a spine that runs along its own top edge. Where every branch terminates, polarity does the work alone, an exception or negative branch still goes below whether or not it stops.
**Rationale:** every signal is a stable property of `SG`; none depends on traversal order, hashing, or geometry, so equivalent graphs produce identical layouts (A9). The fallbacks (`documentOrder`, then `id`) guarantee totality.
**Exceptions:** if a **user priority** is supplied for any branch of a region, it must be supplied for all, or the missing ones sort last.
**Detect:** recompute keys and compare with the stored order.
**Repair:** re-sort and re-stack (subject to the stability threshold, LAYOUT-024).

---

### BRANCH-008 :: Axis occupancy
**Priority:** STRONG
**Rule:** the axis slot is occupied when `AXIS_LOCK` is active, which holds iff:
```
AXIS_LOCK  ⟺  hasPrimary(region) ∧ splitType ∈ {XOR, OR, implicit}
           ∨  (n is odd ∧ splitType ∈ {AND, eventBased} ∧ hasPrimary)
           ∨  largeDiagramMode
BBOX_CENTER otherwise
```
When `AXIS_LOCK` is active, `axis(rank-1 branch) == gy == mergeCy` exactly, giving a bend-free straight line through the whole region.
**Rationale:** answers "should one branch remain on the main horizontal axis?" yes, whenever one branch is genuinely primary; no, when the branches are peers.
**Detect:** `AXIS_LOCK` active but no branch axis equals `gy`.
**Repair:** re-stack.

---

### BRANCH-009 :: Gateway-type specifics
**Priority:** MEDIUM

| Type | Arrangement default | Axis branch | Extra rules |
|---|---|---|---|
| **Exclusive (XOR)** | `AXIS_LOCK` | rank-1 (usually default flow) | branch labels are mandatory in layout terms: reserve `FANOUT_GAP ≥ maxLabelW + 2U`. |
| **Inclusive (OR)** | `AXIS_LOCK` | rank-1 | same as XOR; because several branches may run, keep `BRANCH_GAP_Y` at full value (do not compact below `6U`) so the parallelism is visible. |
| **Parallel (AND)** | `BBOX_CENTER` (symmetric) | none unless `n` odd | branches are peers: enforce `symmetryDefect ≤ 0.15`; congruent branches (equal node counts) must occupy identical column positions. Never label AND branches. |
| **Event-based** | `BBOX_CENTER` | none | the first node of every branch **must be an event** (semantics) — align all first events in one column and give them the *same* band spacing (uniform `BRANCH_GAP_Y`, no per-branch variation), because the visual comparison of the waiting alternatives is the point of the construct. `FAN_COLUMN` disabled (BRANCH-006). |
| **Complex** | `BBOX_CENTER` | none | treat as OR; annotate. |
| **Implicit split (activity with 2+ outgoing)** | `AXIS_LOCK` | rank-1 | a **downward** branch leaves from `E` with offset ports, because the activity's bottom edge belongs to its boundary events and the branch takes EDGE-005's 2-bend fan-corridor form; an **upward** branch leaves from `N` and runs straight to its band, one bend, provided no boundary event has overflowed onto the top edge (LAYOUT-016). A subprocess uses `N`/`S` for both. |

---

### BRANCH-010 :: Fan-out gap and stub geometry
**Priority:** STRONG
**Rule:**
```
FANOUT_GAP = max( NODE_GAP_X,
                  maxOutgoingLabelWidth + 2U,
                  GW/2 + MIN_SEG + EDGE_CLEAR )      # ≥ 6U always
```
The first straight segment leaving the split is vertical (the comb trunk) and runs from the port to the branch axis, its length is `|y_i − gy| − GW/2 ≥ BRANCH_GAP_Y/2 ≥ 3U`, always well above `MIN_SEG`. The following horizontal segment is `x_i − gx ≥ GW/2 + FANOUT_GAP`.
**Diagonals are never permitted** (EDGE-001) regardless of how small the vertical displacement is; if `|y_i − gy| < MIN_SEG` the branch belongs on the axis and the band assignment is wrong.
**Detect:** `FANOUT_GAP` below the formula value, or a trunk shorter than `MIN_SEG`.
**Repair:** widen the gap (recompute columns) or re-stack bands.

---

### BRANCH-011 :: Merge gateway placement
**Priority:** STRONG
**Rule:**
```
layer(merge) = max_i ( maxLayer(branch_i) ) + 1
cy(merge)    = cy(split)                                   # STRONG, see BRANCH-012
cx(merge)    = colCx(layer(merge))
```
Each branch's terminal node keeps its ASAP layer; slack is absorbed by a **single long straight segment** into the merge (see BRANCH-013). All non-axis branches enter through `N`/`S` (EDGE-006); the axis branch enters `W`.
**Merge centered on the branch group?** Only in `BBOX_CENTER` mode, where `cy(split) == stackCenter` already, so a single rule (`cy(merge) = cy(split)`) covers both modes.
**Detect:** `cy(merge) ≠ cy(split)` without a lane clamp; or `layer(merge)` not `max+1`.
**Repair:** re-place the merge; re-run fan-in routing.

---

### BRANCH-012 :: Split/merge alignment
**Priority:** STRONG
**Rule:** a matched split/merge pair shares one `cy`, and their vertical fan geometry is mirror-symmetric about the vertical line `x = (cx(split) + cx(merge))/2` **whenever the branch set is peer-symmetric**. This mirroring is what makes the pairing visually obvious.
**Formula (mirror check):** for every branch `i`, `y_i` is the same at the fan-out and the fan-in (branches do not change band inside the region unless they cross lanes), so mirroring is automatic if `cy(split) == cy(merge)`.
**Exceptions:** the split and merge lie in different lanes (then each aligns to its own lane spine, and the mismatch is intended and readable); a nested region shifts the merge (never, nested regions live *inside* a branch band).
**Detect:** `|cy(split) − cy(merge)| > ALIGN_TOL` with both in the same lane.
**Repair:** move the merge to `cy(split)`; if that violates lane containment, move the whole region's axis.

---

### BRANCH-013 :: Unequal branch lengths
**Priority:** STRONG
**Applies when:** `span(b_i) ≠ span(b_j)` in a region.
**Rule:**
1. **All branches start in the same column**: `minLayer(b_i) = layer(split)+1` for every `i`. (ASAP layering gives this for free.) This is mandatory: it is the visual signal that the branches are alternatives of one decision.
2. **The merge is placed after the longest branch** (BRANCH-011).
3. **Slack is not distributed.** Short branches keep uniform column pitch; the entire slack becomes one long, straight, bend-free horizontal segment from the branch's last node into the merge. Nodes are **never** stretched apart to "fill" a branch, because that destroys column alignment across branches and makes the diagram look like a different process.
4. **No trailing whitespace decoration**: do not insert invisible spacers, do not right-align the short branch.

**Acceptable distortions:** a long straight connector (any length); an asymmetric region bbox; unequal branch bbox widths.
**Unacceptable distortions:** stretched inter-node gaps inside a branch; branches starting at different columns; nodes centered within their branch span; a merge pulled left to meet a short branch; per-branch column pitch.
**Optional mode (off by default):** `SHORT_BRANCH_CENTERING`, when a branch consists of exactly one node and its slack `≥ STRETCH_THRESHOLD` columns *and* the region is peer-symmetric (AND gateway), center that node in the branch span. Enable only for diagrams whose primary purpose is visual balance rather than analysis.
**Detect:** two branches of one region with different `minLayer`; or intra-branch gaps differing by `> ALIGN_TOL` from the global column pitch.
**Repair:** re-layer ASAP; reset column pitch.

---

### BRANCH-014 :: Early-ending branches
**Priority:** STRONG
**Applies when:** a branch reaches an end event without reaching the region's merge (or the region is open).
**Rule:**
1. The **continuing** path stays on the axis (`AXIS_LOCK` forced, regardless of `hasPrimary`): the process must not visibly deviate because one branch stopped.
2. The **terminating** branch goes **below** the axis (polarity rule; a terminating branch is never `POSITIVE`).
3. The terminating branch consumes the **minimum possible horizontal space**: its end event sits at `layer(lastTask)+1` (ASAP), not extended toward the diagram's right edge.
4. After the region, the main flow resumes on the **same baseline** it had before the split, the baseline is never shifted by a terminating branch, because the terminating branch's bbox is accounted for in the band stack, not in the axis.
5. If several branches terminate early, they stack downward in rank order at `BRANCH_GAP_Y`, shortest span nearest the axis (so their end events form a descending staircase to the left, which reads as "these all stop here").
**Geometry:**
```
axis(continuing) = gy = spineY
bbox(term_j).top = bbox(prev).bottom + BRANCH_GAP_Y
layer(endEvent_j) = layer(lastNode_j) + 1
```
**Detect:** a terminating branch on the axis while a continuing branch is off-axis; or an end event with an over-long incoming edge (LAYOUT-015).
**Repair:** swap side assignment; re-layer the end event.

---

### BRANCH-015 :: Nested branches (recursive layout)
**Priority:** STRONG
**Applies when:** a branch contains a further split.
**Rule:** layout is a **post-order recursion over the region tree**. A nested region is laid out first, in its own local coordinate frame, producing `(H, A, W)`; the parent then treats it as an opaque block with those dimensions and stacks it like any other content.
```
layoutRegion(R):
    for each branch b in R.branches:
        for each nested region N in b (in layer order):  layoutRegion(N)
        H[b], A[b], W[b] = accumulateBranchBox(b)      # BRANCH-002
    order   = rankBranches(R)                          # BRANCH-007
    slots   = assignSlots(order, R.type, n)            # BRANCH-003..006
    stackBBoxes(slots, BRANCH_GAP_Y, mode)             # AXIS_LOCK | BBOX_CENTER
    R.H, R.A = regionBox(R)
```
**Key invariants:**
- a nested region is always **centered on its own parent branch's axis** (recursively), never on the outer spine;
- a nested region's bbox is fully contained in its parent branch's bbox, therefore sibling branches can never collide, by construction, with no collision test needed;
- **no additional whitespace is introduced per nesting level.** Nesting depth does not multiply gaps. The only growth is the genuine height of the nested content. Adding `k·U` per level (a common implementation shortcut) produces the "vertical explosion" anti-pattern (AP-014).
**Indentation:** none. Nested branches are **not** indented horizontally; they use the global column grid, so a nested gateway aligns vertically with unrelated nodes at the same layer. This is what prevents "staircase" layouts (AP-016).
**Detect:** a nested region whose axis differs from its parent branch's axis (in `AXIS_LOCK` mode) by more than `ALIGN_TOL`; or nested bbox escaping the parent bbox.
**Repair:** re-run the recursion from the offending region upward.

---

### BRANCH-016 :: Nesting-induced spacing
**Priority:** MEDIUM
**Rule:** the vertical gap between two sibling branches is
```
G[i] = max( BRANCH_GAP_Y,
            EDGE_CLEAR·2 + (channelsBetween(i,i+1) − 1)·CORRIDOR_PITCH,
            labelClearanceBetween(i,i+1) )
```
where `channelsBetween` counts horizontal routing channels that must pass in that gap (loop corridors of nested regions, cross-band edges, exception routes of branch `i`). Nesting therefore increases the gap only when it actually needs routing space.
**Rationale:** makes spacing responsive to real content rather than to depth.
**Detect:** a channel assigned to a gap narrower than the formula requires.
**Repair:** widen the gap; re-stack the region and its ancestors.

---

### BRANCH-017 :: Loop regions
**Priority:** STRONG
**Applies when:** a back edge exists.
**Rule:** a loop region spans from the loop **header** (the back edge's target) to the loop **latch** (the back edge's source). Layout:
1. the loop body is laid out as an ordinary linear/branching region on the spine, **the loop does not displace the body**;
2. the back edge gets a corridor above the region bbox (LAYOUT-018, EDGE-013);
3. the loop header must be a merge point: if the header has 2 incoming (entry + back edge), route the entry into `W` and the back edge into `N`;
4. **multi-activity loops** (`span > 1`) get corridors ordered by span (outermost = farthest);
5. **gateway-tail loops** (the latch is a gateway whose other branch continues forward): the forward branch keeps the axis; the back edge leaves via `N`. The loop is *not* treated as a branch for band allocation, it consumes a corridor, not a band.
**Rationale:** treating a loopback as a "branch" and giving it a full band is the most common cause of wasted vertical space in generated BPMN.
**Detect:** a back edge occupying a node band; a loop body displaced off the spine.
**Repair:** reclassify the back edge as a corridor edge; re-stack.

---

### BRANCH-018 :: Branches that rejoin without a merge gateway
**Priority:** STRONG
**Applies when:** two or more branches converge directly on an activity or event.
**Rule:** treat the convergence node as an **implicit merge**: it gets `layer = max(branchMaxLayer)+1` and `cy = cy(split)` exactly as a merge gateway would (BRANCH-011). The difference is only in port assignment (EDGE-006 exception: offset `W` ports or a junction dummy, since bundling into an activity's single `W` port is less legible than into a gateway apex).
**Detect:** in-degree ≥ 2 activity whose `cy` differs from its dominating split.
**Repair:** align and re-route.

---

### BRANCH-019 :: Open regions and independent branch ends
**Priority:** MEDIUM
**Applies when:** branches of a split never reconverge (each reaches an end event or leaves the scope).
**Rule:** the region is **open**: there is no merge, and the region bbox ends at `max_i(maxLayer(b_i))`. `AXIS_LOCK` is forced with the rank-1 branch on the axis (there is no symmetric interpretation to preserve). Branch end events keep ASAP layers (BRANCH-014 rule 3). The region contributes its bbox to its parent exactly like a closed region.

Every branch of an open region terminates by definition, so BRANCH-014's "terminating goes below" cannot apply here, it would apply to all of them. Sides come from polarity alone, and the rank-1 branch that takes the axis is the one BRANCH-007's comparator chooses: after polarity, the longest span and the largest node count, which is the reading of "the main path" available without a merge to measure against.
**Detect:** a split whose `immediatePostDominator` is the scope exit and whose branches contain end events.
**Repair:** n/a (classification).

---

### BRANCH-020 :: Symmetry: when to force it, when not to
**Priority:** WEAK (but the *classification* is STRONG)
**Rule:** a region is **peer-symmetric-eligible** iff:
```
peerSymmetric(R) ⟺ R.type ∈ {AND, eventBased}
                  ∨ ( R.type ∈ {XOR, OR} ∧ ¬hasPrimary(R) )
    AND  max_i H[i] − min_i H[i] ≤ SYM_TOL
    AND  max_i span[i] − min_i span[i] ≤ SPAN_TOL
    AND  no branch is EXCEPTION-class
```
Only for eligible regions is `symmetryDefect = |upExtent − downExtent| / (upExtent + downExtent)` penalized (target `≤ 0.15`), and only for eligible regions is **congruence** enforced (branches with equal node counts must occupy identical column offsets, i.e. `layer(b_i[k]) == layer(b_j[k])` for all `k`).
Non-eligible regions receive **zero** symmetry pressure. Forcing symmetry across branches of dramatically different complexity produces the "huge empty space beside a short branch" anti-pattern (AP-007) and falsely signals equivalence.
**Repair when eligible and defective:** pad the smaller side's gap by `(upExtent − downExtent)/2` rounded to `U`, never stretch content, never move the axis.

---

### BRANCH-021 :: Split immediately followed by a split
**Priority:** MEDIUM
**Applies when:** a branch's first node is itself a split gateway.
**Rule:** the inner split is placed at `layer(outerSplit)+1`, on the outer branch's axis, with `COMPACT_GAP` between the diamonds (LAYOUT-032). The inner region's stack is centered on the outer branch's axis. Because the outer comb's trunk sits at `x = cx(outerSplit)` and the inner comb's trunk at `x = cx(innerSplit)`, the two trunks are `COMPACT_GAP + GW` apart and cannot overlap.
**Constraint:** the outer fan-out gap must satisfy `FANOUT_GAP ≥ GW/2 + COMPACT_GAP + GW/2` so the inner gateway is not jammed against the outer one.
**Detect:** two gateway trunks closer than `2U`; or an inner region not centered on its branch axis.
**Repair:** widen the fan-out gap; re-stack.

---

### BRANCH-022 :: Merge immediately followed by a split
**Priority:** MEDIUM
**Applies when:** `merge → split` adjacency.
**Rule:** consecutive columns, `COMPACT_GAP`, both on the region axis (LAYOUT-032). The incoming fan (into `N`/`S` of the merge) and the outgoing fan (out of `N`/`S` of the split) must not visually fuse: require `cx(split) − cx(merge) ≥ GW + COMPACT_GAP` and forbid a channel between them (no edge may route in that gap).
**Exception:** if in-degree ≥ 3 and out-degree ≥ 3, increase the gap to `NODE_GAP_X`.
**Detect:** any edge routed between the two gateways; or gap below `COMPACT_GAP`.
**Repair:** widen; re-channel.

---

### BRANCH-023 :: Branches crossing lanes
**Priority:** STRONG
**Applies when:** a branch's content lies in a different lane from its split.
**Rule:** the branch's band is allocated **inside the target lane**, not by the region's stacking formula. The region's stack is computed lane by lane: branches are first grouped by lane, groups are ordered by lane order, and within a lane the group is stacked normally around that lane's spine. `AXIS_LOCK` applies only to branches in the split's own lane.
**Consequence:** `cy(merge) = cy(split)` (BRANCH-012) may be unsatisfiable; the merge then aligns to the lane spine of *its own* lane, and BRANCH-012 is recorded as a permitted exception (not a violation).
**Detect:** a branch node outside its lane (HC-003), the classic symptom of applying the plain stacking formula in a collaboration diagram.
**Repair:** re-run region stacking in lane-partitioned mode.

---

## G. Pools and Lane Rules

### LANE-001 :: Pool geometry
**Priority:** STRONG
**Rule:** a pool is a rectangle with a left header band of width `POOL_LABEL_BAND` containing the pool name rotated 90° CCW, centered. Content area starts at `poolX + POOL_LABEL_BAND + (nested lane label bands)`.
```
poolInnerX = poolX + POOL_LABEL_BAND
poolW      = POOL_LABEL_BAND + maxLaneContentW + 2·CONTAINER_PAD_X
poolH      = Σ laneH(L)
```
A pool with a single lane and no lane semantics renders as a pool with no lane band (`LANE_LABEL_BAND = 0`).
**Detect:** content inside the header band; pool not tightly bounding its lanes.
**Repair:** recompute from lanes upward.

---

### LANE-002 :: Lane geometry and tiling
**Priority:** HARD (HC-007)
**Rule:** all lanes of one pool share `x` and `width`; they tile the pool's inner height exactly, in order, with no gaps. Nested lanes recursively tile their parent lane and add one `LANE_LABEL_BAND` of indentation each.
```
laneX = poolInnerX ; laneW = poolW − POOL_LABEL_BAND
laneY(0) = poolY ; laneY(i) = laneY(i−1) + laneH(i−1)
contentX(L) = laneX + LANE_LABEL_BAND·depth(L) + CONTAINER_PAD_X
```
**Detect:** unequal lane widths, gaps, or `Σ laneH ≠ poolH`.
**Repair:** recompute.

---

### LANE-003 :: Lane height
**Priority:** STRONG
**Rule:** lane height is **content-dependent, not equal**:
```
laneH(L) = max( LANE_MIN_H, contentH(L) + 2·CONTAINER_PAD_Y )
contentH(L) = (max over content of bottom) − (min over content of top),
              including external labels, exception bands, and loop corridors owned by nodes in L
```
Equal-height lanes are **not** the default: forcing a lane containing three tasks to the height of a lane containing a nested region wastes an enormous amount of vertical space and dilutes the association between a lane and its content. Equal heights are available as `LANE_EQUAL_HEIGHT = true` for presentation decks.
**Exception:** a lane with no content still gets `LANE_MIN_H`.
**Detect:** `laneH < contentH + 2·CONTAINER_PAD_Y`, or `laneH > contentH + 2·CONTAINER_PAD_Y + 4U` (excess).
**Repair:** resize the lane; propagate to pool height; translate lanes below.

---

### LANE-004 :: Lane growth propagation
**Priority:** STRONG
**Rule:** resizing is strictly bottom-up and single-pass: `nodes → nested containers → lanes → pool → diagram`. A lane never shrinks below the extent of its content; a pool never clips a lane. When lane `i` grows by `Δ`, lanes `i+1…n` translate down by `Δ` and the pool grows by `Δ`; content inside translated lanes translates with them (rigid-body).
**Detect:** content outside a container after a resize.
**Repair:** re-run the bottom-up pass.

---

### LANE-005 :: Lane ordering
**Priority:** MEDIUM
**Rule:** preserve the input lane order (stability). When generating from scratch, order lanes by the **first touch** of the process in topological order: the lane containing the start event is topmost; each subsequent lane is appended when the flow first enters it. Ties by `(documentOrder, id)`.
**Rationale:** makes the diagram's vertical reading order approximate the process's temporal order, which minimizes the average vertical travel of cross-lane flows and hence the number of long transitions.
**Exceptions:** an explicit lane order (`laneSet` order) always wins; reordering existing lanes costs `LANE_REORDER = 80` in the stability function and is therefore effectively frozen for incremental layout.
**Detect:** compute the first-touch order and compare; report only.
**Repair:** reorder only on a full re-layout.

---

### LANE-006 :: Lane spine
**Priority:** STRONG
**Rule:** each lane has its own baseline `laneSpineY(L)`, at the vertical center of the lane's **content**, and all main-flow nodes inside `L` sit on it:
```
laneSpineY(L) = laneY(L) + CONTAINER_PAD_Y + A(L)     # A(L) = axis offset of L's content box
```
Activities are **not** centered in the lane rectangle if the lane has asymmetric content (e.g. an exception band below); they are centered on the lane's *content axis*. There is no global process baseline across lanes, a global baseline is meaningless once lanes have different heights.
**Detect:** a main-flow node in `L` off `laneSpineY(L)`.
**Repair:** re-stack the lane's bands.

---

### LANE-007 :: First and last node placement in a lane
**Priority:** MEDIUM
**Rule:** horizontal position inside a lane is governed entirely by the **global column grid**, columns span all lanes of a pool. A node is never left-aligned to its own lane. Consequence: a lane may begin far to the right; that gap is meaningful (it shows when the role becomes active) and must not be compacted away.
**Detect:** a lane whose nodes do not sit on global column centers.
**Repair:** re-snap to the column grid.

---

### LANE-008 :: Vertical placement of content within lanes
**Priority:** STRONG
**Rule:** band allocation is performed **per lane**: each lane has its own band stack (spine, artifact gutters, branch bands, exception band, loop corridors), and bands never cross a lane divider. A region whose branches span lanes is laid out per BRANCH-023.
**Detect:** a band whose `y` range crosses a lane border.
**Repair:** split the band per lane and re-run the region's lane-partitioned stacking.

---

### LANE-009 :: Cross-lane sequence flow: horizontal progress
**Priority:** STRONG
**Applies when:** `lane(u) ≠ lane(v)`.
**Rule:** the target must be strictly ahead: `left(v) ≥ right(u) + NODE_GAP_X_MIN`. A lane change may never be drawn as a purely vertical connector between vertically-stacked nodes, because that hides the temporal progression and produces a column of nodes that reads as simultaneous.
**Geometry:** enforced as a layering constraint: `layer(v) ≥ layer(u) + 1` (already implied by ASAP) **plus** a minimum gap constraint added to the column compaction solver.
**Detect:** a cross-lane edge with `left(v) − right(u) < NODE_GAP_X_MIN`, or a purely vertical cross-lane route.
**Repair:** add the gap constraint; re-run compaction.

---

### LANE-010 :: Ping-pong between lanes
**Priority:** MEDIUM
**Applies when:** the flow alternates between the same two lanes more than `3` times within `6` layers.
**Rule:** switch that sub-chain to **staircase mode**: every transition uses the identical Z geometry (same jog position relative to the gap: exactly the gap midpoint), the same column pitch, and the same lane spines, so the repeated transitions form a regular staircase rather than irregular zigzag. Additionally:
- never allow backward `x` movement (LANE-009);
- keep the lane spines fixed for the whole staircase (do not re-center lanes mid-chain);
- if the chain exceeds `8` transitions, emit an advisory that the lane decomposition is likely wrong, do not attempt a heroic layout.
**Rationale:** regular repetition reads as a pattern; irregular repetition reads as spaghetti. The difference is entirely in whether the jogs are at identical relative positions.
**Detect:** count lane alternations per layer window; measure the variance of jog offsets within the chain.
**Repair:** normalize jog offsets to the gap midpoint; equalize column pitch across the chain.

---

### LANE-011 :: Nested lanes
**Priority:** MEDIUM
**Rule:** nested lanes indent by `LANE_LABEL_BAND` per level on the left only; content area shrinks accordingly. Nesting deeper than 3 levels triggers an advisory. Child lanes tile the parent lane exactly (HC-007 recursively).

---

### LANE-012 :: Multiple pools: stacking
**Priority:** STRONG
**Rule:** pools stack vertically, left-aligned at `x = MARGIN`, with `POOL_GAP_Y` between them, grown to `POOL_GAP_Y + (m−1)·CORRIDOR_PITCH` where `m` is the number of jogging message flows in that gap (EDGE-016). All pools share the same width (`max` over pools) so their right edges align, a strong regularity cue in collaboration diagrams.
**Detect:** unequal pool widths or misaligned left edges.
**Repair:** widen all pools to the max; re-align.

---

### LANE-013 :: Pool ordering to minimize message-flow crossings
**Priority:** MEDIUM
**Rule:** order pools to minimize message-flow crossings, using one deterministic barycenter pass over the pool sequence:
```
repeat 4 times (fixed):
    for each pool P: b(P) = mean( index(otherPool(mf)) for mf incident to P )
    stable-sort pools by b(P), ties by current index
```
Accept the new order only if it reduces message-flow crossings by `≥ 2` **and** the pool set is not user-ordered. Otherwise keep input order (stability, `LANE_REORDER = 80`).
**Additional rule:** the pool containing the process that **initiates** the collaboration (has the earliest start event, or is the source of the first message) is placed topmost, which makes the collaboration read top-down as well as left-right.
**Detect:** count message-flow crossings; compare with the barycenter alternative.
**Repair:** reorder; re-route all message flows.

---

### LANE-014 :: Black-box and collapsed pools
**Priority:** STRONG
**Rule:** a black-box pool is a bare rectangle of height `BLACKBOX_H (6U)` and the shared pool width, with its label in the header band. Message flows attach directly to its top or bottom border at `x = cx(otherEndpoint)`, giving 0-bend message flows wherever possible. Black-box pools are placed at the top or bottom of the pool stack (never between two expanded pools) unless message-flow crossing count strictly requires otherwise.
**Rationale:** an external participant surrounded by internal ones creates unnecessary long message flows and breaks the "our process is the core" reading.
**Detect:** a black-box pool between two expanded pools with no crossing benefit.
**Repair:** move to the nearest end of the stack.

---

### LANE-015 :: Lane whitespace
**Priority:** MEDIUM
**Rule:** target lane fill: the content box of a lane should occupy `≥ 60 %` of the lane's inner height (`contentH ≥ 0.6·(laneH − 2·CONTAINER_PAD_Y)`), by construction this is `100 %` unless `LANE_MIN_H` binds. Horizontal whitespace inside a lane is not compacted (LANE-007).
**Detect:** `laneH − contentH − 2·CONTAINER_PAD_Y > 4U` with `laneH > LANE_MIN_H`.
**Repair:** shrink the lane to content + padding.

---

## H. Labels and Secondary Artifacts

### H.1 Labels

### LABEL-001 :: Activity labels (internal)
**Priority:** STRONG
**Rule:** centered horizontally and vertically inside the shape; text box `= (w − 2·LABEL_PAD) × (h − 2·LABEL_PAD − markerBand)`; word wrap; `≤ TASK_MAX_LINES (4)` lines; growth ladder per LAYOUT-029. First line indented `16 px` when a type marker is present. No hyphenation; break on whitespace, then on `/` and `-`, then hard-break.
**Detect:** HC-012.
**Repair:** growth ladder.

### LABEL-002 :: Gateway labels
**Priority:** MEDIUM
**Rule:** the gateway's own label (the question, e.g. "Credit OK?") is placed **above** the gateway, centered on `cx`, at `top − LABEL_GAP − labelH`, max width `LABEL_MAX_W`, wrapped to as many lines as it needs (see LABEL-012 on why two is not a cap). If the space above is occupied by a loop corridor or a branch band within `LABEL_CLEAR`, move to **below**; if both are occupied, move to above-left with the label's right edge at `cx − 1U`.
**Detect:** label box intersecting a corridor, band, or edge.
**Repair:** try anchors in order `[above, below, above-left, below-left]`; the first legal one wins (deterministic).

### LABEL-003 :: Event labels
**Priority:** MEDIUM
**Rule:** placed **below** the event, centered on `cx`, at `bottom + LABEL_GAP`, max width `LABEL_MAX_W`, wrapped to as many lines as it needs (LABEL-012). Fallback order: `[below, above, right, left]`. Start and end events on the spine therefore have their labels in the artifact gutter below, the gutter accounts for them (LAYOUT-013).
**Special case:** consecutive events in a chain whose label boxes would overlap are alternated `below, above, below…` in column order, deterministic and better than shrinking.
**Detect:** label overlap with another label or shape.
**Repair:** alternate anchors; never reduce the font.

### LABEL-004 :: Boundary event labels
**Priority:** MEDIUM
**Rule:** placed below-left of the event when the event is on the bottom edge (so it does not collide with the exception route leaving downward at `cx`), specifically with the label's **right** edge at `cx − 1U`, top at `bottom + LABEL_GAP`. Mirror for top-attached events.
**Fallback order:** `[below-left, below-right, above-left, above-right, left, right]`, then LABEL-006. The mirror is part of the ladder, not just of the top/bottom case: two boundary events on one host are `BE_GAP` apart along an edge that is rarely as wide as one of their captions, so a ladder that only ever reaches left runs out of anchors on the second event and lands its caption on the first. Reaching left, then right, puts the pair on opposite sides of the fan, which is also how a person draws it.
**Rationale:** the exception stub occupies the vertical line at `cx`; centering the label there guarantees a collision.

### LABEL-005 :: Sequence-flow labels
**Priority:** STRONG
**Rule:** anchored to the **first horizontal segment after the source**, offset `FLOW_LABEL_OFFSET` **above** the segment, left-aligned at the segment's start `+ 1U`. If the segment is shorter than `labelW`, the label overhangs to the right (toward the target), never to the left (toward the source).
For a **split comb**, the horizontal peel segment starts at `x = cx(gateway)`. Therefore all outgoing labels of one gateway share the same left `x` and form a **vertically aligned stack**, deterministic, and the single most effective device for making Yes/No labels look deliberate.

That shared `x` is `cx(gateway) + 1U`, **moved right until every label in the stack clears the split's own glyph.** A gateway is a diamond: the corners of its bounding box are empty ink, so the box is not the test, but the band beside its centre line is not empty at all, and the axis branch's label sits exactly there, `FLOW_LABEL_OFFSET` above `gy`. At `1U` from centre a `50 px` diamond is still solid, and the label is drawn across the `X`. The *whole* stack moves, not the offending label: moving one would break the alignment the rule exists for, and moving all of them costs a few pixels of run.
```
labelX = max( stackX , segStartX + 1U )
stackX = cx(gateway) + 1U                          , raised so that for every
         label L in the stack whose y-range meets the gateway's:
           labelX ≥ cx + inkReachRight(L) + LABEL_CLEAR
inkReachRight(L) = GW/2 − minDistance(L.yRange, gy)   (a diamond; GW/2 for a box)
labelY = segY − FLOW_LABEL_OFFSET − labelH        (above the segment)
for the axis branch: labelY = gy − FLOW_LABEL_OFFSET − labelH  (above the straight run)
```
**Vertical segments** (rare for labels): label to the **right** of the segment, offset `FLOW_LABEL_OFFSET`, top-aligned at the segment start `+ 1U`.
**Detect:** label not anchored to the first horizontal segment; labels of one gateway with differing `x`.
**Repair:** re-anchor; align the stack.

### LABEL-006 :: Flow-label collision resolution
**Priority:** MEDIUM
**Rule:** ordered anchor fallback for any flow label: `[above-segment-start, below-segment-start, above-segment-middle, below-segment-middle, above-segment-end]`. Take the first anchor whose box is `LABEL_CLEAR`-free from all shapes, other labels, and non-owning edges. If none is free, **make room**: widen the owning gap by `labelH + 2·LABEL_CLEAR` (band gap) or `labelW + 2U` (column gap) and retry from the first anchor.

Retrying the whole ladder one grid unit further out, up to `LABEL_PUSH_STEPS = 8`, is the same move made from the other end and is what an implementation that places labels after its bands may do instead, a label is part of the diagram bounds (LABEL-011), so a label that steps past the last band grows the diagram to hold it. The step is a grid unit rather than a label height on purpose: the first free position is the one the label takes, and a coarse step walks a caption past the shape it names when a position 10 px nearer was free. Reaching the end of the ladder with nowhere free is a **LABEL-011 violation**, not a licence to overlap.

**Never** solve a label collision by shrinking the font, rotating the text, or hiding the label.

### LABEL-007 :: Default-flow and conditional labels
**Priority:** MEDIUM
**Rule:** a default flow is marked by the tick glyph (EDGE-022) and is labelled `"otherwise"` only if the source model provides a name, the formatter does not invent labels. When present, it uses LABEL-005 like any other flow label but is always placed on the axis branch's straight run, so it sits directly above the spine, accepted, since the spine has no other content there.

### LABEL-008 :: Pool and lane labels
**Priority:** STRONG
**Rule:** rotated 90° CCW, centered in the header band both ways, wrapped to the band's height, `≤ 2` lines. If the text does not fit at 2 lines, widen the band by `1U` steps to `5U`, then truncate with an ellipsis.

### LABEL-009 :: Message-flow labels
**Priority:** MEDIUM
**Rule:** anchored to the **middle** of the longest segment of the message flow (usually the vertical run in the inter-pool gap), offset `FLOW_LABEL_OFFSET` to the **right** of a vertical segment or above a horizontal one. Message-flow labels are obstacles for other message flows (EDGE-018).

### LABEL-010 :: Artifact labels
**Priority:** MEDIUM
**Rule:** data objects and data stores: label centered below the shape, `≤ 2` lines, max width `LABEL_MAX_W`. Text annotations: text is inside the annotation shape (LABEL-001 rules with `LABEL_PAD` and a left bracket band of `1U`).

### LABEL-011 :: Labels as first-class geometry
**Priority:** STRONG
**Rule:** every label has a rectangle in `RG` and participates in: bounding-box computation (BRANCH-002), collision detection (phase 10), routing obstacles (EDGE-018), whitespace metrics (LAYOUT-023), and diagram bounds (LAYOUT-031). A formatter that treats labels as decoration will produce overlapping output on every second diagram.

A label therefore may not overlap a shape, another label, or a connector. The exemptions are exactly the ones placement works to: a label may overlap the element it names, and a flow label may overlap its two endpoint shapes (§L pattern B puts a branch label in the empty ink of a diamond's bounding box) and its **own** connector, which is drawn offset from the segment it annotates (EDGE-018). Everything else is a **tier-1 violation** and fails the build: LABEL-006's answer to a collision is always more room, so reaching the end of the ladder with nowhere free means the formatter failed to make room, and that is worth an error rather than a score point.
**Detect:** any label rect absent from the spatial index; any label rect intersecting a shape, another label, or a foreign connector.
**Repair:** insert and re-run phase 10; then LABEL-006's ladder. A connector routed **after** phase 9, a message flow, which belongs to the collaboration and not to any one scope, introduces an obstacle the ladder never saw, and must re-run it for the labels it crosses (EDGE-018's repair).

### LABEL-012 :: Label text measurement
**Priority:** STRONG
**Rule:** layout must use a real text-measurement function (font metrics), not `charCount × avgWidth`.

**An external label's box is as tall as its wrapped text, always.** Two lines is what most captions take and what LABEL-002/003 are written around, but it is not a cap on the *measurement*: BPMN DI carries a bounds rectangle and the renderer sets the element's own `name` inside it, so a formatter that measures two lines and emits a caption wrapping to four has not shortened the label, it has shortened only its own idea of it, and the extra lines are drawn over whatever the band below reserved. Ellipsising the measured text is the same mistake under a better name, and LABEL-006 already forbids it: the ellipsis never reaches the file, so it hides the label from the formatter alone.

Where a cap is real, it is because something else absorbs it: an activity's internal text is capped at `TASK_MAX_LINES` because the shape *grows* to meet it (LAYOUT-029) and HC-012 checks the result. There is no equivalent growth for a label beside a shape, so there is no equivalent cap. If no measurement is available, the fallback is `w ≈ 0.62 · FONT_SIZE · charCount` with an added `10 %` safety margin, and all label-driven growth thresholds are treated as approximate. The chosen measurement function is part of the determinism contract (LAYOUT-027): the same font metrics must be used in every run.

### H.2 Artifacts

### ART-001 :: Data object placement
**Priority:** MEDIUM
**Rule:** data objects, data inputs and data outputs are placed in the **artifact gutter above** their associated activity, at `ARTIFACT_GAP` from the activity's top edge, with `cx` aligned to the activity's `cx` (or to an offset port when several artifacts attach). Data **stores** are placed in the gutter **below** by default (they represent persistent systems, and the convention keeps the two artifact classes visually separable), moving above if the below gutter is occupied by an exception band.
```
y(artifact) = top(host) − ARTIFACT_GAP − h(artifact)
cx(artifact) = cx(host)                       # single artifact ⇒ 0-bend association
```
**Detect:** artifact farther than `2·ARTIFACT_GAP` from its host, or on the wrong side of the spine relative to its class.
**Repair:** re-place; re-route the association.

### ART-002 :: Multiple artifacts on one host
**Priority:** MEDIUM
**Rule:** artifacts on the same side are laid out left→right in the gutter, spaced `2U`, the group centered on the host's `cx`; each attaches to a distinct offset port on the host's top/bottom edge, assigned in the same left→right order (guarantees no association crossings).
```
groupW = Σ w_k + 2U·(K−1)
x_1 = cx(host) − groupW/2 ;  x_{k+1} = x_k + w_k + 2U
port_k = offset port at cx(host) + (k − (K+1)/2)·PORT_OFFSET_MIN
```
**Detect:** crossing associations; artifacts overlapping.
**Repair:** re-run the group formula.

### ART-003 :: Association routing
**Priority:** MEDIUM
**Rule:** per EDGE-017: prefer 0 bends (vertical, aligned `cx`); at most 1 bend. Associations are dotted and must never be confused with sequence flow: an association may not run collinear with a sequence flow within `2U` for a projected length `> 4U`.
**Detect:** near-collinear association/sequence pair.
**Repair:** shift the artifact by `2U` along the gutter.

### ART-004 :: Artifacts must not dominate
**Priority:** MEDIUM
**Rule:** total artifact area in a region must not exceed `40 %` of node area; artifacts never occupy a band between two node bands (they live in gutters attached to their host); an artifact never sits on the spine.
**Detect:** artifact `cy` within `TASK_H/2` of the spine at a column where a spine node exists.
**Repair:** move to the gutter.

### ART-005 :: Groups
**Priority:** MEDIUM
**Rule:** a group is a rectangle enclosing its members with padding `CONTAINER_PAD_Y` on all sides, drawn behind everything, and **it does not constrain layout**, it is computed after node placement as the bounding box of its members plus padding. If the members are not contiguous (their bbox contains non-members), emit an advisory; do not move nodes to satisfy a group. Group label: top-left, inside, offset `1U`.
**Rationale:** groups are annotations, not containers; letting them drive layout produces severe distortion for zero semantic gain.
**Detect:** group bbox containing non-members.
**Repair:** advisory only.

### ART-006 :: Text annotations
**Priority:** MEDIUM
**Rule:** annotations attach in the gutter **below** their referenced element by default (above if the below gutter is occupied), at `ARTIFACT_GAP`, with the association leaving the annotation's left edge horizontally toward the element's `cx` when the annotation is offset, or vertically when aligned.
- Maximum distance from the referenced element: `3·ARTIFACT_GAP`; beyond that, the association is too long to read and the annotation is moved.
- Sizing: width `= clamp(measuredW, ANNOT_W_MIN, ANNOT_W_MAX)`, height `= lines·LINE_H + 2·LABEL_PAD`, wrapping at the chosen width.
- An annotation belonging to a node in an upper or lower **branch** stays inside that branch's gutter and therefore inside the branch bbox — it must never protrude into a sibling branch's band; if it would, the branch gap grows (BRANCH-016).
- Annotations contribute to bounding boxes (BRANCH-002) and to diagram bounds.
**Detect:** annotation outside its owner branch's bbox; association longer than `3·ARTIFACT_GAP`.
**Repair:** move into the gutter; grow the gap.

### ART-007 :: Artifact–corridor precedence
**Priority:** STRONG
**Rule:** artifact gutters are allocated **before** loop corridors and exception bands. A corridor never crosses an artifact; the corridor moves outward instead. Conversely, an artifact never moves to make room for a corridor.
**Rationale:** artifacts are anchored to a specific host and lose meaning when displaced; corridors are free to move.
**Detect:** corridor ∩ artifact gutter ≠ ∅.
**Repair:** shift the corridor by `CORRIDOR_PITCH` outward; grow the region bbox.

---

## I. Anti-Patterns, Edge Cases and Scale

### I.1 Anti-pattern catalogue

Each entry: **why it is bad → computational detector → repair**. All detectors run in phase 13 and produce a scored report.

| ID | Anti-pattern | Why bad | Detector | Repair |
|---|---|---|---|---|
| `AP-001` | **Diagonal connector** | breaks the orthogonal visual language; direction of travel becomes ambiguous at junctions | any segment with `Δx≠0 ∧ Δy≠0` | re-route per EDGE-005/015 (HC-001) |
| `AP-002` | **Gateway branches exiting in random directions** (one from `E`, one from `S`, one from `W`) | the fan stops reading as one decision | outgoing edges of one split use `>2` distinct ports, or a port other than `{N,E,S}` | re-route as the canonical comb (EDGE-005) |
| `AP-003` | **Split and merge misaligned** | destroys the visual pairing; the region no longer reads as a unit | `|cy(split) − cy(merge)| > ALIGN_TOL` and both in one lane | set `cy(merge)=cy(split)` (BRANCH-012) |
| `AP-004` | **Inconsistent sibling branch spacing** | implies a grouping that does not exist | within one region, `max G[i] − min G[i] > ALIGN_TOL` with no channel/label justification | recompute `G[i]` (BRANCH-016); equalize |
| `AP-005` | **Near-miss alignment (off by a few px)** | reads as sloppiness; the eye detects `2 px` misalignment instantly | `0 < |cy(u) − cy(v)| ≤ ALIGN_TOL` for any pair in the same band | snap both to the band axis (LAYOUT-011) |
| `AP-006` | **Connector grazing an element border** | ambiguous attachment; looks like a connection that isn't one | segment within `[0, EDGE_CLEAR)` of a non-incident node box | re-channel (EDGE-020) |
| `AP-007` | **Huge empty space beside a short branch** | suggests missing content; wastes area | maximal empty rect inside the content bbox with `w ≥ 3·NODE_GAP_X ∧ h ≥ 2·TASK_H`, no corridor/label | compaction (LAYOUT-021/022); check that symmetry was not wrongly forced (BRANCH-020) |
| `AP-008` | **Loopback cutting through the main flow** | the most damaging single defect: forward and backward flow become indistinguishable | a back edge whose route intersects the spine band or any node band | corridor re-allocation (LAYOUT-018) |
| `AP-009` | **Floating branch labels** | the reader cannot tell which branch a label belongs to | label centroid closer to a foreign edge than to its own, or `>2U` from its own segment | re-anchor per LABEL-005; align the gateway's label stack |
| `AP-010` | **Unjustified backward movement on a forward edge** | implies a loop that doesn't exist | any `Δx<0` segment on a non-back edge (EDGE-021) | re-layer |
| `AP-011` | **Arbitrary task size variation** | size implies importance; random sizes imply random importance | `stdev(w)/mean(w) > 0.05` over activities whose labels fit at `TASK_W` | reset to canonical (LAYOUT-003) |
| `AP-012` | **Inconsistent pool padding** | pools stop reading as a family | pool inner padding differs across pools by `>0`; unequal pool widths | normalize (LANE-012) |
| `AP-013` | **Branch order causing avoidable crossings** | crossings that a permutation would remove | for each region, evaluate crossings under the current order vs the BRANCH-007 order | re-rank branches; accept if crossings drop by `≥2` (stability threshold) |
| `AP-014` | **Vertical explosion from nesting** | every nesting level adds constant padding, so depth-4 nesting produces a 3000 px tall diagram | region height `>` `Σ` of leaf content heights `+ Σ` required gaps by more than `2U` per level | remove per-level padding; use BRANCH-015/016 (content-driven gaps only) |
| `AP-015` | **Overly tight gateway spacing** | two diamonds `<20 px` apart fuse into one shape | gateway pair with gap `< COMPACT_GAP` | LAYOUT-032 |
| `AP-016` | **Staircase layout** | every node offset slightly from the previous; no alignment tracks emerge | `>3` consecutive flow nodes with pairwise distinct `cy` and pairwise `|Δcy| < TASK_H` | assign all to one band; re-run LAYOUT-011 |
| `AP-017` | **Many tiny bends** | reads as noise; each bend costs a fixation | an edge with `≥2` segments shorter than `MIN_SEG`, or `bends > budget` (EDGE-007) | simplify waypoints (HC-010), then re-route |
| `AP-018` | **Visually unbalanced peer branch group** | falsely signals that one AND branch is dominant | `peerSymmetric(R) ∧ symmetryDefect > 0.15` | re-center in `BBOX_CENTER`; pad gaps (BRANCH-020) |
| `AP-019` | **Edge routed under a label** | the label becomes unreadable and the edge appears to terminate | segment ∩ (foreign label rect inflated by `LABEL_CLEAR`) ≠ ∅ | re-channel or re-anchor the label (EDGE-018 / LABEL-006) |
| `AP-020` | **Merge pulled left to meet a short branch** | breaks ASAP layering; makes a short branch look longer than the long one | `layer(merge) < max_i maxLayer(b_i) + 1` | re-layer (BRANCH-011) |
| `AP-021` | **Exception path above the spine while a normal branch is below** | inverts the visual hierarchy of §16 | an EXCEPTION-polarity branch with `cy < spineY` while a NEUTRAL/POSITIVE branch has `cy > spineY` | swap sides (BRANCH-007) |
| `AP-022` | **Nodes vertically stacked in the same column across lanes with no horizontal progress** | reads as simultaneity; hides handoff order | cross-lane edge with `left(v) − right(u) < NODE_GAP_X_MIN` | LANE-009 |
| `AP-023` | **Collinear overlapping edges outside a bundle** | multiplicity becomes invisible | HC-009 detector | re-channel |
| `AP-024` | **Lane taller than its content by a wide margin** | dilutes the lane↔content association | `laneH − contentH − 2·CONTAINER_PAD_Y > 4U` and `laneH > LANE_MIN_H` | LANE-003 |
| `AP-025` | **Crossing at a junction** | a crossing within `3U` of a bundle T-point is indistinguishable from a join | crossing point within `3U` of any port or junction | shift the crossing along its channel (EDGE-011) |

---

### I.2 Difficult edge cases and fallback behaviour

| Case | Behaviour |
|---|---|
| **Gateway directly followed by a gateway** | LAYOUT-032, BRANCH-021/022. Consecutive columns at `COMPACT_GAP`, shared axis, no channel between them. |
| **Split whose child is another split** | BRANCH-021. Inner region is centered on the outer branch's axis, uses the global column grid, no indentation. |
| **Merge immediately followed by a split** | BRANCH-022. Single cluster; increase to `NODE_GAP_X` when both fans have `≥3` edges. |
| **Cycles involving multiple gateways** | SCC detection first. If the SCC is reducible (single entry), treat the entry as the loop header and the exit edges as forward edges, the loop region rule applies. If **irreducible** (multiple entries), mark the SCC unstructured (LAYOUT-033), lay it out with the Sugiyama fallback inside one opaque block, and route all back edges of the block in corridors above it. |
| **Multiple merges for one split** | The region is not SESE. Take `m = immediatePostDominator(split)` as the *structural* merge and treat the earlier partial merges as ordinary implicit merges inside branches (BRANCH-018). If no common post-dominator exists before the scope exit, the region is open (BRANCH-019). |
| **Branches sharing nodes** (a node reachable from two branches of one split without passing the merge) | Not SESE ⇒ unstructured. Fallback: assign the shared node to the band of its **highest-ranked** predecessor branch; its other incoming edges become cross-band edges routed in channels. |
| **Crossing dependencies** (edges between branch interiors) | Same as above. These edges are routed in channels between bands; they are the only legitimate source of crossings in an otherwise structured diagram. |
| **Extremely large diagrams** | LAYOUT-028 large mode. |
| **Dozens of outgoing branches** | BRANCH-006 `FAN_COLUMN` at `n ≥ 7` (except event-based). At `n ≥ 20`, emit an advisory recommending a subprocess or a data-driven decision table; still lay out with `FAN_COLUMN` and `ceil(n/5)` sub-fans. |
| **Tiny lane containing a complex flow** | Lane height is content-driven (LANE-003), so the lane simply grows. If a *fixed* lane height is imposed by the caller, the flow inside is compacted to `BRANCH_GAP_Y_MIN` and, if still overflowing, the constraint is broken and reported, never clip content. |
| **Extensive exception handling** (many boundary events) | Exception bands stack downward (LAYOUT-017). If the exception band stack exceeds `4` bands, switch those handlers to **collapsed** rendering advisory, and route their exception flows through a single shared channel with distinct entry points (still crossing-free by LAYOUT-016 ordering). |
| **No crossing-free layout exists** | Accept crossings; ensure each is *clean* (EDGE-011). Do not spend area to avoid an inherent crossing: detect inherence by checking whether the region is non-planar for every branch permutation of size `≤ 5` (exhaustive for `n ≤ 5`, heuristic beyond). |
| **Conflicting manual pins** | LAYOUT-025: honour by `(documentOrder, id)`, break and report the rest. |
| **Zero-node scope / empty subprocess** | Render at `SUB_MIN_W × SUB_MIN_H` with padding; no advisory. |
| **Node in no lane (pool-level node in a pool with lanes)** | Assign to the lane of its highest-ranked predecessor; if none, the first lane. Report. |

**When to abandon the ideal pattern.** The formatter gives up on structured geometry and falls back to Sugiyama-in-a-block (LAYOUT-033) exactly when region decomposition fails, not when the result merely looks imperfect. The fallback is local: the rest of the diagram keeps the structured treatment.

---

### I.3 Large-diagram behaviour (thresholds)

| Signal | Threshold | Effect |
|---|---|---|
| `|V|` | `> 150` | large mode (LAYOUT-028) |
| `maxLayer` | `> 40` | advise link events / subprocess extraction; keep one row (LAYOUT-010) |
| lanes | `> 8` | lane heights become content-driven only; disable `LANE_EQUAL_HEIGHT`; consider pool splitting advisory |
| `maxBranchFactor` | `> 6` | `FAN_COLUMN` (BRANCH-006) |
| density `|E|/|V|` | `> 1.8` | more channels per gap (4), unstructured fallback more likely; disable symmetry |
| region count | `> 40` | modular halo mode: each region ≥ 8 nodes gets a `2U` halo and is compacted independently |

Large diagrams get **more** spacing, not less (`NODE_GAP_X → 7U`, `BRANCH_GAP_Y → 8U`): at low zoom the eye needs larger gaps to segment shapes, and compressed large diagrams become unreadable exactly when they most need to be scanned. Compensate for the added area by aggressive modular compaction *within* regions rather than by shrinking global gaps.

---

## J. Layout Algorithm

Fourteen phases. Each phase declares `reads → writes`. Phases 1–5 touch only `LLS`; 6–12 produce `RG`; 13–14 evaluate and refine.

```
format(SG, previousRG?, pins?) -> RG

# ── Phase 1: graph analysis ────────────────────────────────── SG → LLS
P1:
  canonicalize(SG)                       # sort all collections by (documentOrder, id)
  for each scope S in [process, each expanded subprocess]:   # recursive, post-order
      G  = flowGraph(S)                  # nodes + sequence flows; boundary events attached
      T  = dfsSpanningTree(G, sortedOrder)
      Back = backEdges(T)                # loops
      SCC = tarjanSCC(G)                 # irreducible loop detection
      D   = dominators(G \ Back)         # Lengauer–Tarjan
      PD  = postDominators(G \ Back)
      topo= topologicalOrder(G \ Back)
  outputs: Back, SCC, D, PD, topo

# ── Phase 2: structural region detection ───────────────────── LLS → LLS
P2:
  loops   = buildLoopRegions(Back, SCC)                       # BRANCH-017
  regions = buildSESERegions(D, PD)                           # BRANCH-001
  residue = maximalSubgraphsWithoutValidRegion()              # LAYOUT-033
  regionTree = nest(regions ∪ loops ∪ residue)
  spine   = computeSpine(D, PD, rankBranches)                 # LAYOUT-006
  classify each branch: polarity, terminates, span, nodeCount # BRANCH-007
  classify each region: hasPrimary, peerSymmetric, open       # BRANCH-003/019/020

# ── Phase 3: layering ──────────────────────────────────────── LLS → LLS
P3:
  layer(v) = 0 for sources
  for v in topo: layer(v) = max(layer(u)+1 for u→v ∉ Back)    # LAYOUT-004
  apply pin constraints (LAYOUT-025) and lane-progress constraints (LANE-009)
  insert virtual nodes for edges spanning >1 layer            # LAYOUT-009

# ── Phase 4: branch ordering ───────────────────────────────── LLS → LLS
P4:
  for each region R (any order; result is order-independent):
      order  = sort(R.branches, comparator BRANCH-007)
      sides  = assignSides(order)  ∈ {ABOVE, AXIS, BELOW}     # BRANCH-006 step 2–4
      rebalance(sides)                                        # BRANCH-006 step 3
      if incremental: keep previous order unless ΔScore ≥ 25  # LAYOUT-024
      if |R.branches| ≥ 7 and R.type ≠ eventBased: FAN_COLUMN # BRANCH-006

# ── Phase 5: bounding boxes (post-order recursion) ─────────── LLS → LLS
P5:
  layoutRegion(R):                                            # BRANCH-015
      for b in R.branches:
          for N in nestedRegions(b) in layer order: layoutRegion(N)
          allocateArtifactGutters(b)                          # ART-001/007
          allocateExceptionBands(b)                           # LAYOUT-017
          allocateLoopCorridors(b)                            # LAYOUT-018
          (H[b], A[b], W[b]) = accumulateBranchBox(b)         # BRANCH-002
      G[i]  = gapBetween(b_i, b_{i+1})                        # BRANCH-016
      slots = stack(order, sides, H, A, G)
      mode  = AXIS_LOCK if hasPrimary else BBOX_CENTER        # BRANCH-008
      (R.H, R.A) = centerStack(slots, mode)
  layoutRegion(rootRegion)

# ── Phase 6: x assignment ──────────────────────────────────── LLS → RG.x
P6:
  colW(c) = max(w(v) : layer(v)=c)                            # after LAYOUT-029 sizing
  colX(0) = MARGIN
  for c: colX(c+1) = colX(c) + colW(c) + gapBetween(c, c+1)   # LAYOUT-005
  x(v)    = colCx(layer(v)) − w(v)/2

# ── Phase 7: y assignment ──────────────────────────────────── LLS → RG.y
P7:
  if hasLanes:
      partition regions by lane                               # BRANCH-023
      for each lane L (top→bottom):
          stack L's bands around laneSpineY(L)                # LANE-006/008
          laneH(L) = max(LANE_MIN_H, contentH(L)+2·PAD_Y)     # LANE-003
          laneY(L) = laneY(L−1) + laneH(L−1)                  # LANE-002
  else:
      spineY = MARGIN + rootRegion.A
      apply slots recursively from rootRegion
  y(v) = bandAxisY(band(v)) − above(v)                        # LAYOUT-012 / LAYOUT-020
         # above(v) = h(v)/2 for every node but an expanded subprocess,
         # whose axis is its internal spine and whose extent is asymmetric
  size containers bottom-up                                   # LAYOUT-019, LANE-004

# ── Phase 8: connector routing ─────────────────────────────── RG → RG.waypoints
P8:
  buildChannelModel()                                         # EDGE-008
  for each edge e in sorted order (srcLayer, srcBand, tgtBand, id):
      class = classify(e)   # straight | split | merge | crossLane | loop | boundary | message | assoc
      candidates = canonicalRoutes(class)                     # EDGE-025
      route(e) = argmin routeCost(candidate)                  # EDGE-019
      assignChannels(route(e))                                # EDGE-008/010
  validate HC-001, HC-004, HC-005, HC-009

# ── Phase 9: label placement ───────────────────────────────── RG → RG.labels
P9:
  for each element with an external label: place at primary anchor (LABEL-002/003/004)
  for each flow label: anchor to first horizontal segment (LABEL-005)
  align each gateway's outgoing label stack to x = cx(gateway) + 1U
  resolve collisions by ordered anchor fallback (LABEL-006)
      # obstacles: shapes, labels already placed, and connectors (EDGE-018)
      # if the ladder is exhausted, retry it further out; else LABEL-011 fails
  register all label rects in the spatial index (LABEL-011)

# ── Phase 10: collision removal ────────────────────────────── RG → RG
P10:
  repeat until fixpoint (max 8 iterations, deterministic order):
      v1 = nodeOverlaps()      → separate along the axis of smaller displacement (HC-002)
      v2 = edgeNodeViolations()→ EDGE-020 repair ladder
      v3 = edgeOverlaps()      → next channel (HC-009)
      v4 = labelCollisions()   → LABEL-006
      v5 = containmentBreaks() → grow container (HC-003/HC-014)
      if no violations: break
  if not converged: widen the binding gap by 1U and restart (max 3 restarts)

# ── Phase 11: compaction ───────────────────────────────────── RG → RG
P11:
  columnCompaction()   # 1-D longest-path over the column constraint graph  (LAYOUT-021)
  bandCompaction()     # same over bands, symmetry-aware                     (LAYOUT-022)
  laneShrink()         # LANE-003/015
  re-route only edges whose endpoints or channels moved
  re-validate HARD constraints; roll back any compaction step that fails

# ── Phase 12: alignment refinement ─────────────────────────── RG → RG
P12:
  snap all shape centers to the U grid                        # LAYOUT-002
  snap waypoints perpendicular to their segments
  straighten near-straight edges: if |Δcy| ≤ ALIGN_TOL for a flow-adjacent pair,
      set both to the band axis and replace the route with the 0-bend form (EDGE-003)
  simplify waypoints (HC-010)
  translate diagram to (MARGIN, MARGIN)                       # LAYOUT-031

# ── Phase 13: scoring ──────────────────────────────────────── RG → report
P13:
  score = qualityScore(RG)                                    # §K
  antiPatterns = runDetectors(AP-001..AP-025)
  emit report(score, violations, advisories)

# ── Phase 14: bounded improvement ──────────────────────────── RG → RG
P14:
  budget = large ? 2·|regions| : 6·|regions|
  candidates = [ branchReorder(R) for R with crossings > 0 ]
             + [ sideFlip(b)     for b with polarity NEUTRAL ]
             + [ channelSwap(e1,e2) for crossing pairs ]
             + [ portReassign(v)  for v with >2 same-side edges ]
             + [ axisModeToggle(R) for R with symmetryDefect > 0.15 ]
  sort candidates deterministically by (regionId, candidateType, elementId)
  for cand in candidates while budget-- > 0:
      apply; re-run phases 8–13 for the affected region only
      keep iff Δscore < −(stabilityCost(cand))                # LAYOUT-024
      else revert
  return RG
```

**Complexity.** P1 `O(V+E α)`; P2 `O(V+E)`; P3 `O(V+E)`; P4 `O(Σ n log n)`; P5 `O(V)`; P6/P7 `O(V)`; P8 `O(E · C)` with `C` = channels per gap (bounded); P10 `O(k(V+E) log V)` with a sweep-line index; P11 `O(V+E)`; P14 `O(budget · localCost)`. Overall near-linear for structured graphs, which is why the structured path is preferred to any global optimization.

---

## K. Diagram Quality Function

```
score(RG) = Σ over components below.  Lower is better. 0 is a perfect layout.

# ── Tier T0: validity, effectively infinite ───────────────────────────
overlapPenalty        = 10^6 · nodeOverlapCount
containmentPenalty    = 10^6 · containmentViolations
edgeThroughNode       = 10^6 · edgeNodeIntersections          # clearance < EDGE_CLEAR
nonOrthogonal         = 10^6 · diagonalSegments
illegalOverlapPenalty = 10^6 · nonBundledCollinearOverlaps

# ── Tier T1: positional semantics ─────────────────────────────────────
backwardPenalty       = 500 · forwardEdgesWithNegativeProgress
layerViolation        = 500 · edgesViolatingTopologicalLayering
boundaryDetach        = 500 · boundaryEventsOffHostBorder
bandFragmentation     = 200 · branchesWhoseNodesOccupyMultipleBands
labelOverlap          = 500 · labelsOnAShape, AForeignLabel, OrAForeignEdge   # LABEL-011

# ── Tier T2: comprehension ────────────────────────────────────────────
crossingPenalty       = 40 · sequenceCrossings
                      + 15 · sequenceMessageCrossings
                      + 60 · crossingsWithin3UOfAJunction
spineBendPenalty      = 60 · bendsOnSpineEdges                # spine must be straight
bendPenalty           = 6  · Σ_e max(0, bends(e) − budget(class(e)))
                      + 2  · Σ_e bends(e)                     # mild pressure below budget
proximityPenalty      = 12 · segmentsWithin(EDGE_CLEAR, 2·EDGE_CLEAR) of a node
labelCollision        = 30 · labelPairsOverlapping           # a gradient, not a gate:
                      + 20 · labelsCrossedByEdges           # labelOverlap already rejects
                                                            # these, so this term ranks the
                                                            # candidates phase 14 discards
tinySegmentPenalty    = 8  · segmentsShorterThan(MIN_SEG)

# ── Tier T3: regularity ───────────────────────────────────────────────
alignmentPenalty      = 2  · nodesOffTheirBandAxis
                      + 2  · nodesOffTheirColumnCenter
                      + 10 · splitMergePairsWithDifferentCy
gapUniformity         = 25 · max(0, CV(columnGaps) − 0.10)
                      + 15 · max(0, CV(bandGaps)   − 0.15)
asymmetryPenalty      = 20 · Σ_{R peerSymmetric} max(0, symmetryDefect(R) − 0.15)
sizeUniformity        = 15 · max(0, CV(activityWidths) − 0.05)
labelStackPenalty     = 5  · gatewaysWhoseOutLabelsAreNotXAligned

# ── Tier T4: economy ──────────────────────────────────────────────────
areaPenalty           = 8  · max(0, bboxArea / contentHullArea − 2.5)
edgeLengthPenalty     = 0.02 · Σ_e lengthPx / U
aspectPenalty         = 5  · max(0, aspectRatio − 6.0) + 5 · max(0, 0.8 − aspectRatio)
whitespacePenalty     = 10 · sparseRegions + 20 · crampedRegions   # LAYOUT-023

# ── Tier T5: stability (incremental only) ─────────────────────────────
instabilityPenalty    = 0.5 · D                               # D from LAYOUT-024
```

**Reading the weights.**
- Anything at `10^6` is a hard constraint expressed as a penalty so that a solver can be used; a layout with a non-zero T0 term is *invalid*, not merely bad.
- `crossing (40) ≈ 6.7 bends ≈ 2000 px of edge length ≈ 5 misalignments`. This encodes the normative answer of §2.1: crossings are expensive, length is cheap, alignment is cheap.
- `spineBendPenalty (60) > crossingPenalty (40)`: bending the spine to avoid a crossing is never worth it.
- `areaPenalty` is expressed as a **ratio** (`bboxArea / contentHullArea`) with a free allowance of `2.5×`, so it never punishes a legitimately spread-out diagram, it only punishes waste.
- `aspectPenalty` implements the width-vs-height preference (§28): growth in width is free up to `6:1`, after which height becomes the cheaper direction.

**Local vs global balance.** Penalties are computed **per region** and summed, so a large diagram cannot mask a badly laid-out region behind a good global average. Phase 14 optimizes the worst-scoring region first (deterministic tie-break by region id). A per-region normalized score `score(R)/|V(R)|` is reported to make regions comparable.

**Absolute quality gates (fail the build):** any T0 term `> 0`; any T1 term `> 0`; `spineBendPenalty > 0`; `bends(e) > 6` for any edge.

---

## L. Canonical Examples

Coordinates use `U = 10`, `MARGIN = 40`. Only representative values are shown; all follow from §B and §LAYOUT-005.

### Pattern A :: `Start → Task → Task → End`

```
 (42,62)     (140,40)          (300,40)         (462,62)
   ( )──────►┌─────────┐──────►┌─────────┐──────►(( ))
             │ Task A  │       │ Task B  │
             └─────────┘       └─────────┘
   spineY = 80 for every node's center;  gaps 62 / 60 / 62
```
`Start` center `(60,80)`, `Task A` center `(190,80)`, `Task B` center `(350,80)`, `End` center `(480,80)`. All edges: 2 waypoints, 0 bends (EDGE-003). Diagram bbox `(42,40)–(498,120)`.

### Pattern B :: `Task → XOR → 2 branches → merge → Task` (AXIS_LOCK)

```
                       Yes
   ┌────────┐   ◇            ┌──────────┐            ◇   ┌────────┐
   │ Task A ├──►│ ├───────────► Approve  ├────────────►│ ├──►│ Task B │   spine y=200
   └────────┘   ◇            └──────────┘            ◇   └────────┘
                 │                                    ▲
                 │ No                                 │
                 │        ┌──────────┐                │
                 └───────►│ Reject   ├────────────────┘                   band y=340
                          └──────────┘
```
`Task A` c=(90,200) · `XOR split` c=(230,200) · `Approve` c=(390,200) · `Reject` c=(390,340) · `XOR merge` c=(530,200) · `Task B` c=(670,200).
Axis branch: 0 bends. Lower branch out: `[(230,225),(230,340),(340,340)]` 1 bend. Lower branch in: `[(440,340),(530,340),(530,225)]`  1 bend. `Δaxis = 140 = TASK_H + BRANCH_GAP_Y`. Both labels left-aligned at `x = 260` (LABEL-005): `cx + 1U` would be `240`, but the `Yes` label's band runs from `gy − 19` to `gy − 5`, where the diamond still reaches `20 px` from its centre, so the stack starts at `cx + 20 + LABEL_CLEAR`.

### Pattern C :: `Task → XOR → 3 branches → merge → Task`

```
                        ┌──────────┐
                  ┌────►│ Path 1   ├────┐                     y = 60
                  │     └──────────┘    │
   ┌────────┐   ◇ │     ┌──────────┐    │ ◇   ┌────────┐
   │ Task A ├──►│ ├────►│ Path 2   ├──────►│ ├──►│ Task B │    y = 200 (axis, rank-1)
   └────────┘   ◇ │     └──────────┘    │ ◇   └────────┘
                  │     ┌──────────┐    │
                  └────►│ Path 3   ├────┘                     y = 340
                        └──────────┘
```
Upper/center/lower (BRANCH-004). Axis branch straight through split and merge. Upper: out `[(230,175),(230,60),(340,60)]`, in `[(440,60),(530,60),(530,175)]`. Lower mirrors. `symmetryDefect = 0` when the three branches have equal heights.

### Pattern D :: `AND split → parallel branches → AND join` (BBOX_CENTER)

```
   ┌────────┐   ◆     ┌──────────┐     ◆   ┌────────┐
   │ Task A ├──►│+├─┬─►│ Task P   ├─┬──►│+├──►│ Task B │
   └────────┘   ◆  │  └──────────┘ │   ◆   └────────┘
                   │  ┌──────────┐ │
                   └─►│ Task Q   ├─┘
                      └──────────┘
   axes at spineY − 70 and spineY + 70 (no branch on the axis)
```
`AND split` c=(230,200); `Task P` c=(390,130); `Task Q` c=(390,270); `AND join` c=(530,200). Every branch has 1 bend out + 1 bend in. Congruence enforced: both branches occupy the same column (BRANCH-020).

### Pattern E :: main flow + early-ending branch

```
   ┌────────┐   ◇   ┌──────────┐   ┌──────────┐   (( ))
   │ Check  ├──►│ ├──► Fulfil   ├──►│ Ship     ├──►      main axis, unchanged
   └────────┘   ◇   └──────────┘   └──────────┘
                 │ rejected
                 │   ┌──────────┐   ((X))
                 └──►│ Notify   ├──►                     band below; ends ASAP
                     └──────────┘
```
The continuing path holds the axis (BRANCH-014 rule 1); the terminating path is below (rule 2); its end event sits at `layer(Notify)+1` and is *not* dragged right (rule 3); the baseline after the region is unchanged (rule 4).

### Pattern F :: boundary error event → handler → terminate

```
   ┌──────────────┐
   │  Call Payment│──────────────────────────────►  main axis
   └───────⊗──────┘
           │                                        exception band:
           │       ┌──────────────┐   ((X))         excBand.top = regionBBox.bottom + 50
           └──────►│ Compensate   ├──►
                   └──────────────┘
```
Boundary event centered at `hostX + w/2` for `k=1`; stub down to `handlerAxisY`; then east (EDGE-014, 1 bend). Handler content is in the exception band, below every ordinary branch (LAYOUT-017).

### Pattern G :: validation failure looping backward

```
        ┌────────────────── corridor y = regionTop − 30 ─────────────┐
        ▼                                                            │
   ┌──────────┐     ┌──────────┐     ◇                               │
   │ Fix Data ├────►│ Validate ├────►│ ├──────────► continue          │
   └──────────┘     └──────────┘     ◇                               │
                                      └──────────────────────────────┘   (invalid)
```
Back edge: `[(cx(gw), top(gw)), (cx(gw), corridorY), (cx(Fix), corridorY), (cx(Fix), top(Fix))]`  2 bends, enters the target from above (EDGE-013), corridor above the region bbox, never touching a node band.

### Pattern H :: cross-lane handoff

```
 ┌─Sales────────────────────────────────────────────────┐
 │        ┌──────────┐                                  │
 │        │ Qualify  ├──┐                               │   laneSpineY(Sales)
 │        └──────────┘  │                               │
 ├─Finance──────────────┼───────────────────────────────┤
 │                      └──►┌──────────┐                │
 │                          │ Approve  ├───►            │   laneSpineY(Finance)
 │                          └──────────┘                │
 └──────────────────────────────────────────────────────┘
```
Z route with the jog at the exact midpoint of the inter-column gap (EDGE-015); `left(Approve) − right(Qualify) ≥ NODE_GAP_X_MIN` (LANE-009).

### Pattern I :: two pools exchanging messages

```
 ┌─Customer──────────────────────────────────────────┐
 │  ( )──►┌────────┐──────────────►┌────────┐──►(( ))│
 │        │ Order  │               │ Receive│        │
 └────────────┬───────────────────────▲──────────────┘
              │ (message, 0 bends)    │ (message, 0 bends)
 ┌─Supplier───▼───────────────────────┼──────────────┐
 │        ┌────────┐             ┌────────┐          │
 │        │ Accept │────────────►│ Ship   │          │
 └───────────────────────────────────────────────────┘
```
Message flows are vertical, attach `S`→`N`, 0 bends where `cx` matches; otherwise the jog lies in the inter-pool gap (EDGE-016). Pool widths equal, left edges aligned (LANE-012).

### Pattern J :: nested gateways

```
   ┌────────┐   ◇        ◇   ┌────────┐         ◇   ┌────────┐
   │ Task A ├──►│ ├──┬───►│ ├──►│ A1    ├──┬─────►│ ├──►│ Task B │  spine y=200
   └────────┘   ◇   │    ◇   └────────┘  │      ◇   └────────┘
                    │      │ ┌────────┐  │
                    │      └►│ A2     ├──┘                          y=340 (inner band)
                    │        └────────┘
                    │  ┌────────┐
                    └─►│ B      ├──────────────────┘                y=480 (outer band)
                       └────────┘
```
The inner region is centered on **its own branch's axis** (`y=200`, the outer rank-1 branch), not on the diagram spine (BRANCH-015). The outer rank-2 branch's band starts below the *complete* bbox of the inner region, this is why `H[i]` must include descendants (BRANCH-002). No horizontal indentation is introduced; the inner gateway occupies a normal column.

### Before / after :: a typical repair

```
BEFORE (violations: AP-001 diagonal, AP-003 misaligned merge, AP-016 staircase)

   ┌────┐        ┌────┐
   │ A  │╲       │ C  │
   └────┘ ╲    ┌►└────┘╲      ◇
           ◇──┘         ╲───►│ │──► ...
            ╲ ┌────┐    ╱     ◇
             ►│ B  │───┘
              └────┘

AFTER (comb split, comb merge, straight spine, aligned split/merge)

   ┌────┐   ◇   ┌────┐   ◇
   │ A  ├──►│ ├──► C  ├──►│ ├──► ...
   └────┘   ◇   └────┘   ◇
             │  ┌────┐    ▲
             └─►│ B  ├────┘
                └────┘
```

---

## M. Machine-Readable Rule Summary

Normalized form, ready for conversion to JSON. `priority` feeds the solver's constraint class; `weight` feeds §K; `detect` and `repair` name the implementing functions.

```yaml
constants:
  U: 10
  TASK_W: 100 ;  TASK_H: 80 ;  TASK_W_MAX: 160 ;  TASK_H_MAX: 120
  GW: 50 ;  EV: 36 ;  SUB_MIN_W: 240 ;  SUB_MIN_H: 160
  NODE_GAP_X: 60 ;  NODE_GAP_X_MIN: 40 ;  COMPACT_GAP: 40
  FANOUT_GAP: {formula: "max(NODE_GAP_X, maxOutLabelW + 2U, GW/2 + MIN_SEG + EDGE_CLEAR)", default: 80}
  MERGE_GAP: 60 ;  BRANCH_GAP_Y: 60 ;  BRANCH_GAP_Y_MIN: 40
  EXC_GAP_Y: 50 ;  LOOP_CLEAR: 30 ;  CORRIDOR_PITCH: 20
  EDGE_CLEAR: 15 ;  EDGE_SEP: 10 ;  MIN_SEG: 20 ;  PORT_OFFSET_MIN: 20
  CONTAINER_PAD_X: 40 ;  CONTAINER_PAD_Y: 30 ;  LANE_MIN_H: 140
  POOL_LABEL_BAND: 30 ;  LANE_LABEL_BAND: 30 ;  POOL_GAP_Y: 60 ;  BLACKBOX_H: 60
  MARGIN: 40 ;  ARTIFACT_GAP: 30 ;  BE_GAP: 10
  LABEL_GAP: 5 ;  LABEL_MAX_W: 90 ;  LABEL_CLEAR: 10 ;  FLOW_LABEL_OFFSET: 5
  ALIGN_TOL: 5 ;  SYM_TOL: 20 ;  SPAN_TOL: 1
  largeMode: {NODE_GAP_X: 70, BRANCH_GAP_Y: 80, symmetryWeight: 0, maxChannelsPerGap: 4}

tiers: [T0_validity, T1_positional_semantics, T2_comprehension, T3_regularity, T4_economy, T5_stability]
tier_order: lexicographic          # no lower tier gain justifies any higher tier loss

rules:

- id: HC-002
  priority: HARD
  tier: T0
  condition: "any two non-containing, non-boundary node boxes with clearance < 2U"
  action: {separate_along: minor_axis, then: recompact}
  detect: sweepLineNodeOverlap
  repair: separateNodes
  weight: 1e6

- id: HC-009
  priority: HARD
  tier: T0
  condition: "collinear overlap of two edges without a shared port"
  action: {reassign_channel: next_free, else: widen_gap}
  detect: collinearOverlapScan
  repair: rechannelEdge
  weight: 1e6

- id: LAYOUT-004
  priority: STRONG
  tier: T1
  condition: always
  action: {layering: ASAP_longest_path, back_edges: removed_first}
  guarantees: [branches_start_same_column, merge_after_longest_branch, early_end_terminates_early]
  detect: layerMonotonicity
  repair: relayerComponent

- id: LAYOUT-007
  name: spine_straightness
  priority: STRONG
  tier: T2
  condition: "scope has a spine"
  action: {all_spine_nodes_share: centerY, spine_edges_bends: 0}
  exceptions: [lane_transition, expanded_subprocess_internal_alignment]
  weight: 60          # per bend on a spine edge
  detect: spineDeviationScan
  repair: setSpineY_then_restackBands

- id: LAYOUT-013
  name: band_model
  priority: STRONG
  tier: T1
  bands_outward_from_spine:
    - {index: 0, class: spine, side: axis}
    - {index: 1, class: artifact_gutter_data, side: above, gap: ARTIFACT_GAP}
    - {index: 1, class: artifact_gutter_annotation, side: below, gap: ARTIFACT_GAP}
    - {index: 2, class: alternative_branches, side: both, gap: BRANCH_GAP_Y}
    - {index: 3, class: exception, side: below, gap: EXC_GAP_Y}
    - {index: 4, class: loop_corridors, side: above, gap: "LOOP_CLEAR + k*CORRIDOR_PITCH"}
  allocation_order: [artifacts, exception_bands, loop_corridors]
  detect: bandOverlapScan
  repair: reallocateBands

- id: BRANCH-002
  name: branch_bounding_box
  priority: STRONG
  tier: T1
  action:
    include: [nodes, nested_regions, exception_bands, loop_corridors, artifact_gutters, external_labels, flow_labels]
    export: {H: height, A: "axisY - top", W: width, span: layers}
  note: "A[i] != H[i]/2 in general; all stacking uses A[i]"

- id: BRANCH-003
  priority: STRONG
  tier: T1
  condition: "outgoingBranchCount == 2"
  action:
    mode: "AXIS_LOCK if hasPrimary and type in [XOR,OR,implicit] else BBOX_CENTER"
    AXIS_LOCK: {axis_branch: rank1, other_side: "below if polarity in [NEGATIVE,EXCEPTION] or terminates else above"}
    BBOX_CENTER: {top: "snapCenter(gy - (H1 + BRANCH_GAP_Y + H2)/2)"}
    vertical_gap: "max(BRANCH_GAP_Y, channelDemand, labelClearance)"
  constraints: [no_overlap, avoid_crossings, split_merge_same_cy]

- id: BRANCH-004
  priority: STRONG
  tier: T1
  condition: "outgoingBranchCount == 3"
  action: {arrangement: [upper, center, lower], axis_slot: rank1, side_rule: polarity_then_rank}

- id: BRANCH-005
  priority: STRONG
  tier: T1
  condition: "outgoingBranchCount == 4"
  action:
    no_primary: {stack_top_to_bottom: [r1, r3, r2, r4], mode: BBOX_CENTER}
    has_primary: {mode: AXIS_LOCK, balance: "|#above - #below| <= 1"}

- id: BRANCH-006
  priority: STRONG
  tier: T1
  condition: "outgoingBranchCount >= 5"
  action:
    partition: {DOWN: [NEGATIVE, EXCEPTION, terminating], UP: rest}
    rebalance: "|#UP - #DOWN| <= 1 by moving lowest-ranked NEUTRAL only"
    fan_column_threshold: 7
    fan_column: {subfans: "ceil(n/5)", disabled_for: [eventBased]}

- id: BRANCH-007
  name: branch_order_comparator
  priority: STRONG
  tier: T1
  key: [userPriority, isDefaultFlow, polarity, terminates, -span, -nodeCount, -probability, documentOrder, id]
  polarity_lexicon:
    POSITIVE: [yes, true, ok, approved, accept, valid, success, granted, complete, eligible]
    NEGATIVE: [no, false, reject, denied, invalid, fail, timeout, expired, cancel, ineligible]
    EXCEPTION: {source: boundaryEvent, or_contains: [errorEndEvent, escalationEndEvent, cancelEndEvent]}
  side_map: {POSITIVE: above, NEUTRAL: above, NEGATIVE: below, EXCEPTION: below, terminating: below}

- id: BRANCH-011
  priority: STRONG
  tier: T1
  condition: "region has a merge"
  action: {layer: "max(branchMaxLayer)+1", cy: "cy(split)", entry_ports: "N/S for off-axis, W for axis"}
  weight: 10          # per split/merge pair with differing cy

- id: BRANCH-013
  priority: STRONG
  tier: T1
  condition: "branch spans differ"
  action:
    branch_starts: same_column          # mandatory
    slack: absorbed_by_single_straight_segment_into_merge
    stretching: forbidden
    short_branch_centering: {default: false}

- id: BRANCH-014
  priority: STRONG
  tier: T1
  condition: "a branch terminates without reaching the merge"
  action: {continuing_branch: axis_locked, terminating_branch: below, end_event_layer: ASAP, baseline_after_region: unchanged}

- id: BRANCH-015
  priority: STRONG
  tier: T1
  condition: "branch contains a nested split"
  action:
    recursion: post_order_over_region_tree
    nested_centering: parent_branch_axis
    horizontal_indentation: none
    per_level_padding: none            # prevents AP-014
  detect: nestedAxisDeviation
  repair: rerunRecursion

- id: BRANCH-020
  priority: WEAK
  tier: T3
  condition: "peerSymmetric(R)"
  eligibility: "type in [AND,eventBased] or (type in [XOR,OR] and not hasPrimary); |ΔH| <= SYM_TOL; |Δspan| <= SPAN_TOL; no EXCEPTION branch"
  action: {target: "symmetryDefect <= 0.15", repair: pad_smaller_side_gap, never: stretch_content}
  weight: 20

- id: EDGE-005
  name: canonical_fan_out_comb
  priority: STRONG
  tier: T2
  condition: "outDegree >= 2"
  action:
    axis_branch: {ports: [E, W], bends: 0}
    off_axis:    {ports: [N|S, W], bends: 1, trunk_x: "cx(split)"}
    bundling: allowed_at_shared_port
  fallback: {when: "trunk blocked", route: fan_corridor, bends: 2}

- id: EDGE-006
  name: canonical_fan_in_comb
  priority: STRONG
  tier: T2
  condition: "inDegree >= 2"
  action: {off_axis_bends: 1, turn_x: "cx(merge)", entry_ports: [N, S], axis_entry: W}
  activity_exception: {ports: offset_W_max_3, else: junction_dummy_at: "x(v) - MERGE_GAP/2"}

- id: EDGE-007
  name: bend_budget
  priority: MEDIUM
  tier: T2
  budgets: {straight: 0, split: 1, merge: 1, crossLane: 2, loop: 2, boundary: 2, message: 2, association: 1, unstructured: 4, absolute_max: 6}
  weight: 6           # per bend over budget
  repair_order: [reroute, reassign_band, accept_and_penalize]

- id: EDGE-013
  name: loopback_corridor
  priority: STRONG
  tier: T2
  condition: "back edge"
  action:
    side: above
    route: "[src.N, (src.cx, corridorY), (tgt.cx, corridorY), tgt.N]"
    corridor_order: "loops sorted by span descending -> increasing offset"
    corridorY: "regionTop - LOOP_CLEAR - k*CORRIDOR_PITCH"
  detect: backEdgeIntersectsNodeBand
  repair: reallocateCorridor

- id: EDGE-015
  name: cross_lane_Z
  priority: STRONG
  tier: T2
  condition: "lane(u) != lane(v)"
  action: {bends: 2, jog_x: "midpoint of column gap", min_progress: NODE_GAP_X_MIN}

- id: EDGE-019
  name: route_cost
  priority: MEDIUM
  tier: T2
  formula: "6*bends + 40*crossings + 0.02*lengthPx + 12*proximity + 25*backwardU + 8*channelIndex + 15*portDeviation"

- id: LAYOUT-016
  name: boundary_event_distribution
  priority: STRONG
  tier: T1
  action:
    edges: [bottom, top]
    positions: "cx_j = hostX + w*j/(k+1)"
    required_width: "k*EV + (k+1)*BE_GAP"
    host_growth: "to min(TASK_W_MAX, ceil(required/2U)*2U)"
    order_left_to_right: descending_handler_band_distance
  guarantees: exception_fan_is_crossing_free

- id: LANE-003
  priority: STRONG
  tier: T1
  action: {laneH: "max(LANE_MIN_H, contentH + 2*CONTAINER_PAD_Y)", equal_heights: false}

- id: LANE-006
  priority: STRONG
  tier: T2
  action: {per_lane_spine: true, global_baseline: false}

- id: LANE-009
  priority: STRONG
  tier: T1
  condition: "cross-lane sequence flow"
  action: {min_horizontal_progress: NODE_GAP_X_MIN, pure_vertical_transition: forbidden}

- id: LABEL-005
  priority: STRONG
  tier: T2
  action:
    anchor: first_horizontal_segment_after_source
    offset: {above: FLOW_LABEL_OFFSET, from_segment_start: 1U}
    gateway_stack: "all outgoing labels share x = cx(gateway) + 1U"
  fallback_anchors: [above_start, below_start, above_middle, below_middle, above_end]

- id: LAYOUT-024
  name: stability
  priority: MEDIUM
  tier: T5
  displacement_cost: "Σ ω(v)(|Δcx|+|Δcy|)/U + 40*sideFlips + 30*branchReorders + 80*laneReorders"
  omega: {pinned: 8, spine: 3, other: 1}
  accept_structural_change_if: "Δscore < -stabilityCost"
  full_relayout_if: "changedFraction > 0.5"

- id: LAYOUT-027
  name: determinism
  priority: HARD
  tier: T0
  action: {canonical_sort: [documentOrder, id], iteration: sorted_arrays_only, rounding: half_up, heuristic_iterations: fixed}

- id: LAYOUT-033
  name: unstructured_fallback
  priority: STRONG
  tier: T1
  condition: "SESE decomposition fails"
  action: {algorithm: sugiyama_weighted_median, sweeps: 4, bands: unreserved, symmetry: disabled, isolate_as: opaque_block, halo: 2U}

quality_gates_fail_build:
  - "any T0 penalty > 0"
  - "any T1 penalty > 0"
  - "spineBendPenalty > 0"
  - "bends(e) > 6 for any e"
```

---

## N. Self-Review: Rule Conflicts and Pathological Cases

Each conflict below was found by cross-checking the rules against each other; each has an explicit resolution that is part of the specification.

**N-1. Spine straightness (LAYOUT-007) vs lane containment (LANE-006).** A spine that crosses lanes cannot have one `y`.
*Resolution:* the spine is defined **per lane segment**. `LAYOUT-007` is evaluated within a lane segment only; the transition edge is the sole permitted bent spine edge (2 bends, EDGE-015). `spineBendPenalty` excludes lane-transition edges.

**N-2. `AXIS_LOCK` (BRANCH-003) vs symmetry (BRANCH-020/LAYOUT-026).** Both cannot hold for a 2-branch region.
*Resolution:* mutual exclusion by classification. `hasPrimary ⇒ AXIS_LOCK ∧ symmetry weight = 0`. `peerSymmetric ⇒ BBOX_CENTER`. The predicates are disjoint by construction (`peerSymmetric` requires `¬hasPrimary` for XOR/OR).

**N-3. Left-aligned branch starts (BRANCH-013) vs column compaction (LAYOUT-021).** Compaction could pull a short branch's node rightward into a later column.
*Resolution:* compaction operates on **columns, not nodes** (LAYOUT-021), so a node cannot change column. Add the explicit constraint `colX(layer(split)+1)` is a compaction anchor for all branches of the region.

**N-4. Exception band (LAYOUT-017) vs a branch already occupying the space below.** The lowest branch band and the exception band compete.
*Resolution:* ordering. Exception bands are allocated *after* all ordinary branch bands of the region and always outside them; the exception band is part of the region's bbox (BRANCH-002), so the parent's stacking accounts for it automatically. No collision is possible.

**N-5. Loop corridors (LAYOUT-018) vs artifact gutters (ART-001) vs gateway labels (LABEL-002).** All three want the space immediately above the spine.
*Resolution:* fixed allocation order, artifacts, then labels, then corridors (ART-007). Corridors always move outward; artifacts and labels never move for a corridor. Gateway labels that cannot fit above fall back to below (LABEL-002 anchor ladder).

**N-6. Boundary-event host growth (LAYOUT-016) vs task-width uniformity (LAYOUT-029/AP-011).** A host with 3 boundary events becomes 150 px wide while its neighbours are 100 px.
*Resolution:* `LAYOUT-016` is STRONG, `sizeUniformity` is WEAK (T3). The uniformity detector **excludes** activities whose width was forced by boundary events or by label growth; otherwise it would fire permanently.

**N-7. Bundling (EDGE-009) vs "no ambiguous overlap" (AP-023/EDGE-012).** These directly contradict unless the exception is precise.
*Resolution:* bundling is legal **iff** the overlapping sub-segment is contiguous with a port shared by both edges. Everything else is prohibited. The detector implements exactly this predicate, so the two rules cannot both fire on the same pair.

**N-8. Grid snapping (LAYOUT-002) vs exact symmetry (BRANCH-020).** Centering an odd-height stack can land the axis on a half-grid, and snapping then breaks the mirror.
*Resolution:* round the **half-stack height** up to a multiple of `U` before centering (`top = snapCenter(gy − ceilU(totalH/2))`), and require all branch gaps to be even multiples of `U`. Symmetry is then exact after snapping. Event heights (36) never enter this computation because bands are positioned by axis, and node boxes are derived from the axis.

**N-9. Stability (LAYOUT-024) vs crossing minimization (EDGE-010) vs determinism (LAYOUT-027).** A stability-preserved order may be worse than the canonical order, so the "same graph" can produce two different layouts depending on history.
*Resolution:* determinism is defined over `(SG, previousRG)`, not over `SG` alone. `format(SG, ∅)`, the from-scratch case, is deterministic in `SG`. Incremental results are deterministic in the pair. Both properties are separately testable, and the report always states which mode was used.

**N-10. `FAN_COLUMN` (BRANCH-006) vs branch-start alignment (BRANCH-013).** Sub-fans push some branches one column right, so branch starts no longer share a column.
*Resolution:* the alignment rule is restated in terms of the *fan node*: all branches of one sub-fan start in the same column, and all sub-fan dummies start in the same column. The invariant "alternatives of one decision begin together" is preserved one level down. `FAN_COLUMN` is only reachable at `n ≥ 7`, where the flat form is unusable anyway.

**N-11. Merge alignment (BRANCH-011/012) vs cross-lane branches (BRANCH-023).** `cy(merge) = cy(split)` may be impossible if branches live in different lanes.
*Resolution:* BRANCH-023 declares a **permitted exception** to BRANCH-012; the merge aligns to its own lane spine, and `AP-003` suppresses its detector when the split and merge are in different lanes.

**N-12. ASAP layering (LAYOUT-004) vs "no over-long connector" (LAYOUT-015/AP-020).** ASAP creates a long connector from a short branch's tail into a distant merge, which superficially resembles the "over-long edge" anti-pattern.
*Resolution:* `LAYOUT-015`'s detector applies **only to end events** (which have no successor and therefore no reason to be far right); it explicitly exempts edges terminating at a merge node. `edgeLengthPenalty` is deliberately tiny (`0.02/U`) so it never motivates breaking BRANCH-013.

**N-13. Pool reordering (LANE-013) vs lane order stability (LANE-005) vs black-box placement (LANE-014).** Three rules want to decide the pool order.
*Resolution:* strict precedence, (1) explicit user order; (2) black-box pools at the ends; (3) barycenter reduction accepted only at `≥ 2` crossings improvement; (4) initiator pool topmost; (5) input order. Each later rule may only permute within the freedom left by the earlier ones.

**N-14. Compaction (LAYOUT-021/022) vs channel reservations (EDGE-008).** Compaction reduces a gap that a channel needs, and the subsequent re-route re-widens it, an oscillation.
*Resolution:* channels are converted into **explicit constraints** in the compaction constraint graph *before* compaction runs (`gap ≥ 2·EDGE_CLEAR + (channels−1)·CORRIDOR_PITCH`). Compaction never runs against un-modelled routing demand, so the oscillation cannot start. Phase 11 additionally rolls back any step that fails a HARD constraint.

**N-15. Collision repair loops (phase 10).** Two repairs can undo each other (move node right ↔ move edge to another channel).
*Resolution:* the repair ladder in EDGE-020 is strictly ordered and each rung is monotone (it never increases the number of violations of a higher-priority class). Phase 10 is capped at 8 iterations, then falls back to widening the binding gap by `1U` (a strictly monotone operation guaranteed to terminate), max 3 restarts.

**N-16. Region-local relayout (LAYOUT-024) vs global column grid (LAYOUT-005).** Re-laying out one region can change a column width, which shifts every downstream column and therefore violates the "local change" promise.
*Resolution:* downstream shift is a pure translation (`Δx`), which costs `ω(v)·|Δx|/U` in the displacement function but does **not** count as a structural change. Users perceive uniform translation as stable; only reordering and side flips are perceived as rearrangement. This is why the displacement function weights structural changes 30–80× a unit translation.

**N-17. Pathological case, a peer-symmetric AND region containing an exception band in one branch.** Symmetry would demand mirroring an exception band that only one branch has.
*Resolution:* `peerSymmetric` explicitly excludes regions where any branch is EXCEPTION-class or has an exception band (its `A[i] ≠ H[i]/2`). Such a region is laid out with `BBOX_CENTER` but with **zero symmetry pressure**, so the bboxes straddle the axis without any padding being added to fake a mirror.

**N-18. Pathological case, deep nesting inside a short lane.** `LANE-003` grows the lane, which changes `laneSpineY`, which changes every band inside, which changes the content height, a feedback loop.
*Resolution:* the bottom-up sizing pass (LANE-004) is **single-pass by construction**: content heights are computed in phase 5 (before any lane geometry exists), lane heights in phase 7 from those fixed values, and lane spines are then derived, not re-derived. Nothing computed in phase 7 feeds back into phase 5.

**N-19. Pathological case, every branch is EXCEPTION-class.** The rebalancing rule would push everything below the axis, producing an extremely bottom-heavy region with a lonely spine.
*Resolution:* accepted deliberately (BRANCH-004 exception). An all-exception fan *is* bottom-heavy in reality, and placing an error path above the happy path (AP-021) is worse than imbalance. The symmetry and area penalties are suppressed for such regions so the optimizer does not fight the correct result.

**N-20. Pathological case, a single node that is both a merge and a split and a loop header.** Three rules claim its ports (`W` entry, `N` back edge, `N/S` fan-out, `E` axis out).
*Resolution:* fixed port precedence for gateways: `W` = primary forward entry; `N` = loop back-edge entry (highest priority for `N`); `E` = axis out; `S` = fan-out for off-axis branches; if more branches need ports than remain, the surplus branches use the **fan-corridor form** (EDGE-005 fallback, 2 bends) from the `E` port. Fan-in from a lower band then uses `S`, and the loop keeps `N` exclusively.
