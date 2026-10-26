# Workstream: Tasks as the only stateful objects

## Vision

Tasks become the only stateful objects in ecl. Modules are pure code: they
define words and nothing else. A task owns a stack, a mailbox, and a lifetime;
other tasks reach it through an address and talk to it with `send` and
`call`. The module stack, its transactional `within` application, and the
anonymous module value are deleted rather than kept beside the new model. The
`rng` module, the only consumer of module state, is replaced by a pure `rand`
and an ECL `agent` module that runs any state as a task. No compatibility
layer and no expand-contract staging: each deletion lands whole.

## Current State

Verified against the checkout at `b3bb8cd` on 2026-10-25 and re-checked at
`dd97d88` (the `defm-prelude` merge) before Milestone 1 was planned.

**Module state.** `src/modules.zig` `ModuleSlot` (line ~1097) owns a FIFO
`Arbiter`, the durable `state` stack, `lease_refs`, a live/closing/retired
phase, and a recycling chain. `src/machine.zig` carries `beginWithin`
(line ~6480), the Unit's single turn authority (`~2563`), and the
`StateAcquireDriver` and publication drivers (`~9348`–`9600`) that copy the
durable stack into a draft and publish it back. `within` and `without` are
primitives in `src/module_prims.zig`. The only ECL user of `within` in the
tree is `src/stdlib/rng.ecl`; `fs.zig` and `table.ecl` mention the word in
prose only. Two open issues live entirely inside this machinery: #24 (draft
and publication copies) and #105 (recycled slot assertion).

**Anonymous modules.** `@module`, `register`, and `invoke` are primitives in
`src/module_prims.zig`; `@defm` is implemented as `@module` then `register`.
The `'module` value kind exists in `src/value.zig` and is rejected by JSON,
native views, and port messages. No shipped ECL source or app uses any of the
three words. Twelve Zig test files and four acceptance scripts under
`test/acceptance/modules/` and `test/acceptance/` do.

**Tasks.** `@spawn` and `@give` are the constructor primitives in
`src/task_prims.zig`; since `dd97d88`, `@each` is a prelude definition over
`@spawn` and `@defm` is a prelude definition as `@module` then `register`; the `task` module exposes `await`, `await-any`,
`await-for`, `cancel`, `cancel-self`, and `pending`. A `TaskCell`
(`src/scheduler.zig` ~1377) has a `TaskScope`, parent membership, waiter
lists, and a `WaitSet`; it has no message queue. Task scopes are created in
exactly two places: the session root (`core.root_tasks`, `src/session.zig`
~630, shared by every root unit and closed only on `exit`) and each spawned
task (`src/scheduler.zig` ~1985). `@attempt`, combinators, `load`, and
`@defm` construction bodies open no scope. Measured consequences:
`[] ([] (2000 clock.sleep) @spawn) @attempt` returns in 0.2s with a live
task; a failing `@attempt` cancels nothing; REPL spawns survive across lines
and across a failing line; a task spawned in a `@defm` body survives
construction and is owned by the session root. `SPEC.md` says the opposite
in two places ("`@attempt` is observationally equivalent to `@spawn
task.await`", "a dying unit also cancels its unawaited tasks") and the
formal `concurrency.pant` records the spawning unit as the owner. The
runtime's behavior is the one this workstream adopts.

**Randomness.** `rand` is a Zig builtin module (`src/stdlib/rand.zig`: `int`,
`ints`, `float`, `entropy`); `rng` is ECL source holding `[key counter]` on
its durable stack, with `deal` and `shuffle` written in ECL. The stdlib
manifest (`src/stdlib.zig` ~116–120) allows one entry per module name. `rng`
is used by `test/stdlib-tests/random.ecl`, one line of `test/e2e.zig`, and
two lines of `apps/pkg/test/contracts/version.ecl`.

**Spec pipeline.** `design/SPEC.md` is assembled by `zig build spec` from
`design/SPEC.src.md` and six Pantagruel models in `design/formal/`
(`modules.pant` 782 lines, `concurrency.pant` 293 lines), rendered with the
installed `pant` binary. `zig build check-spec` fails when the rendering is
stale; `zig build check-formal` checks the bounded models with z3.

## Key Challenges

- **Acyclicity under message passing.** The runtime uses precise reference
  counting with no cycle collector. A task handle reaches its cell and
  therefore its cached result; once tasks can exchange values, two tasks
  holding each other's handles and leaving them on their final stacks form an
  unreclaimable cycle. The design splits handle from address and forbids
  handles in messages. The check on send must be bounded and must skip flat
  specialized lists in O(1).
- **Mailbox lifetime without a new owned resource.** The mailbox must be an
  object the task owns, closed by the task's terminal transition, that never
  points back at the cell. Queue cycles through a queued message carrying the
  receiver's own address must be broken by that close, as port cleanup already
  does for exchanges.
- **Call/reply through the existing wait arbitration.** A parked caller
  contends with cancellation, deadline, server termination, and a dropped
  reply capability. Exactly one outcome owns delivery. Deferred destruction
  means a dropped reply fails the caller late, not at the drop.
- **Deleting a formal model's spine.** `modules.pant` is mostly the durable,
  draft, pending-output, and ambient stacks and the `WithinCommit` context.
  The rewrite must leave registration, generations, visibility, and call
  pins intact and provable.
- **Retention soaks.** `test-precommit` gates per-reload memory. Removing
  slot state changes `sizeof` of registry structures; the soaks must still
  pass without the tolerance being widened.
- **Spec and binary must agree at every pause.** Each milestone updates the
  spec slice it changes, never a slice it will implement later.

## Established Precedents

- **documentation — Erlang/OTP `gen_server` call and reply** —
  https://www.erlang.org/doc/apps/stdlib/gen_server.html
  The request/response shape: a synchronous `call` that parks the caller, a
  server loop that receives in arrival order, and `reply` addressed to the
  caller. ecl replaces OTP's monitor-plus-selective-receive with a
  runtime-minted one-shot reply capability carried in the envelope, so the
  server never needs selective receive and the caller never needs a mailbox.
  Applies to the mailbox milestone and shapes the `agent` loop.

- **documentation — Clojure agents** — https://clojure.org/reference/agents
  Single-state holder that applies functions sent to it, serially, with
  state preserved on error. ecl's `agent` module is this with a stack as the
  state and quotations as the functions; `agent.call` adds the synchronous
  result that Clojure's `send` lacks.

- **blog-post — Notes on structured concurrency (Smith)** —
  https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/
  Already the design's lifetime model. This workstream applies it precisely:
  the owner of a spawn is the nearest enclosing scope, scopes are task scopes
  and the session root, and a stack transaction (`@attempt`) is not a scope.

- **paper — Perceus: garbage-free reference counting with reuse** —
  https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/
  Already cited in `INTERPRETER.md` for ownership passing. The handle/address
  split and the no-handles-in-messages rule exist to keep the ownership graph
  acyclic so precise counting stays sufficient.

## Milestones

### Milestone 1: task-scope-ownership

**Status**: executed (2026-10-25) on branch `zax--tasks-only-objects`, three
commits after the workstream commit. Landed as planned with two drifts worth
knowing: the refusal guards only `@spawn` and `@give`, because `@each` had
already become a prelude definition over `@spawn` (its refusal names `@each` in
the trace); and one pre-existing test, "bindings: a task spawned by a module body
reads the image live", was deleted with the behavior it pinned. The formal
model's `task-owner` is a total rule read only under `~root-owned?`; a guarded
rule left nine preservation warnings under the bound-2 check. `zig build
precommit` passed on each commit; the gameplan file is local and gitignored.

**Definition of Done**:
- `design/SPEC.src.md` Units and Concurrency sections state the rule the
  runtime implements: a spawned task is owned by the nearest enclosing task
  scope, which is a spawned task or the session root; `@attempt`,
  combinators, `load`, and construction bodies open no scope. The
  `@attempt` ≡ `@spawn task.await` claim is narrowed to stack and result
  semantics. "A dying unit also cancels its unawaited tasks" is rewritten to
  the scope rule. The Construction bullet "child tasks are cancelled by the
  ordinary failing-unit rule" is removed.
- `design/formal/concurrency.pant` records the owning scope rather than the
  spawning unit; `zig build check-formal` passes.
- `design/INTERPRETER.md` "Tasks form a lifetime tree" distinguishes units
  (stack transactions) from scopes (lifetime owners).
- `@spawn` and `@give` are `'domain` while a module-construction boundary is
  open anywhere in the unit's frame stack: the direct `@defm` body, a helper
  word the body calls, or an `@attempt` nested in the body. `@each` is refused
  through the `@spawn` the prelude defines it over, with `@each` in the error
  trace. The message names the constructor and states the rule. Modules are
  now pure code in fact as well as intent.
- A behavioral test pins each measured fact in Current State: live task out
  of `@attempt`, no cancellation on `@attempt` failure, REPL-style survival
  across root units, and the new `'domain`.
- `zig build spec`, `check-spec`, and `precommit` pass.

**Why this is a safe pause point**: The spec now describes the shipped
binary. The one behavioral change forbids something nothing in the tree does.

**Unlocks**: Every later spec slice builds on an ownership statement that is
true. The mailbox model's closure rule is stated against scopes, not units.

---

### Milestone 2: remove-anonymous-modules

**Status**: executed (2026-10-25) on branch `zax--tasks-only-objects`, three
commits. Landed as planned with these drifts: the formal `Register` action
holds a `Construction` context that only it lists, because a context grants
write authority to every action naming it and `Add alias`/`Remove` otherwise
failed to preserve image existence; `printing.pant` also named `module-type`
and was fixed alongside `values.pant`; the registration retention test runs its
calls in child units, since a unit pins every generation it dispatches through
and each definition is now its own image; and `@defm`'s own isolation
diagnostic now names `@defm`. `zig build precommit` passed on each commit.

**Definition of Done**:
- `@module`, `register`, and `invoke` are gone from `src/module_prims.zig`
  and from `STDLIB.md`. `@defm` constructs and registers directly, validates
  its name (including the reserved `core` and standard-library names) before
  running the body, and fails only when the body fails or publication is
  refused.
- `@defm` is a primitive again (reversing #147's prelude definition over
  `@module` and `register`): a non-symbol name is `'type`; an invalid path,
  `core`, or a standard-library name is `'domain`; none of these runs the body.
- The `'module` value kind is gone from `src/value.zig`, the heap, `print`,
  `match?`, `type` (which now lists nine kinds), the reader's `<module>`
  marker, and the JSON, native-view, and port-message rejection paths.
  `design/formal/values.pant` drops `module-type` in the same patch, since the
  source audit compares the Zig tag universe with it.
  `src/tests/module_value_test.zig` becomes `module_registration_test.zig`
  with its anonymous-value tests deleted and the rest rewritten against
  `@defm`; `test/acceptance/modules/register-style.ecl` and `image-only.ecl`
  are deleted.
- `SPEC.src.md` Modules prose drops "construction and publication are
  separate operations", the two-phase failure story, "nameable at a
  distance", and "parameterized with anonymous module handles";
  `modules.pant` drops image availability without registration.
  `INTERPRETER.md` "Images, registrations, and state have different
  lifetimes" loses the anonymous-image case while keeping generations.
- `zig build spec`, `check-spec`, `check-formal`, and `precommit` pass.

**Why this is a safe pause point**: Purely subtractive. Every registered
module in the tree is built with `@defm` already. The image type remains
internal for generations.

**Unlocks**: Milestone 5 deletes module state against a registry whose only
public operations are `@defm`, `unmodule`, `alias`, `import`, and `qualify`.

---

### Milestone 3: task-mailboxes

**Status**: executed (2026-10-25) on branch `zax--tasks-only-objects`, three
commits. Cut to the minimal layer the runtime alone can provide: five words,
one kind, one object. Request/reply is composed in ECL; the runtime one-shot
reply mailbox is recorded in issue #150. Landed with these drifts: `task.send`
takes `( value address -- )` and `task.receive` returns the sent value with no
envelope (see Decisions Made); mailbox waits have their own `ParkRequest`
family in which a deadline is an ordinary wake and the driver re-polls the
mailbox and the clock, rather than a resume variant that names the timeout;
the gate also repaired two inherited test programs (the M1 ownership pins
awaited a handle `task.cancel` had consumed, and the M2 module-registration
OOM probe let a failing body propagate), because `precommit` runs neither
`concurrency_test` nor `test-oom`. Gates: `precommit`, `test-workers`,
`test-oom`, and one Docker TSan run (arm64) all passed. Operator actions done
2026-10-25: the TSan loop ran 20 iterations in one arm64 container with zero
reports, and issue #13 was closed with a note that mailboxes were chosen.

**Definition of Done**:
- Every task owns a mailbox: a separately counted object reachable from the
  cell, never pointing back at it, closed by the task's terminal transition.
  Closing discards queued messages, which breaks any queue cycle.
- A new `'address` value kind: opaque, prints as `<address:n>`, `match?` by
  mailbox identity, unreadable, rejected by JSON, native views, and port
  messages exactly as tasks are. `task.address ( task -- address )` and
  `task.self ( -- address )`; `task.self` is `'domain` outside a task.
- `task.send ( value address -- )` parks under pressure at capacity 16, is
  per-sender FIFO, and is `'io` with `{'reason 'closed}` on a closed
  mailbox. Any value may be sent except one containing a task handle, which
  is `'type`; the check runs under the work budget and skips flat
  specialized lists without traversal.
- `task.receive ( -- value )` parks in the receiving task and returns the
  sent value as it was sent; `'domain` outside a task.
  `task.receive-for ( ms -- result )`
  returns `{'ok value}` or `{'err {'kind 'timeout}}`, with `'overflow` for
  an unreachable deadline, as `await-for` does.
- Mailbox waits park through the external-readiness arbitration ports use,
  with a resume variant that returns a deadline as a value; receiver and
  sender cancellation go through the existing `WaitSet` arbitration.
- No request/reply primitive. `call` is an ECL composition: a helper task
  whose address travels as `'from` and whose result is the reply, bounded only
  by `task.await-for`. The runtime one-shot reply mailbox, with `'dropped`
  detection, self-call refusal, and abandonment, is issue #150.
- `SPEC.src.md` Concurrency gains a mailbox section and `concurrency.pant`
  gains the `Mailboxes` context with `Send`, `Receive`, and closure on the
  terminal actions, under the invariant that a queued message's target is
  active. `STDLIB.md` documents the five words. `INTERPRETER.md` documents
  the mailbox object, the readiness reuse, and the handle check on send.
- Proofs: behavioral tests under one and eight workers, three
  `src/tests/interleaving_test.zig` programs, a `test-oom` snippet over send
  and receive, and the Docker TSan run.

**Why this is a safe pause point**: Additive. No existing word changes
meaning. Issue #13 (unit-scoped channels) is closed by this milestone with a
note that the design chose mailboxes.

**Unlocks**: Any stateful service in ECL. The `agent` module is one; its
`agent.call` is the composed helper-task form until #150 lands.

**Operator Actions Before Next Milestone**:
- Run the TSan Docker procedure from `agent-guides/testing.md` over the new
  concurrency tests in a loop (at least 20 iterations) and confirm zero
  reports. The gameplan's gate runs it once; the loop is the operator's
  check that the arbitration is not timing-dependent.

---

### Milestone 4: agent-module

**Status**: planned (2026-10-25). Gameplan: `gameplans/agent-module.yaml`
(local; gitignored), two patches: the module with its first-class tests, and
the STDLIB section. Pure ECL over the Milestone 3 words; no runtime change.

**Definition of Done**:
- `src/stdlib/agent.ecl`, registered in `src/stdlib.zig`, exports:
  `agent.serve ( ... -- )`, the loop a task runs over its own stack as state
  (the stack at entry is captured once as the state list);
  `agent.start ( state -- address )`, which spawns `serve` with `state` as
  the one value on the entry stack and returns the address;
  `agent.call ( quotation address -- result )`, which applies the quotation
  to the server's stack as a unit, pops the top of the result stack as the
  reply, keeps the rest as the new state, and re-raises the quotation's error
  in the caller (an empty result stack is `'domain`); and
  `agent.send ( quotation address -- )`, which applies without a reply and
  keeps the whole result stack. Call quotations are therefore
  `( state... -- state... result )`, mirroring `rand`. `agent.call` is
  composed from the Milestone 3 words: a helper task receives the reply and
  `task.await` returns it, so an unbounded call to a dead server hangs until
  #150 lands; `agent.call-for ( quotation address milliseconds -- result )`
  bounds it with `task.await-for` and raises `'timeout` in the caller after
  cancelling its helper; the quotation still runs on the server later.
- Each application runs as a unit, so a failing quotation restores the
  server's stack: state is unchanged on error without any copying by the
  agent itself. A failing `send` drops its error. The server survives
  application errors, including a reply to a helper that has already gone,
  and dies only by cancellation.
- `test/stdlib-tests/agent.ecl` covers roundtrip, state advance, error
  preservation, send without reply, and cancellation through the handle
  obtained by spawning `agent.serve` directly.
- `STDLIB.md` documents the module with the `rng` replacement idiom:
  `[0 0] agent.start 'rng set` then `(5 rand.int) rng agent.call`.

**Why this is a safe pause point**: A new library module over Milestone 3's
primitives. `rng` still exists, so nothing is lost yet.

**Unlocks**: Deleting `rng` with its replacement already shipped.

---

### Milestone 5: remove-module-stacks

**Definition of Done**:
- `within` and `without` are gone from `src/module_prims.zig`. `ModuleSlot`
  loses `arbiter`, `state`, and every lease and recycling path that existed
  for them; the Unit loses its turn authority; `beginWithin`,
  `StateAcquireDriver`, and the publication drivers are deleted from
  `src/machine.zig`. Issues #24 and #105 are closed by removal.
- `@defm` with a nonempty final body stack is `'domain`. Registration is
  name → current generation; replacement publishes a new generation and
  keeps nothing else. `unmodule` closes admission and retires.
- `src/stdlib/rng.ecl` is deleted and removed from the manifest.
  `src/stdlib/rand.zig` gains `shuffle ( state values -- state values )`
  and `deal ( state count pool -- state results )` as kernels with the
  documented `'domain` conditions. `test/stdlib-tests/random.ecl`,
  `test/e2e.zig`, and `apps/pkg/test/contracts/version.ecl` use `rand`
  or `agent`.
- `src/tests/stateful_module_test.zig`, `test/acceptance/stateful-module-
  reload.ecl`, and `stateful-module-instances.ecl` are deleted. Test Sessions
  no longer document durable registration state between `@test` runs.
- `SPEC.src.md` Modules keeps construction, registration, generations,
  visibility, imports, qualified resolution, and tests; the `within`,
  `without`, durable-state, reload-keeps-state, and transaction bullets are
  gone. `modules.pant` drops the `Transactions` and `WithinCommit` contexts
  and the durable, draft, pending-output, and ambient stacks.
  `INTERPRETER.md` drops "Stateful module application is an explicit
  transaction" and the state clauses of the registration sections.
  `STDLIB.md` drops `within`, `without`, and `## rng` and adds the two
  `rand` words. `SPEC.md` Randomness drops the `rng` sentence.
- The two retention soaks in `test-precommit` pass unchanged.
  `zig build spec`, `check-spec`, `check-formal`, and `precommit` pass.

**Why this is a safe pause point**: It is the end state. Every stateful
thing in the system is a task.

**Unlocks**: Supervision as an ECL pattern over `agent` and
`task.await-any`, to be designed after one real customer exists.

**Established Precedents** (milestone-scoped):
- **algorithm — Fisher–Yates shuffle (Durstenfeld variant)** —
  https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle — `rand.shuffle`
  and `rand.deal` as kernels; `deal` is the partial shuffle `rng.ecl`
  already implements in ECL, addressed by counter so the result is a pure
  function of the state.

## Dependency Graph
- Milestone 1 -> []
- Milestone 2 -> []
- Milestone 3 -> [1]
- Milestone 4 -> [3]
- Milestone 5 -> [2, 4]

Milestones 1 and 2 may run in parallel. Milestone 5 waits for 4 so that the
replacement for `rng` ships before `rng` is deleted.

## Open Questions

- Whether the `agent` server should accept a `{'kind 'stop}` protocol message
  or rely on cancellation through the handle. Default is cancellation only.

## Decisions Made

- **The mailbox layer is minimal.** The runtime provides only what it alone
  can: the `'address` kind, one mailbox per task closed at the terminal
  transition, `task.address`, `task.self`, `task.send`, `task.receive`, and
  `task.receive-for`. Request/reply is composed in ECL (a helper task as the
  reply mailbox); the runtime one-shot reply mailbox is issue #150, to land as
  a measured optimization. Decided while planning Milestone 3.
- **Mailbox waits ride the external-readiness arbitration.** A mailbox is a
  readiness cell like the archive, directory, and port cells; a
  `ParkRequest.mailbox` variant shares that registration and resumes the
  driver on a deadline so `receive-for` returns the timeout as a value.
- **The root has no mailbox.** `task.receive`, `task.receive-for`, and
  `task.self` are `'domain` at the root; `task.send` works anywhere. A root
  mailbox is a separate, additive feature if ever wanted.
- **Mailbox words are `task.`-qualified only.** No bare `receive`.
- **`agent.call` pops the top of the result stack as the reply.** The
  alternative, keeping the whole result stack, breaks `(100 rand.int)` on the
  next call because the drawn value would sit above the generator state. So
  call quotations are `( state... -- state... result )` and an empty result
  stack is `'domain`; `agent.send` keeps everything.
- **`agent.call-for` raises `'timeout`.** Chosen over returning a
  `task.await-for`-style envelope so the call family has one result shape; a
  bounded call is `agent.call` with a deadline.
- **`task.receive` returns the sent value, not an envelope.** With the
  one-shot reply moved to #150 the runtime fills no envelope field, so a
  `{'value v}` wrapper would be ceremony on every receive. A composed caller
  that needs a reply address puts it in the value it sends. `task.send` takes
  the value below the address (`( value address -- )`), matching
  `(rand.int) rng task.send` and the `agent` words.
- **`@defm` is the single module constructor and a primitive.** Name
  validation precedes the body; only a registry change during construction
  (an alias now occupying the name) can refuse publication after the body's
  effects. The formal `Register` action constructs and publishes in one step,
  because no program can observe an image between the two. The
  `within`-active registry-mutation refusal stays at publication until
  Milestone 5 deletes `within`. Decided while planning Milestone 2.

- **Mailboxes, not CSP.** Tasks are the objects; a channel would be a second
  object kind with its own ownership. Cost accepted: no unified `select`,
  and competing consumers need a dispatcher task.
- **Handle versus address.** Forced by acyclic reference counting. Handle is
  lifetime and observation; address is communication. Handles never cross
  mailboxes.
- **No service constructor and no service in module bodies.** Ownership is
  already "nearest enclosing scope, else session root"; user code starts
  services and names them with `set`. `@spawn` in a construction body is
  `'domain`.
- **The construction refusal reaches any depth.** Not just the direct body
  (as `test` is restricted) but helper words the body calls and `@attempt`
  nested in the body, because the purpose is purity of construction, and a
  direct-body check can be laundered through a defined word. `@each` is
  refused too; it is a prelude definition over `@spawn`, so one guard covers
  it. Decided while planning Milestone 1.
- **The formal concurrency model keeps `Task` and `Unit` as its only domains.**
  The owner is a `root-owned?` flag plus a task-valued `task-owner` rule, not a
  `Scope` domain, because `build.zig` checks the model at `--bound 2`, where a
  per-task scope domain cannot hold two created tasks. Decided while planning
  Milestone 1.
- **No app manifest, no supervision yet.** Lazy construction on first
  qualified use already orders dependencies. Supervision is a later design
  with the `http.server` acceptor pool as its first customer.
- **No compatibility layer.** Deletions land whole; no deprecation period,
  no expand-contract.
- **`shuffle` and `deal` move to `rand` as Zig kernels**, not a second ECL
  module, because the manifest has one entry per name and `rand` is Zig.
- **Spec slices travel with their code.** No milestone describes behavior a
  later milestone implements.

## Definition of Done (Acceptance Suite)

All `cmd` assertions run the built binary as
`zig-out/bin/ecl -e "<source>" < /dev/null` under `timeout`, and compare the
echoed final stack or the error dictionary on stderr.

- **DoD-1 — unit constructors are refused during construction, at any depth**
  - **Assert**: `@spawn`, `@give`, and `@each` fail with `'domain` while a
    module construction is open, including inside a helper word the body
    defines and inside an `@attempt` nested in the body, and nothing registers.
  - **Verify by** `cmd`: `[] ([] (1) @spawn pop (1) 'x def) 'm @defm m.x`;
    `[] ([] [] (1) @give pop) 'm @defm`; `[] ([1] [] (1) @each pop) 'm @defm`;
    `[] (([] (1) @spawn) 'start def start) 'm @defm`;
    `[] ([] ([] (1) @spawn) @attempt pop) 'm @defm`; then `m.x` alone.
  - **Expected**: each construction exits nonzero with `'kind 'domain` and a
    message naming `@spawn` or `@give` (the `@each` case names `@each` in its
    trace); `m.x` alone is `'undefined-word`.
  - **Traces to**: Milestone 1 — `refuseDuringConstruction` in
    `src/task_prims.zig` over `Unit.inModuleConstruction` in `src/machine.zig`.

- **DoD-2 — a task survives `@attempt`**
  - **Assert**: a task spawned inside `@attempt` is alive after `@attempt`
    returns and completes normally.
  - **Verify by** `cmd`: `[] ([] (300 clock.sleep 7) @spawn) @attempt 'ok at first task.await`.
  - **Expected**: `{'ok [7]}`, exit 0.
  - **Traces to**: Milestone 1 — `design/SPEC.md` scope rule; pinned by the
    new concurrency behavioral test.

- **DoD-3 — a failing `@attempt` cancels nothing**
  - **Assert**: a task spawned inside a failing `@attempt` is still pending
    afterwards.
  - **Verify by** `cmd`: `[] ([] (300 clock.sleep) @spawn pop 'domain error.new fail) @attempt pop task.pending len`.
  - **Expected**: `1`.
  - **Traces to**: Milestone 1 — same.

- **DoD-3b — a failing root unit cancels nothing**
  - **Assert**: a task spawned by a root unit that then fails is still pending
    in the next root unit.
  - **Verify by** `cmd`: in the REPL, `[] (300 clock.sleep) @spawn pop 'domain
    error.new fail` on one line, then `task.pending len` on the next.
  - **Expected**: `1`.
  - **Traces to**: Milestone 1 — `design/SPEC.md` scope rule; pinned by
    `src/tests/concurrency_test.zig`.

- **DoD-4 — anonymous constructors are gone**
  - **Assert**: `@module`, `register`, and `invoke` are undefined words.
  - **Verify by** `cmd`: `[] (1) @module`, `'register which`, and
    `'invoke which` as three `-e` runs.
  - **Expected**: each exits nonzero with `'kind 'undefined-word` naming the
    word.
  - **Traces to**: Milestone 2 — `src/module_prims.zig`.

- **DoD-5 — `@defm` validates its name before running the body**
  - **Assert**: a reserved name fails before the body's own error can occur.
  - **Verify by** `cmd`: `[] ("body ran" 'user error.new fail) 'core @defm`;
    `[] (1 'x set) 'bad..name @defm`; `[] (1 'x set) 'dict @defm`;
    `'wrong [] (1 'x set) @defm`.
  - **Expected**: the first three are `'kind 'domain` (the first never
    `'user`, the third naming the standard library); the last is `'kind
    'type` with `'word '@defm`.
  - **Traces to**: Milestone 2 — `defmWord` in `src/module_prims.zig`.

- **DoD-6 — `type` has no module kind**
  - **Assert**: no expression produces a value whose `type` is `'module`.
  - **Verify by** `cmd`: `[] (1 'x set) 'm @defm m.x type`; `timeout 600
    zig build source-audit < /dev/null`.
  - **Expected**: `'int`; the audit exits 0 with `module-type` absent from
    `design/formal/values.pant`.
  - **Traces to**: Milestone 2 — `src/value.zig`, `design/formal/values.pant`.

- **DoD-6b — nested definitions and reloads publish through the registry**
  - **Assert**: a module body may define another module, and re-defining a
    name publishes new code.
  - **Verify by** `cmd`: `[] ([] ((2) 'x def) 'inner @defm (inner.x) 'get def)
    'outer @defm outer.get`; `[] ((1) 'x def) 'm @defm [] ((2) 'x def) 'm @defm
    m.x`.
  - **Expected**: `2` for both.
  - **Traces to**: Milestone 2 — `ModuleCompletionDriver` in
    `src/machine.zig`.

- **DoD-7 — composed request and reply round trip**
  - **Assert**: `agent.call`'s composition (a helper task as the reply
    mailbox) returns the server's answer.
  - **Verify by** `cmd`: `(|a v| [] (task.receive) @spawn dup task.address {} 'value v put 'from rolldown put a task.send task.await 'ok at first) 'ask def [] (task.receive dup 'from at swap 'value at 1 + swap task.send) @spawn task.address 41 ask`.
  - **Expected**: `42`.
  - **Traces to**: Milestone 3 — `task.send`/`task.receive` in
    `src/task_prims.zig`; Milestone 4 ships the same composition as
    `agent.call`.

- **DoD-8 — handles do not cross mailboxes**
  - **Assert**: sending a value containing a task handle is `'type` and
    delivers nothing.
  - **Verify by** `cmd`: `[] (task.receive) @spawn dup task.address swap wrap task.send`.
  - **Expected**: `'kind 'type`, exit nonzero, and the process exits
    promptly after the root scope cancels the receiver.
  - **Traces to**: Milestone 3 — send validation in `src/task_prims.zig`.

- **DoD-9 — a flat list is sendable without traversal cost**
  - **Assert**: sending a 1,000,000-element int list completes within one
    scheduler turn of overhead.
  - **Verify by** `cmd`: ReleaseSafe build; time
    `[] (task.receive pop) @spawn task.address 1000000 range task.send`
    against `[] (task.receive pop) @spawn task.address [1] task.send`.
  - **Expected**: wall-clock difference below 5 ms across five runs.
  - **Traces to**: Milestone 3 — flat-list fast path in the handle check.

- **DoD-10 — sending to a terminated task fails closed**
  - **Assert**: `task.send` to a terminal task is `'io` with reason `'closed`.
  - **Verify by** `cmd`: `[] (1) @spawn dup task.await pop task.address 1 swap task.send`.
  - **Expected**: `'kind 'io` with `'data {'reason 'closed}`.
  - **Traces to**: Milestone 3 — mailbox closure on terminal transition.

- **DoD-11, DoD-12, DoD-13 — moved to issue #150.** A caller failing when its
  server dies (`'dropped`), a dropped reply address failing the caller, and
  self-call refusal are properties of the runtime one-shot reply mailbox,
  which this workstream does not build. Until then an unbounded composed call
  to a dead server hangs; `task.await-for` bounds it.

- **DoD-14 — receive deadline**
  - **Assert**: `task.receive-for` on an empty mailbox returns the timeout
    result after the deadline, and a delivered message as `{'ok value}`.
  - **Verify by** `cmd`: `[] (50 task.receive-for) @spawn task.await 'ok at first 'err at 'kind at`; `[] (1000 task.receive-for) @spawn dup task.address 7 swap task.send task.await`.
  - **Expected**: `'timeout`; `{'ok [{'ok 7}]}`.
  - **Traces to**: Milestone 3 — `task.receive-for`.

- **DoD-15 — per-sender order**
  - **Assert**: messages from one sender arrive in send order.
  - **Verify by** `cmd`: `[] (3 (task.receive) times 3 pack) @spawn dup task.address 1 over task.send 2 over task.send 3 swap task.send task.await`.
  - **Expected**: `{'ok [[1 2 3]]}`.
  - **Traces to**: Milestone 3 — mailbox queue.

- **DoD-16 — `receive` outside a task is refused**
  - **Assert**: `task.receive` and `task.self` at the root are `'domain`.
  - **Verify by** `cmd`: `task.receive` and `task.self` as separate `-e`
    runs.
  - **Expected**: `'kind 'domain` for both.
  - **Traces to**: Milestone 3 — `src/task_prims.zig`.

- **DoD-17 — agent round trip advances state**
  - **Assert**: `agent.call` applies the quotation to the agent's stack and
    the state advances between calls.
  - **Verify by** `cmd`: `[0 0] agent.start 'g set (100 rand.int) g agent.call (100 rand.int) g agent.call pair` and, separately, the explicit-state computation `[0 0] 100 rand.int swap 100 rand.int nip pair`.
  - **Expected**: both runs echo the same two-element list, proving the
    agent's state advanced exactly as explicit threading would.
  - **Traces to**: Milestone 4 — `src/stdlib/agent.ecl`.

- **DoD-18 — agent error leaves state unchanged**
  - **Assert**: a failing quotation re-raises in the caller and the agent's
    stack is as before.
  - **Verify by** `cmd`: `[7 0] agent.start 'g set [] ((1 0 div) g agent.call) @attempt 'err at 'kind at (dup) g agent.call pair`.
  - **Expected**: `('domain [7 0])`.
  - **Traces to**: Milestone 4 — `agent.serve` applying under a unit.

- **DoD-19 — `within` and `rng` are gone**
  - **Assert**: `within`, `without`, and every `rng.*` name are undefined.
  - **Verify by** `cmd`: `(1) within`; `5 rng.int`.
  - **Expected**: `'kind 'undefined-word` for both; the second names module
    `rng`.
  - **Traces to**: Milestone 5 — `src/module_prims.zig`, `src/stdlib.zig`.

- **DoD-20 — `@defm` rejects a leftover stack**
  - **Assert**: a construction body that leaves values on its stack is
    `'domain` and registers nothing.
  - **Verify by** `cmd`: `[] (1 (2) 'x def) 'm @defm m.x`.
  - **Expected**: `'kind 'domain` from `@defm`; `m.x` alone in a second run
    is `'undefined-word`.
  - **Traces to**: Milestone 5 — `@defm` completion check.

- **DoD-21 — replacement keeps no state**
  - **Assert**: re-registering a module publishes new code and nothing else
    carries over.
  - **Verify by** `cmd`: `[] ((1) 'x def) 'm @defm [] ((2) 'x def) 'm @defm m.x`.
  - **Expected**: `2`.
  - **Traces to**: Milestone 5 — registration as name → generation.

- **DoD-22 — `rand.shuffle` is a pure function of state**
  - **Assert**: two shuffles from the same state produce the same
    permutation and the same advanced state; the result is a permutation.
  - **Verify by** `cmd`: `[42 0] [10 20 30 40] rand.shuffle [42 0] [10 20 30 40] rand.shuffle 4 pack` and `[42 0] [10 20 30 40] rand.shuffle nip dup grade at`.
  - **Expected**: in the packed list, element 0 equals element 2 and element
    1 equals element 3; the sorted shuffle is `[10 20 30 40]`.
  - **Traces to**: Milestone 5 — `src/stdlib/rand.zig`.

- **DoD-23 — `rand.deal` draws distinct values and checks its domain**
  - **Assert**: `deal` returns `count` distinct ints below `pool`, and
    `count > pool` is `'domain`.
  - **Verify by** `cmd`: `[42 0] 4 8 rand.deal nip distinct len` and `[42 0] 9 8 rand.deal`.
  - **Expected**: `4`; then `'kind 'domain`.
  - **Traces to**: Milestone 5 — `src/stdlib/rand.zig`.

- **DoD-24 — spec and models agree with the tree**
  - **Assert**: the checked-in spec is the rendering of its sources and the
    bounded models check.
  - **Verify by** `cmd`: `zig build check-spec` and `zig build check-formal`
    with stdin closed under `timeout`.
  - **Expected**: exit 0 for both.
  - **Traces to**: Milestone 5 — `design/SPEC.src.md`,
    `design/formal/modules.pant`, `design/formal/concurrency.pant` (each
    earlier milestone also leaves this green).

- **DoD-25 — nothing in the shipped tree names the deleted vocabulary**
  - **Assert**: no ECL source, Zig source, or design document outside
    `design/workstreams/` and git history mentions `within`, `without`,
    `@module`, `invoke`, or `rng.` as a word.
  - **Verify by** `cmd`: `grep -rnw "within\|without\|@module\|invoke" src design/*.md apps test --include=*.ecl --include=*.zig --include=*.md` and `grep -rn "rng\." src design/*.md apps test`.
  - **Expected**: no matches other than prose uses of the English words
    "within" and "without".
  - **Traces to**: Milestones 2 and 5.

- **DoD-26 — the local gate passes**
  - **Assert**: `zig build precommit`, including both retention soaks in
    `test-precommit`, passes on the final tree.
  - **Verify by** `cmd`: `timeout 600 zig build precommit < /dev/null`.
  - **Expected**: exit 0.
  - **Traces to**: Milestone 5.

- **DoD-27 — a bounded agent call times out and the agent survives**
  - **Assert**: `agent.call-for` past its deadline raises `'timeout` in the
    caller, and the agent still answers afterwards.
  - **Verify by** `cmd`: `[7 0] agent.start 'g set [] ((100 clock.sleep 1) g 20 agent.call-for) @attempt 'err at 'kind at (dup) g agent.call pair`.
  - **Expected**: `('timeout [7 0])` or `('timeout [7 0 1])` depending on whether the late quotation has run.
  - **Traces to**: Milestone 4 — `agent.call-for`.

- **DoD-28 — a directly spawned server is cancellable through its handle**
  - **Assert**: `agent.serve` spawned with `@spawn` serves calls through its
    address and ends with `'cancelled` when its handle is cancelled.
  - **Verify by** `cmd`: `[[7 0]] (agent.serve) @spawn dup task.address 'g set (dup) g agent.call swap dup task.cancel task.await 'err at 'kind at`.
  - **Expected**: `[7 0] 'cancelled`.
  - **Traces to**: Milestone 4 — `agent.serve`.
