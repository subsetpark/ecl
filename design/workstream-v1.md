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
userland stateful modules, the `result`, `str`, `csv`, `json`, `table`, and
`http` stdlib modules, optional target-specific native extension modules
loaded by the stock binary, and (ruled 2026-08-18) the bitwise pattern
words plus the three-layer randomness design — pure counter-based kernels,
the `entropy` capability, and the userland `rng` stateful module — landing
as one standalone patch between M12 and M13. Core and stdlib retain the single-binary
distribution guarantee; `.eclmod` artifacts are explicitly installed trusted
dependencies, not required runtime pieces.

## Current State

Verified in the checkout (2026-08-17):

- `design/` holds the complete, internally consistent spec: DESIGN.md
  (23 decisions + implementation-agnostic runtime spec), GRAMMAR.md,
  VOCABULARY.md (~70 [P] + ~15 [E] words with contracts),
  ARCHITECTURE.md (literature-grounded implementation architecture with
  a staged plan and a skeleton disposition table), and
  `research/` (the raw architecture panel, citations verified).
- The real Zig interpreter is implemented through M4 at commit
  `2bf6c56`: flat values and CoW containers, the full reader, the
  defunctionalized frame machine and real CLI, chained environments,
  and the complete d.18 module/registry/hot-reload system. Its M4 suite
  records 119 tests across library/cross-layer and real-binary coverage;
  Debug, ReleaseSafe, ReleaseFast, named Linux TSan, formatting, and
  blocking ZLint are green, including builds.sr.ht job 1859966.
- The Zig executable is the **semantic reference**. A checked-in `ohsnap`
  transcript records exact exit status, stdout, and stderr for the 74 CLI
  cases promoted from the former cross-implementation comparison surface.
  The superseded walking skeleton and its toolchain have been removed.
- The real Zig interpreter is now implemented through M8 in the current
  checkout (on the M7 base at commit `6c7c970`). Its closed data plane includes
  pervasive leaf kernels,
  sequence/shape/order/group operations, immutable dict updates, Unicode
  text kernels, kind reflection, cycling/count-vector sequence operations,
  the awk-floor transcendentals, exact whole-value `cmp`, and the promoted CLI
  snapshot gate, isolated and inline combinators, guarded
  phrase recognition, and the documented embedded target-language prelude.
  Its ordinary lists, ordered dicts, `group`, `at`, `where`, `flip`, folds,
  and pervasive kernels provide the data-plane substrate for tabular work;
  no table module or table runtime kind exists. M7 adds green units,
  structured task lifetimes, cancellation/deadlines, deterministic joins,
  bounded retirement, and one/eight-worker acceptance. M8 adds scalar-safe
  TTY editing, locked atomic 100-line history, snapshot-safe live and dotted
  completion, continuation cancellation/EOF behavior, and a real-binary PTY
  gate while leaving non-TTY input unchanged. M9 native extensions, M11
  stateful modules, and M12 stdlib were future milestones when this
  section was written; M9, M10 (one-binder merge), M11, M12, and M13 have
  since landed — their Status records are the as-built truth. The
  workstream is terminal: `0.1.0` is tagged (2026-08-19) and post-terminal
  Steps 14 and 15 have executed.
- All derived core words now live in `src/prelude.ecl`; the loader embeds and
  evaluates that ordinary source with retained provenance before freezing the
  core. Every definition is a documented `### def <name>` block. A standard
  library word belongs here when its source definition is compact or when its
  performance does not justify a host idiom; only a substantial definition
  with a justified host fast path remains wholly primitive.

## Key Challenges

- **The RC/CoW/uniqueness machinery under true parallelism** — precise
  atomic counts, acquire-ordered uniqueness, the Perceus-style stack
  ownership discipline, and publication edges. This is subtle,
  cross-cutting, and hand-built in Zig. Mitigated by d.23's rules being
  written down and by the differential harness.
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
- **Stateful-module publication and teardown** — a canonical registry slot
  must outlive replaceable code generations and immutable durable-stack
  snapshots, while serialized drafts and pending outputs remain cancellable
  and removal remains bounded. M11 makes this one owner-issued lifecycle
  instead of correlating registry, state, arbiter, output, and retirement fields
  in callers.
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
  leaves blocking-pool offload as a future capability.
- **[documentation] Janet C API and native modules** — https://janet-lang.org/capi/
  The ergonomic precedent for loading trusted native modules into a small
  language runtime. ECL narrows that model to one Zig-authored artifact per
  module, with generated capability and ownership adapters rather than a broad
  mutable VM pointer.
- **[pattern] Self-sized exact records** — Every record carries its byte size,
  and the pre-release loader requires that size and every array stride to equal
  the current SDK definition. The field is a corruption and stale-artifact
  guard, not a record-tail negotiation mechanism.
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
from source. Review fixes before landing included exact int/float comparison
beyond 2^53 (`compare_int_float`, covering ordering comparisons — a fix beyond
the original milestone sketch). That accepted behavior now lives in the
promoted CLI snapshot. ZLint was promoted from advisory to
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
continuation. One implementation correction is recorded: exact
top-level rollback retains the immutable entry cells, because a saved
depth cannot recover a pre-existing value consumed before failure;
attempt/dict isolation remains base-index truncation. Post-audit hardening
also locks nested-boundary restoration, substack-relative contract data,
recursive trace multiplicity, attach-if-absent context for `raise`, direct
and flushed `io.pp`/`io.prin` output, and single-EOF REPL exit.
REPL stack display and `io.pp` now use delimiter-preserving K-style row breaks
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
scalar path, `io.pp`/`io.prin`, `def`/`set`, `if`/`call`/`while`, `@attempt`/
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
1859966 is green. Generation and binding leases reclaim displaced
payloads after the last owner releases them; the multiwriter fixtures
cover both repeated and disjoint module names.

**Definition of Done**:
ARCHITECTURE.md §Environments in full: binding cells (rebind swaps the
interior), per-env shape generations, the single `env.bind()` funnel,
lazy child envs shared by every isolated boundary, deep-binding chain
resolution, core frozen after prelude install. The d.18 module system:
`@module`/`use`/`alias`, dotted
qualified access, `defp`/`setp` (top-level error), registry as
name → atomically swapped `{env, generation}` with commit-after-success
and **whole-body generation pinning**, plus the multi-writer registry
swap protocol. Reflection: `body`, `doc`, `words`, `which`, `see`. **New over
the skeleton**: `load` (file as one unit) and `ECL_PATH` auto-load on
unregistered `use`, and the native-builtin-module mechanism (modules
pre-registered at startup whose bindings are primitive-backed — the
static substrate M12 reuses after M9 replaces the public callback seam).
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
(env enumeration), M9 native module publication, and M12 stdlib modules.

---

### Milestone 5: kernels-and-pervasion

**Status**: executed for public behavior, representation, and error semantics.
Debug, ReleaseSafe, ReleaseFast, the named TSan suite, formatting, blocking
ZLint, the ported walking-skeleton coverage, and the promoted CLI snapshots are
green locally. A post-v1 implementation audit found that one structural
performance clause in the original seven-patch design did not land: flat leaves
exist, but kernel pervasion still reboxes each element as `Value`, executes one
scalar node per element, accumulates an `OwnedValueBuffer`, and only then
materializes a specialized result. There is no once-per-operation
`(op × leaf-tag)` dispatch table, monomorphic raw-slice loop family, block fault
mask, or output-buffer adoption path in the current implementation.
Post-terminal Step 14 owns that migration. This correction does not reopen any
accepted M5 semantics.

**Definition of Done (semantic surface executed; structural fast-path remainder
moved to post-terminal Step 14)**:
The intended kernel boundary reuses `value.HeapKind` as the sole tag domain;
kernel entry consumes owned operands and returns one owned result. Pervasion is
bounded explicit-frame descent with scalar extension, leading-axis
conformability, and dict key-union/value alignment. The missing flat-leaf
specialization—once-per-operation dispatch, monomorphic typed-slice loops,
explicit half-open ranges, block fault masks with scalar rescan, and the
mask-before-store aliasing rule—is now the Step 14 contract rather than a claim
about M5's as-built state. The landed d.22 float semantics reject NaN-producing
operations and preserve exact mixed-number comparisons. Full
numeric/logic, structural/order/search vocabulary works over leaves and
spines: `at where in? find raze cat take drop reverse first rest range
shape len`, **new words** `flip`, `reshape`, `group`, `type`,
canonical `str`, `to-dict`, the early source-defined `wrap`/`pair`,
list `put` (functional element update, same word as dict
put, CoW-in-place when unique), the awk-floor transcendentals
`exp log sin cos atan2`, and `cmp`
(three-way whole-value ordering, ruled 2026-08-12: −1/0/1,
non-pervasive — `cmp` is to `<` what `match?` is to `=`; numbers exact,
chars by codepoint, strings codepoint-lexicographic, all else `'type`),
plus stable `grade`/`sort` ordering by exactly `cmp`'s order,
hash-backed `distinct`, dict kernels (`put del merge has? keys vals`),
and Unicode string kernels (`split join format`). Two semantics
rulings from the 2026-08-12 gap scan land here: `take` beyond length
cycles the data (K), and `where` generalizes from 0/1 masks to counts
(each index replicated count times, K).
Kernel unit tests cover every path and allocator failure; the promoted CLI
snapshot locks every previously shared M5 word, while real-binary coverage
locks `flip`/`reshape`/`group`/`cmp` plus the supplemental vocabulary and
extended `put`/`take`/`where` semantics.

The M5 `wrap`, `pair`, and `sort` bindings are ordinary target-word bodies
assembled by Zig as temporary bootstrap scaffolding. They are not new
primitives; M6 moves their authoritative definitions into ecl source.

**Why this is a safe pause point**: All data-plane behavior is complete and
bounded; flat-leaf kernels and combinators still pay the provisional
per-element boxed path that Step 14 removes after the v1 terminal.

**Unlocks**: M6 recognition has kernels to recognize into.

---

### Milestone 6: combinators-and-recognition

**Definition of Done**:
The d.14 combinators (`each zip-with for fold scan`) plus `infra` with
per-application contract checks as base-depth compares; the full
inline Control/Cleave surface finalized (`dip keep bi tri bi2 both
when unless times cond`, `case` as prelude — the Joy/APCL capture
ruled 2026-08-12, VOCABULARY.md correspondence note); the full
error/result vocabulary (`fail ok? or-raise or-else`); the prelude
installed from embedded ecl source ([E] words including `filter`,
`partition`, `any?`, `all?`, `both`, `bi2`, `case`, `unless`,
`signum`, `clamp`, `empty?`, `append`, `pack` (literal-count effect
inference per d.9), `zip`, `min-of`, `max-of`,
`at-path`, `at-or`, `pairs`, plus compact former primitives `over`, `compose`,
`dip`, `mod`, `neg`, `abs`, `<>`, `<=`, `>=`, `and`, `or`, `first`,
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
whole-value `match?`, permits duplicate keys with the first match winning,
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
remain in `zig build test`; initialized-Session paths share two coarse
ReleaseSafe probes under `zig build test-oom`. The established runtime and the
M12 data/host surfaces each pay one prelude bootstrap, avoiding both a Session
per surface and the quadratic cross-product of one ever-growing probe while
preserving kernel, primitive, reflection, loader, module, host, and
metadata-publication coverage. Separate filtered test artifacts execute the
two exhaustive ordinal replays concurrently; completion of both is required
for the gate. Because replay cost grows quadratically with the initialized
Session's allocation count, this full-system proof is a release-candidate gate,
not a per-push CI task; focused component probes remain blocking per push.

**`parse` is the pure reader boundary.** `( string -- q )` UTF-8-encodes the
character vector, invokes the ordinary reader with source name `<parse>`,
and returns all top-level forms in order as one unevaluated generic
quotation. The returned root and nested span tables move into the Session
provenance archive, so a later `call` reports `<parse>`. Non-string input is
`'type`; malformed and incomplete source are `'parse`; cancellation and OOM
leave no partial result. Encoding, lexer/parser scans, binder lowering, and
result/span materialization poll inside their actual traversals. This adds
no host capability: `io.slurp`, `io.spit`, `getenv`, and the source-defined
`io.lines` remain absent until M12.

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
equality, representation parity (brackets), the same success/failure result,
and bit-identical successful floats, with a required fast-path hit so fallback cannot
pass vacuously. The former walking skeleton's full 44-test behavior surface
is ported and green against the Zig binary.

**Why this is a safe pause point**: ecl is feature-complete except
concurrency and stdlib; the harness guards everything behind it, and the
derived core vocabulary now has one inspectable target-language source of
truth rather than host-encoded bodies.

**Unlocks**: M7 (par-each rides spawn), M12 (str module uses kernels +
prelude machinery).

**Established Precedents** (milestone-scoped):

- **[documentation] Gforth — “Forth is written in Forth”** — https://gforth.org/manual/Forth-is-written-in-Forth.html — keep the host kernel small and express the extensible language layer in the language itself.
- **[documentation] Julia system images** — https://docs.julialang.org/en/v1/devdocs/sysimg/ — a precompiled image can later improve startup without replacing source as the semantic authority. For ecl this remains a profile-gated post-v1 optimization, not an M6 deliverable.

---

### Milestone 7: scheduler-and-concurrency

**Definition of Done**:
ARCHITECTURE.md §Scheduler: green units on a lazily-spun fixed worker
pool (no threads until first `@spawn`; 1-worker config supported),
fuel/reduction safe points including kernel chunk polls (~64K
elements), task cells (write-once, multi-waiter, per-cell mutex) with
single-winner wait-policy transitions (no double-enqueue), cancellation with
kill-on-arrival and waiter-list removal, structured lifetime with
wait-for-quiescence at scope close, cancelled results as
`{'err {'kind 'cancelled …}}`, one timer thread + binary heap for
`await-for`, stdout whole-write lock. Vocabulary: `spawn await
await-any await-for cancel tasks @each` [P] and `await-all` [E]. The
bounded `@each` driver represents each captured element directly as the
child Unit's one-value initial stack, publishes tasks without synthesizing or
copying quotations, and transfers them to an evaluator-owned ordered join
state. No private join word is installed. The determinism suite runs
the full test corpus at 1 worker and N workers asserting identical results.
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
linked to live Session state. Both `str` and `io.pp` render a task as its
stable per-Session `<task:N>` marker; the reader rejects that exact
runtime marker wherever an atom may occur, so a task or any rendered
structure containing one is deliberately unparseable. Decision 16's
canonical reader round-trip applies only to values containing no
session-linked runtime object. Scheduling remains cooperative rather
than arbitrary native-stack preemption, but every user-sized traversal
has one explicit cursor implementation. Scheduler-attached drivers preserve
that cursor and its partial result and return to the scheduler within the
accounted-work quantum; blocking bootstrap and tool shells drive the same
cursor without introducing a duplicate traversal mode. Process exit is owned by the
root Unit outside `@attempt`: `exit` in a spawned Unit or inside `@attempt`
raises an ordinary catchable `'domain`, while an allowed root exit
closes, cancels, and quiesces the root task scope before exposing its
status to the CLI.

Value destruction is one of those user-sized traversals. M7 now has one
allocator-scoped `ReleaseDomain`: `OwnedValue` drops only make the
reference-count transition and enqueue zero-count objects, exact-capacity
partial buffers retire as one domain-owned heap root, unknown reader output is
held by a fixed-chunk `OwnedValueChain` with one root, and scheduler/root turns
drain the domain in fixed chunks. Work-driver and continuation teardown receive
that domain explicitly. Every driver carries an exhaustive ownership policy:
field-derived teardown forbids a destructor hook, bounded teardown requires its
intrusive retirement state, and coordinated self-teardown is restricted to
address-stable aggregates. Structured owned payloads with both `retire` and
`deinit` must choose the cancellation-safe protocol at compile time. The
evaluator exposes only `OwnedValue` for live stack pops. Blocking host helpers
drain a local domain but do not implement another graph walker, and no operation
allocates an independent release cursor.

**Why this is a safe pause point**: The language surface of DESIGN.md
is complete; only scope-ruled stdlib and REPL polish remain.

**Unlocks**: M9's typed native `Reschedule` continuation on the production
`WorkDriver`, M12's internal HTTP exception, and M13 acceptance.

---

### Milestone 8: repl-line-editing

**Status**: executed from `gameplans/repl-line-editing.json` (2026-08-16).

The as-built Session completion facade owns and settles its visibility and
registry snapshots through phase-owned cursor variants; completion before the
first unit reaches core names without an intermediate invalid state. Session
renderings own their storage without exposing host allocation authority;
production comptime validation rejects authority-bearing public Session
returns and observation-lease parameters. Console callers receive only narrow
whole-write operations. The editor owns raw-mode restoration and a nominal
line result, and keeps cursor/storage inside an opaque buffer whose fallible
splice owns arbitrary replacement bytes while a total non-growing transition
owns deletion. Transposition derives adjacent editor/display units inside the
opaque buffer and reverses them through that same alias-safe splice, including
when either unit is a malformed byte. Every transition re-derives the cursor.
The editor receives capabilities
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
- **[library] linenoise (antirez)** — https://github.com/antirez/linenoise — the minimal, battle-tested line-editing model; bind or port its focused core to Zig rather than inventing an editor.

---

### Milestone 9: native-extension-abi-and-loader

**Status**: executed `gameplans/native-extension-abi-and-loader.json` on
2026-08-16; this section is the durable as-built record. Seven patches: the installed rebaseline
plus the frozen ABI-v1 wire contract, the
bounded descriptor validator, the `ecl-native` SDK and build helper, retirement
of the general-stack seam, native first light (loader typestate, `.eclmod`
resolution, atomic publication, transactional leaf call, reflection), the typed
`Reschedule` continuation with ordered shutdown, and acceptance. Planning
narrowed the milestone to exactly the capability set M12's CSV and JSON modules
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
version, callback table, definition count and indices, canonical names, UTF-8
documentation, effects, and capability ids are validated and copied through
bounded cursors before host-table installation or registry publication. The
pre-release ABI accepts exactly one version, exact record sizes and strides,
and the current capability set. Unsupported platforms, architectures, ABI
versions, malformed descriptors, unknown capabilities, name mismatches,
duplicate words, missing documentation, invalid effects, invalid continuation
layouts, or an entry point that reports
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
per-producer validation policy. With native module backing state deferred,
`initialized` constructs the
pinned instance from validated metadata. The SDK descriptor itself occupies
addressable image-lifetime storage, so the entry point cannot return a pointer
to a comptime value materialized in its stack frame. Dynamic images use the operating
system loader; Linux runtime artifacts link libc dynamically and never route extensions
through Zig's relocation-incomplete static ELF mapper. Validator records and
generated adapter cursor backing use explicit empty/populated states, so phase
or capability access cannot read uninitialized storage in optimized builds.
The host table is minted only for an
invocation, so no artifact-stored host pointer survives a call; a future SDK
module-state capability can extend that variant without reshaping the
typestate. Native bindings
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
descriptor. That static arm is the transport M12's CSV and JSON modules use; it
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

**The initial capability set remains deliberately closed, at exactly what M12
consumes.** Mandatory `Call` plus optional `BuildValues` and `Reschedule` are
the complete callback surface. CSV and JSON are pure value-in/value-out
transforms, so nothing in the v1 native callback surface needs per-module
state. SDK access to M11's internal module-stack draft and outward-transfer
authority is
therefore deferred alongside
native resource values, persistent ECL-value pins, package assets, external
wake, blocking jobs, quotation evaluation, and task/runtime mutation as future
capabilities. The SDK deferral is unreachable rather than half-present: the
descriptor and capability enum contain no module-state fields, factories, or
ids.
`Offload` is the expected first scheduling addition; the M12 HTTP builtin
remains a documented internal direct-blocking exception in v1 and does not widen
this SDK.

**Proof is production-connected.** A real SDK-built shared-library fixture is
loaded through `ECL_PATH` by the release binary and exercises every operation
of every public capability. Compile-fail build fixtures prove malformed effects,
callback shapes, capability duplication, output-arity mismatch, duplicate words,
and missing documentation without tests that inspect implementation text. Loader
cases cover source/native precedence, path order, first-candidate failure,
name/ABI/capability mismatch, entry-point failure rollback, all-or-nothing
reflection, exact record validation, and the static and dynamic image pins
reaching the same publication path. A delayed-continuation shutdown property
uses the real scheduler, cancellation path, registry pins, image release, and a
DebugAllocator baseline rather than inspecting private representation.
`fuzz-native-descriptor` drives arbitrary bounded metadata through the
production validator with valid backing ranges. Comptime reflection varies
every integer size field; malformed shared-library fixtures separately cover
entry results, strided records, and module-written wire tags.
`fuzz-native-call` selects bounded sequences of public SDK-fixture programs and
executes each through the dynamically linked production CLI, observing only its
exit status and ECL output. Keeping the coverage runner static avoids Zig 0.16's
dynamic-musl coverage-map failure without substituting an internal transaction
model for observable behavior. Separate runtime tests exercise one/eight-worker identity, over-quantum builders,
malformed artifacts, and spawned loading; the TSan gate runs those
production-connected tests, while a DebugAllocator delayed-continuation test
proves complete Session teardown. Focused allocator
failure sweeps remain in the ordinary suite; exhaustive initialized-Session
native loading/call coverage is added once to `src/tests/oom_test.zig` and
`zig build test-oom`.

All nine campaign artifacts select LLVM explicitly. On x86_64 Linux, Zig
0.16's self-hosted backend accepts `-ffuzz` while producing an empty sanitizer-
coverage PC table; backend selection is therefore part of the campaign proof,
not an ambient host default. The bounded runner fails before input execution if
the selected artifact does not publish nonempty coverage metadata.
SourceHut task bodies explicitly enable immediate exit, unset-variable
rejection, and pipeline failure propagation. This is load-bearing for the
nine-target loop: a failure in any target ends the task instead of being
replaced by the final iteration's status.

M9 added the native SDK, ABI, loader, fixtures, and runtime tests to the
source audit's exhaustive manifests. The post-implementation boundary review
required runtime-minted capability tables, resumable aggregate builders,
typed strided record arrays, turn-scoped candidate generations, and owner-only
image settlement; those explicit states remain architectural invariants rather
than being collapsed into caller-specific policy.

**Why this is a safe pause point**: Source modules and language semantics are
unchanged; a rejected or failed native artifact has no registry visibility, and
every successful artifact is pinned through complete Session teardown. The
public surface is useful for value-in/value-out native acceleration without
committing v1 to resources, blocking pools, VM reentry, or application
embedding.

**Unlocks**: User-authored native extensions; M12's CSV/JSON modules as
first-party consumers of the same callback protocol; future SDK access to
M11's module-stack authority, `Offload`, resource,
external-wake, package-asset, and evaluation capabilities.

**Established Precedents** (milestone-scoped):
- **[documentation] Erlang NIFs** — https://www.erlang.org/doc/apps/erts/erl_nif.html — ordinary NIFs demonstrate the non-preemption hazard; timeslice consumption and scheduled/dirty work motivate ECL's typed `Reschedule` now and a future `Offload` capability.
- **[documentation] Janet native modules/C API** — https://janet-lang.org/capi/ — the small-language dynamic-module ergonomics precedent, narrowed here to one generated Zig module descriptor and semantic capabilities instead of a mutable VM pointer.

---

### Milestone 10: one-binder-merge

**Status**: executed from `gameplans/one-binder-merge.json` on 2026-08-17;
this section is the durable as-built record. Five patches, one BEHAVIOR: the
skipped stubs naming the merge's observable contract, capture-shape idiom
recognition, the flip (prelude `set`/`setp` over `literal` + `def`/`defp`,
builtins retired), deletion of the unproducible value arms from `Binding`
and both publication typestates, and the SPEC.md/INTERPRETER.md rewrite.
Counts landed at 88 primitives and 66 documented prelude blocks (the plan
said 62; the working tree also carried the `partial-all` → `with` rename and
the new `with 'name @module`). One planned piece was dropped during execution as
unreachable — the direct-context capture idiom entry — and its underlying
cost is carried as post-v1 follow-up 14.

Ruled 2026-08-17 (see Decisions Made); slotted before stateful modules and the
stdlib so M11's construction-time constants and M12's embedded modules are authored once
against the merged semantics, and
before the `0.1.0` tag because it changes observable behavior —
prerelease is when to break. It reopens M4-frozen binding surface
deliberately, as its own milestone rather than a silent edit to an
executed one.

**Definition of Done**:
One binding kind exists. Bare reference always applies the stored body;
the word|value binding tag is deleted from binding cells, environment
entries, reflection output, and the publication typestates (the
module-callable-requires-`ValidatedEffect` / value-cannot-carry-one split
collapses: every module binding is a callable with a mandatory effect).
Concretely:

- **The equivalence law is the invariant:** `v 'name set` is
  observationally `v literal (-- value) 'name def` (the annotation is part
  of the equivalence: it is what reflection reports and what satisfies the
  mandatory module effect) — it publishes the literal-capture
  body `((v) first)`, safe for every value kind (words, quotations, dicts,
  task handles, `()`), and `setp` likewise over `defp`. `set`/`setp` keep
  their names and always attach the synthesized effect annotation
  `(-- value)`, uniformly in and out of modules, satisfying the mandatory
  module effect while remaining harmless top-level metadata. The
  never-recognize-annotations guarantee holds mechanically: captured
  marker-bearing data ends up nested and inert.
  *(Superseded by Milestone 11, which made module annotations optional and
  dropped the synthesized `(-- value)`: the landed law is
  `v 'name set == v literal 'name def`, with no annotation at all. The text
  above records what M10 shipped.)*
- **Placement is prelude source** —
  `set = (swap literal swap (-- value) swap def)` — demoting both words
  from primitive to prelude (primitives 90 → 88). The gate on this
  placement is resolved (gameplan grounding, 2026-08-17): `def` executed
  inside another word's body writes the *unit's current scope*, never the
  executing frame's resolution environment, because `scheduleWord`
  (`src/machine.zig`) keeps the caller's scope and home for core words —
  so top-level `set` binds the session, module-body `set` binds the
  module root, and `defp`'s module-root check stays correctly dynamic.
  The test "definitions: def inside a word body writes the caller's
  scope" pins the rule; the equivalence law remains the invariant.
- **Reflection is total and honest.** `body` works on every binding
  (`'x body` on a set-bound name returns the capture, printed `([3] first)`); `see`/`which`
  print the stored body with no reconstruction of set-sugar spelling (the
  deleted tag must not reappear as a display heuristic). A captured task
  handle makes `see` non-re-readable, matching today's value display.
  Module constants become documentable via raw `def`/`defp` with a full
  annotation — previously impossible through `set`.
- **Redefinition is uniform snapshot replacement** — no kind flip; `def`'s
  non-list-body error still points at `set`.
- **Idiom recognition covers the `((v) first)` capture shape** through the
  existing guarded bridge, differentially tested like every idiom and
  observationally invisible. Shipped in combinator context (`[capture,
  op]` and `[capture, swap, op]` at `each` entry), which is what
  `partial`-built quotations reach. The direct-context entry for constant
  bodies was dropped during execution as unreachable — direct recognition
  is gated on core origin and core holds no `set`-published names — and
  the underlying cost is carried as post-v1 follow-up 14.
- The multi-value/single-list distinction is legible in bodies:
  `(1 2 3) 'xs def` pushes three values; `[1 2 3] 'xs set` pushes the
  list.
- SPEC.md (Evaluation, Bindings, Definition annotations, Modules, and the
  `def`/`defp`/`set`/`setp`/`body`/`see`/`which` entries), INTERPRETER.md
  (binding cells, typed publication, idiom table), and the snapshot corpus
  are rewritten to the merged semantics in the same change.

**Why this is a safe pause point**: It deletes a semantic axis rather than
adding one; every observable delta is in reflection output and error
cases, and the write-time `def`-vs-`set` intent distinction
(store-as-code vs store-as-data) is unchanged — only its representation
moves from a hidden tag into inspectable structure.

**Unlocks**: M11 can add a durable module stack without changing binding
representation; M12 authors the embedded `str` and `table` sources and the
native modules against final binding semantics — no migration pass; a
simpler M13 acceptance surface; the deferred static checker (Post-v1
follow-ups, item 1) sees constants as ordinary words with known
`( -- x )` effects and loses its values-cannot-carry-effects exception.

**Established Precedents** (milestone-scoped):
- **[standard] Forth `CONSTANT`** — https://forth-standard.org/standard/core/CONSTANT — one dictionary, everything executes; a constant is a word that pushes.
- **[documentation] Factor `CONSTANT:`** — https://docs.factorcode.org/content/word-CONSTANT__colon__,syntax.html — the same one-kind answer in a modern concatenative vocabulary.

---

### Milestone 11: stateful-modules

**Status**: landed 2026-08-18 — gameplan `gameplans/stateful-modules.json`.
Nine original patches plus the M11 addendum, ungated pre-`0.1.0`.
Sub-rulings from planning,
folded into the DoD below: the reload barrier is uniform with a
quiescent-slot fast path; self-directed reload/`unmodule` is `'domain`;
`unmodule` canonicalizes alias names. The 2026-08-18 addendum removes public
module handles and `__MODULE__`, adds dotted canonical module names with
final-dot qualification, and adds `qualify` plus `execute`.

Two planning assumptions did not survive contact and the DoD below records
what landed instead. **Quiescence is arbiter order, not pin drain**:
generation pins are held for a whole Unit lifetime, so "drain the target's
pins" can never complete for a script that calls a module and then reloads
it — exactly what DoD-12's `hot-reload.ecl` does. Re-registration and
removal therefore take an ordinary place in the slot's fair FIFO, which
orders publication against every queued and active state application, and
the invariant "old code cannot publish state after a new representation
becomes current" is enforced directly: a `within` whose home generation is
no longer current is `'domain`. **Self-directed therefore means "from
inside any state application"** — the unit already holds one slot's turn,
and waiting for a second is the deadlock shape `within` refuses everywhere
else — rather than "from code holding a pin". A single per-unit turn
authority, spent by `within`, reload, and removal alike, makes that
unrepresentable rather than separately guarded. The arbiter is
a cooperative-yield FIFO — a waiting unit yields as ordinary resumable
scheduler work rather than parking on a dedicated wake reason; it holds no
OS lock across ECL execution and cannot starve, but it does consume
scheduler turns while waiting, and a dedicated wake path remains available
as a later optimization.

**Definition of Done**:
The existing dynamically constructible module registry becomes ECL's
userland durable-state layer without adding an actor, mailbox, or resident
task. Every canonical module registry slot owns one immutable snapshot of a
durable operand stack per Session, distinct from its replaceable immutable code
generation; the only mutation is transactional publication of a replacement
stack snapshot. Concretely:

- **Validated names describe the public surface.** `ModuleName` is one or more
  valid nonempty segments joined by dots, `BindingName` is one unqualified
  non-reserved segment, and `QualifiedName` is their validated composition.
  Registry APIs, environment APIs, and qualified dispatch accept the matching
  nominal brand, so raw intern ids cannot be accidentally substituted. A
  qualified executable name splits at its final dot; aliases remain
  unqualified. `'name (body) module` and
  the source-defined `with 'name @module` constructor build a candidate; the first
  successful registration of a canonical name creates its slot, while later
  registrations replace only its code generation. Separately constructed names
  own independent stacks even when their bodies come from the same quotation.
  Construction from inside another module remains
  registration in the same flat Session registry, not lexical nesting or
  parent ownership; the created slot has an independent lifetime and its
  completed registration is not rolled back if the constructing body later
  fails. There is no public slot-identity value; lifecycle operations are
  name-based, and a removed canonical name may later select a new slot.
- **Construction produces the initial state stack.** While a module body is
  registering, `def`/`defp` and `set`/`setp` retain M10's one-binding
  representation and build only the immutable candidate code environment. The
  isolated body's final operand stack becomes the durable initial stack for a
  newly created slot instead of being required to be empty. `values (body)
  with 'name @module` supplies its values in order as that construction stack's
  initial contents, using `with` exactly as `with @attempt` and `with @spawn` do;
  the body may consume, reorder, or extend them before publication. On
  re-registration, the successfully built candidate's initial-state stack is
  discarded and the existing slot's durable stack is retained: initialization
  happens once per slot identity, not once per code generation.
- **Source annotations become optional everywhere.** Module `def` and `defp`
  accept the same four forms as top-level `def`: no annotation, effect only,
  documentation only, or both. A declared module effect remains a live
  caller-stack contract checked when execution crosses the module boundary; an
  omitted effect means no such check, not an inferred effect. Malformed
  recognized annotations remain `'domain`, and reflection preserves whether
  each portion is absent. This source-language relaxation does not weaken the
  native ABI's mandatory typed `Call` effect, and the shipped prelude keeps its
  stronger repository policy requiring meaningful documentation.
- **Ordinary module words still use the caller's stack.** An optional
  `(before -- after)` annotation describes and, when present, checks only the
  externally observable caller-stack contract. It acquires no state marker and
  moves no values implicitly. Stateless module words and all existing stdlib
  modules therefore retain their ordinary concatenative behavior.
- **`within` is the explicit stack boundary.** `within`, with effect
  `( quotation -- outputs... )`, is a new core primitive legal only while
  executing a published word whose definition-site home is a live module; the
  registration root already operates directly on the candidate construction
  stack and does not use `within`. The quotation resolves with that module home
  and runs against a private draft of the slot's durable stack, never the
  ambient caller stack. Inputs cross the boundary only because the word body
  explicitly captures them into the quotation with existing composition tools:
  `partial` for one value, or `with` when a list should supply several values.
  Extracting a body and redefining it elsewhere changes its home and therefore
  loses this authority. There is no module-handle-targeted form. Semantically,
  `within` is the module-scoped transactional counterpart of Joy's `infra`:
  `infra` continues to use an explicitly supplied list as a temporary stack,
  while `within` selects the invoking word's durable home-module stack.
- **`without` is the explicit outward boundary.** The second new boundary
  primitive, `without`, pops the draft's top value inside an active `within`
  quotation and appends it to a pending output sequence; elsewhere it is
  `'domain`. Multiple outward values reach the caller in invocation order. A
  value remains on the durable stack and is returned only when the quotation explicitly
  duplicates it before `without`; values captured with `partial` or `with`
  remain in state unless the quotation consumes or moves them outward.
  Before publication the runtime reserves the exact caller-stack result window,
  so no allocation failure can commit state without delivering every output.
- **Each `within` application is the transaction.** Success publishes the
  remaining draft stack once and then transfers the already-owned outputs to
  the caller. Error, cancellation, OOM, contract failure, or `without`
  underflow discards both draft and pending outputs and propagates normally. A
  later failure in the enclosing word or Unit does not roll back a `within`
  application that has
  already returned successfully, matching ECL's existing rule that Unit stack
  rollback does not undo completed environment or IO side effects.
- **`within` applications are serialized scheduler work, not mutex-held
  evaluation.** One fair per-slot arbiter orders drafts. It holds no OS lock
  while ECL code executes and permits ordinary bounded scheduler yields.
  Parking (`await`/deadline waits), nested `within`, and an application
  homed in another module are rejected as `'domain` before parking or acquiring
  another slot, preventing self- and cross-module deadlocks. Ordinary calls,
  including read-only calls into other modules, remain available inside the
  quotation; only another `within` boundary is prohibited.
- **Dynamic word construction preserves ordinary semantics.** `qualify`
  validates a `ModuleName` symbol and `BindingName` symbol and constructs their
  qualified executable word without reparsing source. `execute` applies a word
  through the ordinary late-bound dispatch driver, preserving definition-site
  home, private lookup, annotations, tracing, native/builtin behavior,
  cancellation, and `within` authority. Internal homes remain capabilities,
  never ECL values.
- **Bindings remain immutable after registration.** M11 does not contextualize
  `set`/`setp`, add `unset`, or place mutable bindings in name resolution.
  M10's one-binding representation remains unchanged, while optional module
  effects let the prelude definitions simplify to the exact equivalences
  `value 'name set == value literal 'name def` and likewise for
  `setp`/`defp`, with no synthesized `(-- value)` annotation. `set`/`setp` in the construction
  body still define code-generation constants, while a later attempt to mutate
  the frozen module environment fails exactly as it does before M11. Existing
  `del` remains solely the pure `(dict key -- dict)` transformation.
- **Hot reload preserves the stack.** Re-registration constructs a new code
  generation while retaining the slot and its durable stack. It takes an
  ordinary place in the slot's fair arbiter order, so every `within`
  application queued before it runs against the old generation and finishes
  first and every later one runs against the new one; no application
  straddles the swap. Old-generation code may keep running under its pin,
  but it cannot publish state once a new representation is current: its
  `within` is `'domain`. The barrier is uniform across stateless and
  stateful modules; a quiescent slot (the sequential common case) commits
  immediately as today, and a re-registration initiated from inside any
  state application is `'domain` before any wait: a unit owns one turn
  authority, so waiting for a second slot's turn — the target's own or
  another module's — is the deadlock shape `within` refuses everywhere
  else. Failed
  registration changes neither code nor state. Stack-layout evolution is an
  explicit userland protocol: replacement code must understand the retained
  representation and may migrate it with an ordinary first `within` operation;
  the runtime neither inspects nor names positions in the stack.
- **Removal completes the lifecycle.** `unmodule` accepts a module name
  (alias names canonicalize exactly as `use` and qualified resolution do);
  an unregistered name is `'undefined-word`, and removal from inside any state application is
  `'domain` like re-registration. It closes new resolution, calls, and `within`
  applications, waits through the same arbiter order for queued and active
  drafts, removes aliases targeting the slot,
  then retires code and every value on the durable stack through bounded
  work. Concurrent
  resolution observes either the live module or `'undefined-word` once close
  begins, never a half-removed entry. Session shutdown consumes the same
  `live -> closing -> retired` protocol.
- **No hidden resource or persistence promise.** Native opaque resources,
  persistence across process restart, and SDK exposure of the internal module
  stack/draft capabilities remain later extensions. A future connection module
  supplies opaque connection values natively while its pool policy and
  singleton coordination use this userland state mechanism.
- SPEC.md and INTERPRETER.md record uniform optional source annotations,
  branded name domains, construction-stack ownership, `within`/`without` boundary
  and failure semantics, arbiter fairness, hot-reload barrier, removal
  typestate, and ordered Session shutdown. The type
  system makes a state application one tagged owner of the module-stack draft,
  pending outputs, home authority, and publication transition; only the
  definition-site home can create it, and worker-visible code cannot obtain the
  lifecycle authority required for blocking teardown. The source audit covers
  only constraints the compiler cannot express.

**Why this is a safe pause point**: Existing annotated stateless modules retain
their contracts and binding semantics, while previously inexpressible
unannotated and documentation-only module words have explicit reflection
behavior. Stateful modules have a complete construction, explicit caller/state
transfer, transactional update, reload, removal, and Session-shutdown
lifecycle; there is no published stack or pending output that can be created but
not safely retired.

**Unlocks**: Userland counters, registries, caches, service configuration, and
pool policies as dynamically constructed singleton modules; M12 stdlib modules
may use durable Session-local state without adding private host globals; future
native resource values can inhabit the already-proven ownership and update
protocol.

---

### Milestone 12: stdlib-result-str-csv-json-table-http

**Status**: landed 2026-08-18 — gameplan
`gameplans/stdlib-result-str-csv-json-table-http.json` (local, untracked
per convention; the substance below stands on its own). Ten patches,
ungated pre-`0.1.0`. Planning rulings folded into the DoD: the http spike
ran and `std.http.Client` won; qualified reference to an unregistered
module auto-loads exactly as `use`-miss; embedded stdlib wins over
`ECL_PATH`; `str` ships sixteen words; `http` ships two fixed-arity words;
`stdin` closes Open Question 1.

Four planning assumptions did not survive contact, and what landed differs.

**The native SDK could not express `csv.emit` or `json.emit`.** `list_at`
reaches only a declared input's top level and a `ValueView` of an aggregate
exposes a length and nothing else, so no module — first-party or otherwise —
could read a list of lists. The SDK gained a path-addressed nested read
(`read_path`, gated by the existing `reschedule` capability, so the
descriptor and capability wire are unchanged), and `ecl.module` gained a
`linkage` spec so a statically linked module does not claim the ABI entry
symbol two first-party modules would collide on.

**`json` and `http` are internal builtins, not SDK modules** (user ruling
during execution). The SDK withholds an allocator and any state that
outlives a yield, which is exactly what `std.json.Scanner` needs, so
hand-rolling a JSON grammar was the only SDK-compatible option and was
rejected in favour of the standard library's. `csv` stays the first-party
proof of the public callback protocol — Zig has no CSV library, so
hand-rolling was forced there regardless.

**Two pre-existing defects blocked the milestone and were fixed.** The
loading lease recorded only that a name was being loaded, never by whom, so
any interleaving — at one worker too, since the load driver yields
mid-source — reported a bogus recursive-auto-load `'domain` to every
requester but one; the node now records its owner, and contention waits and
re-resolves. And a binding with no module home resolved its word references
against whatever environment happened to be executing, so a module exporting
a word named like a core one reached inside every prelude word it called: a
module defining `where` broke `filter`. `Eval` frames now carry a separate
resolution scope, so every binding resolves in the chain it was defined
against, with no exceptions. Late binding is unchanged; dynamic scope is
what went away. Both are recorded in SPEC.md and INTERPRETER.md.

**A builtin module word cannot declare an enforceable effect.** The
cross-home effect check runs the instant a builtin primitive returns, which
precedes any output a scheduler driver it started will produce. Builtin
module words are therefore exempt exactly as source module words already
were, and `json`/`http` state their stack shape in prose. `http` also ships
without a request deadline: the blocking call is the documented v1
exception, and a half-deadline that only fires between operations was
declined in favour of recording the limitation.

**Definition of Done**:
Eight stdlib modules ship inside the binary (embedded sources / native
descriptors registered lazily through M4 plus M9's private static transport,
so the single-binary story holds; `ECL_PATH` remains for user modules), each
resolvable by `use` and by bare qualified reference with no `ECL_PATH` and no
filesystem. CSV
and JSON are first-party consumers of the public typed callback/capability
protocol without becoming external runtime dependencies. The same milestone
owns the explicit host scripting words needed by that layer:
- **`result`** — ecl source over the core `{'ok values}` / `{'err error}`
  representation. It exports constructors and observations (`result.ok`,
  `result.err`, `result.ok?`, `result.err?`), success composition
  (`result.and-then`), failure transformation (`result.map-err`), broad and
  kind-selective recovery (`result.recover`, `result.recover-kinds`), an
  exhaustive eliminator (`result.either`), and list aggregation
  (`result.all`, `result.partition`). Successful values are always a list
  representing a stack, never one privileged scalar. `result.and-then` seeds
  that stack into its quotation through `with @attempt`; an existing error is
  returned unchanged. Recovery seeds the error dict as one value and runs the
  recovery quotation through `with @attempt`; `recover-kinds` leaves an
  unmatched result unchanged. `result.all` preserves input order and returns
  the leftmost error unchanged, or one successful value containing the list
  of per-result success stacks. `result.partition` returns success-stack lists
  and error dicts separately without re-raising. All operations reject a
  malformed tagged result before invoking a supplied quotation.
- **`str`** — ecl source, exactly thirteen words (reaffirmed 2026-08-19):
  `upper lower trim trim-left trim-right starts? ends? contains? index-of
  replace repeat pad-left pad-right`. Case operations are ASCII-only per
  the character-model ruling; `index-of` is `'domain` when the needle is
  absent, with `contains?` as the predicate form. Another embedded-source
  module built on the ordinary module path.
- **`io`** — builtin module with `pp`, `prin`, `print`, `inspect`, `stdin`,
  `slurp`, `spit`, and `lines`. `io.slurp` [P] `( path -- string )` reads one
  UTF-8 file, `io.spit` [P] `( string path -- )` writes one file, and `getenv`
  [P] `( name -- string )` reads an environment variable from an immutable
  snapshot taken at session init. Unset variables
  error per absence-is-absence, with `@attempt`/`result.or-else` as the defaulting
  idiom. `io.stdin` [P] `( -- string )` (ruled 2026-08-18) reads the whole
  piped stream once in `-e` and script-file modes and is `'io` in modes
  where stdin is the program source. `io.lines` `( path -- list )` composes
  `io.slurp "\n" split`. `io.pp`, `io.prin`, `io.print`, and `io.inspect`
  group the observable output operations, including those that accept arbitrary
  values; this is an I/O boundary, not a string-receiver boundary.
  These are explicit capabilities and do
  not alter the pure M6 `parse` contract. `io.spit` is truncate-and-replace
  with no temp+rename: a mid-write failure may leave a partial file,
  surfaced as `'io` and documented rather than half-guaranteed.
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
- **`http`** — internal builtin-backed module, client only:
  `http.get ( url headers -- response )` and
  `http.post ( url headers body -- response )` (fixed full arity, `{}` for
  no headers; ruled 2026-08-18), returning a response dict with 'status,
  'headers, 'body; TLS included, timeouts surfacing as 'io error dicts.
  Backend: `std.http.Client` (spike-resolved 2026-08-18); one client per
  call, no shared pool. Its words publish through the new `builtin`
  `ModulePublication` arm. Its blocking
  call runs on the unit's worker thread as the one documented first-party v1
  exception; it is not exposed as an SDK capability and migrates to the future
  `Offload` capability without changing its ECL value-level API.

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

### Milestone 13: v1-acceptance

**Status**: executed 2026-08-19 — the v1 terminal. `0.1.0` is tagged at
commit `27f47f3` and pushed; the complete per-push CI manifest is green on
that commit (builds.sr.ht job 1866102, all fourteen tasks through
acceptance), and the release-candidate matrix — the exhaustive
initialized-Session `test-oom` sweep plus the complete ReleaseFast suite —
ran green against the same commit (operator-attested at finalization,
2026-08-19). The final
ReleaseSafe CI target is intentionally nonduplicative: it runs the M13
retention, installed-binary, display-bounding, and architecture assertions
after the manifest's existing behavioral, PTY, native, worker, fuzz,
differential, TSan, and lint gates. The exhaustive initialized-Session OOM
sweep runs once against a release candidate instead of on every push; its
focused component probes remain in the ordinary suite. The README and printing
contract match the binary. Property-bearing test artifacts run through a
classified child runner that suppresses Minish's successful stderr chatter and
forwards actual failure diagnostics, so CI no longer labels green commands as
failed. The terminal ledger's 50 clauses (DoD-1 through DoD-48, including 25a
and 34a) were audited one by one against their named proof surfaces before
tagging. That pass repaired stale command spellings and added exact runtime
coverage for
grammar negatives, REPL rollback with environment survival, leftmost concurrent
error selection, unified-value/float/UTF-8 edges, partial effects, the complete
removed unit-constructor family, and result-envelope ownership. The per-push
optimization matrix runs the complete suite under Debug
and the distributed ReleaseSafe mode, while ReleaseFast compiles and exercises
the promoted real-binary snapshot corpus; the complete ReleaseFast suite joins
the exhaustive OOM proof on the release-candidate matrix.

**Definition of Done**:
The terminal acceptance suite below is implemented as a CI job
(fixtures + expect scripts where interactive) and green. README rewritten
around the real binary (install, tour, source-module guide, native-extension
SDK/build/trust guide). The source architecture audit remains a blocking CI
check: it exhaustively classifies first-party production and verification
inputs and checks only source-body boundedness, unsafe cast confinement, and
prelude layout where compiler guarantees cannot express the rule. Snapshot
retention is bounded (the M7
reclamation obligation): a soak fixture that defines and re-registers in a loop
shows stable memory. `io.pp` and the REPL stack display implement best-effort
huge-list elision so a unit producing a huge value cannot flood the terminal;
`str` alone carries the round-trip guarantee, and SPEC.md's printing contract
already reserves exactly this split (ruled 2026-08-17). A `0.1.0` tag
exists — the first prerelease tag, not a stable release (ruled 2026-08-17;
supersedes the earlier `v1.0` prescription).

**Why this is a safe pause point**: It is the end of v1; the tag is the
pause before the scheduled post-terminal migration.

**Unlocks**: Post-terminal Step 14 is the first scheduled performance
completion and migrates flat leaves onto the typed monomorphic kernel seam.
Other post-v1 work (scheduled Step 16's static effect checker bundle, d.9;
later performance evolution toward the K ceiling; exactness revisit) starts
from that proven v1 baseline, with SIMD/fusion/multicore depending on Step 14. The native
capabilities deferred out of M9 — SDK
exposure of M11's module-state authority, `Offload`, resource values, external
wake, package assets, and quotation evaluation — also start here. None blocks
the `0.1.0` tag: no v1 consumer needs them, and each requires an explicit
future wire-contract revision.

---

### Post-terminal Step 14: monomorphic-flat-leaf-kernel-migration

**Status**: executed 2026-08-19 — gameplan
`gameplans/monomorphic-flat-leaf-kernel-migration.json` (local, untracked
per convention). Patches 1-6 and the acceptance matrix are complete. The
exact boundary and gate ledger are inventoried below. The
typed seam now carries numeric and character pervasion, membership, rank-one
reshape, typed list replacement, sequence, ordering, grouping, distinct, and
text traversal, while generic spine/dictionary descent embeds the same typed
states at flat leaves. Also
landed, beyond the plan: `zig build test-kernels`
and `zig build test-e2e` as named steps, so the kernel slice and the CLI
acceptance run can be gated without building the whole suite. The plan below is
the original six patches: proof stubs; heap-issued typed capabilities
plus the closed comptime registry in `src/kernels.zig` with the shared
typed machinery in a new `src/kernel_flat.zig`; numeric/logical/bitwise
migration with block fault masks and the guarded numeric idioms; the
sequence/order/text/random migration; the cutover with capability closure,
audit extension, and INTERPRETER.md; and the benchmark tool plus checked-in
report at `design/benchmarks/step14-flat-leaf-kernels.md`. Two planning
rulings folded in (2026-08-19): **dead-code removal is an explicit cutover
deliverable** (user ruling) — kernel-layer helpers left without consumers
after the migration are removed, each verified by reference search before
deletion; and the dormant `kernel_support.Context` seam (zero call sites
as-built — every kernel bypasses `Unit.kernel_fuel` with bare `pollKernel`
plus local budgets) becomes the mandatory kernel budget seam rather than
being deleted, making the DoD's "WorkContext budget" concrete. The
grounding inventory also fixed the differential reference:
`list.fromValuesGeneric` builds generic-representation inputs so the
typed-vs-generic parity properties reach production semantics through a
real generic path, per clause 8. A third ruling (2026-08-19) reframed the
benchmark report: it is a post-state characterization whose durable
content is the deterministic counters, with timing as dated context —
never before/after migration proof, so no pre-migration re-run is
attempted (the deleted boxed route's per-element advances are
unobservable without rebuilding it, and the qualitative before-shape is
already recorded in this section's inventory). This is a
structural completion step, not a condition of the v1 terminal and not an
optional profiling experiment. It restores the implementation boundary that
M5's original design text claimed but did not build. The kernel migration
leaves public values, errors, representations, and scheduling guarantees
unchanged; the same finalization pass separately normalized the predicate
spellings to `in?` and `match?`.

**Execution ledger** (inventoried and completed 2026-08-19). The operation,
structural, and acceptance items are implemented. `src/kernels.zig` is the closed classification
ledger, with rationale kept as comments beside rows rather than unused runtime
metadata.

*Operation migration*

1. **`in?` (membership) — complete 2026-08-19.** Flat scalar and flat-list
   needles now scan a pinned typed haystack, using `equal.intFloatEqual` as
   the shared exact cross-kind numeric rule; flat-list results write their
   `leaf_i64` mask directly and scalar needles stay stride zero. Recursive
   generic-spine needles retain the bounded structural cursor and have their
   own explicit registry row. The parity matrix covers needle-in/out across
   all six leaf representations, both mixed numeric directions, a needle
   list, staging-block boundaries, and the kernel quantum; the initialized-
   Session OOM sweep reaches both new drivers.

2. **`cmp`, `grade`, `group`, and derived `distinct` — complete
   2026-08-19.** String `cmp` scans two pinned width-specialized character
   slices; flat `grade` keeps the stable `poll.MergeSortCursor` but compares
   raw typed keys and gathers either its i64 indices or sorted values directly;
   flat `group` preserves first-appearance order while comparing pinned raw
   keys and publishes each stable index leaf through `LeafWriter(.leaf_i64)`.
   Generic-spine ordering retains the structural comparator, but its known i64
   outputs now also publish directly rather than through `I64Materializer`.
   Parity covers every leaf kind, stability, symbol rejection, staging-block
   and kernel-quantum boundaries; the focused suite pins exact mixed-number
   ordering, cross-width strings, first-key order, and sorted representation.

3. **`split` and `join` — complete 2026-08-19.** Split dispatches once on
   subject/separator widths, scans pinned monomorphic slices, and profiles each
   result piece before selecting its exact-width writer. Join's outer spine
   selects one pinned child reader per string, profiles count and maximum
   codepoint in a bounded first pass, then fills one exact-width `LeafWriter`
   through a 256-codepoint staging block—no full-width output staging remains.
   An empty separator produces exactly the subject's Unicode scalar strings,
   without synthetic empty boundary pieces. Focused coverage pins char1/2/4
   boundaries, ordinary empty pieces, empty separators,
   separator-wider-than-subject, subject-wider-than-separator, and unused wide
   separators; the initialized-Session OOM snippet reaches both paths.

4. **`put` on a list — complete 2026-08-19.** A same-class replacement now
   performs an exact-size typed copy, or a single store when the input is
   solely owned under `UniqueLeafAdoption`; a replacement of another class
   still widens through the profiling route. The parity matrix covers every
   leaf representation, shared-input copy-on-write, cross-class widening,
   staging-block and kernel-quantum boundaries; the focused dict/text suite
   pins the unchanged original and index errors, and the initialized-Session
   OOM sweep reaches the allocating shared-input path.

5. **`reshape`, rank one — complete 2026-08-19.** A flat source and a
   one-axis shape now dispatch directly to the typed cyclic-copy driver;
   higher ranks retain the nested spine builder and a zero-length result
   retains its historical empty representation. The parity matrix covers
   every leaf representation, cyclic extension, staging-block and kernel-
   quantum boundaries, while the focused shape suite continues to pin the
   higher-rank, zero-axis, row-major, and validation rulings. The initialized-
   Session OOM sweep reaches the new typed writer.

6. **Char-element pervasion — complete 2026-08-19.** Character subtraction
   and comparison write fixed i64 results in one pass. Character offsets and
   character `min`/`max` first profile faults and maximum produced codepoint,
   then fill the exact char1/2/4 writer through one bounded block. Invalid
   character and symbol combinations reject at logical index zero without a
   boxed traversal. Parity covers ASCII, BMP, astral, both scalar sides,
   char×char and char×int leaves, width crossings in both directions, block and
   kernel-quantum boundaries, and recognized `each`; the initialized-Session
   OOM sweep reaches both fixed and dynamic outputs.

*Structural obligations*

7. **Generic descent re-enters the typed loop — complete 2026-08-19.**
   `PervadeCursor` carries a `NestedTyped` frame whose variants own the same
   numeric, fixed-character, and dynamic-character states and step functions
   as top-level drivers. Ragged spines and dictionary values therefore stop
   structural descent at each flat leaf, keep their bounded cursor, and report
   a fault's inner logical index. Focused coverage pins nested numeric and
   character leaves, dict-contained leaves, and an overflow in a later child.

8. **Known-type materializer passes — complete.** `ShapeDriver` now publishes
   its rank vector directly through `LeafWriter(.leaf_i64)`; rank is bounded
   by nesting depth, so its fixed stack staging is at most 256 integers.
   `GradeDriver` and `GroupDriver` publish their already-typed index vectors
   through `LeafWriter(.leaf_i64)` on flat and generic paths. The empty-list
   materializer in `src/binder.zig` builds a single empty
   list at lowering time and is not user-sized work. `ValueMaterializer`
   stays: it is the profiling pass that genuinely unknown or heterogeneous
   results need, and item 9 removes only its flat-route callers.

9. **The cutover — complete 2026-08-19.** Every specialized leaf route enters
   a typed/bulk/sequential state before the generic drivers; the surviving
   `PervadeCursor` list frame, idiom drivers, and sequence/text copy drivers are
   reachable for generic spines, dictionaries, empty-representation rulings,
   cross-class widening, or the explicitly heterogeneous mixed-number
   `min`/`max` result—not as a silent specialized-leaf fallback. Reference
   search confirmed the remaining materializers are still consumed by reader,
   documentation, binder-empty, dict-hash, structural-output, or genuine
   profiling paths. The source audit forbids boxed primitives in
   `kernel_flat.zig` and rejects a migrated function that combines a typed
   reader with per-cell access or a profiling materializer.

*Proof obligations*

10. **Parity coverage follows each migration.** `src/tests/kernel_typed_test.zig`
    already has the shape — the same values built as a specialized leaf and
    through `list.fromValuesGeneric`, compared as rendered outcomes — so each
    item above adds cases rather than machinery. An item is not done until its
    operations appear in that matrix at lengths 1, 2, 3, one below/at/above the
    staging block size, and around the kernel quantum, with the length-zero case
    covered by the dedicated empty-representation assertion rather than by the
    matrix (the two representations of an empty list render differently by
    design, which is why the matrix starts at one).

11. **Allocation-failure coverage follows each migration.** Every new
    live-Session path needs the smallest snippet that reaches it in
    `src/tests/oom_test.zig`; the sweep replays each snippet once per
    allocation point, so snippets stay two or three elements long. The
    double-retire this discipline caught on 2026-08-19 — a driver install
    failure retiring capabilities that the caller's `errdefer` then retired
    again — is the reason the gate is not optional.

12. **The acceptance matrix is green.** The complete per-push manifest ran on
    2026-08-19: full Debug and ReleaseSafe suites, ReleaseFast snapshots, both
    PTY modes, native positive and negative surfaces, all nine bounded fuzz
    campaigns, one/eight-worker scheduling, differential comparison,
    Linux/x86_64 TSan, formatting, lint, and ReleaseSafe terminal acceptance.
    The release-candidate-only exhaustive initialized-Session OOM sweep and
    complete ReleaseFast suite had already run green for the M14 migration
    before the namespace, reflection, predicate-spelling, and display
    refinements; repository policy does not replay those quadratic/non-analysis
    gates on every push. The earlier 193-program byte-for-byte ReleaseSafe
    comparison against a pre-migration binary covers numeric, idiom,
    reduction, sequence, binder, and dip surfaces.

*Asymmetries that are settled, not TODOs*

These look like defects to a reader who has not read the clauses, and must
not be "fixed" by a later patch:

- **An empty result keeps its operand's representation**, which printing
  shows as brackets: an empty typed leaf renders `[]`, an empty spine `()`.
  This is a per-producer choice that predates the migration; typed paths
  therefore decline length-zero work rather than forking that decision.
  A typed producer that has no operand to inherit from — `rand-ints` with
  count zero — keeps the generic empty it always produced.
- **`min`/`max` on a mixed numeric pair is heterogeneous by definition**:
  they return an operand, so the result holds ints and floats element by
  element. That pair stays on the profiling route permanently.
- **A recognized `each`/`zip-with`/`fold`/`scan` fault carries no list
  index**, because the combinator it stands in for applies its quotation to
  one element at a time. Direct pervasion does carry one. Both routes were
  like this before the migration and the typed path threads a flag to keep
  it so.
- **Float `fold`/`scan` association is strictly sequential** on both
  routes. `sequential_typed` is a classification, not a missing
  optimization.

**Verified current state**:

- Milestone 1's homogeneous width-tagged leaves remain the value
  representation; Step 14 changes execution, not values or the wire contract.
- `kernels.zig` now owns the closed comptime classification, `kernel_flat.zig`
  owns the bounded range/fault/output machinery, and heap-issued readers,
  writers, and unique-adoption capabilities close their lifetime and mutation
  surfaces.
- Numeric, sequence, ordering, grouping/distinct, text, random, and recognized
  idiom paths dispatch once on flat representations. Generic spines and dicts
  keep bounded structural descent and embed the same typed state at leaves.
- Generic materialization remains only where the output is genuinely
  heterogeneous, structural, cross-class, or governed by the historical empty
  representation. Explicit `@Vector`/ISA variants remain deliberately outside
  this step.

**Definition of Done**:

1. **One closed, typed dispatch seam.** `src/kernels.zig` owns one comptime-
   validated registry that classifies every first-party user-sized operation
   and every applicable `value.HeapKind` combination exactly once as:
   monomorphic typed loop, bulk copy/fill, deliberately sequential typed loop,
   or generic spine/dict fallback. Binary entries distinguish leaf×leaf,
   leaf×scalar, and scalar×leaf without materializing a broadcast. Mixed
   `i64`/`f64`, character-width, comparison-mask, boolean, bitwise, and shift
   cases are explicit. Missing and duplicate classifications are compile
   errors; no second leaf-tag enum or source-audit name list is introduced.

2. **Heap-issued lifetime and mutation capabilities.** Typed loops receive
   read-only slices only through nominal capabilities that keep the owning
   list roots alive for the whole cursor lifetime. Typed builders own their
   allocation and expose only bounded range writes plus one consuming finish
   transition. Optional input-buffer reuse consumes a heap-issued unique
   authority tied to that same list owner; callers never correlate a raw
   slice, allocator, release domain, and header themselves. Success and every
   failure path state whether the input/output capability was consumed or
   retained, and retirement remains bounded work outside publication locks.

3. **Unboxed execution from dispatch through publication.** A flat typed path
   dispatches once per operation/chunk, reads the underlying typed slices, and
   writes the final typed output buffer directly. It does not call
   `list.atUnchecked`, allocate an `OwnedValueBuffer` for result cells, invoke
   `ValueMaterializer`, or push a child per element. Known-width producers
   (`range`, comparisons, recognized scans, random integer vectors, fixed-width
   character transforms, and exact-size copy/gather operations) select their
   builder before filling. Unknown or genuinely heterogeneous results keep the
   existing bounded profile/materialize path; the migration does not force a
   type guess.

4. **The whole flat-leaf surface crosses the seam.** Numeric and logical
   unary/binary pervasion lands first, including scalar extension and dedicated
   mixed-number loops. Sequence/search/copy operations (`at`, `where`, `in?`,
   `find`, `raze`, `cat`, `take`, `drop`, `reverse`, `range`, `flip`, and
   `reshape`), ordering/grouping operations where their inputs or outputs are
   typed leaves, fixed-width string traversal, and known-type materializer
   passes then use the same capabilities and range contract. Resolution-
   guarded direct/`each`/`zip-with`/`fold`/`scan` idioms call those same loop
   entries rather than maintaining a second fast implementation. Generic
   spines and dicts continue bounded descent and enter the typed registry when
   they reach a flat leaf. Every operation not profitably monomorphic still has
   one explicit registry classification explaining its generic or sequential
   path.

5. **Bounded work is preserved without per-element scheduler turns.** Every
   loop cursor carries an absolute index and advances one explicit half-open
   range no larger than the caller's remaining `WorkContext` budget and the
   kernel quantum. A completed small range returns inline within that budget;
   an incomplete range yields once at its chunk boundary. Logical-element
   accounting is conservative for copies and gathers, cancellation is checked
   between bounded chunks, and one ready task cannot monopolize a worker. Cold
   and one-worker Sessions still settle retirement on every public turn.

6. **Faults retain exact scalar semantics.** Checked integer arithmetic,
   division/domain checks, finite/NaN rules, and shift-count validation
   accumulate a fault mask over a bounded block. A hit replays only that block
   through the shared scalar semantic function to report the first logical
   failing index and the existing error kind/message/data. When output storage
   aliases a consumed input, the block is validated before any store that
   would destroy evidence needed by the rescan. No partial output is
   published. Exact mixed-number comparison stays exact, and float
   `fold`/`scan` association remains strictly sequential and bit-identical on
   typed and generic paths; autovectorization never licenses reassociation.

7. **Representation and ownership parity are observable invariants.** Typed
   and generic paths produce the same values, specialized leaf kinds, empty
   representation, character width, printed brackets/strings, errors, and
   float bits. Self-aliasing inputs, scalar-on-either-side operations, ragged
   spine leaf encounters, delayed cancellation, allocation failure, and
   unique/non-unique output cases are covered. The shared builder stages every
   borrowed mutation argument before writing so a caller may legitimately pass
   a borrow from the destination back into the operation.

8. **The old flat boxed route is gone, not retained as a silent fallback.**
   Production code has one typed flat path and one generic spine/dict path.
   Static capability surfaces make per-cell boxing unavailable inside a typed
   loop, and comptime registry validation proves closed coverage. Tests do not
   gain representation accessors or inspect implementation source. Any scalar
   reference evaluator used by differential properties is existing production
   semantics reached through a real generic path, not a second public kernel.

9. **Proof and documentation move with the seam.** The implementing gameplan
   inventories every producer and consumer in `kernel_numeric.zig`,
   `kernel_sequence.zig`, `kernel_order.zig`, `kernel_dict_text.zig`,
   `kernel_storage.zig`, `kernel_random.zig`, `idioms.zig`, and
   `combinators.zig`; its test ledger names exactly one introducing patch per
   test. `design/INTERPRETER.md` is updated only when the typed seam is real,
   and then describes the as-built registry, capabilities, chunking, and fault
   protocol rather than an aspiration. This M5 correction remains in the
   history as the explanation for the migration.

**Implementation sequence (one autonomous gameplan; no operator decision
between patches)**:

1. Introduce the heap-issued typed read/builder/unique capabilities, the
   exhaustive registry shape, and compile-time matrix validation while all
   existing behavior still uses the old route.
2. Move numeric/logic pervasion and its checked block/rescan protocol onto the
   typed cursor, then connect guarded numeric combinator idioms to the same
   entries.
3. Move the classified sequence, order, text, random, and known-type
   materializer operations; keep explicitly classified heterogeneous paths on
   the generic cursor.
4. Cut over every producer and consumer, delete the boxed flat route, close the
   capability surface, update documentation, and run the complete proof matrix.

**Acceptance evidence for this executed step**:

- Per push, `zig build test` and `zig build test -Doptimize=ReleaseSafe` run
  the complete suite; ReleaseFast runs the promoted snapshot corpus. PTY,
  native, fuzz, worker-count, differential, Linux/x86_64 TSan, formatting,
  lint, and ReleaseSafe terminal-acceptance gates are independently green.
- For a release candidate, the complete ReleaseFast suite and `zig build
  test-oom` also exit 0. Component allocation-failure probes stay beside their
  builders/cursors; the initialized-Session sweep uses the smallest snippets
  that reach each new live-Session path.
- Production-connected differential properties cover every registry entry at
  sizes `0`, `1`, one below/at/above the kernel quantum, scalar-left,
  scalar-right, leaf×leaf, mixed numeric leaves, ragged leaf encounters, and
  the first fault in the first/middle/final block. They assert values,
  representations, exact error dicts/indexes, and successful float bits.
- A bounded-work property drives the real kernel cursor through its factory
  with budgets smaller than the input and proves that a flat operation of
  length `n` needs at most `ceil(n / budget) + O(1)` advances—not `O(n)`
  advances—while a competing short Unit completes within the existing
  scheduler latency bound.
- A `DebugAllocator{.enable_memory_limit}` property compares warmed baselines
  and proves temporary requested bytes are bounded by output plus one kernel
  chunk, independently of element count and publication history; a forced
  budget failure leaves inputs valid and leaks nothing.
- A checked-in benchmark report characterizes the migrated post-state for
  flat and ragged cases at `1`, `32`, `1,024`, `65,535`, `65,536`, `65,537`,
  and `1,048,576` elements in ReleaseSafe and ReleaseFast. Its durable
  content is the machine-independent counters — allocations, bytes, and
  cursor advances are deterministic facts about the code: the actuals the
  pass/fail bounds deliberately discard. Wall-clock throughput and
  cancellation latency are dated context under a mandatory
  machine/toolchain header; later work re-measures them and never trusts
  them from the file. The report is not before/after migration proof — the
  structural/type and bounded-turn assertions above are the blocking proof,
  and the pre-migration shape is the qualitative record in this section's
  verified current state (one scalar node and roughly two frame transitions
  per element, three boxed passes). Evidence, never a timing threshold
  gate.

**Why this is a safe pause point**: The step is an observationally invisible
execution-representation migration behind the already frozen value and kernel
semantics. At its boundary every operation is statically classified, the old
flat boxed route is removed, generic data still has one correct bounded path,
and all scheduler, ownership, OOM, differential, and real-binary gates are
green. There is no half-migrated dispatch choice left for a later step to
interpret.

The implementation is at that structural boundary and item 12's acceptance
matrix is green and recorded. The generic drivers still present in source are
the explicit spine/dict,
cross-class, empty, and heterogeneous paths described above, not a hidden flat
fallback.

**Unlocks**: Post-v1 item 8's explicit SIMD/packed-mask/fusion and
kernel-internal multicore work can target one stable typed range ABI. Post-v1
item 9 can measure and optimize remaining non-kernel `WorkDriver` overhead
without confusing per-element kernel transitions with scheduler cost. Neither
is part of this step, and neither may introduce a second semantic loop.

**Operator Actions Before Next Milestone**: None. Later performance work begins
only through a new gameplan against the checked-in benchmark report; no runtime
flag, soak window, or conditional cutover is part of this migration.

---

### Post-terminal Step 15: anonymous-module-values

**Status**: executed 2026-08-20 — gameplan
`gameplans/anonymous-module-values.json` (local, ignored per convention).
This step separates module construction from registry publication without
moving mutable state or lifecycle authority into a freely duplicable value.
`@module` becomes `(body -- module)`, `register` is
`(module 'module-name --)`, and `@defm` preserves the concise combined form
`(body 'module-name --)`. `register` is an upsert: the first registration of a
canonical name creates its slot; a later registration atomically replaces that
slot's code image while preserving its durable live state.

The representation has two nominal layers. An immutable anonymous
`ModuleImage` owns the frozen module environment, module-local definition
metadata, and the construction body's final stack as an initial-state
template. It owns no canonical name, registry slot, arbiter, generation
currency, or `SlotLease`. A registration retains one image and owns the name,
live stack, serialization arbiter, generation lifecycle, aliases, and removal.
The same image may therefore be registered under multiple names while every
registration keeps independent state and lifetime. This preserves the
value-heap DAG and no-cycle-collector invariant: an image never points back to
a slot that may retain it.

Definition metadata becomes module-local rather than name-bearing. Qualified
registry resolution acquires the registered generation and supplies an opaque
`RegistrationHome` to the activation; same-home resolution, private lookup,
effect traces, reflection, and `within` carry that capability for the complete
call. Consequently an image registered as both `left` and `right` executes
against the registration through which it was reached, never a construction-
time or last-registered name.

**Definition of Done**:

1. **An explicit opaque module value exists.** `Value` and `HeapKind` gain one
   module case without changing the 16-byte `Value` layout or native ABI-v1.
   The value reports type `'module`, renders as `<module>`, and `match?`
   compares image identity. Source reading, JSON emission, and native
   scalar/view conversion reject the capability without exposing an address,
   environment, slot, or state.

2. **Construction is anonymous and side-effect free with respect to the
   registry.** `@module` validates only its body contract, evaluates the body
   in an isolated module-root environment, captures its residual stack as the
   image's initial-state template, freezes the image, and pushes it. Body
   failure publishes neither a value nor a registry mutation.

3. **Registration is one atomic upsert protocol.** `register` validates the
   canonical name and consumes a module-value reference into the existing
   bounded registry publication path. A missing name creates a slot from the
   image template. An existing name installs the new image, preserves the
   slot's live state, and discards that image's template for that slot. Alias
   collision, allocation failure, cancellation, or a conflicting state turn
   leaves the prior directory entry, generation, and state unchanged.

4. **`@defm` is exactly the composition.** For ordinary and `with`-seeded
   bodies, successful and failing construction, invalid names, allocation
   failure, and cancellation, `(body 'name @defm)` has the same stack,
   registry, error, and ownership outcome as `(body @module 'name register)`
   in the equivalent isolated context. It is a trusted primitive driver
   composition, not a second publication protocol.

5. **Images are reusable; registrations remain independent.** Retaining one
   image and registering it under two names shares immutable definitions only.
   Each registration has its own durable state, generation currency, aliases,
   and removal lifetime. Reloading or removing one cannot change or retire the
   other. Old-generation calls remain valid through their production leases
   until bounded retirement drains.

6. **Invocation authority comes only from registration.** `ModuleImage`,
   binding origin, and module-root scope contain no canonical module name or
   slot authority. Only a registry lease can mint `RegistrationHome`, and an
   activation retains it across internal resolution, reflection, contracts,
   and `within`. No public or registered-native surface exposes the image,
   home, environment, slot, registry, or reclamation root behind an opaque
   capability.

7. **Loading and observation remain registration-driven.** Fully-qualified
   dispatch, `use`, `doc`, completion, builtin modules, native modules, and
   ECL_PATH auto-loading continue through the single registry path. Loading a
   source succeeds only if it registers the requested canonical name; a file
   that merely constructs an anonymous image produces the existing total
   loader error. Prior explicit `use` or load state is never required for a
   fully qualified observation or invocation.

8. **The language and documentation cut over together.** Every checked-in ECL
   source that intends combined construction/registration uses `@defm`;
   deliberate `@module` uses construct values. Formatter navigation recognizes
   `@defm` definition blocks and treats `@module` as an ordinary expression.
   Primitive docs, README, snapshots, `SPEC.md`'s module section and complete
   module/word-sorted listing, and `INTERPRETER.md` describe the as-built split.

9. **Ownership and concurrency are proven through production paths.** No
   test-only representation accessor is added. Component allocation-failure
   probes cover image and registration-generation construction; the initialized
   Session OOM sweep uses the smallest snippets reaching `@module`, `register`,
   `@defm`, image reuse, and reload. A delayed-call counting-allocator property
   repeatedly registers, reloads, and removes shared images and proves settled
   memory is bounded by peak simultaneously live images/registrations rather
   than history. Debug/ReleaseSafe, REPL, source-audit, snapshots, one/eight-
   worker, and Linux/x86_64 TSan gates are blocking; the last is mandatory
   because module loading/publication timing and generation lifetimes change.
   Repository RC-only gates remain RC-only.

**Implementation sequence**: five strictly sequential patches. First add the
skipped public proof ledger. Second add the dormant module value and bounded
heap adapter, closing every exhaustive consumer. Third split anonymous images
from registered generations while retaining today's public behavior through a
combined internal adapter. Fourth atomically cut over `@module`, add `register`
and `@defm`, migrate source inputs, and implement the runtime/OOM/concurrency
proofs. Fifth update formatter navigation, snapshots, SPEC, INTERPRETER, README,
and the architecture audit. No flag, soak period, operator action, or decision
between patches is permitted.

**Why this is a safe pause point**: construction, value identity, publication,
live state, and execution authority each have one owner. There is no anonymous
value with a registry back-reference, no registration whose state lives in a
copyable value, no binding with a baked-in canonical name, and no second reload
protocol. Checked-in sources and the runtime agree on the new word effects.

**Unlocks**: programs and future transports can construct, retain, choose a
name for, and register module images as ordinary values. A later frozen-module-
environment representation can optimize the immutable image without touching
registration state, and Deferred Item 17 may cache warm module call sites
without putting a canonical name back into the image. This step does not add
package identity, persistence, module serialization, native ABI exposure, or a
loader return-value convention.

**Operator Actions Before Next Milestone**: None.

---

### Post-terminal Step 16: static-effect-schemes

**Status**: design paused 2026-08-20 after settling the language shape,
verification boundary, and no-runtime-permission rule. No gameplan exists yet;
the questions below must be closed before implementation planning. This step
promotes deferred item 1's d.9 bundle into scheduled work. Execution views,
threaded/opcode arrays, contract-elision guards, and module call-site caches do
not move into this step; they remain later, separately measured optimization
work.

Step 16 turns source annotations into optional static stack and observable-
effect schemes. It verifies every claim an immutable module image makes when
that image is sealed, after the construction body has completed and the full
local environment is known. A module may still contain dynamic code: success
means every static claim is sound, not that every binding has a proof. The
checker never becomes a runtime permission system and adds no check to the
Machine, Unit, frame, primitive dispatch, task dispatch, or ordinary word-call
hot path.

**Settled language contract**:

1. **One annotation quotation has three positional sections.** The grammar is
   `stack-effect : documentation : observable-effects`, with trailing sections
   optional. Existing `(x -- y)`, `(: "doc")`, and
   `(x -- y : "doc")` forms retain their meanings. New examples are
   `(: : io)`, `(x -- y : : io)`, `(: "doc" : io)`, and
   `(x -- y : "doc" : io state)`. More than two top-level colons is malformed;
   markers nested inside quotation parameters do not delimit the outer
   annotation.

2. **Empty sections are admitted where their meaning is unambiguous.**
   `(x -- y :)` is accepted and means the same as `(x -- y)`; `(:)` is a no-op
   annotation. Canonical reflection drops those meaningless empty-document
   forms. `(: :)` is retained because a present empty observable-effect
   section explicitly claims purity. A nonempty documentation section is
   still exactly one string. Nested quotation schemes admit observable effects
   but not documentation.

3. **Stack diagrams have shape and relational modes.** Plain slots only state
   shape: `(x -- x)` means one value before and one after with no identity
   relationship. Apostrophe-prefixed slots state symbolic provenance:
   `('x -- 'x)` returns the same input provenance, `('x -- 'y)` produces a new
   provenance, `('x 'y -- 'y 'x)` swaps, and `('x -- 'x 'x)` duplicates.
   Relational input names are unique; an output name first appearing there is
   fresh, and a repeated output name means the same produced value. This is
   symbolic provenance, not a promise of `match?` inequality. Plain and
   apostrophe-prefixed slots may not mix within one diagram, so `('x -- x)` and
   `(x -- 'x)` are malformed. Nested quotation diagrams choose their own mode.

4. **Named stack rows relate otherwise implicit lower stack prefixes.**
   `..a` denotes zero or more slots and may occur only at the left edge of a
   stack side. Ordinary first-order effects already preserve an unnamed lower
   prefix, so `(x y -- y)` and `(..a x y -- ..a y)` are equivalent. The named
   form matters when the same row crosses a quotation boundary, as in
   `(..a q:(..a -- ..b) -- ..b)` and
   `(..a 'x q:(..a -- ..b) -- ..b 'x)`. Row names scope over the complete
   annotation, including nested schemes, but stack rows and observable-effect
   rows occupy separate namespaces. A row escaping through an output must be
   determined by an input position; `(x -- ..a x)` is malformed, while
   `(..a --)` is valid.

5. **The existing `...` row remains deliberately dynamic.** It is valid only
   as the complete output side and means fixed inputs with an unknown output
   stack. It supplies no static stack evidence, but an observable-effect
   section on the same declaration can still be checked independently.
   `call-as` accepts exact shape effects only and therefore rejects `...`.

6. **Quotation parameters are written inline.** `q:(x -- y)` describes a
   shape-mode quotation input and `'q:('x -- 'y)` a relational one; a nested
   observable-effect scheme is written `q:(x -- y : : ..e)`. Quotation
   parameters are input-only in this step. Literal quotation syntax and
   quotation values received through such parameters can participate in
   checking. Quotations returned by words, stored and retrieved, or built via
   general `cons`/`compose` metaprogramming remain dynamic; output-quotation
   schemes and a general quotation type system stay deferred.

7. **Observable effects form a closed, set-like static vocabulary.** The
   initial concrete names are `io` (observable host I/O), `state` (hidden
   module/registry/environment state), `entropy` (nondeterministic entropy),
   and `task` (exposed task creation, waiting, cancellation, or scheduling
   dependence). Order is irrelevant, duplicates and unknown names are
   malformed, and reflection uses one canonical order. No second colon means
   observable effects are unspecified; a present set is a declared upper
   bound; a present empty set proves purity. Allocation and GC are invisible,
   explicit RNG state is pure, successful-path failure typing needs no `fail`
   effect, and an implementation's internal use of workers does not by itself
   add `task`. `@attempt` and `@each` propagate their supplied quotation's
   effects without adding `task`; `@spawn` adds `task`, and `within` adds
   `state`. Consequently an explicitly pure quotation gives `@each` the same
   observable-effect result as `each` despite their different execution
   strategies.

8. **Named observable-effect rows propagate higher-order effects.** At most
   one `..name` appears in an effect section. A row must be introduced by an
   input quotation before it can escape through the enclosing word's effect.
   For example,
   `(sequence q:(element -- result : : ..e) -- results : : ..e)` propagates
   the quotation's effects, while an enclosing word may add concrete effects
   with `: : ..e state`. Repeated use of one effect row unifies by set union,
   not exact equality.

9. **`call-as` is the explicit local bridge for dynamic stack shape.** Its
   form is `quotation (x -- y) call-as`. It runs an otherwise dynamic
   quotation, records the stack window, and raises `'contract` if the exact
   successful input/output counts disagree. It rejects documentation,
   observable-effect sections, relational contracts, and `...`; it cannot
   manufacture observable-effect evidence. Its runtime cost is local and
   explicitly requested. Ordinary dynamic `call` remains legal but exits the
   stack-verified subset.

10. **Inference is strongest-common-successful-path inference.** A static
    branch must join to one compatible stack shape; effects union. Provenance
    survives only when every successful branch returns the same provenance,
    otherwise that slot degrades to an unconstrained shape slot. A path that
    necessarily raises contributes no output to the join. Loops require a
    stable stack invariant for another iteration; relational facts survive
    only when a complete iteration preserves them. An application whose shape
    cannot stabilize stays legal dynamically.

11. **Inference and declaration are distinct.** Every statically analyzable
    source word in an immutable image is inferred, and those inferred facts may
    justify other definitions in that image. An explicit annotation is checked
    as a public contract. Undeclared inferred facts are neither reflected nor
    exported as a stable cross-module interface. Mutable session/top-level
    definitions have no sealing boundary and remain dynamic. Literal-count
    operations such as `pack` may be inferred when their controlling value is
    statically known; a data-dependent count is unknown rather than rejected
    outside a verified application. Stack and observable-effect evidence are
    independent dimensions: `(x -- y)` checks only stack behavior,
    `(: : io)` checks only observable effects, and `(x -- y : :)` checks both.

12. **Forward references are checked over the completed image.** `def` and
    `defp` validate and retain annotation structure while building. After the
    body finishes, the environment freezes, the checker builds the final call
    graph, infers acyclic definitions, and analyzes strongly connected
    components. Recursive inference is not attempted: every member of a
    recursive SCC must declare each dimension that a checked caller relies on;
    the checker assumes those declarations while verifying the bodies. A
    wholly unannotated recursive SCC remains legal and dynamic. Termination is
    never claimed.

13. **Sealing is a bounded typestate transition.** The ownership sequence is
    `BuildingImage -> FrozenCandidate -> VerifiedImage`. A checker cursor owns
    the frozen candidate and advances through the module-construction driver
    in bounded `WorkContext` chunks. Only success creates the capability that
    can become a module value; verification failure, cancellation, or
    allocation failure publishes nothing and retires the candidate through the
    existing bounded machinery. `register` publishes an already verified
    image and performs no second check.

14. **Resolution remains the one ordinary module-resolution mechanism.** The
    checker resolves local, used, and fully qualified words with the same
    namespace and ECL_PATH rules as execution, including cold qualified
    auto-load; it does not grow a signature-only loader. Local proof facts are
    image-owned. Any proof using another registration records that external
    registration's generation/signature and is conditional on those
    dependencies remaining current. Reload stays unrestricted. Step 16 stores
    this evidence but neither consults it on an ordinary call nor elides the
    existing dynamic stack contract; a later execution-view optimization must
    guard currency and fall back before consuming it.

15. **Static semantics are nominal metadata, never spelling recognition.** A
    binding has one exhaustive analysis form: analyzable source body, opaque
    declared scheme for a builtin/native binding, or one of a very small closed
    set of literal-dependent intrinsics. The checker never asks whether an
    ordinary word has a particular spelling. Primitive analysis metadata is
    centrally complete at comptime, and all switches over the analysis form
    are exhaustive. Proofs and normalized schemes are image-owned side data,
    not value payloads, `BindingLease` hot-path fields, or runtime permission
    masks.

16. **The embedded prelude is a build invariant, not a Session failure mode.**
    A dedicated build tool over the shared production interpreter library
    evaluates the exact embedded prelude through the production parser,
    primitive set, definition machinery, and bootstrap environment, then
    drives the same checker over the final graph. Success emits a typed
    certificate tied by digest to the exact embedded source; the normal
    executable build depends on that artifact and embeds it. Session bootstrap
    evaluates the prelude normally and attaches those prebuilt proof facts; it
    performs no static analysis and cannot fail because an internal static
    claim is wrong. The verifier is not an invocation of the finished binary,
    avoiding a certificate/build cycle. Every embedded stdlib source is also
    verified by the normal build and still passes through ordinary module
    sealing when loaded; only the prelude needs this special certificate
    because it has no module-sealing boundary.

17. **Native declarations remain an explicit trust boundary.** The native
    SDK keeps exact input/output arity and gains a validated observable-effect
    declaration. It does not admit `...` or higher-order quotation schemes
    until the ABI can actually evaluate quotations. A relational native
    declaration is a trusted native contract rather than a body-derived proof.
    Registered-native invocation gains no new callback check or permission
    mask.

**Why this is a safe pause point**: design work is paused before code or a
gameplan exists. The settled section fixes the language's surface and the
ownership, phase, build, and hot-path boundaries; the remaining questions are
called out explicitly below rather than being guessed during implementation.

**Unlocks**: once the open questions close and the step executes, modules can
reject false static claims before becoming values, higher-order code can
propagate stack and observable-effect schemes, and later execution views may
use conditional proofs behind generation guards. None of those later
optimizations is licensed merely by module residence or annotation presence.

**Operator Actions Before Next Milestone**: Resume the Step 16 design
conversation and close every Step 16 item in Open Questions before invoking
`write-gameplan`.

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
- Milestone 10 (one-binder-merge) -> [6, 9]   # ruled 2026-08-17; precedes state and stdlib
- Milestone 11 (stateful-modules) -> [7, 10]
- Milestone 12 (stdlib-result-str-csv-json-table-http) -> [6, 9, 10, 11]
- Milestone 13 (v1-acceptance) -> [7, 8, 9, 10, 11, 12]
- Post-terminal Step 14 (monomorphic-flat-leaf-kernel-migration) -> [13]
- Post-terminal Step 15 (anonymous-module-values) -> [14]
- Post-terminal Step 16 (static-effect-schemes) -> [15]

## Open Questions

All pre-Step-16 questions remain closed. Step 16 is deliberately paused with
these unresolved design questions:

1. **Static prelude combinators versus the dynamic quotation boundary.** The
   current `dip` body is `(swap literal compose call)`, which loses static
   quotation identity under the settled rule that `compose`-produced
   quotations are dynamic; `keep`, `bi`, and related definitions inherit the
   loss. Decide whether to rewrite the statically useful combinators into
   direct binder forms such as `(|x q| q call x)`, or to admit a narrowly
   typed quotation-construction algebra. The latter must not accidentally
   introduce the general output-quotation type system already deferred.

2. **The closed scheme and intrinsic catalog.** Enumerate the exact static
   schemes for core primitives and prelude combinators, and the minimal
   intrinsic variants required for binders, literal-dependent `pack`,
   `call-as`, and any control operator not expressible by ordinary scheme
   unification. This list must be centrally comptime-complete and must not
   recognize public bindings by name.

3. **Stale external proof behavior.** External generations make certificates
   conditional, but the checker behavior when it encounters a stale proof is
   not settled: conservatively treat the application as dynamic, recursively
   reanalyze the immutable dependency against current registrations, or admit
   a compatible public-signature fast path. The answer must also specify
   cross-module proof cycles and reload order without restricting ordinary hot
   reload or adding a call-time check in Step 16.

4. **Auto-load transaction semantics during checking.** Ordinary qualified
   resolution may load an ECL_PATH dependency while sealing a candidate.
   Decide whether a dependency loaded for a candidate that later fails remains
   registered like any other cold resolution, or whether checking needs an
   owner-scoped publication transaction. A second signature-only loader is
   already rejected.

5. **Concrete effect classification.** Classify every primitive, prelude word,
   embedded stdlib word, and native capability under `io`, `state`, `entropy`,
   and `task`. In particular settle loader/registry/reflection operations,
   stable `args`/environment snapshots, deadlines and cancellation, `within`,
   `@spawn`, `@each`, and host-backed words whose implementation and observable
   semantics differ.

6. **Diagnostics and reflection details.** Fix the error kinds and source-path
   presentation for malformed schemes, declaration mismatches, unknown static
   dependencies, recursive-contract failures, and `call-as` mismatches. Define
   the canonical `see` rendering for every new grammar form and whether a
   separate observation surface exposes current/conditional proof status;
   undeclared inferred schemes themselves remain non-public.

7. **Certificate and proof representation.** Choose the concrete generated
   artifact, source/interface digest, normalized scheme ownership, dependency
   fingerprint, and bounded retirement representation. Decide whether the
   existing unused `BindingSpec.compiled` slot is removed, repurposed, or left
   for the later execution view; the result may not enlarge hot leases merely
   to store cold proof state.

8. **Milestone proof and size.** Turn the settled semantics into an externally
   observable acceptance ledger, including negative grammar cases, forward and
   recursive references, conditional external proofs, build-time prelude and
   stdlib rejection, OOM/cancellation, worker scheduling, and the absence of
   runtime permission checks. Then decide whether the parser/scheme model,
   bounded checker and certificates, and vocabulary migration fit one atomic
   gameplan or require additional safe post-terminal steps.

## Post-v1 follow-ups (deferred features)

Except for item 1's forwarding placeholder to scheduled Step 16, these are
potential follow-ups rather than milestones: none blocks the `0.1.0` tag, none
has an owner, and picking one up starts a design conversation and its own
workstream or gameplan. Each was deferred with constraints pre-written at
deferral time. The 2026-08-17 documentation consolidation removed them
from SPEC.md and INTERPRETER.md (those describe present state only), so
this section is the sole active record of those constraints; when a
follow-up lands, its present-state description moves into SPEC.md and
INTERPRETER.md and its entry here is retired.

1. **Static effect checker bundle — promoted.** Ledger d.9's deferred layer is
   now scheduled as Post-terminal Step 16 above. Its settled constraints and
   remaining questions live there; this numbered placeholder preserves
   references from later deferred items without maintaining a second design.

2. **Exactness** (ledger d.4). Bignums, rationals, or decimals — deferred,
   not rejected; a positioning decision to revisit. Constraints: the
   numeric tower stays out of core; bignum promotion inside flat leaves is
   rejected outright because scalar and array arithmetic would diverge, so
   any exactness design must keep them identical and cannot silently
   promote. The interpreted-forever positioning neither demands nor
   forecloses it.

3. **pdict** (ledger d.1's reservation). An Erlang-style per-substack
   process dictionary, sketched as `put`/`get` (note the existing list/dict
   word `put`; naming is among the open questions). Constraints reserved
   with it: immutable values only; scoped to the substack (the unit
   boundary); follows env rules — a failed unit does not roll it back;
   stays out of the stdlib. All remaining questions, including child
   inheritance (empty vs copy-on-spawn), are decided if and when it is
   added.

4. **Channels** (ledger d.20's reservation). Producer/consumer streaming.
   If added: immutable values only, and channel ends are scoped to units —
   the structured-lifetime rule extends to them. Promise-style combinator
   algebras on pending tasks remain refused regardless.

5. **Unicode tables layer** (ledger d.15's deferral). Grapheme
   segmentation, normalization, non-ASCII case mapping, and locale
   collation — a stdlib layer gated on Unicode tables, beyond M12's ASCII
   `str` scope. Until it exists, codepoint semantics stay documented
   honestly (composed vs decomposed "café" is 4 vs 5 chars).

6. **`'origin` error field** (ledger d.19's anticipated extension). Errors
   are sendable by construction — immutable plain data — so when errors
   cross process boundaries, `'origin` is an added field, not a redesign.

7. **`fsum`** (ledger d.23). The documented escape valve if float-sum
   throughput ever matters. The standing rule it relaxes stays otherwise
   absolute: float folds are strictly sequential on every path, only exact
   reductions (integer, min/max, boolean) may be reassociated, and fused ≡
   generic remains bit-identical.

8. **Kernel evolution beyond the typed Step 14 baseline.** All work here is
   profiling-gated and depends on the completed monomorphic flat-leaf
   migration. Step 14 supplies the only typed range ABI; these upgrades add
   algorithms or machine variants behind it and may not recreate dispatch,
   fault, ownership, or generic-fallback semantics:
   - Counted float generation closes the deliberate vocabulary asymmetry left
     by the first randomness pass. Add the pure
     `rand-floats ( state count -- state results )` kernel and the stateful
     `rng.floats ( count -- results )` wrapper beside `rand-ints`/`rng.ints`.
     The pure kernel advances the visible counter exactly as repeated
     `rand-float` calls would and fills one exact-width `leaf_f64` result
     through the Step 14 typed writer; the module wrapper performs one
     `within` transaction rather than one transaction per element. Acceptance
     compares values, final state (including the next draw), zero and invalid
     counts, cancellation, and allocation failure against the scalar reference
     path. The pure kernel remains bit-identical under one and eight workers;
     concurrent calls through the shared `rng` module remain arbiter-serialized
     but honestly worker-count-nondeterministic, as the existing module contract
     requires. The same pass adds the ECL-defined
     `rng.choose ( values -- value )`, compositionally equivalent to
     `dup len rng.int at`: it uniformly selects one element, accepts the same
     list representations as `at`, and needs no separate pure kernel or
     placeholder allocation. A singleton returns its element; an empty input
     is `'domain` before generator state advances. Acceptance resets a fixed
     seed and compares `choose` with the explicit composition, including the
     following draw, so both the selected value and state transition are pinned.
   - Fuse the exact identity-guarded phrase `range (quotation) each` into one
     bounded tabulation driver. The driver synthesizes each i64 index instead
     of materializing the range leaf, preserves `each`'s isolated `( a -- b )`
     contract, left-to-right application order, error attribution,
     cancellation bound, and known result length, and uses the existing
     generic result materializer when the quotation's output kind is not known.
     Shadowed bindings and unrecognized/dynamic phrases retain the ordinary
     `range` then `each` path. No public `tabulate` word is added merely as a
     performance escape hatch; a named combinator remains a later vocabulary
     decision only if it proves useful independently of fusion. Differential
     coverage runs automatic and generic-only modes through values, errors,
     effects, shadowing, quantum boundaries, and OOM, while allocator counters
     prove that the recognized path allocates no range leaf.
   - Grounding case study: codereport's
     [`WHY_BQN_WINS.md`](https://github.com/codereport/max-odd-binary/blob/main/WHY_BQN_WINS.md)
     dissects a small CBQN workload into six compounding advantages. Five
     map to ECL's value model: activate the reserved packed-mask leaf;
     specialize mask and `Char1` algorithms (popcount/fill and counting or
     radix sort); generate explicit SIMD variants; fuse recognized pipelines
     such as compare-to-mask-to-count or compare-to-mask-to-replicate; and
     select algorithms by the O(1) leaf kind and length. These are independent
     optimizations rather than a mandate to recognize that particular program.
     Its sixth advantage, a custom array allocator, is orthogonal to the value
     model and remains measurement-gated: prefer the host allocator unless
     allocation profiles justify owner-scoped header, driver, or leaf-buffer
     pools that preserve allocator-failure injection and bounded retirement.
   - Vectorization tier 2: explicit `@Vector` kernels and target-feature
     multiversioning (compress, radix histograms, packed compares).
     Tier 3: per-ISA variants selected at startup. One authoring
     invariant: every ISA variant of a float kernel implements the
     identical association tree.
   - Kernel-internal multicore, deferred entirely: grain around 10⁵
     elements per thread, memory bandwidth as the ceiling. Step 14's kernels
     take explicit index ranges, so a future splitter forks block ranges
     without touching kernel bodies. One worker pool under everything:
     kernel splits are scoped fork-join subtasks on the same pool as
     units, with the caller participating; kernels never own threads.
   - The reserved narrow-mask leaf tag (packed bools) —
     representation-only, never semantics.

9. **Remaining WorkDriver overhead program after Step 14.** Step 14 owns
   once-per-operation flat-leaf dispatch, typed chunk loops, and elimination of
   per-element kernel transitions. This item measures what remains in the
   general cursor/`WorkDriver` substrate—fixed driver allocation, non-kernel
   state transitions, ready-queue interaction, and materializers whose result
   type is genuinely unknown. It must not be used to postpone or condition the
   Step 14 migration. The substrate
   pays per-operation allocation, per-transition state loads, and
   per-slice indirection; measure before optimizing. Benchmarks: input
   sizes 1, 32, 1,024, 65,535, 65,536, 65,537, and 1,048,576 (fixed cost,
   quantum boundaries, steady state visible); one and eight workers,
   uncontended and with a long task competing against short ones; record
   wall/CPU time and ns per logical transition, allocations and bytes,
   resumes and ready-queue handoffs, short-task queue latency
   (p50/p95/p99), cancellation-observation latency and maximum
   uninterrupted work, and peak temporary memory, in ReleaseSafe and the
   intended release mode, through the public runtime surface. Optimize
   only measured contributors, preferring in order:
   1. eliminating fixed driver allocation — an inline continuation area in
      `Unit` (nominal occupied/empty state, comptime alignment and size
      validation), per-unit size-class pools, or typed slabs; pools keep
      precise ownership and allocator-failure behavior and never turn
      teardown into unbounded traversal; deferred item 18 is the dispatch-side
      instance of this same preference and is measured separately. Measured
      2026-08-21: the largest per-element cost this preference was written for
      was not a driver at all. Applying a quotation allocated a 144-byte
      `env.Scope` per element — one per element of every generic combinator,
      including a body that binds nothing and does nothing — and retired it
      through bounded retirement, so each element also cost release-domain
      traffic. `beginApplication` now parks an unmaterialized, unshared scope
      for the next application over the same parent instead of retiring it,
      taking a 100,000-element unrecognized `each` from 100,033 allocations to
      34. Two larger per-element costs were exposed by that measurement, and
      neither was a driver either. The first is gone: a `|x|` body cost about
      ten allocations per element in the reader-time lowering of head binders,
      which now compiles to frame slots and allocates nothing. What remains is
      a body that binds with `set`, at about twenty-one, and scalar arithmetic
      at two per operation — deferred items 20 and 19. Take the measurement
      before assuming this preference names the right structure;
   2. batching non-kernel transitions inside a bounded slice—generic-spine or
      dict descent, heterogeneous materializer passes, reader/formatter/editor
      cursors—with conservative accounting: a bounded chunk may count as one
      transition, an arbitrarily large traversal may not, and a parent driver
      never assumes a completed child consumed one transition; and
   3. scheduler or quantum policy last — never tune the quantum to hide
      avoidable allocation or cursor overhead, and any adaptive policy
      preserves a hard maximum non-yield interval.
   Bounded-first-slice promotion (run one bounded slice locally, install
   the driver only when incomplete) is attempted only if driver allocation
   remains material after inline storage or pooling, and only with an
   immediate scheduler return on an incomplete first slice. Genuinely
   constant-bounded scalar cases may execute directly — domain dispatch,
   never a second implementation of a user-sized algorithm. Every
   candidate preserves INTERPRETER.md's bounded-work invariants and passes
   the scheduler interleaving properties, shell/process properties with
   deadlines, behavioral and differential suites, allocator failure
   sweeps, and the one/eight-worker matrix, reporting both throughput and
   worst-case progress latency: an optimization that improves aggregate
   throughput by monopolizing a worker is a scheduler regression.

10. **Profiling-gated implementation upgrades**, declined for v1 and legal
    later under standing rules: a custom bucket allocator (capacity
    derived from power-of-two bucket class; a concurrent allocator is the
    riskiest subsystem in the plan — ride the system allocator until
    profiling demands otherwise); Tokio-style local run queues with
    steal-half; quickening/inline caches under the iron law — hold the
    binding cell, re-read its interior every execution, never cache a
    completed `Resolution`. Deferred Item 17 gives the module-call
    specialization of that rule: its cache owns an opaque generation
    capability, guards currency, and reacquires the binding lease used by each
    execution. The execution view is item 1's compiled form. The dispatch-loop
    freeze stands: none of these touches the inner loop's design.

11. **Native extension capabilities.** Already recorded in M9's deferral
    ruling, M13's Unlocks, and Decisions Made; listed here only for
    completeness: SDK exposure of M11's internal module-stack draft/outward-transfer
    authority, `Offload` (the expected first scheduling capability — a
    blocking-pool split reusing the await machinery unchanged), resource
    values, external wake, package assets, and quotation evaluation. Each
    requires an explicit wire-contract revision; none is a new callback
    class.

12. **Package manager.** Owns dependency solving and target selection, and
    publishes its result by ordering package roots in `ECL_PATH`; the
    runtime does neither job. `.eclmod` stays portable naming, never a
    portable binary.

13. **Reserved doors.** `;` is a reserved token (parse error; currently
    means nothing). Word aliases for `fold` and friends can come later —
    words-not-glyphs remains the identity, and the glyph budget stays
    spent on literals.

14. **Constant-reference fast path** (M10's one unbuilt piece, deferred
    2026-08-17 during execution). Milestone 10 traded a value binding's
    single push for a word application: referencing a name bound by `set`
    resolves, pushes a frame, evaluates `((v) first)` — pushing the
    one-element list — applies `first`, and returns. The merge's
    equivalence law is unaffected; only the cost is. M10's planned
    mitigation, a `.direct` idiom entry matching the two-form capture
    body, was specified but never built, because it is unreachable:
    direct-context recognition fires only when `resolved.origin == .core`
    (`src/machine.zig`), and core carries no `set`-published names, so the
    entry would have matched nothing. The combinator-context capture
    entries (`[capture, op]`, `[capture, swap, op]` at `each` entry) are
    reachable, shipped, and differentially proven; they are not affected
    by this deferral. Profiling-gated, and constrained if picked up:
    - Whatever fires must be observationally invisible, proven in the
      existing differential harness like every other recognition entry —
      the deleted word|value tag must not return as a dispatch heuristic.
    - Widening direct recognition past core origin is the expensive
      option: the `.core` gate is what keeps a shadowing session
      definition out of the recognizer, so removing it means replacing
      that guarantee, not just deleting a condition.
    - Special-casing the capture shape in `executeResolved`, ahead of the
      idiom machinery, is the cheaper option and the one to measure first;
      it needs no registry mechanism, no `source_word` relaxation, and no
      new `Operation` variant.
    - Measured 2026-08-20 with Step 14's `bench-kernels` tool, so the gate
      is discharged: this item is no longer unmeasured. (Earlier text said
      "M13's benchmarks" — a defect: the benchmark harness was ruled out of
      v1, so M13 shipped none; Step 14 owns the tool and the checked-in
      deterministic baseline, corrected 2026-08-19.) Temporary probe cases,
      ReleaseFast, 1,000,000 references driven through the generic `each`
      spine over the tool's `DebugAllocator` backing:

      | probe | allocations per reference | ms |
      |---|---|---|
      | inline literal `(pop 42) each` | 2.00 | 2971 |
      | `def` word with body `(42)` | 3.00 | 6243 |
      | `def` word with body `((42) first)` | 6.00 | 15123 |
      | `set` constant reference `(pop k) each` | 6.00 | 13993 |
      | inline `(42) first`, no user frame | 5.00 | 11282 |

      A constant reference costs four allocations more than the literal it
      stands for. One of those four is the word frame; the other three are
      the application of `first`. Milliseconds are DebugAllocator-inflated
      machine context and are not evidence, per the Step 14 report's own
      rule; the counts are the durable number.
    - The cost stated above replaces this item's original claim, which was
      wrong in both parts. There is no transient one-element list per
      reference: `literal` builds `((v) first)` once at `set` time
      (`src/prelude.ecl`), a reference pushes that stored list by refcount,
      and `firstPrimitive` (`src/kernel_sequence.zig`) is a popList and a
      `pushBorrowed` with no allocation at all. And the count is four, not
      one.
    - Three of the four allocations were not a constant-reference cost and
      were not this item's to fix; they were the per-word and per-core-word
      drivers of item 18, which every program paid on every word it called.
      Item 18 shipped 2026-08-20 and removed them. Allocation is no longer an
      axis here at all: the last one, a 16-byte `DirectWordFallback` per
      core-origin word application, became inline fallback storage on
      2026-08-21. A constant reference now allocates exactly as much as the
      inline literal it stands for, which is nothing.
    - The work did not go away with the allocations. Re-measured 2026-08-20
      after item 18, marginal cost of one added constant reference, 100,000
      iterations through the generic `each` spine:

      | idiom mode | allocations | polls | µs |
      |---|---|---|---|
      | automatic | 1 | 4.0 | 4.07 |
      | generic_only | 3 | 8.0 | 7.49 |

      For scale, in the same harness a whole literal-push iteration costs
      0.42 µs and 2 polls, and adding a plain non-core word call with a
      trivial body costs 0.12 µs marginal. A constant reference is therefore
      roughly ten times a literal push and thirty times a plain word call.
      What it buys with that: one frame, a word resolution for the bound
      name, a second word resolution for `first`, a recognition match, and
      the primitive.
    - Recognition is not the cost, and no future version of this item may be
      justified as avoiding it. Turning recognition off doubles the price of
      a constant reference — 7.49 µs against 4.07 — because matching
      collapses `first`'s five-form body into one primitive. A special case
      in `executeResolved` is worth building only if it skips the whole
      path, frame and both resolutions included; one that merely sidesteps
      the idiom machinery would land between these two numbers, not below
      them.
    - Frequency measured 2026-08-20, which answers what the cost numbers
      could not. The checked-in corpus holds 24 `set`/`setp` sites, every one
      of them under `test/acceptance`; `src/prelude.ecl` and the stdlib
      modules bind with `def` and are unaffected. Every site is a top-level
      pipeline binding — `"…csv" io.slurp csv.parse from-header-rows 'raw
      set`, then a few top-level references to `raw` — and not one reference
      sits inside a quotation body that a combinator drives per element. A
      constant reference therefore executes a few dozen times per script run,
      on the order of a hundred microseconds in total.
    - Deferred on frequency, not on cost, and deliberately not closed. The
      tenfold gap is a real property of the dispatch path, and it bites the
      first time someone writes a constant reference inside an `each` body —
      an ordinary thing to write that no checked-in code happens to do yet.
      Reopen on that evidence: a reference inside a combinator body, or a
      profile of real work showing one in a loop. Do not reopen on the cost
      numbers above, which were already known when this was deferred.

15. **`within` draft/publication copy elision** (deferred 2026-08-18,
    M11 review conversation). Every state application copies the slot's
    durable snapshot into a private draft (one retain per element) and,
    during the transaction, the snapshot and the draft coexist — so a
    value being functionally updated inside `within` has rc >= 2 and the
    d.23 rc==1 in-place reuse never fires on the mutation itself. A hot
    shared structure (a work queue held as one composite value on the
    durable stack) therefore pays a CoW copy per update. Correct and
    inside the slow-but-correct charter; deliberately not optimized in
    M11. Constraints pre-written at deferral:
    - The per-slot arbiter already provides the exclusivity a reuse
      analysis needs: exactly one draft exists per slot at a time, and
      the superseded snapshot retires immediately after `turn.publish`.
      The candidate optimization is to let the draft either borrow the
      snapshot's spine (publish-by-diff) or take ownership eagerly when
      the snapshot's only other reference is the slot itself — never a
      third path visible to user code.
    - Transactionality is non-negotiable: every failure path must still
      observe the pre-application snapshot, so any in-place mutation
      scheme must be undoable or deferred to the publish edge. The
      all-or-nothing publication and exact caller output-window
      reservation are invariants, not costs to shave.
    - Observational invisibility per d.23: no draft-reuse path may
      change values, representations, error dicts, or float identity;
      the production-connected stateful-module suite at 1/8 workers and
      TSan are the proof surface, and the DoD-40 increment-count
      acceptance must remain schedule-independent.
    - Measure before building, with Step 14's `bench-kernels` tool re-run
      on current hardware (not "M13's benchmarks" — none exist; corrected
      2026-08-19): the win is bounded
      by durable-stack element count and update frequency; the guidance
      that shared state should be one composite value (structure in the
      value plane, sharing in the module plane) already makes the draft
      copy O(1) references, so profile whether the remaining CoW copy of
      the composite's spine matters before adding any reuse machinery.

16. **Frozen module environments as a flat immutable table** (deferred
    2026-08-18, M11 review conversation). Module environments are frozen
    at registration (`Scope.freezeModule` at commit) and reload replaces
    the whole generation, never an individual cell — so nothing ever
    republishes a module binding in place. The per-cell publisher and
    snapshot indirection inside a module environment is therefore
    structurally dead weight for every module in every build mode,
    inherited only from sharing the generic `Environment` type with the
    session environment, which genuinely needs cells because top-level
    `def`/`set` redefine names. A frozen-environment specialization —
    one flat immutable name -> `BindingSpec` table built at freeze and
    read directly by resolution — removes that indirection and shrinks
    the dominant per-module term. Constraints pre-written at deferral:
    - No semantic fork. This is a representation swap behind the same
      typestate: `Environment` stays the mutable form the session uses,
      and freezing produces the flat form. Publication, generation
      pinning, `BindingLease`, reflection, and the M11 slot lifecycle
      must be observationally identical, so the differential harness,
      the snapshot transcript, and the module suites are the proof
      surface — no new resolution mode and no second lookup path
      readers must choose between.
    - Leases still have to work. Old-generation frames keep resolving
      through a superseded environment while retirement drains, so the
      flat table must be owned by the generation and retired with it,
      not freed at freeze. Whatever replaces the per-cell publisher must
      preserve the existing final-reader/later-writer handoff for the
      generation as a whole.
    - Freeze is the one build point. It is already a bounded cursor
      (`Scope.EmbeddedTeardownCursor`'s counterpart on the publish side);
      materializing the table must stay bounded work on that same edge
      and must not turn a failed registration into a half-built
      environment — candidate rollback already has to retire it.
    - Measure before building, with Step 14's `bench-kernels` tool
      extended to a module-registration case (not "M13's benchmarks" —
      none exist; corrected 2026-08-19). The lever is
      memory-per-module, so the number worth having first is resident
      bytes per registered module and how it scales with binding count
      and generation depth; M12's stdlib modules are the realistic
      corpus. Nothing about it is on the `0.1.0` path.

17. **Generation-guarded module call-site caches** (deferred 2026-08-20,
    anonymous-module-values review). The anonymous-image/registration split
    adds only one steady-state pointer traversal, but a hot qualified call still
    repeats dotted-name splitting, registry acquisition, and image-environment
    lookup on every execution. An unqualified call through `use` repeats the
    scope/use walk, while a same-image local call still enters the generic
    direct-lookup machinery. For small module words those existing resolution
    costs can dominate the body. Measure them after the representation has
    settled, then allow one call-site cache behind the execution view:

    - A cache entry is not a completed `Resolution`, raw `ModuleHome`, slot
      pointer, environment pointer, or binding payload. It owns an opaque
      registration-generation capability and the binding cell it located;
      every hit verifies that the canonical slot still publishes that
      generation and reacquires the binding lease used by the call. The cache
      cannot mint execution or mutation authority, bypass Unit generation
      pinning, or outlive the Session reclamation domain that issued it.
    - Qualified canonical and alias calls guard the registration generation.
      A `use`-resolved call additionally guards the scope/use-order generation
      that selected the registration. A same-image local reference may omit
      the registry guard only when its execution view owns the immutable image
      generation for its whole lifetime. Unrelated registry writes may cause a
      conservative miss; they may never make a stale hit legal.
    - A warm hit performs no dotted-spelling scan, directory or alias-map walk,
      use-order traversal, qualified-name interning, or fresh registration
      search. It still performs the language-mandated cross-home effect check,
      body retain, frame scheduling, and Unit pin check. Ordinary calls never
      acquire the state arbiter; `within` remains the only state-turn path.
    - Reload, `register`, alias changes, and `unmodule` are observable binding
      events. The very next call after any relevant publication must miss or
      heal before execution; an old frame that already owns its generation may
      finish, but no cache may dispatch a new call through superseded code.
      Invalidation releases cached capabilities through bounded retirement and
      settled memory is bounded by live execution views/call sites, not reload
      history.
    - Measure only ReleaseSafe and the intended release mode, never Debug. The
      corpus compares cold and warm calls for a top-level trivial word,
      `module.word`, an unqualified word reached through `use`, and a local call
      within the same module; then repeats after unrelated publication, reload
      of the target name, alias removal/recreation, and `unmodule`. Record
      ns/call, allocations and bytes, cache hit/miss/heal counts, registry and
      environment cursor steps, generation-pin scans, and resident bytes per
      call site. Include one and eight workers and a Unit that has visited many
      distinct registrations.
    - Acceptance is behavioral and production-connected: cached and uncached
      modes produce identical stacks, errors, traces, reflection, private-name
      behavior, and state; differential reload/alias/removal races exercise the
      real registry publisher and leases; delayed readers prove bounded
      reclamation; allocator-failure coverage reaches cache creation/healing;
      and the Linux/x86_64 TSan gate is blocking because cache hits change when
      generation and directory leases are acquired and released.

18. **Word dispatch allocates a driver per word execution — complete
    2026-08-20.** Measured while discharging item 14's gate. This item
    originally named the core-word fallback allocation; an allocation-size
    histogram showed that is the smallest of the three allocations involved and
    not the one worth fixing.

    Counts are per iteration, ReleaseFast, 100,000 iterations through the
    generic `each` spine, bucketed by allocation size:

    | workload | 1144 B | 1288 B | 16 B |
    |---|---|---|---|
    | `(pop 42) each` — inline literal | 1 | — | — |
    | `(pop w) each`, `w` defined as `(42)` | 2 | — | — |
    | `(pop k) each`, `k` bound by `set` | 3 | 1 | 1 |

    The 1144-byte allocation is `DispatchDriver`, which embeds a
    `ResolutionCursor` by value (`src/machine.zig`). `executeWord` starts one
    for **every word execution**: the count tracks how many words a body
    executes, not what kind they are — one for `pop`, two once `w` is called,
    three once `k`'s body calls `first`. The 1288-byte allocation is
    `IdiomDriver`, which embeds a second `ResolutionCursor` (`src/idioms.zig`),
    started once per core-origin word application. The 16-byte allocation is
    `DirectWordFallback`. The tax is therefore about 1.1 KB of allocation per
    word executed, paid by every program on every word, and the fallback is
    noise beside it. One earlier claim is withdrawn: the fallback allocation is
    not "pure waste when no `phrase_recognizer` is installed", because
    `Session` always installs `idioms.tryApply` (`src/session.zig`), so that
    case does not arise in a real session.

    - The size comes from shape, not from work. `ResolutionCursor` is a flat
      struct holding about ten mutually exclusive phase cursors as separate
      optional fields, so every word pays the width of the longest resolution
      path — dotted-name splitting, registry acquisition, use-order walking,
      qualified export lookup — to resolve a name that is almost always found
      immediately in scope or core.
    - Fixed in item 9's preference-1 order rather than an invented one. First
      `ResolutionCursor`'s ten optional phase cursors became one `union(Phase)`
      payload, taking `DispatchDriver` from 1144 to 440 bytes and `IdiomDriver`
      from 1288 to 584. Then `Unit` gained a 640-byte inline continuation slot,
      which those two drivers opt into by declaring `inline_driver`; both now
      construct in the slot instead of the allocator. `Unit.native` holds at
      most one work driver at a time — `installDriver` accepts only `idle` or
      `yielded` — so the slot is free at essentially every dispatch, and
      correctness never depends on that: a driver that starts while the slot is
      held simply allocates, and teardown routes by pointer identity.
      Bounded-first-slice promotion stays where item 9 put it, and is now very
      unlikely to be worth attempting.
    - Result, same probes, allocations per iteration: an inline literal push
      went from 2 to 1, a user word call from 3 to 1 — a word call is now
      allocation-free — and a `set` constant reference from 6 to 2. Under the
      probe's `DebugAllocator` backing the 100,000-iteration wall times fell
      from 313/614/1343 ms to 41/53/392 ms; that backing weights allocation
      count heavily, so treat the counts as the result and the times as its
      direction, not its magnitude.
    - Cost paid: every `Unit` carries the 640-byte slot whether or not it runs
      a word, so per-task footprint grows by that much. Raising the slot to
      cover a wider driver raises it for every task; measure before doing so.
      The slot is opt-in for exactly this reason, and `inlineDriverCapable`
      fails the build if an opting driver outgrows it or stops owning its
      fields, so the arrangement cannot silently revert to allocating.
    - Constraints. This changes when and where memory is acquired, never what
      executes. Recognition stays observationally invisible, and the
      differential idiom harness, behavioral suite, and allocator-failure
      sweeps all remain blocking — allocation-failure coverage especially,
      because removing an allocation moves where `error.OutOfMemory` can be
      observed. An inline slot also makes driver storage part of `Unit`'s
      footprint, so per-task memory is a reported number, not an afterthought.
    - This item gated deferred item 14, whose four extra allocations per
      constant reference were two `DispatchDriver`s, one `IdiomDriver`, and one
      `DirectWordFallback`. Three are now gone. Item 14 stays open on its
      remaining non-allocation cost, recorded there.

19. **Scalar `at` allocates a cursor and a driver — complete 2026-08-21.**
    Measured while costing the locals reader. `atPrimitive` (`src/kernel_sequence.zig`) has a
    typed fast path only for an i64 index *vector*. A scalar index falls
    through to `IndexCursor.init` plus `startDriver(IndexDriver)` — two
    allocations and a driver round trip to fetch one element — where
    `firstPrimitive`, three lines away, does the same fetch with
    `list.atUnchecked` and no allocation at all.

    - Measured at two allocations per `at`, over 100,000 elements: a hand
      lowered `([] cons dup 0 at swap pop) each` costs 6 allocations per
      element against 4 for the same shape without the `at`.
    - The fast path is `.list` collection with an `.int` index, and it has to
      reproduce `IndexCursor`'s scalar branch exactly — negative index is
      `'domain "at index is negative"`, out of range is `'domain "at index is
      out of bounds"`, a non-integer non-list index is a type error, and a
      dict collection keeps taking the `DictFindCursor` path. Anything less
      exact changes observable errors rather than costs.
    - Independent of the locals work, which removed `at` from the locals path
      entirely; `at` with a constant index is ordinary ECL that any program
      writes, so it stood on its own. `atPrimitive` now answers a `.list`
      collection with an `.int` index directly, reproducing the cursor's
      checks in the same order with the same kinds and messages. Verified
      against the cursor path on a 48-case corpus covering negative and
      out-of-range indices, non-integer indices, dict keys, index vectors,
      strings, and a non-list collection: identical on every one.

20. **Scalar binary arithmetic allocates twice per operation — complete
    2026-08-21.** Measured while costing the locals reader. In a quotation the idiom
    recognizer does not match, each scalar `+` costs two allocations per
    element: `(pop 42) each` over 100,000 elements is 34 allocations total,
    and `(pop 1 2 +) each` is 200,034. A second `+` adds another two per
    element. Recognized shapes never pay it, because they run a typed kernel
    instead of applying the quotation at all.

    - It was the same defect as item 19 and the same root cause: a kernel
      entered with scalar operands started a driver rather than computing in
      place. `binaryPrimitive` and `unaryPrimitive` now answer directly when no
      operand is a list or dict — the pervade cursor's own leaf case — and one
      change closed both items. `(pop 1 2 +) each` over 100,000 elements went
      from 200,034 allocations to 34.
    - It is now the dominant per-element cost of an unrecognized body. After
      the scope reuse above and the locals rewrite, an arithmetic-free body
      allocates nothing per element — `(|x| x x pop) each` is 42 allocations
      for 100,000 elements — so what is left in `(|x| x x +) each` is entirely
      the `+`.
    - What remains per element in a generic combinator body is real work
      rather than dispatch: `cons` allocates four to build a one-element list,
      and a body that binds with `set` costs about twenty-one. Neither is
      covered by this item. That path materializes a scope
      environment per element by design; whether it can be made cheaper
      without changing the isolation that makes it correct is unmeasured.

## Decisions Made

- **Verification is tiered, and the local tier is not a copy of CI
  (2026-08-20, user ruling).** Local runs had become a repetition of the CI
  matrix: `zig build test` alone measures 5m06s after a one-line change (about
  120s of compilation and 184s of execution), which is too big to be an inner
  loop, so it was skipped exactly when refactors needed it. There are now three
  tiers. `zig build precommit` is the local gate at about 80 seconds: Zig and
  ECL formatting, the source-architecture audit, the installed binary,
  `zig build check`, and `zig build test-precommit`. Per-push CI
  (`.builds/ci.yml`) keeps the complete matrix, and the release-candidate matrix
  keeps the exhaustive initialized-Session OOM sweep and the complete
  ReleaseFast suite. Two properties make the local tier honest rather than
  merely short. Analysis is separated from execution: `check` builds every test
  root with `generated_bin` unset, so all six roots are fully type-checked in
  about 17 seconds and a filtered execution tier never silently becomes a
  filtered compilation tier — the very first run of it found a stale
  non-exhaustive `Value` switch in `test/idiom_differential.zig`. And execution
  is selected by fully qualified test name, so a new test in an included source
  or family joins the tier with no second manifest, while the families excluded
  on measured cost or ambient resource (`concurrency:`, `typed differential:`,
  `dict-text:`, `module:`, `native:`, `fuzz:`, `acceptance:`, PTY, sockets) are
  listed in `build.zig` beside the measurement that justifies them. 218 of the
  suite's 305 tests run in the local tier.

- **Counted random floats and index-map fusion are separate optimizations
  (2026-08-20, user ruling).** The random vocabulary gains
  `rand-floats`/`rng.floats`, because a vector draw can fill one typed result
  and advance module state in one transaction; it also gains the derived
  `rng.choose ( values -- value )`, spelled by the existing `rng.int` and `at`
  semantics rather than a new kernel. Merely removing an index list cannot
  recover the vector draw's two properties. Independently, the natural array
  phrase `range (quotation) each` is identity-guarded and fused so its indices
  are generated directly into `each`'s applications. No public `tabulate` word
  is added solely to expose that optimization. Post-v1 follow-up item 8 records
  the implementation and acceptance boundaries for both changes.

- **Stateful-module lifecycle sub-rulings (2026-08-17, M11 gameplan
  dialogue).** Four questions surfaced by grounding the M11 plan
  (`gameplans/stateful-modules.json`) and resolved conversationally:
  (1) **superseded by the landed M11 ruling below:** the planning rationale
  said code pinning the target generation could not satisfy a pin-draining
  quiescence barrier and therefore made every self-directed reload/`unmodule`
  `'domain`; the implementation does not drain generation pins—only a unit
  already holding a state turn is refused, because it cannot spend a second
  turn authority;
  (2) the reload quiescence barrier is uniform across stateless and
  stateful modules — one protocol, with a quiescent-slot fast path
  keeping sequential reload immediate and new calls waiting
  cooperatively for publication (the state-only alternative was
  rejected: it makes reload timing observable inside state applications
  and leaves old and new code running concurrently without bound);
  (3) `unmodule` canonicalizes alias names exactly as `use` and
  qualified resolution do — every name that reaches a module can remove
  it; (4) **superseded by the M11 addendum below:** the original plan exposed
  slot identity through module handles and specified closed-handle display.
  The addendum removes that value kind and makes every public lifecycle
  operation name-based. During grounding, DoD-36/37's expected strings were
  corrected to the landed printer (`([3] first)`, not `((3) first)`:
  capture lists print specialized).

- **Slot lifetime is witnessed, not revalidated (2026-08-18, M11 lifecycle
  correction).** Arbiter order remains the code/state publication barrier and
  does not drain old generation pins. Independently, every published
  generation owns a refcounted, non-retargetable `SlotLease` for its whole
  lifetime. Directory lookup retains an operation lease before releasing its
  directory snapshot; commit, removal, and `within` keep that lease across
  their check/use boundaries, and a turn
  owns it while queued or granted. Removal may close and retire immediately
  after its arbiter turn, but slot storage cannot become reusable until
  admission is closed, the arbiter and retired directory chain are empty, and
  every lease—including leases held by old generation pins—has released.
  Consequently no mutable identity field or post-hoc identity recheck is part
  of the protocol.

- **Module inventory and post-close retirement are owned transitions
  (2026-08-18, M11 lifecycle correction).** Each slot owns a permanent nominal
  inventory entry. Under the registry writer lock, publication and reuse only
  link pre-reserved records or move one slot between intrusive pending/ready
  queues; they allocate nothing, scan no history, and never mutate inventory
  outside that lock. Removal transfers its granted turn and detached durable
  stack to typed scheduler retirement in the same close transition. The
  initiating Unit retains only an observation lease, so cancellation after the
  close edge cannot abandon cleanup or retain storage until Session shutdown.
  Registry maintenance later releases one quiescent generation record or
  evaluates one empty slot for reuse per step.

- **One-binder merge ruled; LISP-2 rejected (2026-08-17, user ruling).**
  The word|value kind tag is replaced by uniform application with visible
  literal capture — Milestone 10 carries the full contract; SPEC.md is
  rewritten only when it executes (the spec describes implemented state).
  Sub-rulings: `set`/`setp` survive as sugar over `literal` + `def`/`defp`;
  the sugar synthesizes a fixed `(-- value)` effect so module constants
  keep mandatory effects; `see`/`which` print stored bodies with no
  sugar reconstruction; the change lands before the stdlib milestone
  (M11 and M12 now depend on M10) and therefore pre-`0.1.0`. Gameplanned
  2026-08-17 (`gameplans/one-binder-merge.json`): the placement gate
  resolved during grounding — `scheduleWord` keeps the caller's scope for
  core words, so prelude placement of `set`/`setp` is committed rather
  than conditional. Dual namespaces
  (LISP-2) were examined and rejected: concatenative syntax has no
  reference position to select a namespace, so the move either changes
  nothing observable (one-namespace-per-name is isomorphic to the tag) or
  makes bare-name behavior policy-dependent (cross-namespace shadowing;
  words-win priority renders `set` silently inert at call sites), and the
  macro-hygiene motivation for LISP-2 is absent — ecl has no macro layer.
  M11 retains this one-binding representation but, when it makes source
  annotations optional in modules, removes the no-longer-needed synthesized
  effect from the prelude `set`/`setp` bodies. Durable state is a separate
  module-owned operand stack, not a mutable name-resolution layer.
- **M11 addendum removes public slot identity (2026-08-18, user ruling;
  public-value portion superseded by the Step 15 ruling below).**
  `__MODULE__`, the `'module` value kind, handle-targeted removal, handle
  rendering, and all handle-control machinery are deleted. Canonical module
  names may be dotted; qualified execution splits at the final dot. Nominal
  `ModuleName`, `BindingName`, and `QualifiedName` brands own validation and
  prevent ordinary cross-domain id misuse. Their factories share the reader's
  scalar classifier, including the reader's Unicode whitespace set, so host
  and native inputs cannot mint names the source grammar rejects. There is no
  trusted validation mode for reserved syntax markers, and commit, removal,
  and alias publication expose distinct error sets containing only outcomes
  each transition can produce. `qualify` constructs a validated
  qualified word and `execute` invokes it through ordinary dispatch. Internal
  homes and slot leases preserve definition-site and lifetime authority without
  exposing either as an ECL value.
- **Anonymous module images restore a public value without exposing slot
  identity (2026-08-20, user ruling; supersedes only the public-value portion
  of the M11 addendum).** `@module` returns an immutable anonymous module
  image; `register` names and upserts that image in the registry; `@defm`
  combines the operations for source definitions. Live durable state,
  arbitration, generation currency, aliases, removal, and lifetime authority
  remain registration-slot owned. An image has no name or slot back-reference,
  and definition metadata is module-local; qualified resolution supplies the
  opaque registration home used by private lookup, reflection, and `within`.
  The same image may be registered more than once with independent state.
  `register` preserves the existing slot's state on replacement rather than
  introducing a separate reload word or publication protocol. The value is
  type `'module`, identity-matched, printed `<module>`, and unavailable to
  source deserialization, JSON, and native ABI-v1 conversion.
- **Modules are ECL's durable state objects (2026-08-17, user ruling; public
  identity portion superseded first by the M11 addendum and then by Step 15's
  image/registration split).** A
  dynamically constructed canonical module registry slot owns one durable
  operand stack per Session, initialized by the module construction body's
  final stack and preserved across code generations. Ordinary module words
  continue to use the caller stack and ordinary annotations; `partial` or
  `with` explicitly captures caller inputs into a quotation, module-homed
  `within` executes it transactionally against a serialized private draft, and
  contextual `without` explicitly removes values from that draft for delivery to
  the caller. No
  state-specific annotation, implicit argument/result movement, or mutable
  binding overlay exists. The slot, not a replaceable code generation, is the
  internal state owner for the duration of a registration; Step 15's public
  image value still exposes none of that identity or lifecycle authority.
  There is no resident actor,
  mailbox, or supervision tree. M11 also adds an explicit quiescing removal
  path; native resource values and SDK access to its internal stack authority
  remain later extensions.
- **Source annotations are uniformly optional (2026-08-17, user ruling).**
  Top-level and module `def`/`defp` accept absent, effect-only,
  documentation-only, and combined annotations. A supplied module effect
  remains a checked cross-boundary contract; absence means unknown rather than
  inferred. Annotations classify, document, and optionally assert behavior but
  never authorize state access or move values. This lets M11 remove M10's
  synthesized `(-- value)` metadata from `set`/`setp` and restore exact
  equivalence with `literal` plus `def`/`defp`. Native `Call` effects remain
  mandatory ABI declarations, and shipped prelude documentation remains a
  repository authoring requirement rather than a source-language restriction.
- **Host = Zig** (user ruling, this session). Consequences absorbed into the
  plan: Step 14 generates the kernel matrix via comptime; later explicit SIMD
  rides `@Vector` behind that same typed range ABI;
  RC/atomics use `@atomicRmw` with the d.23 orderings, publication is an atomic
  pointer swap over immutable snapshots, and runtime failures use Zig error
  unions with an out-param error dict.
- **Zig is the kernel; ecl source is the prelude.** Irreducible or
  runtime-bound [P] operations live in the host, while shipped [E] core
  words are authored in `src/prelude.ecl`, embedded into the binary, and
  evaluated into the writable core before it is frozen. Zig owns the
  bootstrap loader but not alternate encodings of derived bodies. The M5
  host assembly of `wrap`, `pair`, and `sort` is explicitly temporary
  staging. A generated system image or snapshot is permitted only as a
  profile-justified post-v1 startup optimization; it must be reproducible
  from the same ecl source and cannot become a second semantic authority.
- **The Zig executable is the semantic reference.** The former
  cross-implementation M5/M6 cases are exact CLI snapshots, and the
  superseded walking skeleton is not retained as a second authority.
- **M5 kernel semantics are frozen; its unbuilt structural fast path is owned
  by post-terminal Step 14.** The as-built `PervadeCursor` consumes operands,
  performs bounded explicit-frame descent, returns one owned result, and raises
  `'domain` beyond 256 data levels, but its flat-list branch still reboxes one
  cell and schedules one scalar node at a time. The intended replacement must
  dispatch on `value.HeapKind` without a second tag enum, take explicit
  half-open typed ranges, poll after at most 65,536 elements, and adopt a unique
  width-compatible input buffer only through the mask-before-store/fault-rescan
  protocol. Those are Step 14 acceptance constraints, not claims about the M5
  implementation. Values, errors, representations, scalar extension, and
  pervasion behavior remain frozen throughout the migration.
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
- **The promoted CLI reference is a snapshot CI obligation.** `zig build
  test-snapshots` executes all 74 promoted cases and compares exact exit
  status, stdout, and stderr with the checked-in `ohsnap` transcript. It also
  runs under ordinary `zig build test`. Supplemental vocabulary uses public
  CLI acceptance coverage alongside the focused runtime properties.
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
  optional capabilities; SDK access to module state through narrowly split
  module-stack observation/update authority, resources, blocking offload, external
  wake, package assets, retained ECL values, and evaluation are future
  capabilities.
- **Native calls are transactional leaves but native code remains trusted.**
  Declared inputs remain pinned, candidate outputs belong to one call, and only
  exact completion mutates the stack; fail/cancel/timeout/OOM/abandonment do
  not. Aggregate access is available only through `Reschedule`-budgeted cursors
  and builders mapped to the real `WorkDriver`. The runtime cannot preempt or
  infer reductions for arbitrary native instructions, so inline code must
  return promptly and duration diagnostics expose violations after the fact.
  M12 HTTP remains the sole internal direct-blocking v1 exception; `Offload` is
  the committed first scheduling extension.
- **Native lifetime is one ordered shutdown.** Session shutdown closes new
  native-call creation, quiesces calls, destroys continuations, settles ECL
  retirement, and only then closes libraries. External side effects a native
  word performs are not rolled back with the operand-stack transaction.
- **M9's capability set is closed at exactly what M12 consumes** (gameplan
  ruling, 2026-08-16). Mandatory `Call` plus optional `BuildValues` and
  `Reschedule`; CSV and JSON are pure value-in/value-out transforms with no
  per-Session state, so module-stack draft/outward-transfer capabilities and the
  scheduler-integrated arbiter are absent from the v1 native wire contract.
  M11 introduces the arbiter and nominal authorities internally for userland
  stateful modules; exposing them to native callbacks remains a later explicit
  wire revision. The descriptor and capability enum therefore expose no
  module-state fields or ids in v1.
- **The static transport is an image-pin variant, not a second path** (gameplan
  ruling, 2026-08-16). The load typestate carries `dynamic` (the library
  handle) and `static` (a no-op pin over a linked first-party descriptor);
  both traverse identical validation, publication, transaction, and teardown,
  so M12's CSV and JSON cannot drift from a `.eclmod`'s behavior. M9 proves the
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
  `type` reports `'dict`; printing, `match?`, `keys`/`vals`/`at`/`put`,
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
  session): at M12 planning, `std.http` wins if it handles TLS 1.3
  against 5 real-world hosts including redirects and chunked encoding;
  otherwise bind libcurl. **Resolved at M12 planning (2026-08-18): the
  spike ran on pinned Zig 0.16.0 and `std.http.Client` won** — TLS 1.3
  real-world hosts (ziglang.org, google.com, api.github.com,
  en.wikipedia.org), a followed redirect chain, chunked transfer, gzip
  decompression, and a JSON POST all passed. No libcurl; the
  zero-C-dependency single static binary stands. Timeouts ride
  `Io.async` futures plus `Io.Timeout` cancellation, since the client
  itself has no timeout fields.
- **Qualified reference auto-loads (user ruling, 2026-08-18, M12
  planning).** The first qualified reference (`stats.mean`) to an
  unregistered module triggers exactly the `use`-miss auto-load —
  embedded stdlib and `ECL_PATH` modules are addressable Erlang-style
  with no ceremony. `use` remains solely the unqualified-export splice
  with shadow notices. A misspelled dotted word costs one bounded,
  uncached search before `'undefined-word`; the trust boundary is
  unchanged (`use` already auto-loads — only the trigger moves).
  Recorded in SPEC.md's Modules/Loading section at ruling time, ahead of
  the implementation.
- **Qualified observation auto-loads too** (user ruling, 2026-08-19):
  registration state is an implementation detail. `body`, `doc`, `see`,
  `which`, and qualified completion resolve through the same embedded-stdlib/
  `ECL_PATH` loader as execution. Completion performs a load-only turn: it
  executes no export and imports nothing. Thus every fully qualified operation
  depends on the available module transports, never on whether some earlier
  call happened to load the module.
- **Embedded stdlib wins auto-load precedence over `ECL_PATH`** (user
  ruling, 2026-08-18, M12 planning), identically for `use`-miss and
  qualified-miss: stdlib names stay stable — a stray `csv.ecl` on the
  path cannot silently replace the stdlib; in-session shadowing and
  explicit `@module` registration remain the documented override; embedded
  resolution pays no filesystem stat.
- **stdin is an io word, ruled in at M12** (user ruling, 2026-08-18, closing
  the former open question): `io.stdin` [P] `( -- string )` reads the whole
  piped stream once; legal in `-e` and script-file modes; `'io` in modes
  where stdin is the program source. `"/dev/stdin" io.slurp` was rejected as
  the permanent answer — the positioning deserves a word.
- **The str surface is exactly thirteen words** (reaffirmed 2026-08-19):
  `upper lower trim trim-left trim-right starts? ends? contains? index-of
  replace repeat pad-left pad-right`; case operations ASCII-only per the
  character-model ruling; `index-of` is `'domain` when absent, `contains?`
  is the predicate form. All compact ECL-source definitions over core
  kernels.
- **Observable text I/O is one `io` module** (user ruling, 2026-08-19):
  `pp prin print inspect stdin slurp spit lines`. Arbitrary-value input does
  not make `pp` or `inspect` a poor I/O fit—the words perform output.
  Conversely, canonical `str` stays in the prelude because it returns a value
  without an I/O effect, and `lines` belongs in `io` because its subject is a
  path/stream, not a string. No compatibility globals remain for the eight
  module words.
- **http words are fixed full arity** (user ruling, 2026-08-18):
  `http.get ( url headers -- response )` and
  `http.post ( url headers body -- response )`, with `{}` for no headers.
  No convenience variants.
- **http publishes through a new `builtin` `ModulePublication` arm**
  (M12 gameplan ruling, 2026-08-18). The M4-scoped "native-builtin-module
  mechanism" was never actually built — `ModulePublication` had only
  `word | native` arms, making a primitive-backed module word
  unrepresentable. M12 adds the `builtin` arm (primitive plus mandatory
  effect and documentation) so http's words are ordinary machine
  primitives with full host authority published under a module name; the
  SDK surface does not widen.
- **Stdlib is written in ECL wherever possible, native only when
  necessary** (user directive, 2026-08-18, standing): `result`, `str`, and
  `table` are embedded ECL source; `io`, `json`, and `http` are builtin
  modules where runtime authority or internal representation access is
  required; `csv` alone is native as the deliberate first-party proof of the
  M9 public callback protocol. `http` is builtin because TLS and sockets are
  host authority no ECL program can express through the SDK.
- **Result-envelope vocabulary consolidates into the result module**
  (user ruling, 2026-08-18): `ok?`, `or-raise`, and `or-else` leave the
  prelude and join `result`, routed through the module's `checked`
  validator (a malformed dict is rejected as such instead of failing on
  a raw missing key). The boundary: envelope *interpreters* live in
  `result`; error *producers* (`raise`, `fail`, `assert`) stay core —
  an error dict in flight becomes a result only when `@attempt`/`await`
  reifies it. Two clarity renames land with the move (user directive:
  naming consistent and maximally clear): `map-error -> map-err`
  (every failure-arm word spells `err`, matching the `'err` tag and
  Rust's `map_err`) and `case -> either` (the old name shadowed prelude
  `case` with unrelated semantics under `'result use` — an
  unrelated-homonym trap; `either` is the Haskell-lineage eliminator
  name and collides with nothing; `result.partition` keeps its name
  because adjacent-concept shadowing is the benign, documented kind).
  `and-then` keeps its name — there is deliberately no `result.map`:
  `@attempt`'s lifting collapses functor map into `and-then` on the
  success side, and the distinction survives only on the error side
  (`map-err` rewraps, `recover` replaces the outcome) — now stated in
  `and-then`'s doc. Made cheap by the same-day qualified-miss
  auto-load ruling; the common idiom becomes `@attempt result.or-raise`
  with `'result use` splicing bare names back. Ships as the fourth
  standalone patch (`gameplans/result-consolidation.json`, local,
  untracked), after unit-word-spelling.
- **Bitwise words are pattern words** (user ruling, 2026-08-18): `band
  bor bxor bnot bsl bsr` (Erlang naming — the logical `and`/`or`/`not`
  are taken) operate on the i64 two's-complement bit pattern. `bsl`
  truncates bits off the top and `bsr` zero-fills — bit movement, not
  arithmetic, so no overflow error by design; `*` and friends keep
  overflow-is-error untouched. Shift counts outside 0..63 are `'domain`
  with per-element identification; non-int operands are `'type`;
  int-leaf-only, fully pervasive. Overflow remaining an error means a
  PRNG step is inexpressible in arithmetic ECL — bitwise words make a
  user-authored xorshift expressible in source, which is the
  inspectability story.
- **Randomness resolved (user rulings, 2026-08-18 — closing the last
  open question).** Three layers, no hidden state: (1) pure counter-based
  step kernels — a SplitMix64 counter construction (ruled 2026-08-18,
  superseding the initial Philox proposal: `std.Random.SplitMix64`
  supplies the mixer, the closed-form counter jump, rejection bounding,
  and float conversion are ours, and tests pin Vigna's published test
  vectors so sequences are defined by the algorithm, not the pinned
  stdlib; statistically weaker than Philox, accepted for a documented
  non-cryptographic scripting RNG) — generator state as plain data
  `[key counter]` — `rand-int ( state m -- state' x )`,
  `rand-ints ( state n m -- state' list )`,
  `rand-float ( state -- state' f )`; deterministic values,
  differential-testable, safe for the 1-vs-N worker suite because output
  is a function of visible inputs only. (2) One impure capability word,
  `entropy ( -- int )`, gated like the filesystem ('io without host
  authority) and excluded from deterministic fixtures. (3) A userland
  `rng` stdlib stateful module (the first real M11 showcase): `seed int
  ints roll float deal shuffle` over `within` transactions; fixed
  documented initial state so sequential programs are reproducible by
  default, nondeterminism opt-in via `entropy rng.seed`; concurrent
  draws through the shared module are arbiter-serialized and honestly
  worker-count-nondeterministic — reproducible parallel randomness is
  explicit per-task states through the pure kernels. Per-session and
  per-unit ambient RNGs were rejected: the former breaks the 1-vs-N
  determinism gate outright, the latter buys terseness with hidden
  per-unit state against the language's explicitness doctrine. Bitwise
  and randomness ship together as one standalone post-M12 patch
  (`gameplans/bitwise-and-randomness.json`, local, untracked), executed
  after the M12 gameplan completes and before M13 acceptance.
- **Unit constructors carry a `@` spelling convention** (user ruling,
  2026-08-18; `@` chosen over `&` — `&` implies async, wrong for the
  synchronous attempt; `@` reads as *place*, which is what a
  share-nothing unit is). A leading `@` marks exactly the words that
  apply a quotation in a fresh unit — one unit per application for
  `@each`, whose children are seeded with exactly their element, while
  `@attempt`/`@spawn`/`@module` substacks receive nothing implicitly
  (zero-input is a property of three members, not the class invariant).
  **The `-with` variants are dropped entirely** (ruled 2026-08-18; the
  ruling superseded, within one planning session, both an initial
  refusal of `@each-with` and the subsequent complete-the-family ruling
  that added it — the record keeps the chain): once the `@module`
  operand flip made every member exactly the composition `with @X`, the
  words carried nothing but a name. `attempt-with`, `spawn-with`, and
  `module-with` are deleted; no `@each-with` exists. Seeding is spelled
  compositionally at call sites — `values (q) with @attempt`,
  `list values (q) with @each` (each child's stack is its element
  followed by the values, element deepest), `values (body) with 'name
  @module` — so one word scales to every future unit constructor,
  user-defined ones included, with no companion-word obligation; the
  last `-with` ambiguity with `zip-with` disappears; and the future fast
  path is phrase-level recognition of `with @each`/`with @attempt`
  through the M6 matcher — the performance option the equivalence law
  existed to protect, now needing no dedicated words. The renames:
  `attempt -> @attempt`, `spawn -> @spawn`, `par-each -> @each`,
  `module -> @module`. Hard changes, no
  aliases, pre-`0.1.0`. Two same-patch companions (ruled 2026-08-18):
  **`@module` flips to name-last operand order** — `( quotation name -- )`,
  `(body) 'stats @module` — matching `def`/`set`, where the bound name
  sits nearest the binder (M4's name-first order was an unreconciled
  Forth reflex); seeded registration is `values (body) with 'name
  @module`, the name riding above the composition with no shuffle at
  all, which is what made dropping `with 'name @module` possible. Migration is
  loud: symbol/list operand types make every
  un-flipped call site `'type`, never a misregistration. And **`ecl fmt`
  extends its commenting convention to modules**: a top-level
  registration ending in a literal quoted name followed by `@module`
  (bare or `with`-seeded) gains
  a synthesized `### module <name>` header exactly as definitions gain
  `### def <name>`; the embedded stdlib sources are reformatted under it.
  Deliberately unmarked: `each`/`fold`-family
  (implicitly fed their elements), `infra`/`within` (apply an explicitly
  named other stack), `use`/`load`/`unmodule` (no quotation), the task
  observers, and `with`. `@` stays an ordinary word character — the
  source audit enforces the convention for first-party vocabulary via a
  spelling manifest; users are encouraged to follow it. The same patch
  lands the guided isolation error (underflow at a unit-constructor
  substack base names the isolation and suggests `with` seeding or
  `partial`, per the binder-suggests-`partial` precedent) and records
  the identity that motivated the ruling: `(q) @attempt` is
  observationally `(q) @spawn await`, so attempt-call symmetry was
  traded away to keep attempt-spawn symmetry, which the shared result
  contract makes load-bearing. The same patch also sanctions **the
  after-row annotation token** (user ruling, 2026-08-18): a bare `...`
  as the entire after portion of a definition annotation —
  `(result on-ok on-err -- ...)` — declares fixed-before/variable-after;
  before-slots are boundary-checked as today and the post-condition
  compare is skipped. Grammar is strict in v1 (after is all named slots
  or exactly `...`); named Factor-style rows remain the deferred static
  checker's extension, for which the bare token is the anonymous row;
  the native SDK excludes it (Call effects stay statically exact);
  `...` joins `--`/`:` as reserved on namespace introduction while inert
  as a value. SPEC entries already informally spelling ellipses
  (`unless`, `within`) become sanctioned, and doc-only stdlib
  annotations with fixed inputs (`result.case`) upgrade to partial
  effects. Lineage: ANS Forth's `i*x`/`j*x` comment notation and
  Factor's checked row variables; ecl takes the anonymous middle.
  Ships as the third standalone patch
  (`gameplans/unit-word-spelling.json`, local, untracked), after
  bitwise-and-randomness; its sweep conforms the runnable acceptance
  assertions below while as-built milestone narratives keep their
  historical spellings.
- **Wait-set publication is terminal for its setup** (found 2026-08-18
  during the result-consolidation sweep). `WaitSet.advanceSetup` wrote its
  terminal phase *after* `activate()`, but activation is exactly what lets
  another selector deliver and drop the wait set's last reference — a
  use-after-free. The write now precedes the publish and the arm reads
  nothing afterward. The defect was always in the code; it became
  reachable only once `result.ok?` moved into a module, so the hot-reload
  test's racing children each trigger an auto-load. Confirmed by three
  `test-tsan` runs: crash with the auto-load and no fix, pass without the
  auto-load, pass with both. That test is now the standing reproducer.
- **Toolchain pinned: Zig 0.16.0** (resolved at M1 planning, closing the
  former open question). Pinned in `build.zig.zon`
  (`minimum_zig_version`) and by the CI tarball; revisited only at
  milestone boundaries and at the M12 http spike. Revisited at that spike
  (2026-08-18): 0.16.0 stands.
- **Forge and CI: sourcehut** (M1 planning ruling). The repo is
  `git.sr.ht/~subsetpark/ecl` (unlisted; flip with
  `hut git update --visibility public`); CI is builds.sr.ht via
  `.builds/ci.yml`. Every milestone's per-push CI additions land in that
  manifest — the workstream's earlier generic "CI" references mean
  builds.sr.ht. The quadratic initialized-Session `test-oom` replay is an
  explicit release-candidate proof rather than a per-push task; its focused
  component probes remain in the blocking ordinary suite.
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
  - **Verify by** `cmd`: `ecl '(1 2 3)'` and `ecl '(1 2 3) [1 2 3] match?'`.
  - **Expected**: `[1 2 3]` and `1`.
  - **Traces to**: Milestone 1 — `src/list.zig` (construction
    specialization) + `src/print.zig` (representation-exposing printer).

- **DoD-3 — ragged pervasion**
  - **Assert**: pervasive `*` recurses through ragged nesting.
  - **Verify by** `cmd`: `ecl '[[1 2] [3]] 10 *'`.
  - **Expected**: `([10 20] [30])`.
  - **Traces to**: Milestone 5 — pervasion spine recursion.

- **DoD-4 — mask vs match equality**
  - **Assert**: `=` is pervasive, `match?` is whole-value.
  - **Verify by** `cmd`: `ecl '[1 2] [1 2] ='` and `ecl '[1 2] [1 2] match?'`.
  - **Expected**: `[1 1]` and `1`.
  - **Traces to**: Milestone 5 — comparison kernels; Milestone 1 —
    `src/equal.zig` (structural `match?` and hash).

- **DoD-5 — overflow is an error with element identification**
  - **Assert**: int overflow inside a leaf kernel raises `'overflow`
    naming the operation, not a wrapped result.
  - **Verify by** `cmd`: `ecl '9223372036854775806 [1 2] +'`.
  - **Expected**: exit ≠ 0; stderr error dict with `'kind 'overflow`.
  - **Traces to**: Milestone 5 — scalar kernel fault identification in
    `src/kernel_numeric.zig`.

- **DoD-6 — float regime**
  - **Assert**: `inf` is a literal that propagates; NaN-producing ops
    are `'domain`; `0.0`/`-0.0` agree under `=` and `match?`.
  - **Verify by** `cmd`: `ecl 'inf 1 +'`; `ecl 'inf inf -'`;
    `ecl '0.0 -0.0 match?'`.
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
    `(pop pop 42) '+ def [1 2 3] 0 (+) fold io.pp`.
  - **Expected**: `42`.
  - **Traces to**: Milestone 6 — resolution-identity guards.

- **DoD-11 — module privacy and body-extraction honesty**
  - **Assert**: privates are reachable from publics, unreachable
    qualified, and extracted bodies lose private context.
  - **Verify by** `cmd`: fixture `modules-privacy.ecl` defines
    `(40 's setp (s 2 +) ( -- n ) 'f def) 'm @module`, calls `m.f`,
    then attempts `m.s`; companion fixture `body-extraction.ecl`
    defines the same module and runs `'m.f body call` at session scope.
  - **Expected**: the privacy fixture prints `42`, then exits ≠ 0 with
    `'kind 'undefined-word`, `'word 'm.s`; the extraction fixture exits
    ≠ 0 with `'kind 'undefined-word`, `'word 's`.
  - **Traces to**: Milestone 4 — registry resolution + visibility.

- **DoD-12 — hot reload heals all access paths**
  - **Assert**: re-registering a module updates qualified, `use`d, and
    aliased callers.
  - **Verify by** `cmd`: fixture `hot-reload.ecl`, whose module words carry
    declared effects.
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
    `(99) 'kept def 20 + missing`, then `dup io.pp`, then `kept io.pp`.
    At M4 run `(1 'k set) @attempt pop k`; at M6 run the original probe
    `[1 2 3] (dup 'k set k *) each pop k`.
  - **Expected**: after the failed line `dup io.pp` prints `10` and
    `kept io.pp` prints `99`; both isolation probes error
    `'undefined-word` for `k`.
  - **Traces to**: Milestone 3 — exact unit stack rollback; Milestone 4
    — the shared lazy child-scope mechanism proven through `@attempt`;
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

- **DoD-18 — spawn/await result protocol**
  - **Assert**: `@spawn`+`await` delivers the same result shape as
    `@attempt`; `await` is idempotent; source-defined `await-all` returns
    every ordinary result in input order without re-raising failures.
  - **Verify by** `cmd`: `ecl '(1 2 +) @spawn dup await pop await result.or-raise call'`
    and a mixed success/failure task-list fixture comparing `await-all` with
    `(await) each` at 1 and 8 workers.
  - **Expected**: `3`; the two ordered result lists match at both worker
    counts.
  - **Traces to**: Milestone 7 — task cells.

- **DoD-19 — cancellation and timeout**
  - **Assert**: `cancel` yields `{'err {'kind 'cancelled …}}`;
    `await-for` on a slow task yields `'kind 'timeout`.
  - **Verify by** `cmd`: fixture `cancel-timeout.ecl` (spins a
    `while`-loop unit, cancels it; awaits a sleeper with a 50ms
    deadline).
  - **Expected**: both error kinds observed; exit 0 (the script handles
    results).
  - **Traces to**: Milestone 7 — cancel flags, safe points, timer thread.

- **DoD-20 — @each determinism and leftmost error**
  - **Assert**: `@each` results are in program order and a failing
    element re-raises the leftmost `'err`; output is identical at 1 and
    N workers.
  - **Verify by** `cmd`: fixture `at-each.ecl` runs twice with
    `ECL_WORKERS=1` and `ECL_WORKERS=8`; two failing children name distinct
    missing words so selection of the index-zero error is observable.
  - **Expected**: identical stdout both runs; the designated leftmost
    `'left-missing` error surfaces rather than the racing `'right-missing`.
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
    path-order, wrong-name, ABI-version, duplicate-word, missing-doc,
    invalid-effect, unsupported-capability, invalid-continuation,
    entry-failure, and exact-stride fixture variants.
  - **Expected**: the valid artifact returns `42`, its nonempty documentation,
    canonical `(n -- result)` effect, `which` reporting the binding as `native`
    with its inferred capability list, and `see` rendering
    `<native:sample.increment>` with the ordinary combined annotation. Each
    invalid artifact reports its precise load error, leaves `sample` absent from
    registry/reflection, and never selects a later candidate.
  - **Traces to**: Milestone 9 — SDK descriptor generation, `ECL_PATH` native
    transport, consuming loader typestate, atomic module publication, and exact
    ABI validation.

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
    with an unknown capability id or invalid continuation layout is refused at
    load; deferred native access to module state is unreachable because no
    corresponding wire fields or capability ids exist.
  - **Verify by** `cmd`: `zig build test-native-sdk-negative`,
    `zig build fuzz-native-descriptor`, and the production-loaded fixture
    under Debug, ReleaseSafe, one/eight workers, and Linux TSan. The production
    scheduler property keeps a delayed continuation alive through Session
    shutdown and measures the complete lifetime with `DebugAllocator`.
  - **Expected**: all compile-negative fixtures are rejected by SDK
    comptime validation; arbitrary bounded descriptor metadata never escapes
    validation; unknown-capability and invalid-continuation artifacts report
    precise load errors and publish nothing; and
    allocator accounting returns to baseline with no callback reachable after
    the registry releases its final image pin.
  - **Traces to**: Milestone 9 — SDK comptime reflection, the descriptor
    validator, library pins, and ordered Session teardown. SDK access to the
    module stack remains deferred; M11 owns the internal draft/outward-transfer
    authorities, userland behavior, and arbiter assertions.

- **DoD-25a — result algebra**
  - **Assert**: the embedded `result` module constructs and observes canonical
    results, composes successful stack values through `with @attempt`, maps and
    selectively recovers errors without swallowing unmatched kinds, eliminates
    either variant, and aggregates ordered result lists with the specified
    leftmost-error and partition behavior. Malformed result dicts fail before
    any supplied quotation runs.
  - **Verify by** `cmd`: fixture `result.ecl` covers empty, one-value, and
    multi-value success stacks; word values remain inert; `and-then` success
    and short-circuit paths; recovery of `'io` but not `'type`; a failing
    recovery quotation; error mapping; both `case` branches; all-success,
    mixed, and empty `all`; and stable `partition` output. Run the same fixture
    after `'result use` and through qualified `result.*` calls.
  - **Expected**: successes preserve exact stack order and representation;
    short-circuited and unmatched errors are structurally identical to their
    inputs; `all` returns the leftmost error or ordered success-stack lists;
    `partition` preserves order within both outputs; malformed inputs are
    rejected without executing probe quotations.
  - **Traces to**: Milestone 12 — embedded source `result` module using the M6
    result protocol and `with @attempt`.

- **DoD-25 — json round-trip**
  - **Assert**: `json.parse` maps objects/arrays/numbers per the
    ruling; `json.emit ∘ json.parse` is identity on a canonical corpus;
    non-string-keyed dicts refuse to emit.
  - **Verify by** `cmd`: fixture `json.ecl` over a corpus file
    including nested objects, `null`, integral and non-integral
    numbers; plus `{1 2} json.emit` expecting `'kind 'type`.
  - **Expected**: corpus round-trips byte-identically; the emit error
    fires.
  - **Traces to**: Milestone 12 — json native module using M9 capabilities.

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
  - **Traces to**: Milestone 12 — csv native module using M9 capabilities.

- **DoD-27 — table representation and conversions**
  - **Assert**: a valid table remains an ordinary dict under every core
    interface, while `table.*` constructors, row/record conversions, and
    transformations preserve its ordered equal-length-column convention.
  - **Verify by** `cmd`: fixture `table-values.ecl` constructs populated
    tables through every constructor and zero-row tables through the explicit
    column, named-row, and header-row constructors; observes `type`, `match?`,
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
  - **Traces to**: Milestone 12 — embedded `table` module value policy and
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
  - **Traces to**: Milestone 12 — embedded `table` module validators.

- **DoD-29 — table filtering and aggregation**
  - **Assert**: CSV text can be explicitly cast, filtered, grouped by named
    columns, and aggregated with ordinary ECL quotations while preserving
    first-key occurrence order and stable rows within each group.
  - **Verify by** `cmd`: fixture `table-analysis.ecl` uses `io.slurp`,
    `csv.parse`, and `table.from-header-rows` on `sales.csv`; explicitly casts
    `amount` and `quantity`, derives `revenue` with `table.with-column`, filters
    by an exact 0/1 mask, inspects `table.group-by`, and calls
    `table.aggregate` by `region` with `sum`, `len`, and `mean` quotations.
  - **Expected**: the grouped index dict and final region/revenue/count/mean
    column dict match the checked-in expected values exactly; no header or
    numeric inference occurs.
  - **Traces to**: Milestone 12 — embedded `table` module grouping and
    aggregation words.

- **DoD-30 — stable table joins and explicit missingness**
  - **Assert**: inner and filled left equijoins support named composite keys,
    expand duplicate matches many-to-many in stable left-major/right-minor
    order, reject non-key column collisions, and never invent a missing value.
  - **Verify by** `cmd`: fixture `table-joins.ecl` loads an orders CSV through
    `io.slurp`/`csv.parse` and a JSON array of customer records through
    `io.slurp`/`json.parse`, converts both to tables, then exercises
    `table.inner-join` and `table.left-join-with` using duplicate, unmatched,
    composite-key, collision, and exact-fill cases.
  - **Expected**: inner and left results match expected ordered column dicts;
    duplicates expand in the specified order, unmatched left rows use only
    caller-provided fills, collisions and incomplete fills are `'domain`, and
    a JSON `'null` value remains ordinary data when present.
  - **Traces to**: Milestone 12 — embedded `table` module join words.

- **DoD-31 — http client**
  - **Assert**: `"<url>" {} http.get` against a local fixture server
    returns a dict with `'status 200` and the body; a refused connection
    yields `'kind 'io`.
  - **Verify by** `cmd`: the test suite builds and spawns the loopback
    fixture server (`test/http_fixture_server.zig`, ephemeral port printed
    as the readiness handshake); the server-backed cases run in
    `src/tests/http_test.zig`; the dead-port `'io` case also runs as a
    network-free real-binary fixture.
  - **Expected**: status/body asserted; the dead port errors `'io`
    without crashing the interpreter.
  - **Traces to**: Milestone 12 — internal builtin-backed http module
    (`src/stdlib/http.zig`, `std.http.Client` backend) and documented
    direct-blocking exception.

- **DoD-32 — str module via embedded stdlib**
  - **Assert**: `'str use "hello" str.upper` works with no ECL_PATH
    set, and so does the bare qualified form with no `use` at all
    (qualified-miss auto-load, ruled 2026-08-18).
  - **Verify by** `cmd`: `ecl "'str use \"hello\" str.upper io.pp"` and
    `ecl '"hello" str.upper io.pp'`, both in an empty environment with a
    copied binary in an empty directory.
  - **Expected**: `"HELLO"` from both.
  - **Traces to**: Milestone 12 — the embedded stdlib manifest
    (`src/stdlib.zig`) consulted by the auto-load driver before
    `ECL_PATH`, plus the qualified-miss auto-load trigger (mechanism
    Milestone 4).

- **DoD-33 — source architecture audit**
  - **Assert**: every first-party Zig input belongs to exactly one production
    or verification manifest, and every classified production file is covered
    by the applicable bounded-body and unsafe-cast checks.
  - **Verify by** `cmd`: `zig build source-audit`; `zig build test` depends on
    this audit.
  - **Expected**: exit 0 with exhaustive source classification and no
    architecture-policy violations.
  - **Traces to**: Milestone 13 — the source architecture audit (d.23).

- **DoD-34 — declared source effects remain live contracts**
  - **Assert**: when a module word supplies an effect, it is enforced as a live
    contract on entry from outside its home; same-home calls remain unbracketed,
    and optional documentation in the same annotation remains visible through
    `doc` and `see`.
  - **Verify by** `cmd`:
    `ecl -e "((dup +) (a -- b c) 'lies def) 'm @module 1 m.lies"`;
    `ecl -e "((dup +) (a -- b : \"Double.\") 'dbl def) 'm @module 'm.dbl see 'm.dbl doc"`;
    and the `module: effect shape cross-home contract and same-home TCO` fixture
    at depths 20 and 20,000.
  - **Expected**: the false declaration raises `'contract`; `see` includes
    `(a -- b : "Double.")` and `doc` returns `"Double."`; both recursion depths
    have the same bounded maximum frame count.
  - **Traces to**: Milestone 4 — module call-contract entry, combined
    annotation reflection, and same-home tail calls.

- **DoD-34a — native effect declarations remain mandatory**
  - **Assert**: SDK-loaded native words derive a validated effect from their
    typed `Call`, require nonempty documentation at comptime and load time, and
    expose both through `doc`, `which`, and `see` like ordinary callables; the
    source-language relaxation in M11 does not create an untyped native entry.
  - **Verify by** `cmd`: `zig build test-native-sdk-negative` runs the
    compile-negative missing-`Call` and missing-documentation fixtures;
    `zig build test-native-runtime` loads the real fixture and checks all three
    reflection commands plus callback/effect/capability consistency.
  - **Expected**: both incomplete descriptors are rejected; `which` renders
    the loaded binding kind as `native` followed by its inferred capability
    list, and `see` renders `<native:<module>.<word>>` with the ordinary combined
    annotation.
  - **Traces to**: Milestone 9 — native typed effects, descriptor validation,
    and reflective metadata.

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

- **DoD-36 — one-binder set publishes literal captures**
  - **Assert**: `set` publishes a word binding whose stored body is the
    literal capture: bare reference applies it and pushes the value, and
    `body` returns the capture with no hidden value-binding representation.
  - **Verify by** `cmd`: `ecl -e "3 'x set x 'x body"`.
  - **Expected**: final stack `3 ([3] first)` (the capture list prints
    specialized; drift from the plan's `((3) first)` corrected against the
    landed printer, 2026-08-17).
  - **Traces to**: Milestone 10 — `src/prelude.ecl` `### def set` block +
    `src/definition_prims.zig` reflection over word bindings.

- **DoD-37 — one binding kind supports annotated module constants**
  - **Assert**: an explicitly annotated literal-capture module definition is
    the same callable binding kind as every other word; qualified cross-home
    reference checks its declared effect, and reflection exposes its body.
  - **Verify by** `cmd`:
    `ecl -e "(40 literal (-- value) 'k def) 'm @module m.k 'm.k body 'm.k which"`.
  - **Expected**: stdout shows `40` and a `m.k -> m.k def public` which
    line carrying `(-- value)`; `body` returns `([40] first)` with no distinct
    value-binding representation.
  - **Traces to**: Milestone 10 — the literal-capture publication path and the
    shrunk `Binding` union in `src/env.zig`, which M11 leaves unchanged when it
    adds a separate durable module stack.

- **DoD-38 — source annotations are optional in every definition context**
  - **Assert**: module `def`/`defp` accept no annotation, effect only,
    documentation only, or both; a supplied effect remains a live
    cross-boundary contract, while omission adds no inferred check. `set` and
    `setp` publish the exact literal-capture definition without synthesized
    metadata, and malformed recognized annotations still fail.
  - **Verify by** `cmd`: fixture `optional-module-annotations.ecl` registers
    public and private words in all four source forms, reflects body/doc/effect
    presence, calls one deliberately false supplied effect and one unannotated
    dynamic-effect word, and compares `set` with `literal` plus `def`.
  - **Expected**: all four source forms register and reflect exactly what was
    supplied; only the declared false effect raises `'contract`; malformed
    annotations are `'domain`; `set` and explicit literal definition have the
    same body and absent metadata.
  - **Traces to**: Milestone 11 — definition annotation validation/publication,
    module call-contract entry, reflection, and the simplified prelude
    `set`/`setp` definitions.

- **DoD-39 — dynamically constructed modules are independent state singletons**
  - **Assert**: two canonical module names registered from the same
    `with 'name @module` body own independent durable stacks initialized from their
    supplied construction values; module-homed `within` reaches only its
    definition-site slot. Dotted canonical names, unqualified aliases, and
    final-dot qualified resolution select the intended module without exposing
    slot identity.
  - **Verify by** `cmd`: fixture `stateful-module-instances.ecl` constructs two
    counter modules from one body quotation with different seed values, invokes
    exported `within`-backed operations by different amounts, reads both through
    `without`, exercises a dotted module through `qualify execute`, and repeats
    at 1 and 8 workers. A non-word passed to `execute` and a non-quotation passed
    to `within` are attempted.
  - **Expected**: both worker counts produce the same distinct final values;
    dotted dynamic execution reaches the expected word, both invalid operands
    are `'type`, and neither module can observe or mutate the other's stack.
  - **Traces to**: Milestone 11 — `with 'name @module`, branded module/qualified names,
    construction-stack publication, `qualify`/`execute`, and module-home
    `within` authority.

- **DoD-40 — explicit state transfers serialize and roll back**
  - **Assert**: concurrent module-homed `within` quotations are linearizable;
    caller values enter only through explicit quotation capture (exercised with
    both `partial` and `with`) and `without` is the only draft-to-caller
    transfer;
    ordinary module words still operate on the caller stack. An application
    that errors, is cancelled, exhausts allocation, underflows `without`,
    attempts to park, nests `within`, or enters another module's durable stack
    publishes neither draft nor pending outputs.
  - **Verify by** `cmd`: the production-connected stateful-module suite
    (`src/tests/stateful_module_test.zig`) spawns
    contending counter operations implemented as
    `(+ dup without) partial within`, exercises pool-style checkout as
    `(without) within` and checkin as `() partial within`, uses `with` for one
    multiple-input update, verifies a stateless module word against ambient
    caller values, and runs one case for each failed exit at 1 and 8 workers,
    under Linux/x86_64 TSan, and in the initialized-Session OOM sweep.
  - **Expected**: the final value equals exactly the successful increment
    count in every schedule; every failed path returns its documented error,
    leaves the preceding stack and caller output unchanged, outward values
    preserve invocation order, and there is no TSan report or leak.
  - **Traces to**: Milestone 11 — `within`, `without`, the scheduler-integrated
    per-slot arbiter, exact output-window reservation, and all-or-nothing stack
    publication.

- **DoD-41 — hot reload preserves module state**
  - **Assert**: re-registering a stateful canonical module atomically changes
    its exported behavior without replacing the durable stack with the new
    candidate body's construction stack; failed registration preserves both
    the prior generation and state.
  - **Verify by** `cmd`: fixture `stateful-module-reload.ecl` mutates a module,
    re-registers a body that proposes a different initial stack and implements
    different behavior over the retained layout, observes through both
    qualified and previously used access paths, then attempts one failing
    registration.
  - **Expected**: successful reload exposes the new code over the old durable
    stack, not the proposed replacement initializer; failed reload changes
    neither behavior nor state, and no call observes a mixed generation/state
    transition.
  - **Traces to**: Milestone 11 — the registry-slot stack/code-generation
    identity split and reload quiescence barrier.

- **DoD-42 — module removal closes admission and retires state owners**
  - **Assert**: `unmodule` prevents new calls, cooperatively quiesces active
    `within` drafts through arbiter order without waiting for generation pins,
    removes aliases, and transfers the detached stack and granted turn to
    cancellation-independent bounded retirement at the close edge; Session shutdown
    uses the same ordering. Every published generation and operation that can
    still name the slot owns a `SlotLease`; removal need not drain those pins,
    but retired storage is reusable only after every witness releases. Repeated
    construct/remove/name-reuse cycles do not retain memory proportional to
    history.
  - **Verify by** `cmd`: the production-connected lifecycle suite
    (`src/tests/stateful_module_test.zig`) races
    qualified calls and `within` applications with name-based `unmodule`, checks
    aliases after reusing the canonical name, holds old code across removal
    while an unrelated replacement is created and probes old `within`, cancels
    removal only after fresh dynamic resolution observes the close edge, repeats
    post-close cancellation/removal batches under a warmed counting allocator,
    exercises dynamic construction/removal, and runs the path
    under the Linux/x86_64 TSan gate.
  - **Expected**: pre-close calls finish with stable values, post-close calls
    fail with `'undefined-word`, old code never reaches the replacement slot,
    no alias reaches retired state, and settled memory is
    bounded by peak simultaneously live modules, stack values, drafts, outputs,
    and generation/operation slot leases rather than update or registration
    count.
  - **Traces to**: Milestone 11 — the opaque module-owner
    `live -> closing -> retired` lifecycle, registry removal, and bounded
    retirement integration.

- **DoD-43 — stdin as data**
  - **Assert**: `io.stdin` reads piped input as data in `-e` and script-file
    modes; in bare-stdin mode, where stdin is the program source, it
    raises `'io`.
  - **Verify by** `cmd`: `printf 'a\nb' | ecl -e 'io.stdin "\n" split len io.pp'`;
    and `echo 'io.stdin' | ecl` for the source-mode case.
  - **Expected**: `2` from the data path; the source-mode case errors
    `'io` naming stdin as the program source, without consuming further
    input.
  - **Traces to**: Milestone 12 — the stdin host scripting word (ruled
    2026-08-18, closing the former stdin-as-data open question).

- **DoD-44 — bitwise words are pattern operations**
  - **Assert**: `band bor bxor bnot bsl bsr` operate on the i64 bit
    pattern, pervasively, int-only; `bsl` truncates rather than erroring;
    shift counts outside 0..63 are `'domain` with the failing element's
    index; arithmetic overflow behavior elsewhere is unchanged.
  - **Verify by** `cmd`: promoted snapshot cases including
    `ecl -e '[1 2 3] 60 bsl'` (truncation visible), a `'domain` shift
    error dict with `'index`, `ecl -e '5 bnot bnot'` → `5`, and a `'type`
    case on a float operand.
  - **Expected**: outputs and error dicts match the regenerated snapshot;
    `zig build differential` covers the new ops' rows.
  - **Traces to**: the post-M12 standalone patch
    (`gameplans/bitwise-and-randomness.json`), kernel additions.

- **DoD-45 — randomness is deterministic values plus one capability**
  - **Assert**: identical generator states produce identical draws;
    `'rng use` works with no ECL_PATH; a seeded rng sequence is
    reproducible across runs; `entropy` raises `'io` without host
    authority and differs across real-binary runs.
  - **Verify by** `cmd`: promoted snapshot case for a seeded
    `rand-ints` vector and a seeded `rng` module sequence; e2e runs the
    binary twice asserting the seeded outputs are byte-identical and two
    `entropy` outputs differ.
  - **Expected**: seeded paths byte-identical (and identical at 1 and 8
    workers); the entropy pair differs; the in-process gate case errors
    `'io`.
  - **Traces to**: the post-M12 standalone patch
    (`gameplans/bitwise-and-randomness.json`), rand kernels, entropy
    capability, and the `rng` stateful module.

- **DoD-46 — unit constructors are spelled with `@`**
  - **Assert**: `@attempt @spawn @each @module` are the only first-party
    `@`-spelled words and the only unit constructors; the old spellings
    and every `-with` variant (`attempt-with`, `spawn-with`, `par-each-with`,
    `module-with`, and any `@…-with`) are `'undefined-word`; an
    underflow at a unit-constructor substack base carries the guided
    isolation message suggesting `with` seeding or `partial`;
    `[1 2] [10] (|x a| x a +) with @each`
    computes 11 and 12 per child (element deepest, values above),
    delivered in `@each`'s existing ordered-join result shape;
    `(body) 'name @module` registers name-last and the former
    name-first order is `'type`; `ecl fmt` synthesizes
    `### module <name>` headers for literal-named registrations exactly
    as `### def <name>`.
  - **Verify by** `cmd`: `zig build source-audit` (the spelling
    manifest); e2e cases for one old spelling raising `'undefined-word`
    and for `10 20 30 (+ +) @attempt` showing the guided error; the same e2e
    test runs `[1 2] [10] (|x a| x a +) with @each`; the snapshot corpus pins
    the exact guided error dict.
  - **Expected**: audit exit 0; the old-spelling and guided-error cases
    match; `(q) @attempt` and `(q) @spawn await` produce structurally
    identical results on a success and an error fixture.
  - **Traces to**: the third standalone patch
    (`gameplans/unit-word-spelling.json`) — renames, spelling manifest,
    and guided boundary error.

- **DoD-47 — the after-row annotation token**
  - **Assert**: `(a b -- ...)` annotations validate, store, and reflect;
    the boundary contract checks the before-slots and skips the
    post-check; a `...` anywhere but as the entire after portion is
    `'domain`; a native effect declaring `...` fails validation; `...`
    is reserved on namespace introduction and inert as a value;
    `result.either` reflects a partial effect instead of doc-only.
  - **Verify by** `cmd`: e2e cases define a module word with a `-- ...`
    effect and call it across the module boundary with wrong and right input
    arities; `(1) '... def` proves reservation while `'...` remains inert;
    the native `partial_effect` compile-negative fixture rejects the row; and
    `'result use 'result.either see` shows the sanctioned reflected form.
  - **Expected**: wrong input arity is a `'contract` error naming the
    declared before-slots; variable outputs pass; malformed placements
    are `'domain`; the native fixture is rejected at validation; `see`
    round-trips `-- ...` re-readably.
  - **Traces to**: the third standalone patch
    (`gameplans/unit-word-spelling.json`) — annotation grammar,
    EffectCheck, reflection, and reservation.

- **DoD-48 — the result module owns the envelope vocabulary**
  - **Assert**: bare `ok?`/`or-raise`/`or-else` are `'undefined-word`;
    `result.ok?`, `result.or-raise`, `result.or-else`, `result.map-err`,
    and `result.either` resolve via bare qualified reference with no
    ECL_PATH; every `result.*` word rejects a malformed dict as a
    malformed result before other work; `result.or-raise` re-raises the
    captured error dict unchanged; `result.map-error` and `result.case`
    do not exist; `raise`/`fail`/`assert` remain core.
  - **Verify by** `cmd`: the conformed `test/acceptance/result.ecl`
    fixture plus e2e cases for every old bare spelling, both removed qualified
    spellings, one malformed-dict rejection, and one `result.or-raise` re-raise
    whose error dict matches the originally captured one byte-for-byte.
  - **Expected**: old spellings error `'undefined-word`; the re-raised
    dict is structurally identical to the captured one; malformed input
    is rejected without running any supplied quotation.
  - **Traces to**: the fourth standalone patch
    (`gameplans/result-consolidation.json`) — the move, the `checked`
    routing, and the `map-err`/`either` renames.
