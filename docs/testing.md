# Testing the compiler

This page is a hands-on guide to answering one question: *does this compiler
actually work?* Everything below was run against the repository as it stands.

## One command

```bash
./scripts/check.sh
```

Builds everything, runs the whole test suite, compiles every example into a
scratch directory and diffs each result against its committed golden, compiles
`order.sq` twice and compares hashes, then imports every committed `.bpmn` back
to `.sq`, recompiles it, and checks the process elements are unchanged. Exits
non-zero if any of that fails, with a summary of what did. This is the
confidence signal to run after a change.

Current result:

```
=== build
  ok
=== test
  826 examples, 0 failures
  ok
=== examples
  examples/collaboration.sq: ok
  examples/event-gateway.sq: ok
  examples/hello.sq: ok
  examples/lanes.sq: ok
  examples/linear.sq: ok
  examples/loop.sq: ok
  examples/murex.sq: ok
  examples/onboarding.sq: ok
  examples/order.sq: ok
  examples/parallel.sq: ok
  examples/subprocess.sq: ok
=== determinism
  ok (byte-identical)
=== round trip
  examples/collaboration.bpmn: ok
  examples/event-gateway.bpmn: ok
  examples/hello.bpmn: ok
  examples/lanes.bpmn: ok
  examples/linear.bpmn: ok
  examples/loop.bpmn: ok
  examples/murex.bpmn: ok
  examples/onboarding.bpmn: ok
  examples/order.bpmn: ok
  examples/parallel.bpmn: ok
  examples/subprocess.bpmn: ok

check: PASS
```

The round-trip step compares the **process elements only**, sorted: geometry is
recomputed by design, so asserting it would assert something the import never
promised. What it does assert is that nothing semantic moved.

## Running the test suite directly

```bash
cabal test                 # the whole suite, summarised
cabal test --test-show-details=direct   # the whole suite, every example printed
```

Current result: **826 examples, 0 failures**, in about 0.9 s.

The suite is one hspec `exitcode-stdio-1.0` test-suite called `spec`, whose
`main` is `test/Spec.hs`. That file lists the fourteen modules and the
`describe` label each one runs under — that label is what you filter on.

## What is in the suite

| Module | `describe` label | What it establishes |
|---|---|---|
| `Sequent/XmlSpec.hs` | `Sequent.Camunda.Xml` | attribute and text escaping, element rendering |
| `Sequent/MetricsSpec.hs` | `Sequent.Text.Metrics` | text measurement, wrapping, the activity growth ladder |
| `Sequent/ParserSpec.hs` | `Sequent.Language.Parser` | the grammar: declarations, steps, control flow, attachments, lexing |
| `Sequent/ResolveSpec.hs` | `Sequent.Language.Resolve` | implicit chaining, derived merges, `stop`, event subprocesses, groups, name resolution, property rules, lanes, Camunda metadata |
| `Sequent/PrettySpec.hs` | `Sequent.Language.Pretty` | formatter idempotence, no reordering, canonical layout, every example |
| `Sequent/IdSpec.hs` | `Sequent.Bpmn.Id` | the id policy: NCName validity, no label-derived ids, collision suffixes |
| `Sequent/SerializeSpec.hs` | `Sequent.Camunda.Serialize` | BPMN output, by **re-parsing the XML and querying the tree**, never by string matching |
| `Sequent/LayoutInvariantSpec.hs` | `layout invariants` | the hard constraints of SPEC §C over a corpus of nineteen process shapes |
| `Sequent/SpecRuleSpec.hs` | `SPEC rules` | 128 tests, 111 of them under a `test_<RULE-ID>_<what>` name that says which rule they check |
| `Sequent/DeterminismSpec.hs` | `determinism` | byte-identical output under eight shuffles of every input collection |
| `Sequent/ImportSpec.hs` | `import` | the XML reader, the BPMN reader, name recovery, group membership recovered from geometry, dangling paths closed with `stop`, and a `.bpmn` → `.sq` → `.bpmn` round trip over every example |
| `Sequent/GoldenSpec.hs` | `golden` | the canonical examples of SPEC §L at exact coordinates, plus byte-exact `.bpmn` goldens for every example |
| `Sequent/PerformanceSpec.hs` | `performance` | 10 / 50 / 150 / 500 nodes lay out with no tier-0 or tier-1 violation |
| `Sequent/Test/Support.hs` | — | helpers: `compileOk`, `compileXml`, `layoutOf`, `graphOf`, `diagsOf`, and a small read-only XML parser |

## Running one test

hspec's `--match` filters on the full path of `describe` and `it` labels, as a
substring:

```bash
# one spec module
cabal run spec -- --match "Sequent.Language.Parser"

# one group inside it
cabal run spec -- --match "implicit chaining"

# one golden pattern
cabal run spec -- --match "pattern A"

# one SPEC rule
cabal run spec -- --match "test_HC_005"

# every layout invariant for one corpus shape
cabal run spec -- --match "layout invariants/loopback"
```

`cabal run spec --` runs the test executable with your arguments;
`cabal test` does not forward them. Other useful hspec flags: `--seed N`,
`--fail-fast`, `--format=failed-examples`.

## Writing your first test

The cheapest useful test compiles a snippet and asserts something about the
result. `Sequent.Test.Support.wrapProcess` wraps a bare body in
`process p { … }` for you, so a snippet does not need boilerplate — unless it
starts with `process`, `collaboration`, `message`, `signal`, `error`,
`escalation` or `#`, in which case it is used as written.

Add this to `test/Sequent/ResolveSpec.hs`, inside the `describe "implicit
chaining"` block:

```haskell
    it "chains a service task into an end event" $ do
      let res = compileOk "start s\nservice a { type \"t\" }\nend e"
      succeeded res `shouldBe` True
      flowPairs "start s\nservice a { type \"t\" }\nend e"
        `shouldBe` [("StartEvent_s", "Activity_a"), ("Activity_a", "Event_e")]
```

To assert on the generated BPMN instead, use `compileXml` and the tree
helpers — this belongs in `test/Sequent/SerializeSpec.hs`:

```haskell
    it "emits a zeebe:taskDefinition for a service task" $ do
      let root = parseXml (compileXml "start s\nservice a { type \"order-validate\" }\nend e")
          task = fromMaybe (error "no task") (findById "Activity_a" root)
          def  = head (descendantsNamed "zeebe:taskDefinition" task)
      attr "type" def `shouldBe` Just "order-validate"
```

To assert on geometry, use `layoutOf` (which runs with the quality gate off, so
you can inspect a bad layout) and the `Rect` accessors — this belongs in
`test/Sequent/SpecRuleSpec.hs` or `LayoutInvariantSpec.hs`:

```haskell
    it "test_LAYOUT_005_column_pitch_is_uniform" $ do
      let l = layoutOf "start s\ntask a\ntask b\nend e"
      rX (shapeOf l "Activity_b") - rX (shapeOf l "Activity_a") `shouldBe` 160
```

Where things go:

* a new assertion about an existing subsystem → the matching `*Spec.hs`;
* a new SPEC rule → `test/Sequent/SpecRuleSpec.hs`, named
  `test_<RULE_ID>_<what_it_asserts>`, and add a row to
  [`spec-compliance.md`](spec-compliance.md);
* a whole new subsystem → a new module under `test/Sequent/`, listed in both
  `other-modules:` in `sequent.cabal` and the `main` of `test/Spec.hs`.

The test suite is built with `-Wno-x-partial`, so `head`/`last` on a list you
just constructed is fine and idiomatic here.

## Golden tests

Two kinds live in `test/Sequent/GoldenSpec.hs`, and they check different things.

**SPEC §L canonical examples** are inline fixtures (`patternA` … `patternJ`)
pinned to the exact coordinates the specification prints. Pattern A asserts the
literal bounds `(42,62,36,36) (140,40,100,80) (300,40,100,80) (462,62,36,36)`.
These are not regenerable: if one fails, either the layout engine regressed or
the specification's own numbers are being deliberately departed from, and you
have to decide which.

**Whole-file BPMN goldens** are the committed `examples/*.bpmn`. For every
`examples/*.sq` the spec asserts three things: it compiles without errors, it
matches the committed `.bpmn` byte for byte, and compiling it twice gives the
same bytes. One golden pins id policy, element order, attribute order and every
coordinate at once, which is why a byte diff is worth reading rather than
accepting.

To regenerate them:

```bash
SEQUENT_ACCEPT=1 cabal test
```

That **overwrites every** `examples/*.bpmn` — it is not selective. Always run
`git diff examples/` afterwards and read it. A golden diff is the compiler
telling you what your change did; accepting it unread throws that away. A
diff confined to `<dc:Bounds>` and `<di:waypoint>` is a layout change; a diff
that touches `id=` attributes is an id-policy change and needs much more care.

Adding an example is enough to create its golden: compile it once
(`cabal run sequent -- build examples/new.sq`) and commit both files. The
golden spec fails loudly if a `.sq` has no `.bpmn` beside it.

## Manual smoke tests

Automated tests cannot tell you whether a diagram is one a person would accept.
This ladder can. Compile each, open the result in Camunda Modeler, and look.

```bash
cabal run sequent -- build examples/hello.sq
```

**Smoke 1 — linear** (`examples/hello.sq`, `examples/linear.sq`). Start, tasks,
end, left to right on one horizontal axis. Every connector should be a single
straight segment with exactly two waypoints. Check:

```bash
grep -c 'di:waypoint' examples/linear.bpmn   # 6 waypoints for 3 flows = all straight
```

**Smoke 2 — XOR** (`examples/order.sq`, the `is_valid` gateway). The default
branch stays on the axis; the other drops below. Split and merge share a centre
y. Branch labels sit beside the diamond.

**Smoke 3 — parallel** (`examples/parallel.sq`). `<bpmn:parallelGateway>` twice
— a split and a *derived* join named `Gateway_prepare_join`. The two branches
straddle the axis symmetrically, at ±70 px in the canonical case.

```bash
grep -o 'Gateway_[a-z_]*' examples/parallel.bpmn | sort -u
```

**Smoke 4 — loop** (`examples/loop.sq`). The `goto` becomes a backward
`<bpmn:sequenceFlow>`. Its edge should have four waypoints, running in a
corridor above or below the main flow, never back through it.

**Smoke 5 — lanes** (`examples/lanes.sq`). One `<bpmn:laneSet>` with three
`<bpmn:lane>`s, each listing its members in `<bpmn:flowNodeRef>`. The lanes tile
the pool exactly — no gaps, no overlaps. Cross-lane connectors jog vertically at
the midpoint of the column gap.

**Smoke 6 — boundary error** (`examples/order.sq`, `on charge catch error`).
The `<bpmn:boundaryEvent>` sits centred on the border of `Activity_charge`, and
its handler path runs in a band *below* the main flow. Exception paths are
always below, never above.

**Smoke 7 — pools and message flows** (`examples/collaboration.sq`). Two
`<bpmn:participant>`s stacked vertically, message flows running vertically
between them in the inter-pool gap, drawn dashed by the modeller.

**Smoke 8 — subprocess** (`examples/subprocess.sq`). The expanded
`<bpmn:subProcess>` contains its children entirely, with padding, and the outer
flow enters and leaves its border.

## XML validation: what is and is not guaranteed

There is **no BPMN XSD in the repository** and nothing invokes an XML schema
validator. Be precise about what the green test suite buys you:

| Guarantee | Established by | Status |
|---|---|---|
| **syntactically valid XML** | every serialiser test re-parses the output with the reader in `Sequent/Test/Support.hs`; `XmlSpec` covers escaping | ✅ verified in-repo |
| **BPMN structurally valid** | `SerializeSpec`'s "schema conformance" group: child-element ordering against the BPMN sequence model, and reference integrity (every `sourceRef`, `targetRef`, `flowNodeRef`, `messageRef`, `errorRef`, `bpmnElement` resolves), swept over every example | ✅ verified in-repo, by hand-written checks — **not** by the official XSD |
| **Camunda-importable** | — | ❌ not automated; open the file in Camunda Modeler yourself |
| **Camunda-deployable** | — | ❌ not automated; no deploy tooling in the repository |
| **runtime-correct** | — | ❌ not automated; needs a running Zeebe cluster and job workers |

The first two are real and checked on every run. The last three are your eyes
and your cluster. Nothing in this repository has been through Camunda Modeler
in an automated way, so treat "opens in Modeler" as unverified until you have
done it.

## Debugging a failure

Work outward from the phase that owns the symptom.

| Symptom | Where to look |
|---|---|
| `error[parse]` | `src/Sequent/Language/Parser.hs`; check `reservedWords` first — a step named after a keyword is the usual cause |
| `error[name]` | `src/Sequent/Language/Resolve.hs`, `collectDeclarations` and `allocateSymbols` |
| wrong flows, missing merge | `Resolve.hs`, `runBody` / `gateway` — the merge exists only when two or more branches reach the end of the block, or the author wrote `join` |
| wrong BPMN element or attribute | `src/Sequent/Camunda/Serialize.hs`, `nodeTag` and `nodeElement` |
| missing `zeebe:` extension | `Serialize.hs` `extensionsFor`, and `Resolve.hs` `nodeKind` / `allowedProps` |
| `error[semantic]` | `src/Sequent/Bpmn/Validate.hs` |
| `error[camunda]` | `src/Sequent/Camunda/Validate.hs` |
| `error[layout/HC-*]` or `[layout/LAYOUT-*]` | `cabal run sequent -- rules \| grep <RULE>` names the module; then `sequent report` for the whole picture |
| `error[layout/LABEL-011]` | a caption had nowhere free to go. `Layout.placeAllLabels` for the ladder and its obstacles, `Layout.Labels.anchorLadder` for the order, `Layout.Bands.nodeExtent` for the room phase 5 was supposed to reserve |
| flow steps up or down at a subprocess border | `Layout.layoutScopeRecursive` — `containerBox` decides the container's `(above, below)` and `placeChild` hangs the child from it (LAYOUT-020) |
| a connector through a shape it does not touch | `Layout.Routing.routeOne`, the route class `classifyEdge` chose; `Layout.Validate.hc004` says which shape |
| golden mismatch | `git diff examples/` — coordinates only means layout; `id=` changes mean id policy |
| determinism failure | any `Data.Map`→list conversion whose order is not `(documentOrder, id)`; `Sequent.Bpmn.Semantic.canonicalise` is the reference |

Useful moves while debugging:

```bash
# see the layout's own opinion, without the gate failing the build
cabal run sequent -- report broken.sq

# get the diagram anyway, to look at what went wrong
cabal run sequent -- build broken.sq --lenient

# strip the geometry to see whether the problem is semantic
cabal run sequent -- build broken.sq -o /dev/stdout --no-di

# semantics only, no layout at all
cabal run sequent -- check broken.sq
```

## Turning a bug into a regression test

1. **Shrink it.** Cut the source down to the smallest file that still shows the
   bug. Most bugs fit in five lines; the corpus in `LayoutInvariantSpec.hs`
   shows the size to aim for.
2. **Pick the layer.** Parse or resolve → `ParserSpec`/`ResolveSpec`. BPMN
   output → `SerializeSpec`. Geometry → `SpecRuleSpec` (if a SPEC rule names
   it) or `LayoutInvariantSpec` (if it should hold for every shape).
3. **Write the assertion first, and watch it fail.** A regression test you
   never saw red is a test you have not written.
4. **Fix the compiler.**
5. **Re-run** `./scripts/check.sh`, and read any golden diff.

A worked example, from a bug that was actually fixed this way. The symptom: a
branch whose only content is a 36 px intermediate catch event produced a
connector stub shorter than `MIN_SEG`, and the build failed on `HC-005`.

The shrunk reproduction went into the shared corpus, so that every
hard-constraint sweep covers it rather than just one test:

```haskell
-- test/Sequent/SpecRuleSpec.hs, beside the other fixtures
smallEventBranches :: Text
smallEventBranches =
  "start s\nxor g { branch \"a\" when \"=a\" { wait w1 { timer \"PT5M\" } }\n\
  \branch \"b\" when \"=b\" { wait w2 { timer \"PT9M\" } } }\nend e"
```

added to `everyPattern`, which `test_HC_005_endpoints_lie_on_ports` and a dozen
other rules already sweep. Then a test that states the *reason* rather than the
symptom, so a future regression says what broke:

```haskell
    it "test_HC_005_an_off_axis_band_clears_the_split_by_a_whole_stub" $
      let l = layoutOf smallEventBranches
          gw = shapeOf l "Gateway_g"
          clearance n = abs (rectCenterY (shapeOf l n) - rectCenterY gw) - rH gw `div` 2
       in map clearance ["Event_w1", "Event_w2"] `shouldSatisfy` all (>= minSeg)
```

Both were red before the fix and green after. Note the shape of the second one:
it asserts the geometric property the router depends on, not the absence of one
error message. An assertion that only says `shouldBe []` tells you *that*
something broke; this one tells you *what*.
