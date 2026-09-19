# Current status

A factual report on what has actually been verified in this repository, written
by running the things it describes. Dated 2026-09-17, against version
`0.2.0.0`, GHC 9.8.4, cabal-install 3.18.1.0 on Linux.

## Build

**Clean checkout builds.** `cabal clean && cabal build all` succeeds in about
24 s on one core and produces **zero warnings** under
`-Wall -Wcompat -Wincomplete-record-updates`.

No system dependencies beyond GHC and Cabal. No Nix, no Stack, no Makefile, no
devcontainer — those files simply do not exist here.

There is no CI configuration.

## Tests

```
$ cabal test
826 examples, 0 failures
Finished in 0.9349 seconds
```

**All pass.** No subsystem is failing, and nothing is skipped or pending. The
suite is thirteen hspec modules; see [`testing.md`](testing.md) for what each
covers.

Nothing is asserted here that was not run: the counts above are from an actual
run of this working tree.

## Examples

Twelve `.sq` files in `examples/`, each with a committed `.bpmn` golden. **All
twelve compile with exit status 0 and reproduce their golden byte for byte:**

| Example | Exercises |
|---|---|
| `hello.sq` | the smallest process |
| `linear.sq` | SPEC §L pattern A, exact coordinates |
| `parallel.sq` | parallel split and derived join |
| `loop.sq` | `goto` loopback, corridor routing |
| `event-gateway.sq` | event-based gateway with receive tasks |
| `order.sq` | decision, loop, parallel split, boundary error, annotation |
| `onboarding.sq` | message/signal/error declarations, timer boundary, `goto` across a region |
| `lanes.sq` | three lanes, a lane re-entered, cross-lane connectors |
| `collaboration.sq` | two pools, message flows |
| `subprocess.sq` | expanded subprocess, call activity, multi-instance, business rule, script |
| `murex.sq` | a real process: a pool, an expanded subprocess with its own boundary events and handlers, signal throws, an escalation end, a `goto` out of an exception path |
| `handlers.sq` | two event subprocesses (one non-interrupting), a group, and a branch that stops without an end event |

`./scripts/check.sh` runs all of this in one command and currently prints
`check: PASS`.

## The reverse direction

**Verified over every example.** `sequent import` reads a `.bpmn` and writes the
`.sq` that produces it. All twelve goldens import with **no diagnostics**, and
recompiling the imported source reproduces the same BPMN process elements:

```
=== round trip
  examples/collaboration.bpmn: ok
  ...
  examples/subprocess.bpmn: ok
```

Three things are worth stating precisely, because "it round-trips" invites
over-reading:

* **Geometry is not compared, and not preserved.** It is discarded on the way in
  and computed again on the way out — the intended behaviour, not a shortfall.
  Measured anyway, on this tree: eight of the twelve come back **byte-identical**
  (`collaboration`, `event-gateway`, `handlers`, `hello`, `lanes`, `linear`,
  `loop`, `parallel`); three more (`order`, `subprocess`, `onboarding`) come back with
  **identical coordinates** but the DI elements in a different order, because the
  import re-derives the nesting and that changes document order; `murex` shifts
  one exception handler down by one band (10px) on a tie-break. None of that is
  promised, and none of it is asserted by the round-trip check — only the
  process is.
* **Element ids survive only when they are names.** `Activity_charge` comes back
  as `charge`; `Activity_1x9k2df` does not, and compiles to an id derived from
  the label instead. This is the one thing the round trip cannot keep, and it
  is why the self-check compares symbolic names.
* **The import checks itself.** `importText` compiles its own output and
  compares the graphs before returning, so a mismatch is an error naming the
  difference rather than a plausible-looking file. Every structural bug found
  while writing the emitter was found by that check.

Files this compiler did not write have been exercised only on hand-built inputs
in `Sequent.ImportSpec` — namespace spellings, entity decoding, DOCTYPE
skipping, ids that are not names, Zeebe metadata read from the extension rather
than the tag, group membership recovered from geometry, and each remaining
unsupported construct. **No corpus of `.bpmn` files produced by Camunda Modeler
or another tool has been imported**, for the same reason nothing has been opened
in Modeler: it needs a person with the tool.

The first modeller file that was tried found three attributes of one
declaration that this compiler never writes and so had never read back — a
process named differently from its participant, a process with no name, and
`isExecutable="false"` — and the import rejected its own output for each, which
is the self-check working. The language grew `process "…"` and `nonexecutable`
in response. See [`import.md`](import.md).

## Determinism

**Verified byte-identical.**

```
$ cabal run sequent -- build examples/order.sq -o /tmp/a.bpmn
$ cabal run sequent -- build examples/order.sq -o /tmp/b.bpmn
$ sha256sum /tmp/a.bpmn /tmp/b.bpmn
16d4ed7b4f88164e4ae914dd996cacc8b516e52277b82c4bf7cc01fc2dbc35cf  /tmp/a.bpmn
16d4ed7b4f88164e4ae914dd996cacc8b516e52277b82c4bf7cc01fc2dbc35cf  /tmp/b.bpmn
```

Both also match the committed `examples/order.bpmn`. `Sequent.DeterminismSpec`
strengthens this: it shuffles the node, flow, artifact and lane collections of a
graph eight ways and requires identical bytes back, with a guard test asserting
the shuffle really did reorder the lists.

No exceptions observed. Output depends on the source, the compiler version and
the compile options (`--no-di`, `--lenient`) — not on the clock, the locale, the
filesystem or the host's fonts.

## Camunda compatibility

Be precise about which rung of the ladder has been climbed:

| Stage | Status | Evidence |
|---|---|---|
| Generated XML inspected | ✅ **done** | every example's output read; element inventories checked with `grep -o '<bpmn:[a-zA-Z]*'`; the `zeebe:` extensions for service, user, script, business-rule, call and multi-instance tasks read attribute by attribute |
| XML well-formed | ✅ **verified in-repo** | every serialiser test re-parses the generated document and queries the tree; `XmlSpec` covers escaping |
| BPMN structurally valid | ✅ **verified in-repo, by hand-written checks** | `SerializeSpec`'s schema-conformance group asserts child-element ordering against the BPMN sequence model and full reference integrity (`sourceRef`, `targetRef`, `flowNodeRef`, `messageRef`, `errorRef`, `attachedToRef`, `bpmnElement` all resolve) over every example |
| Validated against the BPMN XSD | ❌ **not done** | no schema file in the repository; nothing invokes a schema validator |
| Opened in Camunda Modeler | ❌ **not done** | not automatable here; requires a person |
| Deployed to Camunda 8 | ❌ **not done** | no deployment tooling in the repository |
| Executed in Zeebe | ❌ **not done** | requires a cluster and job workers |

Two claims that would be easy to over-read: the namespaces, `modeler:executionPlatform="Camunda Cloud"` and `modeler:executionPlatformVersion="8.6.0"`
are emitted, and the id prefixes match what Camunda Modeler itself generates.
Neither of those is evidence that Modeler accepts the file. **The acceptance
test that matters has not been run.** Open `examples/order.bpmn` in Camunda
Modeler and look; that is the first thing to do with this compiler.

## Performance

Source text to BPMN bytes, `-O1`, one core, from `Sequent.PerformanceSpec`:

| nodes | time |
|---|---|
| 10 | 2 ms |
| 50 | 4 ms |
| 150 | 19 ms |
| 500 | 170 ms |

Each of these also asserts no tier-0 or tier-1 violation and that the diagram
stays inside the coordinate space.

## Known issues

Reproduced against this working tree. Each is a *known* failure — hitting one is
not a new bug.

**1. Parallel edges are rejected, not drawn.** Two sequence flows between one
pair of steps, or two message flows between one pair of endpoints, are a
semantic error. BPMN permits them; this compiler cannot draw them, because two
connectors between the same pair of ports are collinear by construction. The
error names the line and suggests the fix, which for two conditional paths to
one step is to combine the conditions. See
[one connection per pair](language.md#one-connection-per-pair).

**2. Constructs with no source syntax.** Nested lanes (`Lane.laneChildren`
exists and is always empty), data stores (`AkDataStore` exists in the model and
in the serialiser but nothing can construct one), BPMN groups, event
subprocesses, transaction subprocesses, collapsed subprocesses, and compensation
activities.

**3. Incremental layout stability has no CLI.** `Sequent.Layout.format` accepts
a `PreviousGeometry` and `CompileOptions` carries `coPrevious`, but no
command-line flag supplies one. LAYOUT-024 is a library feature only.

**4. Cosmetic: an unlabelled process reports as `process ''`.** The "has no
start event" diagnostic prints the process label rather than its identifier.

**5. Untested corners.** These compile and serialise but no test asserts their
output: black-box pools, link event definitions, compensation event
definitions, escalation event definitions in a real emission test (only in the
schema allow-list), and inclusive and complex gateways beyond the parser. See
the [feature matrix](language.md#feature-matrix).

**6. A caption with nowhere to go fails the build.** LABEL-011 is a tier-1
violation: if the anchor ladder and its eight outward retries all land on a
shape, another label or a connector, the compiler reports
`error[layout/LABEL-011]` rather than emitting text over another element. Two
long captions on boundary events one `BE_GAP` apart is the shape that gets
closest to it. `--lenient` downgrades it to an advisory if you want to look at
the result.

**7. One boundary-handler arrangement has no legal route.** A handler whose
`W` port sits `MIN_SEG` to the right of its host at the host's own mid-height
leaves one `MIN_SEG` of gap for both the escape corridor and the approach. The
route still clears the host; it reaches the port at an odd angle, which HC-005
and EDGE-024 report. The BPMN remedy is a different port (EDGE-020 rung 3),
which belongs to port assignment. No `.sq` file produces it — layering and
column separation keep a handler well to the right of its host — so it is
reachable only by constructing the geometry, which
`test_EDGE_014_the_exception_route_never_touches_its_host` does.

**8. 11 SPEC rules are partial and 5 are unimplemented**, each with its gap
named in [`spec-compliance.md`](spec-compliance.md). The unimplemented ones:
EDGE-022 and EDGE-023 (marker clearance — the markers are drawn by the modeller,
not by this compiler), LANE-011 (nested lanes), ART-004 (artifact dominance) and
ART-005 (groups). Also worth knowing: EDGE-010 crossing minimisation is complete
for the structured path only; its numeric fallback is not implemented.

## Where to start

1. `./scripts/check.sh` — confirm the repository is healthy on your machine.
2. `cabal run sequent -- build examples/order.sq` and open
   `examples/order.bpmn` in Camunda Modeler. That is the unverified rung, and
   the one that decides whether this compiler is usable.
3. Write your own `.sq` following [`language.md`](language.md), and compare what
   you get against the known issues above before filing anything.
