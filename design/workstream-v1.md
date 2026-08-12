# Workstream: ecl v1 — the real interpreter

## Vision

Ship feature-complete ecl v1: a single static binary implementing every
settled decision in `design/DESIGN.md` (d.1–d.23), the full grammar
(`GRAMMAR.md`), and the full vocabulary (`VOCABULARY.md`), built to the
architecture in `ARCHITECTURE.md` — flat leaves, precise atomic RC with
CoW uniqueness, the defunctionalized-CEK frame machine, late-binding
environments with modules and hot reload, the closed kernel surface with
combinator-entry idiom recognition, and green-unit concurrency. v1 is
slow-but-correct everywhere the architecture permits, but never violates
the decision-21 invariants that make it evolvable to K-order later.
Scope additions ruled in during planning: REPL line editing/completion,
and `str`, `json`, and `http` stdlib modules.

## Current State

Verified in the checkout (2026-08-12):

- `design/` holds the complete, internally consistent spec: DESIGN.md
  (23 decisions + implementation-agnostic runtime spec), GRAMMAR.md,
  VOCABULARY.md (~70 [P] + ~15 [E] words with contracts),
  ARCHITECTURE.md (literature-grounded implementation architecture with
  a staged plan, line budgets, and a skeleton disposition table), and
  `research/` (the raw architecture panel, citations verified).
- `poc/rust/` is a **complete-for-its-scope walking skeleton** (~4.6k
  lines, 43 tests green): full grammar, unified values with
  construction-time specialization (chars→string only), pervasion with
  leading-axis broadcast and d.22 float semantics, contract-checked
  combinators, crash-only `attempt` with outcome dicts, chained
  environments with the full d.18 module system (registry, defp/letp,
  qualified access, `use`/`alias`, hot reload), binder lowering, and
  error dicts. Its internals are disqualified for v1 by
  ARCHITECTURE.md's disposition table (span-on-Value, boxed `Arc<[Value]>`
  lists, no leaves, no interning, RwLock-per-lookup envs, eager traces).
- **Verified missing from the skeleton** (grep-confirmed): all
  concurrency (`spawn`/`await`/`await-any`/`await-for`/`cancel`/`tasks`/
  `par-each` — zero occurrences), `flip`/`reshape`/`group`,
  `which`/`see`, `load` + `ECL_PATH` module file transport (zero
  occurrences), `exit`, and any stdlib modules. No line editing (bare
  stdin REPL). No flat leaves, no interning, no scheduler, no kernels,
  no idiom recognition, no differential harness.
- There is **no Zig code in the repo**; the real implementation starts
  from an empty directory.

## Key Challenges

- **The RC/CoW/uniqueness machinery under true parallelism** — precise
  atomic counts, acquire-ordered uniqueness, the Perceus-style stack
  ownership discipline, and publication edges. Subtle, cross-cutting,
  and unproven in the skeleton (which leaned on Rust `Arc`). In Zig it
  is hand-built. Mitigated by d.23's rules being written down and by the
  differential harness.
- **Host = Zig, pre-1.0.** Toolchain churn between Zig versions is
  real; `std.http`/TLS maturity is a known risk for the http module.
  Mitigations: pin the toolchain (`build.zig.zon` + CI), keep the http
  backend decision open until its milestone (see Open Questions).
- **Idiom recognition soundness under late binding** — the guard
  discipline (resolve at combinator entry, snapshot scoped to the guard,
  cache cells never resolutions) is specified (d.23) but easy to erode
  in code. The differential harness is the enforcement mechanism, which
  is why it lands in the same milestone as recognition.
- **Scheduler correctness** — wake tokens (no double-enqueue),
  kill-on-arrival, quiescence at scope close, kernel chunk polls. The
  adversarial review found races in the *paper* design; the code must
  implement the corrected protocols.
- **JSON null in a language with no nil** (see Open Questions) — the
  first time absence-is-absence (d.22) meets an external data model
  that reifies null.

## Established Precedents

Cross-cutting prior art this workstream adopts (all verified during the
architecture panel; full groundings in
`design/research/interpreter-architecture-panel-2026-08-12.md`):

- **[paper] Perceus: Garbage-Free Reference Counting with Reuse (Reinking, Xie, de Moura, Leijen, PLDI 2021)** — https://dl.acm.org/doi/10.1145/3453483.3454032
  The RC discipline for the whole runtime: precise counts, ownership-
  passing (the stack owns values; push/pop do zero RC ops), rc==1 reuse,
  and the guarantee that cycle-free programs are garbage-free.
- **[rfc-spec] PEP 393 — Flexible String Representation** — https://peps.python.org/pep-0393/
  Width-tagged (1/2/4-byte) char leaves with O(1) codepoint indexing;
  named by d.15 and implemented in the value layer.
- **[documentation] CPython zero-cost exception handling + PEP 657** — https://peps.python.org/pep-0657/
  The lazy-trace model: happy path pays nothing; spans live in
  code-plane side tables; traces are built by walking frames at unwind.
- **[pattern] Binding cells + version guards (PyPy celldict; CPython `LOAD_GLOBAL` discipline; PEP 659/699 lineage)** — https://peps.python.org/pep-0659/
  The late-binding-sound caching substrate: hold the cell, re-read the
  interior every execution; generations guard only resolution paths.
- **[documentation] Erlang/BEAM — reduction counting, code loading, refc binaries** — https://www.erlang.org/doc/system/code_loading.html
  Fuel-based safe points, two-generation hot reload semantics
  (whole-body pinning), and shared refcounted immutable buffers across
  share-nothing processes.
- **[pattern] Structured concurrency (Trio nurseries; JEP 505)** — https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/
  Scope trees, cancellation checkpoints, wait-for-quiescence at scope
  close, determinism at join points.
- **[pattern] NumPy ufunc inner-loop dispatch** — https://numpy.org/doc/stable/user/basics.ufuncs.html
  The (op × leaf-tag) table of monomorphic inner loops selected once per
  array operation; stride-0 scalar operands instead of materialized
  broadcasts.
- **[documentation] BQN/CBQN implementation notes (Lochbaum)** — https://mlochbaum.github.io/BQN/implementation/
  Kernel algorithms: range-adaptive counting/radix grade, SIMD-friendly
  fold/scan shapes, blockwise overflow checking, replicate/where
  strategies.
- **[pattern] Dyalog idiom recognition (guarded for ecl)** — https://course.dyalog.com/Interpreter-internals/
  Phrase-level fast paths at combinator entry — with the ecl-specific
  addition that every recognition is guarded by resolution identity,
  because ecl primitives are redefinable and APL's are not.
- **[documentation] ARCHITECTURE.md (this repo)** — design/ARCHITECTURE.md
  The binding synthesis of all of the above into ecl's six runtime
  components; every milestone below implements a named section of it.

## Milestones

### Milestone 1: value-core

**Status**: executed (35 tests; Debug, ReleaseSafe, Linux TSan,
formatting, and blocking ZLint validated). Landed at commit `8295fd5`;
CI green at builds.sr.ht job 1859694 with *instrumented* Linux TSan —
the manifest gained `linux-headers`, since Zig builds its TSan runtime
from source. Review fixes before landing included exact int/float
comparison beyond 2^53, which also patched the poc oracle
(`compare_int_float`, covering ordering comparisons — a fix beyond the
original milestone sketch). ZLint was promoted from advisory to
blocking after the milestone landed clean under it.

**Definition of Done**:
A Zig project exists at the repo root (`build.zig`, `src/`, pinned
toolchain in `build.zig.zon`, CI = builds.sr.ht `.builds/ci.yml` with
blocking fmt/Debug/ReleaseSafe/TSan/ZLint tasks). The value
layer implements ARCHITECTURE.md §Values: the 16-byte tagged value (all
atoms inline; NaN-boxing rejected), the 16-byte heap header with atomic
refcount, flat leaves (i64, f64, char×{1,2,4}, symbol-u32) + generic
spines, construction-time specialization as a header fact, the global
append-only intern table (words/symbols share the id space, distinct
tags), K-style dicts (keys+values vectors, cached hashes, commutative
whole-dict hash agreeing with d.22 equality, linear-scan-then-index),
and iterative (never host-recursive) structural equality, hashing, and
the canonical representation-exposing printer. The one shared
acquire-ordered uniqueness function and the kernel buffer-reuse
convention exist and are unit-tested. Property tests cover print/equality
laws (e.g. `(1 2 3)` prints `[1 2 3]`; `"ab"` equals the char list;
0.0 = -0.0 under both equalities).

**Why this is a safe pause point**:
It is a self-contained library with a green test suite; nothing depends
on it yet.

**Unlocks**: Everything — every other milestone keys off the frozen
leaf-tag enum and the 16-byte cell.

**Established Precedents** (milestone-scoped):
- **[documentation] Zig `std.mem.Allocator` / `@atomicRmw` docs** — https://ziglang.org/documentation/master/ — allocator injection and the atomic ops the RC layer is built from.

---

### Milestone 2: reader

**Status**: executed (55 tests; Debug, ReleaseSafe, Linux TSan,
formatting, and blocking ZLint validated). The reader runs 1,000 seeded
dict-free parse-after-print cases, 500 seeded dict desugar-shape cases,
and an exhaustive allocation-failure sweep. Full structural dict
round-trip remains intentionally deferred to M3, where `dict-of` can
execute.

**Definition of Done**:
The full GRAMMAR.md reader over the new value layer: tokens
(whole-token number classification, `inf`/`-inf`, `0x`, `_` separators,
char literals, strings with escapes, comma-as-whitespace, reserved `;`
and `|`), forms (matched pairs, dict-literal desugar to `dict-of`,
binder lowering to point-free code with the boundary-crossing error),
REPL incomplete-input detection, and **code-plane provenance**: spans in
side tables keyed by list identity + token index, never on values
(d.23). A parse∘print round-trip fuzz test runs in CI. The skeleton's
reader tests are ported as fixtures.

**Why this is a safe pause point**: Reader + values form a parse/print
library with green tests; no evaluator yet.

**Unlocks**: The frame machine has something to execute.

---

### Milestone 3: frame-machine-first-light

**Status**: executed (90 tests across library and real-binary suites;
Debug, ReleaseSafe, ReleaseFast, instrumented Linux TSan, formatting,
and blocking ZLint validated). The 20,000-deep countdown keeps a flat
continuation, and the source audit reports 5,412 core lines under the
5,500-line ceiling. One implementation correction is recorded: exact
top-level rollback retains the immutable entry cells, because a saved
depth cannot recover a pre-existing value consumed before failure;
attempt/dict isolation remains base-index truncation. Post-audit hardening
also locks nested-boundary restoration, substack-relative contract data,
recursive trace multiplicity, attach-if-absent context for `raise`, direct
and flushed `pp`/`prin` output, and single-EOF REPL exit.

**Definition of Done**:
The soul test passes end-to-end: `ecl '3 4 +'` prints `7`. Implements
ARCHITECTURE.md §Frame machine and §Dispatch: unit struct (frame stack,
data stack, env ref, control block with fuel counter and cancel flag —
present now, polled even before the scheduler exists), the single
switch-dispatch loop with ip/code/env in locals, ≤48-byte frames,
base-index substack isolation, boundary frames with O(1) truncation,
TCO as frame overwrite, lazy traces built only at unwind, and error
dicts per d.19. Primitives are core-env bindings with fn-pointer
payloads (a minimal set: stack words, arithmetic via a provisional
scalar path, `pp`/`prin`, `def`/`let`, `if`/`call`/`while`, `attempt`/
`raise`, `exit`, `args`). CLI modes: `-e`, script file, stdin, bare-stdin
REPL with continuation, script-prints-nothing-implicitly (d.22). Cold
start spawns zero threads.

**Why this is a safe pause point**: A working (small-vocabulary)
calculator exists; every later milestone extends a running binary.

**Unlocks**: All semantics work (envs, kernels, combinators) lands
against an executable.

---

### Milestone 4: environments-and-modules

**Definition of Done**:
ARCHITECTURE.md §Environments in full: binding cells (rebind swaps the
interior), per-env shape generations, the single `env.bind()` funnel,
lazy child envs, deep-binding chain resolution, core frozen after
prelude install. The d.18 module system: `module`/`use`/`alias`, dotted
qualified access, `defp`/`letp` (top-level error), registry as
name → atomically swapped `{env, generation}` with commit-after-success
and **whole-body generation pinning**, plus the multi-writer registry
swap protocol. Reflection: `body`, `words`, `which`, `see`. **New over
the skeleton**: `load` (file as one unit) and `ECL_PATH` auto-load on
unregistered `use`, and the native-builtin-module mechanism (modules
pre-registered at startup whose bindings are primitive-backed — the
substrate M9 needs). **New over the skeleton (d.9, re-ruled
2026-08-12)**: module `def`/`defp` are 3-ary — `( body ) ( a b -- c )
'name def` — with the effect quotation shape-validated at registration
(exactly one `--`, word elements), stored in the cell's effect slot,
enforced dynamically through the d.14 contract machinery, and displayed
by `see`/`which`; a module def without a declaration is a registration
error, and top-level `def` stays 2-ary. The d.18 shadow notice: `use`
prints one stderr line per session binding that shadows an incoming
export (informational; `use` succeeds). The skeleton's d.18 test
battery is ported and green (its module fixtures gain declarations).

**Why this is a safe pause point**: The binary is a calculator with a
complete module system; kernels/combinators still run the provisional
paths.

**Unlocks**: M5/M6 idiom guards (resolution identity), M8 completion
(env enumeration), M9 stdlib modules.

---

### Milestone 5: kernels-and-pervasion

**Definition of Done**:
ARCHITECTURE.md §Kernels: the (op × leaf-tag) table of monomorphic
loops generated via Zig comptime, dispatched once per array; pervasion
as spine recursion with leaf fast paths and depth guard; scalar-operand
broadcasts; blockwise fault masks with scalar rescan and the
mask-before-store aliasing rule; d.22 float regime (inf propagation,
NaN-producing ops error). Full structural/order/search vocabulary over
leaves and spines: `at where in find raze cat take drop reverse first
rest range shape len`, **new words** `flip`, `reshape`, `group`, plus
`grade`/`sort` (range-adaptive counting/radix, stable, float bit-flip),
`distinct` (hash), dict kernels (`put del merge has? keys vals` +
key-aligned pervade), and string kernels (`split join format`). Kernel
unit tests plus a cross-implementation differential check against
`poc/rust` for every word both implement.

**Why this is a safe pause point**: All data-plane words work at kernel
speed; combinators still per-element via the provisional path.

**Unlocks**: M6 recognition has kernels to recognize into.

---

### Milestone 6: combinators-and-recognition

**Definition of Done**:
The d.14 combinators (`each each2 for fold scan`) with per-application
contract checks as base-depth compares; inline words (`dip keep bi tri
when`) finalized; the full error/outcome vocabulary (`fail ok? ok!
or-else`); the prelude installed from embedded ecl source ([E] words,
`body` returns the real list). **Idiom recognition** at combinator
entry: the closed pattern table that IS the kernel registry, resolution-
identity guards, snapshot semantics scoped to the guard (d.23), float
folds strictly sequential on every path. **The differential harness**
(named v1 deliverable, d.23) runs in CI: every kernel and idiom entry
against the generic frame-machine path for value equality,
representation parity (brackets), error kind/payload equality, and
bit-identical floats. The skeleton's full 43-test suite is ported and
green against the Zig binary.

**Why this is a safe pause point**: ecl is feature-complete except
concurrency and stdlib; the harness guards everything behind it.

**Unlocks**: M7 (par-each rides spawn), M9 (str module uses kernels +
prelude machinery).

---

### Milestone 7: scheduler-and-concurrency

**Definition of Done**:
ARCHITECTURE.md §Scheduler: green units on a lazily-spun fixed worker
pool (no threads until first `spawn`; 1-worker config supported),
fuel/reduction safe points including kernel chunk polls (~64K
elements), task cells (write-once, multi-waiter, per-cell mutex) with
**CAS'd wake tokens** (no double-enqueue), cancellation with
kill-on-arrival and waiter-list removal, structured lifetime with
wait-for-quiescence at scope close, cancelled outcomes as
`{'err {'kind 'cancelled …}}`, one timer thread + binary heap for
`await-for`, stdout whole-write lock. Vocabulary: `spawn await
await-any await-for cancel tasks` [P] and `par-each` [E] (with the
chunking license, d.23). The determinism suite runs the full test
corpus at 1 worker and N workers asserting identical outcomes. The soul
test still spawns zero threads. Before parallel parsing is enabled, the
M1 intern table's tryLock spin loop is replaced with a blocking mutex so
contending intern writers do not burn worker cores.

**Why this is a safe pause point**: The language surface of DESIGN.md
is complete; only scope-ruled stdlib and REPL polish remain.

**Unlocks**: M9's http module may block on worker threads; M10
acceptance.

---

### Milestone 8: repl-line-editing

**Definition of Done**:
The interactive REPL has line editing, history (persisted to
`~/.ecl_history`), and tab completion sourced from the live env chain +
module registry (public exports; dotted completion for `stats.<TAB>`),
preserving the continuation prompt for open delimiters. Non-tty modes
unchanged.

**Why this is a safe pause point**: Pure additive UX; no semantics
touched.

**Unlocks**: Daily-driver usability; nothing structural.

**Established Precedents** (milestone-scoped):
- **[library] linenoise (antirez)** — https://github.com/antirez/linenoise — the minimal, battle-tested line-editing model; bind it or port its ~800-line core to Zig rather than inventing an editor.

---

### Milestone 9: stdlib-str-json-http

**Definition of Done**:
Three stdlib modules ship inside the binary (embedded sources / native
builtins registered lazily via the M4 mechanism, so the single-binary
story holds; `ECL_PATH` remains for user modules):
- **`str`** — ecl source: `upper lower trim` (ASCII per d.15) and
  friends; the first real embedded-module consumer.
- **`json`** — native: `json.parse` (string → value) and `json.emit`
  (value → string) per RFC 8259; integral in-range numbers → int64,
  else f64; objects → dicts (keys as strings), arrays → lists;
  emission requires string/symbol dict keys ('type error otherwise);
  the null ruling implemented per the resolved Open Question and
  recorded in DESIGN.md as a decision addendum.
- **`http`** — native, client only: `http.get`/`http.post`
  (url [headers-dict] [body] → response dict with 'status, 'headers,
  'body), TLS included, timeouts surfacing as 'io error dicts; blocking
  runs on the unit's worker thread (v1-acceptable per ARCHITECTURE.md
  §Scheduler). Backend per the resolved Open Question.

**Why this is a safe pause point**: Modules are additive; core
untouched.

**Unlocks**: Real scripting workloads (fetch → parse → array-crunch →
emit) — the awk/sed/jq positioning made literal.

**Established Precedents** (milestone-scoped):
- **[rfc-spec] RFC 8259 — The JSON Data Interchange Format** — https://www.rfc-editor.org/rfc/rfc8259 — the parse/emit contract, including duplicate-key and number-precision guidance.

---

### Milestone 10: v1-acceptance

**Definition of Done**:
The terminal acceptance suite below is implemented as a CI job
(fixtures + expect scripts where interactive) and green. README rewritten
around the real binary (install, tour, module guide). The d.23 line
budget is audited by a CI check (core ≤ ~5k lines excluding kernels;
kernels ≤ ~5k). A `v1.0` tag exists.

**Why this is a safe pause point**: It is the end; the tag is the
pause.

**Unlocks**: Post-v1 work (the static effect checker bundle, d.9;
performance evolution toward the K ceiling; exactness revisit) starts
from a proven baseline.

## Dependency Graph

- Milestone 1 (value-core) -> []
- Milestone 2 (reader) -> [1]
- Milestone 3 (frame-machine-first-light) -> [2]
- Milestone 4 (environments-and-modules) -> [3]
- Milestone 5 (kernels-and-pervasion) -> [3]
- Milestone 6 (combinators-and-recognition) -> [4, 5]
- Milestone 7 (scheduler-and-concurrency) -> [6]
- Milestone 8 (repl-line-editing) -> [4]        # parallel with 5–7
- Milestone 9 (stdlib-str-json-http) -> [6]     # http may precede 7; blocking IO is v1-legal
- Milestone 10 (v1-acceptance) -> [7, 8, 9]

## Open Questions

1. **http backend (choice only; procedure is decided).** Which backend
   wins the spike — Zig `std.http.Client` + `std.crypto.tls` (pure Zig,
   no C dependency, maturity risk) or a libcurl binding (battle-tested,
   complicates the static single binary). Resolved by the M9 spike per
   the agreed criteria in Decisions Made. Owner: M9 gameplan.

## Decisions Made

- **Host = Zig** (user ruling, this session). Consequences absorbed
  into the plan: the kernel matrix generates via comptime (replacing
  the Rust macro plan), SIMD tier 1 rides `@Vector` (no nightly-Rust
  caveat), RC/atomics are hand-built on `@atomicRmw` with the d.23
  orderings, arc-swap becomes plain atomic pointer swap over immutable
  snapshots, and `Result<Box<EclError>>` becomes a Zig error union with
  an out-param error dict. ARCHITECTURE.md's mechanisms are host-
  agnostic; its Rust-specific grounding notes stay as history.
- **Fresh implementation at repo root; `poc/rust` frozen as the
  executable semantics oracle.** Its 43 tests become cross-
  implementation fixtures (M5/M6); it is never evolved.
- **Benchmark baseline harness is OUT of v1** (user ruling): v1's gate
  is the differential harness, not numbers. Performance work is
  post-v1, against the invariants v1 preserved.
- **Stdlib ships embedded in the binary**, not via ECL_PATH files —
  single-binary distribution is part of the positioning (d.21).
- **http is client-only in v1.** A server is long-running-process
  territory the positioning explicitly declined (d.20/d.21).
- **JSON null ↔ the symbol `'null`** (user ruling, this session).
  `json.parse` maps null to the ordinary symbol `'null`; `json.emit`
  maps `'null` back. Data, not language nil — d.22's absence doctrine
  is untouched; arrays like `[1, null]` round-trip. Recorded in the
  ledger (d.22 addendum).
- **http backend is chosen by spike, not by guess** (user ruling, this
  session): at M9 planning, `std.http` wins if it handles TLS 1.3
  against 5 real-world hosts including redirects and chunked encoding;
  otherwise bind libcurl.
- **Toolchain pinned: Zig 0.16.0** (resolved at M1 planning, closing the
  former open question). Pinned in `build.zig.zon`
  (`minimum_zig_version`) and by the CI tarball; revisited only at
  milestone boundaries and at the M9 http spike.
- **Forge and CI: sourcehut** (M1 planning ruling). The repo is
  `git.sr.ht/~subsetpark/ecl` (unlisted; flip with
  `hut git update --visibility public`); CI is builds.sr.ht via
  `.builds/ci.yml`. Every milestone's CI additions land in that
  manifest — the workstream's earlier generic "CI" references mean
  builds.sr.ht.
- **Strictness posture, workstream-wide** (user directive at M1
  planning): blocking first-party gates — `zig fmt --check`, Debug +
  ReleaseSafe test matrix, a ThreadSanitizer test variant,
  leak-detecting `std.testing.allocator` in every test,
  `checkAllAllocationFailures` on every allocating API, comptime layout
  asserts, else-less switches over frozen enums — plus pinned ZLint
  with `--deny-warnings`. Download, checksum, errors, and warnings all
  fail the lint gate. Later milestones inherit this harness rather than
  re-deciding it.

## Definition of Done (Acceptance Suite)

All `cmd` assertions run the release binary `ecl`; fixtures live in
`test/acceptance/`. Interactive (`ux`) assertions run under an expect
script in CI.

- **DoD-1 — soul test**
  - **Assert**: `ecl '3 4 +'` prints `7` and exits 0, spawning no
    worker threads.
  - **Verify by** `cmd`: `ecl '3 4 +'`; thread probe via the platform's
    process inspector in the same test.
  - **Expected**: stdout `7`, exit 0, thread count 1.
  - **Traces to**: Milestone 3 — the dispatch loop (`src/machine.zig`) + CLI (`src/main.zig`); lazy pool guard Milestone 7.

- **DoD-2 — unified value printing**
  - **Assert**: `(1 2 3)` and `[1 2 3]` are the same value and print
    specialized.
  - **Verify by** `cmd`: `ecl '(1 2 3)'` and `ecl '(1 2 3) [1 2 3] match'`.
  - **Expected**: `[1 2 3]` and `1`.
  - **Traces to**: Milestone 1 — `src/list.zig` (construction
    specialization) + `src/print.zig` (representation-exposing printer).

- **DoD-3 — ragged pervasion**
  - **Assert**: pervasive `*` recurses through ragged nesting.
  - **Verify by** `cmd`: `ecl '[[1 2] [3]] 10 *'`.
  - **Expected**: `([10 20] [30])`.
  - **Traces to**: Milestone 5 — pervasion spine recursion.

- **DoD-4 — mask vs match equality**
  - **Assert**: `=` is pervasive, `match` is whole-value.
  - **Verify by** `cmd`: `ecl '[1 2] [1 2] ='` and `ecl '[1 2] [1 2] match'`.
  - **Expected**: `[1 1]` and `1`.
  - **Traces to**: Milestone 5 — comparison kernels; Milestone 1 —
    `src/equal.zig` (structural `match` and hash).

- **DoD-5 — overflow is an error with element identification**
  - **Assert**: int overflow inside a leaf kernel raises `'overflow`
    naming the operation, not a wrapped result.
  - **Verify by** `cmd`: `ecl '9223372036854775806 [1 2] +'`.
  - **Expected**: exit ≠ 0; stderr error dict with `'kind 'overflow`.
  - **Traces to**: Milestone 5 — blockwise fault masks.

- **DoD-6 — float regime**
  - **Assert**: `inf` is a literal that propagates; NaN-producing ops
    are `'domain`; `0.0`/`-0.0` agree under `=` and `match`.
  - **Verify by** `cmd`: `ecl 'inf 1 +'`; `ecl 'inf inf -'`;
    `ecl '0.0 -0.0 match'`.
  - **Expected**: `inf`; exit ≠ 0 with `'kind 'domain`; `1`.
  - **Traces to**: Milestone 2 — `src/lexer.zig` (inf/-inf float
    literals); Milestone 5 — float_result kernels.

- **DoD-7 — contract violation names the element**
  - **Assert**: an arity-violating quotation under `each` errors
    immediately with `'kind 'contract` and the element index.
  - **Verify by** `cmd`: `ecl '[10 20] (dup) each'`.
  - **Expected**: exit ≠ 0; error dict with `'kind 'contract`, data
    naming element 0 and effect `( a -- b )`.
  - **Traces to**: Milestone 6 — combinator contract checks.

- **DoD-8 — mask-filter idiom**
  - **Assert**: `where`/`at` filtering works end-to-end.
  - **Verify by** `cmd`: `ecl '[5 -3 8 -1] dup 0 > where at'`.
  - **Expected**: `[5 8]`.
  - **Traces to**: Milestone 5 — where/at kernels.

- **DoD-9 — recognition is unobservable (the harness)**
  - **Assert**: for every idiom-table entry, fused and generic paths
    produce identical values, identical representations (brackets),
    identical error dicts, and bit-identical floats — including
    `[0.1 0.2 0.3] 0 (+) fold` (sequential float ruling).
  - **Verify by** `cmd`: `zig build differential` (the harness CI job).
  - **Expected**: exit 0, zero divergences reported.
  - **Traces to**: Milestone 6 — the differential harness + idiom guards.

- **DoD-10 — late binding defeats recognition**
  - **Assert**: re-`def`ing `+` makes `(+) fold` take the generic path
    with the user's semantics.
  - **Verify by** `cmd`: fixture `redefined-plus.ecl`:
    `(pop pop 42) '+ def [1 2 3] 0 (+) fold pp`.
  - **Expected**: `42`.
  - **Traces to**: Milestone 6 — resolution-identity guards.

- **DoD-11 — module privacy and body-extraction honesty**
  - **Assert**: privates are reachable from publics, unreachable
    qualified, and extracted bodies lose private context.
  - **Verify by** `cmd`: fixture `modules-privacy.ecl` (the d.18
    battery: `'m (40 's letp (s 2 +) 'f def) module m.f pp` then
    `'m.f body call` at session).
  - **Expected**: `42` printed; then exit ≠ 0 with
    `'kind 'undefined-word`, `'word 's`.
  - **Traces to**: Milestone 4 — registry resolution + visibility.

- **DoD-12 — hot reload heals all access paths**
  - **Assert**: re-registering a module updates qualified, `use`d, and
    aliased callers.
  - **Verify by** `cmd`: fixture `hot-reload.ecl` (ports
    `poc/rust/examples/modules.ecl`).
  - **Expected**: outputs `11 21 31 12 22 32` (one per line).
  - **Traces to**: Milestone 4 — registry generation swap.

- **DoD-13 — ECL_PATH auto-load**
  - **Assert**: `use` of an unregistered module loads `<name>.ecl` from
    `ECL_PATH` and retries.
  - **Verify by** `cmd`: `ECL_PATH=test/acceptance/modules ecl "'stats use [1 2 3 4] zscore pp"`
    where `test/acceptance/modules/stats.ecl` defines and exports
    `zscore`, and no module was registered beforehand.
  - **Expected**: the expected z-score vector printed; exit 0.
  - **Traces to**: Milestone 4 — module file transport.

- **DoD-14 — REPL crash-only rollback with env survival**
  - **Assert**: a failing REPL line restores the stack but keeps prior
    `def`s; a `let` inside `each` does not leak.
  - **Verify by** `ux`: expect script — enter `10`, then `20 + missing`,
    then `inspect`; then `[1 2 3] (dup 'k let k *) each pop k`.
  - **Expected**: after the error the stack shows `10`; the final line
    errors `'undefined-word` for `k`.
  - **Traces to**: Milestone 3 — unit rollback (`src/session.zig`); Milestone 4 — child-env isolation.

- **DoD-15 — grammar negatives**
  - **Assert**: mismatched delimiters and top-level `defp` are errors.
  - **Verify by** `cmd`: `ecl '[1 2 3)'` and `ecl '(1) (x) 'x defp'`.
  - **Expected**: exit ≠ 0 with `'kind 'parse`; exit ≠ 0 with
    `'kind 'domain`.
  - **Traces to**: Milestone 2 — `src/reader.zig` (matched-pair
    enforcement); Milestone 4 — defp legality.

- **DoD-16 — UTF-8 codepoint semantics**
  - **Assert**: `"café" len` is 4; `\a 1 +` is `\b`.
  - **Verify by** `cmd`: both one-liners.
  - **Expected**: `4`; `\b`.
  - **Traces to**: Milestone 1 — `src/list.zig` (PEP 393 width-tagged
    char leaves, O(1) codepoint indexing); Milestone 5 — char
    arithmetic kernels.

- **DoD-17 — new array words**
  - **Assert**: `flip`, `reshape`, `group`, `grade` work per
    VOCABULARY.md, `grade` stably.
  - **Verify by** `cmd`: fixture `array-words.ecl` covering
    `[[1 2] [3 4]] flip`, `[1 2 3 4 5 6] [2 3] reshape`,
    `[1 2 1 3] group`, stability probe on equal keys.
  - **Expected**: fixture's expected output file matches exactly.
  - **Traces to**: Milestone 5 — flip/reshape/group/grade kernels.

- **DoD-18 — spawn/await outcome protocol**
  - **Assert**: `spawn`+`await` delivers the same outcome shape as
    `attempt`; `await` is idempotent.
  - **Verify by** `cmd`: `ecl '(1 2 +) spawn dup await pop await ok! call'`.
  - **Expected**: `3`.
  - **Traces to**: Milestone 7 — task cells.

- **DoD-19 — cancellation and timeout**
  - **Assert**: `cancel` yields `{'err {'kind 'cancelled …}}`;
    `await-for` on a slow task yields `'kind 'timeout`.
  - **Verify by** `cmd`: fixture `cancel-timeout.ecl` (spins a
    `while`-loop unit, cancels it; awaits a sleeper with a 50ms
    deadline).
  - **Expected**: both error kinds observed; exit 0 (the script handles
    outcomes).
  - **Traces to**: Milestone 7 — cancel flags, safe points, timer thread.

- **DoD-20 — par-each determinism and leftmost error**
  - **Assert**: `par-each` results are in program order and a failing
    element re-raises the leftmost `'err`; output is identical at 1 and
    N workers.
  - **Verify by** `cmd`: fixture run twice with `ECL_WORKERS=1` and
    `ECL_WORKERS=8`; diff outputs.
  - **Expected**: identical stdout both runs; the designated leftmost
    error surfaces.
  - **Traces to**: Milestone 7 — join-order determinism.

- **DoD-21 — REPL editing and completion**
  - **Assert**: tab completes `sq` → `sqrt` at the prompt; history
    recalls the previous line; open delimiters continue.
  - **Verify by** `ux`: expect script driving a pty.
  - **Expected**: completion inserted; up-arrow recall works;
    continuation prompt appears after `(1 2`.
  - **Traces to**: Milestone 8 — line editor + env-sourced completion.

- **DoD-22 — json round-trip**
  - **Assert**: `json.parse` maps objects/arrays/numbers per the
    ruling; `json.emit ∘ json.parse` is identity on a canonical corpus;
    non-string-keyed dicts refuse to emit.
  - **Verify by** `cmd`: fixture `json.ecl` over a corpus file
    including nested objects, `null`, integral and non-integral
    numbers; plus `{1 2} json.emit` expecting `'kind 'type`.
  - **Expected**: corpus round-trips byte-identically; the emit error
    fires.
  - **Traces to**: Milestone 9 — json native module.

- **DoD-23 — http client**
  - **Assert**: `http.get` against a local fixture server returns a
    dict with `'status 200` and the body; a refused connection yields
    `'kind 'io`.
  - **Verify by** `cmd`: CI starts a local static server; fixture
    `http.ecl` gets a known file and one dead port.
  - **Expected**: status/body asserted; the dead port errors `'io`
    without crashing the interpreter.
  - **Traces to**: Milestone 9 — http native module.

- **DoD-24 — str module via embedded stdlib**
  - **Assert**: `'str use "hello" str.upper` works with no ECL_PATH
    set.
  - **Verify by** `cmd`: `ecl "'str use \"hello\" str.upper pp"` in an
    empty environment.
  - **Expected**: `"HELLO"`.
  - **Traces to**: Milestone 9 — embedded stdlib registration (mechanism Milestone 4).

- **DoD-25 — line budget**
  - **Assert**: core (excluding kernels, stdlib, and tests) ≤ 9,500
    lines and every component inside its ARCHITECTURE.md row; kernels
    ≤ 5,500; stdlib ≤ 2,200 (10% grace over the re-derived d.23
    budget). Core excludes `test` blocks wherever they appear and
    excludes test-only sources (`*_test.zig`, `testgen.zig`).
  - **Verify by** `cmd`: `zig build test` (the embedded audit in
    `src/value_test.zig` prints the split and fails the build when a
    component exceeds its row).
  - **Expected**: exit 0 with the per-component counts printed.
  - **Traces to**: Milestone 10 — the audit test (budget: d.23,
    re-derived for the Zig host 2026-08-12).

- **DoD-26 — module effect declarations (d.9)**
  - **Assert**: a module `def` without an effect declaration fails
    registration; a declared effect is enforced dynamically at
    application; the declaration is visible via `see`.
  - **Verify by** `cmd`: `ecl "'m ( (dup +) 'bad def ) module"`;
    `ecl "'m ( (dup +) ( a -- b c ) 'lies def ) module 1 m.lies"`;
    `ecl "'m ( (dup +) ( a -- b ) 'dbl def ) module 'm.dbl see"`.
  - **Expected**: exit ≠ 0 with `'kind 'domain` (missing declaration);
    exit ≠ 0 with `'kind 'contract` (observed `( a -- b )` ≠ declared
    `( a -- b c )`); `see` output includes `( a -- b )`.
  - **Traces to**: Milestone 4 — module `def`/`defp` declaration
    validation + the d.14 dynamic enforcement hook.
