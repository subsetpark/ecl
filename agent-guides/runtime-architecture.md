# Runtime Architecture

Read this guide before changing ownership, lifetimes, capabilities, scheduling,
publication, reclamation, or architectural enforcement. The short rules in
[`AGENTS.md`](../AGENTS.md) and the boundaries in
[`engineering.md`](engineering.md) always apply as well.

## Structural invariants

- This application is still in its design phase. When a defect exposes a weak
  ownership, lifetime, publication, scheduling, or authority seam, revise the
  representation and architectural invariant rather than preserving the seam
  with a field reorder, extra assertion, naming convention, special-case drain,
  or source-audit exception.
- Prefer nominal IDs, opaque handles, validated factories, capability values,
  typestate transitions, and tagged unions over correlated raw fields,
  booleans, debug assertions, naming conventions, or comments.
- Make invalid ownership, publication metadata, environment phase,
  stack-window, and continuation-mode states unrepresentable where Zig permits
  it. Use `comptime` validation for static registries and exhaustive switches
  for state machines.
- Give consuming APIs an explicit ownership contract on both success and
  failure. Transfer ownership through moved/consumed capabilities or tagged
  results; never make a caller infer whether a failed append, publication, or
  transition retained or destroyed its input.
- Update `design/INTERPRETER.md` when introducing or revising a structural
  invariant. If implementation is executing an active gameplan, keep its proof
  claims aligned while it is in use; do not add or maintain the gameplan as a
  repository artifact. Acceptance must show that every producer and consumer
  uses the new seam and that invalid states are unavailable in all build modes.
- Raise a representation ceiling when a strong type boundary honestly needs
  the space. Never weaken or compress away the type boundary merely to satisfy
  a historical frame-size limit; update and explain the ceiling.

## Ownership, lifetime, and capabilities

- Define one lifetime protocol for provisional and published generations,
  Units, tasks, scopes, descendants, drivers, pins, leases, and cursors. Do not
  duplicate teardown ordering assumptions between owners or rely on a
  unique-refcount assertion to stand in for quiescence.
- Keep an embedded owner alive until every descendant has propagated its parent
  release. Encode `waiting-for-children`, scope teardown, environment teardown,
  pin release, and final destruction as one exhaustive typestate, releasing
  dependents before their lifetime guards.
- A pin, lease, cursor, handle, or callback-owned value that releases through a
  reclamation domain must not outlive that domain. Shutdown must first close
  new lifetime creation, then join/adopt outstanding owners, settle their
  retirement, and only then destroy the issuing domain.
- Separate observation, execution, and mutation into distinct nominal
  capabilities. Upgrading requires a distinct owner-issued authority and
  consumes the source capability. Observation APIs return metadata or pinned
  cursors, not raw homes, mutable scopes, ownership factories, or an implicit
  path to greater authority.
- Give Session-facing and registered-native callers only opaque semantic
  facades. Do not expose raw `Env`, `Registry`, Unit, module-home,
  reclamation-domain, wake-control, queue, or manual-advancement aliases when a
  narrower operation can express the contract. A lower-level API is valid only
  when its caller explicitly owns the corresponding lifetime and reclamation
  root.
- Private authority types may appear in signatures, but untrusted callers must
  be unable to construct or obtain their values or factories. Keep private
  runtime primitive bindings unreachable through public dictionaries,
  reflection, shadowing, and higher-order combinators; grant trusted builtins
  only the narrow operation they need.
- Each reclamation root mints or owns exactly one opaque host authority, and
  subordinate objects derive allocator and retirement-domain access from that
  owner. Bind mutation authority separately to its issuer. Use opaque/private
  backing state so neither authority can be forged, substituted, or retargeted
  after construction. Never accept a separately correlated allocator/domain/
  host tuple, and never rely on a debug assertion or audit alone to reject a
  mismatch in optimized builds.
- Scheduler-attached state may enqueue or advance bounded retirement only.
  Blocking destruction requires owner-derived host authority that
  worker-visible types cannot obtain; reaching the final reference never grants
  permission to traverse a user-sized graph synchronously.
- Make retirement settlement inseparable from public mutation authority. Every
  public mutation operation, blocking or resumable, settles or explicitly
  transfers its retirement work on every exit path, and opaque Session APIs
  must not expose lower-level mutable aliases that bypass that postcondition.
- Every cursor borrowing snapshot-owned storage owns the corresponding snapshot
  lease for its complete lifetime and, when that storage belongs to a
  generation, an independent generation pin. Releasing the originating lease
  must not invalidate an independent cursor.

## Bounded work and scheduling

- Route every user-sized traversal, cleanup, and terminal unwind through
  `WorkContext` cursors or bounded chunks. Use exact-size materialization for
  known results and fixed chunks plus one polled materialization pass for
  unknown results; do not introduce relocating or rehashing storage into
  cancellable paths.
- Treat reclamation and terminal cleanup as ordinary resumable scheduler work.
  A final reader, writer, reference, task, or generation may detach and enqueue
  work, but may not hide an unbounded traversal inside one nominal scheduler
  step.
- Cooperative and worker-pool executors use one arbitration policy for ready
  work, cancellation, wait delivery, teardown, and retirement. Bound
  consecutive service of every class so neither a continuously ready task nor
  a reclamation backlog can starve the other classes or make cancellation
  latency scale with a whole retired graph.
- Cold and idle Sessions must not strand retirement. Root completion and every
  public blocking turn must settle or transfer the backlog even before the
  worker pool starts and while a sole worker is busy.
- Treat task-tree registration, publication, and cancellation as one protocol.
  Publish stable task state before making a spawn reachable, register it
  atomically with its tree, prevent a cancelled ready task from dispatching,
  and keep cancellation allocation-free. Snapshot passes carry a mutation
  epoch and restart count/collection when the tree changes.
- Capture an absolute deadline before lazy timer startup and store deadline
  precedence in the wait-arbitration state. Completion, cancellation, timer
  insertion, and timer wake revalidate against that same deadline before
  committing a winner; already-expired or terminal waits must not start timer
  infrastructure unnecessarily.

## Publication and reclamation

- Represent task publication and other multi-phase handoffs as tagged states
  whose variants own exactly the metadata valid in that phase. Transitions
  consume one state and construct the next; do not coordinate publication with
  nullable fields and flags.
- Give every lock-free multi-field publication one documented happens-before
  protocol. Publish initialized payload/count metadata before reachable heads,
  and capture a generation/version before any dependent shape derived from it.
  Readers must announce and validate using the same ordering used by
  replacement and reclamation. Use sequential consistency when correctness
  depends on a single total order across independent reader/writer atomics;
  weakening it requires an explicit proof.
- Binding, Shape, Directory, module-generation, and analogous snapshot
  publishers use one explicit reader/writer handoff that prevents early
  reclamation under every final-reader/later-writer interleaving.
- Read terminal task state under the same lock or tagged publication transition
  that makes it terminal; never infer completion from independently nullable
  fields.
- Publication locks protect validation, state transition, and O(1) detachment
  only. After unlocking, enqueue typed bounded retirement; never allocate for,
  walk, destroy, or call into the shared retirement domain while holding a
  publication lock.
- After delayed leases drain and bounded retirement is serviced, residual
  retired memory must be bounded by current or peak simultaneously live state
  rather than total publication/reload history. Document any retention or
  backpressure bound while readers remain, recycle fixed retirement records
  where appropriate, and prove the residual bound with delayed readers and
  repeated public updates.

## Architectural enforcement

- Recursively enumerate every first-party Zig source and require exactly one
  production or verification classification. Derive all production audits from
  that exhaustive classification; never maintain a narrower hardcoded source
  subset that new files can evade.
- Enforce source-level boundaries primarily with types, opaque state,
  `comptime`, and exhaustive switching. Use AST-aware build tooling over every
  classified production file for constraints Zig cannot express; method-name
  lists, literal-loop detection, comments, debug assertions, and behavioral
  tests are not substitutes for a closed type or capability seam.
- Make the audit follow semantic ownership and blocking-destruction boundaries,
  including indirect helpers and every destructor spelling, rather than
  recognizing only selected names or direct loops.
- Treat source-audit output as the classification authority. Update
  `design/INTERPRETER.md` and any active planning/workstream proof claims in the
  same change whenever classifications, reachability rules, or proof claims
  move. Planning artifacts need not be added to or retained in the repository.
