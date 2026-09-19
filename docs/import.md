# Reading `.bpmn` back

```bash
cabal run sequent -- import drawn-by-hand.bpmn -o process.sq
```

`import` is the only command that reads BPMN. It takes a `.bpmn` and writes the
`.sq` that produces it, so a process drawn in Modeler — or emitted by somebody
else's generator — can be brought under version control and edited as text from
then on. Without it the language is a one-way door, and nobody adopts a one-way
door for an existing repository full of models.

Everything below is what the import does and does not keep, stated precisely,
because "it round-trips" is a claim that is only useful with the exceptions
attached.

## What it is not

It is **not** a geometry-preserving round trip, and it is not trying to be.
`<bpmndi:BPMNDiagram>` is skipped on the way in and computed again from the
layout rules on the way out. Importing a hand-arranged file and building it
gives you the same process under this compiler's arrangement. That is the
intended use of the command, not a shortfall in the reader — the whole premise
of the language is that coordinates are a derived artifact.

**One exception, and it proves the rule: groups.** BPMN records a group as a
rectangle and has no membership relation at all — which elements a group holds
is whatever its rectangle happens to enclose. It is the one construct in the
format whose *meaning* is carried by coordinates, so it is the one construct
whose coordinates the importer has to read. It reads the group's bounds and the
bounds of the flow nodes in the same scope, takes as members those whose centre
falls inside (with a grid unit of slack, because a modeller drags a group
roughly round a run of steps), and then throws all of it away: the members
become a `group` block and ART-005 computes the rectangle again on the way out.
Boundary events are never members — they are drawn on their host's border, so a
group holding the host encloses them whatever the author meant.

A group whose rectangle encloses nothing is reported and comes back with no
members.

## The pipeline

```
.bpmn
    │  Sequent.Camunda.XmlParse   namespace-aware reader; prefixes resolved to URIs
    ▼
XML tree
    │  Sequent.Bpmn.Read          elements + zeebe extensions → BPMN meaning
    ▼
semantic graph                    the same type 'build' produces
    │  Sequent.Language.Emit      symbols, implicit chains, derived merges
    ▼
surface AST                       the same type the parser produces
    │  Sequent.Language.Pretty    the canonical form 'fmt' prints
    ▼
.sq
```

Two things are worth noticing about that diagram.

The **semantic graph in the middle is the same type** the forward direction
builds — not a parallel one written for the importer. Everything downstream of
it (validation, layout, serialisation) therefore applies unchanged, and so does
the check described below.

The **output is an AST, not text**. `Sequent.Language.Emit` builds an `SFile`
and hands it to the formatter, so an import lands in canonical form for free and
the formatter remains the only module that knows how the language is laid out.
`fmt` over an imported file is a no-op.

## It checks its own work

Before printing anything, `Sequent.Compiler.importText` compiles the source it
just produced and compares the resulting graph with the one it read, element by
element. If they differ, the import **fails** with an error naming the
difference:

```
error[internal]: the imported source does not reproduce the original process (step 'settle' changed)
  = help: this is a defect in the importer, not in the file: please report it with the input
```

This matters more than it looks. The emitter's failure mode is not a dropped
edge but an *invented* one: the language connects consecutive steps implicitly,
so writing two unrelated steps next to each other silently creates a flow that
was never in the file. A test suite catches that on the shapes it happens to
cover; comparing the graphs catches it on yours. Every structural bug found
while writing the emitter — a duplicated derived merge, a lost loop edge, a
branch that swallowed the step after the gateway — was found by this check
rather than by reading output.

The comparison is on **symbolic names**, not on raw ids, for the reason in the
next section, and on a normalised graph: document order is zeroed, nodes are
sorted by id and flows by their endpoints, since neither ordering is semantic.

The message has to name something. An earlier version compared the whole graph
but could describe only part of it, so a divergence in a field it did not
inspect — a lane, a process attribute, anything inside a subprocess — reported
`no difference found`, which tells the reader nothing and the maintainer only
that the bug is in the reporting. It now walks processes, lanes and nested
scopes, and the last-resort message says outright that the field is one the
check does not inspect rather than implying the graphs match.

## What survives

| | |
|---|---|
| Process structure | every node, every flow, conditions, defaults, loops |
| Element ids | **only when they are names** — see below |
| Process and participant ids | always |
| Labels | always |
| `documentation` | always, as `doc` |
| Message, signal, error and escalation declarations | always, with their names and codes |
| Correlation keys | always |
| Job types, retries, headers, I/O mappings | always |
| User-task form, assignee, candidate groups and users, due date | always |
| Called decisions, called elements, scripts | always |
| Multi-instance loops | always |
| Lanes | always, including a step that sits inside a branch |
| Pools and message flows | always |
| A process named differently from its participant | always, as `pool p "Participant" process "Process"` |
| A process with no name of its own | always, as `process ""` |
| `isExecutable="false"` | always, as `nonexecutable` |
| Text annotations and their associations | always |
| Boundary events, interrupting and not | always |
| Event subprocesses, interrupting and not | always, as `handler` |
| Groups | members recovered from the rectangle; text from the category value |
| Paths that stop without an end event | always, as `stop` |

### Ids survive only when they are names

An id this compiler allocated carries its symbol, and the import recovers it:
`Activity_charge` becomes `charge`, and compiling that back gives
`Activity_charge`. A file written in a modeller has ids like `Activity_1x9k2df`,
which is not a name anybody chose. The language has no syntax for *"this step's
id is that string"* — deliberately, since ids are derived from names — so the
symbol is slugified from the label instead:

```xml
<bpmn:task id="Activity_1x9k2df" name="Say hello"/>
```

```
task say_hello "Say hello"
```

and the id it compiles to is `Activity_say_hello`. **This is the one thing the
round trip cannot preserve**, and it is why the self-check compares names rather
than ids. If those ids matter to you — a deployed process whose incidents are
keyed on element ids, say — import once, keep the result, and let the ids
change once rather than on every build.

Names are claimed in one pass over the whole graph, so the name a step gets
depends on the file and not on the order a traversal happened to reach it. A
collision appends a numeric suffix (`charge`, `charge_2`). A candidate that is
empty, starts with a digit, or is a reserved word is rejected and the next
source is tried — the stripped id, then the slugified label, then the slugified
id — so a step labelled `end` does not produce a step named `end`.

## What does not survive

* **Geometry.** By design; see above.
* **Comments.** They live in the surface AST and never reach the semantic graph,
  so there is nothing in a `.bpmn` to recover them from.
* **The author's nesting.** The importer re-derives structure from the graph,
  and where the graph admits more than one nesting it picks one. A process whose
  `xor` closes and continues at the top level may come back with the rest of the
  process inside the last branch. The flows are identical — that is what the
  self-check asserts — but the indentation is not the author's.
* **Non-canonical spellings.** A condition written `x > 1` comes back as
  `"=x > 1"`, because the resolver normalises FEEL on the way in and the
  emitter writes what the graph holds.
* **Element order** where it is not semantic: the output follows the canonical
  order, not the document order of the input.
* **Layout pins** (`pin`). A pin never reaches the semantic graph — it nudges
  the diagram and nothing else — so there is nothing in the XML that says a
  coordinate was chosen rather than computed.
* **Whether a subprocess was drawn collapsed.** This compiler writes every
  subprocess expanded. The contents are the same either way; the import says so
  as an advisory, because the file will not look the same.
* **A user task without Camunda 8's `zeebe:userTask`.** A `bpmn:userTask` is a
  user task because of its tag — unlike a `bpmn:task`, whose tag means
  "undefined" — so a BPMN 2.0 file, or one written for Camunda 7, reads as one
  and comes back with the `zeebe:userTask` this language's `user` keyword
  always means. Reported as an advisory rather than done quietly.

## What it reports

Anything the language cannot express is a warning naming the element, and the
import continues without it. Nothing is dropped silently:

| in the file | reported as |
|---|---|
| `bpmn:dataStoreReference` | `a data store reference 'Store_1' …` |
| `bpmn:childLaneSet` | `a nested lane set in lane 'Lane_o' … flatten the lanes, or split the process` |
| a collapsed subprocess | `advisory: … is drawn collapsed and will come back expanded` |
| a `bpmn:group` enclosing nothing | `group 'Group_1' encloses no step and was read with no members` |
| `bpmn:userTask` with no `zeebe:userTask` | `advisory: … has no 'zeebe:userTask'; it will come back with one` |
| `bpmn:transaction`, `bpmn:adHocSubProcess` | `a 'transaction' 'Activity_tx' …` |
| a second `bpmn:collaboration` | `keep one collaboration per file` |
| two event definitions on one event | `event 'Event_x' has more than one trigger; kept the first` |
| Zeebe metadata on a plain `bpmn:task` | `carries execution metadata a plain task cannot run; dropped it` |
| any other element | reported by tag and id |

The last row is the one that matters: the fallback is *report by name*, not
*ignore*, so a construct nobody anticipated shows up in the output instead of
vanishing.

## Reading the extension, not the tag

Camunda 8 puts the meaning of an activity in its `extensionElements` as often as
in its tag, and the reader dispatches on the extension:

* a `zeebe:userTask` makes it a user task, wherever it sits;
* a `zeebe:taskDefinition` on a message end or throw event is the job Camunda
  runs it as, not stray metadata;
* a `zeebe:taskDefinition` on a `bpmn:scriptTask` or `bpmn:businessRuleTask` is
  the job-worker implementation of that task, as opposed to the broker-side
  `zeebe:script` or `zeebe:calledDecision` — the tag is identical either way,
  so a reader that looked only at the tag would lose one of the two;
* a `bpmn:task` is Camunda 8's *undefined* task, which the broker walks straight
  through, so metadata on one is inert and is dropped with a warning.

The XML reader underneath resolves namespace **prefixes to URIs** rather than
matching on the spelling, so `bpmn:process`, `bpmn2:process` and a `process`
under a default namespace all read the same. It has no DTD handling and does not
expand entities beyond the five predefined ones and numeric character
references: a DOCTYPE is skipped rather than honoured, because an importer that
resolves external entities is an XXE waiting to happen.

## How the structure is re-derived

The semantic graph is flat — nodes and the flows between them — while the
surface language is nested, and most of its edges are never written down. Three
reconstructions do the work:

**Implicit chains.** A flow is left unwritten when it is the only way out of its
source, the only way into its target, unlabelled, unconditional, and the target
has not been emitted yet. Everything else becomes a `goto` or an explicit
`flow`. The rule is deliberately conservative: emitting one step after another
*creates* an edge, so the emitter only nests where it already knows the edge
exists.

**Derived merges.** The resolver invents a merge gateway when two or more
branches reach the end of a gateway block. The emitter recognises the one the
resolver would have derived and leaves it out, so the source does not declare a
second one. A merge whose id is *not* the derived one is written as `join`,
which is exactly what that keyword exists for.

**Lanes.** Lane membership is per node, not per region, so a branch that hands
work to another role partitions correctly: each item is emitted under whichever
lane its own node belongs to, recursively, rather than under whichever lane the
gateway happened to be in.

A `flowNodeRef` lists a process's own flow nodes and never a subprocess's, so
the lane of a step *inside* a subprocess is not in the file at all. Both
directions therefore infer it the same way, from one rule in
`Sequent.Bpmn.Semantic.assignOrphanLanes`: a node in no lane takes the lane of
its highest-ranked predecessor, else its container's, else the first lane. A
subprocess is drawn inside a lane, so everything drawn inside it is in that lane
too. That rule used to live in the resolver, where only one of the two
directions could reach it, and a subprocess inside a lane could not round-trip.

**Paths that stop.** Every path that ends without an end event is closed with
`stop`, and so is every gateway branch that dead-ends. Both are the same
problem: two steps written next to each other are connected by the resolver, so
without a terminator a second dangling path swallows the first, and two
dangling branches are two branches the resolver counts as reaching the end of
the block — which is what it derives a merge from. The import used to report
`this scope has 2 paths that stop without an end event; only one of them can be
written` and hand back a source that was missing one; there is now a word for
it and nothing is dropped.

**Event subprocesses** are emitted as `handler` items rather than as steps,
because nothing flows into one: a step written next to the handler must stay
connected to the step on its other side.

## Verification

Every committed example is imported and recompiled on every run of
`./scripts/check.sh`, and `Sequent.ImportSpec` asserts the same property from
outside the compiler — independently of the self-check, which is the point of
doing it twice. All twelve examples import with no diagnostics and recompile to
identical process elements.

Geometry is not part of that claim. Measured anyway, out of curiosity rather
than as a guarantee: eight of the twelve come back byte-identical, three come
back with identical coordinates but the DI elements in a different order —
the import re-derives the nesting, and that changes document order — and
`murex` shifts one exception handler down by one band. Do not rely on any of it;
rely on the process comparison, which is the thing that is checked.

`Sequent.ImportSpec` also covers what the examples cannot: namespace spellings
(`bpmn:`, `bpmn2:`, a default namespace), entity and character-reference
decoding, a DOCTYPE that is skipped rather than expanded, a malformed document,
ids that are not names, Zeebe metadata read from the extension rather than the
tag, group membership recovered from geometry, non-interrupting flags in both
directions, dangling paths closed with `stop`, and each remaining unsupported
construct by name.

**Files from a real modeller have only started to arrive.** The suite is still
hand-built documents and this compiler's own output; the reader is built for
other people's files — that is the whole reason it resolves prefixes to URIs
instead of matching spellings — but it has not been run over a corpus of them.

The first one that was tried found three things this compiler had never
produced and so had never read back, all of them in the same declaration: a
process named differently from its participant, a process nobody named at all,
and a pool with `isExecutable="false"`. The language could write none of the
three, so the pool lent its label to the process and the import rejected its own
output — correctly, which is the point of the self-check. `process "…"` and
`nonexecutable` exist because of that file. Expect the next corpus to find more
of the same shape: attributes a modeller sets that this compiler had no reason
to write.
