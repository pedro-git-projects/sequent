# sequent

*sequent* is a domain-specific language for defining Camunda 8 workflows, compiling directly to BPMN files. Its name is borrowed from logical sequents, conventionally written in the form A ⊢ B.

## What this is

This work grew out of practical frustration with deploying Camunda 8 BPMN workflows to production. Camunda’s orchestration model is strongly developer-oriented: many tasks in a workflow are executed by job workers implemented within microservices. Consequently, workflow artifacts are typically deployed through application services, while their source definitions are maintained in version-control systems alongside the surrounding codebase. In large repositories, particularly those containing multiple or structurally complex BPMN models that evolve frequently, merging becomes increasingly difficult because the serialized representation couples process semantics with incidental positional information.
  
Ultimately BPMN files are XMLs documentas that encode, among other things, the geometric realization of a process. In particular, element coordiantes are regenerated on each save, so a diff mostly records perturbations of the embedding, even the a displacement by a single pixel, rather than changes in the underlying process semantics. Because of this, two developers modifying semantically disjoint regions may still introduce conflicts in a converging syntatic block, despite their changes being essentially orthogonal. This suggested a natural separation of concerns: the source representation should encode only what is semantically relevant to process execution, while the choice of a concrete geometric instantiation should be delegated to a compiler. 

The resulting language, which I called sequent, uses .sq as its file extension. Once geometry is removed from the source, however, a new problem emerges: how should a compiler recover a deterministic and human-acceptable BPMN layout from purely semantic input? The main challenge was therefore to derive a consistent set of layout rules which, when applied to a source term, always produce a readable BPMN diagram. These rules make the rendering canonical in the relevant sense: the same source file always induces the same workflow layout.

The direction runs both ways: `sequent import` reads a `.bpmn` back into `.sq`, so an existing model can be brought under this discipline without being retyped.

The target is **Camunda 8 (Zeebe)**. The output carries the Zeebe namespace, `modeler:executionPlatform="Camunda Cloud"`, and the `zeebe:` extension elements for job types, I/O mappings, task headers, user tasks, forms, called decisions, called elements and multi-instance loops.

[`SPEC.md`](SPEC.md) is the normative layout specification for the rendering implements, and [`docs/spec-compliance.md`](docs/spec-compliance.md) says, rule by rule, where each one lives and which test covers it.

## Quick start

```bash
git clone https://github.com/pedro-git-projects/sequent
cd sequent

cabal build all
cabal run sequent -- build examples/hello.sq
# examples/hello.sq -> examples/hello.bpmn
```

Requires GHC (9.8.4 verified) and cabal-install (3.18.1.0 verified). There are no other
system dependencies.

```
examples/hello.sq
        │
        │  cabal run sequent -- build examples/hello.sq
        ▼
examples/hello.bpmn          <= valid Camunda 8 BPMN, diagram included
```

To write your own file somewhere else:

```bash
cabal run sequent -- build my-process.sq -o build/my-process.bpmn
```

## Minimal example

`examples/hello.sq`:

```
process hello "Hello" {
  start begin "Started"

  task greet "Say hello"

  end done "Finished"
}
```

Line by line:

* `process hello "Hello" { … }` declares a process. `hello` is its **identity** (it becomes the BPMN id `Process_hello`); `"Hello"` is its **label** (it becomes `name="Hello"`). That split runs through the whole language: renaming a label changes one string, renaming an identity changes an id and every reference to it.
* `start begin "Started"` a start event named `begin`, labelled `"Started"`. Becomes `<bpmn:startEvent id="StartEvent_begin" name="Started">`.
* `task greet "Say hello"` an abstract task. Becomes `<bpmn:task id="Activity_greet" name="Say hello">`.
* `end done "Finished"` an end event. Becomes `<bpmn:endEvent id="Event_done" name="Finished">`.
* **Nothing declares the arrows.** Consecutive steps chain implicitly, so the compiler emits `Flow_begin_greet` and `Flow_greet_done` for you. There is no edge list to keep in step with the node list.

Nothing mentions a coordinate or an element id, yet the output contains a complete `<bpmndi:BPMNDiagram>` with a `<dc:Bounds>` per node and waypoints per flow.

A larger one, showing a decision, a loop, a boundary error and a parallel split,
is [`examples/order.sq`](examples/order.sq);
[`examples/handlers.sq`](examples/handlers.sq) shows the constructs that have no
sequence flow of their own — event subprocesses, a group, and a path that stops
without an end event.

## Other commands

```bash
cabal run sequent -- check  in.sq            # diagnostics only, no output written
cabal run sequent -- fmt    in.sq [-w]       # canonical form, comments and all
cabal run sequent -- report in.sq            # layout score and rule violations
cabal run sequent -- import in.bpmn [-o f]   # BPMN back to .sq
cabal run sequent -- rules                   # the implemented layout rules
```

## The other direction

`import` reads a `.bpmn` and writes the `.sq` that produces it, so a process
drawn in Modeler — or emitted by somebody else's tool — can be brought under
version control and edited as text from then on.

```bash
cabal run sequent -- import drawn-by-hand.bpmn -o process.sq
```

Geometry is discarded on the way in and computed again on the way out, which is
the point: what comes back is the same process laid out by the rules rather than
by hand. Element ids survive when they are names — `Activity_charge` becomes
`charge` and compiles back to `Activity_charge` — and are regenerated from the
labels when they are not, which is the case for a file a modeller wrote. The
process id, the message names and every correlation key are kept either way.

The import **checks its own work**: the source it produces is compiled back to a
process and compared with the one that was read. A mismatch is an error naming
the difference, not a file you have to diff yourself. A construct the language
cannot express — a transaction, an ad-hoc subprocess, nested lanes, a data store
— is reported by id rather than dropped quietly.

A BPMN **group** is the one thing the importer reads geometry for. BPMN records
a group as a rectangle and has no membership relation at all, so which elements
a group holds is whatever its rectangle encloses; the importer recovers the
members from the drawing, writes them as a list, and throws the rectangle away
for the layout rules to compute again.

Diagnostics carry a category, a span and a caret:

```
error[semantic]: 'groups' is not a property of a start step
  --> onboarding.sq:8:5
  |
8 |     groups "hr-leads"
  |     ^^^^^^
  = help: a start step accepts: message, timer, signal, link, escalation, doc (on 'offer_accepted')
```

A layout violation names the rule it breaks:

```
error[layout/HC-004]: connector passes through Activity_a (Flow_s_c)
  = help: re-route, or insert a corridor by increasing band spacing
```

## The demos

Two, making the same argument: one small change to a process, made once by
hand in the XML and once in the source, and what each one costs.

```bash
./scripts/demo.sh           # in the terminal, ending in Camunda Modeler
./scripts/demo-visual.sh    # in the browser, with the diagram on screen
```

`demo-visual.sh` compiles the real examples, renders the BPMN diagram
interchange of each result as SVG, and animates the layout from one
compilation to the next, so the claim that the coordinates are derived is
something you watch rather than read. It writes one self-contained HTML file
with no network dependency, in a fixed 16:9 frame - arrow keys or click to
step, `a` to autoplay, `f` for the recording frame. `--stills DIR` writes one
1920x1080 PNG per scene instead, for a post that wants images rather than a
video.

## Running tests

```bash
./scripts/check.sh        # build + full test suite + compile every example + determinism
cabal test                # the test suite alone
```

Current result: **826 examples, 0 failures**.

The suite is a single hspec executable. Filter it with `--match`, which takes a
substring of the `describe`/`it` path:

```bash
cabal run spec -- --match "Sequent.Language.Parser"   # parser tests
cabal run spec -- --match "Sequent.Language.Resolve"  # semantic / resolution tests
cabal run spec -- --match "layout invariants"         # layout invariants
cabal run spec -- --match "SPEC rules"                # rule-by-rule layout tests
cabal run spec -- --match "golden"                    # golden tests
cabal run spec -- --match "test_HC_005"               # one test
```

`SEQUENT_ACCEPT=1 cabal test` rewrites every golden `.bpmn`. Read the `git diff`
afterwards; that is the point of having them.

## Documentation

| | |
|---|---|
| [`docs/language.md`](docs/language.md) | the language: worked example, full construct reference, feature matrix, limitations |
| [`docs/compiler.md`](docs/compiler.md) | building, the CLI, output, failure modes, determinism |
| [`docs/testing.md`](docs/testing.md) | running tests, writing your own, goldens, smoke tests, debugging |
| [`docs/architecture.md`](docs/architecture.md) | the four representations, the modules, the id policy, determinism |
| [`docs/current-status.md`](docs/current-status.md) | what has actually been verified, and what has not |
| [`docs/spec-compliance.md`](docs/spec-compliance.md) | rule => implementation => test, for every rule in `SPEC.md` |
| [`docs/import.md`](docs/import.md) | the reverse direction: reading `.bpmn` back into `.sq` |
| [`docs/migration.md`](docs/migration.md) | moving from the previous `.sequent` language |
| [`SPEC.md`](SPEC.md) | the normative layout specification |

## Pipeline

```
Source file => Surface AST => Semantic graph => Logical layout structure
            => Rendered geometry => Camunda 8 BPMN

Camunda 8 BPMN => Semantic graph => Surface AST => Source file
```

Import is the same road walked backwards, and it stops one representation short of the start: it rebuilds the semantic graph, writes a surface AST from it, and formats that. It never touches the layout structure or the geometry, because those are exactly the things it is throwing away.

Those four representations are kept apart on purpose. The main idea is: the semantic graphic is exactly what it sounds like, it holds BPMN *meanings* but no coordinates. The logical layout structure holds regions, layers, bands and ports but no pixels. The rendered geometry, in its turn holds integer pixels but no xml. [`docs/architecture.md`](docs/architecture.md) explains what each boundary
buys, stage by stage, with the type and module that carries it.
 

## What is in scope

Start, end, intermediate and boundary events with message, timer, signal, error, escalation, link, compensation and terminate definitions; non-interrupting start events; abstract, service, user, manual, script, business-rule, send and receive tasks; call activities; expanded subprocesses; event subprocesses; exclusive, parallel, inclusive, event-based and complex gateways; sequence flows with FEEL conditions and defaults; paths that stop without an end event; lanes; pools and message flows; text annotations, data objects and groups; multi-instance loops.

Camunda: `zeebe:taskDefinition`, `zeebe:ioMapping`, `zeebe:taskHeaders`,
`zeebe:userTask`, `zeebe:formDefinition`, `zeebe:assignmentDefinition`,
`zeebe:taskSchedule`, `zeebe:script`, `zeebe:calledDecision`,
`zeebe:calledElement`, `zeebe:loopCharacteristics`, `zeebe:subscription`.

**TODO**: nested lanes, data stores, transaction subprocesses, ad-hoc subprocesses and compensation activities. The importer reads a file containing any of them and reports each one by id rather than dropping it quietly. A collapsed subprocess imports fine and comes back expanded, with an advisory saying so. The [feature matrix](docs/language.md#feature-matrix) is the exhaustive list, cell by cell.

## Verification

```bash
cabal build all      # -Wall clean, zero warnings
cabal test           # 826 examples, 0 failures
./scripts/check.sh   # the above, plus every example against its golden,
                     # plus a .bpmn -> .sq -> .bpmn round trip of each one
```

The tests cover the parser and resolver behaviors with source positions, formatter idempotence, the id policy, deterministic text mectrics, BPMN structure and schema child ordering, asserted by re-parsing the generated XML rather then by string matching. Hard-constrait invariants over a corpus of nineteen process shapes. A rule-by-rule suite named after `SPEC.md` rules it checks. The canonical examples of `SPEC.md §L` as golden tests; byte-exact goldens for every example; determinism under eight shuffles of every input collection; and scale tests at 10, 50, 150 and 500 nodes. The import direction is covered
both from inside — it compiles its own output and compares the graphs before
returning — and from outside, by importing every golden and asserting the
recompiled process is unchanged.
 
Source to BPMN bytes, `-O1`, one core:

| nodes | time |
|---|---|
| 10 | 2 ms |
| 50 | 4 ms |
| 150 | 19 ms |
| 500 | 170 ms |

**The only acceptance test that matters, however, cannot be automated.** A human being must open the resulting BPMN in modeler and be happy with how it looks. Nothing in this repository has been through Modeler. 

## License

sequent is distributed under the [Apache License, Version 2.0](LICENSE).
