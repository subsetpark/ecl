# Shared runtime overhead

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
