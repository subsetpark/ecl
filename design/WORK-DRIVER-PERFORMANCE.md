# Work-driver performance

Status: deferred optimization design. The scheduler contract and its property
tests are the authority; this document records opportunities to measure after
the first correct implementation is complete.

## Current cost model

User-sized native work is represented by an owned `WorkDriver`. A concrete
driver owns its cursor, inputs, and partially initialized outputs. The
type-erased descriptor contains a context pointer, resume callback, and
destructor callback. A resume performs no more than one accounted-work quantum
(currently 65,536 transitions) before completing or returning the unit to the
scheduler.

The expected costs are different at three scales:

- Every operation that creates a driver currently pays one allocation and one
  destruction of its concrete state. This dominates very small inputs.
- Within a slice, explicit cursor state adds branches and state loads compared
  with an ideal compiler-optimized native loop. Flat memory-bound kernels
  should be affected much less than cheap branch-heavy scalar kernels.
- Type erasure adds one indirect resume call per slice, and scheduling adds one
  handoff per yielded slice. At a 65,536-transition quantum these costs should
  be heavily amortized; they are not paid per element.

Before measurement, reasonable hypotheses are 0–10% overhead for long flat
copies, 10–40% for branch-heavy elementwise cursors, and potentially 20–100%
for deeply structural worklists. Tiny inputs may be several times slower in
relative terms because of fixed allocation cost while remaining only hundreds
of nanoseconds slower in absolute terms. These ranges are hypotheses, not
budgets or acceptance criteria.

## Invariants no optimization may weaken

An optimization must preserve all of the following:

1. Every user-sized traversal has one cursor-based implementation. There is no
   duplicate synchronous implementation kept as a fast path.
2. A scheduler-attached unit returns within its accounted-work quantum with
   the exact next cursor and partial-output state preserved.
3. Resumption never repeats visible IO, publication, mutation, allocation,
   comparison, or ownership transfer.
4. Cancellation, OOM, and ordinary errors unwind all owned partial state.
5. Known-size results use exact-size materialization. Unknown-size results use
   fixed chunks followed by one polled materialization pass; cancellable paths
   do not use relocating or rehashing storage.
6. Constant-bounded work may execute directly. Runtime-size-dependent work may
   not be classified as constant merely because typical inputs are small.
7. Scheduler safety and liveness properties, one-worker progress, observable
   results, error provenance, and representation parity remain unchanged.

## Optimization opportunities

### Remove general-allocation cost from common drivers

The highest-confidence opportunity is changing where concrete continuation
state lives, without changing its state machine:

- add a small aligned inline continuation area to `Unit` and spill only larger
  drivers;
- allocate driver states from a per-unit size-class pool; or
- use typed slabs for the small set of frequent driver sizes.

Inline storage needs a nominal occupied/empty state and compile-time alignment
and size validation. Pools must retain precise ownership and allocator-failure
behavior; they must not turn teardown into an unbounded traversal.

### Keep genuinely constant cases direct

Bounded scalar cases do not need suspension. For example, scalar numeric
comparison may execute directly while string comparison uses the same resumable
comparison cursor used by sorting. This is domain dispatch, not a second
implementation of a user-sized algorithm.

### Batch cursor transitions

Drivers should dispatch once per slice and let monomorphic inner loops consume
a chunk. Likely opportunities include bulk copy/fill, leaf pervasion, fixed-width
string traversal, and materializer profile/fill passes. A child cursor should
report consumed work where a parent must share one budget across phases; parent
drivers must not assume that a completed child consumed only one transition.

Bulk operations still need conservative accounting. A `memcpy` or vector loop
may operate on a bounded byte/element chunk, but cannot make an arbitrarily
large copy appear to be one transition.

### Promote a bounded first slice only when incomplete

A primitive handler could construct the canonical cursor locally and execute
one bounded slice. If it completes, no persistent driver allocation is needed;
if it does not, the cursor is moved into owned driver storage.

This is safe only if an incomplete first slice causes an immediate scheduler
return. The machine must not install the driver and then run a second quantum
in the same worker turn. Cursor state must be safely movable and have one
cleanup path in both local and promoted states. This option should be attempted
only if driver allocation remains material after inline storage or pooling.

### Specialize persistent state and leaf kernels

Profile-guided variants may reduce cursor size, tag switching, and cache
traffic:

- monomorphic drivers for flat leaf kinds;
- compact tagged state for common phases, with exhaustive transitions;
- structure-of-arrays temporary storage where traversal is bandwidth-bound;
- vectorized leaf chunks with scalar tails; and
- fused profile/fill work only when exact representation is already known.

These remain representations of the same pure decision process. Generic and
specialized paths must continue to pass differential tests for values, errors,
and representations.

### Tune the quantum last

A larger quantum improves throughput amortization but worsens queue and
cancellation latency; a smaller quantum does the reverse. Do not tune the
quantum to hide avoidable allocation or cursor overhead. Consider adaptive
quantums only after fixed-quantum measurements, and preserve a hard maximum
non-yield interval independently of any adaptive policy.

The indirect resume call is expected to be a low-priority target because it is
paid once per slice. Devirtualization is worthwhile only if profiles contradict
that expectation.

## Measurement plan

Benchmark the current correct implementation before selecting an optimization.
For each case, use input sizes 1, 32, 1,024, 65,535, 65,536, 65,537, and
1,048,576 so fixed cost, quantum boundaries, and steady-state cost are visible.

Workloads should include:

- constant scalar operations;
- flat typed copy and materialization;
- numeric pervasion over homogeneous and mixed leaves;
- string comparison, encoding, splitting, joining, and formatting;
- structural equality and hashing over wide and deeply nested values;
- grade, distinct, group, dictionary update, and merge; and
- cancellation and failure at each durable phase.

Measure at one and eight workers, both uncontended and with a long task
competing against short tasks. Record:

- wall time, CPU time, and nanoseconds per logical transition;
- allocations and allocated bytes per operation;
- resumes and ready-queue handoffs per operation;
- short-task queue latency at p50, p95, and p99;
- cancellation-observation latency and maximum uninterrupted work; and
- peak temporary memory.

Compare ReleaseSafe and the intended release optimization mode. A benchmark
must consume results and use the public runtime surface where possible. Add a
lower-level harness only to attribute a measured cost, not as the sole evidence
for an optimization.

## Decision rule

Optimize only a measured contributor. Prefer, in order:

1. eliminating fixed driver allocation;
2. batching work inside a bounded slice;
3. specializing hot flat-leaf state machines; and
4. changing scheduler or quantum policy.

Any candidate must pass scheduler interleaving properties, shell/process
properties with deadlines, public behavior and differential suites, allocator
failure sweeps, and the one/eight-worker matrix. Report both throughput and
worst-case progress latency: an optimization that improves aggregate throughput
by monopolizing a worker is a scheduler regression.
