//! Inline control and isolated quotation-taking combinators.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const paging = @import("paging.zig");
const poll = @import("poll.zig");
const support = @import("kernel_support.zig");

const Value = value.Value;
const Header = value.ListHandle;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
const Application = machine.Application;
const ApplicationStep = machine.ApplicationStep;
const StackWindow = machine.StackWindow;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "call", .primitive = call, .effect = "quotation -- ...", .doc = "Run a quotation on the current stack. A data list pushes its elements." },
        .{ .name = "if", .primitive = ifWord, .effect = "bool then else -- ...", .doc = "Run `then` when the condition is 1, `else` when it is 0; any other condition value is `` `type ``." },
        .{ .name = "while", .primitive = whileWord, .effect = "cond body -- ...", .doc = "At the start of each iteration, run `cond` over a paging floor: it takes from the stack only what its words require. Its top result must be a 0/1 boolean; its complete stack result is discarded and what it took is restored. On 1, run `body` in place and loop. On 0, exit. Definitions, IO, and other non-stack effects from the condition survive; definition permission follows the invoking unit. Tail-call optimized." },
        .{ .name = "linrec", .primitive = linrec, .effect = "predicate base pre post -- ...", .doc = "Explicit linear recursion. At each descent, run `predicate` over a paging floor: it takes from the stack only what its words require. Its top result must be a 0/1 boolean; its complete stack result is discarded and what it took is restored. On 1, run `base`. On 0, run `pre`, recurse from `pre`'s resulting stack, then run `post`. Definitions, IO, and other non-stack effects from the predicate survive restoration; definition permission follows the invoking unit. All four quotations run in the invoking application context and communicate through ambient stack state. The recursion runs in constant space: every level applies the same quotations, so the descents whose `post` is pending are a count." },
        .{ .name = "dip", .primitive = dip, .effect = "x (q: ... -- ...) -- ... x", .doc = "Run a quotation beneath a protected top stack value: `q` runs with `x` removed, then `x` is pushed after its results. Inside `above` or `below`, a protected value taken from beneath their floor returns as the original it was, so protecting a value is not consuming it." },
        .{ .name = "dip-n", .primitive = dipN, .effect = "... (q: ... -- ...) n -- ...", .doc = "Run a quotation beneath the top `n` stack values: `q` runs with them removed, then they are pushed back in their original order after its results. `n` must be a nonnegative int, or the word fails with `` `type `` or `` `domain `` before anything is removed. `0 dip-n` is `call`, and `1 dip-n` is `dip`." },
        .{ .name = "above", .primitive = above, .effect = "... (q: ... -- ...) -- ...", .doc = "Run a quotation, then restore the values it consumed above its results, in their original order. The quotation runs on a substack that starts empty and takes operands from beneath as its words need them, so what it consumed is exactly what its words required: `1 2 (+) above` is `3 1 2`, and `1 (dup) above` is `1 1 1`. A `dip` inside returns a protected value as the original it was. The quotation cannot take values from beneath an enclosing `@attempt` or isolated application, which fail with `` `underflow `` as usual. `(q) above` leaves the quotation's results beneath the restored values; `below` leaves them on top." },
        .{ .name = "below", .primitive = below, .effect = "... (q: ... -- ...) -- ...", .doc = "Run a quotation, then restore the values it consumed below its results, in their original order: the stack is as it was, with the results on top. The quotation runs on a substack that starts empty and takes operands from beneath as its words need them, so what it consumed is exactly what its words required: `1 2 (+) below` is `1 2 3`, and `1 2 3 ((+) dip) below` is `1 2 3 3`, since a `dip` inside returns a protected value as the original it was. The quotation cannot take values from beneath an enclosing `@attempt` or isolated application, which fail with `` `underflow `` as usual." },
        .{ .name = "bi", .primitive = bi, .effect = "... p q -- ...", .doc = "Apply two quotations to the same inputs, first `p`, then `q`, leaving `p`'s results beneath `q`'s: a two-quotation `cleave`, with the same consumption rule." },
        .{ .name = "tri", .primitive = tri, .effect = "... p q r -- ...", .doc = "Apply three quotations to the same inputs in left-to-right order: a three-quotation `cleave`, with the same consumption rule." },
        .{ .name = "cleave", .primitive = cleave, .effect = "... quotations -- ...", .doc = "Apply each quotation in `quotations`, in order, to the stack as it was when the list was consumed. Each quotation consumes exactly what its words require, and its results are held aside, so every quotation starts from the same inputs and sees the stack beneath them rather than earlier results. Afterwards the inputs any quotation consumed are dropped and all the results are pushed in order. The list and each of its elements must be quotations, or the word fails with `` `type `` before any quotation runs. An empty list leaves the stack unchanged." },
        .{ .name = "times", .primitive = times, .effect = "n quotation -- ...", .doc = "Run the quotation `n` times; `n` must be a nonnegative int. Tail-call optimized." },
        .{ .name = "cond", .primitive = cond, .effect = "clauses -- ...", .doc = "The clause list is flat, nonempty, and odd: `[test action … else]`, all quotations. The whole list is validated before the first test runs (empty or even lists are `` `shape ``; a non-list or non-quotation member is `` `type ``). Each test runs over a paging floor against the stack as it was when the clause list was consumed: it takes from the stack only what its words require. Only its top result is interpreted, and it must be a 0/1 boolean. The complete test result is then discarded and what the test took is restored. The first true test selects its action; otherwise the final else runs, in either case from the original stack. Stack rollback does not roll back definitions, IO, or other non-stack effects performed by tests; definition permission follows the invoking unit." },
        .{ .name = "each", .primitive = each, .effect = "collection (a -- b) -- collection", .doc = "For a list, apply one level down the leading axis, exactly one result per element; the result specializes when rectangular. For a dictionary, apply to its values in insertion order while preserving its keys. Depth composes by nesting: `((q) each) each`. There is no collect-all map whose output length follows dynamic stack behavior: filtering is the mask idiom (or `filter`), and flat-map is `each raze`. Derived verbs come free from homoiconicity: ``((1 +) each) `inc-all def``." },
        .{ .name = "zip-with", .primitive = zipWith, .effect = "left right (a b -- c) -- list", .doc = "Zip two lists with broadcast conformability (an atom on either side extends). Each-left/each-right are `cons` compositions." },
        .{ .name = "for", .primitive = forWord, .effect = "collection (a --) --", .doc = "Apply to list elements or dictionary values in insertion order, left-to-right, collecting nothing." },
        .{ .name = "fold", .primitive = fold, .effect = "list accumulator (acc a -- acc) -- accumulator", .doc = "Reduce left-to-right from the supplied accumulator." },
        .{ .name = "fold1", .primitive = fold1, .effect = "list (acc a -- acc) -- value", .doc = "Reduce a nonempty list left to right from its first element rather than from an explicit accumulator; an empty list requires `fold`." },
        .{ .name = "lex-cmp-with", .primitive = lexCmpWith, .effect = "left right (left-element right-element -- order) -- order", .doc = "Compare two lists lexicographically with a comparator that returns −1, 0, or 1. The comparator runs only through the first differing pair; when the shared prefix is equal, the lists are ordered by length." },
        .{ .name = "scan", .primitive = scan, .effect = "list accumulator (acc a -- acc) -- list", .doc = "Like `fold` but returns every intermediate accumulator; same length as the input." },
        .{ .name = "stencil", .primitive = stencil, .effect = "list width (window -- result) -- list", .doc = "Apply to each overlapping window of a positive int width, left-to-right. A width larger than the input returns `()` without applying the quotation; zero and negative widths are `` `domain ``. The result has `max(len-width+1, 0)` elements." },
        .{ .name = "unfold", .primitive = unfold, .effect = "state (predicate: state -- bool) (step: state -- state item) -- state list", .doc = "Before every step, apply the predicate. When it returns 0, return the current state and all generated items. When it returns 1, apply the step, append the item, and continue from the returned state. The predicate is therefore always checked before the first step, and a false initial predicate returns the initial state and `()`." },
        .{ .name = "infra", .primitive = infra, .effect = "list (... -- ...) -- list", .doc = "Run the quotation with the list's elements as the entire substack; the substack that remains is the result list." },
        .{ .name = "update", .primitive = update, .effect = "collection selector (value -- value) -- collection", .doc = "Apply an isolated quotation at the selected positions. A list collection's selector pervades with the same nested shape as `at` and is processed left to right, so repeated indices observe earlier updates. A dictionary selector is one whole-value key. The entire selector is validated before the quotation is first applied; an empty selector returns the list unchanged without applying it." },
    };
    try core.installBuiltins(&definitions);
}

fn call(fiber: *Fiber) MachineError!void {
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    try fiber.callOwned(quotation.take().list);
}

fn ifWord(fiber: *Fiber) MachineError!void {
    try fiber.require(3);
    var otherwise = try fiber.popValue();
    defer otherwise.deinit();
    var then = try fiber.popValue();
    defer then.deinit();
    var predicate = try fiber.popValue();
    defer predicate.deinit();
    if (then.borrow() != .list or otherwise.borrow() != .list)
        return fiber.typeError("two quotation branches");
    const selected_then = try boolValue(fiber, &predicate);
    try fiber.callOwned(if (selected_then) then.take().list else otherwise.take().list);
}

fn whileWord(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var body = try fiber.popValue();
    defer body.deinit();
    var condition = try fiber.popValue();
    defer condition.deinit();
    if (body.borrow() != .list or condition.borrow() != .list)
        return fiber.typeError("two quotations/lists");
    const provenance_target = try fiber.applicationProvenanceTarget();
    const state = try fiber.allocator.create(WhileState);
    state.* = .{
        .condition = .init(condition.take().list),
        .body = .init(body.take().list),
        .paged = .init(.init(.discarded)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
        .provenance_target = provenance_target,
        .phase = .condition,
    };
    try fiber.beginApplication(state.application(state.condition.borrow()), .{ .paging = &state.paged.borrowMut().floor });
}

fn selectedProvenance(target: ?*const machine.ApplicationProvenanceTarget) machine.ApplicationProvenance {
    return if (target) |selected| .{ .selected_target = selected } else .boundary;
}

/// The boolean a test left for its guard.
fn popTestResult(fiber: *Fiber, paged: *paging.Region) MachineError!bool {
    var result = try paged.takeTestResult(fiber);
    defer result.deinit();
    return boolValue(fiber, &result);
}

/// Runs the work a guard's frame has in hand, or suspends the frame under a
/// driver that finishes it and resumes the frame at `pending`.
fn finishWork(
    comptime State: type,
    state: *State,
    fiber: *Fiber,
    pending: @FieldType(State, "phase"),
) MachineError!?ApplicationStep {
    if (try state.work(fiber)) return state.resumeAfter(pending);
    state.phase = pending;
    try fiber.startDriver(SuspendedWork(State){ .state = state });
    return fiber.suspendInlineApplication();
}

/// Finishes work for a suspended frame, whose application state the frame
/// owns; the frame resumes once this completes.
fn SuspendedWork(comptime State: type) type {
    return struct {
        state: *State,

        /// Names its word before it polls, so a cancellation is attributed to it.
        pub const cancellation: machine.DriverCancellation = .own;

        pub fn advance(fiber: *Fiber, self: *@This()) MachineError!machine.WorkProgress {
            fiber.active_word = self.state.word;
            try fiber.pollKernel();
            return if (try self.state.work(fiber)) .completed else .stepped;
        }
        pub const ownership: heap.DriverOwnership = .fields;
    };
}

/// One `while` loop's application state, alive for the whole loop under one
/// frame. The condition runs over a paging floor, so it takes from the stack
/// only what its words require; its result is read, its region dropped, and
/// what it paged restored, all as bounded work. The body then runs in place.
/// Only restore work the turn's budget cannot cover stands up a driver, under
/// which the loop suspends until it is done.
const WhileState = struct {
    condition: heap.Owned(*Header),
    body: heap.Owned(*Header),
    paged: heap.Owned(paging.Region),
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    provenance_target: ?*const machine.ApplicationProvenanceTarget,
    /// The quotation that last finished, or the restore a suspension completes.
    phase: enum { condition, body, restored_true, restored_false },

    fn application(self: *WhileState, quotation: *Header) Application {
        return machine.typedApplication(self, quotation, self.site, 0);
    }
    fn conditionStep(self: *WhileState) ApplicationStep {
        self.phase = .condition;
        const paged = self.paged.borrowMut();
        paged.reset();
        return .{ .apply = .{
            .quotation = self.condition.borrow(),
            .seeded = 0,
            .launch = .{ .paging = &paged.floor },
        } };
    }
    fn bodyStep(self: *WhileState) ApplicationStep {
        self.phase = .body;
        return .{ .apply = .{
            .quotation = self.body.borrow(),
            .seeded = 0,
            .provenance = selectedProvenance(self.provenance_target),
            .launch = .in_place,
        } };
    }
    fn work(self: *WhileState, fiber: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(fiber);
    }
    fn resumeAfter(self: *WhileState, finished: @FieldType(WhileState, "phase")) ?ApplicationStep {
        return switch (finished) {
            .restored_true => self.bodyStep(),
            .restored_false => null,
            .condition, .body => unreachable,
        };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *WhileState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        switch (self.phase) {
            .condition => {
                const paged = self.paged.borrowMut();
                paged.base = window.base();
                const selected = try popTestResult(fiber, paged);
                return finishWork(WhileState, self, fiber, if (selected) .restored_true else .restored_false);
            },
            .body => return self.conditionStep(),
            .restored_true, .restored_false => |finished| return self.resumeAfter(finished),
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

const TimesState = struct {
    quotation: heap.Owned(*Header),
    site: machine.ExecutionSite,
    remaining: usize,
    word: intern.TraceWord,

    fn application(self: *TimesState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.site, 0);
    }
    fn step(self: *TimesState) ApplicationStep {
        return .{ .apply = .{ .quotation = self.quotation.borrow(), .seeded = 0, .launch = .in_place } };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *TimesState,
        _: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        self.remaining -= 1;
        return if (self.remaining == 0) null else self.step();
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn times(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    var count_value = try fiber.popValue();
    defer count_value.deinit();
    if (quotation.borrow() != .list or count_value.borrow() != .int)
        return fiber.typeError("a nonnegative int and quotation");
    if (count_value.borrow().int < 0)
        return fiber.fail(.domain, "times requires a nonnegative count");
    if (count_value.borrow().int == 0) return;
    const state = try fiber.allocator.create(TimesState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .site = fiber.applicationSite(),
        .remaining = @intCast(count_value.borrow().int),
        .word = fiber.active_word,
    };
    try fiber.beginApplication(state.application(), .in_place);
}

/// The protected value rides in a continuation rather than in a capture
/// quotation composed onto `q`.
fn dip(fiber: *Fiber) MachineError!void {
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    var protected = try paging.takeProtected(fiber);
    defer protected.item.deinit();
    try startDip(fiber, &quotation, &protected);
}

/// `x quotation cons dip` without the list: the value beneath `x` is
/// protected and `x` stays on the stack for the quotation, as the first form
/// of `(x quotation...)` would have pushed it. The `cons call` and `cons dip`
/// phrases in `idioms.zig` reach this.
pub fn dipBelowHead(fiber: *Fiber) MachineError!void {
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    var head = try fiber.popValue();
    defer head.deinit();
    var protected = try paging.takeProtected(fiber);
    defer protected.item.deinit();
    try fiber.pushOwned(head.take());
    try startDip(fiber, &quotation, &protected);
}

fn startDip(fiber: *Fiber, quotation: *heap.OwnedValue, protected: *paging.Protected) MachineError!void {
    const state = try fiber.allocator.create(DipState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .protected = .init(protected.item.take()),
        .original = protected.original,
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
    };
    try fiber.beginApplication(state.application(), .in_place);
}

const DipState = struct {
    quotation: heap.Owned(*Header),
    protected: heap.Owned(Value),
    /// Whether the value came across a paging floor, so it returns as one.
    original: bool,
    site: machine.ExecutionSite,
    word: intern.TraceWord,

    fn application(self: *DipState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.site, 0);
    }

    /// The protected value returns exactly once, after the quotation's own
    /// application completes, so a failing quotation leaves it to this
    /// driver's field ownership rather than to the rolled-back stack.
    pub fn resumeApplication(
        fiber: *Fiber,
        self: *DipState,
        _: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        try paging.returnProtected(fiber, self.protected.take(), self.original);
        return null;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn dipN(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var count_value = try fiber.popValue();
    defer count_value.deinit();
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    if (count_value.borrow() != .int) return fiber.typeError("an int count");
    if (count_value.borrow().int < 0) return fiber.fail(.domain, "dip-n count must be nonnegative");
    const count: usize = @intCast(count_value.borrow().int);
    // Checked before the buffers are sized by it, and without paging.
    try paging.requireReachable(fiber, count);
    // Each allocation precedes taking the quotation, and a later failure
    // retires the earlier ones: a struct literal would leak them.
    var control = blk: {
        var protected = heap.Owned(heap.OwnedValueBuffer).init(try .init(fiber.releases, count));
        errdefer protected.deinit(fiber.releases, fiber.allocator);
        var originals: std.DynamicBitSetUnmanaged = try .initEmpty(fiber.allocator, count);
        errdefer originals.deinit(fiber.allocator);
        break :blk heap.Owned(DipControl).init(.{
            .quotation = .init(quotation.take().list),
            .protected = protected,
            .originals = originals,
            .count = count,
            .site = fiber.applicationSite(),
            .word = fiber.active_word,
        });
    };
    defer control.deinit(fiber.releases, fiber.allocator);
    switch (try control.borrowMut().advance(fiber)) {
        .finished => unreachable,
        .launch => try launchDipN(fiber, &control),
        .pending => try fiber.startDriver(DipDriver{ .control = .init(control.take()) }),
    }
}

fn launchDipN(fiber: *Fiber, control: *heap.Owned(DipControl)) MachineError!void {
    const state = try fiber.allocator.create(DipNState);
    state.* = .{ .control = .init(control.take()) };
    try fiber.beginApplication(state.application(), .in_place);
}

/// `dip-n` takes its `count` protected values off the stack one at a time,
/// each as `dip` would, runs the quotation, and returns them in their
/// original order. Both phases are user-sized and advance only as far as the
/// turn's budget allows. The values are retained, so a symbol stays a value
/// rather than becoming code.
const DipControl = struct {
    quotation: heap.Owned(*Header),
    /// The protected values, the top of the stack first.
    protected: heap.Owned(heap.OwnedValueBuffer),
    /// Which of them are originals of a paging floor, by `protected` index.
    originals: std.DynamicBitSetUnmanaged,
    count: usize,
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    index: usize = 0,
    phase: enum { take, run, restore } = .take,

    const Progress = union(enum) { pending, launch, finished };

    fn advance(self: *DipControl, fiber: *Fiber) MachineError!Progress {
        const work = fiber.workBudget();
        while (true) switch (self.phase) {
            .take => {
                const end = self.index + work.take(self.count - self.index);
                while (self.index != end) : (self.index += 1) {
                    var taken = try paging.takeProtected(fiber);
                    self.protected.borrowMut().appendOwned(taken.item.take());
                    if (taken.original) self.originals.set(self.index);
                }
                if (self.index != self.count) return .pending;
                self.phase = .run;
                return .launch;
            },
            .run => {
                self.index = self.count;
                self.phase = .restore;
            },
            .restore => {
                const end = self.index - work.take(self.index);
                while (self.index != end) {
                    self.index -= 1;
                    const item = self.protected.borrow().values()[self.index];
                    heap.retainValue(item);
                    try paging.returnProtected(fiber, item, self.originals.isSet(self.index));
                }
                if (self.index != 0) return .pending;
                return .finished;
            },
        };
    }

    pub fn retire(self: *DipControl, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.originals.deinit(allocator);
        self.protected.deinit(releases, allocator);
        self.quotation.deinit(releases, allocator);
    }
};

const DipDriver = struct {
    control: heap.Owned(DipControl),

    /// Names its word before it polls, so a cancellation is attributed to it.
    pub const cancellation: machine.DriverCancellation = .own;

    pub fn advance(fiber: *Fiber, self: *DipDriver) MachineError!machine.WorkProgress {
        fiber.active_word = self.control.borrow().word;
        try fiber.pollKernel();
        const progress = try self.control.borrowMut().advance(fiber);
        if (progress == .pending) return .stepped;
        var control = heap.Owned(DipControl).init(self.control.take());
        defer control.deinit(fiber.releases, fiber.allocator);
        fiber.retireDriver(self);
        switch (progress) {
            .launch => try launchDipN(fiber, &control),
            .finished, .pending => {},
        }
        return .detached;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

/// The finished quotation returns the protected values from the same
/// continuation; only a restore the turn cannot finish hands the control
/// back to a driver.
const DipNState = struct {
    control: heap.Owned(DipControl),

    fn application(self: *DipNState) Application {
        const control = self.control.borrow();
        return machine.typedApplication(self, control.quotation.borrow(), control.site, 0);
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *DipNState,
        _: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.control.borrow().word;
        fiber.chargeContinuationStep();
        switch (try self.control.borrowMut().advance(fiber)) {
            .finished => return null,
            .launch => unreachable,
            .pending => {
                try fiber.startDriver(DipDriver{ .control = .init(self.control.take()) });
                return null;
            },
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn above(fiber: *Fiber) MachineError!void {
    return startPaged(fiber, .above);
}
fn below(fiber: *Fiber) MachineError!void {
    return startPaged(fiber, .below);
}
fn startPaged(fiber: *Fiber, placement: paging.Placement) MachineError!void {
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    const state = try fiber.allocator.create(PagedState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .paged = .init(.init(placement)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
    };
    try fiber.beginApplication(state.application(), .{ .paging = &state.paged.borrowMut().floor });
}

const PagedState = struct {
    quotation: heap.Owned(*Header),
    paged: heap.Owned(paging.Region),
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    phase: enum { run, restored } = .run,

    fn application(self: *PagedState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.site, 0);
    }
    fn work(self: *PagedState, fiber: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(fiber);
    }
    fn resumeAfter(_: *PagedState, _: @FieldType(PagedState, "phase")) ?ApplicationStep {
        return null;
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *PagedState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        switch (self.phase) {
            .run => {
                self.paged.borrowMut().base = window.base();
                return finishWork(PagedState, self, fiber, .restored);
            },
            .restored => return null,
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn cleave(fiber: *Fiber) MachineError!void {
    var quotations = try fiber.popValue();
    defer quotations.deinit();
    if (quotations.borrow() != .list) return fiber.typeError("a list of quotations");
    return startCleave(fiber, .{ .list = .init(quotations.take()) }, .validate);
}
fn bi(fiber: *Fiber) MachineError!void {
    return cleaveFixed(fiber, 2);
}
fn tri(fiber: *Fiber) MachineError!void {
    return cleaveFixed(fiber, 3);
}
/// `bi` and `tri` take their quotations straight off the stack, already
/// validated, so no list is built and no validation phase runs.
fn cleaveFixed(fiber: *Fiber, count: usize) MachineError!void {
    try fiber.require(count);
    var fixed: CleaveQuotations.Fixed = .{};
    errdefer fixed.retire(fiber.releases);
    for (0..count) |offset| {
        const item = fiber.visibleOperandBorrowed(fiber.available() - count + offset);
        if (item != .list) return fiber.typeError("quotations");
        heap.incRef(item.list);
        fixed.items[offset] = item.list;
        fixed.count += 1;
    }
    fiber.discard(count);
    return startCleave(fiber, .{ .fixed = fixed }, .run);
}
fn startCleave(
    fiber: *Fiber,
    quotations: CleaveQuotations,
    phase: @FieldType(CleaveState, "phase"),
) MachineError!void {
    var owned_quotations = heap.Owned(CleaveQuotations).init(quotations);
    const state = fiber.allocator.create(CleaveState) catch |err| {
        owned_quotations.deinit(fiber.releases, fiber.allocator);
        return err;
    };
    state.* = .{
        .quotations = .init(owned_quotations.take()),
        .paged = .init(.init(.collected)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
        .phase = phase,
    };
    var owned = heap.Owned(*CleaveState).init(state);
    // Validation runs where the word is invoked when the turn's budget
    // covers it, so a small cleave launches without installing a driver.
    if (phase == .validate and !(state.work(fiber) catch |err| {
        owned.deinit(fiber.releases, fiber.allocator);
        return err;
    })) return fiber.startDriver(CleaveDriver{ .state = owned });
    try launchCleave(fiber, &owned);
}

fn launchCleave(fiber: *Fiber, owned: *heap.Owned(*CleaveState)) MachineError!void {
    const state = owned.borrow();
    if (state.phase == .done) return owned.deinit(fiber.releases, fiber.allocator);
    state.running = true;
    try fiber.beginApplication(owned.take().application(state.quotation()), .{ .paging = &state.paged.borrowMut().floor });
}

/// Finishes a cleave's validation when the turn ran out, then launches it.
const CleaveDriver = struct {
    state: heap.Owned(*CleaveState),

    /// Names its word before it polls, so a cancellation is attributed to it.
    pub const cancellation: machine.DriverCancellation = .own;

    pub fn advance(fiber: *Fiber, self: *CleaveDriver) MachineError!machine.WorkProgress {
        fiber.active_word = self.state.borrow().word;
        try fiber.pollKernel();
        if (!try self.state.borrow().work(fiber)) return .stepped;
        var owned = heap.Owned(*CleaveState).init(self.state.take());
        fiber.retireDriver(self);
        try launchCleave(fiber, &owned);
        return .detached;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

/// The quotations a cleave applies: a list the program built, or the two or
/// three `bi` and `tri` took off the stack.
const CleaveQuotations = union(enum) {
    list: heap.Owned(Value),
    fixed: Fixed,

    const Fixed = struct {
        items: [3]?*Header = @splat(null),
        count: usize = 0,

        fn retire(self: *Fixed, releases: *heap.ReleaseDomain) void {
            for (self.items[0..self.count]) |quotation| releases.releaseHeader(quotation.?);
            self.count = 0;
        }
    };

    fn count(self: *const CleaveQuotations) usize {
        return switch (self.*) {
            .list => |quotations| @intCast(quotations.borrow().list.length()),
            .fixed => |fixed| fixed.count,
        };
    }
    fn at(self: *const CleaveQuotations, index: usize) *Header {
        return switch (self.*) {
            .list => |quotations| list.atUnchecked(quotations.borrow(), index).list,
            .fixed => |fixed| fixed.items[index].?,
        };
    }
    fn isQuotation(self: *const CleaveQuotations, index: usize) bool {
        return switch (self.*) {
            .list => |quotations| list.atUnchecked(quotations.borrow(), index) == .list,
            .fixed => true,
        };
    }

    pub fn retire(self: *CleaveQuotations, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |*quotations| quotations.deinit(releases, allocator),
            .fixed => |*fixed| fixed.retire(releases),
        }
    }
};

/// A cleave validates every quotation and then runs each over a paging
/// floor above the inputs, so each consumes exactly what its words require.
/// A quotation's results move into the control's buffer and its paged
/// inputs come back, so the next quotation starts from the same inputs; the
/// inputs any quotation consumed are dropped at the end and the results put
/// back in order. Each phase is user-sized and advances only as far as the
/// turn's budget allows, and the inputs are retained values, so a symbol
/// input stays a value rather than becoming code.
const CleaveState = struct {
    quotations: heap.Owned(CleaveQuotations),
    paged: heap.Owned(paging.Region),
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    /// The most inputs any quotation consumed: consumption is a prefix from
    /// the top, so the sets nest.
    consumed: usize = 0,
    /// The quotation running or next to run.
    next: usize = 0,
    index: usize = 0,
    pushed: usize = 0,
    /// A quotation was launched and has not yet returned. A resume with none
    /// outstanding is a suspended restore, drop, or push finishing.
    running: bool = false,
    phase: enum { validate, run, restored, drop, push, done } = .validate,

    fn count(self: *const CleaveState) usize {
        return self.quotations.borrow().count();
    }
    fn quotation(self: *const CleaveState) *Header {
        return self.quotations.borrow().at(self.next);
    }
    fn application(self: *CleaveState, code: *Header) Application {
        return machine.typedApplication(self, code, self.site, 0);
    }

    /// Advances the work in hand; true once the next quotation may launch
    /// or the cleave is done.
    fn work(self: *CleaveState, fiber: *Fiber) MachineError!bool {
        const work_budget = fiber.workBudget();
        while (true) switch (self.phase) {
            .validate => {
                const quotations = self.quotations.borrow();
                const total = self.count();
                const end = self.index + work_budget.take(total - self.index);
                while (self.index != end) : (self.index += 1) {
                    if (!quotations.isQuotation(self.index))
                        return fiber.typeError("a list of quotations");
                }
                if (self.index != total) return false;
                self.phase = if (total == 0) .done else .run;
                return true;
            },
            .restored => {
                const paged = self.paged.borrowMut();
                if (!try paged.advance(fiber)) return false;
                self.consumed = @max(self.consumed, paged.restored);
                self.next += 1;
                if (self.next != self.count()) {
                    self.phase = .run;
                    return true;
                }
                self.index = 0;
                self.phase = .drop;
            },
            .drop => {
                const granted = work_budget.take(self.consumed - self.index);
                fiber.discard(granted);
                self.index += granted;
                if (self.index != self.consumed) return false;
                self.phase = .push;
            },
            .push => {
                const results = self.paged.borrowMut().results.items();
                const end = self.pushed + work_budget.take(results.len - self.pushed);
                while (self.pushed != end) : (self.pushed += 1) try fiber.pushOwned(results[self.pushed]);
                if (self.pushed != results.len) return false;
                self.paged.borrowMut().results.clearRetainingCapacity();
                self.phase = .done;
                return true;
            },
            .run, .done => unreachable,
        };
    }
    fn resumeAfter(self: *CleaveState, _: @FieldType(CleaveState, "phase")) ?ApplicationStep {
        if (self.phase == .done) return null;
        std.debug.assert(self.phase == .run);
        self.running = true;
        const paged = self.paged.borrowMut();
        paged.reset();
        return .{ .apply = .{
            .quotation = self.quotation(),
            .seeded = 0,
            .launch = .{ .paging = &paged.floor },
        } };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *CleaveState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        if (self.running) {
            self.running = false;
            self.paged.borrowMut().base = window.base();
            self.phase = .restored;
            // `work` leaves its own progress in `phase`; `finishWork` would
            // reset it, so a suspension keeps it here.
            if (try self.work(fiber)) return self.resumeAfter(self.phase);
            try fiber.startDriver(SuspendedWork(CleaveState){ .state = self });
            return fiber.suspendInlineApplication();
        }
        // A suspended restore, drop, or push finished under its driver.
        return self.resumeAfter(self.phase);
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

/// One `cond`'s application state, alive for the whole word under one frame.
/// Each test runs over a paging floor, its result is read, its region
/// dropped, and what it paged restored; the selected action then runs in
/// place.
const CondState = struct {
    clauses: heap.Owned(Value),
    paged: heap.Owned(paging.Region),
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    provenance_target: ?*const machine.ApplicationProvenanceTarget,
    pair_index: usize = 0,
    selected: bool = false,
    phase: enum { predicate, action, restored } = .predicate,

    fn count(self: *const CondState) usize {
        return @intCast(self.clauses.borrow().list.length());
    }
    fn clause(self: *const CondState, index: usize) *Header {
        return list.atUnchecked(self.clauses.borrow(), index).list;
    }
    fn application(self: *CondState, code: *Header) Application {
        var launched = machine.typedApplication(self, code, self.site, 0);
        if (self.phase == .action) launched.provenance = selectedProvenance(self.provenance_target);
        return launched;
    }
    fn work(self: *CondState, fiber: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(fiber);
    }
    /// The action a true test selected, the else when the tests ran out, or
    /// the next test.
    fn resumeAfter(self: *CondState, _: @FieldType(CondState, "phase")) ?ApplicationStep {
        if (self.selected) return self.actionStep(self.pair_index + 1);
        self.pair_index += 2;
        if (self.pair_index + 1 >= self.count()) return self.actionStep(self.count() - 1);
        self.phase = .predicate;
        const paged = self.paged.borrowMut();
        paged.reset();
        return .{ .apply = .{
            .quotation = self.clause(self.pair_index),
            .seeded = 0,
            .launch = .{ .paging = &paged.floor },
        } };
    }
    fn actionStep(self: *CondState, index: usize) ApplicationStep {
        self.phase = .action;
        return .{ .apply = .{
            .quotation = self.clause(index),
            .seeded = 0,
            .provenance = selectedProvenance(self.provenance_target),
            .launch = .in_place,
        } };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *CondState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        switch (self.phase) {
            .predicate => {
                const paged = self.paged.borrowMut();
                paged.base = window.base();
                self.selected = try popTestResult(fiber, paged);
                return finishWork(CondState, self, fiber, .restored);
            },
            // A `cond` action is the clause's whole result.
            .action => return null,
            .restored => return self.resumeAfter(.restored),
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn cond(fiber: *Fiber) MachineError!void {
    var clauses = try fiber.popValue();
    defer clauses.deinit();
    if (clauses.borrow() != .list) {
        return fiber.typeError("a clause list");
    }
    const count: usize = @intCast(clauses.borrow().list.length());
    if (count == 0 or count % 2 == 0) {
        return fiber.fail(.shape, "cond requires a nonempty odd clause list ending in else");
    }
    try fiber.startDriver(CondDriver{
        .clauses = .init(clauses.take()),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
        .provenance_target = try fiber.applicationProvenanceTarget(),
    });
}

/// Validates every clause as bounded work, then runs the first test, or the
/// lone else.
const CondDriver = struct {
    clauses: heap.Owned(Value),
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    provenance_target: ?*const machine.ApplicationProvenanceTarget,
    index: usize = 0,

    pub fn advance(fiber: *Fiber, self: *CondDriver) MachineError!machine.WorkProgress {
        const clauses = self.clauses.borrow();
        const count: usize = @intCast(clauses.list.length());
        const end = self.index + fiber.workBudget().take(count - self.index);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(clauses, self.index) != .list)
                return fiber.typeError("quotation clauses and else");
        }
        if (self.index != count) return .stepped;
        const state = try fiber.allocator.create(CondState);
        state.* = .{
            .clauses = .init(self.clauses.take()),
            .paged = .init(.init(.discarded)),
            .site = self.site,
            .word = self.word,
            .provenance_target = self.provenance_target,
            .phase = if (count == 1) .action else .predicate,
        };
        fiber.retireDriver(self);
        const first = state.clause(0);
        if (count == 1) {
            try fiber.beginApplication(state.application(first), .in_place);
        } else {
            try fiber.beginApplication(state.application(first), .{ .paging = &state.paged.borrowMut().floor });
        }
        return .detached;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

/// One `linrec`'s application state, alive for the whole recursion under one
/// frame. Every level applies the same four quotations, so the recursion is
/// a sequence `pre … pre base post … post` and the levels pending `post` are
/// a count. Each predicate runs over a paging floor, its result is read, its
/// region dropped, and what it paged restored; the branches run in place.
const LinrecState = struct {
    predicate: heap.Owned(*Header),
    base: heap.Owned(*Header),
    pre: heap.Owned(*Header),
    post: heap.Owned(*Header),
    paged: heap.Owned(paging.Region),
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    provenance_target: ?*const machine.ApplicationProvenanceTarget,
    /// Descents whose `post` has yet to run.
    depth: usize = 0,
    selected: bool = false,
    phase: enum { predicate, base, pre, post, restored } = .predicate,

    fn application(self: *LinrecState) Application {
        return machine.typedApplication(self, self.predicate.borrow(), self.site, 0);
    }
    fn work(self: *LinrecState, fiber: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(fiber);
    }
    fn resumeAfter(self: *LinrecState, _: @FieldType(LinrecState, "phase")) ?ApplicationStep {
        return if (self.selected) self.branchStep(.base) else self.branchStep(.pre);
    }
    fn predicateStep(self: *LinrecState) ApplicationStep {
        self.phase = .predicate;
        const paged = self.paged.borrowMut();
        paged.reset();
        return .{ .apply = .{
            .quotation = self.predicate.borrow(),
            .seeded = 0,
            .launch = .{ .paging = &paged.floor },
        } };
    }
    fn branchStep(self: *LinrecState, branch: @FieldType(LinrecState, "phase")) ApplicationStep {
        self.phase = branch;
        return .{ .apply = .{
            .quotation = switch (branch) {
                .base => self.base.borrow(),
                .pre => self.pre.borrow(),
                .post => self.post.borrow(),
                .predicate, .restored => unreachable,
            },
            .seeded = 0,
            .provenance = selectedProvenance(self.provenance_target),
            .launch = .in_place,
        } };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *LinrecState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        switch (self.phase) {
            .predicate => {
                const paged = self.paged.borrowMut();
                paged.base = window.base();
                self.selected = try popTestResult(fiber, paged);
                return finishWork(LinrecState, self, fiber, .restored);
            },
            .restored => return self.resumeAfter(.restored),
            .pre => {
                self.depth += 1;
                return self.predicateStep();
            },
            .base, .post => {
                if (self.depth == 0) return null;
                self.depth -= 1;
                return self.branchStep(.post);
            },
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn linrec(fiber: *Fiber) MachineError!void {
    try fiber.require(4);
    var post = try fiber.popValue();
    defer post.deinit();
    var pre = try fiber.popValue();
    defer pre.deinit();
    var base = try fiber.popValue();
    defer base.deinit();
    var predicate = try fiber.popValue();
    defer predicate.deinit();
    if (predicate.borrow() != .list or base.borrow() != .list or
        pre.borrow() != .list or post.borrow() != .list)
    {
        return fiber.typeError("four quotations/lists");
    }
    const provenance_target = try fiber.applicationProvenanceTarget();
    const state = try fiber.allocator.create(LinrecState);
    state.* = .{
        .predicate = .init(predicate.take().list),
        .base = .init(base.take().list),
        .pre = .init(pre.take().list),
        .post = .init(post.take().list),
        .paged = .init(.init(.discarded)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
        .provenance_target = provenance_target,
    };
    try fiber.beginApplication(state.application(), .{ .paging = &state.paged.borrowMut().floor });
}

const IterationKind = enum { each, zip_with, for_word, fold, scan, lex_cmp, infra };
const IterationState = struct {
    kind: IterationKind,
    left: heap.Owned(Value),
    right: ?heap.Owned(Value),
    quotation: heap.Owned(*Header),
    expected: ?heap.Owned(Value),
    results: ?heap.Owned(heap.OwnedValueBuffer) = null,
    site: machine.ExecutionSite,
    index: usize = 0,
    count: usize,
    word: intern.TraceWord,
    /// An iteration over a finite collection is atomic under its bindings.
    plan: ?heap.Owned(machine.ResolutionPlan) = null,

    fn application(self: *IterationState, seeded: u32) Application {
        var application_value = machine.typedApplication(self, self.quotation.borrow(), self.site, seeded);
        if (self.plan) |*plan| application_value.plan = plan.borrowMut();
        return application_value;
    }
    fn step(self: *IterationState, seeded: u32) ApplicationStep {
        return .{ .apply = .{ .quotation = self.quotation.borrow(), .seeded = seeded, .launch = .isolated } };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *IterationState,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        const base: usize = window.base();
        const observed = window.observed(fiber.stack.items.len) orelse
            return fiber.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{
                    .seeded = 0,
                    .expected = switch (self.kind) {
                        .each, .zip_with, .fold, .scan, .lex_cmp => 1,
                        .for_word => 0,
                        .infra => unreachable,
                    },
                    .observed = 0,
                },
                self.index,
            );
        return switch (self.kind) {
            .each, .zip_with => self.resumeCollect(fiber, site, observed),
            .for_word => self.resumeFor(fiber, site, observed),
            .fold, .scan => self.resumeFold(fiber, site, observed),
            .lex_cmp => self.resumeLexCompare(fiber, site, observed),
            .infra => resumeInfra(fiber, base),
        };
    }

    fn resumeCollect(
        self: *IterationState,
        fiber: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        const seeded: usize = if (self.kind == .each) 1 else 2;
        if (observed != 1) {
            return fiber.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = seeded, .expected = 1, .observed = observed },
                self.index,
            );
        }
        var result = try fiber.popDatum();
        self.results.?.borrowMut().appendOwned(result.take());
        self.index += 1;
        if (self.index == self.count) {
            try self.installCollected(fiber);
            return null;
        }
        try self.pushInputs(fiber);
        return self.step(@intCast(seeded));
    }

    fn resumeFor(
        self: *IterationState,
        fiber: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 0) {
            return fiber.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = 1, .expected = 0, .observed = observed },
                self.index,
            );
        }
        self.index += 1;
        if (self.index == self.count) return null;
        try self.pushInputs(fiber);
        return self.step(1);
    }

    fn resumeFold(
        self: *IterationState,
        fiber: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 1) {
            return fiber.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = 2, .expected = 1, .observed = observed },
                self.index,
            );
        }
        var accumulator = try fiber.popValue();
        defer accumulator.deinit();
        const accumulator_value = accumulator.borrow();
        if (self.kind == .scan) self.results.?.borrowMut().appendOwned(value.datum(accumulator.take()));
        self.index += 1;
        if (self.index == self.count) {
            if (self.kind == .scan) {
                try self.installCollected(fiber);
            } else {
                try fiber.pushOwned(accumulator.take());
            }
            return null;
        }
        if (self.kind == .scan) {
            try fiber.pushBorrowed(accumulator_value);
        } else {
            try fiber.pushOwned(accumulator.take());
        }
        try fiber.pushBorrowed(list.atUnchecked(self.left.borrow(), self.index));
        return self.step(2);
    }

    /// A comparator's 0 moves to the next pair; any other int is the order.
    /// A shared prefix that is equal throughout orders by length.
    fn resumeLexCompare(
        self: *IterationState,
        fiber: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 1) {
            return fiber.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = 2, .expected = 1, .observed = observed },
                self.index,
            );
        }
        var result = try fiber.popValue();
        defer result.deinit();
        if (result.borrow() != .int) return fiber.typeError("an int comparator result");
        if (result.borrow().int != 0) {
            try fiber.pushOwned(result.take());
            return null;
        }
        self.index += 1;
        if (self.index == self.count) {
            try pushLengthOrder(fiber, self.left.borrow(), self.right.?.borrow());
            return null;
        }
        try self.pushInputs(fiber);
        return self.step(2);
    }

    fn resumeInfra(fiber: *Fiber, base: usize) MachineError!?ApplicationStep {
        try InfraResultDriver.install(fiber, base);
        return null;
    }

    fn installCollected(self: *IterationState, fiber: *Fiber) error{OutOfMemory}!void {
        const values = self.results.?.take();
        self.results = null;
        try fiber.startDriver(CollectedDriver{
            .materializer = .init(.init(fiber.allocator, values.values())),
            .values = .init(values),
        });
    }

    fn pushInputs(self: *IterationState, fiber: *Fiber) MachineError!void {
        const left = self.left.borrow();
        try fiber.pushBorrowed(if (self.kind == .for_word and left == .dict)
            dict.valueAt(left.dict, self.index)
        else
            inputAt(left, self.index));
        if (self.kind == .zip_with or self.kind == .lex_cmp) try fiber.pushBorrowed(inputAt(
            self.right.?.borrow(),
            self.index,
        ));
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const UpdatePolicy = enum { core_selector, dictionary_key_list };
const UpdateMode = enum { list_selector, dictionary_key, dictionary_key_list };
const UpdatePhase = enum {
    count_positions,
    fill_positions,
    find_positions,
    copy_values,
    apply,
    fill_pairs,
    materialize_list,
    materialize_dict,
};

const UpdateState = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    mode: UpdateMode,
    collection: heap.Owned(Value),
    selector: heap.Owned(Value),
    quotation: heap.Owned(*Header),
    expected: heap.Owned(Value),
    values: heap.Owned(heap.OwnedValueBuffer),
    positions: ?heap.Owned([]usize) = null,
    pairs: ?heap.Owned([]dict.Pair) = null,
    selector_cursor: ?heap.Owned(support.PervasiveSelectorCursor) = null,
    finder: ?heap.Owned(dict.FindCursor) = null,
    requested_key: ?Value = null,
    list_materializer: ?heap.Owned(list.ValueMaterializer) = null,
    dict_materializer: ?heap.Owned(dict.Materializer) = null,
    phase: UpdatePhase,
    position_count: usize = 0,
    position_index: usize = 0,
    copy_index: usize = 0,
    application_index: usize = 0,
    site: machine.ExecutionSite,
    word: intern.TraceWord,
};

const UpdateApplication = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: heap.Owned(*UpdateState),

    fn application(self: *UpdateApplication) Application {
        const state = self.state.borrow();
        return machine.typedApplication(self, state.quotation.borrow(), state.site, 1);
    }

    fn step(self: *UpdateApplication) ApplicationStep {
        return .{ .apply = .{
            .quotation = self.state.borrow().quotation.borrow(),
            .seeded = 1,
            .launch = .isolated,
        } };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *UpdateApplication,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        const state = self.state.borrow();
        fiber.active_word = state.word;
        fiber.chargeContinuationStep();
        const observed = window.observed(fiber.stack.items.len) orelse
            return fiber.applicationContractError(
                site,
                state.quotation.borrow(),
                state.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = 0 },
                state.application_index,
            );
        if (observed != 1)
            return fiber.applicationContractError(
                site,
                state.quotation.borrow(),
                state.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = observed },
                state.application_index,
            );
        var result = try fiber.popValue();
        state.values.borrowMut().replaceOwned(
            state.positions.?.borrow()[state.application_index],
            result.take(),
        );
        state.application_index += 1;
        if (state.application_index != state.positions.?.borrow().len) {
            try fiber.pushBorrowed(state.values.borrow().values()[
                state.positions.?.borrow()[state.application_index]
            ]);
            return self.step();
        }
        if (state.mode != .list_selector) state.copy_index = 0;
        state.phase = if (state.mode == .list_selector) .materialize_list else .fill_pairs;
        try fiber.startDriver(UpdateWorkDriver{ .state = .init(self.state.take()) });
        return null;
    }
};

const UpdateWorkDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: heap.Owned(*UpdateState),

    fn launchApplication(
        fiber: *Fiber,
        self: *UpdateWorkDriver,
    ) MachineError!machine.WorkProgress {
        const state = self.state.borrow();
        if (state.positions.?.borrow().len == 0)
            return .{ .output = state.collection.take() };
        var stack = try fiber.reserveStack(1);
        stack.pushBorrowed(state.values.borrow().values()[state.positions.?.borrow()[0]]);
        state.phase = .apply;
        const application_state = try fiber.allocator.create(UpdateApplication);
        application_state.* = .{ .state = .init(self.state.take()) };
        try fiber.beginApplication(application_state.application(), .isolated);
        return .completed;
    }

    fn listPosition(fiber: *Fiber, state: *const UpdateState, selector: Value) MachineError!usize {
        if (selector != .int) return fiber.typeError("an integer list index");
        if (selector.int < 0) return fiber.fail(.domain, "update index is negative");
        const position = std.math.cast(usize, selector.int) orelse
            return fiber.fail(.domain, "update index is out of bounds");
        if (position >= state.collection.borrow().list.length())
            return fiber.fail(.domain, "update index is out of bounds");
        return position;
    }

    /// Names its word before it polls, so a cancellation is attributed to it.
    pub const cancellation: machine.DriverCancellation = .own;

    pub fn advance(fiber: *Fiber, self: *UpdateWorkDriver) MachineError!machine.WorkProgress {
        const state = self.state.borrow();
        fiber.active_word = state.word;
        try fiber.pollKernel();
        const work = fiber.workBudget();
        while (!work.exhausted()) switch (state.phase) {
            .count_positions => {
                const progress = try state.selector_cursor.?.borrowMut().advanceOne();
                _ = work.spend();
                switch (progress) {
                    .pending => {},
                    .depth_exceeded => return fiber.fail(
                        .domain,
                        "update selector nesting exceeds 256 levels",
                    ),
                    .leaf => |selector| {
                        if (state.mode == .list_selector)
                            _ = try listPosition(fiber, state, selector);
                        state.position_count += 1;
                    },
                    .complete => {
                        state.selector_cursor.?.deinit(fiber.releases, fiber.allocator);
                        state.selector_cursor = null;
                        state.positions = .init(try fiber.allocator.alloc(usize, state.position_count));
                        state.selector_cursor = .init(try support.PervasiveSelectorCursor.init(
                            fiber.allocator,
                            state.selector.borrow(),
                        ));
                        state.phase = if (state.mode == .list_selector) .fill_positions else .find_positions;
                    },
                }
            },
            .fill_positions => {
                const progress = try state.selector_cursor.?.borrowMut().advanceOne();
                _ = work.spend();
                switch (progress) {
                    .pending => {},
                    .depth_exceeded => return fiber.fail(.domain, "update selector nesting exceeds 256 levels"),
                    .leaf => |selector| {
                        state.positions.?.borrow()[state.position_index] =
                            try listPosition(fiber, state, selector);
                        state.position_index += 1;
                    },
                    .complete => {
                        state.selector_cursor.?.deinit(fiber.releases, fiber.allocator);
                        state.selector_cursor = null;
                        state.phase = .copy_values;
                    },
                }
            },
            .find_positions => {
                const positions = state.positions.?.borrow();
                if (state.finder == null) {
                    if (state.position_index == positions.len) {
                        state.phase = .copy_values;
                        continue;
                    }
                    state.requested_key = if (state.mode == .dictionary_key_list)
                        list.atUnchecked(state.selector.borrow(), state.position_index)
                    else
                        state.selector.borrow();
                    state.finder = .init(dict.FindCursor.initHeader(
                        fiber.allocator,
                        state.collection.borrow().dict,
                        state.requested_key.?,
                    ));
                }
                if (work.exhausted()) return .stepped;
                const progress = try state.finder.?.borrowMut().advance(work);
                _ = work.spend();
                switch (progress) {
                    .pending => {},
                    .complete => |found| {
                        if (found == null)
                            return fiber.fail(.domain, "update could not find the dict key");
                        positions[state.position_index] = state.finder.?.borrow().foundIndex().?;
                        state.finder.?.deinit(fiber.releases, fiber.allocator);
                        state.finder = null;
                        state.requested_key = null;
                        state.position_index += 1;
                    },
                }
            },
            .copy_values => {
                const count = state.values.borrow().capacity();
                if (state.copy_index == count) return launchApplication(fiber, self);
                state.values.borrowMut().appendBorrowed(if (state.mode == .list_selector)
                    list.atUnchecked(state.collection.borrow(), state.copy_index)
                else
                    dict.valueAt(state.collection.borrow().dict, state.copy_index));
                state.copy_index += 1;
                _ = work.spend();
            },
            .apply => unreachable,
            .fill_pairs => {
                const pairs = state.pairs.?.borrow();
                if (state.copy_index == pairs.len) {
                    state.dict_materializer = .init(try dict.Materializer.init(
                        fiber.allocator,
                        pairs,
                        false,
                    ));
                    state.phase = .materialize_dict;
                    continue;
                }
                pairs[state.copy_index] = .{
                    dict.keyAt(state.collection.borrow().dict, state.copy_index),
                    state.values.borrow().values()[state.copy_index],
                };
                state.copy_index += 1;
                _ = work.spend();
            },
            .materialize_list => {
                if (state.list_materializer == null)
                    state.list_materializer = .init(.init(
                        fiber.allocator,
                        state.values.borrow().values(),
                    ));
                return switch (try state.list_materializer.?.borrowMut().advance(work)) {
                    .pending => .stepped,
                    .complete => |result| completed: {
                        state.list_materializer.?.deinit(
                            fiber.releases,
                            fiber.allocator,
                        );
                        state.list_materializer = null;
                        break :completed .{ .output = result };
                    },
                };
            },
            .materialize_dict => return switch (try state.dict_materializer.?.borrowMut().advance(work)) {
                .pending => .stepped,
                .duplicate_key => unreachable,
                .complete => |result| completed: {
                    state.dict_materializer.?.borrowMut().deinit();
                    state.dict_materializer = null;
                    break :completed .{ .output = result };
                },
            },
        };
        return .stepped;
    }
};

fn update(fiber: *Fiber) MachineError!void {
    return startUpdate(fiber, .core_selector);
}

pub fn updateDictKeysForModule(fiber: *Fiber) MachineError!void {
    return startUpdate(fiber, .dictionary_key_list);
}

fn startUpdate(fiber: *Fiber, policy: UpdatePolicy) MachineError!void {
    try fiber.require(3);
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    var selector = try fiber.popValue();
    defer selector.deinit();
    var collection = try fiber.popValue();
    defer collection.deinit();

    return startUpdateOwned(
        fiber,
        policy,
        collection.take(),
        selector.take(),
        quotation.take(),
    );
}

fn startUpdateOwned(
    fiber: *Fiber,
    policy: UpdatePolicy,
    collection_value: Value,
    selector_value: Value,
    quotation_value: Value,
) MachineError!void {
    var quotation = heap.OwnedValue.init(fiber.releases, quotation_value);
    defer quotation.deinit();
    var selector = heap.OwnedValue.init(fiber.releases, selector_value);
    defer selector.deinit();
    var collection = heap.OwnedValue.init(fiber.releases, collection_value);
    defer collection.deinit();

    const mode: UpdateMode = switch (collection.borrow()) {
        .list => if (policy == .core_selector) .list_selector else return fiber.typeError("a dict"),
        .dict => switch (policy) {
            .core_selector => .dictionary_key,
            .dictionary_key_list => .dictionary_key_list,
        },
        else => return fiber.typeError(if (policy == .core_selector) "a list or dict" else "a dict"),
    };
    if (policy != .core_selector and selector.borrow() != .list)
        return fiber.typeError("a dictionary selector list");

    const collection_count: usize = switch (mode) {
        .list_selector => @intCast(collection.borrow().list.length()),
        .dictionary_key, .dictionary_key_list => @intCast(collection.borrow().dict.length()),
    };
    var values = try heap.OwnedValueBuffer.init(fiber.releases, collection_count);
    defer values.deinit();
    var expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "value", "--", "value" }),
    );
    defer expected.deinit();
    const initial_phase: UpdatePhase = switch (mode) {
        .list_selector => if (selector.borrow() == .list) .count_positions else .copy_values,
        .dictionary_key => .find_positions,
        .dictionary_key_list => .find_positions,
    };

    const state = try fiber.allocator.create(UpdateState);
    var state_owner: ?*UpdateState = state;
    errdefer if (state_owner) |owned| heap.destroyDriver(
        fiber.releases,
        fiber.allocator,
        owned,
    );
    state.* = .{
        .mode = mode,
        .collection = .init(collection.take()),
        .selector = .init(selector.take()),
        .quotation = .init(quotation.take().list),
        .expected = .init(expected.take()),
        .values = .init(values.take()),
        .phase = initial_phase,
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
    };

    if (mode == .list_selector) {
        if (state.selector.borrow() == .list) {
            state.selector_cursor = .init(try support.PervasiveSelectorCursor.init(
                fiber.allocator,
                state.selector.borrow(),
            ));
            state.phase = .count_positions;
        } else {
            if (state.selector.borrow() != .int)
                return fiber.typeError("an integer list index");
            if (state.selector.borrow().int < 0)
                return fiber.fail(.domain, "update index is negative");
            const position = std.math.cast(usize, state.selector.borrow().int) orelse
                return fiber.fail(.domain, "update index is out of bounds");
            if (position >= collection_count)
                return fiber.fail(.domain, "update index is out of bounds");
            state.positions = .init(try fiber.allocator.alloc(usize, 1));
            state.positions.?.borrow()[0] = position;
            state.phase = .copy_values;
        }
    } else {
        const position_count: usize = if (mode == .dictionary_key_list)
            @intCast(state.selector.borrow().list.length())
        else
            1;
        state.positions = .init(try fiber.allocator.alloc(usize, position_count));
        state.pairs = .init(try fiber.allocator.alloc(dict.Pair, collection_count));
        state.phase = .find_positions;
    }
    state_owner = null;
    try fiber.startDriver(UpdateWorkDriver{ .state = .init(state) });
}

const CollectedDriver = struct {
    values: heap.Owned(heap.OwnedValueBuffer),
    materializer: heap.Owned(list.ValueMaterializer),
    result: ?heap.Owned(Value) = null,

    pub fn advance(fiber: *Fiber, self: *CollectedDriver) MachineError!machine.WorkProgress {
        if (self.result == null) {
            switch (try self.materializer.borrowMut().advance(fiber.workBudget())) {
                .pending => return .stepped,
                .complete => |result| {
                    self.result = .init(result);
                    return .stepped;
                },
            }
        }
        self.values.deinit(fiber.releases, fiber.allocator);
        const result = self.result.?.take();
        self.result = null;
        return .{ .output = result };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const StencilControl = struct {
    input: heap.Owned(Value),
    quotation: heap.Owned(*Header),
    expected: heap.Owned(Value),
    results: heap.OwnedValueBuffer,
    site: machine.ExecutionSite,
    index: usize = 0,
    count: usize,
    width: usize,
    word: intern.TraceWord,

    pub fn retire(
        self: *StencilControl,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        self.input.deinit(releases, allocator);
        self.quotation.deinit(releases, allocator);
        self.expected.deinit(releases, allocator);
        self.results.deinit();
    }
};

/// A typed window under construction, held so a cancelled stencil retires it.
const StencilWindow = struct {
    builder: heap.AnyListBuilder,
    pub fn retire(self: *StencilWindow, releases: *heap.ReleaseDomain) void {
        self.builder.retirePartial(releases);
    }
};

const StencilBootstrapDriver = struct {
    control: heap.Owned(StencilControl),
    window_values: heap.Owned(heap.OwnedValueBuffer),
    stack: machine.StackReservation,
    fill_index: usize = 0,
    materializer: ?heap.Owned(list.ValueMaterializer) = null,
    typed_window: ?heap.Owned(StencilWindow) = null,

    /// Copies the next granted run of a typed input's window straight into a
    /// window of the input's own representation; null when the input is boxed.
    fn fillTyped(self: *StencilBootstrapDriver, fiber: *Fiber) MachineError!?bool {
        const control = self.control.borrow();
        const input = control.input.borrow().list;
        switch (input.kind()) {
            inline .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4 => |kind| {
                if (self.typed_window == null) self.typed_window = .init(.{
                    .builder = try heap.AnyListBuilder.init(fiber.allocator, kind, control.width, control.width),
                });
                var reader = heap.LeafReader(kind).acquire(input);
                defer reader.release(fiber.releases);
                const run = fiber.workBudget().take(control.width - self.fill_index);
                const items = switch (self.typed_window.?.borrowMut().builder) {
                    inline else => |*builder| if (@TypeOf(builder.items()) == []heap.LeafElement(kind)) builder.items() else unreachable,
                };
                @memcpy(items[self.fill_index..][0..run], reader.slice()[control.index + self.fill_index ..][0..run]);
                self.fill_index += run;
                return self.fill_index == control.width;
            },
            .generic_spine, .dict, .task, .port, .address, .reserved_mask => return null,
        }
    }

    /// Names its word before it polls, so a cancellation is attributed to it.
    pub const cancellation: machine.DriverCancellation = .own;

    pub fn advance(
        fiber: *Fiber,
        self: *StencilBootstrapDriver,
    ) MachineError!machine.WorkProgress {
        fiber.active_word = self.control.borrow().word;
        try fiber.pollKernel();
        const control = self.control.borrow();
        if (self.materializer == null) if (try self.fillTyped(fiber)) |complete| {
            if (!complete) return .stepped;
            var window = self.typed_window.?.take();
            self.typed_window = null;
            return self.apply(fiber, .{ .list = window.builder.finish() });
        };
        if (self.materializer == null) {
            const end = self.fill_index + fiber.workBudget().take(control.width - self.fill_index);
            while (self.fill_index != end) : (self.fill_index += 1) {
                self.window_values.borrowMut().appendBorrowed(list.atUnchecked(
                    control.input.borrow(),
                    control.index + self.fill_index,
                ));
            }
            if (self.fill_index != control.width) return .stepped;
            self.materializer = .init(.init(
                fiber.allocator,
                self.window_values.borrow().values(),
            ));
        }
        switch (try self.materializer.?.borrowMut().advance(fiber.workBudget())) {
            .pending => return .stepped,
            .complete => |window| return self.apply(fiber, window),
        }
    }

    /// Hands the finished window to the quotation; consumes `window`.
    fn apply(self: *StencilBootstrapDriver, fiber: *Fiber, window: Value) MachineError!machine.WorkProgress {
        var window_owner = heap.OwnedValue.init(fiber.releases, window);
        defer window_owner.deinit();
        const state = try fiber.allocator.create(StencilApplication);
        var state_owner: ?*StencilApplication = state;
        errdefer if (state_owner) |owned| heap.destroyDriver(
            fiber.releases,
            fiber.allocator,
            owned,
        );
        state.* = .{ .control = .init(self.control.take()) };
        var stack = self.stack;
        fiber.retireDriver(self);
        stack.pushBorrowed(window_owner.borrow());
        state_owner = null;
        try fiber.beginApplication(state.application(), .isolated);
        return .detached;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const StencilApplication = struct {
    control: heap.Owned(StencilControl),

    fn application(self: *StencilApplication) Application {
        const control = self.control.borrow();
        return machine.typedApplication(
            self,
            control.quotation.borrow(),
            control.site,
            1,
        );
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *StencilApplication,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        const control = self.control.borrowMut();
        fiber.active_word = control.word;
        fiber.chargeContinuationStep();
        const observed = window.observed(fiber.stack.items.len) orelse
            return fiber.applicationContractError(
                site,
                control.quotation.borrow(),
                control.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = 0 },
                control.index,
            );
        if (observed != 1)
            return fiber.applicationContractError(
                site,
                control.quotation.borrow(),
                control.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = observed },
                control.index,
            );
        var result = try fiber.popDatum();
        control.results.appendOwned(result.take());
        control.index += 1;
        if (control.index == control.count) {
            const values = control.results.take();
            try fiber.startDriver(CollectedDriver{
                .materializer = .init(.init(fiber.allocator, values.values())),
                .values = .init(values),
            });
            return null;
        }
        const stack = try fiber.reserveStack(1);
        const window_values = try heap.OwnedValueBuffer.init(
            fiber.releases,
            control.width,
        );
        const next = StencilBootstrapDriver{
            .control = .init(self.control.take()),
            .window_values = .init(window_values),
            .stack = stack,
        };
        try fiber.startDriver(next);
        return null;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn stencil(fiber: *Fiber) MachineError!void {
    try fiber.require(3);
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    var width_value = try fiber.popValue();
    defer width_value.deinit();
    var input = try fiber.popValue();
    defer input.deinit();
    if (input.borrow() != .list or width_value.borrow() != .int)
        return fiber.typeError("a list, positive int width, and quotation");
    const width_integer = width_value.borrow().int;
    if (width_integer <= 0)
        return fiber.fail(.domain, "stencil requires a positive width");
    const width = std.math.cast(usize, width_integer) orelse
        return fiber.fail(.domain, "stencil width is too large");
    const input_count: usize = @intCast(input.borrow().list.length());
    const count = if (width > input_count) 0 else input_count - width + 1;
    if (count == 0) {
        try pushGenericEmpty(fiber);
        return;
    }
    var expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "window", "--", "result" }),
    );
    defer expected.deinit();
    var results = try heap.OwnedValueBuffer.init(fiber.releases, count);
    defer results.deinit();
    var window_values = try heap.OwnedValueBuffer.init(fiber.releases, width);
    defer window_values.deinit();
    const stack = try fiber.reserveStack(1);
    const control = StencilControl{
        .input = .init(input.take()),
        .quotation = .init(quotation.take().list),
        .expected = .init(expected.take()),
        .results = results.take(),
        .site = fiber.applicationSite(),
        .count = count,
        .width = width,
        .word = fiber.active_word,
    };
    try fiber.startDriver(StencilBootstrapDriver{
        .control = .init(control),
        .window_values = .init(window_values.take()),
        .stack = stack,
    });
}

const UnfoldItems = poll.ChunkList(Value);

const UnfoldState = struct {
    phase: enum { predicate, step } = .predicate,
    current: heap.Owned(Value),
    predicate: heap.Owned(*Header),
    step_quotation: heap.Owned(*Header),
    predicate_expected: heap.Owned(Value),
    step_expected: heap.Owned(Value),
    values: heap.Owned(heap.OwnedValueChain),
    items: heap.Owned(UnfoldItems),
    site: machine.ExecutionSite,
    index: usize = 0,
    word: intern.TraceWord,

    fn application(self: *UnfoldState) Application {
        return machine.typedApplication(
            self,
            self.predicate.borrow(),
            self.site,
            1,
        );
    }
    fn nextStep(self: *UnfoldState) ApplicationStep {
        return .{ .apply = .{
            .quotation = switch (self.phase) {
                .predicate => self.predicate.borrow(),
                .step => self.step_quotation.borrow(),
            },
            .seeded = 1,
            .launch = .isolated,
        } };
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *UnfoldState,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        const observed = window.observed(fiber.stack.items.len) orelse
            return fiber.applicationContractError(
                site,
                switch (self.phase) {
                    .predicate => self.predicate.borrow(),
                    .step => self.step_quotation.borrow(),
                },
                if (self.phase == .predicate) self.predicate_expected.borrow() else self.step_expected.borrow(),
                .{
                    .seeded = 1,
                    .expected = if (self.phase == .predicate) 1 else 2,
                    .observed = 0,
                },
                self.index,
            );
        return switch (self.phase) {
            .predicate => self.resumePredicate(fiber, site, observed),
            .step => self.resumeStep(fiber, site, observed),
        };
    }

    fn resumePredicate(
        self: *UnfoldState,
        fiber: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 1)
            return fiber.applicationContractError(
                site,
                self.predicate.borrow(),
                self.predicate_expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = observed },
                self.index,
            );
        var predicate_result = try fiber.popValue();
        defer predicate_result.deinit();
        if (try boolValue(fiber, &predicate_result)) {
            try fiber.pushBorrowed(self.current.borrow());
            self.phase = .step;
            return self.nextStep();
        }
        const count = self.items.borrow().count;
        const buffer = try heap.OwnedValueBuffer.init(fiber.releases, count);
        const iterator = self.items.borrow().iterator();
        try fiber.pushOwned(self.current.take());
        try fiber.startDriver(UnfoldCollectDriver{
            .values = .init(self.values.take()),
            .items = .init(self.items.take()),
            .iterator = iterator,
            .result = .init(buffer),
            .count = count,
        });
        return null;
    }

    fn resumeStep(
        self: *UnfoldState,
        fiber: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 2)
            return fiber.applicationContractError(
                site,
                self.step_quotation.borrow(),
                self.step_expected.borrow(),
                .{ .seeded = 1, .expected = 2, .observed = observed },
                self.index,
            );
        var item = try fiber.popDatum();
        defer item.deinit();
        var next_state = try fiber.popValue();
        defer next_state.deinit();
        try self.items.borrowMut().append(item.borrow());
        try self.values.borrowMut().appendOwned(item.take());
        self.current.deinit(fiber.releases, fiber.allocator);
        self.current = .init(next_state.take());
        self.index += 1;
        self.phase = .predicate;
        try fiber.pushBorrowed(self.current.borrow());
        return self.nextStep();
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const UnfoldCollectDriver = struct {
    values: heap.Owned(heap.OwnedValueChain),
    items: heap.Owned(UnfoldItems),
    iterator: UnfoldItems.Iterator,
    result: heap.Owned(heap.OwnedValueBuffer),
    copied: usize = 0,
    count: usize,

    pub fn advance(
        fiber: *Fiber,
        self: *UnfoldCollectDriver,
    ) MachineError!machine.WorkProgress {
        const end = self.copied + fiber.workBudget().take(self.count - self.copied);
        while (self.copied != end) : (self.copied += 1)
            self.result.borrowMut().appendBorrowed(self.iterator.next().?.*);
        if (self.copied != self.count) return .stepped;
        const result = self.result.take();
        fiber.retireDriver(self);
        try fiber.startDriver(CollectedDriver{
            .materializer = .init(.init(fiber.allocator, result.values())),
            .values = .init(result),
        });
        return .detached;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn unfold(fiber: *Fiber) MachineError!void {
    try fiber.require(3);
    var step_quotation = try fiber.popQuotation();
    defer step_quotation.deinit();
    var predicate = try fiber.popQuotation();
    defer predicate.deinit();
    var initial = try fiber.popValue();
    defer initial.deinit();
    var predicate_expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "state", "--", "bool" }),
    );
    defer predicate_expected.deinit();
    var step_expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "state", "--", "state", "item" }),
    );
    defer step_expected.deinit();
    var values = heap.Owned(heap.OwnedValueChain).init(
        try .init(fiber.releases),
    );
    defer values.deinit(fiber.releases, fiber.allocator);
    const state = try fiber.allocator.create(UnfoldState);
    var state_owner: ?*UnfoldState = state;
    errdefer if (state_owner) |owned| heap.destroyDriver(
        fiber.releases,
        fiber.allocator,
        owned,
    );
    state.* = .{
        .current = .init(initial.take()),
        .predicate = .init(predicate.take().list),
        .step_quotation = .init(step_quotation.take().list),
        .predicate_expected = .init(predicate_expected.take()),
        .step_expected = .init(step_expected.take()),
        .values = .init(values.take()),
        .items = .init(.init(fiber.allocator)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
    };
    try fiber.pushBorrowed(state.current.borrow());
    state_owner = null;
    try fiber.beginApplication(state.application(), .isolated);
}

const InfraResultDriver = struct {
    base: usize,
    materializer: heap.Owned(list.ValueMaterializer),
    result: ?heap.Owned(Value) = null,

    fn install(fiber: *Fiber, base: usize) error{OutOfMemory}!void {
        // The isolated stack becomes a list, so each value enters as data
        // (`value.datum`); the operands are discarded once materialized.
        for (fiber.stack.items[base..]) |*item| item.* = value.datum(item.*);
        try fiber.startDriver(InfraResultDriver{
            .base = base,
            .materializer = .init(.init(fiber.allocator, fiber.stack.items[base..])),
        });
    }

    pub fn advance(fiber: *Fiber, self: *InfraResultDriver) MachineError!machine.WorkProgress {
        if (self.result == null) {
            switch (try self.materializer.borrowMut().advance(fiber.workBudget())) {
                .pending => return .stepped,
                .complete => |result| {
                    self.result = .init(result);
                    return .stepped;
                },
            }
        }
        const work = fiber.workBudget();
        while (fiber.stack.items.len != self.base and work.spend()) {
            var discarded = try fiber.popValue();
            discarded.deinit();
        }
        if (fiber.stack.items.len != self.base) return .stepped;
        const result = self.result.?.take();
        self.result = null;
        return .{ .output = result };
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

const InfraBootstrapDriver = struct {
    iteration: heap.Owned(*IterationState),
    stack: machine.StackReservation,
    index: usize = 0,

    pub fn advance(fiber: *Fiber, self: *InfraBootstrapDriver) MachineError!machine.WorkProgress {
        const iteration = self.iteration.borrow();
        const end = self.index + fiber.workBudget().take(iteration.count - self.index);
        while (self.index != end) : (self.index += 1) {
            const item = list.atUnchecked(iteration.left.borrow(), self.index);
            self.stack.pushBorrowed(item);
        }
        if (self.index != iteration.count) return .stepped;
        std.debug.assert(self.stack.complete());
        const application = iteration.application(@intCast(iteration.count));
        _ = self.iteration.take();
        try fiber.beginApplication(application, .isolated);
        return .completed;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn each(fiber: *Fiber) MachineError!void {
    return fiber.continueWithIdiom(.each, eachGeneric);
}
fn eachGeneric(fiber: *Fiber) MachineError!void {
    return startUnaryIteration(fiber, .each);
}

fn forWord(fiber: *Fiber) MachineError!void {
    return startUnaryIteration(fiber, .for_word);
}

fn startUnaryIteration(fiber: *Fiber, kind: IterationKind) MachineError!void {
    try fiber.require(2);
    var quotation = try fiber.popValue();
    defer quotation.deinit();
    var input = try fiber.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list)
        return fiber.typeError(if (kind == .each or kind == .for_word)
            "a list or dict and quotation"
        else
            "a list and quotation");
    if (kind == .each and input.borrow() == .dict) {
        const keys = dict.keysOf(input.borrow().dict);
        heap.retainValue(keys);
        var selector = heap.OwnedValue.init(fiber.releases, keys);
        defer selector.deinit();
        return startUpdateOwned(
            fiber,
            .dictionary_key_list,
            input.take(),
            selector.take(),
            quotation.take(),
        );
    }
    if (input.borrow() != .list and !(kind == .for_word and input.borrow() == .dict))
        return fiber.typeError(if (kind == .each or kind == .for_word)
            "a list or dict and quotation"
        else
            "a list and quotation");
    const count: usize = @intCast(switch (input.borrow()) {
        .list => |header| header.length(),
        .dict => |header| header.length(),
        else => unreachable,
    });
    if (count == 0) {
        if (kind == .each) try pushGenericEmpty(fiber);
        return;
    }
    var expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(
            fiber.allocator,
            if (kind == .each) &.{ "a", "--", "b" } else &.{ "a", "--" },
        ),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        fiber,
        kind,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(fiber.releases, fiber.allocator, state);
    const state = state_owner.?;
    if (kind == .each) state.results = .init(try .init(fiber.releases, count));
    try state.pushInputs(fiber);
    state_owner = null;
    try fiber.beginApplication(state.application(1), .isolated);
}

fn zipWith(fiber: *Fiber) MachineError!void {
    return fiber.continueWithIdiom(.zip_with, zipWithGeneric);
}
fn zipWithGeneric(fiber: *Fiber) MachineError!void {
    try fiber.require(3);
    var quotation = try fiber.popValue();
    defer quotation.deinit();
    var right = try fiber.popValue();
    defer right.deinit();
    var left = try fiber.popValue();
    defer left.deinit();
    const left_list = left.borrow() == .list;
    const right_list = right.borrow() == .list;
    if (!left_list and !right_list) return fiber.typeError("at least one list");
    const count: usize = if (left_list)
        @intCast(left.borrow().list.length())
    else
        @intCast(right.borrow().list.length());
    if (left_list and right_list and left.borrow().list.length() != right.borrow().list.length()) {
        const left_len: usize = @intCast(left.borrow().list.length());
        const right_len: usize = @intCast(right.borrow().list.length());
        return fiber.conformError(left_len, right_len);
    }
    if (count == 0) {
        try pushGenericEmpty(fiber);
        return;
    }
    var expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "a", "b", "--", "c" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        fiber,
        .zip_with,
        &left,
        &right,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(fiber.releases, fiber.allocator, state);
    const state = state_owner.?;
    state.results = .init(try .init(fiber.releases, count));
    try state.pushInputs(fiber);
    state_owner = null;
    try fiber.beginApplication(state.application(2), .isolated);
}

fn fold(fiber: *Fiber) MachineError!void {
    return fiber.continueWithIdiom(.fold, foldGeneric);
}
fn foldGeneric(fiber: *Fiber) MachineError!void {
    return startFold(fiber, .fold);
}

fn fold1(fiber: *Fiber) MachineError!void {
    return fiber.continueWithIdiom(.fold1, fold1Generic);
}
fn fold1Generic(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var quotation = try fiber.popValue();
    defer quotation.deinit();
    var input = try fiber.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return fiber.typeError("a list and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    if (count == 0) return fiber.fail(.domain, "fold1 requires a non-empty list");
    if (count == 1) return fiber.pushBorrowed(list.atUnchecked(input.borrow(), 0));
    var expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "acc", "a", "--", "acc" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        fiber,
        .fold,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(fiber.releases, fiber.allocator, state);
    const state = state_owner.?;
    // The first element is the accumulator, so the walk starts at the second.
    state.index = 1;
    try fiber.pushBorrowed(list.atUnchecked(state.left.borrow(), 0));
    try fiber.pushBorrowed(list.atUnchecked(state.left.borrow(), 1));
    state_owner = null;
    try fiber.beginApplication(state.application(2), .isolated);
}

fn lexCmpWith(fiber: *Fiber) MachineError!void {
    return fiber.continueWithIdiom(.lex_cmp, lexCmpWithGeneric);
}
fn lexCmpWithGeneric(fiber: *Fiber) MachineError!void {
    try fiber.require(3);
    var quotation = try fiber.popValue();
    defer quotation.deinit();
    var right = try fiber.popValue();
    defer right.deinit();
    var left = try fiber.popValue();
    defer left.deinit();
    if (quotation.borrow() != .list or left.borrow() != .list or right.borrow() != .list)
        return fiber.typeError("two lists and a comparator");
    const shared: usize = @intCast(@min(left.borrow().list.length(), right.borrow().list.length()));
    if (shared == 0) return pushLengthOrder(fiber, left.borrow(), right.borrow());
    var expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "left-element", "right-element", "--", "order" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        fiber,
        .lex_cmp,
        &left,
        &right,
        &quotation,
        &expected,
        shared,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(fiber.releases, fiber.allocator, state);
    const state = state_owner.?;
    try state.pushInputs(fiber);
    state_owner = null;
    try fiber.beginApplication(state.application(2), .isolated);
}

/// Two lists whose shared prefix is equal order by length.
fn pushLengthOrder(fiber: *Fiber, left: Value, right: Value) error{OutOfMemory}!void {
    try fiber.pushOwned(.{ .int = switch (std.math.order(left.list.length(), right.list.length())) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } });
}

fn scan(fiber: *Fiber) MachineError!void {
    return fiber.continueWithIdiom(.scan, scanGeneric);
}
fn scanGeneric(fiber: *Fiber) MachineError!void {
    return startFold(fiber, .scan);
}

fn startFold(fiber: *Fiber, kind: IterationKind) MachineError!void {
    try fiber.require(3);
    var quotation = try fiber.popValue();
    defer quotation.deinit();
    var accumulator = try fiber.popValue();
    defer accumulator.deinit();
    var input = try fiber.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return fiber.typeError("a list, accumulator, and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    if (count == 0) {
        if (kind == .scan) {
            try pushGenericEmpty(fiber);
        } else {
            try fiber.pushOwned(accumulator.take());
        }
        return;
    }
    var expected = heap.OwnedValue.init(
        fiber.releases,
        try effectValue(fiber.allocator, &.{ "acc", "a", "--", "acc" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        fiber,
        kind,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(fiber.releases, fiber.allocator, state);
    const state = state_owner.?;
    if (kind == .scan) state.results = .init(try .init(fiber.releases, count));
    try fiber.pushOwned(accumulator.take());
    try fiber.pushBorrowed(list.atUnchecked(state.left.borrow(), 0));
    state_owner = null;
    try fiber.beginApplication(state.application(2), .isolated);
}

fn infra(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var quotation = try fiber.popValue();
    defer quotation.deinit();
    var input = try fiber.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return fiber.typeError("a list and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    const state = try createIteration(fiber, .infra, &input, null, &quotation, null, count);
    var state_owner: ?*IterationState = state;
    errdefer if (state_owner) |owned| heap.destroyDriver(
        fiber.releases,
        fiber.allocator,
        owned,
    );
    const stack = try fiber.reserveStack(count);
    state_owner = null;
    try fiber.startDriver(InfraBootstrapDriver{ .iteration = .init(state), .stack = stack });
}

fn createIteration(
    fiber: *Fiber,
    kind: IterationKind,
    left: *heap.OwnedValue,
    right: ?*heap.OwnedValue,
    quotation: *heap.OwnedValue,
    expected: ?*heap.OwnedValue,
    count: usize,
) error{OutOfMemory}!*IterationState {
    const state = try fiber.allocator.create(IterationState);
    state.* = .{
        .kind = kind,
        .left = .init(left.take()),
        .right = if (right) |item| .init(item.take()) else null,
        .quotation = .init(quotation.take().list),
        .expected = if (expected) |item| .init(item.take()) else null,
        .site = fiber.applicationSite(),
        .count = count,
        .word = fiber.active_word,
    };
    state.plan = .init(.init(state.quotation.borrow()));
    return state;
}

fn inputAt(input: Value, index: usize) Value {
    return if (input == .list) list.atUnchecked(input, index) else input;
}

fn pushGenericEmpty(fiber: *Fiber) error{OutOfMemory}!void {
    try fiber.pushOwned(try list.fromValuesGeneric(fiber.allocator, &.{}));
}

fn effectValue(allocator: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}!Value {
    const forms = try allocator.alloc(Value, names.len);
    defer allocator.free(forms);
    for (names, 0..) |name, index| forms[index] = .{ .symbol = .{ .name = try intern.intern(name) } };
    return list.fromValuesGeneric(allocator, forms);
}

fn boolValue(fiber: *Fiber, item: *const heap.OwnedValue) MachineError!bool {
    return switch (item.borrow()) {
        .int => |integer| switch (integer) {
            0 => false,
            1 => true,
            else => fiber.typeError("a 0/1 bool"),
        },
        .float, .char, .symbol, .list, .dict, .task, .port, .address => fiber.typeError("a 0/1 bool"),
    };
}
