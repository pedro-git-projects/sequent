# Migration from the previous language

The previous compiler read `.sequent` files: a flat list of node declarations
followed by a list of edges. The new language reads `.sq` files in which control
flow nests and consecutive steps chain implicitly.

Everything the old language could express, the new one can. This is the mapping,
and why each change was made.

## File extension

`.sequent` → `.sq`. Shorter, and it makes a mixed repository during migration
unambiguous.

## Topology: edge lists become nesting

**Old**

```
process Onboarding "Employee onboarding" {
  start OfferAccepted "Offer accepted"
  service CreateRecord "Create HR record" { task "hr-create-record" }
  xor CheckClear "Background check clear?"
  service Provision "Provision accounts" { task "it-provision" }
  user ReviewException "Review exception" { groups "hr-leads" }
  end Onboarded "Onboarded"

  OfferAccepted -> CreateRecord -> CheckClear
  CheckClear -> Provision "clear" when "=checkResult = \"clear\""
  CheckClear -> ReviewException "needs review" when "=checkResult != \"clear\""
  ReviewException -> Provision
  Provision -> Onboarded
}
```

**New**

```
process onboarding "Employee onboarding" {
  start offer_accepted "Offer accepted"

  service create_record "Create HR record" { type "hr-create-record" }

  xor check_clear "Background check clear?" {
    branch "clear" otherwise
    branch "needs review" when "=checkResult != \"clear\"" {
      user review_exception "Review exception" { groups "hr-leads" }
    }
  }

  service provision "Provision accounts" { type "it-provision" }

  end onboarded "Onboarded"
}
```

**Reason.** The edge list is the part of a textual BPMN format that ages worst.
It has to be kept in step with the node list by hand, every edit touches the same
block (so two people editing different parts of the process conflict), and the
topology is only visible if you trace it. Nesting puts the shape of the process
in the shape of the file, and makes adding a branch a block insertion rather
than three scattered line edits.

The merge gateway (`Gateway_check_clear_join`) is now derived rather than
written. It exists exactly when two or more branches reach the end of the block.

## Explicit edges are still available

`flow a -> b` is the escape hatch for graphs the structured constructs cannot
express, and `goto x` writes a loop or a cross-link:

```
flow validate -> audit "sampled" when "=sample"
goto validate
```

**Reason.** BPMN is not a structured language; a compiler that can only express
structured graphs is not a BPMN compiler. What changed is which one is the
default.

## `task "type"` becomes `type "…"`

**Old** `service Validate { task "order-validate" retries 3 }`
**New** `service validate { type "order-validate" retries 3 }`

**Reason.** `task` is now a step keyword (an abstract BPMN task). Using the same
word for a step kind and for a Zeebe job type was ambiguous to read and to parse.

## Message, signal and error references are declared

**Old** `receive AwaitContract { message "contract-signed" }` — the string was
matched against a root `message` declaration by wire name, and a message that had
never been declared was invented with a warning.

**New**

```
message contract_signed "contract-signed" correlation "=candidateId"

receive await_contract { message contract_signed }
```

**Reason.** Identity-first, like every other name in the language: renaming the
wire name now touches one line instead of every event that waits for it. And a
caught message needs a correlation key — Zeebe refuses the deployment without
one — so inventing the message silently was deferring a deployment failure. The
error now names the declaration to write.

`error` and `escalation` gained top-level declarations for the same reason;
`timer` still takes a literal, because an ISO-8601 duration has no identity to
declare.

## Boundary events gained a body

**Old** `on Provision catch error "PROVISION_FAILED" -> ReviewException`
**New**

```
error provision_failed "PROVISION_FAILED"

on provision catch error provision_failed as provision_error "Provisioning failed" {
  user manual_provision "Provision by hand" { groups "it-ops" }
  goto workspace
}
```

**Reason.** The boundary event now has a name of its own (`as provision_error`),
so its BPMN id is derived like everything else instead of from
`<host>_<trigger>` — which collided whenever a host had two timers. The handler
is a block, so an exception path reads as a block, and the layout engine has a
scope to allocate the exception band from.

The one-line form is `{ goto target }`.

## Conditions on activity flows

**Old** a `when` condition was rejected on any flow that did not leave an
`xor`/`or` gateway.
**New** conditions are accepted on flows leaving a data-based gateway *or* an
activity (an implicit split), which is what BPMN allows.

## New in the language

Constructs the old compiler had no syntax for:

* `lane`, `collaboration`, `pool` and the `~>` message-flow arrow;
* `subprocess` (expanded) and `call` (call activity);
* `wait` and `throw` intermediate events;
* `script`, `business` and `send` tasks;
* `each … in …` multi-instance loops and `collect … from …`;
* `note` and `data` artifacts;
* `pin` layout hints;
* `escalation` declarations, `link` and `compensation` event definitions;
* `branch priority` and `join` naming.

## Ids

The id scheme is unchanged in shape — `Activity_<name>`, `Gateway_<name>`,
`Flow_<from>_<to>` — so an existing `.bpmn` produced by the old compiler keeps
the same ids for the same names, and a migrated file produces a diff in geometry
rather than in identity. Two additions:

* a derived merge gateway is `Gateway_<split>_join`;
* boundary events take their own declared name rather than `<host>_<trigger>`.

## Mechanical steps

1. Rename `.sequent` to `.sq`.
2. Rename each `task "x"` property to `type "x"`.
3. Add `message` / `error` / `escalation` declarations for anything referred to
   by a wire name, and change the references to the declared names.
4. Turn each gateway plus its outgoing edges into a gateway block with `branch`
   entries, moving the target steps inside.
5. Give each boundary event a name (`as …`) and a body.
6. Run `sequent check file.sq`; every remaining difference is reported with a
   caret and a hint.
7. Run `sequent fmt -w file.sq`.
