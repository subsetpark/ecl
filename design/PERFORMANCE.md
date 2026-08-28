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

`-- --quick` selects only sizes 32 and 65,536 with three repetitions. It is a
smoke gate and is not performance evidence.

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
mixed/cancellation results do not show a uniform eight-worker improvement.
The next bounded investigation should attribute the fixed allocation total to
driver/cursor storage, starting with the separately identified first-frame
`ChunkStack` allocation, before considering transition batching or scheduler
policy.
