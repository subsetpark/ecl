//! Allocator policy for tests, and the session heap that implements the
//! default half of it.
//!
//! ## Which allocator, and what it buys you
//!
//! Five allocators appear in this test tree. They are not interchangeable:
//! each one is the only thing that makes a particular class of assertion
//! possible, and choosing the wrong one silently removes coverage rather
//! than failing.
//!
//! | allocator | where | provides | costs |
//! |---|---|---|---|
//! | `SessionHeap` (this file) | suites that only run source through a session | leak detection, double/invalid-free detection | no allocation site on a leak |
//! | `std.testing.allocator` | tests that hand host-built values to a session | all of the above **plus the allocation site** | ~267ms per session bootstrap |
//! | `DebugAllocator{.enable_memory_limit}` | `module_test`, `concurrency_test` | `total_requested_bytes`, and a settable `requested_memory_limit` to force failure at a budget | as above |
//! | `smp_allocator` + `checkAllAllocationFailures` | `oom_test` | **failure injection at every ordinal, over an initialized Session** | re-runs the probe once per allocation |
//! | `std.testing.allocator` + `checkAllAllocationFailures` | component probes beside their component | the same injection, without a Session | as above |
//! | `page_allocator` | `source_audit` | no bookkeeping; it never frees | nothing to assert |
//!
//! The trace cost is not incidental. `Session.init` replays the embedded
//! prelude — thousands of small allocations — and `std.testing.allocator`
//! captures a stack trace on every one: ~267ms a session against ~14ms
//! without. Turning off `safety` recovers almost nothing (~190ms); the
//! traces are the whole cost.
//!
//! ## Putting a test in the wrong place produces a false negative
//!
//! These suites do not fail when they are the wrong home for an assertion.
//! They pass, having tested less than you think:
//!
//! - **An allocation-failure path is only covered by a
//!   `checkAllAllocationFailures` probe.** Ordinary tests run each
//!   allocation once and it succeeds. Component-level probes live beside
//!   their component (`list.zig`, `dict.zig`, `env.zig`, `equal.zig`, and
//!   the reader, formatter, line-editor, registry, and native-validation
//!   probes) and construct their subject directly. `oom_test` is the only
//!   sweep over an initialized Session, so a surface reachable only through
//!   a live one — a word, a prelude definition, a module, reflection, the
//!   scheduler — is covered only if a snippet in its *enumerated* probe
//!   reaches it. This is the easiest false negative in the tree to create:
//!   you add a feature, you add behavioral tests, they pass, and the
//!   failure path was never run.
//! - **A bounded-memory claim needs a counting allocator.** Only
//!   `enable_memory_limit` populates `total_requested_bytes`. Asserting
//!   "retirement stays bounded" anywhere else is unwriteable, and asserting
//!   it against a fixed number instead of a measured delta passes for the
//!   wrong reason.
//! - **A leak-attribution need is not a leak-detection need.** Every
//!   allocator here detects leaks. Only `std.testing.allocator` says where
//!   one came from. Reach for it when a test exists *because* something
//!   leaked before; otherwise take the default and raise
//!   `stack_trace_frames` below when you actually have a leak to chase —
//!   one edit restores attribution across every suite at once, which is
//!   what you want, since the leak is never in the suite you predicted.
//!
//! ## The rule the compiler cannot check
//!
//! A session must own every value it will free. A test that builds a heap
//! value with one allocator and hands it to a session backed by another —
//! `define`, `pushOwned`, `publishTop`, `publishModule` — frees across
//! allocators and aborts with "Invalid free" at teardown, from inside
//! `heap.freePayload`, far from the line at fault.
//!
//! So this heap suits suites that only run source strings through a session
//! (`kernel_test_support`, `combinator_test`, `machine_test`,
//! `module_source_test`). Suites that mix host-built values into a session
//! (`definition_test`, `module_test`) stay on `std.testing.allocator`, where
//! the value and the session already agree. If you move a test here and it
//! aborts on a free, that is this rule, not a bug in the code under test.
//!
//! The rule cuts *files*, not tests, so a file that needs both is two files.
//! `module_test.zig` was one file until the same-home TCO walk was measured:
//! twenty thousand activations under a tracing allocator cost 15.4s against
//! 4.2s untraced, and none of that file's source-only tests read a stack
//! trace. Splitting `module_source_test.zig` out took the local gate from
//! 103s to 81s. When a slow test's allocator is not load-bearing, move the
//! test rather than shrinking the proof.
const std = @import("std");

/// Raise to restore allocation-site attribution in every suite that uses
/// this heap. Costs roughly 19x on session bootstrap; leave at 0 otherwise.
pub const stack_trace_frames = 0;

pub const SessionHeap = std.heap.DebugAllocator(.{ .stack_trace_frames = stack_trace_frames });

/// Tear down a session heap, failing loudly if the session leaked. Declare
/// the `defer` for this *before* the session it backs, so the session is
/// destroyed before its allocator is checked.
pub fn retire(heap: *SessionHeap) void {
    if (heap.deinit() == .leak) std.debug.panic("test session leaked memory", .{});
}
