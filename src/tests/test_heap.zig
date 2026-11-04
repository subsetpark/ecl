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
//! | `SessionHeap` (this file) | suites that only run source through a session | leak detection, double/invalid-free detection | none beyond the checks |
//! | `std.testing.allocator` | tests that hand host-built values to a session | the same checks, plus write-after-free detection | none beyond the checks |
//! | `DebugAllocator{.enable_memory_limit}` | `module_test`, `concurrency_test` | `total_requested_bytes`, and a settable `requested_memory_limit` to force failure at a budget | as above |
//! | `smp_allocator` + this file's `FailingAllocator` | `oom_test` | **failure injection at every ordinal, over an initialized Session**, without the stack capture that faults beside concurrent native-module unloads | re-runs the probe once per allocation |
//! | `std.testing.allocator` + `checkAllAllocationFailures` | component probes beside their component | the same injection, without a Session | as above |
//! | `page_allocator` | `source_audit` | no bookkeeping; it never frees | nothing to assert |
//!
//! No allocator here records allocation sites by default. `Session.init`
//! replays the embedded prelude — thousands of small allocations — and a
//! traced allocator captures a stack trace on every one: ~267ms a session
//! against ~14ms without. Turning off `safety` recovers almost nothing
//! (~190ms); the traces are the whole cost. One build option,
//! `-Dalloc-trace-frames`, sets the frame count for `std.testing.allocator`
//! (through `test/test_runner.zig`), every `DebugAllocator` in the tree
//! (through `stack_trace_frames` below), and the Debug CLI. It defaults to 0.
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
//!   allocator here detects leaks, and none says where one came from until
//!   asked. When you have a leak to chase, build with
//!   `-Dalloc-trace-frames=7`: that restores attribution across every suite
//!   at once, which is what you want, since the leak is never in the suite
//!   you predicted.
//!
//! ## The rule the compiler cannot check
//!
//! A session must own every value it will free. A test that builds a heap
//! value with one allocator and hands it to a session backed by another —
//! `define`, `pushOwned`, `publishTop`, `publishModule` — frees across
//! allocators and aborts with "Invalid free" at teardown, from inside
//! `heap.destroyObject`, far from the line at fault.
//!
//! So this heap suits suites that only run source strings through a session
//! (`kernel_test_support`, `combinator_test`, `machine_test`,
//! `module_source_test`). Suites that mix host-built values into a session
//! (definition_test, module_test) stay on `std.testing.allocator`, where
//! the value and the session already agree. If you move a test here and it
//! aborts on a free, this allocator rule caused it; the code under test may be sound.
//!
//! The rule divides whole *files*, so tests needing both homes must live in two files.
//! `module_test.zig` was one file until the same-home TCO walk was measured:
//! twenty thousand activations under a tracing allocator cost 15.4s against
//! 4.2s untraced, and none of that file's source-only tests read a stack
//! trace. Splitting `module_source_test.zig` out took the local gate from
//! 103s to 81s. When a slow test's allocator is not load-bearing, move the
//! test rather than shrinking the proof.
const std = @import("std");

/// Allocation-site attribution for every test allocator, from
/// `-Dalloc-trace-frames`. Costs roughly 19x on session bootstrap.
pub const stack_trace_frames = @import("alloc_options").trace_frames;

pub const SessionHeap = std.heap.DebugAllocator(.{ .stack_trace_frames = stack_trace_frames });

/// Tear down a session heap, failing loudly if the session leaked. Declare
/// the `defer` for this *before* the session it backs, so the session is
/// destroyed before its allocator is checked.
pub fn retire(heap: *SessionHeap) void {
    if (heap.deinit() == .leak) std.debug.panic("test session leaked memory", .{});
}

/// Fails the allocation at `fail_index` and every one after it, counting
/// bytes so a sweep can prove an induced failure reclaimed everything.
///
/// This is `std.testing.FailingAllocator` without its stack capture. That
/// allocator unwinds the stack on every induced failure, and Zig's ELF
/// unwinder caches each loaded object's address range and `.eh_frame_hdr`
/// without noticing `dlclose`. When concurrent Sessions load and unload native
/// modules, a later library mapped over a stale range resolves to unmapped
/// unwind tables: the capture faults, and the fault handler deadlocks on the
/// unwinder lock the faulting thread still holds. No sweep reads the trace.
pub const FailingAllocator = struct {
    internal_allocator: std.mem.Allocator,
    fail_index: usize,
    alloc_index: usize = 0,
    allocated_bytes: usize = 0,
    freed_bytes: usize = 0,
    allocations: usize = 0,
    deallocations: usize = 0,
    has_induced_failure: bool = false,

    pub const Config = struct {
        /// Allocations that succeed before the first failure.
        fail_index: usize = std.math.maxInt(usize),
    };

    pub fn init(internal_allocator: std.mem.Allocator, config: Config) FailingAllocator {
        return .{ .internal_allocator = internal_allocator, .fail_index = config.fail_index };
    }

    pub fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        if (self.alloc_index == self.fail_index) {
            self.has_induced_failure = true;
            return null;
        }
        const result = self.internal_allocator.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocated_bytes += len;
        self.allocations += 1;
        self.alloc_index += 1;
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        if (!self.internal_allocator.rawResize(memory, alignment, new_len, return_address)) return false;
        self.countResize(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        const result = self.internal_allocator.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        self.countResize(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(context));
        self.internal_allocator.rawFree(memory, alignment, return_address);
        self.deallocations += 1;
        self.freed_bytes += memory.len;
    }

    fn countResize(self: *FailingAllocator, old_len: usize, new_len: usize) void {
        if (new_len < old_len) self.freed_bytes += old_len - new_len else self.allocated_bytes += new_len - old_len;
    }
};

test "failing allocator fails at its index and accounts every byte" {
    var failing = FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const gpa = failing.allocator();
    const first = try gpa.alloc(u8, 8);
    const second = try gpa.alloc(u8, 4);
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 1));
    try std.testing.expectError(error.OutOfMemory, gpa.alloc(u8, 1));
    try std.testing.expect(failing.has_induced_failure);
    const grown = gpa.realloc(first, 16) catch first;
    gpa.free(grown);
    gpa.free(second);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);
}
