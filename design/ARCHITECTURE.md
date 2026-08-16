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
   are excluded from every ceiling and from line measurement. Source coverage
   still classifies first-party Zig so production files cannot evade the
   architectural checks, but test and tooling line totals are not a metric:

   | component | budget | measured |
   |---|---|---|
   | values + RC | 4,200 | 3,731 |
   | reader | 3,300 | 2,451 |
   | machine | 5,600 | 5,495 |
   | modules and registry | 4,400 | 4,203 |
   | bootstrap prelude loader | 150 | 86 |
   | combinators | 1,200 | 748 |
   | definition annotations and doc normalization | 1,000 | 901 |
   | primitive documentation | 300 | 159 |
   | CLI and source formatter | 1,900 | 1,428 |
   | kernels and idioms | 8,500 | 5,590 |
   | scheduler and concurrency | 3,500 | 2,662 |
   | **business-logic Zig total** | **30,000** | **27,454** |

   The M7 recalibration supersedes the earlier 22,000 total and 5,500 kernel
   ceilings. Scheduler-safe kernels, task joins, failure unwinding, snapshot
   reclamation, and failed-result release now represent user-sized work with
   nominal cursor/ownership states instead of native-stack traversal. Keeping
   the earlier limits would require recombining those states or restoring
   synchronous teardown, contrary to the structural and scheduler-quantum
   invariants. The 30,000 total and 8,500 kernel ceilings preserve room for
   those explicit boundaries; they are enforced ceilings, not growth targets.
   A limit must not incentivize weakening a type boundary. The audit
   recursively enumerates `src/**/*.zig`, `test/**/*.zig`, and root-level Zig
   build inputs and requires every file to belong to exactly one business-logic
   component or uncapped verification manifest; adding an unclassified file
   anywhere in those first-party roots fails.
   `src/prelude.ecl` and other ECL code are intentionally not line-counted.
   Within mixed production files, the AST-aware counter starts at exported,
   comptime, and entry declarations and follows top-level identifier
   references. It excludes inline `test` declarations, declarations gated by
   `builtin.is_test`, and private top-level helpers reachable only from
   verification code.
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
  releases only the provisional guard. Tasks spawned before commit carry
  independent generation pins, so rollback cannot destroy the embedded module
  scope until those tasks and their child scopes quiesce. Unit and generation
  lifetime use the same nominal embedded-scope teardown cursor, which retains
  its owner until dependent child scopes have propagated their releases.
  Attempt and module boundaries are distinct tagged-union states,
  so candidate ownership no longer depends on nullable pointers or side-band
  booleans.
- Auto-loading likewise owns a consumable `LoadingLease`. Removal consumes it
  only after success; unwinding retains the capability until the cursor-owned
  cleanup phase. Environment and module resolution expose explicit cursors,
  including shadow and visibility checks, so runtime lookup cannot silently
  select another traversal implementation.
- Public native callbacks return `PrimitiveOutcome`, which atomically carries
  either success or the complete language-failure payload. Trusted builtins use
  a separate callback variant. Registered callbacks receive an opaque
  `NativeMachine` exposing only semantic stack operations; they cannot obtain a
  `Unit`, module home, generation pin, or reclamation domain. Public
  registration therefore cannot return a detached `error.Ecl`, manufacture an
  independently escaping generation lifetime, or mutate scheduler reclamation.
- Core construction is a `BuildingEnv` typestate capability consumed by
  `finish`. Session, core-build, module-root, lazy-local, and owned-local scope
  storage are a tagged union rather than correlated environment/ownership flags.
- Dictionary storage is `initializing | ready`, and the ready payload always
  carries keys, values, and hashes plus one optional owned index slice. There is
  no separately mutable initialized bit, nullable payload, or pointer/length
  pair for reclamation and lookup to reconcile.
- Heap values carry nominal `ListHandle`, `DictHandle`, and `TaskHandle`
  pointers. Allocation returns kind-specific initializing capabilities and
  publication consumes the matching capability, so a list cannot be passed to
  task storage or a constructing dictionary observed through a ready handle.
- Native continuation ownership retained across a yield is represented by an
  optional or tagged owner (`Accumulator` distinguishes borrowed, owned, and
  transferred). Driver teardown does not consult a side-band transferred or
  owned boolean. Short-lived transfers use the same `OwnedValue` capability as
  long-lived continuations.
- Operand removal exposes only `popValue() -> OwnedValue` to evaluators. Raw
  stack extraction is reserved for stopped-unit scheduler cleanup, and the
  source audit rejects its use by primitives or kernels.
- Quotation applications use a validated `StackWindow` and tagged in-place or
  isolated mode. The continuation frame owns its trace and immutable driver;
  callbacks return only the next `ApplicationStep`, so they cannot substitute a
  context or destructor. The stronger frame is 80 bytes (formerly 48), an
  intentional ceiling increase for representational safety.
- Fallible continuation insertion consumes an `OwnedFrame` capability only
  after storage growth succeeds. Failure leaves the same capability with the
  caller, eliminating the prior implicit "append also deinitializes" contract.
- Task result publication exposes only `constructing`, a stable active
  `TaskExecution`, or a published terminal outcome/OOM state. The execution's
  evaluating/finishing union is worker-private, so advancing a materialization
  cursor cannot race a waiter reading the cell's publication tag. No phase can
  carry an unrelated unit, materializer, or terminal payload.

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
  execution. Host-registered primitives must carry both a validated effect
  and nonempty documentation; registration normalizes and copies the borrowed
  documentation into the same immutable binding snapshot used by `doc`,
  `which`, and `see`.

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
- **Snapshot reclamation (M7 as-built).** Binding snapshots, environment
  shapes, and registry directories use announced reader leases. Pointer
  publication, reader announcement, and the writer's zero-reader check are
  sequentially consistent, placing the handoff in one total order: a reader
  either protects the old snapshot before reclamation or observes the new
  pointer. The last departing reader detaches a retired chain under the writer
  lock and publishes its head to the shared retirement domain after unlocking;
  it never walks or frees that chain. Each retirement turn destroys one typed
  snapshot/directory record and requeues its successor. Superseded chains are
  therefore reclaimed once their announced readers drain without imposing
  history-sized work on the final reader or writer. One generated property
  drives the production `snapshot.Publisher` through arbitrary acquire,
  publication, observation, and release traces. A barrier-controlled
  reader/writer/reclaimer proof first holds an old production binding lease
  while publications replace it, then acquires another production cursor before
  a barrier-released publication and advances the actual shared retirement
  domain while that cursor remains live. All three participants continue in
  concurrent loops; the instrumented TSan step covers acquisition, publication, and reclamation
  together, while the test observes stable binding values through public
  leases. A counting-allocator property
  then holds a real environment shape lease and a real registry `Directory`
  lease while exercising use-order changes, alias churn, and distinct-module
  publication; after those leases drain, live bytes remain bounded by current
  state rather than update count. Module slots use the same handoff for
  generation leases; reclaimed generation records return to a registry-owned
  free list, bounding both record storage and later commit scans by peak
  simultaneously retired generations rather than total reloads.
  `GenerationLease` is a narrow nominal observation capability: it exposes
  identity metadata and cursor factories, not the mutable environment, scope,
  reference count, or retirement operations. Session execution may consume it
  into a distinct `ExecutionGeneration` only with the Session-private
  `ExecutionAccess` capability; neither observation type returns a raw
  `ModuleHome`. Only a `Unit` lifetime guard can turn that execution home into
  an independent `GenerationPin`, registered native callbacks receive no such
  authority, and Session shutdown joins/tears down every Unit before destroying
  the issuing host domain. Each resolve/name cursor takes
  its own `GenerationPin`, so releasing the originating lease cannot retire
  the generation while the cursor still holds an environment snapshot.

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
- **One owned stack handoff:** a `WorkDriver` cannot mutate the operand stack
  with its result. It returns `WorkProgress.output`, transferring the value to
  the evaluator, which destroys the producer and performs the sole fallible
  stack commit through `pushOwned`. That operation consumes the value whether
  append succeeds or fails: success transfers it to the stack; append OOM
  retires it directly into the allocator-scoped `ReleaseDomain`. It never
  destroys the graph on the failing native stack or creates a second cleanup
  owner. Known multi-output
  resumptions reserve their complete stack window before transferring either
  output. The parsed source audit identifies driver functions by their
  `WorkProgress` return type and rejects direct stack pushes, a second
  result-push API, or synchronous release inside `pushOwned`. All other
  production components receive a `StackReservation` for exact-size,
  non-fallible writes or call the machine's consuming stack API; the source
  audit rejects direct operand-stack mutation outside `machine.zig`.
- **Parking payload ownership is defined by the request type.** `ParkRequest`
  and `ParkResume` expose the sole projections for their owned value graph and,
  for requests, their selected task sequence. Wait registration, abandonment,
  and deinitialization do not repeat tag-to-payload ownership switches.
- **Join result teardown owns one heap root:** evaluator-owned join
  accumulation uses an exact-capacity `OwnedValueBuffer`. Abandonment retires
  the buffer's single
  generic-spine root, and the shared release domain traverses its results later;
  the fixed tagged teardown state sequences only the task input, result root,
  optional raised value, and terminal disposition. That disposition
  distinguishes continuation from OOM. A terminal language failure consumes
  those same fixed roots through one bounded cleanup advance before leaving
  the evaluator; abandoned Units use the scheduler teardown cursor. No
  result-sized loop survives.
- **`par-each` owns construction and joining without dictionary authority.**
  Its public primitive installs a `WorkDriver` that owns the input sequence,
  quotation, and exact task buffer. Each slice publishes the unchanged
  quotation with an explicit borrowed seed; initialization retains that seed
  as the child's sole initial stack value. Completion transfers the task list
  into the evaluator's ordered join state. The join state is a private tagged
  machine representation, not a private binding, and name resolution has no
  privileged core-access mode.
- **Runtime retirement has one allocator-scoped owner.** `ReleaseDomain` is the
  sole value-graph walker and bounded external-retirement scheduler. Dropping `OwnedValue` performs only the refcount
  transition and intrusively queues a zero-count object; scheduler/root turns
  drain that queue in fixed chunks. `OwnedValueBuffer` gives partially filled,
  exact-capacity result construction the same constant-time abandonment rule;
  `OwnedValueChain` links fixed generic-spine chunks for unknown-size reader
  results while preserving a single retirement root.
  Typed intrusive retirement nodes also own snapshot chains, fixed reader
  chunks, abandoned source drivers, binding cells, environments, scopes, and
  module generations; their generated adapter advances one bounded cleanup
  step and requeues unfinished work without allocating. Final generation
  release changes typestate and enqueues work; it never destroys an environment
  or releases a parent scope under the registry publication lock. Unit and
  `ModuleGeneration` use the same `Scope.EmbeddedTeardownCursor`: its
  `waiting_for_children` phase retains the embedded owner's stable reference
  until every heap child has propagated its parent release, then its typed
  retirement phase advances the scope and environment before final owner
  destruction. Queued cleanup therefore cannot retain a pointer into freed
  unit or generation storage.
  Work-driver, application-frame, and fallback destructors receive the domain
  explicitly, and reader/binder/kernel materializers retire into it on
  abandonment. Unit OOM/exit teardown pops continuations and operands through
  a scheduler-owned cursor instead of looping on the evaluator stack. Blocking
  teardown does not accept a free-standing cleanup argument. Root-owned
  `Env`, `Registry`, `SpanArchive`, and `Scheduler` expose only opaque,
  consumable root identities. Each identity points to module-private backing
  state containing the one `HostCleanup` issued at construction; no public
  root field can replace that capability after allocation. Their constructors
  derive both the allocator and retirement domain from the private capability,
  and teardown destroys the backing through the same owner before consuming
  the identity. They expose no independently mutable allocator/domain/host
  triple. A compile-time root-shape check requires the opaque handle/private
  state split and the single host capability. Synchronous
  reader, binder, prelude, and formatter entry points use the same seam rather
  than accepting a second allocator and validating it dynamically. Scopes and
  reader cursors expose
  resumable retirement, and chunk stores obtain their allocator from their own
  storage rather than from a caller. None exposes a `(target, arbitrary host)`
  pair. The mismatched-owner state therefore cannot be formed at a teardown
  call, in any optimization mode. Scheduler-owned
  destructors receive only the domain. Production has no synchronous
  `releaseValue`/`decRef` adapter that can pair an arbitrary value with an
  unrelated host; owned values retire through their construction domain.
  Allocator-only compatibility cleanup exists solely in test builds. The
  synchronous reader likewise requires caller-supplied host authority and
  returns `HostParsed` bound to that exact authority.
  `HostParsed.deinit` derives and drains its issuing owner, while cursor and
  scheduler code receive `Parsed`, whose API exposes only `RetireCursor`.
  Blocking versus resumable parsed teardown is therefore selected by type.
  Copy-on-write replacement swaps the destination's old representation into
  the consumed source wrapper and retires that wrapper through the caller's
  shared domain; representation adoption has no allocator-only blocking
  adapter. Every classified production file passes the
  same AST-aware ownership/destructor checks; adding a component cannot omit it
  through a second hand-maintained list. The audit rejects legacy `_owned`
  identifiers, any reintroduced `ReleaseCursor`, and a blocking-cleanup
  capability or synchronous value drop in release-capable destructors, while
  the type signatures catch indirect blocking container destruction. The
  classification-driven audit rejects `HostOwner` in production outside the
  Session, CLI, formatter, and heap host boundaries and rejects every
  production function outside the heap authority factory that combines
  `HostCleanup` with an erased pointer cast. Behavioral tests may
  create a host explicitly; allocator-only compatibility cleanup is compiled
  only into test builds.
- **Observation and execution capabilities do not expose host ownership.**
  `Env` returns a copyable opaque `EnvironmentView`, never a mutable
  `*Environment`; its API is limited to snapshot leases, lookup/name cursors,
  generation observation, and owned name materialization. Snapshot leases
  carry the same observation identity rather than exporting their environment
  pointer. Scheduler host state and worker execution state are distinct:
  `Scheduler` alone retains `HostCleanup` and owns settlement, shutdown, wake
  detachment, and backing destruction, while units, task scopes, and OS
  threads receive only `*const WorkerScheduler`. The worker facade has private
  allocator/domain execution resources but neither host cleanup authority nor
  a lifecycle method. `SessionCore` likewise stores only its `HostOwner` and
  derives allocator and release-domain borrows; compile-time representation
  checks reject cached correlated fields, host authority in worker state, or
  lifecycle methods on the worker facade.
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
  idempotent walk. Two-pass task snapshots retain a pass epoch independently
  of their optional next-cell cursor, including the yield between count and
  collection; any intervening spawn or unlink restarts the whole snapshot.
  The session root environment scope is a lazily allocated stable handle, not
  inline optional storage: child reference-count traffic therefore never
  aliases the session thread's write-once root-handle read, and moving the
  `Session` value cannot invalidate a child scope parent.
  Root teardown waits on a scope-owned condition using the
  same scope mutex as the child-count predicate, so final-child notification
  cannot be lost between the predicate check and sleep.
- **One fair work contract:** cooperative execution and every worker use the
  same persistent `ExecutorArbitration` state. When ready and retirement work
  coexist it alternates one queue entry with one retirement quantum, and a
  contending worker never blocks behind the active retirement cursor. Ready
  tasks, cancellation walks, wait delivery, unit teardown, value graphs,
  reader chunks, and snapshot records therefore share progress without either
  queue starving the other. `Session` stores an opaque state handle rather
  than exposing raw mutable `Environment` or `Registry` aliases. Its public
  API does not return environment or generation leases coupled to its private
  reclamation domain. Every public definition/module/alias mutation owns a
  guard that acquires blocking host authority and settles root retirement on
  all exits, even while the only worker is occupied; cold native registration,
  public definition, and root evaluation therefore cannot return an idle
  Session with a stranded backlog.
- **Timers:** one lazy timer thread + an indexed binary heap whose pointer
  slots grow in fixed chunks; embedded wait nodes never relocate and removal
  is allocation-free (timing wheels are a scale problem ecl doesn't have).
  `await-for` captures its absolute monotonic deadline before lazy timer startup
  and stores it in the `WaitSet`'s arbitration state. Every later completion or
  cancellation candidate is reclassified as timeout once that deadline has
  passed. A final timestamp check after heap insertion removes an expired node
  before the wait mutex is released, so allocation, lock contention, and thread
  creation can neither extend a short timeout nor let a later candidate win.
  **IO:** direct on workers in v1 (scripting
  scale); the committed evolution is the blocking-pool split reusing the
  await machinery unchanged. Console writes take the stdout lock per
  call — whole-write atomicity, satisfying d.11/d.20's interleaving
  contract.
- **Determinism lives at join points**, never in scheduling: program-
  order `await-all` outcomes and `par-each` leftmost-error are
  schedule-invariant. `await-all` is the source-defined `(await) each` fan-in;
  the public `par-each` primitive transfers its tasks directly into the
  evaluator's ordered one-result, suffix-cancellation, and re-raise state.
  No internal join word exists. The only sanctioned
  nondeterminism is `await-any` and cross-unit IO
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
prelude bootstrap once. Its tagged cooperative scheduler mode executes the
same queue, wait-set, cancellation, publication, and reclamation transitions
on the root thread while starting no worker pool. This makes ordinal failure
injection a total order instead of depending on which allocator call wins a
thread race; the 1/N-worker suites and TSan separately validate the threaded
executor. Deadline setup remains in the sweep through a pending task selected
before a far deadline, while public scheduler tests cover actual timeout
selection. `checkAllAllocationFailures` supplies exact
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
