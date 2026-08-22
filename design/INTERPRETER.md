# ecl — the interpreter

This document describes the interpreter as built: one Zig program whose
observable behavior is specified by SPEC.md. SPEC.md is the semantics
authority; nothing here may change an observable behavior. Type and file
names below are the real ones under `src/`.

The interpreter is six cooperating components: immutable reference-counted
**values**, one explicit **frame machine**, chained **environments** plus a
module **registry**, a green-unit **scheduler**, flat-leaf **kernels**, and
the **boundary layers** (reader, printer, IO). It is interpreted,
permanently: no bytecode VM, no JIT, no machine-code generation. The
performance model is interpreter overhead amortized over fat, flat array
primitives, operationalized as two rules:

1. **The dispatch loop got one design pass and is frozen.** All subsequent
   performance work goes into kernels over specialized flat leaves.
2. **Source architecture is audited exhaustively.** The build audit
   recursively enumerates `src/**/*.zig`, `test/**/*.zig`, and root-level
   Zig build inputs and requires every file to belong to exactly one
   production or verification manifest; an unclassified file anywhere in
   those first-party roots fails the build. Classified production files
   receive the bounded-body and unsafe-cast checks that Zig's types cannot
   express. Runtime sources live directly under `src/`; test suites and
   helpers under `src/tests/`; substantive build-only checks under
   `src/tools/`. `src/native/` is the independently rooted author SDK
   package — that module-root boundary prevents SDK code from importing
   interpreter internals.

   The same audit lexes `src/prelude.ecl` well enough to distinguish
   comments from multiline strings and requires each top-level definition
   to be a `### def <name>` / attached comments / annotation / body /
   matching quoted name / `def` block. This source-layout rule lives in
   build tooling, deliberately not in a runtime test that searches
   implementation text.

## Values and memory

- **Value = 16-byte two-word tagged cell** (a Zig tagged union). Word 0:
  payload (i64 / f64 / char codepoint / u32 symbol id / u32 word id / heap
  pointer). Word 1: tag. All atoms are inline; heap objects exist only for
  lists, dicts, and tasks. NaN-boxing is impossible here: full-range int64
  with overflow-as-error cannot live in a 48-bit payload. The data stack
  is contiguous `Value` storage.
- **Heap header (16 bytes):** `{ rc: AtomicU32, meta: u32, len: u64 }`;
  `meta` holds the representation tag and flags. Capacity is an explicit
  field in the leaf payload. Allocation rides the system allocator; there
  is no custom bucket allocator.
- **Mutation is capability-gated.** `Header` is opaque. Allocation yields
  an `InitializingHeader`, uniqueness checking yields a `UniqueHeader`, and
  only those capabilities expose their kind-checked mutation operations.
  Immutable readers are representation-specific; there is no public
  generic mutable-payload cast and no debug-only uniqueness gate.
- **Leaf kinds (one frozen enum shared by header tags, kernel dispatch,
  the idiom table, and the printer):** GenericSpine, U8, I64, F64, Char1,
  Char2, Char4, Symbol (u32 interned ids), Dict, Task, plus one reserved
  tag for a narrow-mask representation. Leaf kinds are representation
  only, never semantics. U8 stores ordinary integer-list elements in one
  byte when every value is in `0..255`; construction selects it automatically,
  and mutation outside that range widens to I64. Host binary consumers may
  borrow its packed storage while retaining the list, but ECL code cannot
  observe whether it is packed. A string leaf carries its width tag (1/2/4 bytes
  per char, per string), so ASCII costs one byte per char and indexing
  stays O(1). Specialization is a construction-time header fact, never
  recomputed by inspection — the printer reads a bit.
- **Value rendering:** `print.zig` uses one explicit action worklist for
  both styles. `str`, errors, and reflective source use compact canonical
  whitespace. REPL stack display and `io.pp` select the display style, which
  changes only the separators between rectangular matrix rows (and one
  enclosing matrix-group axis) to newline-plus-indentation and replaces a
  list longer than 256 elements with one count-bearing whole-list marker.
  Canonical rendering never elides. The worklist keeps both styles free of
  host recursion, and display elision happens before matrix-shape scanning or
  before any element or character from the huge list is scheduled.
- **Dicts:** keys vector + values vector (insertion order for free) +
  cached per-entry hashes + linear scan below ~16 entries, one u32 hash
  index above. Hash agrees with `=`: numerics hash by numeric value (2 and
  2.0 collide), and the whole-dict hash is a commutative combine of entry
  hashes because equality ignores insertion order.
- **Symbols:** one global append-only intern table; a symbol is a u32
  index. Words and symbols share the id space with distinct value tags.
  Concurrent interning locks the write path only; reads index the
  append-only vector lock-free. Symbols are never freed — the unbounded
  intern table is a documented hazard.
- **Provenance lives on the code plane, never on values.** Reader-built
  side tables key spans by list identity + token index. Runtime values
  carry none; code assembled at runtime via `cons`/`compose` has no spans,
  and error dicts omit position — absence is absence.

## Reference counting

- **Precise atomic counts:** Relaxed increment, Release/Acquire decrement.
  There is no sticky "shared bit" — a sticky bit never recovers
  uniqueness, which would permanently defeat copy-on-write's copy-once
  guarantee.
- **The stack owns its values.** Push and pop perform *zero* RC
  operations; the dup family (`dup`/`over`) is the sole increment site in
  the evaluator; primitives consume their arguments and increment only
  when storing into a new structure or the environment. This
  ownership-passing discipline is what makes rc==1 actually fire on
  pipeline intermediates.
- **One uniqueness function:** an rc==1 read with **Acquire** ordering
  (never Relaxed — an rc==1 Relaxed load does not synchronize with a
  concurrent drop's still-in-flight reads). Used identically by append,
  amend, and every kernel's buffer-reuse check. Nested in-place amend
  requires rc==1 along the whole path.
- **Kernel reuse rule, uniform:** output buffer := left input if unique
  and width-compatible, else right input if unique, else fresh. This one
  rule is where hidden in-place mutation lives.
- **Publication edges are Release/Acquire:** task-cell completion,
  `env.bind()`, and registry swaps — the only points where one unit's
  writes become visible to another.
- **No cycle collector.** Immutable bottom-up construction, words
  resolving by name (never by heap pointer), and the absence of closures
  make the value heap a DAG. Sole exception: a task returning its own
  handle into its result cell — a documented bounded leak, not machinery.

## Code representation and dispatch

- **The quotation list is the only code representation.** After
  interning, span eviction, and lock-free environments, walking the plain
  list is a load + match per token. There is no bytecode and no derived
  execution view; the binding cell's compiled-form slot exists and is
  unused.
- **One switch-dispatch inner loop:** ip/code/env live in host locals; the
  frame stack is touched only at word calls, combinator suspensions,
  returns, and unit boundaries. Tail calls overwrite the in-register
  (code, ip, env) triple — TCO is frame reuse.
- **Binder lowering retires its environment at the last local read.** A
  head binder lowers to the environment build, one `dup i at swap` per
  local reference, and one `pop`. A body form that is not a local read has
  to run under `dip` only while that environment is still on top of the
  stack, so the `pop` position decides how many forms pay for it: hoisting
  it to one past the last local read — to the start of the body when no
  local is read at all — emits every later form as ordinary code. The
  common shape `(|x| x …)` therefore pays for its locals once rather than
  once per form, and failures raised by the forms after that boundary
  trace without a `dip` activation and carry their own source span.
- **Primitives are ordinary core-env bindings** carrying a primitive
  id/function pointer; core is the outermost environment. This eliminates
  string-match dispatch, makes shadowing uniform, and gives every word
  exactly one resolution per execution. Host-registered primitives must
  carry both a validated effect and nonempty documentation; registration
  normalizes and copies the borrowed documentation into the same immutable
  binding snapshot used by `doc`, `which`, and `see`.

## Environments and late binding

- **Deep binding** (chain search: child → session → core; module → its
  uses → core). Chains are structurally short because quotations capture
  nothing.
- **A binding resolves in the chain it was defined against, with no
  exceptions.** An `Eval` frame carries two scopes, not one. `scope` is where
  the body's own definitions land and what it hands to any quotation it
  invokes on a caller's behalf; `resolution_scope` is where the body's *word
  references* resolve. `scheduleWord` sets the second to the module home for a
  homed binding and to the unit's lexical scope — the session root over core —
  for a primitive or embedded prelude definition. Before that split, a
  homeless binding inherited whichever environment happened to be executing,
  so a module exporting a word named like a core one reached inside every
  prelude word that module called: a module defining `where` broke `filter`,
  whose body is `over swap each where at`. Late binding is untouched — lookup
  is still performed at call time, which is why redefining `cons` at the
  session level still changes `wrap`. What went away is dynamic scope.
- **A quotation resolves where its invoker runs.** Quotations are plain lists
  that capture nothing, so `call`, `each`, `@attempt`, `@module`, `@defm`, and
  `within` all set the new frame's `resolution_scope` from the invoking frame's
  `scope`. That is what keeps a module word's `(private-helper)` resolving
  when it is handed to a combinator defined in core. It also means a
  session-level `import` that replaces a core name still reaches prelude bodies
  — explicit one-name replacement is the documented way to patch a binding.
- **Name domains are nominal and validated.** `BindingName` is exactly one
  unqualified non-reserved segment, `ModuleName` is one or more valid
  segments joined by dots, and `QualifiedName` is the validated pair of a
  module name and binding name. Only their cursors/factories construct these
  brands from raw intern ids. Environment maps accept `BindingName`, registry
  maps accept `ModuleName`, and qualified dispatch splits source at the final
  dot before constructing `QualifiedName`; the types prevent accidentally
  substituting one id domain for another. The factories and the source reader
  drive one scalar classifier, including UTF-8 decoding and the complete
  Unicode whitespace set used by tokenization; a branded host/native name
  therefore cannot contain whitespace, reader delimiters, malformed bytes,
  or another spelling the language could not read as that name category.
  Syntax markers such as `--` and `:` remain raw interned symbols and cannot
  pass through a privileged binding-name factory. Registry mutation cursors
  likewise expose operation-specific error sets, so callers cannot retain
  diagnostics for outcomes a transition cannot produce.
- **Slot identity is separate from the code generation.** A registry slot is
  created for the first successful registration of a canonical name and
  outlives every generation published under that live registration. It owns
  the fair per-slot arbiter that serializes state applications and one
  immutable snapshot of the durable operand stack. Re-registration replaces
  only the generation the slot publishes; the durable stack is retained.
  Removal and Session teardown consume one `live -> closing -> retired`
  transition on the same structure. A removed name may later acquire a new
  slot; no ECL value can name the old one. A retired slot's inventory entry is
  recycled only after its lifetime witnesses drain, so settled memory tracks
  peak simultaneously live slots rather than registration history.
  Each slot owns a nominal `InventoryEntry` for its allocation lifetime. The
  writer lock links that entry once and later moves the slot between O(1)
  pending and ready reuse queues; removal never scans or mutates an unlocked
  backing inventory.
- **Binding cells:** a binding is one closed sum — a source-defined word
  body, a host builtin, or a native callable. There is no kind tag beyond
  that and no value arm: constants are word bodies holding a literal
  capture, so resolution never has to ask whether a name pushes or
  applies. `def`/`set` replacement publishes one complete immutable
  snapshot atomically: binding, visibility, home, effect, documentation,
  and compiled form. Omitting metadata clears it in the new
  snapshot; extant leases retain the old snapshot's body and metadata
  until release. Every future resolution heals by construction, so late
  binding needs zero invalidation. Shape changes (name create/delete,
  `uses` edits) bump a per-env generation. **The iron law for any future
  cache: hold the cell, re-read its interior every execution; never cache
  a resolution.**
- **Registry:** name → atomically swapped `{env, generation}`;
  re-registration bumps the generation; commit happens only after the
  module body succeeds. The generation counter is the observable form of
  binding writes. **Module words pin one generation for a whole body** —
  no mixed-generation execution mid-word.
- **Dynamic qualification reuses ordinary dispatch.** `qualify` drives the
  validated module-name and binding-name cursors and materializes their
  `QualifiedName` as a word value without reparsing source. `execute` consumes
  only a word and enters the same resumable `DispatchDriver` used by an
  executable source form; there is no second lookup/application path and no
  loss of home, private visibility, annotation checks, trace metadata,
  builtin/native behavior, cancellation, or state authority.
- **Single-writer rule:** only the session thread writes session-visible
  environments; unit bodies write only their disposable child scopes. The
  registry is the one multi-writer table and takes an explicit
  synchronized swap. Registry publication reserves directory, slot-inventory,
  retired-generation, and loader-admission records before acquiring that
  lock. The locked transition is allocation-free and O(1): it validates the
  observed head, links already-owned records, and publishes. Core is frozen
  after prelude installation — zero
  synchronization forever after.
- **Lazy child envs:** scope = `{local: Option<EnvRef>, parent}`; the
  child table is allocated only when a `def`/`set` actually executes in
  the scope. Quotations capture nothing and locals compile away, so
  combinator elements essentially never allocate an environment.
- **Lock strategy:** no lock on the per-word read path, anywhere. Shared
  structures (core, module envs, registry) publish immutable snapshots via
  atomic pointer swap; unit-local scopes are unsynchronized by ownership.
- **Snapshot reclamation.** Binding snapshots, environment shapes, and
  registry directories use announced reader leases. Pointer publication,
  reader announcement, and the writer's zero-reader check are sequentially
  consistent, placing the handoff in one total order: a reader either
  protects the old snapshot before reclamation or observes the new
  pointer. The last departing reader detaches a retired chain under the
  writer lock and publishes its head to the shared retirement domain after
  unlocking; it never walks or frees that chain. Each retirement turn
  destroys one typed snapshot/directory record and requeues its successor,
  so superseded chains are reclaimed as their announced readers drain
  without imposing history-sized work on the final reader or writer.
  Module slots use the same handoff for generation leases; retired generation
  records form an intrusive FIFO serviced one record per maintenance step,
  so neither commit nor maintenance scans reload history. `GenerationLease`
  is a narrow nominal observation capability: it exposes identity metadata and cursor
  factories, not the mutable environment, scope, reference count, or
  retirement operations. Session execution may consume it into a distinct
  `ExecutionGeneration` only with the Session-private `ExecutionAccess`
  capability; neither observation type returns a raw `ModuleHome`. Only a
  `Unit` lifetime guard can turn that execution home into an independent
  `GenerationPin`; registered native callbacks receive no such authority,
  and Session shutdown joins and tears down every Unit before destroying
  the issuing host domain. Each resolve/name cursor takes its own
  `GenerationPin`, so releasing the originating lease cannot retire the
  generation while the cursor still holds an environment snapshot.
  A published generation also owns a nominal `SlotLease` for its complete
  lifetime. Directory maps may contain raw slot entries only while their
  directory lease is held; lookup retains an operation `SlotLease` before
  releasing that directory lease. Commit, removal, and `within` carry the
  witness through every later phase, and a
  `StateTurn` owns it while queued or granted. Closing can retire code and
  state without draining generation pins, but the allocation cannot be
  recycled until the arbiter, retired directory chain, and slot-lease count
  are all quiescent. There is no mutable slot identity to race or revalidate.
  After removal publishes its directory close edge, it transfers the granted
  turn and detached durable stack to a typed `RemovalRetirement` in the shared
  scheduler domain before the initiating Unit can observe cancellation again.
  That work owns no pointer into Unit storage: transfer returns the Unit's
  turn authority immediately. Cancellation may discard only an observation
  lease; it cannot abandon code/state retirement or slot reuse settlement.
- **Visible-name completion boundary:** `VisibleNameCursor` is the single
  public-name traversal for both `words` and host completion. Its tagged
  root is either one retained scope path or the pre-first-unit session
  environment; its tagged phase variants own exactly the direct cursor,
  scope Shape lease, registry acquisition cursor, export generation/cursor
  pair, or core cursor required in that phase. A transition constructs its
  successor payload in one step, so the pre-first-unit environment-to-core
  transition cannot expose a core phase without a core cursor. Registry
  namespace enumeration likewise owns one Directory lease while yielding
  canonical module and alias names. `Session.completionCandidates` drives
  those observation cursors inside a retirement-settling blocking turn.
  Dotted prefixes use non-mutating intern lookup plus a public-export
  cursor; arbitrary input is never inserted into the process intern table.
  The public `CompletionSet` contains only sorted, duplicate-free rendered
  bytes in allocator-owned storage: it leaks neither ids nor runtime
  authority and remains valid after Session teardown. The same opaque
  `RenderedText` ownership carries stack and error renderings; no Session
  method returns its host allocator. Production `comptime` reflection
  recursively rejects allocator, IO, environment, registry, Unit,
  scheduler, console, host-owner, release-domain, observation leases, and
  private Session state from every public Session return type, and rejects
  observation leases in public parameters while permitting Session
  construction to accept its host resources.
- **Definition annotations:** `definition_prims.zig` recognizes only
  direct top-level word markers in the candidate quotation, validates the
  entire combined effect/doc shape with bounded polling, constructs owned
  effect metadata, and calls the single binding publication funnel only
  after every check and allocation succeeds. Top-level effect metadata
  does not schedule contract frames; module home transitions trigger the
  effect frame, while same-home tail calls remain frame-neutral. `doc`,
  `which`, and `see` resolve through ordinary leased bindings; `see` combines
  effect and documentation back into one quotation, materializes that source
  through the poll-aware reflection plan, and sends it through the same
  canonical layout as `ecl fmt`. Every parsed unit owns one ref-counted source
  buffer; provenance records the byte range of each reader-built quotation,
  and a published binding retains only that slice handle. `see` can therefore
  render authored binder names while dispatch continues to use the lowered
  executable quotation, with no duplicated source body per binding.
  `doc.zig` normalizes documentation with an
  exact-size two-pass traversal and the machine's structural poller before
  publication, so formatter-introduced physical wrapping never leaks into
  reflection.

## The frame machine

- **A unit is a movable heap struct** `{frame stack, data stack, env ref,
  control block}`. No evaluation recursion ever occurs on the host call
  stack, which is what makes units green: suspension is "stop stepping."
  This identity between the frame machine and the scheduler is the
  load-bearing synergy of the design.
- **Frames are ≤104-byte uniform records** (code ref, ip, env ref, kind
  tag, typed payload). The ceiling covers the tagged application mode, the
  immutable continuation driver, trace ownership, and the qualified-load
  return frame's complete replay-or-dispatch continuation. That last state
  raised the former 80-byte ceiling: retaining the semantic request across
  nested source execution is preferable to correlating a consumed operand,
  instruction pointer, and ambient load state. Combinator state is indices.
  Isolation and failure rollback save only base indices into the
  unit's one contiguous data stack: isolation is a base-index barrier and
  attempt-catch is truncate-to-base, O(1). `cond` and `while` are the one
  distinct observation protocol: a resumable guard cursor retains the visible
  operands in an immutable generic-spine checkpoint, permits destructive test
  execution in the same scope, and restores that checkpoint in bounded chunks
  before selecting an action or body. No frame owns or copies a user-sized
  stack snapshot.
- **Boundary frames** (attempt/module) record saved depths and form an
  intrusive chain with a register to the innermost — unwinding never scans
  or interprets frames (crash-only has no finally); it truncates.
- **Lazy traces:** no live trace vector. An unwind walks frames once,
  mapping word-body frames to qualified symbols and the failing token to
  its span. The happy path pays nothing; TCO means traces show the
  non-tail spine; host frames never appear.
- **Errors:** `Result<(), Box<EclError>>`-shaped returns through the
  machine (boxed so the happy-path return stays register-sized); host
  errors convert to error dicts only at IO boundary words. The `ErrorKind`
  enum is the closed kind set from SPEC.md; the unit owns an
  allocation-free `EclErr` payload until an unwind materializes the
  language dict.

## Bounded work

All user-sized work is cursor-shaped so that scheduling, cancellation, and
allocation failure interrupt it at bounded intervals.

- **User-sized traversal is an explicit cursor.** There is one
  cursor-based implementation of each algorithm. Scheduler-attached shells
  own that state in a `WorkDriver`, advance at most one accounted quantum,
  and return the Unit to the ready queue with the exact next position and
  partial result. Blocking bootstrap/tool shells drive the same cursor
  repeatedly; there is no cancellation-only, unlimited, or second
  synchronous implementation.
- **Iteration and bulk access are coupled to cursor progress.** Index,
  slice, byte, release, and materialization cursors expose bounded chunks
  and report suspension before another quantum. Bulk operations cannot
  hide unbounded work behind one logical transition; bulk chunks expose no
  more than 256 already-charged bytes, and repeated passes share the
  unit-wide budget.
- **Polling has one vocabulary.** Finite cursors return
  `poll.Progress(T)`, streams return `poll.StreamProgress(T)`, and
  blocking facades use the shared `drive` helpers. Stable bottom-up
  sorting is one parameterized `MergeSortCursor`; reflection name ordering
  and language `grade` supply only their payload and resumable comparator,
  so resumption and stability have one implementation.
- **Construction has two approved shapes.** A known-size result is
  allocated exactly once and initialized through a work cursor. An
  unknown-size result uses linked fixed chunks, then materializes exactly
  once through a work cursor. Reader forms, binder output, string
  provenance, span tables, and the session span archive use this
  substrate; none grows by relocating accumulated state or by automatic
  hash-table rehashing. Homogeneous fill phases share
  `ChunkedMaterializer`; action-producing reflection drivers accumulate
  through `ActionPlan`, which owns counting, exact allocation, filling,
  and rendering.
- **Stateful list combinators use those same shapes.** `stencil` computes
  its result count up front, owns one exact result buffer, and stages and
  materializes only the current overlapping window before its isolated
  application. `unfold` owns the current state and distinct predicate/step
  contracts while generated values accumulate in a non-relocating
  `OwnedValueChain`; a parallel fixed-chunk metadata cursor borrows those
  values. Termination allocates the now-known exact result once, copies into
  it in bounded chunks, and hands it to the ordinary polled value
  materializer. Cancellation, application failure, and allocation failure
  therefore all retire through driver fields without a synchronous walk.
- **One accounted native step per unwind pass.** An application
  continuation that resumes records a bounded native step, and the machine
  loop consumes exactly one of those per pass before returning the Unit to
  the scheduler. Frame unwinding therefore stops after a continuation that
  finished with a step recorded, exactly as it stops for one that installed
  a work driver; nested in-place applications completing in a single
  unwind — `(q) dip` inside `bi` — are the ordinary case, not an exception.
- **Bounded probes are lazy.** Formatter group lookahead uses a
  fixed-capacity command stack and expands concatenations one child at a
  time; its step and stack ceilings apply before child expansion, and
  width scans stop once the remaining line width is exceeded.
- **The build audit enforces the boundary from parsed Zig syntax.** It
  rejects relocating/rehashing provenance storage, whole-traversal
  charging, optional polling helpers in migrated paths, unbounded
  identifier scans, and allocator-backed formatter lookahead. Because the
  audit examines parsed tokens and function spans, comments and string
  literals cannot evade or spuriously trip a rule. Behavioral tests
  separately prove cancellation through public paths.

Work cursors keep position explicitly, and every scheduler-reached
traversal returns at the unit-wide kernel budget (65,536 transitions).
Cancellation is therefore observed no later than that safe-point interval;
evaluator fuel returns movable units to the scheduler between dispatch
slices. At the same boundary a long pure kernel lets the pool execute one
other ready slice, which provides one-worker progress without yielding
from inside console or publication critical sections.

Any change to this machinery must preserve:

1. one cursor-based implementation per user-sized traversal — no duplicate
   synchronous fast path;
2. return within the accounted quantum with exact next-cursor and
   partial-output state;
3. resumption never repeats visible IO, publication, mutation, allocation,
   comparison, or ownership transfer;
4. cancellation, OOM, and ordinary errors unwind all owned partial state;
5. exact-size materialization for known sizes; fixed chunks plus one
   polled materialization pass for unknown sizes; no relocating or
   rehashing storage on cancellable paths;
6. only constant-bounded work may execute directly — runtime-size-
   dependent work is never classified constant because typical inputs are
   small; and
7. scheduler safety and liveness, one-worker progress, observable results,
   error provenance, and representation parity remain unchanged.

## Scheduler

- **Functional core, imperative shell:** `scheduler_core.zig` is an
  allocation-free transition module for unit, wait,
  registration-ownership, and scope decisions. The threaded shell owns
  locks, queues, task payloads, clocks, and handlers, and executes only
  commands returned by that core. Generated Minish traces drive the
  production scheduler, and a second property drives the installed CLI
  with shrinking scheduler scenarios and a process deadline; these cover
  the imperative registrations, handlers, publication, wake, structured
  children, and cancellation-drain behavior directly.
- **Per-slot state arbitration.** `within` applications are serialized
  scheduler work, not mutex-held evaluation: a unit whose turn is not yet
  granted yields as ordinary resumable work and is re-run until the FIFO
  reaches it, so no OS lock is held across `runSlice` and cancellation
  unlinks a waiting turn without waking anything. Deadlock is prevented
  structurally rather than detected: parking is refused at the single
  `Machine.park` choke point every parking word must traverse, and
  nesting, a second slot, and a superseded generation are refused at
  admission. Refusal is structural rather than remembered: a unit owns one
  turn authority, `request` spends it, and `release` returns it, so a second
  acquisition — a nested `within`, another module's draft, or a reload or
  removal issued from inside a state application — has nothing to spend and
  every acquisition site must handle the resulting error. A turn queued
  behind a re-registration re-establishes the currency of its home after the
  grant as well, because the barrier it waited on may have replaced it.
- **Green units on a fixed pool** (default = CPU count; the 1-worker
  degenerate configuration is supported and tested). One mutex-protected
  global run queue; the invariant to protect is "a unit is a movable
  object," not the queueing policy. No worker threads or timer thread
  start until first `@spawn`; prelude installation is bounded; nothing else
  spins up at launch — cold start (`ecl '3 4 +'`) is a budget.
- **Fuel safe points:** a per-unit counter decremented per dispatch step
  and per kernel chunk; at zero, check the atomic cancel flag, maybe
  yield, refill. Native work spanning a quantum is represented by an
  owned, type-erased `WorkDriver`; each resume performs one bounded slice
  and returns the unit to the ready queue. A worker never runs another
  unit recursively while retaining the current unit's native stack.
  Attempt, task-result, and join-result list construction use the same
  exact-size resumable materializer. Raised-error field lookup and trace
  validation are likewise scheduler-visible cursor work. No signals, ever.
- **One owned stack handoff:** a `WorkDriver` cannot mutate the operand
  stack with its result. It returns `WorkProgress.output`, transferring
  the value to the evaluator, which destroys the producer and performs the
  sole fallible stack commit through `pushOwned`. That operation consumes
  the value whether append succeeds or fails: success transfers it to the
  stack; append OOM retires it directly into the allocator-scoped
  `ReleaseDomain`. Known multi-output resumptions reserve their complete
  stack window before transferring either output. The source audit
  identifies driver functions by their `WorkProgress` return type and
  rejects direct stack pushes; all other production components receive a
  `StackReservation` for exact-size, non-fallible writes or call the
  machine's consuming stack API, and the audit rejects direct
  operand-stack mutation outside `machine.zig`.
- **Parking payload ownership is defined by the request type.**
  `ParkRequest` and `ParkResume` expose the sole projections for their
  owned value graph and, for requests, their selected task sequence. Wait
  registration, abandonment, and deinitialization do not repeat
  tag-to-payload ownership switches.
- **Join result teardown owns one heap root:** evaluator-owned join
  accumulation uses an exact-capacity `OwnedValueBuffer`. Abandonment
  retires the buffer's single generic-spine root, and the shared release
  domain traverses its results later; the fixed tagged teardown state
  sequences only the task input, result root, optional raised value, and
  terminal disposition (continuation vs OOM). A terminal language failure
  consumes those same fixed roots through one bounded cleanup advance
  before leaving the evaluator; abandoned Units use the scheduler teardown
  cursor. No result-sized loop survives.
- **`@each` owns construction and joining without dictionary
  authority.** Its public primitive installs a `WorkDriver` that owns the
  input sequence, quotation, and exact task buffer. Each slice publishes
  the unchanged quotation with an explicit borrowed seed; initialization
  retains that seed as the child's sole initial stack value. Completion
  transfers the task list into the evaluator's ordered join state — a
  private tagged machine representation, not a private binding; name
  resolution has no privileged core-access mode. `await-all` is the
  source-defined `(await) each` fan-in; no internal join word exists.
- **Runtime retirement has one allocator-scoped owner.** `ReleaseDomain`
  is the sole value-graph walker and bounded external-retirement
  scheduler. Dropping `OwnedValue` performs only the refcount transition
  and intrusively queues a zero-count object; scheduler/root turns drain
  that queue in fixed chunks. `OwnedValueBuffer` gives partially filled,
  exact-capacity result construction the same constant-time abandonment
  rule; `OwnedValueChain` links fixed generic-spine chunks for
  unknown-size reader results while preserving a single retirement root.
  Scheduler continuation fields mark transferable ownership as
  `heap.Owned(T)`; bare fields are borrows or scalar state. A compile-time
  field walk retires those markers and rejects payload types without a
  disposal protocol. Each owned payload's disposal receives only that
  payload; resources needing correlated state are one owned value (an open
  source file owns both its file handle and IO capability). Disposal never
  receives the enclosing driver, so declaration order carries no lifetime
  meaning. A structured payload exposing both `retire` and `deinit` must
  select an `OwnedDisposal` at compile time; partial-state materializers
  select `retire`, and an omitted or contradictory selection fails
  compilation. Every scheduler, application, and fallback driver declares
  one exhaustive `DriverOwnership`: `fields` forbids destructor hooks and
  always uses the generated walk, `bounded_retirement` requires the
  intrusive node and `advanceRetirement`, and `self_owned` is restricted
  to address-stable aggregate state whose internal borrows require
  coordinated teardown. All erased adapters and direct detach paths call
  the same policy dispatcher. `Machine.startDriver` consumes the whole
  initialized value on both success and allocation failure; the only
  separate entry accepts a heap object whose type declares address-stable
  construction and cannot be used by an ordinary driver. Typed intrusive
  retirement nodes also own snapshot chains, fixed reader chunks,
  abandoned source drivers, binding cells, environments, scopes, and
  module generations; their generated adapter advances one bounded cleanup
  step and requeues unfinished work without allocating. Final generation
  release changes typestate and enqueues work; it never destroys an
  environment or releases a parent scope under the registry publication
  lock. Unit and `ModuleGeneration` use the same
  `Scope.EmbeddedTeardownCursor`: its `waiting_for_children` phase retains
  the embedded owner's stable reference until every heap child has
  propagated its parent release, then its typed retirement phase advances
  the scope and environment before final owner destruction — queued
  cleanup therefore cannot retain a pointer into freed unit or generation
  storage. Work-driver, application-frame, and fallback destructors
  receive the domain explicitly, and reader/binder/kernel materializers
  retire into it on abandonment. Unit OOM/exit teardown pops continuations
  and operands through a scheduler-owned cursor instead of looping on the
  evaluator stack. Blocking teardown does not accept a free-standing
  cleanup argument. Root-owned `Env`, `Registry`, `SpanArchive`, and
  `Scheduler` expose only opaque, consumable root identities; each
  identity points to module-private backing state containing the one
  `HostCleanup` issued at construction, and no public root field can
  replace that capability after allocation. Their constructors derive both
  the allocator and retirement domain from the private capability, and
  teardown destroys the backing through the same owner before consuming
  the identity; they expose no independently mutable
  allocator/domain/host triple. A compile-time root-shape check requires
  the opaque handle/private state split and the single host capability.
  Synchronous reader, binder, prelude, and formatter entry points use the
  same seam rather than accepting a second allocator and validating it
  dynamically. Scopes and reader cursors expose resumable retirement, and
  chunk stores obtain their allocator from their own storage rather than
  from a caller; none exposes a `(target, arbitrary host)` pair, so the
  mismatched-owner state cannot be formed at a teardown call in any
  optimization mode. Scheduler-owned destructors receive only the domain.
  Production has no synchronous `releaseValue`/`decRef` adapter that can
  pair an arbitrary value with an unrelated host; owned values retire
  through their construction domain, and tests hold an explicit owner or
  `Cleanup` capability. The synchronous reader requires caller-supplied
  host authority and returns `HostParsed` bound to that exact authority;
  `HostParsed.deinit` derives and drains its issuing owner, while cursor
  and scheduler code receive `Parsed`, whose API exposes only
  `RetireCursor` — blocking versus resumable parsed teardown is selected
  by type. Copy-on-write replacement swaps the destination's old
  representation into the consumed source wrapper and retires that wrapper
  through the caller's shared domain; representation adoption has no
  allocator-only blocking adapter. Driver destruction is selected by the
  exhaustive compile-time ownership policy rather than a source scan for
  destructor names; the audit is limited to boundaries the compiler cannot
  represent directly, including unsafe casts that could forge
  `HostCleanup` or `ExecutionAccess` and casts at the owned erased
  callback seams.
- **Observation and execution capabilities do not expose host ownership.**
  `Env` returns a copyable opaque `EnvironmentView`, never a mutable
  `*Environment`; its API is limited to snapshot leases, lookup/name
  cursors, generation observation, and owned name materialization.
  Snapshot leases carry the same observation identity rather than
  exporting their environment pointer. Scheduler host state and worker
  execution state are distinct: `Scheduler` alone retains `HostCleanup`
  and owns settlement, shutdown, wake detachment, and backing destruction,
  while units, task scopes, and OS threads receive only
  `*const WorkerScheduler`. The worker facade has private
  allocator/domain execution resources but neither host cleanup authority
  nor a lifecycle method. `SessionCore` likewise stores only its
  `HostOwner` and derives allocator and release-domain borrows;
  compile-time representation checks reject cached correlated fields, host
  authority in worker state, and lifecycle methods on the worker facade.
- **Task cells:** write-once, multi-waiter (handles are dup-able values),
  under a small per-cell mutex. `await` parks the unit — it never blocks a
  worker; completion moves waiters to run queues. **Wake decisions:** one
  mutexed `WaitSet` policy selects exactly once per park, so completion
  and cancel cannot double-enqueue a unit (a unit on two workers corrupts
  its stacks). The core distinguishes registering,
  selected-before-activation, active, and delivered wait phases. Each
  cell-list entry is a stable owning wake handle in the wait set's
  exact-size, non-relocating registration array, never a borrowed pointer
  into temporary setup storage; each entry has its own ownership phase and
  reference count, and the array remains alive until every entry retires.
  Completion detaches at most 256 handles per scheduler turn; the core
  separately models directory cleanup and delivery return in either order.
  Wait setup, canonical duplicate lookup, loser cleanup, and value-graph
  retirement are resumable scheduler jobs. This is deliberately
  reference-counted rather than lock-free reclamation. Cancel also removes
  parked units from waiter lists.
- **Publishing a wait set is the last thing its setup may do.** Activation
  is precisely what lets another selector deliver and drop the wait set's
  final reference, so the resumable setup job advances its own phase
  *before* the publish and reads nothing afterward. Writing the terminal
  phase after activating is a use-after-free that only a racing delivery
  reveals — found by `test-tsan` in the hot-reload-against-concurrent-callers
  case, where an auto-load inside the racing children widened the window.
- **Task result publication** exposes only `constructing`, a stable active
  `TaskExecution`, or a published terminal result/OOM state. The
  execution's evaluating/finishing union is worker-private, so advancing a
  materialization cursor cannot race a waiter reading the cell's
  publication tag. No phase can carry an unrelated unit, materializer, or
  terminal payload.
- **Structured lifetime:** the children list lives under the per-task
  mutex, and spawn re-checks its own cancel flag after registering each
  child (kill-on-arrival closes the orphan race). Scope close cancels
  unawaited children and **waits for quiescence** before reporting its
  result. A cancelled unit's result is `{'err {'kind 'cancelled …}}`
  with trace fields when the poll site can produce them, absent otherwise.
  Language code cannot call a blocking scheduler wait API: `await`, joins,
  deadlines, and permitted root `exit` all emit typed park requests; the
  shell alone registers and resumes those requests, and root-scope
  blocking exists only inside scheduler-owned exit handling and teardown.
  A root waiter's release store is its selector's final access to that
  stack-owned generation; every scheduler pointer and result destination
  is captured first, which prevents an old wake from observing a later
  root wait at the same stack address. Cancellation walks keep a retained
  next-cell cursor, validate it with a tree epoch, and release the tree
  mutex every 256 cells; mutations restart the idempotent walk. Two-pass
  task snapshots retain a pass epoch independently of their optional
  next-cell cursor, including the yield between count and collection; any
  intervening spawn or unlink restarts the whole snapshot. The session
  root environment scope is a lazily allocated stable handle, not inline
  optional storage: child reference-count traffic never aliases the
  session thread's write-once root-handle read, and moving the `Session`
  value cannot invalidate a child scope parent. Root teardown waits on a
  scope-owned condition using the same scope mutex as the child-count
  predicate, so final-child notification cannot be lost between the
  predicate check and sleep.
- **One fair work contract:** cooperative execution and every worker use
  the same persistent `ExecutorArbitration` state. When ready and
  retirement work coexist it alternates one queue entry with one
  retirement quantum, and a contending worker never blocks behind the
  active retirement cursor. Ready tasks, cancellation walks, wait
  delivery, unit teardown, value graphs, reader chunks, and snapshot
  records therefore share progress without either queue starving the
  other. `Session` stores an opaque state handle rather than exposing raw
  mutable `Environment` or `Registry` aliases, and its public API does not
  return environment or generation leases coupled to its private
  reclamation domain. Every public definition/module/alias mutation owns a
  guard that acquires blocking host authority and settles root retirement
  on all exits, even while the only worker is occupied; cold native
  registration, public definition, and root evaluation therefore cannot
  return an idle Session with a stranded backlog.
- **Timers:** one lazy timer thread + an indexed binary heap whose pointer
  slots grow in fixed chunks; embedded wait nodes never relocate and
  removal is allocation-free. `await-for` captures its absolute monotonic
  deadline before lazy timer startup and stores it in the `WaitSet`'s
  arbitration state. Every later completion or cancellation candidate is
  reclassified as timeout once that deadline has passed, and a final
  timestamp check after heap insertion removes an expired node before the
  wait mutex is released — allocation, lock contention, and thread
  creation can neither extend a short timeout nor let a later candidate
  win.
- **IO** runs directly on workers. Console exposes only narrow whole-write
  methods; each method takes and releases its own stdout/stderr lock, so
  no caller can retain or mismatch a writer/lock lease. This preserves
  whole-write atomicity and the cross-task interleaving contract.
- **Determinism lives at join points**, never in scheduling:
  program-order `await-all` results and `@each` leftmost-error are
  schedule-invariant. The only sanctioned nondeterminism is `await-any`
  and cross-unit IO interleaving. Enforced by running the suite at 1 and N
  workers.

## Kernels

The typed seam described here is the one built by post-terminal Step 14. The
milestone-5 text this section replaced described the same shape as if it
existed; what existed was flat *storage* with a boxed execution route over it.
The classification table below is the artifact that makes the difference
checkable rather than claimed: it names how every operation executes for every
operand shape, and rows that still run boxed say so.

- **Dispatch is one closed, comptime-validated table** in `kernels.zig`. It
  classifies every sized kernel operation against every operand shape it can
  meet — aggregates named by `value.HeapKind`, atoms by the `Value` tag, so
  there is no second representation vocabulary to drift — as one of
  `typed_loop`, `bulk_copy` (movement with no per-element semantics),
  `sequential_typed` (unboxed but order-carrying), or `generic_fallback`.
  Coverage is exactly-once over the whole domain: a missing or duplicated
  classification is a compile error, and a scalar pair is outside the domain
  because it carries no representation. Each row's adjacent rationale comment
  keeps a generic classification reviewable without pretending that prose is
  runtime registry data.
- **Typed loops receive memory only through heap-issued capabilities.**
  `heap.LeafReader(kind)` retains its list's root for the reader's whole
  lifetime, so a slice cannot outlive its owner across a suspension.
  `heap.LeafWriter(kind)` owns an exact-size allocation and exposes only
  bounded range writes plus one consuming `finish`; it has no whole-slice
  accessor, which is what keeps a block's stores under the fault protocol's
  control. Both refuse `generic_spine` at comptime: per-cell boxing is not
  reachable from inside a typed loop, and `kernel_flat.zig` imports neither
  `list.zig` nor the materializers — the source audit enforces that boundary.
- **Reuse is a claimed authority, not an optimization guess.**
  `heap.UniqueLeafAdoption(result_kind)` claims a list only when it is solely
  owned and its elements are the result's width, and it is consumed exactly
  once — by `finish`, which republishes that same list retagged, or by
  `abandon`, which leaves the input untouched. A shared or self-aliased operand
  fails the claim, which is why aliasing needs no special case.
- **One cursor rule for bounded work.** `kernel_flat.FlatCursor` carries an
  absolute logical index and plans one half-open range per advance, bounded by
  the caller's remaining `WorkContext` budget and by the kernel quantum, and at
  least one element so progress is guaranteed. The charge goes through
  `kernel_support.Context`, the only seam that touches `Unit.kernel_fuel`, which
  polls at the interval boundary — so cancellation is checked between chunks
  rather than per element. A flat operation of length n therefore costs
  `ceil(n / budget) + O(1)` advances; the planner's arithmetic is unit-tested
  apart from the charging, and the session-level bound is a test that counts
  kernel safe points.
- **Broadcast by scalar operand** (stride-0 style), never a materialized
  replicated vector.
- **Fault handling:** a block of up to 256 staged results carries one fault
  flag rather than a check per element. A block that faults is replayed through
  the same scalar semantic function the generic route uses, which is what makes
  the reported index, kind, message, and data the scalar path's rather than a
  reimplementation's. Nothing is stored until a block is known clean, so a
  result sharing a reused input buffer never destroys the operands the replay
  reads. Recognized `each`/`zip-with`/`fold`/`scan` reach the same loop entries
  and report faults *without* a list index, because the combinator they stand in
  for applies its quotation to one element at a time and its fault has no list
  position.
- **The typed bodies are the scalar semantics.** A monomorphic body calls
  `scalarBinary`/`scalarUnary` with statically known operand tags, so an
  optimized build folds the tag switches away while the meaning stays in one
  place. Nothing about arithmetic, comparison, boolean, bitwise, or shift
  behavior is written twice.
- **Result width is decided before the first element or the operation stays
  generic.** The numeric width map is exact for every operation except `min`
  and `max` on a mixed int/float pair, which return one of their operands and
  are therefore genuinely heterogeneous; that pair keeps the profiling route, as
  does a length-zero result, whose representation is the value layer's existing
  per-producer choice and observable as printed brackets.
- **What crosses the seam today.** Numeric, comparison, logical, bitwise, and
  shift pervasion, including the guarded idioms; `range`; `where`; `rand-ints`;
  and the exact-size copies and gathers behind `cat`, `take`, `drop`, `rest`,
  `reverse`, and `at` with a typed index vector; typed membership over scalar
  or flat-list needles; rank-one `reshape`; same-kind list `put`; and `shape`'s
  known-width result; cross-width string `cmp`; stable typed `grade`/`sort`;
  and first-seen typed `group`/`distinct`; pinned width-specialized `split`;
  and two-pass exact-width `join`. Character-element pervasion uses a fixed
  i64 writer for subtraction and comparison and a profile/fill pass for
  character offsets and selection; invalid character and symbol combinations
  reject at the first logical element without a boxed traversal. `format` is
  value-shaped by definition rather than a pending flat traversal. Generic
  spine and dictionary descent embeds these same typed states when it reaches
  a flat leaf, preserving the inner logical fault index.
- **Order:** grade is a stable merge sort (`poll.MergeSortCursor`) over an index
  vector. Flat keys are read from pinned typed slices and both grade indices
  and sorted values publish directly; generic keys retain the structural
  comparator. Flat group compares typed keys in first-seen order and writes
  each i64 index leaf directly; generic group retains structural equality.
- **Float folds are strictly sequential on every path.** Only exact
  reductions — integer (with fault masks), min/max, boolean — may be
  reassociated for SIMD. Fused and generic paths are bit-identical; the
  fast path is unobservable down to the last float bit.
- **Loop shapes are autovectorization-friendly:** monomorphic branchless
  bodies, block fault masks, scalar tails. Every kernel takes an explicit
  index range. Kernels never own threads; units (`@spawn`/`@each`) are
  the sole concurrency grain, and `@each` guarantees no cross-element
  rendezvous, so a chunking driver is observationally conformant.
- **The kernel list is closed and written down** — adding a kernel is a
  design event, and every kernel ships with its idiom-table entry (one
  artifact) and its differential test.
- **Representation parity is a tested invariant:** fused and generic paths
  must produce identical values *and* identical representations —
  printing makes brackets observable at the prompt.
- **Bitwise kernels reuse the numeric cursor, not the numeric contract.**
  `band`/`bor`/`bxor`/`bnot`/`bsl`/`bsr` are ordinary pervasive entries in
  the same table, so pervasion, dict alignment, polling, and failing-index
  identification come for free. What they do not share is the fault
  vocabulary: a pattern has no magnitude, so there is no overflow mask to
  test, and the shift words carry their own `ShiftCount` scalar fault so
  an out-of-range count reports as a shift problem rather than as
  arithmetic outside its domain.
- **Random draws are addressed, not stepped.** The generator state is a
  `[key counter]` pair, and the mixer is SplitMix64 over
  `key + counter * gamma`. Nothing in the kernel is mutable: element *i*
  of a vector draw is a function of `counter + i` alone, so the driver may
  build the result across resumptions, in blocks, or out of order and
  still produce the same list. Bounded draws reject candidates in the
  incomplete top range (`threshold = (0 -% bound) % bound`) rather than
  folding them, which keeps the distribution exactly uniform at the cost
  of an unbounded — but geometrically improbable — retry.
- **`entropy` is the one kernel that reads the host.** It is gated on the
  host IO capability and calls the platform CSPRNG. Every other random
  word is pure, which is what makes an ecl program reproducible without a
  recording layer.

## Idiom recognition

At direct source-word and isolated-combinator entry
(each/zip-with/fold/scan), the machine structurally matches the body or
quotation against a small closed pattern table. Pattern words name an
expected core binding, which may be either an irreducible builtin or an
ordinary prelude source word. Resolving each exposed pattern word in the
application environment guards the selection; a mismatch falls through to
the generic frame-machine path. The selected host callback is private to
the recognizer: it has no core binding, reflection entry, or higher-order
route of its own.

This lets compact source definitions remain authoritative while still
reaching pervasive numeric kernels and allocation-saving
sequence/dictionary paths. `neg`, `abs`, `mod`, `<>`, `<=`, `>=`, `and`,
`or`, `first`, `rest`, `reverse`, `distinct`, and `vals` use that bridge;
the literal-capture shape `((v) first)` that `literal`, `partial`, and
`set` produce is a pattern atom of its own at `each` entry, so a
capture-headed quotation reaches the same constant-operand kernels a bare
constant does — guarded on `first` resolving to its core source binding
and on the capture being a one-element list, and falling through
generically otherwise;
`sort = (dup grade at)` runs a direct sort, and `sum = (0 (+) fold)`
reaches the sum kernel through fold's entry recognition.
`dip = (swap literal compose call)` is recognized as well, and it is the
one entry whose callback is control flow rather than a kernel: rather than
capture the protected value in a synthesized quotation and compose that
onto the argument, it holds the value in an application continuation and
pushes it back when the quotation finishes, which turns three list
allocations per application into none. It is also the hottest composition
in the language, because binder lowering emits one `dip` per body form
that still precedes a local read. The phrase falls through to the generic
composition whenever it cannot apply — fewer than two operands, or a
non-list on top — so those errors still name the word that observed them.
Since the callback installs an application frame where dip's own body
frame would have been, that frame inherits the word for tracing and a
failure inside the quotation still traces through `dip`; nested
activations collapse to the innermost one, which the generic composition
reported only because its capture quotation forced an extra frame. Cheap
compositions such as `over` and `compose` have no host callback at
all. Per-application guard cost is O(phrase length) against
O(n) work, with no cache and no invalidation. A combinator may resolve its
quotation's words once at entry to choose a fused kernel — that snapshot
is scoped to the recognition guard only; the generic path keeps full
per-application late binding, and resolutions are never cached.

The standard-library placement rule is deliberately asymmetric: implement
a word in the prelude when its definition in ecl is compact, or when its
performance does not justify a host idiom; keep a word entirely primitive
only when its source definition would be substantial and its performance
characteristics justify the host implementation (`zip-with`, `range`,
`to-dict`, `has?`, `del`, `merge`). Recognition is the third option and
the one for a definition that is both compact and hot: `dip` reaches a
host implementation without becoming one, which also keeps it a source
binding for the patterns that guard on it. Prelude words therefore stay
honest source with no public dual representation.

## Typed publication and control state

- Namespace publication accepts `NamespaceName`, produced by the polled
  validator, rather than a raw intern id. Top-level and module
  publications are different tagged types — top-level publication is a
  word body, module publication is a word body or a native callable. Both
  arms carry optional effect and documentation for source definitions, so
  a module binding's declared effect is a live contract exactly when one
  was supplied; the native arm keeps its `ValidatedEffect` and
  documentation mandatory, because the ABI has no unannotated form. The
  module-root scope supplies the single coherent home.
- **A state application is one tagged owner.** `within` constructs a
  single heap-owned structure holding the module-stack draft (the unit
  window above its boundary base), the pending output sequence, the home
  authority, and the publication transition; it appears in the frame stack
  as a third boundary mode beside `@attempt` and module construction. Only the
  definition-site home can create one — the authority comes from the
  executing home's slot, never from a value — and it is consumed exactly
  once, by publication on success or by retirement on every failure. The
  draft never escapes the owning unit, and worker-visible code cannot
  obtain the lifecycle authority required for blocking teardown.
- **Mutation authority is a granted turn.** A slot's durable stack can be
  read or replaced only through a `StateTurn`, a place in the slot's fair
  FIFO. The arbiter mutex is held for O(1) pointer surgery only, never
  across ECL execution, and admission is refused from inside the same lock
  once a slot begins closing, so a turn is never queued against an owner
  that is about to be destroyed. Re-registration and removal take ordinary
  turns, which is what makes reload and close order against in-flight
  applications without a second protocol. Each turn consumes an owned
  `SlotLease` before it joins the queue and releases it only after unlinking;
  queued and granted work therefore cannot observe recycled storage.
- **An immutable image and a stateful registration are separate owners.** A
  `ModuleImage` owns the frozen environment, the module-root scope its
  definitions were published through, and the construction body's residual
  stack as an initial-state template. It owns no canonical name, registry
  slot, arbiter, generation number, or `SlotLease`. A `Registration` retains
  exactly one image and owns everything the image deliberately does not: the
  name, the generation number, and the slot lifetime witness. The reference
  goes one way only — a registration retains an image, never the reverse —
  which is what keeps the value heap a DAG with no cycle collector, because
  a module *value* is a freely duplicable retainer of an image. A first
  registration copies the template into its new slot's durable stack rather
  than consuming it, so the same image can seed a second registration; a
  re-registration does not consult it at all.
- **Invocation context is supplied by a registration lease, not stored in
  binding metadata.** `BindingOrigin.module_local` records a definition's own
  module-local name and nothing else. A qualified resolution acquires a
  registration generation and mints the opaque `ModuleHome` the activation
  carries for its whole lifetime; same-home resolution, private lookup,
  reflection, effect contracts, and `within` all read the slot, name, and
  state through that capability. Only `ExecutionGeneration` — reachable only
  from a registry lease plus the Session's execution authority — can produce
  one. That is why one image registered under two names executes correctly
  under both, and why baking either a name or a slot pointer into the image
  would be a defect rather than an optimization.
- **A diagnostic word is a `(registration, local name)` pair, qualified at the
  render boundary.** An image has no name, so no qualified spelling can be
  interned at definition time. `intern.TraceWord` carries both halves through
  `active_word`, frame trace slots, effect checks, and the failure record;
  byte sinks render the two atoms directly and only the failure-value builder
  interns a qualified spelling. Failures are rare, which is where that cost
  belongs.
- An image under construction is held by an opaque, consumable `OwnedImage`,
  and `seal` is a *consuming* transition to `SealedImage`, the only producer of
  the `ImageRef` registration accepts. Freezing the environment and ending the
  construction capability are therefore one step: the frozen flag refuses a late
  definition, and the typestate refuses a late initial-state template write,
  which has no frozen check of its own because a sealed image has no writer.
  Publication safety is a property of the types rather than of call ordering.
  Publication retains its own image reference rather than consuming the
  caller's, so the module value on the operand stack and the registration are
  independent owners. Tasks spawned during construction carry independent
  generation pins, so rollback cannot destroy the embedded module scope until
  those tasks and their child scopes quiesce. Unit, image, and registration
  lifetime use the same nominal embedded-scope teardown cursor, which retains
  its owner until dependent child scopes have propagated their releases.
  Attempt and module boundaries are distinct tagged-union states, so image
  ownership never depends on nullable pointers or side-band booleans.
- Auto-loading owns a consumable `LoadingLease`. Removal consumes it only
  after success; unwinding retains the capability until the cursor-owned
  cleanup phase. Environment and module resolution expose explicit
  cursors, including shadow and visibility checks, so runtime lookup
  cannot silently select another traversal implementation.
- Core builtins and host-loaded native words occupy distinct binding
  variants. A native binding carries one nominal `NativeCallable`
  (module-instance handle plus validated definition index), never a bare
  callback/context pair. The external extension surface is the typed
  transaction described below; the general-stack `NativeMachine`
  registration seam is not a second supported extension API. Neither
  native bindings nor their callbacks can obtain a `Unit`, mutable
  environment, module home, generation pin, registry, host owner, wake
  control, or reclamation domain.
- Core construction is a `BuildingEnv` typestate capability consumed by
  `finish`. Session, core-build, module-root, lazy-local, and owned-local
  scope storage are a tagged union rather than correlated
  environment/ownership flags.
- Dictionary storage is `initializing | ready`, and the ready payload
  always carries keys, values, and hashes plus one optional owned index
  slice. There is no separately mutable initialized bit, nullable payload,
  or pointer/length pair for reclamation and lookup to reconcile.
- Fixed runtime maps accept only enum key types. Binder locals use nominal
  `LocalName`, environment maps use `BindingName`, registry maps use
  `ModuleName`, and qualified lookup carries `QualifiedName`; a raw
  integer-keyed publication map is rejected at `comptime`.
- Heap values carry nominal `ListHandle`, `DictHandle`, `TaskHandle`, and
  `ModuleHandle` pointers. Allocation returns kind-specific initializing
  capabilities and publication consumes the matching capability, so a list
  cannot be passed to task storage or a constructing dictionary observed
  through a ready handle. Module storage holds one opaque payload plus the
  release callback its typed factory derived; `heap.zig` never learns what an
  image is, and final release drops one image reference into the same bounded
  retirement domain rather than walking a user-sized graph.
- Native continuation ownership retained across a yield is represented by
  an optional or tagged owner (`Accumulator` distinguishes borrowed,
  owned, and transferred). Driver teardown does not consult a side-band
  transferred/owned boolean; short-lived transfers use the same
  `OwnedValue` capability as long-lived continuations.
- Operand removal exposes only `popValue() -> OwnedValue` to evaluators.
  Raw stack extraction is reserved for stopped-unit scheduler cleanup, and
  the source audit rejects its use by primitives or kernels.
- Quotation applications use a validated `StackWindow` and tagged in-place
  or isolated mode. The continuation frame owns its trace and immutable
  driver; callbacks return only the next `ApplicationStep`, so they cannot
  substitute a context or destructor.
- `StencilControl` is the single owner of a stencil's input, quotation,
  contract, exact result storage, and current window index across alternating
  bootstrap and application continuations. `UnfoldState` similarly makes the
  predicate/step phase exhaustive and owns the only current state; the stack
  receives retained seeds rather than an alias with implicit ownership.
- Fallible continuation insertion consumes an `OwnedFrame` capability only
  after storage growth succeeds. Failure leaves the same capability with
  the caller — there is no implicit "append also deinitializes" contract.

## The embedded standard library

- **One manifest, three transports.** `src/stdlib.zig` is a comptime table
  mapping a module name to exactly one entry arm: embedded ECL source
  (`@embedFile`), a linked native descriptor (`*const abi.Descriptor`), or a
  builtin word table (`[]const env.BuiltinWord`). Duplicate names, empty
  sources, and undocumented builtin words are compile errors, so the manifest
  cannot describe a module the loader would have to repair.
- **Embedded ECL files preserve the language's module boundaries.** Each source
  entry is one independently parsed file whose terminal `@defm` registers the
  exact canonical path named by the manifest. `env.assertStaticModuleName`
  validates dotted paths segment by segment at comptime. The host neither
  concatenates definition fragments nor synthesizes umbrella modules, so
  privacy, cold loading, and cross-module qualified dispatch are the same for
  `pkg.*` modules as for user-authored modules.
- **The manifest is consulted before `ECL_PATH`.** `AutoLoadDriver` acquires
  the loading lease, checks whether the module is already registered, then
  consults the manifest, and only then walks the search path. So a stdlib name
  resolves with no host IO and no `ECL_PATH`, and no path module can shadow
  one. The host-IO/search-path bail moved after the manifest check for exactly
  this reason.
- **Every qualified execution carries its request through auto-load.** Resolution
  acquires the module *before* looking up the export atom, because a first
  reference is precisely the state in which that atom has never been interned;
  checking the export first made the trigger depend on whether some unrelated
  source happened to intern the name. A dispatch miss transfers its requested
  word, source site, and trace parent into the load continuation. Source-backed
  loading preserves the caller evaluation even in tail position; after the
  `.qualified_after_load` frame verifies the requested registration, dispatch
  resumes that stored word directly. It never replays a consumed `execute`
  operand. Reflection and import currently restore their consumed symbols and
  select the continuation's explicit replay arm. Session completion selects
  load-only, without executing an export or creating an import. Transport and
  prior registration are therefore unobservable to every qualified-name
  operation, and the tagged continuation makes the three resumption modes
  exhaustive.
- **Contention and recursion are different states.** A `LoadingNode` stores
  its owner rather than a bare active flag, so a second request from the same
  owner is a cycle and one from another owner is contention. A cycle raises
  `'domain`; a contender waits and re-resolves, and a load that finds the
  module already published publishes nothing. Before that, any interleaving —
  even at one worker, since the load driver yields mid-source — reported a
  bogus recursive-auto-load error to every requester but one.
- **The builtin publication arm completes the M4-scoped mechanism.**
  `ModulePublication` gained a `builtin` arm carrying a primitive pointer plus
  documentation, mapping onto the `Binding.builtin` arm that already existed;
  only the publication typestate had been missing. `BuiltinCandidateCursor`
  publishes one word per turn through the same candidate/commit protocol as a
  native module, building each word's documentation value from compiled-in
  text. Publication retains what it is handed, so the cursor releases its own
  reference on every path.
- **A builtin module word cannot declare an enforceable effect.** The
  cross-home effect check runs the instant a builtin primitive returns, which
  is before a scheduler driver it started has produced anything. Builtin
  module words are therefore exempt from the declared-effect requirement that
  native words carry, exactly as source module words are, and `json` and
  `http` state their stack shape in prose instead.
- **`io` is the observable-I/O boundary.** Its builtin table publishes
  `pp`, `prin`, `print`, `inspect`, `stdin`, `slurp`, `spit`, and `lines`;
  qualified names and explicit imports such as `'io.print 'print import` are
  the only routes to those words. The
  primitive callbacks keep host authority private, while `print`, `inspect`,
  and `lines` schedule fixed quotations over sibling exports. The canonical
  any-value renderer `str` is a bounded core primitive because `format`
  interpolates string contents directly; it still produces a value and
  performs no I/O. The `str` module contains only transformations whose
  subject is a string.
- **Static linkage needs no entry symbol.** `ecl.module` takes a `linkage`
  spec: a dynamically loaded extension exports `ecl_module_abi_v1`, while a
  module linked into this image does not, so several first-party SDK modules
  can coexist in one binary. `Loader.startStatic` publishes a linked
  descriptor through the same validate/publish/commit phases as a dynamic
  image, differing only in a no-op image pin.
- **The `@` convention is enforced by the audit, both directions.** A
  hardcoded manifest in `source_audit.zig` lists the unit constructors; the
  audit asserts each is installed and documented under its `@` spelling, and
  that no other first-party primitive or prelude/stdlib definition begins with
  `@`. The compiler cannot express "applies its quotation in a fresh unit", so
  the rule is written down once and checked, which is what keeps the
  convention from eroding as vocabulary grows. `@` stays an ordinary word
  character: user vocabulary may use it freely.
- **An anonymous after row is an input-only contract.** `ValidatedEffect`
  carries a `row` flag set when the after portion is exactly the `...` token;
  `prepareEffectCheck` forwards it and `finishEffectCheck` returns before the
  post-condition compare. Entry consumption is still verified, so a word with
  a variable output regains input checking instead of dropping to a
  documentation-only annotation. The token lexes as an ordinary word — one
  special case in `SymbolCursor`, since it is the only dotted name the
  language spells for itself — and joins `--` and `:` in `isReservedBytes`.
  The native SDK rejects it at comptime: a native `complete` requires the
  exact output tuple, so there is nothing for a row to mean there.
- **`rng` is source, not native, because its state has nowhere else to go.**
  A module's own binding is the only place a threaded generator state can
  live without becoming ambient — a native module holding a state would be
  process-global mutable data, which is precisely what the kernels are
  designed to avoid. Writing it in ECL over `within`/`without` puts the
  state in a binding the user can inspect, seed, and shadow, and costs
  nothing: the arithmetic is already in the kernels.

## Native extension boundary

- **One artifact is one module and one lifetime unit.** A target-specific
  `<name>.eclmod` contains exactly one canonical ECL module and exports
  one SDK-generated ABI-v1 entry point. Its complete word table validates
  and publishes atomically; an artifact cannot partially register, publish
  a second namespace, or leave definitions behind after failed
  initialization. `ECL_PATH` is the only module search path: for each path
  entry in order, resolution tries `<name>.ecl` and then `<name>.eclmod`;
  the first existing candidate is authoritative, including its errors, and
  a native descriptor's canonical name must equal the requested name.
- **Nested input reads are addressed by path.** `list_at`/`dict_at` reach only
  a declared input's top level, and a `ValueView` of an aggregate exposes a
  length and nothing else — so no module, first-party or otherwise, could read
  a list of lists. `read_path` walks one bounded path from an input root: a
  list level is indexed directly and a dict level addresses entry `n`'s key as
  `2n` and its value as `2n+1`. Depth is capped by `max_read_path_depth`,
  which keeps one read constant-cost and makes a pathological document a
  bounded error rather than unbounded host work. The budget is charged per
  step walked. Like the cursors, it is gated by the `reschedule` capability,
  so the descriptor and capability wire are unchanged.
- **Trusted, Zig-only authoring over an exact wire ABI.** The supported
  author surface is the separately distributed `ecl-native` Zig SDK, built
  with the pinned Zig toolchain. It emits the descriptor and a
  target-native shared object without linking or rebuilding `ecl`. The
  adapter alone speaks a C-shaped ABI: fixed-width tags and integers,
  explicit pointer/length pairs, sized records, callback tables, and
  capability ids. No Zig slice, error union, enum layout, tagged union,
  allocator, or author type crosses the library boundary. The ABI accepts
  exactly one wire version, exact record sizes and strides, and the
  current capability set; changing any of those changes the contract
  rather than invoking a compatibility path, and the binary promise is not
  a supported C author API. Linux and macOS are the loader targets; the
  `.eclmod` suffix is portable naming, not a portable binary.
- **Loading is one consuming typestate.** A Session-owned native instance
  moves through `opened -> described -> validated -> initialized ->
  published`. Each variant owns exactly the library handle, copied
  metadata, callback table, and cleanup operation valid in that phase, and
  a failed transition consumes and cleans its input. Descriptor lengths,
  exact record sizes and strides, the ABI version, canonical names, UTF-8
  documentation, parsed effects, definition uniqueness, callback indices,
  continuation layout, and all counts are validated before instance
  initialization or registry publication can run. The SDK places the
  returned descriptor in addressable image-lifetime storage; an entry
  point never returns a pointer to a comptime value materialized in its
  stack frame. The validator's copied descriptor and current definition
  are optional phase-owned values rather than uninitialized records, so
  every read requires a populated state. Dynamic images load through the
  operating-system loader; Linux runtime artifacts link libc dynamically.
  One module-to-host text ingress owns pointer/null, representability,
  ceiling, and UTF-8 validation for descriptor text, scalar symbols/words,
  callback failures, and entry diagnostics. Character scalars cross the
  shared `Value.unicodeScalar` factory: only U+0000 through U+10FFFF
  excluding surrogate halves can become a native candidate, and every
  UTF-8 encoder consumes that same validated narrowing rather than a
  trapping cast. Validation and metadata materialization are
  cursor-driven. Opening a native library is nevertheless arbitrary-code
  execution at the platform level — library constructors may run before
  ECL can inspect the descriptor — so every directory in an `ECL_PATH`
  used for native loading is a trusted-code boundary.
- **Library lifetime is Session lifetime.** There is no native hot reload
  or early unload. A published instance pins its code image while any
  binding, call transaction, or continuation can reach a callback. Worker
  Units inherit only an opaque `Loader`; that capability can begin
  validation but has no descriptor-settlement, image-close, or
  owner-destruction method. Session consumes the distinct owner through
  `open -> closing -> settled`: closing rejects new call/image lifetimes,
  task quiescence and environment retirement release every pin, and only
  the settled capability can destroy the root after owner-only descriptor
  teardown and library close. A private static transport accepts the same
  generated descriptor for first-party modules, with a no-op code image
  pin; it is not an ECL-in-Zig embedding API.
- **The effect is part of the call type.** A callback's mandatory first
  parameter is exactly `*ecl.Call("inputs -- outputs")`, where the SDK
  parses the fixed successful effect at comptime. That type exposes only
  the declared immutable inputs and accepts exactly the declared number of
  outputs. Word registration adds only the name, nonempty documentation,
  and callback; the descriptor derives its effect and arity from the call
  type, leaving no duplicated declaration to drift. Remaining callback
  parameters must be exact SDK-owned capability types. `@typeInfo`
  validation rejects generic or variadic callbacks, a wrong result,
  optional, unknown, duplicate, or conflicting capabilities, a
  capability/continuation mismatch, and duplicate word names. The SDK
  generates the canonical capability manifest and wire adapter from that
  one signature. Adapter inputs and cursor backing are explicit optional
  states: the factory populates them before the opaque capability can
  expose a pointer, so no callback observes uninitialized scratch in any
  build mode. Unknown capability ids fail loading, and `which`/`see`
  expose the validated native origin and requirements.
- **Calls are transactional leaf operations.** `ValueView` permits
  immutable, O(1) kind, scalar, and aggregate-length observation; it never
  reveals the runtime `Value` or heap storage. `call.forward(i)` and
  `BuildValues` produce issuer-checked candidate outputs owned by the call
  transaction. Complete reserves the exact final stack window before
  atomically replacing the inputs with the effect's output tuple. Yield
  preserves the inputs, transaction, and host-owned aggregate builders.
  Candidate handles are valid for one callback turn only; their roots
  enter bounded retirement at the turn boundary, while a builder retains
  only values already appended to its exact-size storage. Deliberate
  failure, cancellation, deadline loss, OOM, or abandonment leaves the
  operand stack unchanged and transfers tentative roots to bounded
  retirement. Native failures may name only `type`, `shape`, `conform`,
  `overflow`, `domain`, `parse`, `io`, or `user` plus one bounded message;
  the runtime retains authority over underflow, undefined-word, contract,
  cancellation, timeout, word/site/trace attachment, and OOM. The Zig
  callback result is exactly `error{OutOfMemory,InvalidValue}!Outcome`;
  its generated adapter maps complete/failure/yield/OOM to explicit wire
  tags and maps an SDK capability rejection to a language `domain` error
  rather than a process trap.
- **Capability values are ephemeral authority, not a host object.** There
  is no public capability map, lookup by string, raw host-context pointer,
  or allocator. The loader mints each instance's host table from its
  validated requirements, leaving undeclared optional operations null, and
  the adapter exposes only the exact parameters named by a callback for
  one invocation. Comptime state validation recursively rejects ephemeral
  capabilities, `Call`, `ValueView`, and lifetime-incompatible SDK handles
  from module or continuation state; only handles explicitly marked
  durable for that owner may cross a turn. Runtime issuer/generation
  checks remain active in optimized builds. Native machine code is trusted
  and can deliberately escape Zig's safe surface, so these are strong
  supported-API invariants, not a sandbox against malicious code.
- **Rescheduling is a typed `WorkDriver`, not an execution class.** A
  callback requests `Reschedule(ContinuationSpec)`, whose spec fixes its
  private Zig state and explicit bounded destructor. The host owns aligned
  opaque storage and a library pin for that continuation. From its first
  invocation the call advances as the ordinary scheduler-owned driver,
  with one 65,536-unit kernel budget per turn, the normal cancellation
  check, and the same ready-queue and retirement arbitration as
  first-party cursors. Aggregate content is available only through
  budget-charging list cursors (including text and specialized leaves) and
  dictionary cursors; incremental aggregate append/materialization charges
  the same budget, and extension-local loops call `consume`. No raw
  aggregate backing slice, whole-slice public builder, or unmetered SDK
  iterator bypasses that path. Exhaustion yields with the exact
  continuation and builder state; complete/fail/cancel consumes them once.
  Native machine code itself is not preemptible, and the runtime cannot
  infer instruction reductions, so unrelated long computation or blocking
  is a trusted-code violation detected only by per-invocation
  duration/overrun diagnostics.
- **Callbacks are leaf-shaped.** The descriptor and capability enum expose
  no module-state fields or ids. Native callbacks cannot resolve or invoke
  words, evaluate quotations, spawn tasks, re-enter a Session, publish
  definitions, retain ECL values in module state, create opaque ECL
  resource values, wait for an external wake, or submit blocking jobs;
  inline callbacks must return promptly. Native external side effects
  remain outside operand-stack rollback.

## The REPL boundary

TTY detection in `main.entry` is the only editor activation point. `repl`
owns one `line_editor.Editor`; `runStdin`, explicit `-`, file, eval, and
format paths do not construct or call it. On Linux and macOS each physical
read turn saves termios, enters raw mode without flushing queued input,
and drains output before restoring the saved attributes without flushing
typeahead. Restoration precedes returning a tagged `line`, `cancelled`, or
`eof` result — or any error; if restoration fails after line completion,
the still-owned line is destroyed before the terminal error escapes. Other
targets retain a canonical single-line fallback. `OwnedLine` is a nominal
allocator-owned result, and the editor copies its bytes into the
pre-existing pending-unit accumulator before releasing it. Ctrl-C clears
that accumulator; Ctrl-D preserves the clean-primary and
incomplete-continuation outcomes.

The editor owns exactly one thing: which bytes are in the buffer and where
the cursor sits between them. Every other concern is held by the layer
that can decide it, and each boundary is a type rather than a convention.
The governing rule: correlated facts never cross a boundary separately —
an owner-issued value either contains them or exposes the only valid
transition over them.

**Terminal authority is a capability, not a Session.** `readLine` receives
an `EditorTerminal` and a `CompletionObserve`, both opaque handles
carrying the heap-stable session core rather than the address of the
movable `Session` value that minted them. Between them they offer a
prompt, a named terminal effect, a candidate list, name observation, and —
only through a `RowTerminal` obtained from a measured row — single-row
redraw. There is no operation for program output and none that accepts
caller-supplied control bytes, so the editor cannot emit an unescaped
byte. Prompts and effects are enums: a runtime slice trusted by comment is
not trusted.

**The terminal boundary owns geometry, planning, and escaping together.**
`console.zig` measures the row, chooses the window, escapes what it
writes, and places the cursor. Escaping covers malformed, truncated, C0,
DEL, and C1 — C1 because U+0080–U+009F is well-formed two-byte UTF-8 that
a terminal in UTF-8 mode may still act on; decodability is not what makes
a scalar safe to emit. The cursor column is produced by writing the row,
erasing, returning to column zero, and rewriting the prefix, which makes
the terminal compute it. That is sound only while the row cannot wrap, so
three things hold together: sizing uses an upper bound on every unit —
printable ASCII exactly one cell, an escape exactly four per byte, and
every other scalar charged the widest a terminal renders — no unit is ever
forced in when it does not fit, and drawing is reachable only from a
`Columns` value that `geometry` minted. An unmeasurable terminal is
`Geometry.unavailable` and selects the canonical line reader; there is
deliberately no fallback width (guessing a width on a narrower terminal
wraps the row and moves the cursor) and no character-width table (a table
is data no property can validate).

**Bytes and a cursor offset never cross the boundary together.** The
buffer mints a `DisplayView` — the text either side of the cursor — which
is the only place both facts are known, and planning narrows a view into a
view. An offset that does not correspond to its bytes is therefore not
expressible, and the console never slices on an index it was handed.

**Byte storage owns its input, once, for everybody.** `TextBuffer` is the
storage under both the edit buffer and the pending unit. Its fallible
splice copies every source before touching storage and reserves the
result's capacity before writing, so sources may be slices of the very
bytes being replaced and a failure leaves the buffer exactly as it was.
Operations that cannot fail have separate total forms: removal has no
source and only shortens storage; scalar transposition validates two
adjacent UTF-8 ranges and stages at most eight bytes before a same-length
replacement. Neither can allocate, so their signatures carry no impossible
error.

**Byte rewriting is one storage boundary owning the whole transition.**
`EditBuffer` is an opaque handle, not a struct with a private field type,
because Zig's inferred struct literals would let external code build the
latter and hand itself a cursor no storage transition produced. Growth and
arbitrary replacement route through `splice(range, source)`, which
validates, stages, and commits in that order; deletion and scalar
transposition use the total non-growing transitions. Validation belongs at
this boundary because whether a replacement fits depends on the range it
replaces. The cursor is re-derived from the result rather than computed,
because a replacement can form a scalar across either seam and arithmetic
would land inside it.

**Lexical state is minted by the reader and carried with its bytes.** The
reader owns an opaque `PendingUnit` holding the accumulated source and the
tokenizer state at its end. Appending copies the line and reserves
capacity before writing anything, so a caller may pass a slice of the
unit's own storage safely; the state cannot describe different bytes than
the unit holds, and the cost across a unit is linear. The checkpoint type
is private — a public one was constructible from an inferred literal and
could be paired with source that never produced it. Completion asks the
unit itself, passing only the current line, so the editor has nothing to
re-derive lexical state from: a duplicate scanner could disagree with the
lexer, and only ever saw one physical line, which is not a unit of this
language.

Only valid-UTF-8, nonempty physical lines without CR/LF enter the
100-entry history; malformed bytes still reach the reader diagnostic but
cannot corrupt durable history. When HOME is usable, `History` serializes
writers with a sibling lock, rereads and merges the current UTF-8 file
under that lock, and replaces `.ecl_history` atomically with user-only
permissions. Missing or failed persistence never disables the editor; one
stable warning surfaces through Session diagnostics. The raw-mode,
owned-line, locked-history, lease-owning visibility, and completion
capabilities are distinct architectural boundaries.

## The formatter

`formatter.zig` is deliberately separate from the value reader. Its first
layer is a formatter-only CST retaining every trivia, comment, delimiter,
atom, and complete string slice in source order; the ordinary reader
validates the unit, but no code is scheduled. CST assembly and document
lowering are iterative/postorder, matching the reader's full nesting bound
without consuming the host stack. The second layer lowers that CST to a
Wadler/Oppen-style document IR (`text`, concat, soft/hard lines, groups,
alignment, prose fill). The renderer keeps one command stack and performs
bounded, remaining-width lookahead at each group; it never materializes
both flat and broken renderings. Generic containers align at the column
immediately after their opening delimiter. Local nested groups pack each
space-separated structural run, so a hard break in one child cannot
explode its surrounding phrase into one-item lines. Existing source line
boundaries remain hard. Only binders and structurally recognized
definition annotations receive syntax-specific layout; doc paragraphs use
fill rather than one all-or-nothing group. Structurally literal
`def`/`defp`/`set`/`setp` blocks receive matching canonical
`### def <name>` / `### defp <name>` section comments, separated from
preceding material by one empty line.

## Verification

**Three tiers, one of them local.** Verification is deliberately tiered by
cost, because a gate nobody runs proves nothing. `zig build precommit` is the
local tier: Zig and ECL formatting, the source-architecture audit, the binary,
whole-tree semantic analysis, and the fast core of the suite, in about eighty
seconds after a source change. Per-push CI owns the complete matrix, and the
release-candidate matrix owns the exhaustive initialized-Session OOM sweep and
the complete ReleaseFast suite.

The local tier separates *analysis* from *execution*, and that separation is
the load-bearing part. `zig build check` builds every test root — the in-process
suite, the CLI e2e artifact, the native-runtime artifact, the differential
harness, the snapshot transcript, and the OOM root — with `generated_bin` unset,
so each one is fully type-checked while the codegen and link stages never run.
That costs seconds rather than the minutes the same analysis costs when a binary
is emitted, and it means a filtered execution tier never becomes a filtered
*compilation* tier: a stale call in a test the local tier does not run is still
a local failure. Execution is then selected by fully qualified test name, so a
new test in an included source or family joins the tier without a second
manifest, exactly as the `concurrency: ` prefix routes tests into `test-workers`
and `test-tsan`. The excluded families are excluded on measured cost or on
ambient resource — a PTY, a socket, a built native fixture — and `build.zig`
records both the list and the measurement beside it.

**The differential harness.** Every kernel and every idiom entry runs
against the generic frame-machine path on generated inputs, asserting:
value equality, representation parity (brackets), error kind/payload
equality, and bit-identical floats. The scheduler suite runs at 1 worker
and N workers, asserting identical results. This is the cheapest guard on
the entire "fast paths are unobservable" doctrine.

**The typed-kernel proof surface.** `src/tests/kernel_typed_test.zig` guards the
typed seam with four properties the differential harness cannot state, because
that harness compares idiom recognition against its absence rather than typed
storage against boxed storage. Parity builds the same values twice — once as the
specialized leaf a typed loop dispatches on, once through
`list.fromValuesGeneric` — and compares the whole rendered outcome, which puts
values, brackets, string forms, float bits, error kinds, messages, and failing
indexes under one assertion. A bounded-work property counts kernel safe points
for an operation of three quanta, separating a chunked loop from a per-element
one by four orders of magnitude rather than by a tuned constant. A fault-block
property places the first fault in the first, a middle, and the final block and
pins the reported index. A memory bound runs the session under a
`DebugAllocator` live-byte limit of output plus one kernel chunk, and then
starves it below the output to prove the limit is doing work. Registry closure is
asserted independently of the comptime validation, so a validator that stopped
checking shows up as a failing test rather than as silence.

**The stateful-module suite.** `src/tests/stateful_module_test.zig` pins
the Milestone 11 contracts one test per obligation. Its tests carrying the
`concurrency: ` name prefix are routed by the build file into
`test-workers` (1 and 8) and `test-tsan` automatically, so every new
concurrent surface — arbiter ordering, the reload barrier, and the removal
close edge — enters those gates without a second manifest. The
initialized-Session OOM sweep reaches construction stacks, transactional
updates, a mid-draft failure, and removal. Lifecycle coverage keeps
superseded code alive across removal and unrelated module creation,
repeatedly probes old `within`, and proves the replacement's state and code
remain unchanged. Dynamic `execute` supplies the fresh public resolution used
to observe the close edge; cancellation is issued only after that resolution
fails. The counting-allocator property
compares small and large batches of both post-close-cancel/remove and ordinary
construct/remove cycles, each run as one Unit, so more history must not retain
proportionally more memory.

**Snapshots.** The Zig executable is the semantic reference. `zig build
test-snapshots` runs the real CLI over the promoted reference corpus and
compares exact exit status, stdout, and stderr with one checked-in
`ohsnap` transcript. Snapshot changes are intentional review events, and
the same gate is part of `zig build test`.

**Allocation-failure topology.** Focused constructors and other low-level
allocation paths use exhaustive failure injection in the ordinary
`zig build test` suite. Initialized-Session coverage is two coarse probes in
the separate ReleaseSafe `zig build test-oom` release-candidate gate; its
quadratic ordinal replay is intentionally not part of per-push CI. The
established core bundle crosses kernels, primitives, session services,
reflection, source and native loading, native call transactions, modules, and
definition replacement in one deterministic lifetime. The M12 bundle crosses
its embedded data modules and host IO surfaces in another. The build schedules
the two filtered test artifacts independently, so their exhaustive ordinal
replays run in parallel while each bundle remains deterministic. This removes
the quadratic cross-product between two large allocation sets while still
paying for one embedded-prelude bootstrap per bundle rather than per word.
Native fixture code uses the real generated descriptor and public loader. The probes' tagged
cooperative scheduler mode executes the same queue, wait-set, native
continuation, cancellation, publication, and reclamation transitions on
the root thread while starting no worker pool, making ordinal failure
injection a total order instead of depending on which allocator call wins
a thread race; the 1/N-worker suites and TSan separately validate the
threaded executor. `checkAllAllocationFailures` supplies exact
allocated/freed accounting over the standard backing allocator; the debug
test allocator is deliberately not nested underneath this already
exhaustive wrapper. Within the M12 bundle, expensive fixed-work fixtures are
ordered at the tail: embedded data modules precede host filesystem IO, and the
attempted HTTP call is last. This changes no failure site or Session lifetime;
it prevents unrelated later ordinals from repeatedly paying for earlier IO.
Reaching
snippets use the smallest collection that enters each path, because additional
elements add work but no allocation site.

**Terminal acceptance topology.** `zig build acceptance` rejects Debug builds
and owns only the M13-specific ReleaseSafe assertions: the public
definition/module retention soak, the installed-binary soul check, bounded
display rendering, and the source architecture audit. The SourceHut manifest
runs it last. Earlier sequential tasks remain the owners of the general
behavioral, PTY, native, worker-count, fuzz, differential, TSan, and lint
evidence; terminal acceptance does not replay those matrices. The exhaustive
initialized-Session OOM gate runs once for a release candidate rather than on
every pushed commit; focused component OOM probes remain in the ordinary test
task.
The complete behavioral suite runs per push in Debug and in the distributed
ReleaseSafe mode. ReleaseFast disables checks rather than adding a detector,
and ecl does not distribute that configuration, so its per-push gate compiles
the real binary and runs the broad promoted CLI snapshot instead of replaying
every internal test. The complete ReleaseFast suite remains a release-candidate
matrix entry, where mode-specific optimized code generation is still checked.
Repository verification classification includes every native SDK
compile-negative input, including the fixture proving that native effects
cannot declare the source-only `...` after-row.
The root and e2e artifacts contain Minish properties, whose upstream runner
prints a passing summary to stderr. A classified build-only child runner
captures stderr on success and forwards stdout plus every real nonzero or
abnormal-termination diagnostic. This keeps Zig 0.16 from rendering a passing
test artifact as `failed command` without hiding actionable failure output.

**Coverage-guided fuzz topology.** The parser, formatter, shrinkable
arbitrary-byte edit-buffer model, pending-unit accumulator, Session
completion mutation path, durable-history merge path, production scheduler
publication/join path, native-descriptor validator, and native-call
transaction path each have a distinct named build step and exactly one
selected `std.testing.fuzz` entry point. `zig build fuzz` executes all
nine seed corpora as ordinary tests; bounded campaigns invoke
`fuzz-reader`, `fuzz-formatter`, `fuzz-editor`, `fuzz-completion`,
`fuzz-history`, `fuzz-pending`, `fuzz-scheduler`,
`fuzz-native-descriptor`, and `fuzz-native-call` separately, because Zig's
coverage-guided runner selects one fuzz entry point per invocation. CI
therefore cannot report validation of a model or metadata parser as
coverage for the real dynamic loader, generated adapter, scheduler
continuation, and retirement path.

Every coverage-guided test artifact explicitly selects LLVM: Zig 0.16's
x86_64 self-hosted backend accepts `-ffuzz` but emits an empty
sanitizer-coverage PC table, so the build graph requires a backend that
supplies nonempty coverage metadata, and Zig's runner rejects the artifact
before executing inputs otherwise.

The native-descriptor campaign passes arbitrary bounded metadata through
the production validator using valid host-owned backing ranges. Comptime
reflection varies every integer size field in the ABI records, while the
campaign also varies selected counts, callback indices, capability ids,
and module name length; dedicated malformed shared libraries cover entry
results, strided records, and module-written call/scalar/error tags. The
native-call fuzz target selects bounded sequences of public SDK-fixture
calls and runs them through the dynamically linked production CLI,
observing only exit status and ECL output; its coverage runner remains
static because Zig 0.16 cannot map fuzz coverage in a dynamic-musl test
process, while the child still exercises the real loader, generated
adapter, cooperative scheduler, and retirement path. Separate runtime
tests cover one/eight-worker identity, >quantum list and dictionary
construction, spawned-unit loading, malformed wire values, and delayed
shutdown. The TSan gate runs the production-connected tests, and the
delayed-continuation test uses a DebugAllocator to require complete
Session teardown. These are distinct claims; a fuzz campaign alone is not
evidence for worker scheduling, dynamic-loader failure, or allocator
reclamation.

The editor fuzz target is a shrinkable arbitrary-byte/action state
machine. After every operation it compares production bytes and cursor
position with an independent byte-vector model, checks the line limit and
cursor bounds, and, when the whole buffer is valid UTF-8, requires both
slices at the cursor to be valid. Oversized mutations must preserve the
old state; repeated `takeOwned`/deinit transitions run under the
leak-detecting allocator. It requires — independently of whether the rest
of the buffer is well-formed — that the cursor never sits inside a scalar,
and it replaces the buffer with an alias of its own contents (the shape
that makes a naive splice overlap itself). Arbitrary and prompt-relative
row widths, an unmeasurable row, a row too narrow for the prompt, and a
row wider than any line the campaign builds all drive the real console
after every action, into a buffer sized from the expectation so that
writing more than expected fails rather than being skipped. That property
is an exact byte comparison against an independently escaped expectation,
including the framing the console owns, and it confirms the selected
window fits the row it was planned for. The completion fuzzer issues both
arbitrary and known-core queries before the first Unit. The real PTY
corpus separately covers completion before the first Unit, queued lines,
malformed/truncated UTF-8 and escapes, a pasted control sequence that must
be displayed escaped rather than replayed, completion declining inside a
string that opened on an earlier physical line and inside a comment,
error/EOF recovery, exact parseable history, cross-process recall, and
canonical/echo restoration after errors. A seventh campaign drives the
real pending unit, including appending a line borrowed from the unit's own
source, and requires that scanning a unit one line at a time reaches the
same lexical state as scanning it in a single pass.

Two standing rules bound what any one campaign proves. A fuzz result is
evidence only for the exact production seam it invokes — never for
adjacent compiler, libc, or kernel behavior; in-process models cannot
contain kernel-owned state (terminal queues) or calling-convention
corruption. And every foreign function this repository calls must be
declared with the same variadic shape as its C prototype (`ioctl` is
variadic; a non-variadic declaration passes the argument in a register the
callee never reads on AArch64).
