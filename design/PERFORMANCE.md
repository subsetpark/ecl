# Performance baselines

Performance claims in this repository are release-mode, target-specific
characterizations through public runtime surfaces. They are not portable
constants. Regenerate a baseline on the target under discussion rather than
copying timings from this file.

## Further compile-time trials — 2026-09-11

These incremental trials start at `5922754`, using the same Zig 0.16.0,
ReleaseSafe, native x86_64 Linux host and CLI-only fresh-local-cache build
procedure described below. Each row is one isolated build with LLVM IR emission;
individual timing differences are exploratory, not repeated speedup estimates.
The baseline's isolated build was 256.6 seconds with 159.19 MiB of IR.

| Change | Build, seconds | Unoptimized IR, MiB |
|---|---:|---:|
| Shared validated builtin installation | 246.0 | 155.89 |
| Shared unary and sequential reduction preparation | 243.8 | 154.16 |
| Shared cold scalar fault replay | 237.7 | 148.47 |

The builtin installer preserves static declaration validation and runtime
installation/allocation order. Effect builders specialize by token count instead
of authored spelling. Environment object-function code falls from 107,474 to
26,285 bytes. In 31 alternating before/after ReleaseSafe CLI processes executing
`1 2 +`, with `ECL_WORKERS=1` and no concurrent build/test workload, whole-process
p50 was 33.42/32.96 ms and p95 was 36.33/35.29 ms. This includes startup and
teardown; it does not establish a runtime speedup.

Shared unary/reduction plans reduce numeric-kernel object-function code from
952,822 to 857,853 bytes without changing the element loops. The same
31-alternating-pair method, timing warmed batches inside the CLI, gives these
before/after p50 milliseconds: small unary 113/115, large unary 153/153,
small fold 97/97, large fold 119/120, and large scan 25/25. Small batches execute
20,000 iterations over `[1 2 3]`; large unary/fold batches execute 20 iterations
over a retained million-element integer range, and scan uses 100,000 elements.
Unary uses `neg`; fold and scan use seed `0` and quotation `(+)`. Corresponding
p95 pairs are 135/136, 170/173, 108/110, 140/143, and 32/34 ms.

Shared fault replay removes 873 numeric-kernel IR definitions (3,548 to 2,675).
Numeric-kernel machine code increases by 22,058 bytes, so the improvement is in
the input to LLVM rather than final code size. The 31-pair warmed-batch method
gives small numeric addition p50 79/79 ms and p95 89/87 ms, and character offset
p50 94/96 ms and p95 106/110 ms. Each batch performs 20,000 iterations of
`[1 2 3] 1 + pop` or `"aλ🙂" 1 + pop`, respectively. A public regression test
covers fault kind and first index when unique-buffer reuse changes integer and
float representation; a deliberately wrong index was confirmed to fail the
77-test kernel slice before restoration.

A separate build-only cache-splitting experiment compiled the existing runtime
aggregation module as a static library. Its 2,710-byte archive contained no
text symbols: public Zig declarations remain source imports, not independently
linked definitions. That shortcut was rejected. Reusable runtime machine code
would require an explicit external boundary; merely adding another build module
or library does not provide it.

## Binary kernel specialization — 2026-09-11

Compared `ebaa07d` with shared binary-kernel preparation and compile-time
exclusion of unreachable character and scalar-storage combinations. Both
variants use Zig 0.16.0, ReleaseSafe, native x86_64 Linux on an Intel Core Ultra
5 125U with 16 GiB RAM. The host's energy preference remained `power`.

Each variant builds from a separate source snapshot and a fresh local Zig
cache, sharing an already populated global dependency/toolchain cache. The
measured artifact is the CLI executable, without tests or native fixtures.
IR emission is enabled identically for both variants:

```sh
timeout 1200 zig build -Doptimize=ReleaseSafe --summary all \
  --cache-dir /tmp/ecl-compile-cache --prefix /tmp/ecl-compile-out \
  --verbose-llvm-ir=/tmp/ecl-compile.ll < /dev/null > /tmp/ecl-compile.log 2>&1
build_status=$?
printf 'build_exit=%s\n' "$build_status"
```

Use distinct empty cache and output directories for each variant and repeat;
an unchanged build against its existing cache measures cache validation instead
of compilation. This is a warm-dependency rebuild measurement, not a completely
cold installation of Zig and the project's dependencies.

### Compilation time

Both variants completed two fresh-local-cache builds. The first pass overlapped
local verification; its approximate elapsed times come from log creation and
final-write timestamps at one-second resolution. The repeat ran the two builds
serially with no other build, test, or benchmark process active, measured by a
monotonic clock around each complete `zig build` invocation. Both passes include
the identical IR-emission option, build-runner work, and installation.

| Pass | Before, seconds | After, seconds |
|---|---:|---:|
| Initial diagnostic, concurrent verification | ~329 | ~295 |
| Isolated repeat | 330.3 | 256.6 |

The isolated repeat removes 73.7 seconds, or 22.3% of build time. These are two
observations per variant, not a portable compile-time guarantee; the explicit
isolation makes the second pair the useful comparison. LLVM compilation still
takes several minutes on this host.

### Emitted size

The IR numbers include debug metadata and precede LLVM optimization. Function
counts are emitted definitions, including generated helpers. Object code bytes
sum text-symbol sizes reported by `nm -S`; they exclude debug information.

| Measurement | Before | After |
|---|---:|---:|
| Unoptimized LLVM IR, MiB | 220.92 | 159.19 |
| Numeric-kernel IR definitions | 8,798 | 3,578 |
| Shared flat-kernel IR definitions | 1,934 | 689 |
| Numeric-kernel emitted functions | 2,336 | 1,190 |
| Numeric-kernel object code, bytes | 2,478,037 | 970,549 |
| Total object function code, bytes | 5,973,607 | 4,464,543 |
| CLI executable, MiB | 32.46 | 26.28 |

The reachable arithmetic loops retain their specialized element types and
operation bodies. Shared preparation removes repeated allocation and ownership
setup, while selection avoids generating loops for unsupported character
operations and storage classes that a scalar cannot have.

### Runtime comparison

Each workload has 31 before/after pairs with alternating execution order,
`ECL_WORKERS=1`, and ReleaseSafe CLI binaries. No build or test process ran
during this comparison. Each sample starts a fresh CLI process, loads `clock`,
performs its setup and three warmup iterations, then uses `clock.now` and
`clock.elapsed` around the measured batch. Session startup and input setup are
excluded. Times are whole milliseconds for a batch, not per-element times.
For the large cases, setup binds `1000000 range` to `x`; retaining that binding
exercises fresh output allocation rather than unique-input reuse.

| Workload | Iterations | Before p50 | After p50 | Before p95 | After p95 |
|---|---:|---:|---:|---:|---:|
| `[1 2 3] 1 + pop` | 20,000 | 79 | 78 | 87 | 87 |
| `x 1 + pop` | 20 | 140 | 139 | 153 | 148 |
| `1 x + pop` | 20 | 140 | 140 | 148 | 154 |
| `x x + pop` | 20 | 146 | 142 | 174 | 153 |
| `"aλ🙂" 1 + pop` | 20,000 | 94 | 94 | 103 | 103 |
| `[[1 2] [3]] 1 + pop` | 10,000 | 1,399 | 1,400 | 1,443 | 1,449 |

Medians remain within 2.8%; the tails vary in both directions. No consistent
runtime regression was observed. The 76-test kernel slice also passes in Debug
and ReleaseSafe,
including differential representation checks, fault indices, aliased output,
bounded work, and typed-write allocation failures. New public character cases
cover width combinations, both scalar broadcasts, and byte-subtraction
fallback; a deliberately incorrect expected value was confirmed to fail the
selected test before restoration.

## WorkDriver baseline — 2026-08-28

This baseline was recorded by the WorkDriver harness added on top of `f63f189`, using
Zig 0.16.0 on macOS arm64 (Apple M4 Max, 16 logical CPUs, 128 GiB). The full
run uses 101 timing repetitions at sizes 1, 32, 1,024, 65,535, 65,536, 65,537,
and 1,048,576 with one and eight workers. The mixed workload queues two long
flat sums ahead of a short task; the cancellation workload cancels and awaits
an already running infinite task.

Reproduce both the timing and counter passes with:

```sh
timeout 500 zig build bench-workdrivers -Doptimize=ReleaseSafe < /dev/null
timeout 500 zig build bench-workdrivers -Doptimize=ReleaseFast < /dev/null
```

`-- --quick` selects reduced size sets with three repetitions. It is a smoke
gate and is not performance evidence. `-- --cursor-storage-only` selects the
focused first-frame cursor workload, `-- --nested-cursor-only` selects the
structural shared-budget workload, `-- --materializer-budget-only` selects the
result-materialization shared-budget workload, `-- --call-site-only` selects
the repeated qualified-call workload, `-- --local-call-site-only` selects the
module-local hit and core-fallback workloads, and `-- --latency-only` selects
the mixed short-task and cancellation safeguards. Without `--quick`, each
retains the full 101 repetitions.

### Selected timing results

All values below are wall-clock microseconds. The complete command output is
versioned CSV: the uninstrumented timing pass reports polls, CPU p50/p95, and
wall p50/p95/p99, while the counter pass reports allocation count, peak
temporary bytes, and root-Unit execution counters. Values are untrimmed; the
ReleaseFast task/cancellation tails below include host-scheduling outliers and
must be reproduced before attributing them to a runtime change.

| Mode | Case | Workers | Size | p50 | p95 | p99 |
|---|---|---:|---:|---:|---:|---:|
| ReleaseSafe | flat × scalar | 1 | 65,536 | 103.5 | 113.2 | 119.7 |
| ReleaseSafe | flat × scalar | 1 | 1,048,576 | 1,146.8 | 1,306.0 | 1,455.5 |
| ReleaseSafe | range materialize | 1 | 1,048,576 | 1,076.9 | 1,148.5 | 1,204.3 |
| ReleaseSafe | mixed short latency | 1 | 5,000,000 | 641.3 | 1,081.0 | 2,064.5 |
| ReleaseSafe | mixed short latency | 8 | 5,000,000 | 164.9 | 201.4 | 215.5 |
| ReleaseSafe | cancellation latency | 1 | — | 38.8 | 46.7 | 47.6 |
| ReleaseSafe | cancellation latency | 8 | — | 139.6 | 230.5 | 266.7 |
| ReleaseFast | flat × scalar | 1 | 65,536 | 84.6 | 95.8 | 97.3 |
| ReleaseFast | flat × scalar | 1 | 1,048,576 | 933.8 | 1,020.5 | 1,047.6 |
| ReleaseFast | range materialize | 1 | 1,048,576 | 819.0 | 1,274.8 | 3,192.5 |
| ReleaseFast | mixed short latency | 1 | 5,000,000 | 186.8 | 4,132.9 | 10,337.8 |
| ReleaseFast | mixed short latency | 8 | 5,000,000 | 206.0 | 281.5 | 348.8 |
| ReleaseFast | cancellation latency | 1 | — | 41.3 | 48.0 | 50.5 |
| ReleaseFast | cancellation latency | 8 | — | 131.0 | 208.3 | 260.1 |

### Deterministic counters and disposition

Both scaling cases make 27 measured allocation/remap requests independent of
size. `flat × scalar` takes four driver resumes through 65,536 elements, five
at 65,537, and 34 at 1,048,576. `range materialize` takes one additional
resume. Neither case hands back to the scheduler below 65,537; both record one
handoff at 65,537 and 30 at 1,048,576. Counts are identical at one and eight
workers and in ReleaseSafe and ReleaseFast.

The baseline therefore does not justify changing queue topology or the
scheduler quantum: non-task throughput is insensitive to worker count, and the
mixed/cancellation results do not show a uniform eight-worker improvement. It
instead selected the separately identified first-frame `ChunkStack` allocation
as the first bounded intervention, recorded below.

## Inline-first `ChunkStack` A/B — 2026-08-28

The first bounded intervention compared the original heap-first `ChunkStack`
with a treatment holding exactly one entry inline. Both variants were compiled
from the same source behind a temporary build-time switch; the switch was
removed after acceptance so production retains no dormant container path. The
focused public workload applies scalar membership over a generic spine once per
input element. It changes neither root polls nor logical transition counts, so
the result isolates cursor storage rather than a different execution path.

ReleaseSafe results below are 101 repetitions on macOS arm64 (Apple M4 Max),
Zig 0.16.0. Times are wall-clock milliseconds.

| Workers | Operations | Control p50 | Inline p50 | Reduction | Control allocations | Inline allocations |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 32 | 0.234 | 0.083 | 64.3% | 96 | 64 |
| 1 | 1,024 | 5.176 | 0.860 | 83.4% | 1,088 | 64 |
| 1 | 65,536 | 326.186 | 50.824 | 84.4% | 65,600 | 64 |
| 8 | 32 | 0.236 | 0.082 | 65.1% | 96 | 64 |
| 8 | 1,024 | 5.161 | 0.854 | 83.5% | 1,088 | 64 |
| 8 | 65,536 | 330.830 | 50.686 | 84.7% | 65,600 | 64 |

The allocation delta is exactly one per operation at every measured size while
polls, driver resumes, application resumes, and scheduler handoffs are
identical. The treatment therefore clears both gates: it removes the attributed
allocation rather than moving it, and produces a large repeated release-mode
improvement on the affected path. The general throughput cases remain at their
27-allocation fixed baseline because they do not construct this cursor; the
focused case remains in the versioned WorkDriver schema to keep that
distinction observable.

## Nested-cursor budget A/B — 2026-08-28

The second intervention tested the conservative boundary between generic-spine
membership and structural equality. The control handed `MatchCursor` an integer
remaining count and returned to the scheduler whenever the child completed,
because the parent could not know the exact consumption. The treatment passes
one `WorkBudget` through both cursors, allowing the parent to continue only
while that same bounded allowance remains. Both variants were compiled from
one temporary build-time switch, removed after acceptance.

The focused public workload searches a generic spine of structurally compared
dictionaries and deliberately misses so every candidate crosses the nested
cursor boundary. ReleaseSafe timings below are 101 repetitions on macOS arm64
(Apple M4 Max), Zig 0.16.0; times are wall-clock milliseconds.

| Workers | Candidates | Control p50 | Shared-budget p50 | Reduction | Control resumes | Shared-budget resumes | Control handoffs | Shared-budget handoffs |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 32 | 0.036 | 0.033 | 9.0% | 36 | 4 | 32 | 0 |
| 1 | 1,024 | 0.224 | 0.122 | 45.7% | 1,028 | 4 | 1,024 | 0 |
| 1 | 65,536 | 12.803 | 5.946 | 53.6% | 65,540 | 13 | 65,536 | 9 |
| 8 | 32 | 0.034 | 0.032 | 6.0% | 36 | 4 | 32 | 0 |
| 8 | 1,024 | 0.228 | 0.122 | 46.4% | 1,028 | 4 | 1,024 | 0 |
| 8 | 65,536 | 13.339 | 5.946 | 55.4% | 65,540 | 13 | 65,536 | 9 |

Allocation count (38), peak temporary bytes (82,280), logical dispatch (3),
and application resumes (0) are identical. At 65,536 candidates the treatment
still makes nine scheduler handoffs, proving the throughput change did not turn
the traversal into one unbounded slice. Two reversed-order 101-repetition
latency comparisons left the unrelated mixed short-task and cancellation
p50/p95 results within 3.1%, with identical deterministic counters; a first
eight-worker tail was not reproducible. The treatment therefore clears the
throughput and hard-progress gates without motivating a scheduler or quantum
change. The focused workload and the optional `--latency-only` selection remain
in schema `ecl.workdrivers.*.v6`.

## Membership materializer budget A/B — 2026-08-28

The third intervention tested the remaining conservative boundary inside
generic-spine membership. The control handed `ValueMaterializer` an integer
remaining count and returned to the scheduler even when a small result
materializer completed early. The treatment adds the same `advanceWithBudget`
composition used by structural matching, so result profiling and writes draw
from the parent's exact allowance and the parent continues only while that
allowance remains. Both variants were compiled from one temporary build-time
switch, removed after acceptance.

The focused public workload applies membership to a generic spine of singleton
lists against a scalar collection. Every singleton creates a small nested
result materializer, while scalar comparison avoids the structural
`MatchCursor` measured by the preceding A/B. ReleaseSafe timings below are 101
repetitions on macOS arm64 (Apple M4 Max), Zig 0.16.0; times are wall-clock
milliseconds.

| Workers | Results | Control p50 | Shared-budget p50 | Reduction | Control resumes | Shared-budget resumes | Control handoffs | Shared-budget handoffs |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 32 | 0.051 | 0.046 | 9.1% | 40 | 7 | 33 | 0 |
| 1 | 1,024 | 0.418 | 0.324 | 22.6% | 1,032 | 7 | 1,025 | 0 |
| 1 | 65,536 | 24.985 | 20.554 | 17.7% | 65,545 | 18 | 65,538 | 11 |
| 8 | 32 | 0.048 | 0.045 | 5.6% | 40 | 7 | 33 | 0 |
| 8 | 1,024 | 0.414 | 0.323 | 22.0% | 1,032 | 7 | 1,025 | 0 |
| 8 | 65,536 | 25.316 | 20.612 | 18.6% | 65,545 | 18 | 65,538 | 11 |

Allocation counts are identical at every size. Peak bytes rise within a single
quantum because releases are drained at its end (for example 220,107 to
317,427 bytes at 1,024 results), but both variants converge at 6,155,211 bytes
by 65,536 results and the treatment still makes eleven scheduler handoffs.
A reversed-order 101-repetition comparison reproduced the 65,536-result p50
improvement at 19.5% with one worker and 18.6% with eight. The unrelated mixed
short-task and cancellation latency safeguard showed no treatment regression,
with identical polls, logical transitions, driver resumes, application
resumes, and scheduler handoffs. The accepted path therefore retains one
shared-budget implementation with no experimental or legacy control branch;
the focused workload remains in schema `ecl.workdrivers.*.v6`.

## Generation-guarded qualified call-site cache A/B — 2026-08-28

The fourth intervention tested repeated qualified dispatch from one source call
site. The control performed the complete module-prefix, registry-generation,
and export lookup on every call. The treatment gives each Unit a fixed
16-entry, allocation-free lookaside keyed by owned code root, instruction
index, and word id. An entry owns a generation guard and stable binding cell;
every hit first proves that exact generation is still current and then reloads
the cell's current snapshot. Alias-qualified calls bypass the cache because an
alias may be retargeted independently. Both variants were compiled from one
temporary build-time switch, removed after acceptance.

The focused public workload repeatedly executes one canonical qualified word
from one quotation. ReleaseSafe timings below are 101 repetitions on macOS
arm64 (Apple M4 Max), Zig 0.16.0; times are wall-clock milliseconds.

| Workers | Calls | Control p50 | Guarded-cache p50 | Reduction | Control resumes | Guarded-cache resumes | Hits / misses |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 32 | 0.087 | 0.069 | 20.2% | 66 | 35 | 31 / 1 |
| 1 | 1,024 | 1.161 | 0.554 | 52.3% | 2,050 | 1,027 | 1,023 / 1 |
| 1 | 65,536 | 71.372 | 32.391 | 54.6% | 131,074 | 65,539 | 65,535 / 1 |
| 8 | 32 | 0.088 | 0.069 | 21.6% | 66 | 35 | 31 / 1 |
| 8 | 1,024 | 1.136 | 0.551 | 51.5% | 2,050 | 1,027 | 1,023 / 1 |
| 8 | 65,536 | 71.794 | 32.678 | 54.5% | 131,074 | 65,539 | 65,535 / 1 |

The one-call cold case was unchanged in the first comparison and within 1.8%
in the reversed comparison. The reversed 101-repetition run reproduced the
65,536-call result at 54.5% with one worker and 55.1% with eight. Allocation
count (33), peak temporary bytes (83,081), logical transitions (196,611),
application resumes (65,536), and scheduler handoffs (65,728) are identical;
the cache removes exactly one driver resume and poll per hit. The unrelated
mixed short-task and cancellation medians showed no treatment regression.

Public behavior counterfactuals reuse a call site across canonical reload,
alias retarget, and module removal. They prove that reload observes the new
generation, aliases remain late-bound, and removal heals to `undefined-word`
rather than executing a retained generation. Fixed capacity bounds retained
code, generations, and cells per Unit; collisions affect performance only.
The accepted path retains no experimental or legacy control branch, while the
focused workload and hit/miss/heal counters remain in schema
`ecl.workdrivers.*.v6`.

## Same-image module-local call-site cache A/B — 2026-08-28

The fifth intervention tested a plain word whose stamped scope is exactly the
module root the running activation already owns. The control retained the
canonical-qualified cache but drove the module environment's generic direct
lookup on every local call. The treatment stores that direct lookup's stable
binding cell in the same fixed 16-entry per-Unit cache. It also arranges those
entries as eight two-way sets: an initial direct-mapped treatment showed one
timing repetition where the caller's qualified site and callee's local site
continually evicted each other. Two ways removed that collision without raising
the entry bound.

A local hit requires one nominal context carrying the exact non-recycled scope
id and current activation home. The factory produces it only when the word's
stamp equals the running resolution scope and that scope is a module root. The
activation is therefore the image-liveness proof; child scopes and escaped
foreign quotations bypass the cache. The entry stores no home, environment, or
binding payload and reloads its cell on every hit.

ReleaseSafe timings below are 101 repetitions on macOS arm64 (Apple M4 Max),
Zig 0.16.0; times are wall-clock milliseconds.

| Workers | Calls | Control p50 | Local-cache p50 | Reduction | Control resumes | Local-cache resumes | Hits / misses |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1,024 | 0.747 | 0.598 | 19.9% | 2,051 | 1,028 | 1,023 / 1 |
| 1 | 65,536 | 44.527 | 35.126 | 21.1% | 131,075 | 65,540 | 65,535 / 1 |
| 8 | 1,024 | 0.745 | 0.601 | 19.3% | 2,051 | 1,028 | 1,023 / 1 |
| 8 | 65,536 | 44.815 | 35.044 | 21.8% | 131,075 | 65,540 | 65,535 / 1 |

The reversed focused run reproduced 22.3% with one worker and 21.3% with
eight. Allocation count (33), peak temporary bytes (83,089), logical
transitions (262,147), application resumes (65,536), and scheduler handoffs
(65,792) are identical; the cache removes exactly one driver resume and poll
per warm local hit. The one-call cold case stayed within 0.7%.

A second focused case repeatedly resolves core `+` from a module body, so every
local probe misses. At 65,536 calls its medians moved 47.521 to 47.558 ms with
one worker and 48.030 to 47.788 ms with eight, demonstrating no material miss
tax. Reversed qualified-cache and unrelated latency safeguards changed
direction across orderings while retaining identical deterministic counters.

The public counterfactual warms a private local state call, escapes the exact
quotation, and invokes it from another module. It still receives the ordinary
registration-less foreign-home domain error rather than authority over the
caller. Existing double-registration behavior also continues deriving state
authority from the registration used for each invocation. The accepted path
retains one two-way cache implementation with no experimental or legacy
control branch; the two focused cases and local hit/miss counters remain in
schema `ecl.workdrivers.*.v6`.

## CSV and table primitives — 2026-09-10

Baseline is the committed columnar implementation `05454f6`; updated is the
ABI 7 implementation with forward construction, cached CSV conversions,
shared hash grouping, and whole-key dictionary batches. Both executables use
Zig 0.16.0 ReleaseSafe on macOS 26.6.2 arm64, with `ECL_WORKERS=1`.
Each workload has one warmup and three measured runs. Values below are medians;
peak memory is the median process maximum RSS from `/usr/bin/time -l`, including
input, output, and runtime memory. Stage clocks have millisecond resolution.
Baseline and updated use identical fixed input files, verified by SHA-256.

The final benchmark exited 0. Completed baseline runs were
retained while updated runs were repeated after compacting CSV descriptors;
failed benchmark setup runs are excluded. No builds or tests ran concurrently
with measured workloads.

### CSV stages

All times are milliseconds, rates are input MiB/s during parsing, and memory
is MiB. Each cell shows **baseline → updated**. `bytes` uses `fs.read-bytes`;
`text` uses `fs.read-text`. Parsing uses automatic inference and headers, then
`dict.from-lists table.from-columns` constructs the table. File reading and
UTF-8 decoding are included in the read stage, separately from parsing.

| Workload | Input | Read ms | Parse ms | Table ms | Parse MiB/s | Peak MiB |
|---|---|---:|---:|---:|---:|---:|
| all_bands_discography | bytes | 6 → 7 | 1376 → 899 | 21 → 13 | 19.3 → 29.5 | 432.6 → 499.4 |
| all_bands_discography | text | 306 → 307 | 1526 → 936 | 22 → 14 | 17.4 → 28.3 | 528.6 → 595.4 |
| complete_roster | bytes | 24 → 22 | 3063 → 1783 | 24 → 20 | 23.6 → 40.6 | 826.9 → 915.8 |
| complete_roster | text | 853 → 842 | 3801 → 2224 | 28 → 26 | 19.1 → 32.6 | 1210.9 → 1299.8 |
| escaped | bytes | 3 → 3 | 316 → 188 | 6 → 6 | 31.1 → 52.2 | 74.4 → 79.9 |
| labels_roster | bytes | 5 → 5 | 795 → 512 | 14 → 10 | 20.9 → 32.5 | 254.3 → 287.0 |
| labels_roster | text | 197 → 192 | 865 → 528 | 13 → 10 | 19.2 → 31.5 | 286.4 → 319.0 |
| late-mismatch | bytes | 0 → 0 | 90 → 60 | 6 → 6 | 19.8 → 29.7 | 30.3 → 35.4 |
| metal_bands | bytes | 7 → 7 | 1061 → 602 | 11 → 9 | 27.5 → 48.5 | 230.8 → 252.0 |
| metal_bands | text | 338 → 334 | 1428 → 674 | 12 → 11 | 20.5 → 43.4 | 326.9 → 348.1 |
| metal_bands_roster | bytes | 8 → 8 | 1184 → 676 | 12 → 10 | 26.5 → 46.4 | 264.9 → 290.6 |
| metal_bands_roster | text | 357 → 361 | 1503 → 764 | 14 → 11 | 20.9 → 41.0 | 360.9 → 386.6 |
| numeric | bytes | 1 → 1 | 281 → 172 | 9 → 8 | 20.2 → 33.1 | 52.9 → 65.7 |

The five real workloads are the metal datasets named above. The synthetic
numeric workload has 100,000 rows and eight columns; escaped has 100,000 rows
and three columns with quotes, Unicode, and embedded newlines; late-mismatch
has 100,000 rows and three columns ending in a spelling-preserving text fallback.

### Grouping, joins, and reduction

Setup constructs the input before the measured operation. Rates are rows/s;
all pairs again show baseline → updated. Composite baseline is `flip group`;
updated is `group-columns`. Aggregation compares gathered `(sum)` / `(len)`
quotations with fixed `'sum` / `'count` reducers on the same data.

| Workload | Rows | Setup ms | Operation ms | Rows/s | Peak MiB |
|---|---:|---:|---:|---:|---:|
| group-low | 100,000 | 0 → 0 | 3 → 4 | 33333333 → 25000000 | 15.9 → 17.0 |
| group-low-large | 1,000,000 | 2 → 2 | 26 → 41 | 38461538 → 24390244 | 112.1 → 120.5 |
| group-high | 20,000 | 0 → 0 | 512 → 17 | 39062 → 1176471 | 10.3 → 10.7 |
| composite-low | 50,000 | 0 → 0 | 3625 → 4 | 13793 → 12500000 | 16.8 → 12.2 |
| composite-high | 3,000 | 0 → 0 | 2509 → 3 | 1196 → 1000000 | 6.0 → 6.0 |
| join | 3,000 | 0 → 0 | 2570 → 25 | 1167 → 120000 | 8.7 → 9.4 |
| aggregate | 100,000 | 0 → 0 | 44 → 19 | 2272727 → 5263158 | 22.2 → 20.1 |

Low-cardinality scalar grouping repeats eight integer keys; high-cardinality
uses distinct integers. Composite-low combines row indices modulo 32 and 7
(224 groups); composite-high repeats the distinct row index in two columns.
Join matches 3,000 distinct keys, with two columns on each side. Aggregation
has 100 groups and computes sum and count over 100,000 values.

### Regressions and limits

Real CSV parsing improves approximately 1.5–2.1× in this run. CSV memory remains
higher: preserving original spans and cached numeric bits adds staging storage,
and staged chains remain transaction-owned during output construction. The
first measured implementation used seven words per descriptor. Packing scalar
metadata reduces this to five without narrowing offsets, lengths, or numeric
bits; the final table includes that reduction. Numeric synthetic peak RSS is
52.9 → 65.7 MiB, and real byte-input increases range from about 9% to 15%.
This is an explicit memory-for-repeated-conversion tradeoff, not a memory win.

The eight-key scalar workload regresses from 3 to 4 ms. Increasing it tenfold
confirms a repeatable regression, 26 → 41 ms, rather than only clock rounding.
The shared hash path replaces short typed linear searches with per-row hashing
and a row-sized index initialization; it removes quadratic discovery cost but
has higher overhead at very low cardinality. High-cardinality, composite,
join, and aggregate workloads improve. Very small timings and unusually large
speedup ratios should not be treated as portable constants.

### Verification

The final `zig build precommit test-ecl test-native-acceptance test-snapshots
-Doptimize=ReleaseSafe -j4` run exited 0. Focused cancellation/session-reuse tests
for the column primitives exited 0. Initialized-Session allocation-failure
sweeps for CSV, dictionary operations, tables, and column primitives exited 0;
the CSV sweep was repeated after descriptor compaction. Commands used closed
stdin and bounded timeouts.

The independent Python CSV oracle compared every one of 13,644,293 real data
fields, headers, and inferred column types, plus generated text and numeric
cases; the final binary passed (exit 0). Public tests cover whole string and
composite dictionary keys, defaults, duplicates, assignment ordering, malformed
selectors, reducers, and mixed quotation/symbol aggregates. Standalone SDK
fixtures cover staging direction and sealing, budget retries, initialized
prefixes, chunk boundaries, UTF-8, and partial text construction. Deliberately
incorrect grouped-reduction and SDK assertions each failed their intended
selected test before being restored.

## Shared string identity and length-map idiom — 2026-09-10

This comparison isolates the changes in `cc41a0d` against `18be833`: shared string
hash/equality traversal over typed character buffers, and guarded recognition
of `(len) each` on list inputs. Both executables are Zig 0.16.0 ReleaseSafe on
macOS 26.6.2 arm64 with `ECL_WORKERS=1`. Each version has one warmup and three
measured runs on the same files; the table reports median milliseconds.

The inputs are `metal_bands.csv` (183,397 rows) and
`all_bands_discography.csv` (636,801 rows). Parsing happens before table timers.
The Band ID join returns 638,937 rows and 12 columns in both versions. Stage
measurements use public operations matching the table implementation and
retain intermediate values; their sum need not equal the full join, which
includes validation and has different temporary lifetimes. Millisecond clocks
limit precision for short stages.

| Operation | Before | After |
|---|---:|---:|
| country grouping | 256 | 26 |
| composite grouping | 538 | 44 |
| symbol aggregate | 258 | 31 |
| quotation aggregate | 278 | 43 |
| join left grouping | 173 | 176 |
| join right grouping | 203 | 203 |
| join distinct lookup | 160 | 158 |
| join group lengths | 160 | 1 |
| join match lengths | 134 | 1 |
| join left gather | 217 | 217 |
| join right gather | 152 | 151 |
| whole join | 1336 | 1036 |

Country grouping improves about 9.8× and country/status composite grouping
about 12.2×. The two interpreted length passes fall from 294 ms combined to
about 2 ms; the complete join improves from 1,336 to 1,036 ms (about 22% less
time). Numeric join grouping and output gathering remain essentially unchanged.
String grouping and map dispatch were the intended targets of these changes;
this comparison does not attribute any improvement to CSV parsing itself.

The optimized string cursors keep the generic per-codepoint hash semantics
across character widths and generic character lists. Charged ranges contain
at most 256 characters. The idiom checks the trusted built-in binding on each
application, retains generic execution for dictionary inputs, and preserves
errors for non-list elements.

Each measurement process exited 0; no builds or tests ran alongside the
measurements. This document retains the methodology, rationale, and results;
transient benchmark artifacts are not maintained in the repository.

Verification passed with `zig build precommit differential test-ports
-Dport-test-filter="native: column primitives" -Doptimize=ReleaseSafe -j4`
(exit 0), plus the table language tests and the initialized-Session column
primitive allocation-failure sweep (exit 0). Deliberately incorrect string-hash
and idiom-hit assertions failed their intended selected suites and were restored.
Cancellation tests cover active string hashing, mixed-width string comparison,
and the recognized length map, followed by Session reuse. The complete grouped
aggregate and 144,226,682-byte serialized join result have identical SHA-256
hashes before and after.

### Boolean reductions, generic gathers, and join keys — 2026-09-10

Compared against `cc41a0d`, using Zig 0.16.0 ReleaseSafe on macOS 26.6.2
arm64 with `ECL_WORKERS=1`. The fixed inputs remain `metal_bands.csv`
(183,397 rows, seven columns) and `all_bands_discography.csv` (636,801 rows,
six columns). Each workload used one warmup process and three measured
processes. No builds or tests ran alongside timing measurements; every
measurement process exited 0. Parsing precedes the stage timers.

A standalone join, without the stage experiment's retained intermediate
structures, produces 638,937 rows and twelve columns:

| Standalone join | Before | After |
|---|---:|---:|
| Median join time | 661 ms | 241 ms |
| Output throughput | 0.97 million rows/s | 2.65 million rows/s |
| Median process peak RSS | 1,009 MiB | 801 MiB |

The join is about 2.74× faster with 21% lower peak RSS. Measured times were
658/661/662 ms before and 241/241/242 ms after. RSS comes from `/usr/bin/time
-l` and includes CSV loading, the retained result, and process teardown;
the join timer excludes CSV loading and final teardown. These times are not
directly interchangeable with the earlier retained-intermediate stage runs.

Repeating the previous hotspot stage script gives these medians:

| Stage | Before (ms) | After (ms) |
|---|---:|---:|
| Composite numeric left grouping | 166 | 81 |
| Composite numeric right grouping | 206 | 99 |
| Composite numeric dictionary lookup | 158 | 20 |
| Individual generic/text output column gather | 35–37 | 4–6 |
| Individual numeric output column gather | 0–1 | 1 |
| Standalone boolean mask fold | 695 | <1 |
| Filter gather | 32 | 4 |
| Complete `table.where` | 534 | 14 |
| Country grouping | 32 | 20 |
| Country/status grouping | 54 | 38 |

The composite-key rows deliberately retain the old key shape to exercise
shared cursor improvements. Production single-column joins now use scalar
keys. Filtering selects even Band IDs. Sub-millisecond stage values are
below the timer's resolution; stage times are not additive because intermediate
lifetimes differ. The retained-intermediate whole-join samples were more
variable, so the standalone join above is the primary end-to-end comparison.

Recognized reductions over eight million elements, with ten reductions per
measurement batch, use the same typed loop for `fold` and `fold1`:

| Reducer | `fold` median per reduction | `fold1` median per reduction |
|---|---:|---:|
| `and`, alternating 0/1 bytes | 6.7 ms | 5.8 ms |
| `or`, alternating 0/1 bytes | 8.5 ms | 6.9 ms |
| `+`, integer range | 18.2 ms | 18.2 ms |

`fold1` does not copy the input tail. Boolean reductions still validate every
operand, including values after a determining zero or one. Generic gathers
transfer completed generic storage directly; the shared materializer retains
narrowing behavior for selected scalar values.

`zig build precommit -Doptimize=ReleaseSafe -j4`, the differential suite,
`test-ecl`, `test-snapshots`, focused column-primitive cancellation/session
reuse, and initialized-Session column-primitive OOM coverage passed. The
standalone scalar-composite cursor test also passed in ReleaseSafe with
allocation disabled and an exhausted shared work budget. Deliberately wrong
boolean-idiom and list-key join assertions failed their selected differential
and language suites; both were restored before final verification.

The complete grouped aggregate (23,295 bytes) and serialized join
(144,226,682 bytes) match the baseline byte-for-byte.
