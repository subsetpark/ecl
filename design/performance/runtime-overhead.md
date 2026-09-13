# Shared runtime overhead

## Bounded operation completion

This iteration follows `2c6006c`. It retains coalescing of callback, result
publication, and operation retirement within a scheduled cooperative turn.
One allowance covers extension work and host phase transitions; explicit yield,
parking, cancellation unwind, and exhaustion return to arbitration. Host
construction retains its separate bounded grant, so a callback that spends its
last credit can still advance an already-started construction. No executor
placement changes or experimental switches remain.

A second prototype attempted the first slice of an admitted operation on the
current eligible executor. It reserved the ordinary continuation and ownership
before publication, shared the evaluation allowance, rejected recursive
dispatch, respected retirement arbitration, and excluded worker-pool embedding
callers. It did not establish an additional benefit above variation and is not
retained. In particular, the cached-stat workload did not justify moving
potentially blocking filesystem work onto an embedding caller.

Measurements use native x86_64 Linux, Zig 0.16.0, ReleaseSafe, identical CPU
affinity 4,6, the same 64 KiB stat input, one warmup and five fresh-process
repetitions. Variant order alternates. Timing ran without concurrent task builds,
tests, or profiling; the unrelated host workload remained active. CLI cases
measure whole-process elapsed time. Native benchmark cases measure the program
after setup, perform 1,000 operations, and assert the exact callback/retirement
count after joined close. Stat and direct-native cases perform 10,000 requests.

| Case | Lookup seconds | Coalescing seconds | First-slice prototype seconds |
|---|---:|---:|---:|
| Public stat, default pool | 17.662 | 17.214 | 17.502 |
| Public stat, one worker | 17.005 | 16.760 | 16.658 |
| Public stat, cooperative | 16.463 | 16.897 | 16.397 |
| Direct native request, one worker | 8.531 | 8.364 | 8.309 |
| Native operation, cooperative root | 0.783 | 0.781 | 0.778 |
| Native operation, one-worker root | 0.784 | 0.761 | 0.761 |
| Native operation, eight-worker root | 0.814 | 0.794 | 0.810 |
| Native operation, one-worker task | 0.731 | 0.726 | 0.726 |
| Native operation, eight-worker task | 1.384 | 1.360 | 1.345 |

The one-worker root case supports retaining coalescing: its median improves
2.9%, with disjoint ranges of 0.774684–0.797129 and 0.749824–0.765334 seconds.
First-slice execution adds no measurable benefit in that case. Its eight-worker
task median improves another 1.0%, but the coalescing and first-slice ranges
overlap (1.324828–1.396548 versus 1.262333–1.357364 seconds). Other timing
changes also have overlapping ranges. These measurements do not establish a
general stat or native-operation speedup. The earlier migration baseline remains
far faster on stat; restoring that backend's performance is not established.

Five separate fresh-process allocation probes confirm that the one-worker task
uses 186,734 allocations instead of 188,732, with the same 843,335-byte peak
in every run. Eight-worker allocation medians fall from 188,732 to 188,646.
Eight-worker peak memory has a higher median, 570,469 versus 478,209 bytes;
the ranges overlap at 510,825–775,118 versus 477,489–667,444 bytes. This is a
transient scheduling tradeoff, not evidence of identical memory use in all
modes. All samples remain below the unchanged one-worker peak, and exact
joined-cleanup assertions pass. The optimization adds no per-operation heap
storage. Public SDK budget observations report retirement grants of 254 after
coalescing versus 256 before, confirming that host transitions share the grant.

Separate instruction diagnostics investigate the cooperative stat median's
2.6% increase. User instructions are essentially unchanged:
127,867,613,164 versus 127,874,367,837 (+0.005%); cycles increase 3.0%.
A whole-process 10,000-operation native CLI diagnostic instead increases
instructions 1.1% (60,087,979,644 to 60,764,132,248) and cycles 3.5%.
These single diagnostics are not timing repetitions and do not support a
universal improvement. The retained benefit is the measured one-worker case
and reduced allocations. A separate 199 Hz native profile loses no samples;
dispatch, resolution, idiom execution, lexical lookup, and memory initialization
remain prominent (8.62%, 8.53%, 7.65%, 7.31%, and 7.22%, respectively).

Five fresh-process comparisons of mixed short-task latency, cancellation, and
10,000-level recursive value creation plus joined cleanup have overlapping
before/after ranges. The cooperative deep-value median rises from 23.029 to
24.580 ms, with ranges 22.347–23.749 and 22.788–39.473 ms; one- and
eight-worker medians are effectively unchanged. No repeatable fairness or
cleanup regression is established by those probes.

The raw [three-variant measurements](runtime-overhead-immediate-timing.json)
include elapsed/user/system time, context switches, counters, programs, fixture
identity, and artifact SHA-256 values. The retained CLI SHA-256 is
`06b246fb9b362c543e7b032cc4265973a922fc5b44cf37da2bc65f6e3ab391fe`.
The [allocation repetitions](runtime-overhead-immediate-memory.json),
[public grant observations](runtime-overhead-immediate-grants.json), and
[latency/cleanup repetitions](runtime-overhead-immediate-extra.json) preserve
the additional evidence. The first-slice artifact identities remain in the raw
comparison even though its code is rejected.

Verification passed: `zig build check test-native-runtime precommit`, the
initialized-Session `test-oom-surfaces -Doom-filter='cooperative native'`
resource/message/child-publication probes, and Docker Ubuntu/glibc `test-tsan`.
The one-credit finalizer assertion was deliberately broken, observed failing,
restored, and verified through the static and dynamic native fixtures. The
retained source patch against `2c6006c` has SHA-256
`5c72ba6c792859625a30e0e111e2203ec17147da12c72055390d622c170aac8f`.
The native ABI remains 24. The subsequent filesystem direction is a direct
runtime implementation targeting the pre-SDK performance envelope; these
shared-runtime improvements alone do not resolve its overhead.

## Guarded plain lookup

The lookup iteration follows `d2f81a9`. It retains the 16-entry binding cache
and adds guarded lexical/core resolutions, with at most eight searched scopes.
A first successful lookup records its context; a repeat admits observations.
Lexical entries cannot evict established qualified or module-local entries at
other occurrences. Guard storage belongs to the Unit rather than hot resolver
return values. Revisions cover absent environments as well as installed shapes.

These measurements use native x86_64 Linux ReleaseSafe builds with Zig 0.16.0,
the same 64 KiB stat input, and CPUs 4 and 6. Both variants use identical
affinity. This is a new paired control, not a direct comparison with the earlier
CPUs 0 and 2 measurements. Each case has one warmup and five fresh-process
repetitions, with alternating variant order and no concurrent task builds or
tests. The unrelated host workload remained active.

| Case | Retirement median seconds | Lookup median seconds |
|---|---:|---:|
| Public stat, default pool | 32.755 | 33.833 |
| Public stat, one worker | 30.741 | 30.792 |
| Public stat, cooperative | 23.509 | 25.304 |
| Direct native request, one worker | 14.631 | 15.218 |
| Lexical loop, one worker | 1.150 | 0.844 |

Stat is a cold-lookup control, not a demonstrated speedup. Its default-pool
median increases 3.3%, with overlapping ranges of 20.162–34.169 and
27.343–39.748 seconds. Cooperative ranges are 18.006–29.767 and
17.863–27.410 seconds. The one-worker stat ranges are 19.002–32.690 and
17.720–32.957 seconds. The lexical loop's median improves 26.6%, but its ranges
also overlap on this busy host.

The dedicated 4,096-iteration cases establish the lookup benefit more clearly.
Each fresh process reports the median of three samples; the table below gives
the median across the five recorded processes. Every before/after range in
these cases is disjoint.

| Case | Workers | Retirement milliseconds | Lookup milliseconds |
|---|---:|---:|---:|
| Module-local call site | cooperative | 8.319 | 5.176 |
| Module-local call site | 1 | 8.101 | 5.051 |
| Module-local call site | 8 | 8.083 | 5.148 |
| Core fallback | cooperative | 10.808 | 5.476 |
| Core fallback | 1 | 10.614 | 5.176 |
| Core fallback | 8 | 10.579 | 5.331 |

Separate instrumented runs reduce core-fallback resolver resumptions from
8,195 to 7, with 8,188 plain hits. The module-local case falls from 4,100
resumptions to 6, while preserving its qualified and local specializations.
Both retain 33 allocations. Stat records no plain hits: its allocation count
changes from 4,747,155 to 4,747,156, and peak temporary memory stays at
1,892,444 bytes. Instrumentation changes object layout, so its cache-collision
counts are evidence for those instrumented artifacts, not exact CLI coverage.
The fixed Unit size increases from 3,792 to 5,536 bytes, including the bounded
guard pool and a 736-byte driver slot. Dormant guards retain no snapshot reader.

A separate stat instruction-count sample measures 124,412,588,735 versus
127,226,565,187 user instructions, a 2.3% cold-path cost. User cycles increase
0.8%, from 52,887,246,094 to 53,318,500,038. These are individual diagnostic
samples, not repeated timing estimates. Only `cpu_atom` counts are used
(99–100% coverage); the effectively zero-coverage `cpu_core` results are not
combined with them. This identifies a small real cost alongside much larger
elapsed variation. The retained tradeoff is bounded extra metadata and cold
lookup work for repeatable 36–51% gains on repeated lookups.

The separate 199 Hz profile has 4,070 samples and no reported loss. Dispatch,
resolution, lexical traversal, and direct lookup remain the leading stat costs.
Memory clearing is 5.72% of self samples. An earlier discarded draft widened
hot resolver payloads and put 68.05% of its profile in memory clearing;
subsequent drafts moved observations out of those payloads and protected the
existing specializations from lexical churn. The preserved migration baseline
remains much faster on stat; this iteration does not close that gap.

### Lookup evidence and verification

Raw results are retained in `runtime-overhead-lookup-timing.json`,
`runtime-overhead-lookup-benches.json`, `runtime-overhead-lookup-cooperative.json`,
`runtime-overhead-lookup-services.json`, `runtime-overhead-lookup-process.json`,
and `runtime-overhead-lookup-extra.json`. They include artifact identities,
individual timings, CPU time, context switches, counters, and service samples.
The ReleaseSafe CLI SHA-256 is
`e4dc676f8470352e593b848c61f1fcb1aef4a488e53bf68c46329782635933b6`.
Scripts, instruction counts, profiles, rejected drafts, and gate logs remain
under `/home/zax/.cache/ecl-overhead/evidence`.

The service pass uses one warmup and one recorded process per workload; it
checks behavior, joined exit, and cleanup residue rather than claiming timing
gains. Filesystem and network thread peaks remain 16 and 147 respectively.
Sampled filesystem RSS is 14,832–17,864 KiB, and network RSS is 58,204 KiB.
The process workload was checked again with one warmup and five alternating
fresh processes per variant. Thread-peak ranges overlap: 198–228 before and
194–213 after (medians 199 and 209). RSS ranges are 79,384–87,992 and
82,404–88,196 KiB. Elapsed medians are 0.773 and 0.768 seconds. These observations
do not establish a process-thread or memory regression; every run joins and
passes its output and cleanup checks.

Repeated short-task and cancellation probes have lower medians and overlapping
ranges, without a reproducible latency regression. Creating and then releasing
a 10,000-deep value takes 26.760 versus 22.354 ms cooperatively, 26.405 versus
22.923 ms with one worker, and 25.863 versus 21.970 ms with eight workers.
Those ranges are disjoint. This measures creation plus joined cleanup, not
destruction in isolation.

The new public cases cover rebinding, unbinding, core shadowing, installation
of an absent child environment, deep-chain fallback, escaped quotations, and
cache churn. Existing module, environment, and concurrency suites exercise
replacement, concurrent publication, and delayed-reader reclamation.
`zig build check`, final `zig build precommit`, Docker/glibc TSan, and
initialized-Session batch-import OOM coverage passed.
The absent-environment assertion was deliberately broken, failed in the
selected test, and restored. Earlier precommit attempts rejected an external
cache path and then its escaping symlink; verification uses a physical cache
inside the repository. A stale default-cache artifact was detected by its
hash and excluded from measurements. A later precommit attempt exceeded its
timeout during concurrent build load; the completed final rerun is recorded in
`lookup-verified-precommit.log`. The source/test patch relative to `d2f81a9`
has SHA-256 `480499a9966fef9cca73da53c5015dd6529902e87f03791aad84a81c85205470`.

## Retirement scheduling

Measured on x86_64 Linux 7.1.9-1-MANJARO with Zig 0.16.0, native
ReleaseSafe binaries. The predecessor is `fa62273`; the preserved migration
baseline is `8aae611`. Every process performs 10,000 stat calls on the same
cached 64 KiB regular file. The inherited affinity exposes CPUs 0–13, spanning
three CPU classes. Each case has one discarded warmup and five fresh-process
measurements, with variant order reversed on alternating repetitions. No builds
or test gates from this task ran alongside timing. An unrelated host workload
was present; paired measurements and the affinity control below are retained
rather than treating the machine as isolated.

| Case | Before median seconds | Claims median seconds |
|---|---:|---:|
| Public stat, default pool | 50.848 | 21.927 |
| Public stat, one worker | 15.213 | 19.744 |
| Direct native request, one worker | 8.179 | 10.222 |
| Public stat, one worker, CPUs 0 and 2 only | 15.905 | 15.210 |

The default-pool improvement is 57%, beyond the observed ranges: 43.207–63.246
seconds before and 17.213–28.117 seconds after. Median voluntary context
switches fall from 12,838,456 to 1,305,048; median involuntary switches fall
from 11,940,749 to 3,646. Median user CPU falls from 99.341 to 22.128 seconds,
and system CPU from 223.268 to 4.890 seconds.

The unrestricted one-worker timings are bimodal and do **not** establish a
speedup. Their medians worsen, although their elapsed ranges overlap almost
completely. A separate alternating five-process comparison restricted both
variants to the same two performance cores does not reproduce that regression:
the ranges are 12.442–17.371 seconds before and 12.330–16.868 after. This supports
CPU placement as a contributor, rather than proving an improvement for every
one-worker deployment. The preserved migration baseline has a 0.114-second
median in the unrestricted comparison; that gap remains substantial.

An intermediate claim implementation still broadcast every availability event.
Its preliminary measurements are retained, but were stopped before completing
five repetitions. They motivated waking one retirement executor and preserving
a distinct broadcast for evaluation backpressure relief. They are not a second
completed timing comparison.

Separate 199 Hz user-cycle profiles contain 3,853 default-pool and 3,561
one-worker samples, with no lost samples reported. The leading costs now include
dispatch, lexical resolution, binding/shape access, and memory clearing. On the
default profile's `cpu_atom` event, lexical, resolution, and direct-lookup
cursors account for 5.52%, 5.30%, and 4.78% of self samples respectively. On the
one-worker `cpu_core` event, the resolution cursor alone accounts for 11.03%.
PMU percentages are not combined across CPU classes.

### Reproduction and identities

The public workload is:

```ecl
10000 ('cwd "data" fs.stat pop) times 10000
```

The direct control preserves native operation, result, and cleanup ownership
while excluding public wrapper work:

```ecl
10000 (fs.core.request ['stat 'cwd "data"] port.open
       dup fs.core.execute-request [] port.call pop port.close) times 10000
```

The original input and migration artifacts remain under
`/home/zax/.cache/ecl-instance-verification`. New scripts, raw timing JSON,
profiles, logs, and the exact source patch are retained under
`/home/zax/.cache/ecl-overhead/evidence`. `compare.py`, `pinned.py`, and
`profile.py` specify commands, affinity, environment, inputs, and exit/output
checks. Every workload exited zero and returned `10000`; process exit includes
joined Session cleanup. Run scripts with closed stdin and an outer timeout.

| Artifact | SHA-256 |
|---|---|
| Predecessor ReleaseSafe binary | `272e3d177d0daee3a3bb233ddfd5c8693d53ed8c70869936cf94177cb4192f76` |
| Retirement-claim ReleaseSafe binary | `93e2a2dd7e3a0c3bf4b8fd9a18f7f924e3bda21b5db661ad47731f42246d5687` |
| Preserved migration binary | `29369868a797e4bf1c897f49b7b9b21f43cb072b58b0ed332db9b6ba8458a1de` |
| Source/test patch relative to `fa62273` | `67666fa3bb9457be7ea9dbb84e11994aa5a0c5aabf7eef9b806f13b9be5e160f` |

### Verification

`zig build check`, focused retirement claim/pressure behavior, `zig build
precommit`, and Docker Ubuntu/glibc `zig build test-tsan` passed. The claim test
also failed with an intentionally incorrect assertion and passed after
restoration. It exercises enqueueing while another thread holds destruction
ownership, exclusion of competing claims, coalesced notifications, and bounded
continuation release. Existing public Session and native tests cover cold/idle
settlement, cancellation, child cleanup, and publication lifetime behavior.

One earlier precommit attempt exceeded its outer timeout; another formal-check
invocation exited 2 without diagnostics. The isolated formal command and the
complete final precommit subsequently passed. The broad initialized-Session
filesystem OOM attempt timed out after compilation plus five minutes of probe
execution; it is not recorded as passing. The focused initialized-Session
`native capacity rejection` allocation-failure sweep passed.

A separate `test/service_benchmark.py` smoke/sampling pass ran one warmup and
one recorded process per workload and variant, without concurrent builds.
All six workloads completed, including joined cleanup and the fixture's check
for unpublished filesystem residue. These are memory/thread observations, not
additional five-run timing claims. Sampling is per interpreter at 1 ms and
excludes subprocess memory.

| Workload | Before peak KiB | Claims peak KiB | Peak threads, both |
|---|---:|---:|---:|
| Directory resources | 16,172 | 16,128 | 16 |
| Stat | 14,808 | 14,820 | 16 |
| Whole-file reads | 17,456 | 17,648 | 16 |
| Staging cleanup | 14,972 | 15,004 | 16 |
| Concurrent connections | 58,036 | 58,068 | 147 |
| Concurrent duplex processes | 85,500 | 88,984 | 207 |

The isolated process-memory sample is about 4% higher for duplex processes;
one sample does not establish a retention regression. The source change adds
no allocation site or per-operation retained record. Bounded-memory and joined
lifetime checks remain part of the public behavior gates above.
