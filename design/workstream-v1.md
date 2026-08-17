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
the `str`, `csv`, `json`, `table`, and `http` stdlib modules, and optional
target-specific native extension modules loaded by the stock binary. Core and
stdlib retain the single-binary distribution guarantee; `.eclmod` artifacts
are explicitly installed trusted dependencies, not required runtime pieces.

## Current State

Verified in the checkout (2026-08-16):

- `design/` holds the complete, internally consistent spec: DESIGN.md
  (23 decisions + implementation-agnostic runtime spec), GRAMMAR.md,
  VOCABULARY.md (~70 [P] + ~15 [E] words with contracts),
  ARCHITECTURE.md (literature-grounded implementation architecture with
  a staged plan, line budgets, and a skeleton disposition table), and
  `research/` (the raw architecture panel, citations verified).
- The real Zig interpreter is implemented through M4 at commit
  `2bf6c56`: flat values and CoW containers, the full reader, the
  defunctionalized frame machine and real CLI, chained environments,
  and the complete d.18 module/registry/hot-reload system. Its M4 suite
  records 119 tests across library/cross-layer and real-binary coverage;
  Debug, ReleaseSafe, ReleaseFast, named Linux TSan, formatting, and
  blocking ZLint are green, including builds.sr.ht job 1859966. The
  audited core is 6,361/9,500 lines, with machine 2,289/2,300 and
  modules/registry 1,104/1,300.
- `poc/rust/` remains a **frozen, complete-for-its-scope walking
  skeleton** (~4.6k lines, 44 tests green): full grammar, unified values
  with construction-time specialization (chars→string only), pervasion with
  leading-axis broadcast and d.22 float semantics, contract-checked
  combinators, crash-only `attempt` with outcome dicts, chained
  environments with the full d.18 module system (registry, legacy
  `defp`/`letp` spelling,
  qualified access, `use`/`alias`, hot reload), binder lowering, and
  error dicts. Its internals are disqualified for v1 by
  ARCHITECTURE.md's disposition table (span-on-Value, boxed `Arc<[Value]>`
  lists, no leaves, no interning, RwLock-per-lookup envs, eager traces).
- The real Zig interpreter is now implemented through M8 in the current
  checkout (on the M7 base at commit `6c7c970`). Its closed data plane includes
  pervasive leaf kernels,
  sequence/shape/order/group operations, immutable dict updates, Unicode
  text kernels, kind reflection, cycling/count-vector sequence operations,
  the awk-floor transcendentals, exact whole-value `cmp`, and the separate
  frozen-Rust differential job, isolated and inline combinators, guarded
  phrase recognition, and the documented embedded target-language prelude.
  Its ordinary lists, ordered dicts, `group`, `at`, `where`, `flip`, folds,
  and pervasive kernels provide the data-plane substrate for tabular work;
  no table module or table runtime kind exists. M7 adds green units,
  structured task lifetimes, cancellation/deadlines, deterministic joins,
  bounded retirement, and one/eight-worker acceptance. The source audit
  reports 29,184/30,000 shipped business-logic Zig lines. M8 adds scalar-safe
  TTY editing, locked atomic 100-line history, snapshot-safe live and dotted
  completion, continuation cancellation/EOF behavior, and a real-binary PTY
  gate while leaving non-TTY input unchanged. M9 native extensions and M10
  stdlib remain future milestones.
- All derived core words now live in `src/prelude.ecl`; the loader embeds and
  evaluates that ordinary source with retained provenance before freezing the
  core. Every definition is a documented `### def <name>` block. A standard
  library word belongs here when its source definition is compact or when its
  performance does not justify a host idiom; only a substantial definition
  with a justified host fast path remains wholly primitive.

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
  discipline (match at each application boundary, resolve every referenced
  word in the generic path's scope/home, require the expected core builtin or source
  identities, and retain no resolution cache) is specified (d.23) but easy
  to erode in code. The differential harness is the enforcement mechanism,
  which is why it lands in the same milestone as recognition.
- **Scheduler correctness** — wake tokens (no double-enqueue),
  kill-on-arrival, quiescence at scope close, kernel chunk polls. The
  adversarial review found races in the *paper* design; the code must
  implement the corrected protocols.
- **JSON null in a language with no nil** (see Open Questions) — the
  first time absence-is-absence (d.22) meets an external data model
  that reifies null.
- **Validated tables without a table runtime kind** — the stdlib must make
  a useful columnar contract over ordinary dicts while remaining honest that
  core dict operations can forge invalid candidates. Every `table.*` boundary
  therefore validates the convention; no evaluator, kernel, reflection, or
  serialization path may grow hidden table behavior.
- **Trusted native code without an untyped host back door** — a separately
  compiled callback cannot be preempted or made memory-safe by the VM, while a
  dynamic ABI cannot rely on Zig's source-level layouts. The extension SDK must
  nevertheless make effects, capabilities, ownership, continuation state,
  publication, and teardown exact at comptime or load time;
  expose no raw stack, environment, allocator, scheduler, or reclamation root;
  and make the supported aggregate path obey the same bounded-work contract as
  first-party kernels. The irreducible trust boundary and the v1 HTTP blocking
  exception must remain visible rather than being disguised as reductions.

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
- **[documentation] Erlang NIFs** — https://www.erlang.org/doc/apps/erts/erl_nif.html
  The cautionary scheduler precedent: ordinary native code is not preempted;
  cooperative timeslice consumption/rescheduling and dirty schedulers are
  distinct remedies. ECL adopts a typed cooperative continuation first and
  leaves blocking-pool offload as an additive capability.
- **[documentation] Janet C API and native modules** — https://janet-lang.org/capi/
  The ergonomic precedent for loading trusted native modules into a small
  language runtime. ECL narrows that model to one Zig-authored artifact per
  module, with generated capability and ownership adapters rather than a broad
  mutable VM pointer.
- **[pattern] Sized records with additive tails (protobuf unknown fields; Vulkan `sType`/`pNext` chains)** — https://protobuf.dev/programming-guides/proto3/
  Every record carries its own byte size, a reader takes
  `min(declared, sizeof(local))`, and unrecognized trailing bytes are ignored
  rather than trusted. This is the rule that lets ABI major 1 accept additive
  minor revisions, so an older `.eclmod` keeps loading on a newer v1 runtime.
  M9 freezes it in the wire contract and M10's CSV and JSON modules ride the
  same descriptor.
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
dict-free parse-after-print cases, 500 seeded structural dict round-trip
cases, and an exhaustive allocation-failure sweep.

**Definition of Done**:
The full GRAMMAR.md reader over the new value layer: tokens
(whole-token number classification, `inf`/`-inf`, `0x`, `_` separators,
char literals, strings with escapes, comma-as-whitespace, reserved `;`
and `|`), forms (matched pairs, inert even-paired dict literals,
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
continuation. After the Zig line budget was re-derived at `a49881c`, the
source audit reports 5,158 core lines under the 9,500-line total ceiling,
with the machine component at 2,185/2,300. One implementation correction
is recorded: exact
top-level rollback retains the immutable entry cells, because a saved
depth cannot recover a pre-existing value consumed before failure;
attempt/dict isolation remains base-index truncation. Post-audit hardening
also locks nested-boundary restoration, substack-relative contract data,
recursive trace multiplicity, attach-if-absent context for `raise`, direct
and flushed `pp`/`prin` output, and single-EOF REPL exit.
REPL stack display and `pp` now use delimiter-preserving K-style row breaks
for rectangular matrices and nested matrix groups; `str` remains compact, and
the displayed form is reparsed in the runtime suite to prove round-trip.

**Definition of Done**:
The soul test passes end-to-end: `ecl '3 4 +'` prints `7`. Implements
ARCHITECTURE.md §Frame machine and §Dispatch: unit struct (frame stack,
data stack, env ref, control block with fuel counter and cancel flag —
present now, polled even before the scheduler exists), the single
switch-dispatch loop with ip/code/env in locals, ≤80-byte frames (raised from
48 for typed application modes and immutable continuation drivers),
base-index substack isolation, boundary frames with O(1) truncation,
TCO as frame overwrite, lazy traces built only at unwind, and error
dicts per d.19. Primitives are core-env bindings with fn-pointer
payloads (a minimal set: stack words, arithmetic via a provisional
scalar path, `pp`/`prin`, `def`/`set`, `if`/`call`/`while`, `attempt`/
`raise`, `exit`, `args`). CLI modes: `-e`, script file, stdin, bare-stdin
REPL with continuation, script-prints-nothing-implicitly (d.22). Cold
start spawns zero threads.

**Why this is a safe pause point**: A working (small-vocabulary)
calculator exists; every later milestone extends a running binary.

**Unlocks**: All semantics work (envs, kernels, combinators) lands
against an executable.

---

### Milestone 4: environments-and-modules

**Status**: executed (119 tests: 106 library/cross-layer and 13
real-binary; Debug, ReleaseSafe, ReleaseFast, the named TSan suite,
formatting, and blocking ZLint validated locally; Linux CI enables the
TSan instrumentation). Landed at commit `2bf6c56`; builds.sr.ht job
1859966 is green. The audited result is 6,361 core lines under the
9,500-line ceiling, with modules and registry at 1,104/1,300 and the
machine at 2,289/2,300. Generation and binding leases reclaim displaced
payloads after the last owner releases them; the multiwriter fixtures
cover both repeated and disjoint module names.

**Definition of Done**:
ARCHITECTURE.md §Environments in full: binding cells (rebind swaps the
interior), per-env shape generations, the single `env.bind()` funnel,
lazy child envs shared by every isolated boundary, deep-binding chain
resolution, core frozen after prelude install. The d.18 module system:
`module`/`use`/`alias`, dotted
qualified access, `defp`/`setp` (top-level error), registry as
name → atomically swapped `{env, generation}` with commit-after-success
and **whole-body generation pinning**, plus the multi-writer registry
swap protocol. Reflection: `body`, `doc`, `words`, `which`, `see`. **New over
the skeleton**: `load` (file as one unit) and `ECL_PATH` auto-load on
unregistered `use`, and the native-builtin-module mechanism (modules
pre-registered at startup whose bindings are primitive-backed — the
static substrate M10 reuses after M9 replaces the public callback seam).
**New over the skeleton (d.9, re-ruled
2026-08-12, supplemented after M6)**: module `def`/`defp` consume a body
plus a unified annotation whose effect portion is mandatory —
`( body ) ( a b -- c : "Documentation." ) 'name def`. The annotation is
shape-validated before registration and its effect/doc portions are stored in
the binding snapshot,
enforced dynamically through the d.14 contract machinery when execution
enters a word from outside its home module, and displayed by
`see`/`which`. Same-home calls are not bracketed, so internal and tail
recursion stay constant-space under the pinned module activation; the
post-v1 static checker owns internal word-to-word verification. A module
def without an effect is a registration error. Top-level `def` permits no
annotation, effect only, documentation only, or both; its effects are
reflective metadata rather than dynamic call frames. The d.18 shadow notice: `use`
prints one stderr line per session binding that shadows an incoming
export (informational; `use` succeeds). The skeleton's d.18 test
battery is ported and green (its module fixtures gain declarations).

**Why this is a safe pause point**: The binary is a calculator with a
complete module system; kernels/combinators still run the provisional
paths.

**Unlocks**: M5/M6 idiom guards (resolution identity), M8 completion
(env enumeration), M9 native module publication, and M10 stdlib modules.

---

### Milestone 5: kernels-and-pervasion

**Status**: executed in the working tree (source totals are reported by
`zig build source-audit`). Debug, ReleaseSafe, ReleaseFast,
the named TSan suite, formatting, blocking ZLint, all 44 frozen Rust
tests, and the CLI oracle differential are green locally. The audited
pre-kernel core is 6,990/9,500 lines (values/RC 2,248/2,300;
machine 2,290/2,300; modules/registry 1,300/1,300; bootstrap prelude
29/100), and the closed kernel component is 3,571/5,500 production
lines. Its seven-patch design and formal contracts are complete; the durable
implementation contract now lives in this workstream and the design documents.

**Definition of Done**:
ARCHITECTURE.md §Kernels: the (op × leaf-tag) table of monomorphic
loops generated via Zig comptime and dispatched once per flat operation,
reusing `value.HeapKind` as the sole tag domain. Kernel entry consumes
owned operands and returns one owned result; low-level loops take
explicit half-open ranges and poll at most every 65,536 logical
elements. Pervasion is guarded spine recursion with leaf fast paths,
scalar extension, leading-axis conformability, and dict key-union/value
alignment. Checked blocks use fault masks, scalar rescan, and the
mask-before-store aliasing rule; d.22 float semantics reject NaN-producing
operations and preserve exact mixed-number comparisons. Full
numeric/logic, structural/order/search vocabulary works over leaves and
spines: `at where in find raze cat take drop reverse first rest range
shape len`, **new words** `flip`, `reshape`, `group`, `type`,
canonical `str`, `to-dict`, the early source-defined `wrap`/`pair`,
list `put` (functional element update, same word as dict
put, CoW-in-place when unique), the awk-floor transcendentals
`exp log sin cos atan2`, and `cmp`
(three-way whole-value ordering, ruled 2026-08-12: −1/0/1,
non-pervasive — `cmp` is to `<` what `match` is to `=`; numbers exact,
chars by codepoint, strings codepoint-lexicographic, all else `'type`),
plus stable `grade`/`sort` ordering by exactly `cmp`'s order,
hash-backed `distinct`, dict kernels (`put del merge has? keys vals`),
and Unicode string kernels (`split join format`). Two semantics
rulings from the 2026-08-12 gap scan land here: `take` beyond length
cycles the data (K), and `where` generalizes from 0/1 masks to counts
(each index replicated count times, K).
Kernel unit tests cover every path and allocator failure; a separate CI
job compares every shared M5 word with the untouched `poc/rust`, while a
real-binary fixture locks Zig-only `flip`/`reshape`/`group`/`cmp` plus the
post-freeze supplemental vocabulary and extended `put`/`take`/`where`
semantics.

The M5 `wrap`, `pair`, and `sort` bindings are ordinary target-word bodies
assembled by Zig as temporary bootstrap scaffolding. They are not new
primitives; M6 moves their authoritative definitions into ecl source.

**Why this is a safe pause point**: All data-plane words work at kernel
speed; combinators still per-element via the provisional path.

**Unlocks**: M6 recognition has kernels to recognize into.

---

### Milestone 6: combinators-and-recognition

**Definition of Done**:
The d.14 combinators (`each zip-with for fold scan`) plus `infra` with
per-application contract checks as base-depth compares; the full
inline Control/Cleave surface finalized (`dip keep bi tri bi2 both
when unless times cond`, `case` as prelude — the Joy/APCL capture
ruled 2026-08-12, VOCABULARY.md correspondence note); the full
error/outcome vocabulary (`fail ok? or-raise or-else`); the prelude
installed from embedded ecl source ([E] words including `filter`,
`partition`, `any?`, `all?`, `both`, `bi2`, `case`, `unless`,
`signum`, `clamp`, `empty?`, `append`, `pack` (literal-count effect
inference per d.9), `zip`, `min-of`, `max-of`,
`at-path`, `at-or`, `pairs`, plus compact former primitives `over`, `compose`,
`str`, `dip`, `mod`, `neg`, `abs`, `<>`, `<=`, `>=`, `and`, `or`, `first`,
`rest`, `reverse`, `distinct`, and `vals`; `body` returns the real list); and pure reader
reification through `parse` [P].

**Conditional clauses use one flat, exhaustive shape.** `cond` consumes a
nonempty `2n+1` list of quotations: alternating test/action slots followed
by a mandatory else quotation. It prevalidates the entire list before
running a test; each test must leave exactly one 0/1 boolean, the first true
test selects its adjacent action, and `[()] cond` is the no-op-else case.
`case` uses the parallel shape `( subject [key action ... else] -- …)`, but
its left slots are inert Values rather than predicate quotations. It
prevalidates every action/else quotation, compares keys left-to-right with
whole-value `match`, permits duplicate keys with the first match winning,
and executes exactly the selected action or else after consuming the
subject and clause list. Word-, quotation-, list-, dict-, and numeric-valued
keys are never resolved or called merely because they occupy a key slot.

**The target-language prelude is authoritative.** `src/prelude.ecl` is
embedded in the binary at build time; `src/prelude.zig` is only its
bootstrap loader and contains no derived word bodies. Startup installs the
irreducible primitives, kernels, and module primitives into the writable
core, initializes the provenance archive, reads the embedded bytes through
the ordinary reader, retains the parsed root and span tables, and evaluates
the unit on an empty stack in a dedicated root scope whose writable
environment is the core environment. Bootstrap must succeed and leave the
stack empty before core is frozen. All M5 host-assembled words (`wrap`,
`pair`, and `sort`) and every audited compact composition move into this
source together with the remaining [E] vocabulary; `pack` is defined there as
`() swap (cons) times` once `times` is installed. Complex,
performance-sensitive `zip-with`, `range`, `to-dict`, `has?`, `del`, and
`merge` remain primitives. Calls and `body` therefore see ordinary late-bound ecl words,
and failures in their bodies retain the embedded `prelude.ecl` provenance.
The loader never consults the filesystem or `ECL_PATH`. Parse, evaluation,
or stack-balance failure is an interpreter bootstrap defect, exercised by
the build/test suite (including the named exhaustive `test-oom` gate), rather
than a recoverable user-program load error.

**Definition metadata is one ordinary annotation.** The supplementary M6
patch unifies effects and documentation as `(before -- after : "doc")`
quotation data immediately beneath the name. A direct top-level `--` or `:`
recognizes a candidate; nested markers and `'--`/`':` remain inert. Validation
is complete before binding publication, including allocation and bounded
polling. Top-level definitions may carry either portion independently; module
`def`/`defp` still require an effect and may add documentation. `set`/`setp`
remain data-only. The immutable binding snapshot owns body, effect, and doc so
replacement clears omitted metadata while old leases remain valid. `doc`
uses normal qualified/shadowing resolution, and `see` emits one canonical
re-readable combined annotation. The exact names `--` and `:` are reserved on
every namespace-introduction path (including locals and native registration)
without preventing their use as ordinary word values.

Every prelude definition begins with the exact section header
`### def <name>`, followed by attached comments, its body, documented annotation, matching quoted
name, and `def`. Fixed successful effects are declared; quotation- or
count-dependent definitions use documentation-only annotations. A dedicated
build source audit scans comments, quotations, and multiline strings to
enforce this layout without turning source substrings into runtime tests.

Exhaustive failure injection is stratified by cost. Focused low-level probes
remain in `zig build test`; initialized-Session paths share one ReleaseSafe
probe under `zig build test-oom`, preserving kernel, primitive, reflection,
loader, module, and metadata-publication coverage without independently
replaying the embedded prelude for each surface.

**`parse` is the pure reader boundary.** `( string -- q )` UTF-8-encodes the
character vector, invokes the ordinary reader with source name `<parse>`,
and returns all top-level forms in order as one unevaluated generic
quotation. The returned root and nested span tables move into the Session
provenance archive, so a later `call` reports `<parse>`. Non-string input is
`'type`; malformed and incomplete source are `'parse`; cancellation and OOM
leave no partial result. Encoding, lexer/parser scans, binder lowering, and
result/span materialization poll inside their actual traversals. This adds
no host capability: `slurp`, `spit`, `getenv`, and the source-defined
`lines` remain absent until M10.

**Idiom recognition** uses one context-parameterized exact-phrase matcher,
not a combinator-only switch plus special cases. Phrase shape may be
arbitrarily longer than one word, while the initial closed registry covers
the direct, `each`, `zip-with`, `fold`, and `scan` contexts; direct application
of `(dup grade at)` is the motivating source-body case. At application time
every exposed pattern word resolves in exactly the scope/home the generic path
would use and must be the expected core builtin or source binding. The matcher
retains no cache: any structural mismatch, shadow, redefinition, or
ineligible context falls through to the untouched late-bound frame-machine
path. Private host callbacks are selected only by this matcher and have no
public binding or reflective surface. Float folds remain strictly sequential
on every path (d.23).
**The differential harness** (named v1 deliverable, d.23) runs in CI: every
kernel and idiom entry against the generic frame-machine path for value
equality, representation parity (brackets), the same success/failure outcome,
and bit-identical successful floats, with a required fast-path hit so fallback cannot
pass vacuously. The skeleton's full 44-test suite is ported and green
against the Zig binary.

**Why this is a safe pause point**: ecl is feature-complete except
concurrency and stdlib; the harness guards everything behind it, and the
derived core vocabulary now has one inspectable target-language source of
truth rather than host-encoded bodies.

**Unlocks**: M7 (par-each rides spawn), M10 (str module uses kernels +
prelude machinery).

**Established Precedents** (milestone-scoped):

- **[documentation] Gforth — “Forth is written in Forth”** — https://gforth.org/manual/Forth-is-written-in-Forth.html — keep the host kernel small and express the extensible language layer in the language itself.
- **[documentation] Julia system images** — https://docs.julialang.org/en/v1/devdocs/sysimg/ — a precompiled image can later improve startup without replacing source as the semantic authority. For ecl this remains a profile-gated post-v1 optimization, not an M6 deliverable.

---

### Milestone 7: scheduler-and-concurrency

**Definition of Done**:
ARCHITECTURE.md §Scheduler: green units on a lazily-spun fixed worker
pool (no threads until first `spawn`; 1-worker config supported),
fuel/reduction safe points including kernel chunk polls (~64K
elements), task cells (write-once, multi-waiter, per-cell mutex) with
single-winner wait-policy transitions (no double-enqueue), cancellation with
kill-on-arrival and waiter-list removal, structured lifetime with
wait-for-quiescence at scope close, cancelled outcomes as
`{'err {'kind 'cancelled …}}`, one timer thread + binary heap for
`await-for`, stdout whole-write lock. Vocabulary: `spawn await
await-any await-for cancel tasks par-each` [P] and `await-all` [E]. The
bounded `par-each` driver represents each captured element directly as the
child Unit's one-value initial stack, publishes tasks without synthesizing or
copying quotations, and transfers them to an evaluator-owned ordered join
state. No private join word is installed. The determinism suite runs
the full test corpus at 1 worker and N workers asserting identical outcomes.
The soul test still spawns zero threads. Before parallel parsing is enabled, the
M1 intern table's tryLock spin loop is replaced with a blocking mutex so
contending intern writers do not burn worker cores. **Snapshot
reclamation (v1 obligation recorded at M4):** superseded environment
shapes and registry directories are retained until teardown in the
M4 as-built (ARCHITECTURE.md §Environments, snapshot retention); this
milestone must make reclamation worker-safe — quiescent-point or
epoch/lease-gated compaction of superseded shapes and directories — so
long-lived sessions stop growing with distinct-name insertions and
module re-registrations.

**Settled M7 semantics.** Task values are identity-bearing capabilities
linked to live Session state. Both `str` and `pp` render a task as its
stable per-Session `<task:N>` marker; the reader rejects that exact
runtime marker wherever an atom may occur, so a task or any rendered
structure containing one is deliberately unparseable. Decision 16's
canonical reader round-trip applies only to values containing no
session-linked runtime object. Scheduling remains cooperative rather
than arbitrary native-stack preemption, but every user-sized traversal
has one explicit cursor implementation. Scheduler-attached drivers preserve
that cursor and its partial result and return to the scheduler within the
accounted-work quantum; blocking bootstrap and tool shells drive the same
cursor without introducing a legacy traversal mode. Process exit is owned by the
root Unit outside `attempt`: `exit` in a spawned Unit or inside `attempt`
raises an ordinary catchable `'domain`, while an allowed root exit
closes, cancels, and quiesces the root task scope before exposing its
status to the CLI.

Value destruction is one of those user-sized traversals. M7 now has one
allocator-scoped `ReleaseDomain`: `OwnedValue` drops only make the
reference-count transition and enqueue zero-count objects, exact-capacity
partial buffers retire as one domain-owned heap root, unknown reader output is
held by a fixed-chunk `OwnedValueChain` with one root, and scheduler/root turns
drain the domain in fixed chunks. Work-driver and continuation teardown receive
that domain explicitly. The evaluator exposes only `OwnedValue` for live stack
pops. Blocking host helpers drain a local domain but do not implement another
graph walker, and no operation allocates an independent release cursor.

**Why this is a safe pause point**: The language surface of DESIGN.md
is complete; only scope-ruled stdlib and REPL polish remain.

**Unlocks**: M9's typed native `Reschedule` continuation on the production
`WorkDriver`, M10's internal HTTP exception, and M11 acceptance.

---

### Milestone 8: repl-line-editing

**Status**: executed from `gameplans/repl-line-editing.json` (2026-08-16).

The as-built Session completion facade owns and settles its visibility and
registry snapshots through phase-owned cursor variants; completion before the
first unit reaches core names without an intermediate invalid state. Session
renderings own their storage without exposing host allocation authority;
production comptime validation rejects authority-bearing public Session return
types. Console callers receive only narrow whole-write operations. The editor
owns raw-mode restoration and a nominal line result, and keeps cursor/storage
inside an opaque buffer whose single splice consumes an owned replacement and
re-derives the cursor after every mutation. The editor receives capabilities
rather than the Session: a terminal that redraws, lists candidates, and accepts
only named prompts and named effects, and a completion observer that can render
matching names and nothing else. The console owns terminal geometry, row
planning, and escaping, sizes rows with an upper bound so a redraw cannot wrap,
and lets the terminal place the cursor by rewriting the text before it. The
reader mints the lexical checkpoint the REPL loop carries with its pending
bytes, so completion resumes over the current line instead of rescanning the
unit. It preserves queued input across non-flushing
transitions, and excludes malformed physical lines from history; the history
writer locks, rereads, merges, caps, and atomically replaces its durable file.
Six independently wired fuzz campaigns exercise reader, formatter, editor,
completion, history, and the real scheduler path. The editor campaign uses a
shrinkable arbitrary-byte/action model that checks exact bytes, cursor bounds,
the splice cursor postcondition, conditional UTF-8 boundaries, size rejection,
owned-line cleanup, an exact independently derived window at arbitrary,
one-cell, and oversized row widths, and that the real console can emit no
control byte for any buffer it reaches. The
Expect PTY suite runs against Debug and ReleaseSafe binaries and proves
first-turn completion, editing/redraw, queued multiline input,
malformed/truncated UTF-8 and escapes, escaped rather than replayed control
sequences, completion declining inside a string opened on an earlier physical
line, live/public-only dotted completion,
exact parseable history plus cross-process recall, continuation/error/EOF
behavior, and canonical/echo terminal restoration against the real binary.
The source audit measures 29,184/30,000 shipped business-logic Zig lines.

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

### Milestone 9: native-extension-abi-and-loader

**Status**: executed `gameplans/native-extension-abi-and-loader.json` on
2026-08-16; this section is the durable as-built record. Seven patches: the installed rebaseline
plus the frozen ABI-v1 wire contract, the
bounded descriptor validator, the `ecl-native` SDK and build helper, retirement
of the general-stack seam, native first light (loader typestate, `.eclmod`
resolution, atomic publication, transactional leaf call, reflection), the typed
`Reschedule` continuation with ordered shutdown, and acceptance. Planning
narrowed the milestone to exactly the capability set M10's CSV and JSON modules
consume; see the deferred-capability entry in Decisions Made.

**Definition of Done**:
Stock `ecl` can discover and load a precompiled Zig native extension from
`ECL_PATH` without rebuilding or relinking the interpreter. The shipped
`ecl-native` SDK and Zig build helper produce a target-specific
`<module>.eclmod` on Linux and macOS. V1 supports Zig authors using the pinned
Zig toolchain only; the generated adapter uses a stable C-shaped ABI, but that
wire contract is not yet a supported C author API. An artifact is exactly one
canonical ECL module, one atomic definition table, and one lifetime unit. It
exports one ABI-v1 entry point and may publish documented native callable words
only—no second module, ECL quotation, persistent ECL value, resource value, or
partial registration.

**Resolution and ABI are deterministic and fail closed.** For each `ECL_PATH`
entry in order, the auto-loader tries `<name>.ecl` and then `<name>.eclmod`; the
first existing candidate is authoritative, including its failures. The native
descriptor must name the requested module exactly. Its sized header, ABI
major/minor, callback table, definition count and indices, reserved state
layout, canonical names, UTF-8 documentation, effects, and capability
ids/versions are validated and copied through bounded cursors before host-table
installation or registry publication. ABI major 1 permits additive record tails
and capability versions: an older v1 extension continues loading on a newer v1
runtime when all named requirements are supported, while any breaking change
requires ABI v2. Unsupported platforms, architectures, ABI/capability versions,
malformed descriptors, name mismatches, duplicate words, missing documentation,
invalid effects, a nonzero reserved state layout, or an entry point that reports
failure instead of returning a descriptor publish nothing and produce a precise
module load error. Opening a dynamic library is documented as arbitrary trusted-code
execution—platform constructors may run before descriptor validation—so a
native-bearing `ECL_PATH` is a trusted dependency path. Future first-party
package management resolves versions and targets by constructing that ordered
path; the runtime gains no dependency solver or separate native path.

**Loading and lifetime are one consuming typestate.** A Session-owned instance
moves through `opened -> described -> validated -> initialized -> published`,
and every variant owns exactly the handle, copied metadata, and rollback action
valid in that phase. Descriptor text, scalar symbols/words, callback failures,
and entry diagnostics all cross one bounded UTF-8 ingress rather than carrying
per-producer validation policy. With module state deferred, `initialized` constructs the
pinned instance from validated metadata. The host table is minted only for an
invocation, so no artifact-stored host pointer survives a call; a future
module-state capability can extend that variant without reshaping the typestate. Native bindings
store a nominal module-instance handle plus validated definition index, never a
raw callback/context pair. V1 has no native hot reload or early unload. Session
hands worker Units only a loader capability whose surface cannot settle
descriptors, close a published image, or destroy the issuing root. Shutdown
consumes the separate owner through `open -> closing -> settled`: it closes new
native-call/image creation, joins/cancels all tasks, destroys every call
continuation, drains registry and environment pins, performs owner-only
descriptor/image settlement, and only then destroys the settled root. The
image pin is a variant of the load typestate: `dynamic` holds the
library handle, while `static` is a no-op pin over a linked first-party
descriptor. That static arm is the transport M10's CSV and JSON modules use; it
is proved in M9 by registering the SDK fixture as a linked Zig module, and it is
not a public API for embedding ECL in Zig applications. The old general-stack `NativeMachine` and
public `Session.registerNativeModule` seam cease to be a supported extension
surface rather than surviving as an authority bypass.

**The Zig SDK derives one unambiguous capability contract.** A callback begins
with exactly `*ecl.Call("inputs -- outputs")`; that comptime-parsed type is the
single source of its fixed successful effect and exposes only those immutable
inputs while requiring exactly that many outputs. Registration supplies the
word name, nonempty documentation, and callback. Every later callback parameter
must be one exact SDK-owned capability type, and the return type is exactly
`error{OutOfMemory,InvalidValue}!Outcome`. SDK reflection rejects generic or variadic
callbacks, optional/unknown/duplicate capabilities, the wrong call or return
type, an output-arity mismatch at `complete`, duplicate words, malformed
effects, and empty documentation. It generates the canonical requirement
manifest and uniform adapter;
authors write no `.requires` list, callback symbol table, effect duplicate, raw
host context, or allocator plumbing. `doc`, `which`, and `see` expose the normal
effect/documentation plus native origin and capability requirements.

**A native word is a transactional leaf call.** The runtime pins the declared
inputs unchanged for the whole call. `ValueView` exposes only immutable O(1)
kind/scalar/aggregate-length observation; `call.forward(i)` and `BuildValues`
produce issuer-checked candidate outputs owned by the transaction. Native
character construction crosses the same `Value.unicodeScalar` factory used by
UTF-8 materialization: values above U+10FFFF and surrogate halves are rejected
as language `domain` errors before a candidate exists, and no later encoder can
trap while narrowing an unvalidated codepoint. Completion
first reserves the exact final stack window and then atomically replaces the
inputs with its statically exact output tuple. Failure, cancellation, deadline
loss, OOM, or abandonment leaves the stack unchanged and transfers all
tentative ECL roots to bounded retirement; yield preserves the transaction.
Native authors may return `type`, `shape`, `conform`, `overflow`, `domain`,
`parse`, `io`, or `user` with a bounded message. Underflow, undefined-word,
contract, cancellation, timeout, OOM, source/word attachment, and trace
authority remain runtime-owned. The public SDK exposes no raw runtime `Value`,
stack mutation, environment resolution, word/quotation evaluation, spawn,
Session reentry, registry, module home, generation pin, wake control, allocator,
or reclamation domain.

**Cooperation is a composable typed capability, not a callback class.** A word
requests `Reschedule(ContinuationSpec)`, where the spec fixes its private Zig
state and explicit bounded destructor. The host owns its aligned storage and
library pin. From the first invocation it advances through the production
`WorkDriver` path with one ordinary 65,536-unit kernel budget, cancellation
poll, scheduler requeue, and retirement turn per slice. Base value observation
is O(1); aggregate contents are available only through budget-charging list
cursors (including text and specialized leaves) and dictionary cursors,
aggregate builders charge the same budget, and extension-local work calls
`consume`. There is no whole aggregate backing slice, public whole-slice
builder, or unmetered SDK iterator. Inputs and host-owned aggregate builders
remain pinned across yield; candidate handles and their uncommitted roots are
turn-scoped and retired after each callback. Complete/fail/cancel consumes the
continuation and any builders exactly once. Native machine
code itself remains non-preemptible and can deliberately ignore this contract,
so per-invocation duration/overrun diagnostics make violations observable but do
not pretend to provide instruction reductions or sandboxing. Those diagnostics
are opt-in through `ECL_NATIVE_DIAGNOSTICS`: with the variable unset no clock is
sampled and nothing is emitted, so the default build does not observe the limit
it documents. Inline callbacks must return promptly.

**The initial capability set remains deliberately closed, at exactly what M10
consumes.** Mandatory `Call` plus optional `BuildValues` and `Reschedule` are
the complete callback surface. CSV and JSON are pure value-in/value-out
transforms, so nothing in v1 needs per-module state. Module state with its
`ModuleView`/`ModuleUpdate` authority split and scheduler-integrated arbiter is
therefore deferred alongside native resource values, persistent ECL-value pins,
package assets, external wake, blocking jobs, quotation evaluation, and
task/runtime mutation as future independently versioned capabilities. The
deferral is unreachable rather than half-present: `module_view` and
`module_update` are reserved capability ids with no supported version and the
descriptor's state layout must be zero, so an artifact naming them is refused at
load while the additive-tail rule keeps ABI v1 open for the real capability.
`Offload` is the expected first scheduling addition; the M10 HTTP builtin
remains a documented internal direct-blocking exception in v1 and does not widen
this SDK.

**Proof is production-connected.** A real SDK-built shared-library fixture is
loaded through `ECL_PATH` by the release binary and exercises every operation
of every public capability. Compile-fail build fixtures prove malformed effects,
callback shapes, capability duplication, output-arity mismatch, duplicate words,
and missing documentation without tests that inspect implementation text. Loader
cases cover source/native precedence, path order, first-candidate failure,
name/ABI/capability mismatch, entry-point failure rollback, all-or-nothing
reflection, old-v1/new-v1 compatibility, and the static and dynamic image pins
reaching the same publication path. A delayed-continuation shutdown property
uses the real scheduler, cancellation path, registry pins, image release, and a
DebugAllocator baseline rather than inspecting private representation.
`fuzz-native-descriptor` drives arbitrary bounded metadata through the
production validator with valid backing ranges. Comptime reflection varies
every integer size field; malformed shared-library fixtures separately cover
entry results, strided records, and module-written wire tags.
`fuzz-native-call` selects bounded sequences of public SDK-fixture programs in
one cooperative Session and observes only ECL stack values and errors. Separate
runtime tests exercise one/eight-worker identity, over-quantum builders,
malformed artifacts, and spawned loading; the TSan gate runs those
production-connected tests, while a DebugAllocator delayed-continuation test
proves complete Session teardown. Focused allocator
failure sweeps remain in the ordinary suite; exhaustive initialized-Session
native loading/call coverage is added once to `src/tests/oom_test.zig` and
`zig build test-oom`.

M9's first production patch remeasured the source-audit classification and
synchronously installed an honest native SDK/ABI/loader component ceiling,
raised the machine, module, and definition-annotation ceilings required by
these nominal states, and updated `ARCHITECTURE.md`, this workstream, and the
audit constants. The planning envelope was 4,000 shipped lines for the new
native component and 37,000 total. Gameplanning narrowed the milestone to the
capability set M10 consumes, which removes the module-state arbiter and its
scheduler wait-set variant, so the first installed ceilings were **3,000 for the
native component and 36,000 total**, with `scheduler and concurrency` left at 3,500.
The installed first-patch measurement was 29,490/36,000 total and 305/3,000 for
the native component. The post-implementation boundary review required
runtime-minted capability tables, resumable aggregate builders, typed strided
record arrays, turn-scoped candidate generations, and owner-only image
settlement. Those explicit states raise the native ceiling to **3,800** while
leaving the total at **36,000**; final acceptance measures **33,176/36,000**
total and **3,428/3,800** for the native component. No implementation may compress or
hide these type boundaries to fit any of these numbers; the source audit and
ARCHITECTURE.md carry the same final rows.

**Why this is a safe pause point**: Source modules and language semantics are
unchanged; a rejected or failed native artifact has no registry visibility, and
every successful artifact is pinned through complete Session teardown. The
public surface is useful for value-in/value-out native acceleration without
committing v1 to resources, blocking pools, VM reentry, or application
embedding.

**Unlocks**: User-authored native extensions; M10's CSV/JSON modules as
first-party consumers of the same callback protocol; additive post-v1 module
state with `ModuleView`/`ModuleUpdate` authority, `Offload`, resource,
external-wake, package-asset, and evaluation capabilities.

**Established Precedents** (milestone-scoped):
- **[documentation] Erlang NIFs** — https://www.erlang.org/doc/apps/erts/erl_nif.html — ordinary NIFs demonstrate the non-preemption hazard; timeslice consumption and scheduled/dirty work motivate ECL's typed `Reschedule` now and additive `Offload` later.
- **[documentation] Janet native modules/C API** — https://janet-lang.org/capi/ — the small-language dynamic-module ergonomics precedent, narrowed here to one generated Zig module descriptor and semantic capabilities instead of a mutable VM pointer.

---

### Milestone 10: stdlib-str-csv-json-table-http

**Definition of Done**:
Five stdlib modules ship inside the binary (embedded sources / native
descriptors registered lazily through M4 plus M9's private static transport,
so the single-binary story holds; `ECL_PATH` remains for user modules). CSV
and JSON are first-party consumers of the public typed callback/capability
protocol without becoming external runtime dependencies. The same milestone
owns the explicit host scripting words needed by that layer:
- **`str`** — ecl source: `upper lower trim` (ASCII per d.15) and
  friends; the first real embedded-module consumer.
- **Host scripting words** — `slurp` [P] `( path -- string )` reads one
  UTF-8 file, `spit` [P] `( string path -- )` writes one file, and `getenv`
  [P] `( name -- string )` reads an environment variable. Unset variables
  error per absence-is-absence, with `attempt`/`or-else` as the defaulting
  idiom. `lines` [E] `( path -- list )` lands here, not M6, as the ordinary
  source body `(slurp "\n" split)`. These are explicit capabilities and do
  not alter the pure M6 `parse` contract.
- **`csv`** — native: `csv.parse` `( string -- rows )` and `csv.emit`
  `( rows -- string )` for RFC 4180 comma-delimited data. Parsing accepts
  CRLF or LF record endings, quoted commas and newlines, and doubled-quote
  escapes; it preserves empty fields and record widths and returns every
  field as a string, with no header interpretation, delimiter sniffing, or
  scalar inference. Emission accepts a list of nonempty rows whose cells are
  strings and produces canonical CRLF-terminated RFC 4180 output, quoting
  exactly the fields that require it. Empty input maps to an empty row list;
  malformed quoting is `'parse`, non-list rows and non-string cells are
  `'type`, and a zero-field row is `'shape`. Both user-sized traversals use SDK
  aggregate cursors and `Reschedule`, exercising the same `WorkDriver` budget
  as external modules.
- **`json`** — native: `json.parse` (string → value) and `json.emit`
  (value → string) per RFC 8259; integral in-range numbers → int64,
  else f64; objects → dicts (keys as strings), arrays → lists;
  emission requires string/symbol dict keys ('type error otherwise);
  the null ruling implemented per the resolved Open Question and
  recorded in DESIGN.md as a decision addendum. Parsing, emission, and
  aggregate construction use the M9 `Reschedule`/`BuildValues` path rather than
  a privileged whole-value traversal.
- **`table`** — ecl source over validated ordinary column dicts, never a new
  runtime kind. Its constructors and conversions are `table.from-columns`,
  `table.from-rows`, `table.from-header-rows`, `table.from-records`,
  `table.rows`, `table.header-rows`, and `table.records`; inspection and
  transformation are `table.valid?`, `table.names`, `table.column`,
  `table.cast`, `table.select`, `table.rename`, `table.with-column`, and
  `table.where`; analysis is `table.group-by`, `table.aggregate`,
  `table.inner-join`, and `table.left-join-with`. Column names are strings and
  columns are equal-length lists. Aggregation specs are
  `[output-name input-name quotation]` triples whose isolated quotation has
  `( column -- value )`; joins accept explicit left/right name pairs. The
  Decisions Made policy below freezes validation, ordering, collision,
  missingness, error, and reflection behavior.
- **`http`** — internal native builtin, client only: `http.get`/`http.post`
  (url [headers-dict] [body] → response dict with 'status, 'headers,
  'body), TLS included, timeouts surfacing as 'io error dicts. Its blocking
  call runs on the unit's worker thread as the one documented first-party v1
  exception; it is not exposed as an SDK capability and migrates to the future
  `Offload` capability without changing its ECL value-level API. Backend per
  the resolved Open Question.

**Why this is a safe pause point**: Modules and the three explicit host
scripting primitives are additive; evaluator and value semantics are
untouched.

**Unlocks**: Real scripting workloads (read/fetch → parse → validate → join →
aggregate → emit) — the awk/sed/jq positioning made literal.

**Established Precedents** (milestone-scoped):
- **[rfc-spec] RFC 4180 — Common Format and MIME Type for CSV Files** — https://www.rfc-editor.org/rfc/rfc4180 — the comma, record-ending, quoting, escaping, and field-preservation contract.
- **[rfc-spec] RFC 8259 — The JSON Data Interchange Format** — https://www.rfc-editor.org/rfc/rfc8259 — the parse/emit contract, including duplicate-key and number-precision guidance.
- **[documentation] q column dictionaries and tables** — https://code.kx.com/kdb-x/how_to/basics/work-with-tables.html
  The ordered name-to-equal-length-columns representation and column-oriented
  analysis model, adopted without q's distinct table type or query syntax.

---

### Milestone 11: v1-acceptance

**Definition of Done**:
The terminal acceptance suite below is implemented as a CI job
(fixtures + expect scripts where interactive) and green. README rewritten
around the real binary (install, tour, source-module guide, native-extension
SDK/build/trust guide). The d.23 line
budget is audited by a CI check. Its complete budget domain is the classified
production/core-business-logic Zig components listed in ARCHITECTURE.md:
their total is ≤ 36,000 lines, the native SDK/ABI/loader component is ≤ 3,800,
and the kernel component is ≤ 8,500. The first two were revised down from the
4,000/37,000 planning envelope at M9 gameplanning, because narrowing M9 to the
capability set M10 consumes removes the module-state arbiter and its scheduler
wait-set variant. They are synchronized with the source audit and
ARCHITECTURE.md at M9's first production patch; any further structurally
justified revision must update all three authorities in that same patch. Tests,
fixtures, inline `test` declarations, build/source-audit verification tooling,
and target-language ECL are outside LOC measurement and control; their
classification exists only to keep the first-party source manifest exhaustive.
Private top-level helpers reachable only from inline tests are excluded by the
same AST reachability pass, so co-location does not turn test support into
measured business logic.
Line figures in earlier executed-milestone status paragraphs are historical
measurements, not active v1 ceilings or policy for verification code.
The prior 22,000/5,500 and pre-M9 30,000 ceilings assumed
native-stack traversal; the replacement headroom preserves the nominal resumable
ownership, snapshot, reclamation, task-join, native transaction, capability, and
loader typestate boundaries required by M7 and M9 rather
than compressing them. Snapshot retention is bounded (the M7
reclamation obligation): a soak fixture that defines and re-registers in a loop
shows stable memory. A `v1.0` tag exists.

**Why this is a safe pause point**: It is the end; the tag is the
pause.

**Unlocks**: Post-v1 work (the static effect checker bundle, d.9;
performance evolution toward the K ceiling; exactness revisit) starts
from a proven baseline. The additive native capabilities deferred out of M9 —
module state with `ModuleView`/`ModuleUpdate` authority and its
scheduler-integrated arbiter, then `Offload`, resource values, external wake,
package assets, and quotation evaluation — also start here. None blocks the
`v1.0` tag: no v1 consumer needs them, and each is reachable through the
reserved capability ids and the ABI-v1 additive-tail rule without an ABI v2.

## Dependency Graph

- Milestone 1 (value-core) -> []
- Milestone 2 (reader) -> [1]
- Milestone 3 (frame-machine-first-light) -> [2]
- Milestone 4 (environments-and-modules) -> [3]
- Milestone 5 (kernels-and-pervasion) -> [3]
- Milestone 6 (combinators-and-recognition) -> [4, 5]
- Milestone 7 (scheduler-and-concurrency) -> [6]
- Milestone 8 (repl-line-editing) -> [4]        # parallel with 5–7
- Milestone 9 (native-extension-abi-and-loader) -> [4, 7]
- Milestone 10 (stdlib-str-csv-json-table-http) -> [6, 9]
- Milestone 11 (v1-acceptance) -> [7, 8, 9, 10]

## Open Questions

1. **stdin as data (gap scan 2026-08-12).** The awk positioning implies
   line-processing of piped input, but piped stdin is currently
   consumed as *source*. A `stdin` word must coexist with the
   stdin-as-source CLI modes without ambiguity. Real design
   conversation; owner: M10 gameplan at the latest.
2. **Randomness (gap scan 2026-08-12).** No `rand`/roll/deal words
   exist. First impure-nondeterministic vocabulary: seeding must be
   ruled against d.20 units (per-session RNG, per-unit, or
   explicit-seed-only) and determinism testing. Real design
   conversation; not blocking any current milestone.
3. **http backend (choice only; procedure is decided).** Which backend
   wins the spike — Zig `std.http.Client` + `std.crypto.tls` (pure Zig,
   no C dependency, maturity risk) or a libcurl binding (battle-tested,
   complicates the static single binary). Resolved by the M10 spike per
   the agreed criteria in Decisions Made. Owner: M10 gameplan.

## Decisions Made

- **Host = Zig** (user ruling, this session). Consequences absorbed
  into the plan: the kernel matrix generates via comptime (replacing
  the Rust macro plan), SIMD tier 1 rides `@Vector` (no nightly-Rust
  caveat), RC/atomics are hand-built on `@atomicRmw` with the d.23
  orderings, arc-swap becomes plain atomic pointer swap over immutable
  snapshots, and `Result<Box<EclError>>` becomes a Zig error union with
  an out-param error dict. ARCHITECTURE.md's mechanisms are host-
  agnostic; its Rust-specific grounding notes stay as history.
- **Zig is the kernel; ecl source is the prelude.** Irreducible or
  runtime-bound [P] operations live in the host, while shipped [E] core
  words are authored in `src/prelude.ecl`, embedded into the binary, and
  evaluated into the writable core before it is frozen. Zig owns the
  bootstrap loader but not alternate encodings of derived bodies. The M5
  host assembly of `wrap`, `pair`, and `sort` is explicitly temporary
  staging. A generated system image or snapshot is permitted only as a
  profile-justified post-v1 startup optimization; it must be reproducible
  from the same ecl source and cannot become a second semantic authority.
- **Fresh implementation at repo root; `poc/rust` frozen as the
  executable semantics oracle.** Its 44 tests become cross-
  implementation fixtures (M5/M6); it is never evolved.
- **M5 kernel boundary and ownership are frozen.** Dispatch reuses
  `value.HeapKind` rather than translating to a second tag enum. A
  kernel entry consumes its operands and returns one owned result;
  unique width-compatible buffers may be adopted only after the
  fault-mask pass succeeds. Leaf loops receive explicit half-open
  ranges, poll after at most 65,536 elements, and data-spine recursion
  raises `'domain` beyond 256 levels.
- **M5 pervasion and array transforms are frozen.** Atoms extend over
  lists, conforming list pairs descend by leading axis, and dict pairs
  align over insertion-ordered key union while recursing only on shared
  keys. `flip` is rank-one identity and otherwise swaps the first two
  rectangular axes, rejecting a transpose whose leading zero would erase
  later axes in the nested-list model. `reshape` requires a non-empty, non-negative shape,
  checks volume, ravels row-major, cycles the source, and treats dicts as
  atomic cells. Because values are nested lists without hidden rank
  metadata, a zero dimension must be final; shapes such as `[0 3]` are
  rejected instead of silently collapsing to `[0]`. Empty source is legal
  only for those exactly representable zero-volume outputs.
- **M5 ordering is deliberately partial.** `cmp` and `grade`/`sort`
  share one order over numbers (including exact mixed int/float
  comparisons), chars, and strings by codepoint-lexicographic order.
  Symbols, words, dicts, non-string nested cells, and cross-domain pairs
  are type errors rather than being ordered by allocation-history intern
  ids. Every comparison, bucket, and radix path is stable; float keys
  canonicalize both zero signs before sorting.
- **M5 preserves the derived-word boundary where semantics allow.**
  `sort` is installed as the stored ordinary word body `dup grade at`,
  temporarily assembled by Zig until the M6 embedded-source bootstrap.
  `has?` is a
  primitive whole-value membership probe: every key is inert, only absence
  returns false, and cancellation or allocation failure propagates rather
  than being mistaken for absence. `find` is provisional direct primitive
  because
  its specified body needs M6's `each`. M5 does not preempt M6's idiom
  table, resolution guards, or fast-vs-frame-machine harness.
- **The Rust oracle is a separate CI obligation.** Ordinary `zig build
  test` needs no Rust toolchain. SourceHut separately builds the frozen
  PoC and exhaustively maps every shared M5 word; successes compare
  canonical stdout, errors compare semantic kind/word, and Zig-only
  `flip`/`reshape`/`group`/`cmp`, kind reflection, collection constructors,
  canonical `str`, transcendentals, and extended `put`/`take`/`where` behavior use native
  unit proofs plus a real-binary acceptance fixture.
- **Benchmark baseline harness is OUT of v1** (user ruling): v1's gate
  is the differential harness, not numbers. Performance work is
  post-v1, against the invariants v1 preserved.
- **Stdlib ships embedded in the binary**, not via ECL_PATH files —
  single-binary distribution is part of the positioning (d.21).
- **Native interop is extension-outward, not an embedding API.** Stock `ecl`
  loads trusted target-specific `.eclmod` dependencies from the same ordered
  `ECL_PATH` used for source modules; future package management makes resolved
  dependencies available by constructing that path. V1 supports Zig authors
  on the pinned toolchain, one artifact = one canonical atomically published
  module, and Linux/macOS loading. It does not expose a public API for hosting
  ECL inside a Zig application, a C author SDK, native hot reload, or early
  unload.
- **Native authority is inferred capability composition.** The callback's
  `Call("before -- after")` type is the sole effect/arity declaration, and each
  additional exact parameter names one capability; the SDK generates the
  requirement manifest and stable C-shaped adapter at comptime. There are no
  callback classes, `.requires` duplication, raw VM/context/allocator, or
  general stack access. `BuildValues` and typed `Reschedule` are the initial
  optional capabilities; module state with distinct `ModuleView`/`ModuleUpdate`
  authority, resources, blocking offload, external wake, package assets,
  retained ECL values, and evaluation are additive future capabilities.
- **Native calls are transactional leaves but native code remains trusted.**
  Declared inputs remain pinned, candidate outputs belong to one call, and only
  exact completion mutates the stack; fail/cancel/timeout/OOM/abandonment do
  not. Aggregate access is available only through `Reschedule`-budgeted cursors
  and builders mapped to the real `WorkDriver`. The runtime cannot preempt or
  infer reductions for arbitrary native instructions, so inline code must
  return promptly and duration diagnostics expose violations after the fact.
  M10 HTTP remains the sole internal direct-blocking v1 exception; `Offload` is
  the committed first scheduling extension.
- **Native lifetime is one ordered shutdown.** Session shutdown closes new
  native-call creation, quiesces calls, destroys continuations, settles ECL
  retirement, and only then closes libraries. External side effects a native
  word performs are not rolled back with the operand-stack transaction.
- **M9's capability set is closed at exactly what M10 consumes** (gameplan
  ruling, 2026-08-16). Mandatory `Call` plus optional `BuildValues` and
  `Reschedule`; CSV and JSON are pure value-in/value-out transforms with no
  per-Session state, so `ModuleState`, `ModuleView`, `ModuleUpdate`, and the
  scheduler-integrated arbiter are deferred to post-v1 along with the additive
  capabilities already listed. That removes the milestone's riskiest piece — a
  new `ParkRequest` wait-set variant — and initially dropped the ceilings to
  3,000 native and 36,000 total. The boundary-review correction above raises
  only the native row to 3,800. The deferral is unreachable rather than half-present:
  `module_view` and `module_update` are reserved capability ids with no
  supported version and the descriptor's state layout must be zero, so an
  artifact naming them is refused at load while the additive-tail rule keeps
  ABI v1 open for the real capability. When it lands, module state extends the
  `initialized` typestate variant rather than reshaping the typestate.
- **The static transport is an image-pin variant, not a second path** (gameplan
  ruling, 2026-08-16). The load typestate carries `dynamic` (the library
  handle) and `static` (a no-op pin over a linked first-party descriptor);
  both traverse identical validation, publication, transaction, and teardown,
  so M10's CSV and JSON cannot drift from a `.eclmod`'s behavior. M9 proves the
  static arm by registering the SDK fixture as a linked Zig module rather than
  shipping it unexercised.
- **Native loading ships ungated** (gameplan ruling, 2026-08-16). No feature
  flag, no opt-in environment variable, and no build option that compiles the
  loader out. Placing a `.eclmod` on `ECL_PATH` is already a deliberate
  operator act; a second toggle would only create a state where an installed
  trusted dependency silently fails to load, and would fork every native
  acceptance run into two resolution modes. Trust is addressed by fail-closed
  validation before any side effect, a load error that names arbitrary-code
  execution, and the README guide.
- **Native overrun diagnostics are opt-in** (gameplan ruling, 2026-08-16).
  `ECL_NATIVE_DIAGNOSTICS` enables per-invocation duration and over-quantum
  accounting with one rate-limited line per module through Session
  diagnostics; unset, no clock is sampled and nothing is emitted. The accepted
  consequence is that the default build does not observe the non-preemption
  limit it documents, so DoD-23 and the README state the observability is
  opt-in and acceptance runs the non-cooperative fixture in both modes.
- **The `ecl-native` SDK ships from this repository** at `src/native/`, exposed
  as a build module rooted at `src/native/sdk.zig` (gameplan ruling,
  2026-08-16). Zig forbids importing a file above a module's root directory, so
  that root *is* the isolation boundary: `@import("../machine.zig")` is a
  compile error rather than a source-denylist entry. A separate repository
  would add release synchronization without adding enforcement.
- **d.21 gains an addendum rather than a new decision** (gameplan ruling,
  2026-08-16). DESIGN.md records that ecl still generates no machine code, that
  core and stdlib remain a single binary with `.eclmod` artifacts as optional
  installed dependencies, that a native-bearing `ECL_PATH` is an explicitly
  trusted path, and that d.9's cached compiled form is still threaded or opcode
  arrays only. Without it a reader of the ledger alone would conclude native
  loading contradicts the positioning.
- **CSV is text-preserving table interchange, not schema inference.**
  `csv.parse` returns rows of strings and treats a header, when present, as
  an ordinary first row; `csv.emit` accepts the same representation. This
  preserves leading zeroes, empty cells, and ragged record widths without
  inventing null, header, or scalar-coercion semantics.
- **A table is a validated ordinary column dictionary, not a runtime type.**
  It is a nonempty insertion-ordered dict whose keys are unique nonempty
  strings and whose values are lists with one common top-level length. A table
  may have zero rows but never zero columns. `table.valid?` recognizes exactly
  this convention and every other exported `table.*` word validates every
  table input before doing work; it returns 0 only for a convention mismatch,
  while cancellation and OOM still propagate. Core reflection remains honest:
  `type` reports `'dict`; printing, `match`, `keys`/`vals`/`at`/`put`,
  pervasion, and `json.emit` retain their ordinary dict behavior; `csv.emit`
  consumes an explicit `table.rows` or `table.header-rows` result. No reader,
  evaluator, value tag, heap kind, kernel dispatch, or generic serializer
  recognizes tables implicitly. A core dict operation may therefore produce
  an invalid candidate, which the next `table.*` boundary rejects rather than
  repairing or reclassifying.
- **Table construction and conversion are strict and explicit.**
  `table.from-columns` validates the column-dict convention.
  `table.from-rows` takes explicit names and exact-width rows, including an
  empty row list for a known zero-row schema; `table.from-header-rows` requires
  a nonempty first row of unique nonempty string names and exact-width data
  rows. `table.from-records` accepts a nonempty list of dicts with the same
  string key set, uses first-record insertion order, and tolerates later key
  order differences but not missing or extra keys; an empty record list is
  `'shape` because it carries no schema. `table.rows` returns data rows in
  order, `table.header-rows` prefixes the ordered names for a schema-preserving
  CSV round-trip (including zero rows), and `table.records` returns row dicts
  in schema order but necessarily loses schema when its result is empty.
  `table.rows` paired with `table.names` is the schema-preserving explicit-row
  form. CSV remains text-only; `table.cast` takes a dict from existing column
  name to an isolated `( cell -- value )` quotation, prevalidates the complete
  spec, and performs the only requested coercions transactionally.
- **Table transformations preserve schema and row order unless their name says
  otherwise.** `table.select` requires a nonempty unique list of existing
  names in desired output order; `table.rename` takes an ordered dict from old
  name to new name and rejects missing sources, non-string targets, and
  collisions; `table.with-column` requires exactly the table row count,
  replaces an existing name in place, and appends a new name; and `table.where`
  accepts only an exact-length 0/1 mask.
  `table.group-by` accepts zero or more existing names and returns an
  insertion-ordered dict from scalar or composite structural keys to stable
  row-index lists; no names means one global group. `table.aggregate`
  prevalidates unique `[output-name input-name quotation]` specs, rejects
  missing inputs and output/key collisions, requires at least one key or
  aggregate output, calls each `( column -- value )` quotation once per group
  in group-then-spec order and in isolation, and returns key columns first
  followed by aggregate columns. With grouping keys, a zero-row table has zero
  result rows; without keys it has one global group and quotations receive
  empty columns.
- **Table joins are stable equijoins with explicit missingness.** Join keys are
  a nonempty list of `[left-name right-name]` string pairs, with no column
  repeated on either side. Equality is ECL's whole-value structural equality;
  duplicate keys produce the full
  many-to-many product in left-row order and, within each left row, right-row
  order. Results contain all left columns in their original order followed by
  right non-key columns in right order; any non-key name collision is
  `'domain` and must be resolved with `table.rename`. `table.inner-join` emits
  matches only. `table.left-join-with` emits one row for an unmatched left row
  and requires a fill dict covering exactly every appended right column; it
  never invents null. Right/full/as-of/window joins and query syntax are out of
  v1. JSON `'null` remains ordinary data, not a missing-cell marker.
- **Table failures follow the existing semantic kinds.** Non-dicts,
  non-string names, non-list columns, invalid masks/spec members, and invalid
  record members are `'type`; zero-column schemas, unequal column lengths,
  and row/mask width mismatches are `'shape`; missing, empty, or duplicate
  names, schema disagreement, join/rename collisions, and incomplete fill
  dicts are `'domain`; aggregation quotation shape failures are `'contract`.
  Validation, grouping, casting, joins, and materialization traverse through
  the existing polled combinators or explicit `WorkContext` cursors, and
  cancellation, OOM, or user errors expose no partial table.
- **http is client-only in v1.** A server is long-running-process
  territory the positioning explicitly declined (d.20/d.21).
- **JSON null ↔ the symbol `'null`** (user ruling, this session).
  `json.parse` maps null to the ordinary symbol `'null`; `json.emit`
  maps `'null` back. Data, not language nil — d.22's absence doctrine
  is untouched; arrays like `[1, null]` round-trip. Recorded in the
  ledger (d.22 addendum).
- **http backend is chosen by spike, not by guess** (user ruling, this
  session): at M10 planning, `std.http` wins if it handles TLS 1.3
  against 5 real-world hosts including redirects and chunked encoding;
  otherwise bind libcurl.
- **Toolchain pinned: Zig 0.16.0** (resolved at M1 planning, closing the
  former open question). Pinned in `build.zig.zon`
  (`minimum_zig_version`) and by the CI tarball; revisited only at
  milestone boundaries and at the M10 http spike.
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
  - **Verify by** `cmd`: fixture `modules-privacy.ecl` defines
    `'m (40 's setp (s 2 +) ( -- n ) 'f def) module`, calls `m.f`,
    then attempts `m.s`; companion fixture `body-extraction.ecl`
    defines the same module and runs `'m.f body call` at session scope.
  - **Expected**: the privacy fixture prints `42`, then exits ≠ 0 with
    `'kind 'undefined-word`, `'word 'm.s`; the extraction fixture exits
    ≠ 0 with `'kind 'undefined-word`, `'word 's`.
  - **Traces to**: Milestone 4 — registry resolution + visibility.

- **DoD-12 — hot reload heals all access paths**
  - **Assert**: re-registering a module updates qualified, `use`d, and
    aliased callers.
  - **Verify by** `cmd`: fixture `hot-reload.ecl` (ports
    `poc/rust/examples/modules.ecl` and adds mandatory effects to its
    module words).
  - **Expected**: outputs `11 21 31 12 22 32` (one per line).
  - **Traces to**: Milestone 4 — registry generation swap.

- **DoD-13 — ECL_PATH auto-load**
  - **Assert**: `use` of an unregistered module loads `<name>.ecl` from
    `ECL_PATH` and retries.
  - **Verify by** `cmd`:
    `ECL_PATH=test/acceptance/modules ecl -e "'stats use answer"`,
    where `test/acceptance/modules/stats.ecl` registers a module with
    `42 'answer set`, and no module was registered beforehand.
  - **Expected**: `42`; exit 0.
  - **Traces to**: Milestone 4 — module file transport. The composite
    `zscore` acceptance remains downstream of M5/M6 rather than making
    M4 depend on vocabulary it does not own.

- **DoD-14 — REPL crash-only rollback with env survival**
  - **Assert**: a failing REPL line restores the stack while completed
    env writes survive; every isolated application gets a disposable
    child scope; the eventual `each` implementation consumes that same
    boundary API rather than recreating environment isolation.
  - **Verify by** `ux`: enter `10`, then
    `(99) 'kept def 20 + missing`, then `dup pp`, then `kept pp`.
    At M4 run `(1 'k set) attempt pop k`; at M6 run the original probe
    `[1 2 3] (dup 'k set k *) each pop k`.
  - **Expected**: after the failed line `dup pp` prints `10` and
    `kept pp` prints `99`; both isolation probes error
    `'undefined-word` for `k`.
  - **Traces to**: Milestone 3 — exact unit stack rollback; Milestone 4
    — the shared lazy child-scope mechanism proven through `attempt`;
    Milestone 6 — `each` adopts that mechanism and owns the terminal
    each-specific assertion.

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
    `attempt`; `await` is idempotent; source-defined `await-all` returns
    every ordinary outcome in input order without re-raising failures.
  - **Verify by** `cmd`: `ecl '(1 2 +) spawn dup await pop await or-raise call'`
    and a mixed success/failure task-list fixture comparing `await-all` with
    `(await) each` at 1 and 8 workers.
  - **Expected**: `3`; the two ordered outcome lists match at both worker
    counts.
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

- **DoD-22 — native artifact discovery, ABI, and reflection**
  - **Assert**: the public Zig SDK builds one `sample.eclmod`; stock `ecl`
    discovers it through ordered `ECL_PATH`, validates ABI/capabilities and the
    exact module identity before initialization, publishes the complete table
    once, and exposes ordinary effects/docs plus native capability metadata.
    Source wins over native within one path root, path-root order wins across
    roots, and the first existing malformed candidate fails without fallback.
  - **Verify by** `cmd`: `zig build native-fixture`, which emits
    `zig-out/native-fixture/sample.eclmod` from `test/native/sample.zig` plus
    one artifact per defect under `zig-out/native-fixture/<defect>/`; then run
    the release binary with only a fixture directory on `ECL_PATH` and execute
    `'sample use 41 sample.increment 'sample.increment doc
    'sample.increment which 'sample.increment see`; repeat with source/native,
    path-order, wrong-name, ABI-major, capability-version, duplicate-word,
    missing-doc, invalid-effect, reserved-capability, reserved-state,
    entry-failure, and old-v1 additive-tail fixture variants.
  - **Expected**: the valid artifact returns `42`, its nonempty documentation,
    canonical `(n -- result)` effect, `which` reporting the binding as `native`
    with its inferred capability list, and `see` rendering
    `<native:sample.increment>` with the ordinary combined annotation. Each
    invalid artifact reports its precise load error, leaves `sample` absent from
    registry/reflection, and never selects a later candidate.
  - **Traces to**: Milestone 9 — SDK descriptor generation, `ECL_PATH` native
    transport, consuming loader typestate, atomic module publication, and ABI
    negotiation.

- **DoD-23 — transactional cooperative native calls**
  - **Assert**: a real loaded callback sees exactly its declared immutable
    inputs; aggregate access and construction consume the scheduler budget;
    repeated yields preserve typed continuation and draft state; exact
    completion commits once; and failure, cancellation, deadline expiry, OOM,
    or abandonment exposes no partial stack or output graph. A one-worker run
    makes progress between yielded native slices, while an intentionally
    non-cooperative fixture run with `ECL_NATIVE_DIAGNOSTICS` demonstrates the
    documented non-preemption limit without being mistaken for a reductions
    proof. The same fixture run without that variable emits nothing and samples
    no clock: the diagnostic is opt-in and the default build does not measure.
  - **Verify by** `cmd`: `zig build test-native-runtime`,
    `zig build fuzz-native-call`, and the release-binary fixture at
    `ECL_WORKERS=1` and `ECL_WORKERS=8`, with diagnostics both disabled and
    enabled; the fixture invokes budget-spanning list scans, dictionary
    cursors, aggregate builders, fail-after-draft, cancel-after-yield, and
    exact zero/one/multiple-output words through the generated adapter.
    Initialized-Session allocation failures run once under
    `zig build test-oom`.
  - **Expected**: successful outputs and reflection are identical at both
    worker counts; observer tasks advance between cooperative slices;
    every non-success preserves the pre-call operand stack; all candidate
    values and continuation storage retire; cancellation latency is bounded by
    one cooperative native quantum after the callback returns; the overrun
    diagnostic appears only in the enabled runs; and allocator
    accounting returns to baseline.
  - **Traces to**: Milestone 9 — typed `Call`, `BuildValues`, `Reschedule`,
    production `WorkDriver` integration, and bounded retirement.

- **DoD-24 — native SDK rejection and shutdown lifetime**
  - **Assert**: shutdown closes new native-call creation before joining tasks;
    delayed continuations, draft candidates, registry pins, and the code image
    are all released before Session teardown returns. SDK-invalid callback and
    capability shapes fail compilation
    rather than requiring a runtime convention, and arbitrary bounded
    descriptor metadata never escapes the production validator. An artifact
    naming the reserved `module_view` or `module_update` capability ids, or
    declaring a nonzero reserved state layout, is refused at load — the
    deferred capability is unreachable rather than half-present.
  - **Verify by** `cmd`: `zig build test-native-sdk-negative`,
    `zig build fuzz-native-descriptor`, and the production-loaded fixture
    under Debug, ReleaseSafe, one/eight workers, and Linux TSan. The production
    scheduler property keeps a delayed continuation alive through Session
    shutdown and measures the complete lifetime with `DebugAllocator`.
  - **Expected**: all compile-negative fixtures are rejected by SDK
    comptime validation; arbitrary bounded descriptor metadata never escapes
    validation; reserved-capability and nonzero-state-layout artifacts report
    a precise unsupported-capability load error and publish nothing; and
    allocator accounting returns to baseline with no callback reachable after
    the registry releases its final image pin.
  - **Traces to**: Milestone 9 — SDK comptime reflection, the descriptor
    validator, library pins, and ordered Session teardown. Module state with
    `ModuleView`/`ModuleUpdate` authority and its scheduler-integrated arbiter
    is deferred post-v1 and carries its own assertions when it lands.

- **DoD-25 — json round-trip**
  - **Assert**: `json.parse` maps objects/arrays/numbers per the
    ruling; `json.emit ∘ json.parse` is identity on a canonical corpus;
    non-string-keyed dicts refuse to emit.
  - **Verify by** `cmd`: fixture `json.ecl` over a corpus file
    including nested objects, `null`, integral and non-integral
    numbers; plus `{1 2} json.emit` expecting `'kind 'type`.
  - **Expected**: corpus round-trips byte-identically; the emit error
    fires.
  - **Traces to**: Milestone 10 — json native module using M9 capabilities.

- **DoD-26 — csv round-trip**
  - **Assert**: `csv.parse` preserves fields, empty cells, record widths,
    header-looking and scalar-looking text, quoted commas/newlines, and
    doubled quotes as strings; `csv.emit ∘ csv.parse` is identity on a
    canonical RFC 4180 corpus; malformed quotes and invalid tables are
    rejected with the specified error kinds.
  - **Verify by** `cmd`: fixture `csv.ecl` reads a corpus containing CRLF
    and LF records, blank and ragged records, a header-looking first row,
    leading-zero text, semicolons, embedded commas/newlines, and escaped
    quotes, then checks the parsed rows and emits the canonical corpus;
    separate cases parse an unclosed quoted field and emit a numeric cell,
    a non-list row, and a zero-field row.
  - **Expected**: parsed rows match the fixture's nested string lists;
    canonical output matches byte-for-byte; the malformed input yields
    `'kind 'parse`, the numeric cell and non-list row yield `'kind 'type`,
    and the zero-field row yields `'kind 'shape`.
  - **Traces to**: Milestone 10 — csv native module using M9 capabilities.

- **DoD-27 — table representation and conversions**
  - **Assert**: a valid table remains an ordinary dict under every core
    interface, while `table.*` constructors, row/record conversions, and
    transformations preserve its ordered equal-length-column convention.
  - **Verify by** `cmd`: fixture `table-values.ecl` constructs populated
    tables through every constructor and zero-row tables through the explicit
    column, named-row, and header-row constructors; observes `type`, `match`,
    `keys`, `at`, `str`, and `json.emit`; round-trips through
    `table.rows`, `table.header-rows`, and `table.records`; and exercises
    `table.names`, `table.column`, `table.cast`, `table.select`,
    `table.rename`, `table.with-column`, and `table.where`.
  - **Expected**: `type` is `'dict`, `table.valid?` is 1, ordinary dict
    observations match the underlying column dict, names plus rows and
    header-inclusive rows round-trip populated and zero-row schemas, populated
    records round-trip while empty records are explicitly schema-less, casts
    are the only scalar coercions, and every transformation produces the
    fixture's expected ordered column dict.
  - **Traces to**: Milestone 10 — embedded `table` module value policy and
    conversion/transform words.

- **DoD-28 — table validation boundary**
  - **Assert**: invalid table candidates are never implicitly repaired or
    reclassified, and every exported `table.*` operation validates all table
    and specification inputs before executing user quotations or exposing a
    partial result.
  - **Verify by** `cmd`: fixture `table-invalid.ecl` passes zero-column,
    non-string-name, non-list-column, unequal-length, duplicate-header,
    record-schema-mismatch, bad-mask, bad-cast, bad-aggregate, colliding-name,
    and incomplete-fill cases through every applicable public word; it also
    breaks a valid table with core `put` and retries a table operation.
  - **Expected**: `table.valid?` returns 0 for each invalid candidate; operations
    fail as `'type`, `'shape`, `'domain`, or `'contract` according to the
    frozen policy, no cast/aggregate quotation runs before complete
    prevalidation, and core `type` continues to report `'dict`.
  - **Traces to**: Milestone 10 — embedded `table` module validators.

- **DoD-29 — table filtering and aggregation**
  - **Assert**: CSV text can be explicitly cast, filtered, grouped by named
    columns, and aggregated with ordinary ECL quotations while preserving
    first-key occurrence order and stable rows within each group.
  - **Verify by** `cmd`: fixture `table-analysis.ecl` uses `slurp`,
    `csv.parse`, and `table.from-header-rows` on `sales.csv`; explicitly casts
    `amount` and `quantity`, derives `revenue` with `table.with-column`, filters
    by an exact 0/1 mask, inspects `table.group-by`, and calls
    `table.aggregate` by `region` with `sum`, `len`, and `mean` quotations.
  - **Expected**: the grouped index dict and final region/revenue/count/mean
    column dict match the checked-in expected values exactly; no header or
    numeric inference occurs.
  - **Traces to**: Milestone 10 — embedded `table` module grouping and
    aggregation words.

- **DoD-30 — stable table joins and explicit missingness**
  - **Assert**: inner and filled left equijoins support named composite keys,
    expand duplicate matches many-to-many in stable left-major/right-minor
    order, reject non-key column collisions, and never invent a missing value.
  - **Verify by** `cmd`: fixture `table-joins.ecl` loads an orders CSV through
    `slurp`/`csv.parse` and a JSON array of customer records through
    `slurp`/`json.parse`, converts both to tables, then exercises
    `table.inner-join` and `table.left-join-with` using duplicate, unmatched,
    composite-key, collision, and exact-fill cases.
  - **Expected**: inner and left results match expected ordered column dicts;
    duplicates expand in the specified order, unmatched left rows use only
    caller-provided fills, collisions and incomplete fills are `'domain`, and
    a JSON `'null` value remains ordinary data when present.
  - **Traces to**: Milestone 10 — embedded `table` module join words.

- **DoD-31 — http client**
  - **Assert**: `http.get` against a local fixture server returns a
    dict with `'status 200` and the body; a refused connection yields
    `'kind 'io`.
  - **Verify by** `cmd`: CI starts a local static server; fixture
    `http.ecl` gets a known file and one dead port.
  - **Expected**: status/body asserted; the dead port errors `'io`
    without crashing the interpreter.
  - **Traces to**: Milestone 10 — internal http native module and documented
    direct-blocking exception.

- **DoD-32 — str module via embedded stdlib**
  - **Assert**: `'str use "hello" str.upper` works with no ECL_PATH
    set.
  - **Verify by** `cmd`: `ecl "'str use \"hello\" str.upper pp"` in an
    empty environment.
  - **Expected**: `"HELLO"`.
  - **Traces to**: Milestone 10 — embedded stdlib registration (mechanism Milestone 4).

- **DoD-33 — line budget**
  - **Assert**: only classified production/core-business-logic Zig is in the
    line-budget domain: its total is ≤ 36,000 lines, the native
    SDK/ABI/loader component is ≤ 3,800, every component is inside its
    synchronized ARCHITECTURE.md row, and kernels are ≤ 8,500. M9 installed
    these ceilings in its first patch and updates all authorities together when
    a strong representation requires a justified revision, so scheduler-safe
    and native work retain explicit cursor,
    ownership, transaction, and typestate states instead of
    synchronous native-stack cleanup or raw correlated fields. The 3,800/36,000
    figures supersede both the 4,000/37,000 planning envelope and the too-small
    initial 3,000 native estimate.
    Tests, fixtures, inline `test` declarations, test-only sources,
    build/source-audit tooling, and target-language ECL are outside LOC
    measurement and control.
    Top-level declarations gated by `builtin.is_test` and private declarations
    reachable only from tests are likewise excluded by AST reachability rather
    than conservatively charged to the containing production component.
    Source coverage still classifies first-party test and tooling files solely
    to make the manifest exhaustive; DoD-33 neither measures nor reports their
    line totals and imposes no line ceiling on them.
  - **Verify by** `cmd`: `zig build source-audit` (the dedicated audit in
    `src/tools/source_audit.zig` prints the business-logic split and fails the build when a
    component exceeds its row); `zig build test` depends on this audit.
  - **Expected**: exit 0, including 3,428/3,800 native and 33,176/36,000 total;
    no test or tooling line total is part of the contract.
  - **Traces to**: Milestone 11 — the source audit (budget: d.23,
    re-derived for the Zig host 2026-08-12).

- **DoD-34 — module effect declarations (d.9)**
  - **Assert**: a module `def` without an effect declaration fails
    registration; a declared effect is enforced dynamically when a call
    enters from outside its home module; same-home calls are unbracketed;
    optional documentation shares the same annotation and is visible via
    `doc`/`see`. SDK-loaded native words derive their validated effect from the
    typed `Call`, require nonempty documentation at comptime and load time, and
    expose both through `doc`, `which`, and `see` like ordinary callables.
  - **Verify by** `cmd`: `ecl -e "'m ( (dup +) 'bad def ) module"`;
    `ecl -e "'m ( (dup +) ( a -- b c ) 'lies def ) module 1 m.lies"`;
    `ecl -e "'m ( (dup +) ( a -- b : \"Double.\" ) 'dbl def ) module 'm.dbl see 'm.dbl doc"`;
    `zig build native-fixture`; and `zig build test`, whose
    `module: effect shape cross-home contract and same-home TCO` fixture compares
    20- and 20,000-deep module countdowns. The real loaded native fixture checks
    all three reflection commands plus callback/effect/capability consistency.
  - **Expected**: exit ≠ 0 with `'kind 'domain` (missing declaration);
    exit ≠ 0 with `'kind 'contract` (observed `( a -- b )` ≠ declared
    `( a -- b c )`); `see` output includes
    `(a -- b : "Double.")` and `doc` returns `"Double."`; both countdown
    depths have the same bounded maximum frame count, proving no
    per-activation same-home contract checkpoint. For the native fixture,
    `which` renders the binding kind as `native` followed by its inferred
    capability list, and `see` renders `<native:<module>.<word>>` with the
    ordinary combined annotation.
  - **Traces to**: Milestone 4 — module `def`/`defp` declaration validation and
    the cross-home d.14 dynamic enforcement hook; Milestone 9 — native typed
    effects and reflective metadata.

- **DoD-35 — embedded target-language prelude**
  - **Assert**: the shipped [E] core vocabulary loads without filesystem
    support, remains reflectable as ordinary ecl bodies, exposes nonempty
    documentation for every word, follows the audited `### def <name>` block
    convention, includes the literal-count `pack` behavior, and keeps private
    performance idioms unreachable as ordinary bindings.
  - **Verify by** `cmd`: the acceptance fixture copies only the release
    `ecl` binary into an empty temporary directory and runs
    `env -u ECL_PATH ./ecl -e "'wrap body 'pair body 'sort body 'pack body 1 2 3 4 4 pack"`;
    `zig build test` additionally exercises the embedded source loader,
    empty-stack postcondition, and retained provenance; `zig build test-oom`
    exhausts allocation failures across the initialized runtime surfaces.
  - **Expected**:
    `(() cons) (() cons cons) (dup grade at) (() swap (cons) times) [1 2 3 4]`;
    tests exit 0 without reading an external prelude file.
  - **Traces to**: Milestone 6 — `src/prelude.ecl` plus the core bootstrap
    loader and provenance archive.
