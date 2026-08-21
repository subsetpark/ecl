//! Per-element allocation budgets for the dispatch path.
//!
//! Every fast path in the interpreter is invisible to a behavioural test: when
//! one stops firing, nothing produces a wrong answer, the runtime just starts
//! allocating again. That is how a leaked inline driver slot survived until a
//! benchmark caught it, and how a cursor built to fetch one element went
//! unnoticed for as long as it did. These budgets make the absence of an
//! allocation an assertion.
//!
//! Each case runs its workload over two input sizes and asserts the *marginal*
//! allocations per element, so a fixed setup cost cannot make the number drift:
//! adding a field to a driver, or an allocation to session startup, cancels out
//! between the two runs. What survives the subtraction is exactly what the
//! runtime spends per element, which is the quantity a fast path exists to
//! keep at zero.
//!
//! A budget is a ceiling, not a record. Lowering one belongs to the change that
//! earns it, and raising one is a decision to spend memory that needs saying
//! out loud in a diff rather than being absorbed silently.
const std = @import("std");
const session = @import("../session.zig");

/// Counts what the run asks for. Only the count matters here — bytes and
/// timing are machine-dependent, the count is not.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.allocations += 1;
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const Case = struct {
    /// What the budget is about, named as the reader would describe it.
    name: []const u8,
    /// Source producing the input list; `{d}` is the element count.
    setup: []const u8,
    /// The measured workload, applied to whatever setup left.
    workload: []const u8,
    /// Allocations the workload may spend per element.
    per_element: usize,
};

const small = 1_000;
const large = 3_000;

/// Runs `setup` at `count` elements, then measures `workload` alone.
fn measure(allocator: std.mem.Allocator, case: Case, count: usize) !usize {
    var counting = CountingAllocator{ .backing = allocator };
    var runtime = try session.Session.init(counting.allocator(), &.{});
    defer runtime.deinit();

    var count_text: [24]u8 = undefined;
    const digits = try std.fmt.bufPrint(&count_text, "{d}", .{count});
    const setup = try allocator.alloc(u8, std.mem.replacementSize(u8, case.setup, "{d}", digits));
    defer allocator.free(setup);
    _ = std.mem.replace(u8, case.setup, "{d}", digits, setup);
    switch (try runtime.runUnit("<budget-setup>", setup)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.SetupFailed;
        },
        .incomplete => return error.SetupFailed,
    }

    // The window opens after setup so the count describes the workload rather
    // than the input it was handed.
    counting.allocations = 0;
    switch (try runtime.runUnit("<budget-workload>", case.workload)) {
        .ok => {},
        .err => |failure| {
            runtime.release(failure);
            return error.WorkloadFailed;
        },
        .incomplete => return error.WorkloadFailed,
    }
    return counting.allocations;
}

fn expectBudget(case: Case) !void {
    const allocator = std.testing.allocator;
    const at_small = try measure(allocator, case, small);
    const at_large = try measure(allocator, case, large);
    // Subtracting removes every fixed cost the two runs share, so what is left
    // is the per-element spend and nothing else. A fast path that stopped
    // firing shows up here and nowhere else.
    if (at_large < at_small) {
        std.debug.print(
            "\n{s}: allocations fell with input size ({d} at {d}, {d} at {d})\n",
            .{ case.name, at_small, small, at_large, large },
        );
        return error.NonMonotonicAllocation;
    }
    const marginal = (at_large - at_small) / (large - small);
    if (marginal > case.per_element) {
        std.debug.print(
            "\n{s}: {d} allocations per element, budget {d}" ++
                " ({d} at {d} elements, {d} at {d})\n",
            .{ case.name, marginal, case.per_element, at_small, small, at_large, large },
        );
        return error.AllocationBudgetExceeded;
    }
}

/// Dispatch spends nothing per element. Each of these was measured allocating
/// once or more per element before the fast path it now takes; the budget of
/// zero is what those changes bought, and the assertion is what keeps it.
const dispatch_free = [_]Case{
    .{
        .name = "empty quotation applied per element",
        .setup = "{d} range",
        .workload = "() each len",
        .per_element = 0,
    },
    .{
        .name = "unrecognized quotation body",
        .setup = "{d} range",
        .workload = "(pop 42) each len",
        .per_element = 0,
    },
    .{
        .name = "recognized idiom",
        .setup = "{d} range",
        .workload = "(1 +) each len",
        .per_element = 0,
    },
    .{
        .name = "head binder, two reads",
        .setup = "{d} range",
        .workload = "(|x| x x +) each len",
        .per_element = 0,
    },
    .{
        .name = "head binder, three names",
        .setup = "{d} range",
        .workload = "(|a| a a a + +) each len",
        .per_element = 0,
    },
    .{
        .name = "scalar binary arithmetic",
        .setup = "{d} range",
        .workload = "(pop 1 2 +) each len",
        .per_element = 0,
    },
    .{
        .name = "scalar unary arithmetic",
        .setup = "{d} range",
        .workload = "(pop 5 neg) each len",
        .per_element = 0,
    },
    .{
        .name = "scalar comparison",
        .setup = "{d} range",
        .workload = "(pop 1 2 <) each len",
        .per_element = 0,
    },
    .{
        .name = "scalar index into a list",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] 1 at) each len",
        .per_element = 0,
    },
    .{
        .name = "dict lookup by symbol key",
        .setup = "{d} range",
        .workload = "(pop {'k 5} 'k at) each len",
        .per_element = 0,
    },
    .{
        .name = "dict lookup by int key",
        .setup = "{d} range",
        .workload = "(pop {1 5} 1 at) each len",
        .per_element = 0,
    },
    .{
        .name = "structureless match",
        .setup = "{d} range",
        .workload = "(pop 1 1 match?) each len",
        .per_element = 0,
    },
    .{
        .name = "prelude word application",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] first) each len",
        .per_element = 0,
    },
    .{
        .name = "constant reference bound by set",
        .setup = "42 'k set {d} range",
        .workload = "(pop k) each len",
        .per_element = 0,
    },
    .{
        .name = "list length",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] len) each len",
        .per_element = 0,
    },
    .{
        .name = "value type",
        .setup = "{d} range",
        .workload = "(pop 5 type) each len",
        .per_element = 0,
    },
};

test "allocation: dispatch spends nothing per element" {
    for (dispatch_free) |case| try expectBudget(case);
}

/// Operations that build something. These allocate because there is a value to
/// construct, not because reaching the construction cost anything, and the
/// budgets record where that floor currently sits. They are here so that a
/// change which raises one has to say so.
const construction = [_]Case{
    .{
        .name = "cons onto an empty list",
        .setup = "{d} range",
        .workload = "(pop 1 () cons len) each len",
        .per_element = 4,
    },
    .{
        .name = "wrap a scalar",
        .setup = "{d} range",
        .workload = "(pop 5 wrap len) each len",
        .per_element = 4,
    },
    .{
        .name = "rest of a three-element list",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] rest len) each len",
        .per_element = 4,
    },
    .{
        .name = "reverse a three-element list",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] reverse len) each len",
        .per_element = 4,
    },
};

test "allocation: construction stays at its recorded floor" {
    for (construction) |case| try expectBudget(case);
}
