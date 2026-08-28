# Performance baselines

Performance claims in this repository are release-mode, target-specific
characterizations through public runtime surfaces. They are not portable
constants. Regenerate a baseline on the target under discussion rather than
copying timings from this file.

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
the repeated qualified-call workload, and `-- --latency-only` selects the mixed
short-task and cancellation safeguards. Without `--quick`, each retains the
full 101 repetitions.

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
in schema `ecl.workdrivers.*.v5`.

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
the focused workload remains in schema `ecl.workdrivers.*.v5`.

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
`ecl.workdrivers.*.v5`.
