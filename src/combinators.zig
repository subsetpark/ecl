//! Inline control and isolated quotation-taking combinators.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const poll = @import("poll.zig");
const support = @import("kernel_support.zig");

const Value = value.Value;
const Header = value.ListHandle;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
const Application = machine.IsolatedApplication;
const ApplicationStep = machine.ApplicationStep;
const StackWindow = machine.StackWindow;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "call", .primitive = call, .effect = "quotation -- ...", .doc = "Run a quotation on the current stack. A data list pushes its elements." },
        .{ .name = "if", .primitive = ifWord, .effect = "bool then else -- ...", .doc = "Run `then` when the condition is 1, `else` when it is 0; any other condition value is `` `type ``." },
        .{ .name = "while", .primitive = whileWord, .effect = "cond body -- ...", .doc = "At the start of each iteration, run `cond` over a paging floor: it takes from the stack only what its words require. Its top result must be a 0/1 boolean; its complete stack result is discarded and what it took is restored. On 1, run `body` in place and loop. On 0, exit. IO and other non-stack effects from the condition survive; definitions are not legal in it. Tail-call optimized." },
        .{ .name = "linrec", .primitive = linrec, .effect = "predicate base pre post -- ...", .doc = "Explicit linear recursion. At each descent, run `predicate` over a paging floor: it takes from the stack only what its words require. Its top result must be a 0/1 boolean; its complete stack result is discarded and what it took is restored. On 1, run `base`. On 0, run `pre`, recurse from `pre`'s resulting stack, then run `post`. IO and other non-stack effects from the predicate survive restoration; definitions are not legal in it. All four quotations run in the invoking application context and communicate through ambient stack state. The recursion runs in constant space: every level applies the same quotations, so the descents whose `post` is pending are a count." },
        .{ .name = "dip", .primitive = dip, .effect = "x (q: ... -- ...) -- ... x", .doc = "Run a quotation beneath a protected top stack value: `q` runs with `x` removed, then `x` is pushed after its results. Inside `above` or `below`, a protected value taken from beneath their floor returns as the original it was, so protecting a value is not consuming it." },
        .{ .name = "dip-n", .primitive = dipN, .effect = "... (q: ... -- ...) n -- ...", .doc = "Run a quotation beneath the top `n` stack values: `q` runs with them removed, then they are pushed back in their original order after its results. `n` must be a nonnegative int, or the word fails with `` `type `` or `` `domain `` before anything is removed. `0 dip-n` is `call`, and `1 dip-n` is `dip`." },
        .{ .name = "above", .primitive = above, .effect = "... (q: ... -- ...) -- ...", .doc = "Run a quotation, then restore the values it consumed above its results, in their original order. The quotation runs on a substack that starts empty and takes operands from beneath as its words need them, so what it consumed is exactly what its words required: `1 2 (+) above` is `3 1 2`, and `1 (dup) above` is `1 1 1`. A `dip` inside returns a protected value as the original it was. The quotation cannot take values from beneath an enclosing `@attempt` or isolated application, which fail with `` `underflow `` as usual. `(q) above` leaves the quotation's results beneath the restored values; `below` leaves them on top." },
        .{ .name = "below", .primitive = below, .effect = "... (q: ... -- ...) -- ...", .doc = "Run a quotation, then restore the values it consumed below its results, in their original order: the stack is as it was, with the results on top. The quotation runs on a substack that starts empty and takes operands from beneath as its words need them, so what it consumed is exactly what its words required: `1 2 (+) below` is `1 2 3`, and `1 2 3 ((+) dip) below` is `1 2 3 3`, since a `dip` inside returns a protected value as the original it was. The quotation cannot take values from beneath an enclosing `@attempt` or isolated application, which fail with `` `underflow `` as usual." },
        .{ .name = "bi", .primitive = bi, .effect = "... p q -- ...", .doc = "Apply two quotations to the same inputs, first `p`, then `q`, leaving `p`'s results beneath `q`'s: a two-quotation `cleave`, with the same consumption rule." },
        .{ .name = "tri", .primitive = tri, .effect = "... p q r -- ...", .doc = "Apply three quotations to the same inputs in left-to-right order: a three-quotation `cleave`, with the same consumption rule." },
        .{ .name = "cleave", .primitive = cleave, .effect = "... quotations -- ...", .doc = "Apply each quotation in `quotations`, in order, to the stack as it was when the list was consumed. Each quotation consumes exactly what its words require, and its results are held aside, so every quotation starts from the same inputs and sees the stack beneath them rather than earlier results. Afterwards the inputs any quotation consumed are dropped and all the results are pushed in order. The list and each of its elements must be quotations, or the word fails with `` `type `` before any quotation runs. An empty list leaves the stack unchanged." },
        .{ .name = "times", .primitive = times, .effect = "n quotation -- ...", .doc = "Run the quotation `n` times; `n` must be a nonnegative int. Tail-call optimized." },
        .{ .name = "cond", .primitive = cond, .effect = "clauses -- ...", .doc = "The clause list is flat, nonempty, and odd: `[test action … else]`, all quotations. The whole list is validated before the first test runs (empty or even lists are `` `shape ``; a non-list or non-quotation member is `` `type ``). Each test runs over a paging floor against the stack as it was when the clause list was consumed: it takes from the stack only what its words require. Only its top result is interpreted, and it must be a 0/1 boolean. The complete test result is then discarded and what the test took is restored. The first true test selects its action; otherwise the final else runs, in either case from the original stack. Stack rollback does not roll back IO or other non-stack effects performed by tests; definitions are not legal in a test." },
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

fn call(evaluator: *Fiber) MachineError!void {
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    try evaluator.callOwned(quotation.take().list);
}

fn ifWord(evaluator: *Fiber) MachineError!void {
    try evaluator.require(3);
    var otherwise = try evaluator.popValue();
    defer otherwise.deinit();
    var then = try evaluator.popValue();
    defer then.deinit();
    var predicate = try evaluator.popValue();
    defer predicate.deinit();
    if (then.borrow() != .list or otherwise.borrow() != .list)
        return evaluator.typeError("two quotation branches");
    const selected_then = try boolValue(evaluator, &predicate);
    try evaluator.callOwned(if (selected_then) then.take().list else otherwise.take().list);
}

fn whileWord(evaluator: *Fiber) MachineError!void {
    try evaluator.require(2);
    var body = try evaluator.popValue();
    defer body.deinit();
    var condition = try evaluator.popValue();
    defer condition.deinit();
    if (body.borrow() != .list or condition.borrow() != .list)
        return evaluator.typeError("two quotations/lists");
    const provenance_target = try evaluator.applicationProvenanceTarget();
    const state = try evaluator.allocator.create(WhileState);
    state.* = .{
        .condition = .init(condition.take().list),
        .body = .init(body.take().list),
        .paged = .init(.init(.discarded)),
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
        .provenance_target = provenance_target,
        .phase = .condition,
    };
    try evaluator.beginPagingApplication(
        state.application(state.condition.borrow()),
        &state.paged.borrowMut().floor,
    );
}

fn selectedProvenance(target: ?*const machine.ApplicationProvenanceTarget) machine.ApplicationProvenance {
    return if (target) |selected| .{ .selected_target = selected } else .boundary;
}

/// The boolean a test left on top of its region. A test that left nothing
/// took its result from beneath, like any operand its words required: the
/// value is paged now, so the restore gives it back.
fn popTestResult(evaluator: *Fiber, paged: *PagedControl) MachineError!bool {
    var result = if (evaluator.stack.items.len != paged.base) try evaluator.popValue() else taken: {
        try paged.floor.originals.ensureUnusedCapacity(evaluator.allocator, 1);
        var taken = try evaluator.popProtected();
        heap.retainValue(taken.item.borrow());
        paged.floor.originals.appendAssumeCapacity(.{ .value = taken.item.borrow(), .shared = taken.original });
        paged.base -= 1;
        break :taken taken.item;
    };
    defer result.deinit();
    return boolValue(evaluator, &result);
}

/// Runs the work a guard's frame has in hand, or suspends the frame under a
/// driver that finishes it and resumes the frame at `pending`.
fn finishWork(
    comptime State: type,
    state: *State,
    evaluator: *Fiber,
    pending: @FieldType(State, "phase"),
) MachineError!?ApplicationStep {
    if (try state.work(evaluator)) return state.resumeAfter(pending);
    state.phase = pending;
    try evaluator.startDriver(SuspendedWork(State){ .state = state });
    return evaluator.suspendInlineApplication();
}

/// Finishes work for a suspended frame, whose application state the frame
/// owns; the frame resumes once this completes.
fn SuspendedWork(comptime State: type) type {
    return struct {
        state: *State,

        pub fn advance(evaluator: *Fiber, self: *@This()) MachineError!machine.WorkProgress {
            evaluator.active_word = self.state.word;
            try evaluator.pollKernel();
            return if (try self.state.work(evaluator)) .completed else .stepped;
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
    paged: heap.Owned(PagedControl),
    site: machine.ApplicationSite,
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
    fn work(self: *WhileState, evaluator: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(evaluator);
    }
    fn resumeAfter(self: *WhileState, finished: @FieldType(WhileState, "phase")) ?ApplicationStep {
        return switch (finished) {
            .restored_true => self.bodyStep(),
            .restored_false => null,
            .condition, .body => unreachable,
        };
    }

    pub fn resumeApplication(
        evaluator: *Fiber,
        self: *WhileState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        switch (self.phase) {
            .condition => {
                const paged = self.paged.borrowMut();
                paged.base = window.base();
                const selected = try popTestResult(evaluator, paged);
                return finishWork(WhileState, self, evaluator, if (selected) .restored_true else .restored_false);
            },
            .body => return self.conditionStep(),
            .restored_true, .restored_false => |finished| return self.resumeAfter(finished),
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};

const TimesState = struct {
    quotation: heap.Owned(*Header),
    site: machine.ApplicationSite,
    remaining: usize,
    word: intern.TraceWord,

    fn application(self: *TimesState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.site, 0);
    }
    fn step(self: *TimesState) ApplicationStep {
        return .{ .apply = .{ .quotation = self.quotation.borrow(), .seeded = 0 } };
    }

    pub fn resumeApplication(
        evaluator: *Fiber,
        self: *TimesState,
        _: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        self.remaining -= 1;
        return if (self.remaining == 0) null else self.step();
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn times(evaluator: *Fiber) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    if (quotation.borrow() != .list or count_value.borrow() != .int)
        return evaluator.typeError("a nonnegative int and quotation");
    if (count_value.borrow().int < 0)
        return evaluator.fail(.domain, "times requires a nonnegative count");
    if (count_value.borrow().int == 0) return;
    const state = try evaluator.allocator.create(TimesState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .site = evaluator.applicationSite(),
        .remaining = @intCast(count_value.borrow().int),
        .word = evaluator.active_word,
    };
    try evaluator.beginInlineApplication(state.application());
}

/// The protected value rides in a continuation rather than in a capture
/// quotation composed onto `q`.
fn dip(evaluator: *Fiber) MachineError!void {
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    var protected = try evaluator.popProtected();
    defer protected.item.deinit();
    try startDip(evaluator, &quotation, &protected);
}

/// `x quotation cons dip` without the list: the value beneath `x` is
/// protected and `x` stays on the stack for the quotation, as the first form
/// of `(x quotation...)` would have pushed it. The `cons call` and `cons dip`
/// phrases in `idioms.zig` reach this.
pub fn dipBelowHead(evaluator: *Fiber) MachineError!void {
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    var head = try evaluator.popValue();
    defer head.deinit();
    var protected = try evaluator.popProtected();
    defer protected.item.deinit();
    try evaluator.pushOwned(head.take());
    try startDip(evaluator, &quotation, &protected);
}

fn startDip(evaluator: *Fiber, quotation: *heap.OwnedValue, protected: *Fiber.Protected) MachineError!void {
    const state = try evaluator.allocator.create(DipState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .protected = .init(protected.item.take()),
        .original = protected.original,
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
    };
    try evaluator.beginInlineApplication(state.application());
}

const DipState = struct {
    quotation: heap.Owned(*Header),
    protected: heap.Owned(Value),
    /// Whether the value came across a paging floor, so it returns as one.
    original: bool,
    site: machine.ApplicationSite,
    word: intern.TraceWord,

    fn application(self: *DipState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.site, 0);
    }

    /// The protected value returns exactly once, after the quotation's own
    /// application completes, so a failing quotation leaves it to this
    /// driver's field ownership rather than to the rolled-back stack.
    pub fn resumeApplication(
        evaluator: *Fiber,
        self: *DipState,
        _: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        try evaluator.pushReturned(self.protected.take(), self.original);
        return null;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn dipN(evaluator: *Fiber) MachineError!void {
    try evaluator.require(2);
    var count_value = try evaluator.popValue();
    defer count_value.deinit();
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    if (count_value.borrow() != .int) return evaluator.typeError("an int count");
    if (count_value.borrow().int < 0) return evaluator.fail(.domain, "dip-n count must be nonnegative");
    const count: usize = @intCast(count_value.borrow().int);
    // Checked before the buffers are sized by it; `require` would page early
    // and lose which values `popProtected` finds to be originals.
    if (count > evaluator.reachable()) return evaluator.failShort(count);
    var control = heap.Owned(DipControl).init(.{
        .quotation = .init(quotation.take().list),
        .protected = .init(try .init(evaluator.releases, count)),
        .originals = try .initEmpty(evaluator.allocator, count),
        .count = count,
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
    });
    defer control.deinit(evaluator.releases, evaluator.allocator);
    switch (try control.borrowMut().advance(evaluator)) {
        .finished => unreachable,
        .launch => try launchDipN(evaluator, &control),
        .pending => try evaluator.startDriver(DipDriver{ .control = .init(control.take()) }),
    }
}

fn launchDipN(evaluator: *Fiber, control: *heap.Owned(DipControl)) MachineError!void {
    const state = try evaluator.allocator.create(DipNState);
    state.* = .{ .control = .init(control.take()) };
    try evaluator.beginInlineApplication(state.application());
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
    site: machine.ApplicationSite,
    word: intern.TraceWord,
    index: usize = 0,
    phase: enum { take, run, restore } = .take,

    const Progress = union(enum) { pending, launch, finished };

    fn advance(self: *DipControl, evaluator: *Fiber) MachineError!Progress {
        const work = evaluator.workBudget();
        while (true) switch (self.phase) {
            .take => {
                const end = self.index + work.take(self.count - self.index);
                while (self.index != end) : (self.index += 1) {
                    var taken = try evaluator.popProtected();
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
                    try evaluator.pushReturned(item, self.originals.isSet(self.index));
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

    pub fn advance(evaluator: *Fiber, self: *DipDriver) MachineError!machine.WorkProgress {
        evaluator.active_word = self.control.borrow().word;
        try evaluator.pollKernel();
        const progress = try self.control.borrowMut().advance(evaluator);
        if (progress == .pending) return .stepped;
        var control = heap.Owned(DipControl).init(self.control.take());
        defer control.deinit(evaluator.releases, evaluator.allocator);
        evaluator.retireDriver(self);
        switch (progress) {
            .launch => try launchDipN(evaluator, &control),
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
        evaluator: *Fiber,
        self: *DipNState,
        _: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.control.borrow().word;
        evaluator.chargeContinuationStep();
        switch (try self.control.borrowMut().advance(evaluator)) {
            .finished => return null,
            .launch => unreachable,
            .pending => {
                try evaluator.startDriver(DipDriver{ .control = .init(self.control.take()) });
                return null;
            },
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn above(evaluator: *Fiber) MachineError!void {
    return startPaged(evaluator, .above);
}
fn below(evaluator: *Fiber) MachineError!void {
    return startPaged(evaluator, .below);
}
fn startPaged(evaluator: *Fiber, placement: Placement) MachineError!void {
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    const state = try evaluator.allocator.create(PagedState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .paged = .init(.init(placement)),
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
    };
    try evaluator.beginPagingApplication(state.application(), &state.paged.borrowMut().floor);
}

/// What becomes of the region a paged quotation leaves.
const Placement = enum {
    /// The restored originals go on top of the region.
    above,
    /// The restored originals go beneath the region.
    below,
    /// The region is dropped: a test's result was read from it, and the
    /// test's only lasting effect on the stack is none.
    discarded,
    /// The region moves into the control's `results`, in stack order, for
    /// a cleave to put back once every quotation has run.
    collected,
};

/// A quotation run over a paging floor, and the bounded phases that put the
/// stack back together once it returns: originals a `dip` returned are swept
/// to the top of the region and dropped, the region is placed, and the paged
/// originals come back in their original order. Each phase is user-sized and
/// advances only as far as the turn's budget allows, and no phase takes a
/// live value off the stack except to release it or to collect it.
///
/// A restored original the floor beneath holds too goes back as that
/// floor's returned original, so restoring is never producing: a word that
/// only looked at a value beneath the floor did not produce it.
const PagedControl = struct {
    placement: Placement,
    floor: machine.PagingFloor = .{ .floor = 0, .beneath = .{ .hard = 0 } },
    /// What a collected region held, in stack order.
    results: heap.InlineList(Value, 4, .{ .int = 0 }) = .empty,
    /// The region's base: the floor as the quotation left it.
    base: usize = 0,
    /// How many originals come back: the floor's count before they do.
    restored: usize = 0,
    sweep: machine.StackSweep = .from(0),
    /// The reversal that orders a collected region, or the three that rotate
    /// the restored originals beneath the region.
    spans: [3]machine.StackReversal = @splat(.none),
    reversed: usize = 0,
    phase: Phase = .begin,

    const Phase = enum { begin, sweep, drop, clear, reverse, gather, surface, rotate, finished };

    fn init(placement: Placement) PagedControl {
        return .{ .placement = placement };
    }
    /// Readies the floor for another quotation once a restore has finished.
    fn reset(self: *PagedControl) void {
        std.debug.assert(self.floor.paged() == 0 and self.floor.returned.items.len == 0);
        self.phase = .begin;
        self.reversed = 0;
    }

    fn advance(self: *PagedControl, evaluator: *Fiber) MachineError!bool {
        const work = evaluator.workBudget();
        while (true) switch (self.phase) {
            .begin => {
                self.restored = self.floor.paged();
                const returned = self.floor.returned.items;
                if (self.placement == .discarded) {
                    self.phase = .clear;
                } else if (returned.len == 0) {
                    self.placeRegion(evaluator);
                } else {
                    // The region lies above the floor beneath, whose returned
                    // originals all sit below it, so only this floor's records
                    // name slots in it.
                    self.sweep = .from(returned[0]);
                    self.phase = .sweep;
                }
            },
            .sweep => {
                if (!evaluator.sweepStack(&self.sweep, self.floor.returned.items, work)) return false;
                self.phase = .drop;
            },
            .drop => {
                const returned = &self.floor.returned;
                const granted = work.take(returned.items.len);
                evaluator.discard(granted);
                returned.shrinkRetainingCapacity(returned.items.len - granted);
                if (returned.items.len != 0) return false;
                self.placeRegion(evaluator);
            },
            .clear => {
                const granted = work.take(evaluator.stack.items.len - self.base);
                evaluator.discard(granted);
                if (evaluator.stack.items.len != self.base) return false;
                self.floor.returned.clearRetainingCapacity();
                self.phase = .surface;
            },
            .reverse => {
                if (!evaluator.reverseStack(&self.spans[0], work)) return false;
                try self.results.ensureUnusedCapacity(evaluator.allocator, evaluator.stack.items.len - self.base);
                self.phase = .gather;
            },
            .gather => {
                const granted = work.take(evaluator.stack.items.len - self.base);
                for (0..granted) |_| {
                    var item = try evaluator.popValue();
                    self.results.appendAssumeCapacity(item.take());
                }
                if (evaluator.stack.items.len != self.base) return false;
                self.phase = .surface;
            },
            .surface => {
                const originals = &self.floor.originals;
                const granted = work.take(originals.len());
                for (0..granted) |_| {
                    const index = self.restored - originals.len();
                    const original = originals.pop().?;
                    try evaluator.pushOwned(original.value);
                    // Beneath the region, the originals end up at the base
                    // once rotated; the records name those slots now.
                    const position = if (self.placement == .below) self.base + index else evaluator.stack.items.len - 1;
                    if (original.shared) try evaluator.noteReturned(position);
                }
                if (originals.len() != 0) return false;
                if (self.placement != .below) {
                    self.phase = .finished;
                    continue;
                }
                const top = evaluator.stack.items.len;
                const split = top - self.restored;
                self.spans = .{ .of(self.base, split), .of(split, top), .of(self.base, top) };
                self.phase = .rotate;
            },
            .rotate => {
                while (self.reversed != self.spans.len) : (self.reversed += 1) {
                    if (!evaluator.reverseStack(&self.spans[self.reversed], work)) return false;
                }
                self.phase = .finished;
            },
            .finished => return true,
        };
    }

    /// The region holds only results now; what happens to it is the placement.
    fn placeRegion(self: *PagedControl, evaluator: *const Fiber) void {
        switch (self.placement) {
            .above, .below => self.phase = .surface,
            .collected => {
                self.spans[0] = .of(self.base, evaluator.stack.items.len);
                self.phase = .reverse;
            },
            .discarded => unreachable,
        }
    }

    pub fn retire(self: *PagedControl, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        for (self.results.items()) |item| releases.releaseValue(item);
        self.results.deinit(allocator);
        self.floor.retire(releases, allocator);
    }
};

const PagedState = struct {
    quotation: heap.Owned(*Header),
    paged: heap.Owned(PagedControl),
    site: machine.ApplicationSite,
    word: intern.TraceWord,
    phase: enum { run, restored } = .run,

    fn application(self: *PagedState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.site, 0);
    }
    fn work(self: *PagedState, evaluator: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(evaluator);
    }
    fn resumeAfter(_: *PagedState, _: @FieldType(PagedState, "phase")) ?ApplicationStep {
        return null;
    }

    pub fn resumeApplication(
        evaluator: *Fiber,
        self: *PagedState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        switch (self.phase) {
            .run => {
                self.paged.borrowMut().base = window.base();
                return finishWork(PagedState, self, evaluator, .restored);
            },
            .restored => return null,
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn cleave(evaluator: *Fiber) MachineError!void {
    var quotations = try evaluator.popValue();
    defer quotations.deinit();
    if (quotations.borrow() != .list) return evaluator.typeError("a list of quotations");
    return startCleave(evaluator, .{ .list = .init(quotations.take()) }, .validate);
}
fn bi(evaluator: *Fiber) MachineError!void {
    return cleaveFixed(evaluator, 2);
}
fn tri(evaluator: *Fiber) MachineError!void {
    return cleaveFixed(evaluator, 3);
}
/// `bi` and `tri` take their quotations straight off the stack, already
/// validated, so no list is built and no validation phase runs.
fn cleaveFixed(evaluator: *Fiber, count: usize) MachineError!void {
    try evaluator.require(count);
    var fixed: CleaveQuotations.Fixed = .{};
    errdefer fixed.retire(evaluator.releases);
    for (0..count) |offset| {
        const item = evaluator.visibleOperandBorrowed(evaluator.available() - count + offset);
        if (item != .list) return evaluator.typeError("quotations");
        heap.incRef(item.list);
        fixed.items[offset] = item.list;
        fixed.count += 1;
    }
    evaluator.discard(count);
    return startCleave(evaluator, .{ .fixed = fixed }, .run);
}
fn startCleave(
    evaluator: *Fiber,
    quotations: CleaveQuotations,
    phase: @FieldType(CleaveState, "phase"),
) MachineError!void {
    var owned_quotations = heap.Owned(CleaveQuotations).init(quotations);
    const state = evaluator.allocator.create(CleaveState) catch |err| {
        owned_quotations.deinit(evaluator.releases, evaluator.allocator);
        return err;
    };
    state.* = .{
        .quotations = .init(owned_quotations.take()),
        .paged = .init(.init(.collected)),
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
        .phase = phase,
    };
    var owned = heap.Owned(*CleaveState).init(state);
    // Validation runs where the word is invoked when the turn's budget
    // covers it, so a small cleave launches without installing a driver.
    if (phase == .validate and !(state.work(evaluator) catch |err| {
        owned.deinit(evaluator.releases, evaluator.allocator);
        return err;
    })) return evaluator.startDriver(CleaveDriver{ .state = owned });
    try launchCleave(evaluator, &owned);
}

fn launchCleave(evaluator: *Fiber, owned: *heap.Owned(*CleaveState)) MachineError!void {
    const state = owned.borrow();
    if (state.phase == .done) return owned.deinit(evaluator.releases, evaluator.allocator);
    state.running = true;
    try evaluator.beginPagingApplication(
        owned.take().application(state.quotation()),
        &state.paged.borrowMut().floor,
    );
}

/// Finishes a cleave's validation when the turn ran out, then launches it.
const CleaveDriver = struct {
    state: heap.Owned(*CleaveState),

    pub fn advance(evaluator: *Fiber, self: *CleaveDriver) MachineError!machine.WorkProgress {
        evaluator.active_word = self.state.borrow().word;
        try evaluator.pollKernel();
        if (!try self.state.borrow().work(evaluator)) return .stepped;
        var owned = heap.Owned(*CleaveState).init(self.state.take());
        evaluator.retireDriver(self);
        try launchCleave(evaluator, &owned);
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
    paged: heap.Owned(PagedControl),
    site: machine.ApplicationSite,
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
    fn work(self: *CleaveState, evaluator: *Fiber) MachineError!bool {
        const work_budget = evaluator.workBudget();
        while (true) switch (self.phase) {
            .validate => {
                const quotations = self.quotations.borrow();
                const total = self.count();
                const end = self.index + work_budget.take(total - self.index);
                while (self.index != end) : (self.index += 1) {
                    if (!quotations.isQuotation(self.index))
                        return evaluator.typeError("a list of quotations");
                }
                if (self.index != total) return false;
                self.phase = if (total == 0) .done else .run;
                return true;
            },
            .restored => {
                const paged = self.paged.borrowMut();
                if (!try paged.advance(evaluator)) return false;
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
                evaluator.discard(granted);
                self.index += granted;
                if (self.index != self.consumed) return false;
                self.phase = .push;
            },
            .push => {
                const results = self.paged.borrowMut().results.items();
                const end = self.pushed + work_budget.take(results.len - self.pushed);
                while (self.pushed != end) : (self.pushed += 1) try evaluator.pushOwned(results[self.pushed]);
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
        evaluator: *Fiber,
        self: *CleaveState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        if (self.running) {
            self.running = false;
            self.paged.borrowMut().base = window.base();
            self.phase = .restored;
            // `work` leaves its own progress in `phase`; `finishWork` would
            // reset it, so a suspension keeps it here.
            if (try self.work(evaluator)) return self.resumeAfter(self.phase);
            try evaluator.startDriver(SuspendedWork(CleaveState){ .state = self });
            return evaluator.suspendInlineApplication();
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
    paged: heap.Owned(PagedControl),
    site: machine.ApplicationSite,
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
    fn work(self: *CondState, evaluator: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(evaluator);
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
        evaluator: *Fiber,
        self: *CondState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        switch (self.phase) {
            .predicate => {
                const paged = self.paged.borrowMut();
                paged.base = window.base();
                self.selected = try popTestResult(evaluator, paged);
                return finishWork(CondState, self, evaluator, .restored);
            },
            // A `cond` action is the clause's whole result.
            .action => return null,
            .restored => return self.resumeAfter(.restored),
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn cond(evaluator: *Fiber) MachineError!void {
    var clauses = try evaluator.popValue();
    defer clauses.deinit();
    if (clauses.borrow() != .list) {
        return evaluator.typeError("a clause list");
    }
    const count: usize = @intCast(clauses.borrow().list.length());
    if (count == 0 or count % 2 == 0) {
        return evaluator.fail(.shape, "cond requires a nonempty odd clause list ending in else");
    }
    try evaluator.startDriver(CondDriver{
        .clauses = .init(clauses.take()),
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
        .provenance_target = try evaluator.applicationProvenanceTarget(),
    });
}

/// Validates every clause as bounded work, then runs the first test, or the
/// lone else.
const CondDriver = struct {
    clauses: heap.Owned(Value),
    site: machine.ApplicationSite,
    word: intern.TraceWord,
    provenance_target: ?*const machine.ApplicationProvenanceTarget,
    index: usize = 0,

    pub fn advance(evaluator: *Fiber, self: *CondDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const clauses = self.clauses.borrow();
        const count: usize = @intCast(clauses.list.length());
        const end = self.index + evaluator.workBudget().take(count - self.index);
        while (self.index != end) : (self.index += 1) {
            if (list.atUnchecked(clauses, self.index) != .list)
                return evaluator.typeError("quotation clauses and else");
        }
        if (self.index != count) return .stepped;
        const state = try evaluator.allocator.create(CondState);
        state.* = .{
            .clauses = .init(self.clauses.take()),
            .paged = .init(.init(.discarded)),
            .site = self.site,
            .word = self.word,
            .provenance_target = self.provenance_target,
            .phase = if (count == 1) .action else .predicate,
        };
        evaluator.retireDriver(self);
        const first = state.clause(0);
        if (count == 1) {
            try evaluator.beginInlineApplication(state.application(first));
        } else {
            try evaluator.beginPagingApplication(state.application(first), &state.paged.borrowMut().floor);
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
    paged: heap.Owned(PagedControl),
    site: machine.ApplicationSite,
    word: intern.TraceWord,
    provenance_target: ?*const machine.ApplicationProvenanceTarget,
    /// Descents whose `post` has yet to run.
    depth: usize = 0,
    selected: bool = false,
    phase: enum { predicate, base, pre, post, restored } = .predicate,

    fn application(self: *LinrecState) Application {
        return machine.typedApplication(self, self.predicate.borrow(), self.site, 0);
    }
    fn work(self: *LinrecState, evaluator: *Fiber) MachineError!bool {
        return self.paged.borrowMut().advance(evaluator);
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
        evaluator: *Fiber,
        self: *LinrecState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        switch (self.phase) {
            .predicate => {
                const paged = self.paged.borrowMut();
                paged.base = window.base();
                self.selected = try popTestResult(evaluator, paged);
                return finishWork(LinrecState, self, evaluator, .restored);
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

fn linrec(evaluator: *Fiber) MachineError!void {
    try evaluator.require(4);
    var post = try evaluator.popValue();
    defer post.deinit();
    var pre = try evaluator.popValue();
    defer pre.deinit();
    var base = try evaluator.popValue();
    defer base.deinit();
    var predicate = try evaluator.popValue();
    defer predicate.deinit();
    if (predicate.borrow() != .list or base.borrow() != .list or
        pre.borrow() != .list or post.borrow() != .list)
    {
        return evaluator.typeError("four quotations/lists");
    }
    const provenance_target = try evaluator.applicationProvenanceTarget();
    const state = try evaluator.allocator.create(LinrecState);
    state.* = .{
        .predicate = .init(predicate.take().list),
        .base = .init(base.take().list),
        .pre = .init(pre.take().list),
        .post = .init(post.take().list),
        .paged = .init(.init(.discarded)),
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
        .provenance_target = provenance_target,
    };
    try evaluator.beginPagingApplication(state.application(), &state.paged.borrowMut().floor);
}

const IterationKind = enum { each, zip_with, for_word, fold, scan, lex_cmp, infra };
const IterationState = struct {
    kind: IterationKind,
    left: heap.Owned(Value),
    right: ?heap.Owned(Value),
    quotation: heap.Owned(*Header),
    expected: ?heap.Owned(Value),
    results: ?heap.Owned(heap.OwnedValueBuffer) = null,
    site: machine.ApplicationSite,
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
        return .{ .apply = .{ .quotation = self.quotation.borrow(), .seeded = seeded } };
    }

    pub fn resumeApplication(
        evaluator: *Fiber,
        self: *IterationState,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        const base: usize = window.base();
        const observed = window.observed(evaluator.stack.items.len) orelse
            return evaluator.applicationContractError(
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
            .each, .zip_with => self.resumeCollect(evaluator, site, observed),
            .for_word => self.resumeFor(evaluator, site, observed),
            .fold, .scan => self.resumeFold(evaluator, site, observed),
            .lex_cmp => self.resumeLexCompare(evaluator, site, observed),
            .infra => resumeInfra(evaluator, base),
        };
    }

    fn resumeCollect(
        self: *IterationState,
        evaluator: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        const seeded: usize = if (self.kind == .each) 1 else 2;
        if (observed != 1) {
            return evaluator.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = seeded, .expected = 1, .observed = observed },
                self.index,
            );
        }
        var result = try evaluator.popDatum();
        self.results.?.borrowMut().appendOwned(result.take());
        self.index += 1;
        if (self.index == self.count) {
            try self.installCollected(evaluator);
            return null;
        }
        try self.pushInputs(evaluator);
        return self.step(@intCast(seeded));
    }

    fn resumeFor(
        self: *IterationState,
        evaluator: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 0) {
            return evaluator.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = 1, .expected = 0, .observed = observed },
                self.index,
            );
        }
        self.index += 1;
        if (self.index == self.count) return null;
        try self.pushInputs(evaluator);
        return self.step(1);
    }

    fn resumeFold(
        self: *IterationState,
        evaluator: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 1) {
            return evaluator.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = 2, .expected = 1, .observed = observed },
                self.index,
            );
        }
        var accumulator = try evaluator.popValue();
        defer accumulator.deinit();
        const accumulator_value = accumulator.borrow();
        if (self.kind == .scan) self.results.?.borrowMut().appendOwned(value.datum(accumulator.take()));
        self.index += 1;
        if (self.index == self.count) {
            if (self.kind == .scan) {
                try self.installCollected(evaluator);
            } else {
                try evaluator.pushOwned(accumulator.take());
            }
            return null;
        }
        if (self.kind == .scan) {
            try evaluator.pushBorrowed(accumulator_value);
        } else {
            try evaluator.pushOwned(accumulator.take());
        }
        try evaluator.pushBorrowed(list.atUnchecked(self.left.borrow(), self.index));
        return self.step(2);
    }

    /// A comparator's 0 moves to the next pair; any other int is the order.
    /// A shared prefix that is equal throughout orders by length.
    fn resumeLexCompare(
        self: *IterationState,
        evaluator: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 1) {
            return evaluator.applicationContractError(
                site,
                self.quotation.borrow(),
                self.expected.?.borrow(),
                .{ .seeded = 2, .expected = 1, .observed = observed },
                self.index,
            );
        }
        var result = try evaluator.popValue();
        defer result.deinit();
        if (result.borrow() != .int) return evaluator.typeError("an int comparator result");
        if (result.borrow().int != 0) {
            try evaluator.pushOwned(result.take());
            return null;
        }
        self.index += 1;
        if (self.index == self.count) {
            try pushLengthOrder(evaluator, self.left.borrow(), self.right.?.borrow());
            return null;
        }
        try self.pushInputs(evaluator);
        return self.step(2);
    }

    fn resumeInfra(evaluator: *Fiber, base: usize) MachineError!?ApplicationStep {
        try InfraResultDriver.install(evaluator, base);
        return null;
    }

    fn installCollected(self: *IterationState, evaluator: *Fiber) error{OutOfMemory}!void {
        const values = self.results.?.take();
        self.results = null;
        try evaluator.startDriver(CollectedDriver{
            .materializer = .init(.init(evaluator.allocator, values.values())),
            .values = .init(values),
        });
    }

    fn pushInputs(self: *IterationState, evaluator: *Fiber) MachineError!void {
        const left = self.left.borrow();
        try evaluator.pushBorrowed(if (self.kind == .for_word and left == .dict)
            dict.valueAt(left.dict, self.index)
        else
            inputAt(left, self.index));
        if (self.kind == .zip_with or self.kind == .lex_cmp) try evaluator.pushBorrowed(inputAt(
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
    site: machine.ApplicationSite,
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
        } };
    }

    pub fn resumeApplication(
        evaluator: *Fiber,
        self: *UpdateApplication,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        const state = self.state.borrow();
        evaluator.active_word = state.word;
        evaluator.chargeContinuationStep();
        const observed = window.observed(evaluator.stack.items.len) orelse
            return evaluator.applicationContractError(
                site,
                state.quotation.borrow(),
                state.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = 0 },
                state.application_index,
            );
        if (observed != 1)
            return evaluator.applicationContractError(
                site,
                state.quotation.borrow(),
                state.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = observed },
                state.application_index,
            );
        var result = try evaluator.popValue();
        state.values.borrowMut().replaceOwned(
            state.positions.?.borrow()[state.application_index],
            result.take(),
        );
        state.application_index += 1;
        if (state.application_index != state.positions.?.borrow().len) {
            try evaluator.pushBorrowed(state.values.borrow().values()[
                state.positions.?.borrow()[state.application_index]
            ]);
            return self.step();
        }
        if (state.mode != .list_selector) state.copy_index = 0;
        state.phase = if (state.mode == .list_selector) .materialize_list else .fill_pairs;
        try evaluator.startDriver(UpdateWorkDriver{ .state = .init(self.state.take()) });
        return null;
    }
};

const UpdateWorkDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    state: heap.Owned(*UpdateState),

    fn launchApplication(
        evaluator: *Fiber,
        self: *UpdateWorkDriver,
    ) MachineError!machine.WorkProgress {
        const state = self.state.borrow();
        if (state.positions.?.borrow().len == 0)
            return .{ .output = state.collection.take() };
        var stack = try evaluator.reserveStack(1);
        stack.pushBorrowed(state.values.borrow().values()[state.positions.?.borrow()[0]]);
        state.phase = .apply;
        const application_state = try evaluator.allocator.create(UpdateApplication);
        application_state.* = .{ .state = .init(self.state.take()) };
        try evaluator.beginIsolatedApplication(application_state.application());
        return .completed;
    }

    fn listPosition(evaluator: *Fiber, state: *const UpdateState, selector: Value) MachineError!usize {
        if (selector != .int) return evaluator.typeError("an integer list index");
        if (selector.int < 0) return evaluator.fail(.domain, "update index is negative");
        const position = std.math.cast(usize, selector.int) orelse
            return evaluator.fail(.domain, "update index is out of bounds");
        if (position >= state.collection.borrow().list.length())
            return evaluator.fail(.domain, "update index is out of bounds");
        return position;
    }

    pub fn advance(evaluator: *Fiber, self: *UpdateWorkDriver) MachineError!machine.WorkProgress {
        const state = self.state.borrow();
        evaluator.active_word = state.word;
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (!work.exhausted()) switch (state.phase) {
            .count_positions => {
                const progress = try state.selector_cursor.?.borrowMut().advanceOne();
                _ = work.spend();
                switch (progress) {
                    .pending => {},
                    .depth_exceeded => return evaluator.fail(
                        .domain,
                        "update selector nesting exceeds 256 levels",
                    ),
                    .leaf => |selector| {
                        if (state.mode == .list_selector)
                            _ = try listPosition(evaluator, state, selector);
                        state.position_count += 1;
                    },
                    .complete => {
                        state.selector_cursor.?.deinit(evaluator.releases, evaluator.allocator);
                        state.selector_cursor = null;
                        state.positions = .init(try evaluator.allocator.alloc(usize, state.position_count));
                        state.selector_cursor = .init(try support.PervasiveSelectorCursor.init(
                            evaluator.allocator,
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
                    .depth_exceeded => return evaluator.fail(.domain, "update selector nesting exceeds 256 levels"),
                    .leaf => |selector| {
                        state.positions.?.borrow()[state.position_index] =
                            try listPosition(evaluator, state, selector);
                        state.position_index += 1;
                    },
                    .complete => {
                        state.selector_cursor.?.deinit(evaluator.releases, evaluator.allocator);
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
                        evaluator.allocator,
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
                            return evaluator.fail(.domain, "update could not find the dict key");
                        positions[state.position_index] = state.finder.?.borrow().foundIndex().?;
                        state.finder.?.deinit(evaluator.releases, evaluator.allocator);
                        state.finder = null;
                        state.requested_key = null;
                        state.position_index += 1;
                    },
                }
            },
            .copy_values => {
                const count = state.values.borrow().capacity();
                if (state.copy_index == count) return launchApplication(evaluator, self);
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
                        evaluator.allocator,
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
                        evaluator.allocator,
                        state.values.borrow().values(),
                    ));
                return switch (try state.list_materializer.?.borrowMut().advance(work)) {
                    .pending => .stepped,
                    .complete => |result| completed: {
                        state.list_materializer.?.deinit(
                            evaluator.releases,
                            evaluator.allocator,
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

fn update(evaluator: *Fiber) MachineError!void {
    return startUpdate(evaluator, .core_selector);
}

pub fn updateDictKeysForModule(evaluator: *Fiber) MachineError!void {
    return startUpdate(evaluator, .dictionary_key_list);
}

fn startUpdate(evaluator: *Fiber, policy: UpdatePolicy) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    var selector = try evaluator.popValue();
    defer selector.deinit();
    var collection = try evaluator.popValue();
    defer collection.deinit();

    return startUpdateOwned(
        evaluator,
        policy,
        collection.take(),
        selector.take(),
        quotation.take(),
    );
}

fn startUpdateOwned(
    evaluator: *Fiber,
    policy: UpdatePolicy,
    collection_value: Value,
    selector_value: Value,
    quotation_value: Value,
) MachineError!void {
    var quotation = heap.OwnedValue.init(evaluator.releases, quotation_value);
    defer quotation.deinit();
    var selector = heap.OwnedValue.init(evaluator.releases, selector_value);
    defer selector.deinit();
    var collection = heap.OwnedValue.init(evaluator.releases, collection_value);
    defer collection.deinit();

    const mode: UpdateMode = switch (collection.borrow()) {
        .list => if (policy == .core_selector) .list_selector else return evaluator.typeError("a dict"),
        .dict => switch (policy) {
            .core_selector => .dictionary_key,
            .dictionary_key_list => .dictionary_key_list,
        },
        else => return evaluator.typeError(if (policy == .core_selector) "a list or dict" else "a dict"),
    };
    if (policy != .core_selector and selector.borrow() != .list)
        return evaluator.typeError("a dictionary selector list");

    const collection_count: usize = switch (mode) {
        .list_selector => @intCast(collection.borrow().list.length()),
        .dictionary_key, .dictionary_key_list => @intCast(collection.borrow().dict.length()),
    };
    var values = try heap.OwnedValueBuffer.init(evaluator.releases, collection_count);
    defer values.deinit();
    var expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "value", "--", "value" }),
    );
    defer expected.deinit();
    const initial_phase: UpdatePhase = switch (mode) {
        .list_selector => if (selector.borrow() == .list) .count_positions else .copy_values,
        .dictionary_key => .find_positions,
        .dictionary_key_list => .find_positions,
    };

    const state = try evaluator.allocator.create(UpdateState);
    var state_owner: ?*UpdateState = state;
    errdefer if (state_owner) |owned| heap.destroyDriver(
        evaluator.releases,
        evaluator.allocator,
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
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
    };

    if (mode == .list_selector) {
        if (state.selector.borrow() == .list) {
            state.selector_cursor = .init(try support.PervasiveSelectorCursor.init(
                evaluator.allocator,
                state.selector.borrow(),
            ));
            state.phase = .count_positions;
        } else {
            if (state.selector.borrow() != .int)
                return evaluator.typeError("an integer list index");
            if (state.selector.borrow().int < 0)
                return evaluator.fail(.domain, "update index is negative");
            const position = std.math.cast(usize, state.selector.borrow().int) orelse
                return evaluator.fail(.domain, "update index is out of bounds");
            if (position >= collection_count)
                return evaluator.fail(.domain, "update index is out of bounds");
            state.positions = .init(try evaluator.allocator.alloc(usize, 1));
            state.positions.?.borrow()[0] = position;
            state.phase = .copy_values;
        }
    } else {
        const position_count: usize = if (mode == .dictionary_key_list)
            @intCast(state.selector.borrow().list.length())
        else
            1;
        state.positions = .init(try evaluator.allocator.alloc(usize, position_count));
        state.pairs = .init(try evaluator.allocator.alloc(dict.Pair, collection_count));
        state.phase = .find_positions;
    }
    state_owner = null;
    try evaluator.startDriver(UpdateWorkDriver{ .state = .init(state) });
}

const CollectedDriver = struct {
    values: heap.Owned(heap.OwnedValueBuffer),
    materializer: heap.Owned(list.ValueMaterializer),
    result: ?heap.Owned(Value) = null,

    pub fn advance(evaluator: *Fiber, self: *CollectedDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.result == null) {
            switch (try self.materializer.borrowMut().advance(evaluator.workBudget())) {
                .pending => return .stepped,
                .complete => |result| {
                    self.result = .init(result);
                    return .stepped;
                },
            }
        }
        self.values.deinit(evaluator.releases, evaluator.allocator);
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
    site: machine.ApplicationSite,
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
    fn fillTyped(self: *StencilBootstrapDriver, evaluator: *Fiber) MachineError!?bool {
        const control = self.control.borrow();
        const input = control.input.borrow().list;
        switch (input.kind()) {
            inline .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4 => |kind| {
                if (self.typed_window == null) self.typed_window = .init(.{
                    .builder = try heap.AnyListBuilder.init(evaluator.allocator, kind, control.width, control.width),
                });
                var reader = heap.LeafReader(kind).acquire(input);
                defer reader.release(evaluator.releases);
                const run = evaluator.workBudget().take(control.width - self.fill_index);
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

    pub fn advance(
        evaluator: *Fiber,
        self: *StencilBootstrapDriver,
    ) MachineError!machine.WorkProgress {
        evaluator.active_word = self.control.borrow().word;
        try evaluator.pollKernel();
        const control = self.control.borrow();
        if (self.materializer == null) if (try self.fillTyped(evaluator)) |complete| {
            if (!complete) return .stepped;
            var window = self.typed_window.?.take();
            self.typed_window = null;
            return self.apply(evaluator, .{ .list = window.builder.finish() });
        };
        if (self.materializer == null) {
            const end = self.fill_index + evaluator.workBudget().take(control.width - self.fill_index);
            while (self.fill_index != end) : (self.fill_index += 1) {
                self.window_values.borrowMut().appendBorrowed(list.atUnchecked(
                    control.input.borrow(),
                    control.index + self.fill_index,
                ));
            }
            if (self.fill_index != control.width) return .stepped;
            self.materializer = .init(.init(
                evaluator.allocator,
                self.window_values.borrow().values(),
            ));
        }
        switch (try self.materializer.?.borrowMut().advance(evaluator.workBudget())) {
            .pending => return .stepped,
            .complete => |window| return self.apply(evaluator, window),
        }
    }

    /// Hands the finished window to the quotation; consumes `window`.
    fn apply(self: *StencilBootstrapDriver, evaluator: *Fiber, window: Value) MachineError!machine.WorkProgress {
        var window_owner = heap.OwnedValue.init(evaluator.releases, window);
        defer window_owner.deinit();
        const state = try evaluator.allocator.create(StencilApplication);
        var state_owner: ?*StencilApplication = state;
        errdefer if (state_owner) |owned| heap.destroyDriver(
            evaluator.releases,
            evaluator.allocator,
            owned,
        );
        state.* = .{ .control = .init(self.control.take()) };
        var stack = self.stack;
        evaluator.retireDriver(self);
        stack.pushBorrowed(window_owner.borrow());
        state_owner = null;
        try evaluator.beginIsolatedApplication(state.application());
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
        evaluator: *Fiber,
        self: *StencilApplication,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        const control = self.control.borrowMut();
        evaluator.active_word = control.word;
        evaluator.chargeContinuationStep();
        const observed = window.observed(evaluator.stack.items.len) orelse
            return evaluator.applicationContractError(
                site,
                control.quotation.borrow(),
                control.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = 0 },
                control.index,
            );
        if (observed != 1)
            return evaluator.applicationContractError(
                site,
                control.quotation.borrow(),
                control.expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = observed },
                control.index,
            );
        var result = try evaluator.popDatum();
        control.results.appendOwned(result.take());
        control.index += 1;
        if (control.index == control.count) {
            const values = control.results.take();
            try evaluator.startDriver(CollectedDriver{
                .materializer = .init(.init(evaluator.allocator, values.values())),
                .values = .init(values),
            });
            return null;
        }
        const stack = try evaluator.reserveStack(1);
        const window_values = try heap.OwnedValueBuffer.init(
            evaluator.releases,
            control.width,
        );
        const next = StencilBootstrapDriver{
            .control = .init(self.control.take()),
            .window_values = .init(window_values),
            .stack = stack,
        };
        try evaluator.startDriver(next);
        return null;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn stencil(evaluator: *Fiber) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popQuotation();
    defer quotation.deinit();
    var width_value = try evaluator.popValue();
    defer width_value.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (input.borrow() != .list or width_value.borrow() != .int)
        return evaluator.typeError("a list, positive int width, and quotation");
    const width_integer = width_value.borrow().int;
    if (width_integer <= 0)
        return evaluator.fail(.domain, "stencil requires a positive width");
    const width = std.math.cast(usize, width_integer) orelse
        return evaluator.fail(.domain, "stencil width is too large");
    const input_count: usize = @intCast(input.borrow().list.length());
    const count = if (width > input_count) 0 else input_count - width + 1;
    if (count == 0) {
        try pushGenericEmpty(evaluator);
        return;
    }
    var expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "window", "--", "result" }),
    );
    defer expected.deinit();
    var results = try heap.OwnedValueBuffer.init(evaluator.releases, count);
    defer results.deinit();
    var window_values = try heap.OwnedValueBuffer.init(evaluator.releases, width);
    defer window_values.deinit();
    const stack = try evaluator.reserveStack(1);
    const control = StencilControl{
        .input = .init(input.take()),
        .quotation = .init(quotation.take().list),
        .expected = .init(expected.take()),
        .results = results.take(),
        .site = evaluator.applicationSite(),
        .count = count,
        .width = width,
        .word = evaluator.active_word,
    };
    try evaluator.startDriver(StencilBootstrapDriver{
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
    site: machine.ApplicationSite,
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
        } };
    }

    pub fn resumeApplication(
        evaluator: *Fiber,
        self: *UnfoldState,
        window: StackWindow,
        site: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        evaluator.active_word = self.word;
        evaluator.chargeContinuationStep();
        const observed = window.observed(evaluator.stack.items.len) orelse
            return evaluator.applicationContractError(
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
            .predicate => self.resumePredicate(evaluator, site, observed),
            .step => self.resumeStep(evaluator, site, observed),
        };
    }

    fn resumePredicate(
        self: *UnfoldState,
        evaluator: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 1)
            return evaluator.applicationContractError(
                site,
                self.predicate.borrow(),
                self.predicate_expected.borrow(),
                .{ .seeded = 1, .expected = 1, .observed = observed },
                self.index,
            );
        var predicate_result = try evaluator.popValue();
        defer predicate_result.deinit();
        if (try boolValue(evaluator, &predicate_result)) {
            try evaluator.pushBorrowed(self.current.borrow());
            self.phase = .step;
            return self.nextStep();
        }
        const count = self.items.borrow().count;
        const buffer = try heap.OwnedValueBuffer.init(evaluator.releases, count);
        const iterator = self.items.borrow().iterator();
        try evaluator.pushOwned(self.current.take());
        try evaluator.startDriver(UnfoldCollectDriver{
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
        evaluator: *Fiber,
        site: *machine.ApplicationContractSite,
        observed: usize,
    ) MachineError!?ApplicationStep {
        if (observed != 2)
            return evaluator.applicationContractError(
                site,
                self.step_quotation.borrow(),
                self.step_expected.borrow(),
                .{ .seeded = 1, .expected = 2, .observed = observed },
                self.index,
            );
        var item = try evaluator.popDatum();
        defer item.deinit();
        var next_state = try evaluator.popValue();
        defer next_state.deinit();
        try self.items.borrowMut().append(item.borrow());
        try self.values.borrowMut().appendOwned(item.take());
        self.current.deinit(evaluator.releases, evaluator.allocator);
        self.current = .init(next_state.take());
        self.index += 1;
        self.phase = .predicate;
        try evaluator.pushBorrowed(self.current.borrow());
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
        evaluator: *Fiber,
        self: *UnfoldCollectDriver,
    ) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const end = self.copied + evaluator.workBudget().take(self.count - self.copied);
        while (self.copied != end) : (self.copied += 1)
            self.result.borrowMut().appendBorrowed(self.iterator.next().?.*);
        if (self.copied != self.count) return .stepped;
        const result = self.result.take();
        evaluator.retireDriver(self);
        try evaluator.startDriver(CollectedDriver{
            .materializer = .init(.init(evaluator.allocator, result.values())),
            .values = .init(result),
        });
        return .detached;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn unfold(evaluator: *Fiber) MachineError!void {
    try evaluator.require(3);
    var step_quotation = try evaluator.popQuotation();
    defer step_quotation.deinit();
    var predicate = try evaluator.popQuotation();
    defer predicate.deinit();
    var initial = try evaluator.popValue();
    defer initial.deinit();
    var predicate_expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "state", "--", "bool" }),
    );
    defer predicate_expected.deinit();
    var step_expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "state", "--", "state", "item" }),
    );
    defer step_expected.deinit();
    var values = heap.Owned(heap.OwnedValueChain).init(
        try .init(evaluator.releases),
    );
    defer values.deinit(evaluator.releases, evaluator.allocator);
    const state = try evaluator.allocator.create(UnfoldState);
    var state_owner: ?*UnfoldState = state;
    errdefer if (state_owner) |owned| heap.destroyDriver(
        evaluator.releases,
        evaluator.allocator,
        owned,
    );
    state.* = .{
        .current = .init(initial.take()),
        .predicate = .init(predicate.take().list),
        .step_quotation = .init(step_quotation.take().list),
        .predicate_expected = .init(predicate_expected.take()),
        .step_expected = .init(step_expected.take()),
        .values = .init(values.take()),
        .items = .init(.init(evaluator.allocator)),
        .site = evaluator.applicationSite(),
        .word = evaluator.active_word,
    };
    try evaluator.pushBorrowed(state.current.borrow());
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application());
}

const InfraResultDriver = struct {
    base: usize,
    materializer: heap.Owned(list.ValueMaterializer),
    result: ?heap.Owned(Value) = null,

    fn install(evaluator: *Fiber, base: usize) error{OutOfMemory}!void {
        // The isolated stack becomes a list, so each value enters as data
        // (`value.datum`); the operands are discarded once materialized.
        for (evaluator.stack.items[base..]) |*item| item.* = value.datum(item.*);
        try evaluator.startDriver(InfraResultDriver{
            .base = base,
            .materializer = .init(.init(evaluator.allocator, evaluator.stack.items[base..])),
        });
    }

    pub fn advance(evaluator: *Fiber, self: *InfraResultDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.result == null) {
            switch (try self.materializer.borrowMut().advance(evaluator.workBudget())) {
                .pending => return .stepped,
                .complete => |result| {
                    self.result = .init(result);
                    return .stepped;
                },
            }
        }
        const work = evaluator.workBudget();
        while (evaluator.stack.items.len != self.base and work.spend()) {
            var discarded = try evaluator.popValue();
            discarded.deinit();
        }
        if (evaluator.stack.items.len != self.base) return .stepped;
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

    pub fn advance(evaluator: *Fiber, self: *InfraBootstrapDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const iteration = self.iteration.borrow();
        const end = self.index + evaluator.workBudget().take(iteration.count - self.index);
        while (self.index != end) : (self.index += 1) {
            const item = list.atUnchecked(iteration.left.borrow(), self.index);
            self.stack.pushBorrowed(item);
        }
        if (self.index != iteration.count) return .stepped;
        std.debug.assert(self.stack.complete());
        const application = iteration.application(@intCast(iteration.count));
        _ = self.iteration.take();
        try evaluator.beginIsolatedApplication(application);
        return .completed;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn each(evaluator: *Fiber) MachineError!void {
    return evaluator.continueWithIdiom(.each, eachGeneric);
}
fn eachGeneric(evaluator: *Fiber) MachineError!void {
    return startUnaryIteration(evaluator, .each);
}

fn forWord(evaluator: *Fiber) MachineError!void {
    return startUnaryIteration(evaluator, .for_word);
}

fn startUnaryIteration(evaluator: *Fiber, kind: IterationKind) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list)
        return evaluator.typeError(if (kind == .each or kind == .for_word)
            "a list or dict and quotation"
        else
            "a list and quotation");
    if (kind == .each and input.borrow() == .dict) {
        const keys = dict.keysOf(input.borrow().dict);
        heap.retainValue(keys);
        var selector = heap.OwnedValue.init(evaluator.releases, keys);
        defer selector.deinit();
        return startUpdateOwned(
            evaluator,
            .dictionary_key_list,
            input.take(),
            selector.take(),
            quotation.take(),
        );
    }
    if (input.borrow() != .list and !(kind == .for_word and input.borrow() == .dict))
        return evaluator.typeError(if (kind == .each or kind == .for_word)
            "a list or dict and quotation"
        else
            "a list and quotation");
    const count: usize = @intCast(switch (input.borrow()) {
        .list => |header| header.length(),
        .dict => |header| header.length(),
        else => unreachable,
    });
    if (count == 0) {
        if (kind == .each) try pushGenericEmpty(evaluator);
        return;
    }
    var expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(
            evaluator.allocator,
            if (kind == .each) &.{ "a", "--", "b" } else &.{ "a", "--" },
        ),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        kind,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releases, evaluator.allocator, state);
    const state = state_owner.?;
    if (kind == .each) state.results = .init(try .init(evaluator.releases, count));
    try state.pushInputs(evaluator);
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(1));
}

fn zipWith(evaluator: *Fiber) MachineError!void {
    return evaluator.continueWithIdiom(.zip_with, zipWithGeneric);
}
fn zipWithGeneric(evaluator: *Fiber) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    const left_list = left.borrow() == .list;
    const right_list = right.borrow() == .list;
    if (!left_list and !right_list) return evaluator.typeError("at least one list");
    const count: usize = if (left_list)
        @intCast(left.borrow().list.length())
    else
        @intCast(right.borrow().list.length());
    if (left_list and right_list and left.borrow().list.length() != right.borrow().list.length()) {
        const left_len: usize = @intCast(left.borrow().list.length());
        const right_len: usize = @intCast(right.borrow().list.length());
        return evaluator.conformError(left_len, right_len);
    }
    if (count == 0) {
        try pushGenericEmpty(evaluator);
        return;
    }
    var expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "a", "b", "--", "c" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        .zip_with,
        &left,
        &right,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releases, evaluator.allocator, state);
    const state = state_owner.?;
    state.results = .init(try .init(evaluator.releases, count));
    try state.pushInputs(evaluator);
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(2));
}

fn fold(evaluator: *Fiber) MachineError!void {
    return evaluator.continueWithIdiom(.fold, foldGeneric);
}
fn foldGeneric(evaluator: *Fiber) MachineError!void {
    return startFold(evaluator, .fold);
}

fn fold1(evaluator: *Fiber) MachineError!void {
    return evaluator.continueWithIdiom(.fold1, fold1Generic);
}
fn fold1Generic(evaluator: *Fiber) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return evaluator.typeError("a list and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    if (count == 0) return evaluator.fail(.domain, "fold1 requires a non-empty list");
    if (count == 1) return evaluator.pushBorrowed(list.atUnchecked(input.borrow(), 0));
    var expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "acc", "a", "--", "acc" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        .fold,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releases, evaluator.allocator, state);
    const state = state_owner.?;
    // The first element is the accumulator, so the walk starts at the second.
    state.index = 1;
    try evaluator.pushBorrowed(list.atUnchecked(state.left.borrow(), 0));
    try evaluator.pushBorrowed(list.atUnchecked(state.left.borrow(), 1));
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(2));
}

fn lexCmpWith(evaluator: *Fiber) MachineError!void {
    return evaluator.continueWithIdiom(.lex_cmp, lexCmpWithGeneric);
}
fn lexCmpWithGeneric(evaluator: *Fiber) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var right = try evaluator.popValue();
    defer right.deinit();
    var left = try evaluator.popValue();
    defer left.deinit();
    if (quotation.borrow() != .list or left.borrow() != .list or right.borrow() != .list)
        return evaluator.typeError("two lists and a comparator");
    const shared: usize = @intCast(@min(left.borrow().list.length(), right.borrow().list.length()));
    if (shared == 0) return pushLengthOrder(evaluator, left.borrow(), right.borrow());
    var expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "left-element", "right-element", "--", "order" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        .lex_cmp,
        &left,
        &right,
        &quotation,
        &expected,
        shared,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releases, evaluator.allocator, state);
    const state = state_owner.?;
    try state.pushInputs(evaluator);
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(2));
}

/// Two lists whose shared prefix is equal order by length.
fn pushLengthOrder(evaluator: *Fiber, left: Value, right: Value) error{OutOfMemory}!void {
    try evaluator.pushOwned(.{ .int = switch (std.math.order(left.list.length(), right.list.length())) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } });
}

fn scan(evaluator: *Fiber) MachineError!void {
    return evaluator.continueWithIdiom(.scan, scanGeneric);
}
fn scanGeneric(evaluator: *Fiber) MachineError!void {
    return startFold(evaluator, .scan);
}

fn startFold(evaluator: *Fiber, kind: IterationKind) MachineError!void {
    try evaluator.require(3);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var accumulator = try evaluator.popValue();
    defer accumulator.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return evaluator.typeError("a list, accumulator, and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    if (count == 0) {
        if (kind == .scan) {
            try pushGenericEmpty(evaluator);
        } else {
            try evaluator.pushOwned(accumulator.take());
        }
        return;
    }
    var expected = heap.OwnedValue.init(
        evaluator.releases,
        try effectValue(evaluator.allocator, &.{ "acc", "a", "--", "acc" }),
    );
    defer expected.deinit();
    var state_owner: ?*IterationState = try createIteration(
        evaluator,
        kind,
        &input,
        null,
        &quotation,
        &expected,
        count,
    );
    errdefer if (state_owner) |state| heap.destroyDriver(evaluator.releases, evaluator.allocator, state);
    const state = state_owner.?;
    if (kind == .scan) state.results = .init(try .init(evaluator.releases, count));
    try evaluator.pushOwned(accumulator.take());
    try evaluator.pushBorrowed(list.atUnchecked(state.left.borrow(), 0));
    state_owner = null;
    try evaluator.beginIsolatedApplication(state.application(2));
}

fn infra(evaluator: *Fiber) MachineError!void {
    try evaluator.require(2);
    var quotation = try evaluator.popValue();
    defer quotation.deinit();
    var input = try evaluator.popValue();
    defer input.deinit();
    if (quotation.borrow() != .list or input.borrow() != .list)
        return evaluator.typeError("a list and quotation");
    const count: usize = @intCast(input.borrow().list.length());
    const state = try createIteration(evaluator, .infra, &input, null, &quotation, null, count);
    var state_owner: ?*IterationState = state;
    errdefer if (state_owner) |owned| heap.destroyDriver(
        evaluator.releases,
        evaluator.allocator,
        owned,
    );
    const stack = try evaluator.reserveStack(count);
    state_owner = null;
    try evaluator.startDriver(InfraBootstrapDriver{ .iteration = .init(state), .stack = stack });
}

fn createIteration(
    evaluator: *Fiber,
    kind: IterationKind,
    left: *heap.OwnedValue,
    right: ?*heap.OwnedValue,
    quotation: *heap.OwnedValue,
    expected: ?*heap.OwnedValue,
    count: usize,
) error{OutOfMemory}!*IterationState {
    const state = try evaluator.allocator.create(IterationState);
    state.* = .{
        .kind = kind,
        .left = .init(left.take()),
        .right = if (right) |item| .init(item.take()) else null,
        .quotation = .init(quotation.take().list),
        .expected = if (expected) |item| .init(item.take()) else null,
        .site = evaluator.applicationSite(),
        .count = count,
        .word = evaluator.active_word,
    };
    state.plan = .init(.init(state.quotation.borrow()));
    return state;
}

fn inputAt(input: Value, index: usize) Value {
    return if (input == .list) list.atUnchecked(input, index) else input;
}

fn pushGenericEmpty(evaluator: *Fiber) error{OutOfMemory}!void {
    try evaluator.pushOwned(try list.fromValuesGeneric(evaluator.allocator, &.{}));
}

fn effectValue(allocator: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}!Value {
    const forms = try allocator.alloc(Value, names.len);
    defer allocator.free(forms);
    for (names, 0..) |name, index| forms[index] = .{ .symbol = .{ .name = try intern.intern(name) } };
    return list.fromValuesGeneric(allocator, forms);
}

fn boolValue(evaluator: *Fiber, item: *const heap.OwnedValue) MachineError!bool {
    return switch (item.borrow()) {
        .int => |integer| switch (integer) {
            0 => false,
            1 => true,
            else => evaluator.typeError("a 0/1 bool"),
        },
        .float, .char, .symbol, .list, .dict, .task, .port, .address => evaluator.typeError("a 0/1 bool"),
    };
}
