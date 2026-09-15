# The sequent language

A `.sq` file describes a process. The compiler turns it into Camunda 8 BPMN,
including the diagram — the source never mentions a coordinate or an element id.

This guide teaches the language by building one process up step by step, then
documents every construct the compiler actually supports. Every complete example
on this page compiles with the compiler in this repository.

- [Why the language looks like this](#why-the-language-looks-like-this)
- [One process, built up](#one-process-built-up)
- [Identifiers and labels](#identifiers-and-labels)
- [Control flow](#control-flow)
- [Reference](#reference)
- [Feature matrix](#feature-matrix)
- [Errors](#errors)
- [Formatting](#formatting)
- [Current limitations](#current-limitations)
- [Grammar](#grammar)

## Why the language looks like this

Five ideas explain almost every syntactic decision. All five are properties the
compiler actually has; each one names where to verify it.

**The `.bpmn` file is a build artifact, not a source file.** Its ids and
coordinates churn on every save, so a diff shows the picture moved without
telling you whether the behaviour changed. Here the `.sq` is the truth. Ids are
derived from declared names and geometry is computed, so recompiling the same
source produces the same bytes — verifiable with `sha256sum`, asserted in
`Sequent.DeterminismSpec`.

**Identity is separate from presentation.** `service validate "Validate order"`
declares a step whose *identity* is `validate` and whose *label* is
`"Validate order"`. The identity becomes the BPMN id `Activity_validate` and is
what everything else refers to. Renaming the label changes one string in the
output; the id, and every reference to it, stays put. See
[Identifiers and labels](#identifiers-and-labels).

**Steps chain implicitly.** Consecutive steps in a block are joined by a
sequence flow. There is no edge list to keep in step with the node list — which
is the single biggest source of both noise and merge conflicts in textual BPMN
formats, because every edit touches the same block.

**Control flow nests.** A decision is a block containing its branches, so the
shape of the process is the shape of the file. Adding a branch adds a block;
adding a step adds a line. Two people working on different branches touch
different lines. This is why the language has no `->` chains for the common
case.

**No coordinates in ordinary source.** Layout is computed from BPMN meaning
alone by the engine in `Sequent.Layout`, following the normative specification
in [`SPEC.md`](../SPEC.md). The single exception is an explicit `pin`, for when
a human's refinement should survive re-formatting.

## One process, built up

### 1. The smallest thing that compiles

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

`process <name> <label>? { … }` declares a process. `start`, `task` and `end`
declare steps. Each step takes a symbolic name and an optional label string.
The three steps are joined by two sequence flows because they are consecutive —
nothing else is written.

Output: `<bpmn:process id="Process_hello" name="Hello" isExecutable="true">`
containing `<bpmn:startEvent id="StartEvent_begin" name="Started">`,
`<bpmn:task id="Activity_greet" …>`, `<bpmn:endEvent id="Event_done" …>` and
two `<bpmn:sequenceFlow>`s.

### 2. Real tasks with Camunda metadata

`task` is an abstract task — a placeholder with no execution semantics. Replace
it with the kind of work it actually is:

```
process fulfil "Order fulfilment" {
  start placed "Order placed"

  service validate "Validate order" {
    type "order-validate"
    input orderId = "=order.id"
    output valid = "=result.valid"
  }

  user review "Review by hand" {
    groups "order-desk"
    form "order-review"
  }

  end shipped "Shipped"
}
```

`service` becomes `<bpmn:serviceTask>` with a `<zeebe:taskDefinition
type="order-validate">`; `input`/`output` become `<zeebe:ioMapping>` entries;
`user` becomes `<bpmn:userTask>` with `<zeebe:userTask/>`,
`<zeebe:formDefinition>` and `<zeebe:assignmentDefinition>`.

Which properties a step accepts depends on its keyword. A misplaced one is an
error pointing at the property, with the accepted list in the hint.

### 3. A decision

```
process fulfil "Order fulfilment" {
  start placed "Order placed"

  service validate "Validate order" {
    type "order-validate"
    output valid = "=result.valid"
  }

  xor is_valid "Order valid?" {
    branch "valid" otherwise
    branch "invalid" when "=not(valid)" {
      user fix "Correct the order" { groups "order-desk" }
    }
  }

  service charge "Charge card" { type "payment-charge" }

  end shipped "Shipped"
}
```

`xor` is an exclusive gateway. Each `branch` is a block. `when "…"` carries a
FEEL condition; `otherwise` marks the default branch. A branch with no block —
like `branch "valid" otherwise` here — runs straight to the merge.

**The merge gateway is not written.** It is derived, because two branches reach
the end of the block, and it is named `<gateway>_join`: here
`Gateway_is_valid_join`. That keeps its id as stable as everything else.

### 4. A loop

Replace the `invalid` branch body so it goes back:

```
    branch "invalid" when "=not(valid)" {
      user fix "Correct the order" { groups "order-desk" }
      goto validate
    }
```

`goto <step>` connects the current path to an existing step and **ends the
path**. It is the only way to write a loop or a cross-link. Because the path
ends, only one branch now reaches the end of the block, so no merge gateway is
derived at all.

### 5. A parallel split

```
  and prepare "Prepare shipment" {
    branch {
      service pick "Pick items" { type "wms-pick" }
    }
    branch {
      service print_label "Print label" { type "shipping-label" }
    }
  }
```

`and` is a parallel gateway: every branch runs. Branches carry no conditions —
`when` or `otherwise` on an `and` branch is an error, since there is nothing to
choose. Two branches reach the end, so `Gateway_prepare_join` is derived as a
second `<bpmn:parallelGateway>`.

### 6. A boundary event

```
  on charge catch error payment_failed as charge_failed "Payment failed" {
    service notify "Tell the customer" { type "notify" }
    end aborted "Order abandoned" { terminate }
  }

  ...

error payment_failed "PAYMENT_FAILED" "Payment failed"
```

`on <host> catch <trigger> [noninterrupting] as <name> <label>? { handler }`
attaches a boundary event to an activity. The handler is a block, so the
exception path reads as a block — and the layout engine puts it in a band below
the main flow, always on the same side.

The `error` declaration is at the top level. Triggers refer to declarations by
name rather than carrying a wire string inline, so renaming the wire code does
not touch the events that catch it.

### 7. Lanes

```
process claim "Insurance claim" {
  lane intake "Intake" {
    start filed "Claim filed"
    service register "Register claim" { type "claim-register" }
  }

  lane assessment "Assessment" {
    user assess "Assess damage" { groups "assessors" }
    end settled "Settled"
  }
}
```

Lane membership comes from **nesting**, so moving a step between roles is one
block move rather than an attribute edit on every line. A repeated `lane` block
re-enters the same lane, which is what makes a process that hands work back and
forth writable without inventing a second name for a role — see
`examples/lanes.sq`.

### 8. Pools and message flows

```
message purchase_order "purchase-order" correlation "=orderId"

collaboration trade "Buyer and seller" {
  pool buyer "Buyer" {
    start need "Need identified"
    service raise_po "Raise purchase order" { type "po-create" }
    end received "Goods received"
  }

  pool seller "Seller" {
    start order_arrived "Order received" { message purchase_order }
    service confirm "Confirm order" { type "order-confirm" }
    end shipped "Goods shipped"
  }

  raise_po ~> order_arrived "purchase order"
}
```

A `collaboration` holds pools and the message flows between them. `->` is a
sequence flow; `~>` is a message flow, so a reader never has to work out which
kind of connection a line describes. A message flow must connect two different
pools; one that does not is a semantic error.

A `pool` with no body is a black-box participant, and a message flow may target
it by name.

The whole worked-up process is `examples/order.sq`; the collaboration is
`examples/collaboration.sq`.

## Identifiers and labels

An identifier matches `[A-Za-z_][A-Za-z0-9_]*` and must not be one of the
[reserved words](#grammar). It is the step's identity.

* **Scope.** Identifiers are unique across a whole process, including inside
  subprocesses and lanes — nesting does not open a new namespace. A repeat is
  `error[name]: duplicate declaration of '…'`. The one exception is a repeated
  `lane` name, which re-enters the existing lane.
* **They become BPMN ids, transformed.** The rule, in `Sequent.Bpmn.Id`, is
  `<ClassPrefix>_<sanitised name>`. Characters outside the XML `NCName` set
  become `_`. Prefixes match what Camunda Modeler itself generates:

  | Source | BPMN id |
  |---|---|
  | `start placed` | `StartEvent_placed` |
  | `end shipped` | `Event_shipped` |
  | `wait await_payment` | `Event_await_payment` |
  | `service charge` | `Activity_charge` |
  | `subprocess pick_pack` | `Activity_pick_pack` |
  | `xor is_valid` | `Gateway_is_valid` |
  | its derived merge | `Gateway_is_valid_join` |
  | `process fulfil` | `Process_fulfil` |
  | `lane finance` | `Lane_finance` |
  | `pool buyer` | `Participant_buyer` |
  | `message payment_confirmed` | `Message_payment_confirmed` |
  | `note retry_note` | `TextAnnotation_retry_note` |
  | `data receipt` | `DataObjectReference_receipt` |

* **Flow ids come from both endpoints.** `validate` → `charge` becomes
  `Flow_validate_charge`. Reordering declarations cannot renumber it.
* **Collisions get a numeric suffix** (`Activity_x_2`), allocated in a fixed
  class order so that adding an edge can never renumber a node.
* **No UUIDs, no counters, no label-derived ids.** An id is a pure function of
  the source name.

The consequences in a diff:

| Edit | What changes in the BPMN |
|---|---|
| change a **label** (`"Validate order"` → `"Check order"`) | one `name=` attribute |
| change an **identifier** (`validate` → `check`) | that element's `id`, every flow id mentioning it, every `sourceRef`/`targetRef`/`incoming`/`outgoing` referring to it, and its DI `bpmnElement` |

So renaming an identifier is a rename in the Camunda sense — historical
instances keyed on the old id will not match. Renaming a label is free.

## Control flow

Answers, taken from `Sequent.Language.Resolve`:

* **Sequence is implicit from order.** Consecutive steps in a block are joined
  by a sequence flow, in source order.
* **`->` exists but is the escape hatch, not the norm.** `flow a -> b` writes an
  explicit sequence flow, and it does *not* suppress implicit chaining. Use it
  only between steps the structure has left unconnected. Writing it between
  steps that already chain is an error, not a restatement — see
  [one connection per pair](#one-connection-per-pair).
* **Blocks are sequential by default.** A branch body, a subprocess body, a lane
  body and a boundary handler body all chain internally the same way.
* **Branches are blocks, not expressions.** A `branch` produces no value; it
  produces a path.
* **Split gateways are explicit, merges are synthesised.** You write `xor g {…}`;
  the merge `Gateway_g_join` appears exactly when two or more branches reach the
  end of the block, or when you name it with `join`.
* **Branches rejoin at the derived merge.** A branch whose body ends in an `end`
  step or a `goto` does not reach the merge — it terminates independently, and
  the layout engine ends it as early as it can rather than dragging it to the
  right margin.
* **Loops are `goto`.** There is no `while`, no `repeat` and no loop keyword.
  `goto` is a backward (or forward) sequence flow that ends the current path.
* **A step with no successor is a warning**, not an error:
  `'Activity_b' has no outgoing flow and is not an end event`.

A named merge, for when something has to refer to it:

```
and prepare join ready { … }
goto ready
```

## Reference

### File structure

A file is a sequence of top-level declarations. At least one `process` or
`collaboration` is required; at most one `collaboration` per file. Standalone
`process` declarations may sit beside a `collaboration`.

### Top-level declarations

| Construct | Syntax | Becomes |
|---|---|---|
| process | `process name "Label"? { item* }` | `bpmn:process` (`isExecutable="true"`) |
| collaboration | `collaboration name "Label"? { citem* }` | `bpmn:collaboration` |
| message | `message name "wire-name" correlation "=expr"?` | `bpmn:message`, with `zeebe:subscription` when a correlation key is given |
| signal | `signal name "wire-name"` | `bpmn:signal` |
| error | `error name "CODE" "Label"?` | `bpmn:error` (`errorCode="CODE"`) |
| escalation | `escalation name "CODE" "Label"?` | `bpmn:escalation` |

Messages, signals, errors and escalations are declared once and referred to by
their symbolic name. Referring to an undeclared one is an error whose hint is
the declaration to write. The label defaults to the code when omitted.

### Steps

Every step is `<keyword> <name> <label>? { <property>* }?`.

| Keyword | BPMN element | Notes |
|---|---|---|
| `start` | `bpmn:startEvent` | one per process; exactly one per subprocess |
| `end` | `bpmn:endEvent` | |
| `wait` | `bpmn:intermediateCatchEvent` | |
| `throw` | `bpmn:intermediateThrowEvent` | |
| `task` | `bpmn:task` | abstract; no execution semantics |
| `service` | `bpmn:serviceTask` | requires `type` |
| `user` | `bpmn:userTask` | emits `<zeebe:userTask/>` (Camunda 8 user tasks) |
| `manual` | `bpmn:manualTask` | |
| `script` | `bpmn:scriptTask` | requires `expression` (broker) or `type` (job worker) |
| `business` | `bpmn:businessRuleTask` | requires `decision` (DMN) or `type` (job worker) |
| `send` | `bpmn:sendTask` | requires `type`; emits `zeebe:taskDefinition` |
| `receive` | `bpmn:receiveTask` | requires `message`; emits `messageRef=` |
| `call` | `bpmn:callActivity` | requires `calls`; emits `zeebe:calledElement` |
| `subprocess` | `bpmn:subProcess` | `subprocess name "Label"? { item* }` — a block, not a property list |

A missing required property is an error at the step's name with the property to
add in the hint.

`script` and `business` have two implementations each, because Camunda 8 does:
the broker runs `expression` or `decision` itself, and `type` hands the work to
a job worker exactly as it does on a `service` step. Give one or the other —
naming both is an error, since only one of them would reach the XML.

```
script fee "Fee" { expression "=total * 0.02" }   # zeebe:script
script fee "Fee" { type "fee-worker" retries 3 }  # zeebe:taskDefinition

business risk "Risk" { decision "credit-scoring" }  # zeebe:calledDecision
business risk "Risk" { type "risk-worker" }         # zeebe:taskDefinition
```

### Properties

Accepted per keyword; anything else is an error at the property.

| Property | Syntax | Meaning | Allowed on |
|---|---|---|---|
| `type` | `type "job-type"` | `zeebe:taskDefinition type=` | `service`, `send`, a `script` or `business` implemented by a worker, and an `end` or `throw` that carries a `message` |
| `retries` | `retries 3` | `zeebe:taskDefinition retries=` | as `type` |
| `input` | `input target = "=expr"` | `zeebe:input` | `service`, `user`, `script`, `business`, `send`, `call`, and a message `end` / `throw` |
| `output` | `output target = "=expr"` | `zeebe:output` | as `input` |
| `header` | `header key = "value"` | `zeebe:header` | as `type` |
| `form` | `form "form-id"` | `zeebe:formDefinition formId=` | `user` |
| `assignee` | `assignee "=userId"` | `zeebe:assignmentDefinition assignee=` | `user` |
| `groups` | `groups "order-desk"` | `candidateGroups=` | `user` |
| `users` | `users "alice"` | `candidateUsers=` | `user` |
| `due` | `due "=deadline"` | `zeebe:taskSchedule dueDate=` | `user` |
| `expression` | `expression "=a * b"` | `zeebe:script expression=` | `script` (instead of `type`) |
| `result` | `result total` | result variable (default `result`) | `script`, `business` |
| `decision` | `decision "credit-scoring"` | `zeebe:calledDecision decisionId=` | `business` (instead of `type`) |
| `calls` | `calls "shipping-process"` | `zeebe:calledElement processId=` | `call` |
| `propagate` | `propagate` | `propagateAllChildVariables="true"` | `call` |
| `each` | `each item in "=order.lines" sequential?` | `bpmn:multiInstanceLoopCharacteristics` + `zeebe:loopCharacteristics` | every task keyword |
| `collect` | `collect results from "=score"` | multi-instance output collection | every task keyword |
| `message` | `message order_placed` | `bpmn:messageEventDefinition` / receive-task `messageRef` | `start`, `end`, `wait`, `throw`, `receive` |
| `timer` | `timer "PT15M"` | `bpmn:timerEventDefinition` | `start`, `wait` |
| `signal` | `signal hiring_frozen` | `bpmn:signalEventDefinition` | `start`, `end`, `wait`, `throw` |
| `error` | `error payment_failed` | `bpmn:errorEventDefinition` | `end` |
| `escalation` | `escalation overdue` | `bpmn:escalationEventDefinition` | `start`, `end`, `wait`, `throw` |
| `link` | `link "hop"` | `bpmn:linkEventDefinition` | `start`, `end`, `wait`, `throw` |
| `terminate` | `terminate` | `bpmn:terminateEventDefinition` | `end` |
| `compensation` | `compensation` | `bpmn:compensateEventDefinition` | `end`, `throw` |
| `doc` | `doc "text"` | `bpmn:documentation` | every step |

An event carries **at most one** definition; a second is an error.

**A thrown message is a job.** Camunda 8 implements a message `end` or `throw`
event the way it implements a service task: the broker creates a job and a
worker publishes the message. So those two steps take the job properties —
`type`, `retries`, `input`, `output`, `header` — and a process that omits the
job type is valid BPMN that Zeebe refuses to deploy:

```
end notify "Publish the shipment" {
  message shipment_published
  type "publish-shipment"
  retries 5
  header channel = "kafka"
}
```

Leaving the `type` out is a **warning**, not an error, because a model is often
written before the worker that serves it is named:

```
warning[camunda]: 'Done' throws a message but has no job type; Camunda 8 will reject the deployment
  = help: Zeebe creates a job for the worker that publishes the message: type "publish-shipment"
```

A job type on an event that throws no message *is* an error — a catching
message event takes a subscription, not a job.

FEEL expressions are normalised: a leading `=` is added when omitted, so
`"order.id"` and `"=order.id"` produce the same `zeebe:input source="=order.id"`.
The formatter writes the `=` back, so the source converges on the normalised
form.

Timer strings are classified by shape: `R…` is a cycle, `P…` a duration,
anything else a date. Each is checked against ISO-8601 and a malformed one is a
`camunda` error.

### Gateways

`<keyword> <name> <label>? (join <name>)? { branch* }`

| Keyword | BPMN element | Conditions |
|---|---|---|
| `xor` | `bpmn:exclusiveGateway` | `when` / `otherwise` allowed |
| `and` | `bpmn:parallelGateway` | neither allowed |
| `or` | `bpmn:inclusiveGateway` | `when` / `otherwise` allowed |
| `event` | `bpmn:eventBasedGateway` | neither allowed; every branch must begin with a catching event or a receive task |
| `complex` | `bpmn:complexGateway` | `when` / `otherwise` allowed |

An `event` gateway's derived merge is an **exclusive** gateway, which is what
BPMN requires.

A branch is `branch "Label"? (priority N)? (when "=expr" | otherwise)? { item* }?`.
The label becomes the sequence flow's `name`; `otherwise` sets the gateway's
`default` attribute. `priority` only influences which side of the axis the
branch is drawn on — it has no runtime meaning.

Rules the compiler enforces: a gateway with no branches is an error; multiple
`otherwise` branches on one gateway is an error; an unconditional branch on a
data-based gateway is diagnosed; a conditional branch on `and` or `event` is an
error.

### Attachments

| Construct | Syntax | Becomes |
|---|---|---|
| boundary event | `on host catch trigger noninterrupting? as name "Label"? { item* }` | `bpmn:boundaryEvent` with `attachedToRef` and `cancelActivity` |
| annotation | `note name "text" on host` | `bpmn:textAnnotation` + `bpmn:association` |
| data object | `data name "Label"? (from \| to) host` | `bpmn:dataObjectReference` + `bpmn:dataObject`, plus a `dataOutputAssociation` (`from`) or `dataInputAssociation` (`to`) |
| explicit flow | `flow a -> b -> c "Label"? guard?` | one `bpmn:sequenceFlow` per pair |
| layout pin | `pin name at X Y` | nothing in the semantics; fixes the shape's top-left corner |
| documentation | `doc "text"` | `bpmn:documentation` on the enclosing process or subprocess |

Triggers are `message name`, `signal name`, `error name`, `escalation name` or
`timer "P…"`. Only the timer carries a literal, because an ISO-8601 duration has
no identity to declare.

A boundary event attaches only to a task or a subprocess; attaching one to a
gateway or an event is an error. An empty handler block is a warning.

A label or condition on `flow` needs a single pair, not a chain.

### One connection per pair

Two steps may be joined by **at most one** sequence flow, and two endpoints by
at most one message flow. A second one is an error, reported at the line that
wrote it:

```
error[semantic]: 's' and 'a' are already connected
  --> p.sq:5:3
  |
5 |   flow s -> a
  |   ^
  = help: consecutive steps are connected without writing a flow; delete this line
```

The usual cause is writing a connection the language had already made — steps
chain implicitly, so `flow a -> b` under `task a` / `task b` adds a *second*
edge rather than restating the first. That matters because the second edge
normally carries the intent, and having two means the label or condition you
wrote lands on a connector nobody sees. The hint changes to match:

| Situation | Hint |
|---|---|
| the duplicate is bare | delete the line; the steps already chain |
| only the duplicate carries a label or condition | put them on the connection that already exists, or send the path elsewhere |
| both carry conditions (two branches with the same target) | combine the conditions into one branch, or give the paths different targets |

There is a second reason, and it is worth knowing because it is a limitation
rather than a preference: **the compiler cannot draw parallel edges.** Two
connectors between one pair of steps leave the same port and arrive at the same
port, so they are collinear by construction and no channel assignment separates
them. BPMN permits them; this compiler rejects them at the line that wrote them
rather than emitting a diagram with one connector hidden underneath another. If
you need two conditional paths to the same step, combine the conditions.

### Layout pins

```
pin charge at 500 200
```

`X Y` is the shape's top-left corner, in the same coordinate space the generated
`<dc:Bounds>` uses. This is the only place a coordinate may appear in source.

A pin does not move the node on its own — it forces the **band** the node sits
on. Everything on that band goes with it, and whatever is stacked beyond it in
the direction of travel follows: bands below a downward pin move down, lanes
below it move down, the exception band holding a boundary handler stays below
the host it belongs to. That is what makes a pin a refinement rather than a way
to break the diagram; pinning one step out of its band on its own would leave a
bent spine and a handler level with its own host.

Two rules constrain what you get back:

* **A pinned centre stays on the 10 px grid.** `HC-011` is a hard constraint and
  a pin is a strong one, so `pin e at 600 205` on a 36 px event puts it at
  `602 202` — the nearest position whose centre is aligned.
* **A pin is never silently dropped.** Any pin whose final position differs from
  what you asked for — because the grid moved it, because its column cannot move
  left without pushing its predecessor through it, or because another pin on the
  same band was applied first — is reported as
  `advisory[layout/LAYOUT-025]: layout pin could not be honoured: <id>`.

Conflicting pins are resolved in favour of the one declared first; the other is
reported.

### Comments

`#` and `//` to end of line, `/* … */` for blocks. `sequent fmt` keeps them —
see [Formatting](#formatting).

## Feature matrix

Every cell was checked against this repository: **Source** means the parser
accepts it, **Model** means it reaches the semantic graph, **BPMN** means it is
serialised, **Tested** means a test in `test/` covers it.

| Feature | Source | Model | BPMN | Tested |
|---|---|---|---|---|
| Process declaration | ✅ | ✅ | ✅ | ✅ |
| Start / end events | ✅ | ✅ | ✅ | ✅ |
| Intermediate catch (`wait`) / throw (`throw`) | ✅ | ✅ | ✅ | ✅ |
| Abstract task | ✅ | ✅ | ✅ | ✅ |
| Service task | ✅ | ✅ | ✅ | ✅ |
| User task | ✅ | ✅ | ✅ | ✅ |
| Manual task | ✅ | ✅ | ✅ | ✅ |
| Script task (`expression`, or `type` for a worker) | ✅ | ✅ | ✅ | ✅ |
| Business-rule task (`decision`, or `type` for a worker) | ✅ | ✅ | ✅ | ✅ |
| Send task | ✅ | ✅ | ✅ | ✅ |
| Receive task | ✅ | ✅ | ✅ | ✅ |
| Call activity | ✅ | ✅ | ✅ | ✅ |
| Expanded subprocess | ✅ | ✅ | ✅ | ✅ |
| Exclusive gateway (`xor`) | ✅ | ✅ | ✅ | ✅ |
| Parallel gateway (`and`) | ✅ | ✅ | ✅ | ✅ |
| Inclusive gateway (`or`) | ✅ | ✅ | ✅ | ⚠ parser only |
| Event-based gateway (`event`) | ✅ | ✅ | ✅ | ✅ parser, validation, `examples/event-gateway.sq` golden |
| Complex gateway (`complex`) | ✅ | ✅ | ✅ | ⚠ parser only |
| Derived merge gateway | ✅ | ✅ | ✅ | ✅ |
| Named merge (`join`) | ✅ | ✅ | ✅ | ✅ |
| Branch conditions (`when`) | ✅ | ✅ | ✅ | ✅ |
| Default flow (`otherwise`) | ✅ | ✅ | ✅ | ✅ |
| Branch priority | ✅ | ✅ | n/a (layout only) | ✅ |
| Implicit chaining | ✅ | ✅ | ✅ | ✅ |
| Explicit flow (`flow a -> b`) | ✅ | ✅ | ✅ | ✅ |
| Parallel edges between one pair | ❌ rejected | ❌ | ❌ | ✅ |
| Loops (`goto`) | ✅ | ✅ | ✅ | ✅ |
| Boundary events, interrupting | ✅ | ✅ | ✅ | ✅ |
| Boundary events, `noninterrupting` | ✅ | ✅ | ✅ | ✅ |
| Timer definitions | ✅ | ✅ | ✅ | ✅ |
| Message definitions + `correlation` | ✅ | ✅ | ✅ | ✅ |
| Signal definitions | ✅ | ✅ | ✅ | ✅ |
| Error definitions | ✅ | ✅ | ✅ | ✅ |
| Escalation definitions | ✅ | ✅ | ✅ | ⚠ schema allow-list only |
| Link events | ✅ | ✅ | ✅ | ⚠ schema allow-list only |
| Terminate end event | ✅ | ✅ | ✅ | ✅ |
| Compensation event definition | ✅ | ✅ | ✅ | ⚠ schema allow-list only |
| Lanes | ✅ | ✅ | ✅ | ✅ |
| Nested lanes | ❌ | ⚠ `laneChildren` exists, always empty | ❌ | ❌ |
| Pools / participants | ✅ | ✅ | ✅ | ✅ |
| Black-box pool | ✅ | ✅ | ✅ | ❌ untested |
| Message flows (`~>`) | ✅ | ✅ | ✅ | ✅ |
| Text annotations (`note`) | ✅ | ✅ | ✅ | ✅ parser, layout, `examples/order.sq` golden |
| Data objects (`data`) | ✅ | ✅ | ✅ | ⚠ parser, id and layout tested; no BPMN-output test |
| Data stores | ❌ | ⚠ `AkDataStore` exists, unreachable | ⚠ code path exists | ❌ |
| Groups (BPMN artifact) | ❌ | ❌ | ❌ | ❌ |
| Multi-instance (`each` / `collect`) | ✅ | ✅ | ✅ | ✅ |
| I/O mappings | ✅ | ✅ | ✅ | ✅ |
| Task headers | ✅ | ✅ | ✅ | ✅ |
| Job type / retries | ✅ | ✅ | ✅ | ✅ |
| Job on a message `end` / `throw` event | ✅ | ✅ | ✅ | ✅ resolve, Camunda validation, serialiser |
| Forms, assignee, groups, users, due | ✅ | ✅ | ✅ | ✅ |
| Documentation (`doc`) | ✅ | ✅ | ✅ | ✅ |
| Layout pins (`pin`) | ✅ | n/a (kept beside the graph) | affects DI only | ✅ |
| Comments | ✅ | ✅ kept in the AST | n/a (never serialised) | ✅ parser and formatter |
| Generated BPMN DI (shapes, edges, labels) | n/a | n/a | ✅ | ✅ |
| Compensation *activity* / association | ❌ | ❌ | ❌ | ❌ |
| Transaction subprocess, event subprocess | ❌ | ❌ | ❌ | ❌ |
| Ad-hoc subprocess | ❌ | ❌ | ❌ | ❌ |
| Collapsed subprocess | ❌ | ❌ | ❌ | ❌ |
| Reading `.bpmn` back (`sequent import`) | n/a | ✅ | n/a | ✅ every example round-trips |

Legend: ✅ supported · ⚠ partial · ❌ unsupported.

### What `import` reads

The importer's coverage is the **BPMN** column read backwards: it reads every
construct the serialiser writes, including the `zeebe:` extension elements, and
it recognises them by what is in `extensionElements` rather than by the tag — a
Camunda 8 user task is a `bpmn:userTask` in some files and a `bpmn:task` with a
`zeebe:userTask` in others, and both read the same.

Everything with a ❌ in the **BPMN** column is reported by id and skipped, never
dropped silently:

| in the file | what you get |
|---|---|
| `bpmn:group` | `warning: a BPMN group 'Group_1' … the language has no group construct` |
| `bpmn:dataStoreReference` | `warning: a data store reference 'Store_1' …` |
| `bpmn:childLaneSet` | `warning: a nested lane set in lane 'Lane_o' … flatten the lanes, or split the process` |
| `bpmn:subProcess triggeredByEvent="true"` | `warning: an event subprocess 'Activity_es' … inline its contents, or model it as a call activity` |
| `bpmn:transaction`, `bpmn:adHocSubProcess` | `warning: a 'transaction' 'Activity_tx' …` |
| a collapsed subprocess | `warning: a collapsed subprocess 'Activity_c' …` |
| any other element | reported by tag and id, so nothing goes missing unnoticed |

The one thing that does not survive is an **element id that is not a name**.
`Activity_charge` is a name and comes back as `charge`; `Activity_1x9k2df` is
not, so the symbol is slugified from the label and the id changes on the way
out. Message names, correlation keys, the process id, job types and FEEL
expressions are kept in both cases. [`import.md`](import.md) is the full
account.

## Errors

Every diagnostic carries a severity, a category and — for everything before
layout — a source span with a caret. Read it as: `severity[category]: message`,
then `--> file:line:col`, then the source line with the offending characters
underlined, then an optional `= help:` hint.

Categories: `parse`, `name`, `semantic`, `camunda`, `layout/<RULE-ID>`,
`internal`. Severities: `error` (fails the build), `warning`, `advisory`.

**Syntax error** — points at the character the parser could not use:

```
error[parse]: unexpected 'e'; expecting '}' or property
  --> e1.sq:4:3
  |
4 |   end c
  |   ^
```

**Reserved word as an identifier** — reported at the word, not three lines
later:

```
error[parse]: 'flow' is a reserved word and cannot name a step
  --> e5.sq:3:8
  |
3 |   task flow
  |        ^
```

**Duplicate identifier**:

```
error[name]: duplicate declaration of 'a'
  --> e2.sq:3:8
  |
3 |   task a "Again"
  |        ^
```

**Unknown reference**:

```
error[name]: undefined step 'nowhere'
  --> e3.sq:5:13
  |
5 |   flow b -> nowhere
  |             ^^^^^^^
  = help: every name in a flow must be declared as a step somewhere in the process
```

**Invalid semantic relationship**:

```
error[semantic]: a boundary event attaches to a task or subprocess, not to the xor gateway
  --> t.sq:5:4
  |
5 | on g catch error e1 as h { task t } }
  |    ^
  = help: move the catch onto the activity that can fail
```

**Unsupported combination** — a property that exists but not on this keyword:

```
error[semantic]: a 'when' condition is only allowed on a branch of an xor, or or complex gateway, not and 'g'
  --> e4.sq:4:18
  |
4 |     branch "one" when "=x" { task t1 }
  |                  ^^^^^^^^^^
  = help: an event gateway selects by which event arrives first; a parallel gateway takes every branch
```

**Layout violation** — after the layout engine has run. These name BPMN element
ids, not source positions, because they are properties of the geometry:

```
error[layout/HC-004]: connector passes through Activity_a (Flow_s_c)
  = help: re-route, or insert a corridor by increasing band spacing
```

Diagnostics are deterministically ordered (severity, then position, then
category, then rule, then message) and go to stderr. See
[`compiler.md`](compiler.md) for exit codes.

## Formatting

```bash
cabal run sequent -- fmt file.sq        # canonical form to stdout
cabal run sequent -- fmt file.sq -w     # rewrite in place
```

* **Idempotent**: `fmt (fmt x) == fmt x`, asserted for every example in
  `Sequent.PrettySpec`.
* **Never reorders anything.** Source order is process order, and the formatter
  preserves it.
* **Blank lines follow one local rule** — one before and after any construct
  that occupies more than one line — so adding a step perturbs at most the lines
  beside it.
* **Two-space indentation**, and a property key is quoted only when it is not a
  valid identifier.
* **Comments survive.** One written after code stays on that line; one on its
  own line stays above the construct it introduces, and stays attached to it, so
  the blank-line rule can never come between a comment and what it documents. A
  run of comment lines stays a run. The only comment that moves is one written
  *inside* a construct — `task /* why */ a` comes back as `task a  /* why */`.
* One-liner blocks are expanded to multiple lines.

Formatting never changes the compiled BPMN: `PrettySpec` asserts that a file and
its formatted form compile to identical bytes.

## Current limitations

Real findings, not speculation. Where a bug has a minimal reproduction it is
given, so you can tell a known failure from a new one.

**`flow` does not suppress implicit chaining.** Writing `flow a -> b` between
steps that are already consecutive silently produces two parallel sequence flows
(`Flow_a_b`, `Flow_a_b_2`). There is no duplicate-flow diagnostic; you find out
because the layout engine then reports `HC-005`.

**No BPMN reader.** The direction is `.sq` → `.bpmn`, once. A hand-edit to the
generated file is lost on the next build.

**No deployment tooling.** The compiler writes a file; getting it into a Camunda
8 cluster is a separate job with separate tools.

**Nested lanes, data stores, groups, event subprocesses, transaction
subprocesses, collapsed subprocesses and compensation activities have no
syntax.** For lanes and data stores the semantic model has a field
(`laneChildren`, `AkDataStore`) that nothing can populate from source.

**A process with no label reports as `process ''`.** The "has no start event"
diagnostic prints the label rather than the identifier, so an unlabelled process
shows an empty name. Cosmetic.

**Incremental layout stability has no CLI.** `Sequent.Layout` accepts a
`PreviousGeometry`, and `CompileOptions` carries `coPrevious`, but no flag
supplies one. Library-only today.

**12 SPEC layout rules are partial and 5 are unimplemented.** Each keeps a row,
with its gap named, in [`spec-compliance.md`](spec-compliance.md).

## Grammar

```
file        := decl*
decl        := 'process' name label? '{' item* '}'
             | 'collaboration' name label? '{' citem* '}'
             | 'message' name string ('correlation' string)?
             | 'signal' name string
             | 'error' name string label?
             | 'escalation' name string label?

citem       := 'pool' name label? ('{' item* '}')?
             | name '~>' name label?

item        := 'doc' string
             | 'lane' name label? '{' item* '}'
             | 'on' name 'catch' trigger 'noninterrupting'? 'as' name label? '{' item* '}'
             | 'note' name string 'on' name
             | 'data' name label? ('from' | 'to') name
             | 'pin' name 'at' int int
             | 'flow' name ('->' name)+ label? guard?
             | 'goto' name
             | gateway name label? ('join' name)? '{' branch* '}'
             | 'subprocess' name label? '{' item* '}'
             | step name label? ('{' prop* '}')?

branch      := 'branch' label? ('priority' int)? guard? ('{' item* '}')?
guard       := 'when' string | 'otherwise'
trigger     := ('message' | 'signal' | 'error' | 'escalation') name
             | 'timer' string

step        := 'start' | 'end' | 'wait' | 'throw' | 'task' | 'service' | 'user'
             | 'manual' | 'script' | 'business' | 'send' | 'receive' | 'call'
gateway     := 'xor' | 'and' | 'or' | 'event' | 'complex'

prop        := 'type' string | 'retries' int
             | 'input' key '=' string | 'output' key '=' string
             | 'header' key '=' string
             | 'form' string | 'assignee' string | 'groups' string
             | 'users' string | 'due' string
             | 'expression' string | 'result' key
             | 'decision' string | 'calls' string | 'propagate'
             | 'each' key 'in' string 'sequential'?
             | 'collect' key 'from' string
             | 'message' name | 'signal' name | 'error' name | 'escalation' name
             | 'timer' string | 'link' string
             | 'terminate' | 'compensation' | 'doc' string

name        := [A-Za-z_][A-Za-z0-9_]*      -- and not a reserved word
key         := name | string
label       := string
string      := '"' ( escape | ~["\\] )* '"'
escape      := '\\' ( '"' | '\\' | 'n' | 't' | 'r' )
int         := [0-9]+
```

The grammar is whitespace-insensitive with `{}` blocks: no indentation rules, so
a merge that shifts indentation cannot change meaning.

Every keyword above is reserved and cannot name a step, plus `correlation`,
`join`, `priority`, `in`, `at`, `sequential`, `from`, `to`, `on`, `catch`, `as`
and `branch`. That costs a handful of unusable names and buys unambiguous
parsing and errors that land on the offending word. The full set is
`Sequent.Language.Parser.reservedWords`.
