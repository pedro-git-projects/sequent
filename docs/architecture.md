# Architecture

This is the implementation map. For *why* the boundaries are where they are, and
what Haskell contributed to the design, see [`design.md`](design.md).

```
Source text
    │  Sequent.Language.Parser          megaparsec, spans on everything
    ▼
Surface AST                             Sequent.Language.Syntax
    │  Sequent.Language.Resolve         names, ids, implicit flows, merges
    ▼
Semantic graph  (SG)                    Sequent.Bpmn.Semantic
    │  Sequent.Bpmn.Validate            BPMN semantics
    │  Sequent.Camunda.Validate         Zeebe execution metadata
    ▼
Semantic graph  (validated)
    │  Sequent.Layout                   14 phases
    ├── Logical layout structure (LLS)  Sequent.Layout.Types
    ▼
Rendered geometry (RG)                  Sequent.Layout.Types
    │  Sequent.Camunda.Serialize        BPMN 2.0 + BPMN DI
    ▼
Camunda 8 BPMN XML
```

Each arrow is a total function returning diagnostics. Nothing throws for an
ordinary user mistake.

The reverse direction runs the same chain backwards, and stops one
representation short of the top:

```
Camunda 8 BPMN XML
    │  Sequent.Camunda.XmlParse         namespace-aware reader, prefixes → URIs
    ▼
XML tree                                Sequent.Camunda.XmlParse
    │  Sequent.Bpmn.Read                elements + zeebe extensions → BPMN meaning
    ▼
Semantic graph  (SG)                    the same type, unchanged
    │  Sequent.Language.Emit            symbols, implicit chains, derived merges
    ▼
Surface AST                             the same type, unchanged
    │  Sequent.Language.Pretty          the canonical form 'fmt' prints
    ▼
Source text
```

There is no inverse of `Sequent.Layout` or `Sequent.Camunda.Serialize`, and
there is not meant to be: those two stages are precisely what the import throws
away. The `<bpmndi:BPMNDiagram>` is not read at all.

The semantic graph is the fixed point of the two directions — the *same* type,
not a parallel one — and that is what makes the import checkable.
`Sequent.Compiler.importText` compiles its own output and compares the two
graphs, so an emitter bug is an error naming the difference rather than a file
that looks plausible. See [`import.md`](import.md).

## The four representations, and why they are four

The boundaries are not bookkeeping. Each one exists because collapsing it
produces a specific, recognisable class of bug.

**Surface AST ≠ semantic graph.** The AST has branches nested inside gateways,
which BPMN does not have; it has no sequence flows for implicit chaining and no
merge gateways at all. Keeping it separate is what lets the language nest while
the model stays flat.

**Semantic graph ≠ logical layout structure.** `SG` is BPMN meaning:
elements, flows, containment, conditions, boundary attachment. It contains no
`x`, no `y`, no waypoint. Storing a coordinate here "because serialisation needs
it eventually" is the specific mistake SPEC §0 exists to prevent — it makes the
layout engine's input depend on its own output.

**Logical layout structure ≠ rendered geometry.** `LLS` is structure: the region
tree, layers, bands, branch order, ports, corridors. It has no pixels. Phases
1–5 may only write `LLS`, so code that tries to nudge a node in the region phase
does not typecheck. Phases 6–12 write `RG` from `LLS`, which makes every
coordinate traceable to a structural decision rather than to an accumulated
adjustment.

**Rendered geometry ≠ XML.** `RG` is integer pixels and nothing else. The
serialiser reads `SG` and `RG` and writes bytes; it makes no decision that could
have been made earlier. That direction of dependency is what keeps "what Camunda
wants in the file" from becoming the compiler's shape.

## Stage by stage

Each row is a real stage in `Sequent.Compiler.compileText`, with the type that
carries it and the module that produces it.

| Stage | Main type | Module | Input → output | Invariant |
|---|---|---|---|---|
| Parse | `SFile` | `Sequent.Language.Parser` | `FilePath`, `Text` → `Either [Diagnostic] SFile` | every node carries the `Span` it came from; reserved words are rejected at the name; the space consumer records each comment it crosses, and `withComments` weaves them back into the list being built |
| Surface AST | `SFile`, `SDecl`, `SItem`, `SStep`, `Comment` | `Sequent.Language.Syntax` | — | branches nest inside gateways; there are no sequence flows and no merge gateways; comments are ordinary elements of the list they were written in, so the formatter can put them back and nothing downstream has to know they exist |
| Resolve | `ResolveResult` | `Sequent.Language.Resolve` | `SFile` → `Maybe SemanticGraph`, `PinSet`, `Provenance`, `[Diagnostic]` | every name is declared before use; every id is allocated once, through `Sequent.Bpmn.Id` |
| Semantic graph (SG) | `SemanticGraph`, `BpmnProcess`, `Scope`, `FlowNode`, `SequenceFlow` | `Sequent.Bpmn.Semantic` | — | no `x`, no `y`, no waypoint, no XML; every collection is a list in document order; `canonicalise` sorts by `(documentOrder, id)` |
| Validate (BPMN) | `[Diagnostic]` | `Sequent.Bpmn.Validate` | `Provenance`, `SemanticGraph` → `[Diagnostic]` | reachability, event flow direction, gateway and boundary rules; no repair, only diagnosis |
| Validate (Camunda) | `[Diagnostic]` | `Sequent.Camunda.Validate` | as above | job types, retries, ISO-8601 timers, mapping targets |
| Graph analysis | `FlowGraph`, `Analysis` | `Sequent.Bpmn.Graph`, `Sequent.Layout.Analysis` | `Scope` → back edges, topological order, dominators, post-dominators, SCCs | vertices are dense `Int`s in canonical order, so every traversal is deterministic |
| Logical layout structure (LLS) | `LayoutStructure`, `Region`, `Branch`, `Extent`, `Port`, `Corridor`, `AxisMap` | `Sequent.Layout.Types` (built by `Regions`, `Layering`, `Branches`, `Bands`) | `Analysis` → regions, layers, bands, sides, corridors | no pixels — structure only; a band extent is a signed pair about a node's axis, never a height |
| Rendered geometry (RG) | `Geometry` (`Map NodeId Rect`, `Map FlowId Route`, label boxes, lane and pool rects) | `Sequent.Layout.Types` (built by `Geometry`, `Ports`, `Routing`, `Labels`, `Collision`, `Compact`, `Snap`) | LLS → integer pixels | centres on the 10 px grid — in the assembled diagram, so every container offset is a whole number of units; coordinates non-negative; every route orthogonal |
| Score and gate | `Score`, `[Violation]` | `Sequent.Layout.Score`, `.Validate`, `.Rules` | `Geometry` → penalties and rule violations by tier | violations carry a `RuleId` and a `Tier`; ordering is total |
| Serialize | `Element`, `Text` | `Sequent.Camunda.Serialize`, `Sequent.Camunda.Xml` | `SemanticGraph` + `Geometry` → BPMN 2.0 + BPMN DI | write-only; makes no decision that could have been made earlier |

`Sequent.Compiler` stops at the first stage that produced an error, and applies
the SPEC §K quality gates after layout.

## Modules

| Module | Job |
|---|---|
| `Sequent.Diagnostic` | spans, severities, categories, rule ids, caret rendering |
| `Sequent.Text.Metrics` | deterministic font metrics and wrapping |
| `Sequent.Language.Syntax` | surface AST |
| `Sequent.Language.Parser` | grammar |
| `Sequent.Language.Pretty` | canonical formatter |
| `Sequent.Language.Resolve` | names, ids, implicit flows, derived merges |
| `Sequent.Language.Emit` | SG → surface AST: the inverse of `Resolve` |
| `Sequent.Bpmn.Id` | the one deterministic id policy |
| `Sequent.Bpmn.Semantic` | the semantic graph |
| `Sequent.Bpmn.Graph` | DFS, SCC, dominators, topological order, longest path |
| `Sequent.Bpmn.Validate` | BPMN semantic validation |
| `Sequent.Bpmn.Read` | BPMN XML tree → SG: the inverse of `Serialize` |
| `Sequent.Camunda.Model` | Zeebe execution metadata |
| `Sequent.Camunda.Validate` | Zeebe validation |
| `Sequent.Camunda.Xml` | write-only XML tree and serialiser |
| `Sequent.Camunda.XmlParse` | namespace-aware XML reader (read-only; no DTD, no entities) |
| `Sequent.Camunda.Serialize` | SG + RG → BPMN 2.0 + DI |
| `Sequent.Layout.Constants` | SPEC §B, and nowhere else |
| `Sequent.Layout.Types` | LLS and RG types, geometry primitives |
| `Sequent.Layout.Analysis` | P1 graph analysis |
| `Sequent.Layout.Regions` | P2 SESE regions, region tree, spine |
| `Sequent.Layout.Layering` | P3 ASAP layering, virtual nodes |
| `Sequent.Layout.Branches` | P4 branch ordering, polarity, sides |
| `Sequent.Layout.Bands` | P5 bounding boxes and band assignment |
| `Sequent.Layout.Geometry` | P6/P7 columns, lanes, boundary placement |
| `Sequent.Layout.Ports` | the port model |
| `Sequent.Layout.Routing` | P8 route classes and channels |
| `Sequent.Layout.Labels` | P9 placement, and LAYOUT-029 sizing |
| `Sequent.Layout.Collision` | P10 repair |
| `Sequent.Layout.Compact` | P11 compaction |
| `Sequent.Layout.Snap` | P12 snapping, re-anchoring, translation |
| `Sequent.Layout.Score` | P13 §K score and anti-pattern detectors |
| `Sequent.Layout.Improve` | P14 bounded deterministic improvement |
| `Sequent.Layout.Validate` | hard-constraint and positional detectors |
| `Sequent.Layout.Rules` | the normative rule registry |
| `Sequent.Layout` | the 14-phase driver |
| `Sequent.Compiler` | the pipeline and the quality gates |

## The layout API

```haskell
format :: LayoutConfig -> SemanticGraph -> Maybe PreviousGeometry -> LayoutResult
```

The signature is the architecture. Layout is a pure function of the semantic
graph, an optional previous geometry (LAYOUT-024) and a pin set (LAYOUT-025) —
and of nothing else. No clock, no randomness, no XML, no hash iteration.

`PreviousGeometry` is `Map ScopeId Geometry`: the geometry of a previous run,
which the engine uses to recover each branch's side so a re-run keeps the
arrangement a reader already knows. It is read, never required; without it the
layout is derived from scratch, which is the from-scratch determinism case of
SPEC N-9.

## Determinism

The contract is HC-016: identical canonicalised input produces byte-identical
output. It is maintained structurally rather than by discipline.

* Every collection in `SG` is a list in document order, and `canonicalise`
  sorts every one by `(documentOrder, id)` before any traversal. Both the layout
  engine and the serialiser canonicalise their input, so element order in the
  XML is a property of the document rather than of how the graph was assembled.
* Every derived map is a `Data.Map.Strict` keyed by an `Ord` id. There is no
  `HashMap` and no `HashSet` anywhere in the compiler.
* Graph algorithms are indexed by a dense `Int` assigned in canonical order, and
  every adjacency list is stored in that order (`Sequent.Bpmn.Graph`).
* Every tie-break ends in a total order — usually `(documentOrder, id)`.
* Heuristics use fixed iteration counts, never time limits or
  convergence-on-epsilon. Phase 10 is capped at 8 iterations with 3 restarts;
  phase 14 has a fixed candidate budget.
* Text measurement is a compiled-in advance-width table, so it cannot vary with
  the host's font configuration.

`Sequent.DeterminismSpec` asserts this by shuffling the node, flow, artifact and
lane lists of a graph eight ways and requiring byte-identical BPMN back — plus a
guard test that the shuffle really did reorder the lists.

## The id policy

Every BPMN id is `<Prefix>_<sanitised symbolic name>`. Consequences, which are
the properties the policy exists to guarantee:

* no UUIDs and no randomness — an id is a pure function of the source name;
* labels are not identity — renaming `"Validate order"` leaves
  `Activity_validate` alone;
* unrelated edits do not rename unrelated elements — ids come from names, never
  from a counter over the document;
* references stay stable — a flow id is built from its two endpoint names, so
  reordering declarations cannot renumber it.

Collisions get a numeric suffix, and allocation runs in a fixed class order
(`allocationClasses`) so that adding an edge can never renumber a node. All id
construction goes through `Sequent.Bpmn.Id`; the serialiser only consumes ids
and the two derived-name helpers.

## Invariants worth knowing

* **The semantic graph never carries geometry.** If you find yourself wanting a
  coordinate in `SG`, the thing you actually want is a `Provenance` entry (a
  source span) or an `LLS` field.
* **Layout never repairs semantics.** A graph that reaches `Sequent.Layout` is
  already a well-formed process, so every repair the engine performs is
  geometric. A formatter that silently repairs semantics produces diagrams that
  do not describe the process the author wrote.
* **A region owns the nodes strictly between its split and its merge that no
  nested region owns.** A nested region's split and merge belong to the parent
  branch — they sit on its axis — while the nested region contributes only its
  off-axis content. That is what stops them being counted twice in BRANCH-002's
  bounding box.
* **Branch extents are a signed pair, not a height.** `A[i] ≠ H[i]/2` whenever a
  branch has an exception band below it, and collapsing the two is, per the
  spec, the single most common implementation error in BPMN formatters. The same
  is true of a single node once it is an expanded subprocess: its extent is
  `(above, below)` about its internal spine, not `(h/2, h/2)` about its centre.
* **A phase pays a later phase the room it owes, while it still can.** The
  router cannot invent a stub that the bands left no space for; phase 9 cannot
  find room for a caption that phase 5 never reserved; a container offset
  rounded to a fraction of a grid unit cannot be un-rounded downstream. Each of
  those has been a bug here, and each was fixed in the phase that owed the
  room, never in the one that discovered the shortfall.
* **Every scope validating clean does not mean the diagram is clean.** A pool
  and an expanded subprocess are laid out in frames of their own and then
  translated into place, so a fault that lives in the *assembly* — an offset
  that takes the contents off the grid, a message flow crossing a caption — is
  invisible to a per-scope check. Those are asserted over the merged geometry.
* **Camunda metadata is opaque to layout.** Nothing in name resolution, region
  detection, layering, banding, routing or scoring branches on a Zeebe
  attribute.

## Structural layout, in the compiler's own terms

`SPEC.md` is the normative source for all of this; what follows is the map from
its vocabulary to the code, so you can find the thing you need to change.

**Region** — a single-entry, single-exit subgraph, found from dominators and
post-dominators. `Sequent.Layout.Regions.detectRegions` builds the region tree
(`Region`, `RegionId`, `rrChildren`, `parentOf`). A region owns the nodes
strictly between its split and its merge that no nested region owns; a nested
region's own split and merge belong to the *parent* branch, which is what stops
them being counted twice in the parent's bounding box. Irreducible strongly
connected components are isolated here and handled by the local fallback rather
than being allowed to break the structured path.

**Layer** — a column index. `Sequent.Layout.Layering.asapLayers` is
longest-path (ASAP) layering over the acyclic skeleton, so a forward flow always
makes non-decreasing horizontal progress (LAYOUT-001). Layering runs *before*
region detection, because a region's `span` is defined in layers and layering
depends only on the acyclic skeleton.

**Spine** — the horizontal axis chain the reader's eye follows.
`Sequent.Layout.Regions` computes it by walking the root branch and recursing
into axis-locked branches. `LAYOUT-007` says it is straight and bend-free, and
the detector in `Sequent.Layout.Validate` enforces it.

**Branch and band** — a branch is one path through a split; a band is the
vertical slot it gets. `Sequent.Layout.Branches` ranks branches (the nine-part
`BranchKey` comparator of BRANCH-007), assigns each a side from a polarity
lexicon (positive above, exception always below), and picks a stacking mode
(`AxisLock` keeps the top-ranked branch on the spine; `BboxCenter` straddles).

Two of those signals are easy to over-read, and both send a whole diagram to
one side of its own spine when they are. **Exception polarity** is a property of
a branch's *outcomes*, not of its members: a main path that reaches a normal end
and an escalation end somewhere is not an exception path, and classifying it as
one hands the spine to whichever short branch happened to be neutral.
**Terminating** decides a side only where it *separates* the branches
(`terminatesAgainstPeers`): BRANCH-014 is about a branch that stops while
another continues, and in an open region every branch stops, so letting it
decide there pushes all of them below at once.
`Sequent.Layout.Bands` then turns that into geometry-free vertical extents.
A branch's extent is a **signed pair** (`Extent`, `exAbove`/`exBelow`), not a
height: `A[i] ≠ H[i]/2` whenever a branch carries an exception band below it,
and collapsing the two is the single most common implementation error in BPMN
formatters.

**Axis** — the `y` a node's connectors run on, and the `y` its band was stacked
around. For every node it is the box centre (LAYOUT-012), with one exception
that is worth the whole mechanism: an **expanded subprocess hangs from its own
internal spine** (LAYOUT-020), so that the flow line continues straight through
the container border instead of stepping to the box's middle. A subprocess is
bottom-heavy in practice — handler bands, exception paths and below-the-axis
branches all hang downward — so its spine is typically near its top edge of the
content, and a container placed by its content alone drops the reader's eye at
exactly the point a diagram must not.

`Layout.layoutScopeRecursive.containerBox` measures the child as `(above,
below)` about its spine rather than as a height, and then **centres the box on
that spine** by taking the larger half for both. The outer spine, the inner
spine and the container's vertical middle are one line. That costs real empty
space on the lighter side — in `examples/murex.sq`, the whole depth of two
exception-handler bands, paid again above the spine — and the alternative reads
worse: a flow line meeting a tall box a third of the way down leaves the reader
deciding whether the box or the line is the misaligned one.

`Sequent.Layout.Types.AxisMap` carries the signed offset from a box centre to
its axis. Because the sizing rule above centres the box, that offset is
currently always zero and the map is always empty; it is kept because the
coincidence is a property of one arithmetic line and not of the model. "Where a
connector attaches" and "the middle of the box" are different questions, and the
phases below read the first: `Bands` reserves the extent about it, `Geometry`
hangs the box from it, `Ports` puts the `W` and `E` midpoints on it, `Routing`
asks it whether two nodes are on the same line, and `Score` and `Validate`
measure alignment against it. Reclaiming the space centring costs is then a
change to `containerBox` alone, instead of a silent regression in seven places
that had gone back to reading the box centre — a needless jog into the
container, a spine reported as crooked, a fan entering above the flow it
continues.

**Port** — the point on a node's border where a connector attaches.
`Sequent.Layout.Ports.assignPorts` gives every node the four side midpoints
plus, for activities, offset ports; target sides are decided before source
sides so the surplus rule can move an outgoing branch off a side an incoming fan
has claimed. Every endpoint must sit on a declared port with a perpendicular
stub of at least `MIN_SEG` (HC-005).

That stub is not something the router can create: it is the distance from the
node's border to the band or column it is heading for, and by phase 8 both are
fixed. So the room for it is reserved upstream — `Layout.Bands.stackLane` keeps
every off-axis band at least `GW/2 + MIN_SEG` from the split, and
`Layout.Geometry.columnsFor` rounds column centres *up* to the grid so a gap can
never be rounded shut below the pitch it asked for. A phase that owes a later
phase room has to pay it while it still can.

**Channel and corridor** — the vertical lanes a connector may run in.
`Sequent.Layout.Routing.channelX` puts channel 0 at the midpoint of the column
gap and clamps it so both stubs keep their minimum segment;
`Sequent.Layout.Bands.corridorsOf` reserves loop corridors outside the region a
back edge spans, so a loopback never cuts through the main flow (AP-008).

**Route class** — routing is not "Manhattan connectors after the fact".
`Sequent.Layout.Routing.classifyEdge` puts every connector into a canonical
class (straight, split, merge, cross-lane, loopback, boundary, message flow,
association, fallback), and each class has its own construction and its own bend
budget (`edgeBendBudget`).

The boundary class is the one worth reading, because it is the only connector
that *starts* inside the shape it must not cross.
`Sequent.Layout.Routing.boundaryExceptionRoute` takes the host, the source
point and the target's port as arguments rather than reading them out of the
routing context, and generates five forms — straight, canonical L, vertical
approach, detour, excursion — taking the first that clears the host and reaches
the port from outside it. Generating and filtering rather than deciding by cases
is what makes "no segment of an exception route touches its host" a property of
the function instead of a claim about it. Parameterising it is what makes it
testable: layering and column separation keep a handler to the right of its
host, so a `.sq` file can only ever reach the first two forms, and the rest are
exercised by constructing the geometry directly.

**Labels are geometry.** `Sequent.Layout.Labels` sizes activities from measured
text (`activityGrowthLadder`), places external labels down an anchor ladder, and
puts flow labels on a deterministic stack beside the gateway trunk — far enough
beside it to clear the diamond, which the bounding box does not tell you: a
gateway's corners are empty ink and the band by its centre line is not, and the
axis branch's label sits exactly there. Label boxes
participate in collision detection and in the final bounds; they are not
decoration painted on afterwards.

The obstacles a label is placed against are shapes, labels already placed **and
connectors** (EDGE-018) — text with a line drawn through it is unreadable
however well the boxes are arranged. When the whole ladder is blocked, the
answer is more room and never an overlap (LABEL-006): the ladder is retried a
grid unit further out, up to `LABEL_PUSH_STEPS`, and because a label counts
toward the diagram bounds, a label that steps past the last band grows the
diagram to hold it. Reaching the end of that with nowhere free is a **tier-1
LABEL-011 violation** and fails the build.

Room is also *reserved* rather than only searched for. `Bands.nodeExtent` claims
a node's external label, its artifact gutters, and — for a host with boundary
events — the events **and their captions**, on whichever edge each one attaches
to. Phase 9 can only find room that phase 5 set aside; two boundary captions
landing on top of each other is what it looks like when it did not.

Reserving the right amount depends on measuring honestly, and the measurement is
the easiest place to lie. BPMN DI carries a bounds rectangle and the element's
`name`; the renderer breaks that name itself and need not agree with us about
where. Two consequences, and both were bugs here:

* A box measured at two lines for a caption that wraps to four does not shorten
  the label — the extra lines are drawn over whatever is below, and the
  formatter never sees it. `externalLabelBox` therefore has no line cap. An
  activity's *internal* text does, because the shape grows to meet it
  (LAYOUT-029) and HC-012 checks the result; nothing grows to meet a caption
  beside a shape.
* The widest line *we* produced is not the width the label occupies. Camunda
  Modeler sets external labels a point smaller, fits more words per line, and
  centres the wider result on the box we declared — so a caption measured 59 px
  wide is drawn 90 px wide, 15 px past each edge, across whatever the anchor
  ladder had cleared. `wrappedBox` therefore reports `LABEL_MAX_W` for any label
  that wraps: a renderer breaking the same text at that width produces lines no
  wider, whichever renderer it turns out to be.

Message flows are the one connector class routed after phase 9, because they
belong to the collaboration rather than to any one scope. `Layout.stackPools`
therefore does two things phase 9 would otherwise have done: it re-runs the
ladder for the captions its new routes cross (EDGE-018's own repair, applied by
the phase that introduced the obstacle), and it **places the message flows' own
captions**. Leaving one unplaced does not leave it unlabelled — the name is
serialised either way, and a renderer given no bounds drops the text at the
middle of the flow, which for a route crossing the inter-pool gap is squarely on
a pool border.

Which is the other rule worth naming: a label sits inside a container or outside
every container, never across a border. That is a different condition from
overlapping a shape, because a pool or a lane is mostly empty space a label may
legitimately occupy — the border line is not. Lanes need it twice over: a lane
is sized from the shapes it holds and from the column grid, and neither knows
how wide a caption is.

## Quality gates

`Sequent.Compiler` applies SPEC §K: any tier-0 or tier-1 violation is an error
and no BPMN is written. Everything else is reported at its own severity so the
caller still gets a diagram. `--lenient` downgrades the gate for inspection;
`sequent report` prints the score breakdown and every violation with its rule id.
