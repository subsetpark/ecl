# ecl — interpreter architecture

Companion to DESIGN.md (which remains the semantics authority) and the
runtime spec's six components. This document says *how* the real
interpreter implements them. Every recommendation here came out of a
literature-grounded research panel plus an adversarial review pass; the
raw research with verified citations is preserved in
`research/interpreter-architecture-panel-2026-08-12.md`. Decision 23 in
DESIGN.md records the semantic rulings this architecture forced.

## The cost model, operationalized

Decision 21's doctrine becomes two enforced rules:

1. **The dispatch loop gets one design pass, then is frozen.** All
   subsequent performance work goes into kernels over specialized flat
   leaves. (K, J, and CBQN all reached their ceilings through kernels,
   not dispatch; the corrected dispatch literature — Rohou et al. CGO
   2015, the CPython 3.14 musttail numbers after Nelhage/Jin — shows
   dispatch technique is worth 1–5% even in bytecode-bound languages,
   and ecl is kernel-bound by design.)
2. **Zig line budget (recalibrated 2026-08-14 for structural type boundaries).**
   Only shipped business-logic Zig is counted, including kernels, the CLI, and
   the formatter. Tests (including inline `test` declarations), fixtures,
   build/source-audit verification tooling, and all target-language ECL source
   are excluded from every ceiling. Excluded Zig remains exactly classified and
   is reported separately by the audit:

   | component | budget | measured |
   |---|---|---|
   | values + RC (value, heap, intern, list, equal, dict, print, poll) | 3,500 | 2,828 |
   | reader (lexer, binder, reader) | 1,900 | 1,433 |
   | machine (machine, spans, prims, root) | 3,000 | 2,246 |
   | modules and registry (env, modules, module_prims, reflection, session) | 2,600 | 1,680 |
   | bootstrap prelude loader | 150 | 80 |
   | combinators | 1,200 | 703 |
   | definition annotations and doc normalization | 1,000 | 602 |
   | CLI and source formatter | 1,900 | 1,374 |
   | kernels and idioms | 5,500 | 4,069 |
   | **business-logic Zig total** | **22,000** | **15,015** |

   These ceilings were raised specifically so nominal IDs, opaque heap
   capabilities, validated publication types, tagged application/scope modes,
   typestate, and mandatory work cursors can remain
   explicit. A limit must not incentivize weakening a type boundary. The audit
   recursively enumerates `src/**/*.zig` and requires every file to belong to exactly one
   business-logic component or uncapped verification input; adding an
   unclassified file fails.
   `src/prelude.ecl` and other ECL code are intentionally not line-counted.
   Runtime sources remain directly under `src/`; test suites and helpers are
   grouped in `src/tests/`, while substantive build-only checks live in
   `src/tools/` behind package-root entrypoints required by Zig.

   The same dedicated source audit lexes `src/prelude.ecl` well enough to
   distinguish comments from multiline strings. It requires each top-level
   definition to be a `### def <name>` / attached comments / body / annotation / matching quoted
   name / `def` block. This source-layout rule deliberately lives in build
   tooling, not a runtime test that searches implementation text.

   The original ~5k came from "the walking skeleton proved the semantics
   fit in 4.6k." That baseline does not transfer, for three independent
   reasons: the skeleton is Rust and the budget was written while host
   choice was deliberately outside the ledger; the skeleton's 480-line
   value layer uses precisely the boxed lists, uninterned symbols, and
   assoc-vector dicts this document's disposition table disqualifies, so
   the real layer's 3.8x is the architecture rather than bloat; and the
   skeleton lacks concurrency, kernels, interning, the scheduler, idiom
   recognition, `load`, and the stdlib, while its 3,026-line `runtime.rs`
   spans what M3 through M6 cover separately here. Evidence that the
   ceiling is a measurement problem and not a sprawl problem: an
   adversarial 40-agent deduplication sweep over the whole tree returned
   about 3% of core, with most candidate abstractions costing more lines
   than they saved.

Deliberately declined, with the evidence trail in the research file:
NaN-boxing, computed goto, musttail dispatch, Ertl stack caching,
superinstructions, quickening/inline caches (v1), a cached execution
view (v1 — it is d.9's cached compiled form for module words, built
there or never),
a custom bucket allocator (v1), biased reference counting, per-unit
heaps with copy-on-send, cycle collection, and all machine-code
generation (permanently, per decision 21).

## Values and memory

- **Mutation is capability-gated.** `Header` is opaque. Allocation yields an
  `InitializingHeader`, uniqueness checking yields a `UniqueHeader`, and only
  those capabilities expose their respective kind-checked mutation operations.
  Immutable readers are representation-specific; there is no public generic
  mutable payload cast or debug-only uniqueness gate.

- **Value = 16-byte two-word tagged cell.** Word 0: payload (i64 / f64 /
  char codepoint / u32 symbol id / u32 word id / heap pointer). Word 1:
  tag. All atoms inline; heap objects only for lists, dicts, tasks.
  NaN-boxing is rejected decisively: full-range int64 with
  overflow-as-error (d.4) cannot live in a 48-bit payload — CBQN can
  NaN-box because BQN numbers *are* f64; ecl is not that language.
  In Rust this is a niche-optimized enum; the data stack is a plain
  `Vec<Value>`.
- **Heap header (16 bytes):** `{ rc: AtomicU32, meta: u32, len: u64 }` —
  meta holds the representation tag and flags. Capacity is an explicit
  field in the leaf payload for v1 (the kdb+ trick of deriving capacity
  from a power-of-two bucket class is deferred along with the custom
  allocator; ride mimalloc/system malloc until profiling demands
  otherwise — a concurrent allocator is the riskiest subsystem in the
  plan and K's tiny one exists because K is single-threaded).
- **Leaf kinds (one frozen enum, shared by header tags, kernel dispatch,
  idiom table, and printer):** GenericSpine, I64, F64, Char1, Char2,
  Char4, Symbol (u32 interned ids — K symbol vectors), Dict, Task, plus
  one reserved tag for a future narrow-mask representation (packed
  bools; representation-only, d.23). Specialization is a
  construction-time header fact, never recomputed by inspection — the
  printer reads a bit.
- **Dicts, K-style:** keys vector + values vector (insertion order for
  free — the columns literally are the table story) + cached per-entry
  hashes + linear scan below ~16 entries, one u32 hash index above.
  Hash must agree with `=`: numerics hash by numeric value (2 and 2.0
  collide), and the whole-dict hash is a commutative combine of entry
  hashes because d.22 equality ignores insertion order.
- **Symbols:** one global append-only intern table; symbol = u32 index;
  words and symbols share the id space with distinct value tags
  (`to-word`/`to-symbol` are tag flips). Concurrent interning locks the
  write path only; reads index the append-only vector lock-free. Symbols
  are never freed (Erlang atom-table precedent and hazard, documented).
- **Provenance lives on the code plane, never on values.** Reader-built
  side tables key spans by list identity + token index. Runtime values
  carry none (the skeleton's span-on-every-Value made an int ~56 bytes);
  code assembled at runtime via cons/compose has no spans and error
  dicts omit position — absence-is-absence (d.22/d.23).

## Bounded work

- **User-sized traversal is an explicit cursor.** There is one cursor-based
  implementation of each algorithm. Scheduler-attached shells own that state
  in a `WorkDriver`, advance at most one accounted quantum, and return the Unit
  to the ready queue with the exact next position and partial result. Blocking
  bootstrap/tool shells may drive the same cursor repeatedly; there is no
  cancellation-only, unlimited, or second synchronous implementation.
- **Iteration and bulk access are coupled to cursor progress.** Index, slice,
  byte, release, and materialization cursors expose bounded chunks and report
  suspension before another quantum. Standard-library bulk operations cannot
  hide unbounded work behind one logical transition.
- **Construction has two approved shapes.** A known-size result is allocated
  exactly once and initialized through a work cursor. An unknown-size result
  uses linked fixed chunks, then materializes exactly once through a work
  cursor. Reader forms, binder output, string provenance, span tables, and the
  session span archive use this substrate; none grows by relocating accumulated
  state or by automatic hash-table rehashing.
- **Bounded probes are lazy.** Formatter group lookahead uses a fixed-capacity
  command stack and expands concatenations one child at a time. Its step and
  stack ceilings apply before child expansion, and width scans stop once the
  remaining line width is exceeded.
- **The build audit enforces the boundary from parsed Zig syntax.** It rejects
  relocating/rehashing provenance storage, whole-traversal charging, optional
  polling helpers in migrated paths, unbounded identifier scans, and allocator-
  backed formatter lookahead. Because the audit examines parsed tokens and
  function spans, comments and string literals cannot evade or spuriously trip
  a rule. Behavioral tests separately prove cancellation through public paths.

Work cursors keep position explicitly and every scheduler-reached traversal
returns at the unit-wide kernel budget. Cancellation is therefore observed no
later than the existing 65,536-element safe-point interval; evaluator fuel
returns movable units to the scheduler between dispatch slices. At the same
boundary a long pure kernel lets the pool execute one other ready slice, which
provides one-worker progress without yielding from inside console or
publication critical sections.

## Typed publication and control state

- Namespace publication accepts `NamespaceName`, produced by the polled
  validator, rather than a raw intern id. Top-level and module publications are
  different tagged types; module callables require `ValidatedEffect`, values
  cannot carry one, and the module-root scope supplies the single coherent home.
- An unpublished module generation is held by an opaque, consumable
  `OwnedCandidate`. Registry publication consumes that capability; rollback
  destroys it. Attempt and module boundaries are distinct tagged-union states,
  so candidate ownership no longer depends on nullable pointers or side-band
  booleans.
- Auto-loading likewise owns a consumable `LoadingLease`. Removal consumes it
  only after success; unwinding retains the capability until the cursor-owned
  cleanup phase. Environment and module resolution expose explicit cursors,
  including shadow and visibility checks, so runtime lookup cannot silently
  select another traversal implementation.
- Public native callbacks return `PrimitiveOutcome`, which atomically carries
  either success or the complete language-failure payload. Trusted builtins use
  a separate callback variant, so public registration cannot return a detached
  `error.Ecl` and crash the dispatcher.
- Core construction is a `BuildingEnv` typestate capability consumed by
  `finish`. Session, core-build, module-root, lazy-local, and owned-local scope
  storage are a tagged union rather than correlated environment/ownership flags.
- Quotation applications use a validated `StackWindow` and tagged in-place or
  isolated mode. The continuation frame owns its trace and immutable driver;
  callbacks return only the next `ApplicationStep`, so they cannot substitute a
  context or destructor. The stronger frame is 80 bytes (formerly 48), an
  intentional ceiling increase for representational safety.

## Reference-counting discipline (Perceus-on-a-stack)

- **Precise atomic counts** (Relaxed increment, Release/Acquire
  decrement — Arc/Swift discipline). The "or shared bit" option is
  struck from the ledger (d.23): a sticky bit never recovers uniqueness
  and permanently defeats CoW's copy-once clause.
- **The stack owns its values.** Push and pop perform *zero* RC
  operations; the dup-family (dup/over) is the sole increment site in
  the evaluator; primitives consume their arguments and increment only
  when storing into a new structure or the env. This is Perceus's
  ownership-passing discipline (PLDI 2021) mapped onto a stack machine,
  and it is what makes rc==1 actually fire on pipeline intermediates.
- **One uniqueness function:** rc==1 read with **Acquire** ordering
  (never Relaxed — an rc==1 Relaxed load does not synchronize with a
  concurrent drop's still-in-flight reads). Used identically by append,
  amend, and every kernel's buffer-reuse check. Nested in-place amend
  requires rc==1 along the whole path (Swift nested-CoW rule).
- **Kernel reuse rule, uniform:** output buffer := left input if unique
  and width-compatible, else right input if unique, else fresh. This one
  rule is where decision 1's "hidden in-place mutation" lives.
- **Publication edges are Release/Acquire:** task-cell completion,
  `env.bind()`, registry swaps — the only points where one unit's writes
  become visible to another.
- **No cycle collector, ever** (d.23): immutable bottom-up construction,
  words resolving by name (never heap pointer), and no closures make the
  heap a DAG. Sole exception: a task returning its own handle into its
  outcome cell — documented bounded leak, no machinery.

## Code representation and dispatch

- **The quotation list is the only code representation in v1.** No
  bytecode, no execution view — after interning, span eviction, and
  lock-free envs, walking the plain list is a load + match per token,
  which the doctrine says is enough. The derived, memoized execution
  view (pre-classified tokens, constant indices, call-site slots) is
  precisely d.9's "cached compiled form" for module words (d.9/d.21d);
  the intra-module binding license permits it, and it is built there,
  later, or never.
- **One switch-dispatch inner loop:** ip/code/env in host locals; the
  frame stack is touched only at word calls, combinator suspensions,
  returns, and unit boundaries. Tail calls overwrite the in-register
  (code, ip, env) triple — TCO is frame reuse (Clinger PLDI 1998), and
  the skeleton's traced_word/TraceEnd machinery is deleted outright.
- **Primitives are ordinary core-env bindings** carrying a primitive
  id/fn pointer; core is the outermost env. This kills string-match
  dispatch, makes shadowing uniform, and gives d.9's module hardening one
  representation to bind against. Each word resolves exactly once per
  execution.

## Environments and late binding

- **Deep binding** (chain search: child → session → core; module → its
  uses → core). Shallow binding/rerooting is rejected as GIL-shaped
  (Baker 1978 requires rerooting to be globally serialized). Chains are
  structurally short because quotations capture nothing.
- **Binding cells:** `def`/`set` replacement publishes one complete immutable
  snapshot atomically: binding, visibility, home, effect, documentation, and
  compiled form. Omitting metadata clears it in the new snapshot; extant
  leases retain the old snapshot's body and metadata until release. Every
  future resolution heals by construction, so late binding needs zero
  invalidation. Shape changes (name create/delete, `uses` edits) bump a
  per-env generation. **The iron law for any future cache: hold the
  cell, re-read the interior every execution; never cache a resolution**
  (PyPy celldict / CPython LOAD_GLOBAL discipline — this closes the
  late-binding hole the adversarial review found).
- **Registry:** name → atomically swapped `{env, generation}`;
  re-registration bumps the generation; commit only after the module
  body succeeds (skeleton-proven). The generation counter doubles as the
  ledger's "binding writes are observable events" and the d.9 checker
  layer's guard. **Module words pin one generation for a whole body** — no
  mixed-generation execution mid-word (Erlang whole-version rule).
- **Single-writer rule (d.23):** only the session thread writes
  session-visible envs; unit bodies write only their disposable child
  scopes. The registry is the one multi-writer table and takes an
  explicit synchronized swap (CAS-retry or write lock). Core is frozen
  after prelude installation — zero synchronization forever after.
- **Lazy child envs:** scope = `{local: Option<EnvRef>, parent}`; the
  child table is allocated only when a `def`/`set` actually executes in
  the scope. Quotations capture nothing and locals compile away, so
  combinator elements essentially never allocate (the skeleton paid an
  Arc+RwLock+HashMap per element).
- **Lock strategy:** no lock on the per-word read path, anywhere.
  Shared structures (core, module envs, registry) publish immutable
  snapshots via atomic pointer swap (arc-swap/RCU discipline);
  unit-local scopes are unsynchronized by ownership.
- **Snapshot retention (M4 as-built; bounded reclamation is a v1
  obligation).** Superseded environment shapes and registry directories
  are currently retained until session teardown — that is what lets the
  lock-free read path dereference them without hazard pointers. Cost
  therefore scales with distinct-name insertions, use-list edits, and
  module commits (rebinds swap cell interiors and retain nothing).
  Acceptable at REPL scale; unbounded for a long-lived session that
  keeps defining names or re-registering modules. v1 must add some
  degree of control before the acceptance milestone: quiescent-point
  reclamation (compact superseded shapes/directories when no unit is
  executing — trivial while single-threaded, epoch/lease-gated once M7
  workers exist) and/or a session word that reports and compacts
  retained snapshots. Binding-cell snapshot chains already reclaim at
  readers==0 and need nothing.

- **Definition annotations:** `definition_prims.zig` recognizes only direct
  top-level word markers in the candidate quotation, validates the entire
  combined effect/doc shape with bounded polling, constructs owned effect
  metadata, and calls the single binding publication funnel only after every
  check and allocation succeeds. Top-level effect metadata does not schedule
  contract frames. Module home transitions still trigger the existing effect
  frame, while same-home tail calls remain frame-neutral. `doc`, `which`, and
  `see` resolve through ordinary leased bindings; canonical `see` rendering is
  poll-aware and combines effect and documentation back into one quotation.
  `doc.zig` normalizes documentation with an exact-size two-pass traversal and
  the machine's structural poller before publication, so formatter-introduced
  physical wrapping never leaks into reflection.

- **Source formatter:** `formatter.zig` is deliberately separate from the
  value reader. Its first layer is a formatter-only CST retaining every trivia,
  comment, delimiter, atom, and complete string slice in source order; the
  ordinary reader validates the unit, but no code is scheduled. CST assembly
  and document lowering are iterative/postorder, matching the reader's full
  nesting bound without consuming the host stack. The second
  layer lowers that CST to a Wadler/Oppen-style document IR (`text`, concat,
  soft/hard lines, groups, alignment, and prose fill). The renderer keeps one
  command stack and performs bounded, remaining-width lookahead at each group;
  it never materializes both flat and broken renderings. Generic containers
  align at the column immediately after their opening delimiter. Local nested
  groups pack each space-separated structural run, so a hard break in one
  child cannot explode its surrounding phrase into one-item lines. Existing
  source line boundaries remain hard. Only binders and structurally recognized
  definition annotations receive syntax-specific layout; doc paragraphs use
  fill rather than one all-or-nothing group. Literal
  `def`/`defp` blocks also receive canonical `### def <name>` section comments,
  separated from preceding material by one empty line.

## The frame machine

- **A unit is a movable heap struct** `{frame stack, data stack, env
  ref, control block}` — decision 10 (no host-stack recursion) already
  made units green; suspension is "stop stepping." This identity between
  the frame machine and the scheduler is the load-bearing synergy of the
  whole design.
- **Frames are ≤80-byte uniform records** (code ref, ip, env ref, kind
  tag, and typed payload). The ceiling was raised from 48 bytes for the
  tagged application mode, immutable continuation driver, and trace ownership.
  Combinator state is indices; saved
  stacks are **base indices into the unit's one contiguous data stack**,
  never moved-out Vecs. Isolation = base-index barrier (underflow check
  is one compare, which also implements decision 14's contract checks);
  rollback and attempt-catch = truncate-to-base, O(1).
- **Boundary frames** (attempt/module) record saved depths and
  form an intrusive chain with a register to the innermost — unwinding
  never scans or interprets frames (crash-only has no finally), it
  truncates.
- **Lazy traces** (CPython 3.11 zero-cost model, PEP 657): no live trace
  vector; an unwind walks frames once, mapping word-body frames to
  qualified symbols and the failing token to its span. Happy path pays
  nothing. TCO means traces show the non-tail spine (d.23).
- **Errors:** `Result<(), Box<EclError>>` through the machine (boxed so
  the happy-path return stays register-sized); host errors convert to
  error dicts only at IO boundary words.

## Kernels

- **Dispatch:** a static (op × leaf-tag) table of monomorphic loops over
  raw slices, selected once per array operation (NumPy ufunc structure).
  Char operands normalize to a common width at kernel entry to contain
  the instantiation matrix. Generic spines fall back to recursive
  descent (host-stack over *data* depth, with a depth guard) whose leaf
  encounters call the same kernels.
- **Broadcast by scalar operand** (stride-0 style), never a materialized
  replicated vector.
- **Fault handling:** overflow/NaN checks accumulate a block mask
  (~64–512 elements), tested once per block; on a hit, a scalar rescan
  identifies the exact element for the error dict. Licensed by
  crash-only rollback (d.23) — computation past the fault is
  unobservable. **When output aliases a stolen input buffer, test the
  mask before the block's stores** (the rescan must read pristine
  input).
- **Order:** grade = range-adaptive counting/radix on leaves (min/max
  prepass shrinks key width; float bit-flip trick is safe because NaN
  cannot exist), stable everywhere; comparison sort on spines. The sort
  idiom runs a direct sort. distinct/group are hash-based.
- **The kernel list is closed and written down** — adding a kernel is a
  design event, and every kernel ships with its idiom-table entry (one
  artifact) and its differential test.
- **Representation parity is a tested invariant:** fused and generic
  paths must produce identical values *and* identical representations —
  d.16 makes brackets observable at the prompt.

## Idiom recognition (the only bridge to the vector unit)

At isolated-combinator entry (each/each2/fold/scan), structurally match
the quotation against a small closed pattern table — `(w)` for a
primitive word, constant-operand forms, the sum/prod compositions — then
**guard by resolving each word against the application env and checking
identity with the expected core primitive**. Guard passes → fused
kernel; fails (user re-defined `+`) → generic path, always semantically
complete. Per-application guard cost is O(quotation length) against O(n)
work: no cache, no invalidation, sound under late binding by
construction (Dyalog's unguarded token idioms are safe only because APL
primitives aren't redefinable; ecl's are). Snapshot semantics are scoped
to this guard alone (d.23) — the generic path keeps full per-application
late binding. Prelude words stay honest source with no dual
representation: `sum = (0 (+) fold)` reaches the sum kernel through
fold's entry recognition.

**Float folds are strictly sequential on every path (d.23).** Only exact
reductions — integer (with fault masks), min/max, boolean — may be
reassociated for SIMD or future multicore. This keeps fused ≡ generic
bit-identical, which is the entire invisibility doctrine. `fsum` is the
future escape valve if float-sum throughput ever matters.

## Vectorization and the parallelism hierarchy

Three levels, each kept in its lane:

1. **SIMD lanes** inside one kernel loop — the default, ~ns/element.
   v1 ships tier 1 only: autovectorization-friendly loop shapes
   (monomorphic, branchless bodies, block fault masks, scalar tails) on
   stable Rust — never nightly `std::simd`. Tier 2 (explicit portable
   SIMD via stable `target_feature`/multiversioning for compress, radix
   histograms, packed compares) and tier 3 (per-ISA variants selected at
   startup — the Highway/ISPC ahead-of-time model, CBQN/Singeli as the
   array-language proof) are profiling-gated, with one authoring
   invariant: every ISA variant of a float kernel implements the
   identical association tree.
2. **Kernel-internal multicore** — deferred entirely (kdb+ waited until
   4.0/2020; grain ~10⁵ elements/thread; memory bandwidth is the
   ceiling per roofline reasoning). The one free concession now: every
   kernel takes an explicit index range, so a future splitter forks
   block ranges without touching kernel bodies.
3. **Units** (`spawn`/`par-each`) — coarse, heterogeneous, IO-bound
   grains, ~µs each. Using level 3 for element-wise arithmetic loses by
   ~1000×; the defense is level-1 kernels being fast, plus docs culture
   (kdb+'s `peach` framing), never runtime warnings. par-each guarantees
   no cross-element rendezvous (d.23), so a chunking [P] override is
   observationally conformant.

**One worker pool** under everything, when level 2 ever lands: units are
scheduled tasks; kernel splits are scoped fork-join subtasks on the same
pool with the caller participating (the OpenMP-inside-TBB /
rayon-inside-tokio oversubscription failure is the thing being designed
out). Kernels never own threads.

## Scheduler

- **Functional core, imperative shell:** `scheduler_core.zig` is an
  allocation-free transition module for unit, wait, registration-ownership,
  and scope decisions. The
  threaded shell owns locks, queues, task payloads, clocks, and handlers, and
  executes only commands returned by that core. Generated Minish traces use
  the same transitions and shrink failing event programs while checking
  exactly-once publication/wake, queue consistency, structured child counts,
  safety, and cancellation-drain liveness. A second generated property drives
  the installed CLI with shrinking scheduler scenarios and a process deadline;
  it covers the imperative registrations and handlers that the pure model
  deliberately cannot observe.
- **Green units on a fixed pool** (default = cores; 1-worker degenerate
  config supported and tested). v1: one mutex-protected global run
  queue — the invariant to protect is "unit is a movable object," not
  the stealing policy; Tokio-style local rings + steal-half are the
  profiled upgrade.
- **Fuel/reduction safe points** (BEAM model): a per-unit counter
  decremented per dispatch step and per kernel chunk (~64K elements —
  kernels are safe-point deserts otherwise, d.23); at zero, check the
  atomic cancel flag, maybe yield, refill. Native work which spans a quantum
  is represented by an owned, type-erased `WorkDriver`; each resume performs
  one bounded slice and returns the unit to the ready queue. A worker never
  runs another unit recursively while retaining the current unit's native
  stack. Attempt, task-outcome, and join-result list construction use the same
  exact-size resumable materializer. Raised-error field lookup and trace
  validation are likewise scheduler-visible cursor work. No signals, ever.
- **Task cells:** write-once, multi-waiter (handles are dup-able
  values), under a small per-cell mutex in v1. `await` parks the unit
  (never blocks a worker); completion moves waiters to run queues.
  **Wake decisions:** one mutexed `WaitSet` policy selects exactly once per
  park, so completion and cancel cannot double-enqueue a unit (a unit on two
  workers corrupts its stacks). The core distinguishes registering,
  selected-before-activation, active, and delivered wait phases. Each cell-list
  entry is a stable owning wake handle in the wait set's exact-size,
  non-relocating registration array, never a borrowed pointer into temporary
  setup storage. Each entry has its own ownership phase and reference count;
  the array remains alive until every entry retires. Completion detaches at
  most 256 handles per scheduler turn; the core separately models directory
  cleanup and delivery return in either order. Wait setup, canonical duplicate
  lookup, loser cleanup, and value-graph retirement are resumable scheduler
  jobs. This is deliberately reference-counted rather than lock-free
  reclamation: the Negele scheduler's processor-local hazard-pointer shortcut
  requires uncooperative regions and processor identity that ecl does not have.
  Cancel must also remove parked units from waiter lists.
- **Structured lifetime:** children list under the per-task mutex, and
  spawn re-checks its own cancel flag after registering each child
  (kill-on-arrival — closes the orphan race). Scope close cancels
  unawaited children and **waits for quiescence** (Trio/JEP 505) before
  reporting its outcome. A cancelled unit's outcome is
  `{'err {'kind 'cancelled …}}` with trace fields when the poll site can
  produce them, absent otherwise.
  Language code cannot call a blocking scheduler wait API: `await`, joins,
  deadlines, and permitted root `exit` all emit typed park requests. The shell
  alone registers and resumes those requests; root-scope blocking exists only
  inside scheduler-owned exit handling and teardown. A root waiter's release
  store is its selector's final access to that stack-owned generation; every
  scheduler pointer and result destination is captured first. This prevents an
  old wake from observing a later root wait at the same stack address.
  Cancellation walks keep a retained next-cell cursor, validate it with a tree
  epoch, and release the tree mutex every 256 cells; mutations restart the
  idempotent walk. Root teardown waits on a scope-owned condition using the
  same scope mutex as the child-count predicate, so final-child notification
  cannot be lost between the predicate check and sleep.
- **Timers:** one lazy timer thread + an indexed binary heap whose pointer
  slots grow in fixed chunks; embedded wait nodes never relocate and removal
  is allocation-free (timing wheels are a scale problem ecl doesn't have).
  **IO:** direct on workers in v1 (scripting
  scale); the committed evolution is the blocking-pool split reusing the
  await machinery unchanged. Console writes take the stdout lock per
  call — whole-write atomicity, satisfying d.11/d.20's interleaving
  contract.
- **Determinism lives at join points**, never in scheduling: program-
  order await and leftmost-error are schedule-invariant; the only
  sanctioned nondeterminism is `await-any` and cross-unit IO
  interleaving. Enforced by running the suite at 1 and N workers.
- **Cold start is a budget** (the soul test: `ecl '3 4 +'` answers
  instantly): no worker threads or timer thread until first `spawn`;
  prelude installation stays bounded; nothing else spins up at launch.

## The differential harness (named v1 deliverable, d.23)

Built before the second kernel exists:

1. Every kernel and every idiom entry runs against the generic
   frame-machine path on generated inputs, asserting: value equality,
   representation parity (brackets), error kind/payload equality, and
   bit-identical floats.
2. The scheduler suite runs at 1 worker and N workers (plus a
   randomized-steal stress mode later), asserting identical outcomes.

This is the cheapest guard on the entire "fast paths are unobservable"
doctrine — most soundness holes the adversarial review found would have
been caught by it.

## Allocation-failure test topology

Focused constructors and other low-level allocation paths use exhaustive
failure injection in the ordinary `zig build test` suite. Initialized-Session
coverage is one consolidated probe in the separate ReleaseSafe
`zig build test-oom` gate. That probe crosses kernels, primitives, session
services, reflection, loading, modules, and definition replacement in one
deterministic lifetime, so each injected failure index pays for the embedded
prelude bootstrap once. `checkAllAllocationFailures` supplies exact
allocated/freed accounting over the standard backing allocator; the debug
test allocator is deliberately not nested underneath this already exhaustive
wrapper.

## What the d.9 hardening layer needs from v1 (the substrate contract)

Exactly two things, replacing five speculative hooks: (1) the binding
struct's reserved slots (doc; effect — populated in v1 by M4's
mandatory module declarations; compiled-form cache — present, unused);
(2) observable binding writes as generation counters (per-env shape
generation + per-module registry generation), already required. The
"cached compiled form" is the deferred execution view: pre-resolved
threaded arrays, guard-free for intra-module references because module
envs are write-once (d.9's binding license), generation-guarded at
`use`/core edges. Nothing in v1 is throwaway and nothing anticipates
beyond these two.

## Skeleton disposition

Dies (unanimous across the panel): span-on-every-Value; `Arc<[Value]>`
leafless lists; `Arc<str>` uninterned symbols; UTF-8 `String` with O(n)
indexing; assoc-vector dicts and O(n²) equality/distinct; string-keyed
primitive dispatch; RwLock-per-lookup envs; clone-checkpoint rollback;
eager trace push/pop and the TraceEnd dance; per-element child-env
allocation; per-token frame push/pop; print-time specialization scans;
`mem::take` substack isolation.

Survives (as proven semantics and, in places, as structure): the frame
machine's shape — explicit frames, no host recursion, all control
effects as frame operations; word ≠ symbol atoms; construction-time
specialization as a concept; the representation-exposing round-tripping
printer; numeric cross-type equality; module home-as-registry-name with
commit-after-success and use-order shadowing; attempt's outcome
protocol; `while`'s two-frame pattern; error.rs's attach-if-absent
context and absence-is-absence dict shape.
