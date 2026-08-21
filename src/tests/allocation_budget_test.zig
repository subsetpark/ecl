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

// Small enough that the whole sweep stays inside the fast tier's budget, and
// far enough apart that a per-element cost is unambiguous in the difference.
const small = 400;
const large = 1_200;

/// Runs `setup` at `count` elements in `runtime`, then measures `workload`
/// alone. Both sizes share one session: initializing one costs more than either
/// measurement, and the subtraction removes anything they share anyway.
fn measure(
    runtime: *session.Session,
    counting: *CountingAllocator,
    allocator: std.mem.Allocator,
    case: Case,
    count: usize,
) !usize {
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
    var counting = CountingAllocator{ .backing = allocator };
    var runtime = try session.Session.init(counting.allocator(), &.{});
    defer runtime.deinit();
    const at_small = try measure(&runtime, &counting, allocator, case, small);
    const at_large = try measure(&runtime, &counting, allocator, case, large);
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
    .{
        .name = "scalar compare",
        .setup = "{d} range",
        .workload = "(pop 1 2 cmp) each len",
        .per_element = 0,
    },
    .{
        .name = "membership",
        .setup = "{d} range",
        .workload = "(pop 2 [1 2 3] in?) each len",
        .per_element = 0,
    },
    .{
        .name = "dict membership",
        .setup = "{d} range",
        .workload = "(pop {'a 1} 'a has?) each len",
        .per_element = 0,
    },
    .{
        .name = "fold to a scalar",
        .setup = "{d} range",
        .workload = "(pop [1 2] 0 (+) fold) each len",
        .per_element = 0,
    },
    // Swept across the primitive surface 2026-08-21 rather than sampled. Every
    // one of these already measured zero; they are here so that stays true.
    .{
        .name = "stack dup",
        .setup = "{d} range",
        .workload = "(pop 5 dup pop) each len",
        .per_element = 0,
    },
    .{
        .name = "stack swap",
        .setup = "{d} range",
        .workload = "(pop 1 2 swap pop) each len",
        .per_element = 0,
    },
    .{
        .name = "logical not",
        .setup = "{d} range",
        .workload = "(pop 1 not) each len",
        .per_element = 0,
    },
    .{
        .name = "equality",
        .setup = "{d} range",
        .workload = "(pop 1 2 =) each len",
        .per_element = 0,
    },
    .{
        .name = "less than",
        .setup = "{d} range",
        .workload = "(pop 1 2 <) each len",
        .per_element = 0,
    },
    .{
        .name = "greater than",
        .setup = "{d} range",
        .workload = "(pop 1 2 >) each len",
        .per_element = 0,
    },
    .{
        .name = "min",
        .setup = "{d} range",
        .workload = "(pop 1 2 min) each len",
        .per_element = 0,
    },
    .{
        .name = "max",
        .setup = "{d} range",
        .workload = "(pop 1 2 max) each len",
        .per_element = 0,
    },
    .{
        .name = "subtraction",
        .setup = "{d} range",
        .workload = "(pop 3 2 -) each len",
        .per_element = 0,
    },
    .{
        .name = "multiplication",
        .setup = "{d} range",
        .workload = "(pop 3 2 *) each len",
        .per_element = 0,
    },
    .{
        .name = "division",
        .setup = "{d} range",
        .workload = "(pop 6 2 /) each len",
        .per_element = 0,
    },
    .{
        .name = "integer division",
        .setup = "{d} range",
        .workload = "(pop 7 2 div) each len",
        .per_element = 0,
    },
    .{
        .name = "power",
        .setup = "{d} range",
        .workload = "(pop 2 3 pow) each len",
        .per_element = 0,
    },
    .{
        .name = "atan2",
        .setup = "{d} range",
        .workload = "(pop 1.0 2.0 atan2) each len",
        .per_element = 0,
    },
    .{
        .name = "square root",
        .setup = "{d} range",
        .workload = "(pop 4 sqrt) each len",
        .per_element = 0,
    },
    .{
        .name = "floor",
        .setup = "{d} range",
        .workload = "(pop 1.5 floor) each len",
        .per_element = 0,
    },
    .{
        .name = "ceiling",
        .setup = "{d} range",
        .workload = "(pop 1.5 ceil) each len",
        .per_element = 0,
    },
    .{
        .name = "round",
        .setup = "{d} range",
        .workload = "(pop 1.5 round) each len",
        .per_element = 0,
    },
    .{
        .name = "exp",
        .setup = "{d} range",
        .workload = "(pop 1.0 exp) each len",
        .per_element = 0,
    },
    .{
        .name = "log",
        .setup = "{d} range",
        .workload = "(pop 1.0 log) each len",
        .per_element = 0,
    },
    .{
        .name = "sine",
        .setup = "{d} range",
        .workload = "(pop 1.0 sin) each len",
        .per_element = 0,
    },
    .{
        .name = "cosine",
        .setup = "{d} range",
        .workload = "(pop 1.0 cos) each len",
        .per_element = 0,
    },
    .{
        .name = "bitwise and",
        .setup = "{d} range",
        .workload = "(pop 3 5 band) each len",
        .per_element = 0,
    },
    .{
        .name = "bitwise or",
        .setup = "{d} range",
        .workload = "(pop 3 5 bor) each len",
        .per_element = 0,
    },
    .{
        .name = "bitwise xor",
        .setup = "{d} range",
        .workload = "(pop 3 5 bxor) each len",
        .per_element = 0,
    },
    .{
        .name = "bitwise not",
        .setup = "{d} range",
        .workload = "(pop 3 bnot) each len",
        .per_element = 0,
    },
    .{
        .name = "shift left",
        .setup = "{d} range",
        .workload = "(pop 3 2 bsl) each len",
        .per_element = 0,
    },
    .{
        .name = "shift right",
        .setup = "{d} range",
        .workload = "(pop 12 2 bsr) each len",
        .per_element = 0,
    },
    .{
        .name = "quotation call",
        .setup = "{d} range",
        .workload = "(pop 5 (dup) call pop) each len",
        .per_element = 0,
    },
    .{
        .name = "conditional",
        .setup = "{d} range",
        .workload = "(pop 1 (2) (3) if) each len",
        .per_element = 0,
    },
    .{
        .name = "dict keys",
        .setup = "{d} range",
        .workload = "(pop {'a 1} keys len) each len",
        .per_element = 0,
    },
    .{
        .name = "dict values",
        .setup = "{d} range",
        .workload = "(pop {'a 1} vals len) each len",
        .per_element = 0,
    },
};

test "allocation: dispatch spends nothing per element" {
    for (dispatch_free) |case| try expectBudget(case);
}

/// Membership over a generic spine, which the typed scan declines. The match
/// worklist it allocated per candidate is gone; what remains is exactly one
/// allocation for the walk itself -- the cursor's frame stack, allocated to
/// hold a single search entry -- plus, when the needle is a list and the
/// operation pervades, the cost of building the result it returns.
///
/// The scalar-needle case isolates the first from the second, and one is the
/// floor this shape reaches without changing `ChunkStack`, which every cursor
/// in the interpreter builds on.
const generic_membership = [_]Case{
    .{
        .name = "membership over a generic spine",
        .setup = "{d} range",
        .workload = "(pop [1 2] [[1 2] [3]] in?) each len",
        .per_element = 5,
    },
    .{
        .name = "scalar needle over a generic spine",
        .setup = "{d} range",
        .workload = "(pop 2 [[1 2] [3]] in?) each len",
        .per_element = 1,
    },
};

test "allocation: generic membership holds its recorded cost" {
    for (generic_membership) |case| try expectBudget(case);
}

/// Operations that build something. These allocate because there is a value to
/// construct, not because reaching the construction cost anything. The numbers
/// are what the sweep measured, not what anyone argued for: several look higher
/// than the structure they produce, and whether that is the floor or slack
/// nobody has looked at yet is exactly what a recorded baseline is for.
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
    .{
        .name = "range",
        .setup = "{d} range",
        .workload = "(pop 3 range len) each len",
        .per_element = 3,
    },
    .{
        .name = "gather by index vector",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] [0 2] at len) each len",
        .per_element = 3,
    },
    .{
        .name = "join",
        .setup = "{d} range",
        .workload = "(pop [\"a\" \"b\"] \",\" join len) each len",
        .per_element = 3,
    },
    .{
        .name = "where",
        .setup = "{d} range",
        .workload = "(pop [1 0 1] where len) each len",
        .per_element = 3,
    },
    .{
        .name = "drop",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] 1 drop len) each len",
        .per_element = 3,
    },
    .{
        .name = "take",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] 2 take len) each len",
        .per_element = 3,
    },
    .{
        .name = "each over two elements",
        .setup = "{d} range",
        .workload = "(pop [1 2] (1 +) each len) each len",
        .per_element = 3,
    },
    .{
        .name = "concatenate",
        .setup = "{d} range",
        .workload = "(pop [1 2] [3] cat len) each len",
        .per_element = 3,
    },
    .{
        .name = "raze",
        .setup = "{d} range",
        .workload = "(pop [[1] [2]] raze len) each len",
        .per_element = 4,
    },
    .{
        .name = "shape",
        .setup = "{d} range",
        .workload = "(pop [1 2 3] shape len) each len",
        .per_element = 5,
    },
    .{
        .name = "grade",
        .setup = "{d} range",
        .workload = "(pop [3 1 2] grade len) each len",
        .per_element = 5,
    },
    .{
        .name = "split",
        .setup = "{d} range",
        .workload = "(pop \"a,b\" \",\" split len) each len",
        .per_element = 9,
    },
    .{
        .name = "dict delete",
        .setup = "{d} range",
        .workload = "(pop {'a 1} 'a del keys len) each len",
        .per_element = 9,
    },
    .{
        .name = "flip",
        .setup = "{d} range",
        .workload = "(pop [[1 2] [3 4]] flip len) each len",
        .per_element = 12,
    },
    .{
        .name = "dict put",
        .setup = "{d} range",
        .workload = "(pop {'a 1} 'b 2 put keys len) each len",
        .per_element = 15,
    },
    .{
        .name = "dict merge",
        .setup = "{d} range",
        .workload = "(pop {'a 1} {'b 2} merge keys len) each len",
        .per_element = 15,
    },
    .{
        .name = "reshape",
        .setup = "{d} range",
        .workload = "(pop [1 2 3 4] [2 2] reshape len) each len",
        .per_element = 18,
    },
    .{
        .name = "group",
        .setup = "{d} range",
        .workload = "(pop [1 1 2] group keys len) each len",
        .per_element = 27,
    },
};

test "allocation: construction stays at its recorded floor" {
    for (construction) |case| try expectBudget(case);
}
