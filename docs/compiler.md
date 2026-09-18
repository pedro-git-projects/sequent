# Using the compiler

Everything on this page was run against the repository as it stands. Where the
behaviour is surprising, the surprise is described rather than smoothed over.

## Prerequisites

There is no Nix file, no `Makefile`, no `stack.yaml` and no devcontainer. The
build is plain Cabal:

| | |
|---|---|
| GHC | 9.8.4 (the version this was built and tested with) |
| cabal-install | 3.18.1.0 |

`sequent.cabal` requires `base >=4.17 && <5`, so any GHC from 9.4 upwards
should work, but 9.8.4 is the only one verified here. Dependencies —
`containers`, `megaparsec`, `text`, `transformers`, `optparse-applicative`,
`filepath`, and for the tests `hspec`, `QuickCheck`, `directory`, `deepseq` —
all come from Hackage.

```bash
cabal build all      # library, the sequent executable, and the test suite
```

The build is `-Wall -Wcompat -Wincomplete-record-updates` clean.

## The executable

The package produces one executable, `sequent`, from `app/Main.hs`. Run it
through Cabal:

```bash
cabal run sequent -- <command> [args]
```

Everything after `--` goes to the program. To get a binary you can call
directly:

```bash
cabal install --installdir=./bin --overwrite-policy=always
./bin/sequent build examples/hello.sq
```

There is no `--version` flag. The version lives in `sequent.cabal`
(`0.2.0.0`) and is written into every generated file as
`exporterVersion="0.2.0"`.

## CLI reference

```
$ cabal run sequent -- --help
sequent - a textual process language compiled to Camunda 8 BPMN

Usage: sequent COMMAND

Available commands:
  build                    compile a .sq file to .bpmn
  check                    report diagnostics without writing output
  fmt                      print the file in canonical form
  report                   print the layout quality report
  import                   read a .bpmn file and write the .sq that produces it
  rules                    list the implemented specification rules
```

Every command that takes a file takes exactly one, as a positional argument.
There is no glob expansion, no directory mode and no watch mode; loop in the
shell if you need several files.

### `build`

```
Usage: sequent build FILE [-o|--output FILE] [--no-di] [--lenient]

  FILE                     a .sq source file
  -o,--output FILE         where to write the BPMN
                           (default: the source with a .bpmn extension)
  --no-di                  omit the diagram, emitting semantics only
  --lenient                downgrade hard layout violations to advisories
```

```bash
cabal run sequent -- build examples/order.sq
# examples/order.sq -> examples/order.bpmn

cabal run sequent -- build examples/order.sq -o /tmp/order.bpmn
```

* The default output path is the input path with its extension replaced by
  `.bpmn`. The input extension is not checked — `sequent build foo.txt` works
  and writes `foo.bpmn`.
* An existing output file is **overwritten** without warning, but only on
  success. On failure nothing is written and the previous file is left exactly
  as it was.
* `--no-di` drops the whole `<bpmndi:BPMNDiagram>` element. The result is valid
  BPMN semantics with no diagram; Camunda Modeler will open it and lay it out
  itself. Useful when you want to read the structure without the geometry.
* `--lenient` downgrades tier-0 and tier-1 layout violations from errors to
  advisories, so a diagram is written even when the layout engine knows it is
  wrong. Use it to *look at* a bad layout, not to ship one.

### `check`

```bash
cabal run sequent -- check examples/order.sq
# examples/order.sq: ok
```

Parses, resolves and validates — parser, BPMN semantics and Camunda semantics —
and writes nothing. It does **not** run the layout engine, so layout violations
never appear here. `build` can fail on a file `check` accepts.

### `fmt`

```bash
cabal run sequent -- fmt file.sq        # canonical form to stdout
cabal run sequent -- fmt file.sq -w     # rewrite the file in place
```

Formatting is conservative. It never reorders declarations or steps, and blank
lines follow one local rule (a blank line before and after any construct that
occupies more than one line), so adding a step perturbs at most the lines beside
it. It is idempotent: `fmt (fmt x) == fmt x`, asserted for every example in
`Sequent.PrettySpec`.

**Comments survive.** A comment written after code stays on that line; one
written on its own line stays above the construct it introduces, and stays
attached to it — the blank-line rule cannot come between them. A run of comment
lines stays a run. `Sequent.PrettySpec` asserts, for every committed example,
that formatting preserves the comments exactly.

The one comment the formatter moves is one written *inside* a construct rather
than between two — `task /* why */ a` comes back as `task a  /* why */`. The
text is kept; only its position within the line changes.

It also expands one-liner blocks:

```
end aborted "Abandoned" { terminate }
```

becomes

```
end aborted "Abandoned" {
  terminate
}
```

### `report`

```bash
$ cabal run sequent -- report examples/order.sq
score 89
  bendPenalty 16
  proximityPenalty 12
  gapUniformity 1
  areaPenalty 55
  edgeLengthPenalty 5
```

Compiles with the quality gate off, prints the layout score (lower is better)
broken down by term, then every layout violation with its rule id and tier.
This is the tool for "the diagram looks wrong, what does the compiler think?".

### `import`

```bash
$ cabal run sequent -- import examples/loop.bpmn
process rework "Rework loop" {
  start received "Draft received"

  user revise "Revise the draft" {
    groups "=editors"
  }
  ...
}
```

The only command that reads a `.bpmn`. It writes to stdout unless `-o` names a
file:

```bash
cabal run sequent -- import drawn-by-hand.bpmn -o process.sq
```

The output is already in canonical form — the same formatter `fmt` uses — so
running `fmt` over it changes nothing.

`import` verifies itself. Before printing anything it compiles the source it
just produced and compares the result with the process it read, element by
element, on symbolic names rather than on ids. A difference is an `error` that
names it, and nothing is written:

```
error[internal]: the imported source does not reproduce the original process (step 'settle' changed)
  = help: this is a defect in the importer, not in the file: please report it with the input
```

That check is why an import either round-trips or fails loudly; it never
half-succeeds.

A construct the language cannot express is a warning naming the element, and the
import continues without it:

```
$ cabal run sequent -- import odd.bpmn
warning[semantic]: a 'transaction' 'Activity_tx' has no equivalent in this language and was skipped
  = help: there is no syntax for it; keep it in a separate file, or model it another way
warning[semantic]: a data store reference 'Store_1' has no equivalent in this language and was skipped
  = help: the language has no data-store construct
process x {
  ...
}
```

Geometry is read for exactly one thing, and thrown away again. `<bpmndi:BPMNDiagram>`
is skipped on the way in and computed again on the way out, so `import` of a
hand-arranged file followed by `build` gives you the same process under this
compiler's layout rules. That is the intended use, not a limitation of the
reader. The exception is a **group**: BPMN records a group as a rectangle and
has no membership relation, so which elements a group holds is whatever its
rectangle encloses. The reader recovers the members from the drawing, writes
them as a `group` block, and discards the rectangle for ART-005 to compute
again.

**Ids survive only when they are names.** An id this compiler allocated carries
its symbol — `Activity_charge` imports as `charge` and compiles back to
`Activity_charge`. An id a modeller's tool allocated does not: `Activity_1x9k2df`
has no name in it, so the symbol is slugified from the label instead
(`say_hello`) and the id it compiles to is `Activity_say_hello`. Everything else
— the process id, message names, correlation keys, job types, every FEEL
expression — is preserved either way. See [`import.md`](import.md).

### `rules`

```bash
$ cabal run sequent -- rules
HC-001      Hard    T0  every connector is an orthogonal polyline    Layout.Routing.routeOne
...
```

Prints the 27 entries of `Sequent.Layout.Rules.ruleRegistry`: rule id, priority,
tier, one-line summary, and the module and function that implement it. This is
the registry the layout violations are reported against. It is *not* the full
list of `SPEC.md` rules — see [`spec-compliance.md`](spec-compliance.md) for
that, rule by rule.

## Exit codes and streams

| | |
|---|---|
| exit 0 | no errors; the requested output was produced |
| exit 1 | at least one diagnostic of severity `error` |

Diagnostics go to **stderr**. Command output — the `src -> dest` line, the
formatted source, the report, the rule list — goes to **stdout**. So
`sequent fmt f.sq > out.sq` is safe even when the file has warnings.

Warnings and advisories do not fail the build. This compiles and writes output:

```
$ cabal run sequent -- build /tmp/warn.sq
warning[semantic]: 'Activity_b' has no outgoing flow and is not an end event
/tmp/warn.sq -> /tmp/warn.bpmn
```

## The pipeline

```
source text
    ↓  Sequent.Language.Parser        megaparsec, spans on everything
surface AST
    ↓  Sequent.Language.Resolve       names, ids, implicit flows, derived merges
semantic graph (SG)                   BPMN meaning; no coordinates
    ↓  Sequent.Bpmn.Validate          BPMN semantics
    ↓  Sequent.Camunda.Validate       Zeebe execution metadata
    ↓  Sequent.Layout                 14 phases: LLS, then rendered geometry
rendered geometry (RG)                integer pixels; no XML
    ↓  Sequent.Camunda.Serialize      BPMN 2.0 + BPMN DI
.bpmn
```

`import` runs the right-hand column of that diagram backwards, and stops one
stage short of the top:

```
.bpmn
    ↓  Sequent.Camunda.XmlParse       namespace-aware reader; prefixes resolved to URIs
XML tree
    ↓  Sequent.Bpmn.Read              elements and Zeebe extensions -> BPMN meaning
semantic graph (SG)                   the same type 'build' produces
    ↓  Sequent.Language.Emit          symbols, implicit chains, derived merges
surface AST
    ↓  Sequent.Language.Format        the canonical form 'fmt' prints
.sq
```

There is no reverse of `Sequent.Layout` or `Sequent.Camunda.Serialize`, which is
the point: those two stages are what the import is discarding. The semantic
graph in the middle is the same type in both directions, which is what lets
`importText` compile its own output and compare.

The compiler stops at the first stage that produced an error, so a file with a
parse error does not also report every name it could not resolve. Within a
stage everything is reported at once. See
[`architecture.md`](architecture.md) for what each boundary buys.

## Reading the output

Take the smallest example:

```
process hello "Hello" {
  start begin "Started"
  task greet "Say hello"
  end done "Finished"
}
```

```bash
cabal run sequent -- build examples/hello.sq
```

Each source construct lands in a predictable place:

| Source | Generated BPMN |
|---|---|
| `process hello "Hello"` | `<bpmn:process id="Process_hello" name="Hello" isExecutable="true">` |
| `start begin "Started"` | `<bpmn:startEvent id="StartEvent_begin" name="Started">` |
| `task greet "Say hello"` | `<bpmn:task id="Activity_greet" name="Say hello">` |
| `end done "Finished"` | `<bpmn:endEvent id="Event_done" name="Finished">` |
| the implicit chaining | `<bpmn:sequenceFlow id="Flow_begin_greet" sourceRef="StartEvent_begin" targetRef="Activity_greet" />` |
| every node | one `<bpmndi:BPMNShape>` with a `<dc:Bounds>` |
| every flow | one `<bpmndi:BPMNEdge>` with two or more `<di:waypoint>` |

The symbolic name is visible in every id: `greet` → `Activity_greet`,
`Flow_begin_greet`. The label appears only in `name=`. That separation is the
point — see the identifiers section of [`language.md`](language.md).

Useful one-liners for eyeballing output:

```bash
# what elements did it produce?
grep -o '<bpmn:[a-zA-Z]*' out.bpmn | sort | uniq -c | sort -rn

# what Camunda extensions?
grep -o '<zeebe:[a-zA-Z]*' out.bpmn | sort -u

# semantics only, no geometry noise
cabal run sequent -- build in.sq -o /dev/stdout --no-di
```

## Failure modes

**Parse error.** Category `parse`, points at the offending character. No output.

```
error[parse]: 'flow' is a reserved word and cannot name a step
  --> e5.sq:3:8
  |
3 |   task flow
  |        ^
```

**Name resolution error.** Category `name`. Undefined step, duplicate
declaration, undeclared message/signal/error/escalation. No output.

**BPMN semantic error.** Category `semantic`. Unreachable node, flow into a
start event, boundary event on a gateway, event-gateway branch that does not
start with a catching event, subprocess without exactly one start event. No
output.

**Camunda validation error.** Category `camunda`. Empty job type, non-positive
retries, malformed ISO-8601 timer, mapping target that is an expression rather
than a variable name, a job type on an event that throws no message. No output.

A message `end` or `throw` event with no job type is a **warning**, not an
error: Camunda 8 runs a thrown message as a job and rejects the deployment
without one, but the process is valid BPMN and a model is often written before
its worker is named.

**Layout violation.** Category `layout/<RULE-ID>`, emitted after the layout
engine has run, with no source span — layout violations name BPMN element ids,
not source positions, because they are properties of the geometry.

```
error[layout/HC-004]: connector passes through Activity_a (Flow_s_c)
  = help: re-route, or insert a corridor by increasing band spacing
```

`Sequent.Compiler` applies the SPEC §K quality gates: a tier-0 or tier-1
violation is an error and no BPMN is written. Everything else is an advisory and
the diagram is still produced. `--lenient` downgrades the gate; `report` shows
the same information without failing.

To go from a layout violation to the code responsible, look the rule up:

```bash
cabal run sequent -- rules | grep HC-004
# HC-004  Hard  T0  no connector passes within EDGE_CLEAR of a non-incident node  Layout.Routing + Layout.Bands
```

## Determinism

Verified, not asserted:

```bash
cabal run sequent -- build examples/order.sq -o /tmp/a.bpmn
cabal run sequent -- build examples/order.sq -o /tmp/b.bpmn
sha256sum /tmp/a.bpmn /tmp/b.bpmn
# 16d4ed7b...  /tmp/a.bpmn
# 16d4ed7b...  /tmp/b.bpmn
```

Identical bytes, and identical to the committed `examples/order.bpmn`. The test
suite goes further: `Sequent.DeterminismSpec` shuffles the node, flow, artifact
and lane collections of a graph eight ways and requires byte-identical BPMN
back.

Known exceptions: none observed. The output depends on the source text, the
compiler version and the compile options (`--no-di` and `--lenient` change it,
by design). It does not depend on the clock, the filesystem, the locale or the
host's fonts — text measurement is a compiled-in advance-width table in
`Sequent.Text.Metrics`.

## What this compiler does not do

* **It does not preserve geometry in either direction.** Coordinates are
  computed from the layout rules on every build, so a hand-edit to the arrangement
  of a `.bpmn` is lost on the next one. `import` is how you keep the *process*
  from such a file; the arrangement is deliberately not kept.
* **It does not deploy.** There is no `zbctl` integration, no REST client and
  no cluster configuration anywhere in the repository. Generating the file and
  deploying it to Camunda 8 are separate jobs, and only the first one is here.
* **It does not validate against the BPMN XSD.** No schema file ships with the
  repository and nothing invokes an XML schema validator. What the tests check
  instead is described in [`testing.md`](testing.md).
* **The incremental-stability path has no CLI.** `Sequent.Layout` accepts a
  `PreviousGeometry` (`Map ScopeId Geometry`) so a re-run can keep a branch on
  the side a reader already knows, and `CompileOptions` carries `coPrevious`,
  but no command-line flag supplies one. It is a library feature today.
