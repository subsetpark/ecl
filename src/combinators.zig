//! Inline control and isolated quotation-taking combinators.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const floor_api = @import("floor.zig");
const stack_summary = @import("stack_summary.zig");
const poll = @import("poll.zig");
const support = @import("kernel_support.zig");

const Value = value.Value;
const Header = value.ListHandle;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
const Application = machine.Application;
const ApplicationStep = machine.ApplicationStep;
const StackWindow = machine.StackWindow;

/// How a combinator's stack effect follows from the literal quotations it
/// is given, for the words whose declared effect holds a row.
pub const Flow = union(enum) {
    /// No rule: the declared effect is all there is to read.
    declared,
    /// Runs its quotation where it stands.
    apply,
    /// Runs its quotation beneath one protected value.
    dip,
    /// Runs one of two quotations.
    branch,
    /// Runs its quotation and puts back what it consumed, above its results
    /// or below them.
    measured: enum { above, below },
    /// Runs this many quotations from the same inputs.
    cleave: usize,
    /// Runs this many quotations, each on its own inputs.
    spread: usize,
};

pub fn flow(primitive: env.PrimitiveImpl) Flow {
    if (primitive == &call) return .apply;
    if (primitive == &dip) return .dip;
    if (primitive == &ifWord) return .branch;
    if (primitive == &above) return .{ .measured = .above };
    if (primitive == &below) return .{ .measured = .below };
    if (primitive == &bi) return .{ .cleave = 2 };
    if (primitive == &tri) return .{ .cleave = 3 };
    if (primitive == &bracket) return .{ .spread = 2 };
    return .declared;
}

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    const definitions = comptime [_]env.BuiltinWord{
        .{ .name = "apply", .primitive = call, .effect = "quotation -- ...", .doc = "Run `quotation` on the current stack." },
        .{ .name = "if", .primitive = ifWord, .effect = "bool then else -- ...", .doc = "Run `then` when the condition is 1, `else` when it is 0." },
        .{ .name = "while", .primitive = whileWord, .effect = "cond body -- ...", .doc = "Evaluate `cond` and then restore any consumed elements. If `cond` pushes 1, consume the boolean, evaluate `body` in place and loop. If `cond` pushes 0, consume the boolean and exit." },
        .{ .name = "linrec", .primitive = linrec, .effect = "predicate base pre post -- ...", .doc = "Linear recursion. Evaluate `predicate` and then restore any consumed elements. If `predicate` pushes 1, consume the boolean and evaluate `base`. If `predicate` pushes 0, consume the boolean, evaluate `pre`, recurse from `pre`'s resulting stack, then evaluate `post`." },
        .{ .name = "dip", .primitive = dip, .effect = "x (q: ... -- ...) -- ... x", .doc = "Run a quotation beneath a protected top stack value: evaluate `q` with `x` removed, then push `x` on top of its results." },
        .{ .name = "dip-n", .primitive = dipN, .effect = "... (q: ... -- ...) n -- ...", .doc = "Run a quotation beneath the top `n` stack values: evaluate `q` with them removed, then they push them back in their original order after its results." },
        .{ .name = "above", .primitive = above, .effect = "... (q: ... -- ...) -- ...", .doc = "Evaluate `q`, then restore the values it consumed above its results, in their original order." },
        .{ .name = "below", .primitive = below, .effect = "... (q: ... -- ...) -- ...", .doc = "Evaluate `q`, then restore the values it consumed below its results, in their original order." },
        .{ .name = "bi", .primitive = bi, .effect = "... p q -- ...", .doc = "Apply `p` and `q` to the same view of the stack. Push `p`'s results, followed by `q`'s results." },
        .{ .name = "tri", .primitive = tri, .effect = "... p q r -- ...", .doc = "Apply `p`, `q`, `r` to the same view of the stack. Push `p`'s results, followed by `q`'s results, followed by `r`'s." },
        .{ .name = "cleave", .primitive = cleave, .effect = "... quotations -- ...", .doc = "Apply each quotation in `quotations` to the same view of the stack. Push each quotation's results to the stack in order." },
        .{ .name = "bracket", .primitive = bracket, .effect = "... p q -- ...", .doc = "Apply `q` to the inputs it takes from the top of the stack and `p` to the inputs it takes from what remains. Push `p`'s results, followed by `q`'s results, in place of everything they consumed. `q` runs first. `(p) (q) bracket` is `[(p) (q)] spread`." },
        .{ .name = "spread", .primitive = spread, .effect = "... quotations -- ...", .doc = "Apply each quotation in `quotations` to its own inputs: the last takes what it needs from the top of the stack, the one before it from what remains, and so on. Push every quotation's results in the order of the quotations, in place of everything they consumed. The quotations run last to first." },
        .{ .name = "times", .primitive = times, .effect = "n quotation -- ...", .doc = "Evaluate `quotation` `n` times." },
        .{ .name = "cond", .primitive = cond, .effect = "clauses -- ...", .doc = "Conditionally evaluate the first action in `clauses` whose predicate is true.\n\n`clauses` consists of an odd number of quotations; every odd quotation (except the last) is a predicate, and is directly followed by its associated action. If no predicate evaluates to true, then evaluate the last quotation (`else`). Each quotation runs against the same view of the stack." },
        .{ .name = "each", .primitive = each, .effect = "collection (q: a -- b) -- collection", .doc = "Evaluate `q` against every element in `collection`, collecting the results of each application in order in a collection of the same type. When `collection` is a dict, then `a` is a value in `collection`, and it's mapped back to the same key in the result." },
        .{ .name = "zip-with", .primitive = zipWith, .effect = "left right (q: a b -- c) -- list", .doc = "Conform `left` and `right`, and apply `q` to an element from each side, collecting the results in a list." },
        .{ .name = "for", .primitive = forWord, .effect = "collection (a --) --", .doc = "Evaluate `q` against every element in `collection`. `q` must leave no results." },
        .{ .name = "fold", .primitive = fold, .effect = "list accumulator (acc a -- acc) -- accumulator", .doc = "Reduce left-to-right from the supplied accumulator." },
        .{ .name = "fold1", .primitive = fold1, .effect = "list (acc a -- acc) -- value", .doc = "Reduce a nonempty list left to right from its first element." },
        .{ .name = "lex-cmp-with", .primitive = lexCmpWith, .effect = "left right (left-element right-element -- order) -- order", .doc = "Compare two lists lexicographically with a comparator that returns −1, 0, or 1. The comparator runs only through the first differing pair; when the shared prefix is equal, the lists are ordered by length." },
        .{ .name = "scan", .primitive = scan, .effect = "list accumulator (acc a -- acc) -- list", .doc = "Reduce left-to-right from the supplied accumulator. Return a list of the state of the accumulator after each reduction." },
        .{ .name = "stencil", .primitive = stencil, .effect = "list width (q: window -- result) -- list", .doc = "Apply `q` to each overlapping window of a positive int width, left-to-right." },
        .{ .name = "unfold", .primitive = unfold, .effect = "state (predicate: state -- bool) (step: state -- state item) -- state list", .doc = "Evaluate `predicate`; when it returns 0, return the current state and all generated items. When it returns 1, evaluate `step`, pushing `item` to `list`, and continue from the returned state." },
        .{ .name = "infra", .primitive = infra, .effect = "list (q: ... -- ...) -- list", .doc = "Evaluate `q` with `list`'s elements as stack, and push the resulting stack as a list." },
        .{ .name = "update", .primitive = update, .effect = "collection selector (q: value -- value) -- collection", .doc = "Apply `q` at the selected positions. A list collection's selector pervades with the same nested shape as `at` and is processed left to right, so repeated indices observe earlier updates. A dictionary selector is one whole-value key." },
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
        .measured = .init(.init(.discarded)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
        .provenance_target = provenance_target,
        .phase = .condition,
    };
    try fiber.beginApplication(state.application(state.condition.borrow()), .{ .measured = &state.measured.borrowMut().floor });
}

fn selectedProvenance(target: ?*const machine.ApplicationProvenanceTarget) machine.ApplicationProvenance {
    return if (target) |selected| .{ .selected_target = selected } else .boundary;
}

/// The boolean a test left for its guard.
fn popTestResult(fiber: *Fiber, region: *floor_api.Region) MachineError!bool {
    var result = try region.takeTestResult(fiber);
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

        /// Marks its word active before it polls, so a cancellation is attributed to it.
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
/// frame. The condition runs over a soft floor, so it takes from the stack
/// only what its words require; its result is read, its region dropped, and
/// what it admitted restored, all as bounded work. The body then runs in place.
/// Only restore work the turn's budget cannot cover stands up a driver, under
/// which the loop suspends until it is done.
const WhileState = struct {
    condition: heap.Owned(*Header),
    body: heap.Owned(*Header),
    measured: heap.Owned(floor_api.Region),
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
        const region = self.measured.borrowMut();
        region.reset();
        return .{ .apply = .{
            .quotation = self.condition.borrow(),
            .seeded = 0,
            .launch = .{ .measured = &region.floor },
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
        return self.measured.borrowMut().advance(fiber);
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
                const region = self.measured.borrowMut();
                region.base = window.base();
                const selected = try popTestResult(fiber, region);
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
    var protected = try fiber.popValue();
    defer protected.deinit();
    try startDip(fiber, &quotation, &protected);
}

/// `x quotation cons dip` without the list: the value beneath `x` is
/// protected and `x` stays on the stack for the quotation, as the first form
/// of `(x quotation...)` would have pushed it. The `cons apply` and `cons dip`
/// phrases in `idioms.zig` reach this.
pub fn dipBelowHead(fiber: *Fiber) MachineError!void {
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    var head = try fiber.popValue();
    defer head.deinit();
    var protected = try fiber.popValue();
    defer protected.deinit();
    try fiber.pushOwned(head.take());
    try startDip(fiber, &quotation, &protected);
}

fn startDip(fiber: *Fiber, quotation: *heap.OwnedValue, protected: *heap.OwnedValue) MachineError!void {
    const state = try fiber.allocator.create(DipState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .protected = .init(protected.take()),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
    };
    try fiber.beginApplication(state.application(), .in_place);
}

const DipState = struct {
    quotation: heap.Owned(*Header),
    protected: heap.Owned(Value),
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
        try fiber.pushOwned(self.protected.take());
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
    // Checked before the buffer is sized by it, and without admitting any.
    try floor_api.requireReachable(fiber, count);
    // The buffer is allocated before the quotation is taken: nothing after
    // it can fail, so the struct literal cannot leak it.
    const buffer = try heap.OwnedValueBuffer.init(fiber.releases, count);
    var control = heap.Owned(DipControl).init(.{
        .quotation = .init(quotation.take().list),
        .protected = .init(buffer),
        .count = count,
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
    });
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
/// each as `dip` would, admitting it across a soft floor, runs the quotation, and returns them in their
/// original order. Both phases are user-sized and advance only as far as the
/// turn's budget allows. The values are retained, so a symbol stays a value
/// rather than becoming code.
const DipControl = struct {
    quotation: heap.Owned(*Header),
    /// The protected values, the top of the stack first.
    protected: heap.Owned(heap.OwnedValueBuffer),
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
                    var taken = try fiber.popValue();
                    self.protected.borrowMut().appendOwned(taken.take());
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
                    try fiber.pushOwned(item);
                }
                if (self.index != 0) return .pending;
                return .finished;
            },
        };
    }

    pub fn retire(self: *DipControl, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.protected.deinit(releases, allocator);
        self.quotation.deinit(releases, allocator);
    }
};

const DipDriver = struct {
    control: heap.Owned(DipControl),

    /// Marks its word active before it polls, so a cancellation is attributed to it.
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
    return startMeasured(fiber, .above);
}
fn below(fiber: *Fiber) MachineError!void {
    return startMeasured(fiber, .below);
}
fn startMeasured(fiber: *Fiber, placement: floor_api.Placement) MachineError!void {
    var quotation = try fiber.popQuotation();
    defer quotation.deinit();
    const state = try fiber.allocator.create(MeasuredState);
    state.* = .{
        .quotation = .init(quotation.take().list),
        .measured = .init(.init(placement)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
    };
    try fiber.beginApplication(state.application(), .{ .measured = &state.measured.borrowMut().floor });
}

const MeasuredState = struct {
    quotation: heap.Owned(*Header),
    measured: heap.Owned(floor_api.Region),
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    phase: enum { run, restored } = .run,

    fn application(self: *MeasuredState) Application {
        return machine.typedApplication(self, self.quotation.borrow(), self.site, 0);
    }
    fn work(self: *MeasuredState, fiber: *Fiber) MachineError!bool {
        return self.measured.borrowMut().advance(fiber);
    }
    fn resumeAfter(_: *MeasuredState, _: @FieldType(MeasuredState, "phase")) ?ApplicationStep {
        return null;
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *MeasuredState,
        window: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        switch (self.phase) {
            .run => {
                self.measured.borrowMut().base = window.base();
                return finishWork(MeasuredState, self, fiber, .restored);
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
    var counts: CountedCleave.Counts = .{};
    // Read through a borrowed view: the list moves only once a launch is chosen.
    if (try countedInputs(fiber, .cleave, &.{ .list = .init(quotations.borrow()) }, &counts)) |inputs|
        return launchCountedCleave(fiber, .cleave, .{ .list = .init(quotations.take()) }, counts, inputs);
    return startCleave(fiber, .cleave, .{ .list = .init(quotations.take()) }, .validate);
}
fn spread(fiber: *Fiber) MachineError!void {
    var quotations = try fiber.popValue();
    defer quotations.deinit();
    if (quotations.borrow() != .list) return fiber.typeError("a list of quotations");
    var counts: CountedCleave.Counts = .{};
    if (try countedInputs(fiber, .spread, &.{ .list = .init(quotations.borrow()) }, &counts)) |inputs|
        return launchCountedCleave(fiber, .spread, .{ .list = .init(quotations.take()) }, counts, inputs);
    return startCleave(fiber, .spread, .{ .list = .init(quotations.take()) }, .validate);
}

/// Which inputs each quotation of a list meets. A cleave runs every
/// quotation from the same inputs, first to last, and consumes the most any
/// one did. A spread runs them last to first, each consuming from the top of
/// what the ones after it left, so the inputs are theirs in order.
const Sharing = enum { cleave, spread };
fn bi(fiber: *Fiber) MachineError!void {
    return cleaveFixed(fiber, .cleave, 2);
}
fn tri(fiber: *Fiber) MachineError!void {
    return cleaveFixed(fiber, .cleave, 3);
}
fn bracket(fiber: *Fiber) MachineError!void {
    return cleaveFixed(fiber, .spread, 2);
}
/// `bi`, `tri`, and `bracket` take their quotations straight off the stack,
/// already validated, so no list is built and no validation phase runs.
fn cleaveFixed(fiber: *Fiber, sharing: Sharing, count: usize) MachineError!void {
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
    var counts: CountedCleave.Counts = .{};
    if (try countedInputs(fiber, sharing, &.{ .fixed = fixed }, &counts)) |inputs| {
        const quotations: CleaveQuotations = .{ .fixed = fixed };
        fixed.count = 0;
        return launchCountedCleave(fiber, sharing, quotations, counts, inputs);
    }
    return startCleave(fiber, sharing, .{ .fixed = fixed }, .run);
}

/// How many inputs the quotations consume together when every one has a
/// summary and those inputs are in reach, with each quotation's own counts
/// in `counts`. Null when the soft floor must find the counts or report
/// the failure.
fn countedInputs(
    fiber: *Fiber,
    sharing: Sharing,
    quotations: *const CleaveQuotations,
    counts: *CountedCleave.Counts,
) MachineError!?usize {
    const count = quotations.count();
    if (count == 0 or count > counts.consumed.len) return null;
    counts.publication = fiber.currentPublication();
    var inputs: usize = 0;
    for (0..count) |index| {
        if (!quotations.isQuotation(index)) return null;
        const summary = try stack_summary.of(fiber, fiber.applicationSite(), quotations.at(index)) orelse return null;
        counts.consumed[index] = @intCast(summary.consumed);
        counts.produced[index] = @intCast(summary.produced);
        inputs = switch (sharing) {
            .cleave => @max(inputs, summary.consumed),
            .spread => inputs + summary.consumed,
        };
    }
    // Counts read across a publication belong to no one definition set.
    if (fiber.currentPublication() != counts.publication) return null;
    return if (floor_api.reachable(fiber, inputs)) inputs else null;
}

/// Launches a cleave or spread whose quotations all have summaries. Owns
/// `quotations` on every path.
fn launchCountedCleave(
    fiber: *Fiber,
    sharing: Sharing,
    quotations: CleaveQuotations,
    counts: CountedCleave.Counts,
    inputs: usize,
) MachineError!void {
    var owned_quotations = heap.Owned(CleaveQuotations).init(quotations);
    // The word consumes its inputs, so any enclosing soft floor admits
    // them now.
    fiber.require(inputs) catch |err| {
        owned_quotations.deinit(fiber.releases, fiber.allocator);
        return err;
    };
    var state: CountedCleave = .{
        .sharing = sharing,
        .quotations = .init(owned_quotations.take()),
        .counts = counts,
        .inputs = inputs,
        .base = fiber.stack.items.len,
        .cursor = fiber.stack.items.len,
        .expected = fiber.stack.items.len,
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
        .publication = counts.publication,
    };
    state.recheck(fiber) catch |err| {
        heap.deinitDriverFields(fiber.releases, fiber.allocator, &state);
        return err;
    };
    state.prepare(fiber) catch |err| {
        heap.deinitDriverFields(fiber.releases, fiber.allocator, &state);
        return err;
    };
    const first = state.quotations.borrow().at(state.current());
    const site = state.site;
    const housed = try fiber.houseApplication(state);
    try fiber.beginApplication(housed.application(first, site, 0), .in_place);
}

/// A cleave or spread whose quotations all have summaries: each runs in
/// place over copies of the inputs it consumes, its results accumulate above
/// the inputs, and the consumed inputs are removed at the end. A spread's
/// results accumulate last quotation first, so they are put in order then.
const CountedCleave = struct {
    sharing: Sharing,
    quotations: heap.Owned(CleaveQuotations),
    counts: Counts,
    /// The most any quotation consumes.
    inputs: usize,
    /// The stack depth above the inputs: results accumulate from here.
    base: usize,
    /// The stack depth above the running quotation's inputs: `base` for a
    /// cleave, and lower by each quotation a spread has run.
    cursor: usize,
    /// The stack depth the running quotation leaves, by its summary.
    expected: usize,
    site: machine.ExecutionSite,
    word: intern.TraceWord,
    next: usize = 0,
    /// The publication the counts were read under.
    publication: u64,

    /// What each quotation consumes and leaves, by its index. A cleave of
    /// more quotations than these hold runs over the soft floor.
    const Counts = struct {
        consumed: [8]u8 = @splat(0),
        produced: [8]u8 = @splat(0),
        /// The publication read before any summary was, which every count
        /// here was read under.
        publication: u64 = 0,
    };

    /// The index of the quotation running or next to run.
    fn current(self: *const CountedCleave) usize {
        return switch (self.sharing) {
            .cleave => self.next,
            .spread => self.quotations.borrow().count() - 1 - self.next,
        };
    }
    /// Counts read under an earlier publication say nothing about words
    /// since redefined. After a publication, every quotation yet to run is
    /// read again and the baseline moves only once all of them agree, so no
    /// quotation runs on counts that were not read under the publication it
    /// runs in. Stops rather than run on counts that no longer hold.
    fn recheck(self: *CountedCleave, fiber: *Fiber) MachineError!void {
        const now = fiber.currentPublication();
        if (now == self.publication) return;
        const total = self.quotations.borrow().count();
        for (self.next..total) |step| {
            const index = switch (self.sharing) {
                .cleave => step,
                .spread => total - 1 - step,
            };
            const again = try stack_summary.of(fiber, self.site, self.quotations.borrow().at(index));
            const same = if (again) |summary|
                summary.consumed == self.counts.consumed[index] and summary.produced == self.counts.produced[index]
            else
                false;
            if (!same) return fiber.fail(.domain, "definitions changed while a cleave or spread was running");
        }
        // A publication during the reads leaves them under two.
        if (fiber.currentPublication() != now) return fiber.fail(.domain, "definitions changed while a cleave or spread was running");
        self.publication = now;
    }
    /// Copies the next quotation's inputs to the top of the stack.
    fn prepare(self: *CountedCleave, fiber: *Fiber) error{OutOfMemory}!void {
        const index = self.current();
        self.expected += self.counts.produced[index];
        try floor_api.copyInputs(fiber, self.cursor, self.counts.consumed[index]);
        if (self.sharing == .spread) self.cursor -= self.counts.consumed[index];
    }
    /// Puts a spread's result segments, left last quotation first, in the
    /// order of the quotations: the whole span reversed, then each segment.
    /// A constant bounds every count here.
    fn orderResults(self: *const CountedCleave, results: []Value) void {
        std.mem.reverse(Value, results);
        var start: usize = 0;
        for (0..self.quotations.borrow().count()) |index| {
            const length = self.counts.produced[index];
            std.mem.reverse(Value, results[start..][0..length]);
            start += length;
        }
    }

    pub fn resumeApplication(
        fiber: *Fiber,
        self: *CountedCleave,
        _: StackWindow,
        _: *machine.ApplicationContractSite,
    ) MachineError!?ApplicationStep {
        fiber.active_word = self.word;
        fiber.chargeContinuationStep();
        // A publication while the quotation ran may have changed a word it
        // called, so its counts cannot be trusted to describe what it did.
        if (fiber.currentPublication() != self.publication)
            return fiber.fail(.domain, "definitions changed while a cleave or spread was running");
        // A summary that disagreed with what its quotation did would have
        // been read from a wrong effect declaration.
        std.debug.assert(fiber.stack.items.len == self.expected);
        self.next += 1;
        if (self.next == self.quotations.borrow().count()) {
            const results = fiber.stack.items.len - self.base;
            floor_api.dropBeneath(fiber, self.inputs, results);
            if (self.sharing == .spread) self.orderResults(fiber.stack.items[fiber.stack.items.len - results ..]);
            return null;
        }
        try self.recheck(fiber);
        try self.prepare(fiber);
        return .{ .apply = .{
            .quotation = self.quotations.borrow().at(self.current()),
            .seeded = 0,
            .launch = .in_place,
        } };
    }

    pub const ownership: heap.DriverOwnership = .fields;
    /// Lives for one word's quotations and is small, so it takes a fiber
    /// slot when one is free.
    pub const housed_application = true;
};
fn startCleave(
    fiber: *Fiber,
    sharing: Sharing,
    quotations: CleaveQuotations,
    phase: @FieldType(CleaveState, "phase"),
) MachineError!void {
    var owned_quotations = heap.Owned(CleaveQuotations).init(quotations);
    const state = fiber.allocator.create(CleaveState) catch |err| {
        owned_quotations.deinit(fiber.releases, fiber.allocator);
        return err;
    };
    state.* = .{
        .sharing = sharing,
        .quotations = .init(owned_quotations.take()),
        .measured = .init(.init(switch (sharing) {
            .cleave => .collected,
            .spread => .taken,
        })),
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
    try fiber.beginApplication(owned.take().application(state.quotation()), .{ .measured = &state.measured.borrowMut().floor });
}

/// Finishes a cleave's validation when the turn ran out, then launches it.
const CleaveDriver = struct {
    state: heap.Owned(*CleaveState),

    /// Marks its word active before it polls, so a cancellation is attributed to it.
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

/// A cleave validates every quotation and then runs each over a soft
/// floor above the inputs, so each consumes exactly what its words require.
/// A quotation's results move into the control's buffer and its admitted
/// inputs come back, so the next quotation starts from the same inputs; the
/// inputs any quotation consumed are dropped at the end and the results put
/// back in order. Each phase is user-sized and advances only as far as the
/// turn's budget allows, and the inputs are retained values, so a symbol
/// input stays a value rather than becoming code.
const CleaveState = struct {
    sharing: Sharing,
    quotations: heap.Owned(CleaveQuotations),
    measured: heap.Owned(floor_api.Region),
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
    /// A spread runs its quotations last to first.
    fn quotation(self: *const CleaveState) *Header {
        return self.quotations.borrow().at(switch (self.sharing) {
            .cleave => self.next,
            .spread => self.count() - 1 - self.next,
        });
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
                const region = self.measured.borrowMut();
                if (!try region.advance(fiber)) return false;
                // A spread's quotation kept what it consumed.
                if (self.sharing == .cleave) self.consumed = @max(self.consumed, region.restored);
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
                // A spread gathered each region from its top down, last
                // quotation first, so the results read back to front.
                const results = self.measured.borrowMut().results.items();
                const end = self.pushed + work_budget.take(results.len - self.pushed);
                while (self.pushed != end) : (self.pushed += 1) try fiber.pushOwned(results[
                    switch (self.sharing) {
                        .cleave => self.pushed,
                        .spread => results.len - 1 - self.pushed,
                    }
                ]);
                if (self.pushed != results.len) return false;
                self.measured.borrowMut().results.clearRetainingCapacity();
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
        const region = self.measured.borrowMut();
        region.reset();
        return .{ .apply = .{
            .quotation = self.quotation(),
            .seeded = 0,
            .launch = .{ .measured = &region.floor },
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
            self.measured.borrowMut().base = window.base();
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
/// Each test runs over a soft floor, its result is read, its region
/// dropped, and what it admitted restored; the selected action then runs in
/// place.
const CondState = struct {
    clauses: heap.Owned(Value),
    measured: heap.Owned(floor_api.Region),
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
        return self.measured.borrowMut().advance(fiber);
    }
    /// The action a true test selected, the else when the tests ran out, or
    /// the next test.
    fn resumeAfter(self: *CondState, _: @FieldType(CondState, "phase")) ?ApplicationStep {
        if (self.selected) return self.actionStep(self.pair_index + 1);
        self.pair_index += 2;
        if (self.pair_index + 1 >= self.count()) return self.actionStep(self.count() - 1);
        self.phase = .predicate;
        const region = self.measured.borrowMut();
        region.reset();
        return .{ .apply = .{
            .quotation = self.clause(self.pair_index),
            .seeded = 0,
            .launch = .{ .measured = &region.floor },
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
                const region = self.measured.borrowMut();
                region.base = window.base();
                self.selected = try popTestResult(fiber, region);
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
            .measured = .init(.init(.discarded)),
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
            try fiber.beginApplication(state.application(first), .{ .measured = &state.measured.borrowMut().floor });
        }
        return .detached;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

/// One `linrec`'s application state, alive for the whole recursion under one
/// frame. Every level applies the same four quotations, so the recursion is
/// a sequence `pre … pre base post … post` and the levels pending `post` are
/// a count. Each predicate runs over a soft floor, its result is read, its
/// region dropped, and what it admitted restored; the branches run in place.
const LinrecState = struct {
    predicate: heap.Owned(*Header),
    base: heap.Owned(*Header),
    pre: heap.Owned(*Header),
    post: heap.Owned(*Header),
    measured: heap.Owned(floor_api.Region),
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
        return self.measured.borrowMut().advance(fiber);
    }
    fn resumeAfter(self: *LinrecState, _: @FieldType(LinrecState, "phase")) ?ApplicationStep {
        return if (self.selected) self.branchStep(.base) else self.branchStep(.pre);
    }
    fn predicateStep(self: *LinrecState) ApplicationStep {
        self.phase = .predicate;
        const region = self.measured.borrowMut();
        region.reset();
        return .{ .apply = .{
            .quotation = self.predicate.borrow(),
            .seeded = 0,
            .launch = .{ .measured = &region.floor },
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
                const region = self.measured.borrowMut();
                region.base = window.base();
                self.selected = try popTestResult(fiber, region);
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
        .measured = .init(.init(.discarded)),
        .site = fiber.applicationSite(),
        .word = fiber.active_word,
        .provenance_target = provenance_target,
    };
    try fiber.beginApplication(state.application(), .{ .measured = &state.measured.borrowMut().floor });
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

    /// Marks its word active before it polls, so a cancellation is attributed to it.
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
                            return fiber.failMissingKey("update could not find the dict key", state.requested_key.?);
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

/// Builds a window the application could not build within its turn, then
/// begins a fresh application with it. A boxed window is profiled from the
/// input's own cells, which `control` holds.
const StencilBootstrapDriver = struct {
    control: heap.Owned(StencilControl),
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

    /// Marks its word active before it polls, so a cancellation is attributed to it.
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
        if (self.materializer == null) self.materializer = .init(boxedWindow(fiber, &control));
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
        // The next window continues this application, as `each` continues
        // with its next element, when it can be built within the turn.
        var started: ?heap.Owned(list.ValueMaterializer) = null;
        errdefer if (started) |*materializer| materializer.deinit(fiber.releases, fiber.allocator);
        switch (try nextWindow(fiber, control)) {
            .built => |next_window| {
                var owner = heap.OwnedValue.init(fiber.releases, next_window);
                defer owner.deinit();
                try fiber.pushBorrowed(owner.borrow());
                return .{ .apply = .{
                    .quotation = control.quotation.borrow(),
                    .seeded = 1,
                    .launch = .isolated,
                } };
            },
            .profiling => |materializer| started = materializer,
            .deferred => {},
        }
        const stack = try fiber.reserveStack(1);
        const next = StencilBootstrapDriver{
            .control = .init(self.control.take()),
            .stack = stack,
            .materializer = started,
        };
        started = null;
        try fiber.startDriver(next);
        return null;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

/// The next window, as far as the turn's remaining budget builds it.
const NextWindow = union(enum) {
    /// Finished: the application continues with it.
    built: Value,
    /// A boxed window whose profiling the budget left unfinished.
    profiling: heap.Owned(list.ValueMaterializer),
    /// A typed window wider than the budget left, copied by the driver in
    /// granted runs.
    deferred,
};

/// Builds the window at `control.index`: a typed input's in one charged copy
/// when the remaining budget covers its width, a boxed input's by profiling
/// the input's own cells against the same budget.
fn nextWindow(fiber: *Fiber, control: *const StencilControl) error{OutOfMemory}!NextWindow {
    const input = control.input.borrow().list;
    switch (input.kind()) {
        inline .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4 => |kind| {
            const work = fiber.workBudget();
            if (work.remaining < control.width) return .deferred;
            var builder = try heap.AnyListBuilder.init(fiber.allocator, kind, control.width, control.width);
            const items = switch (builder) {
                inline else => |*typed| if (@TypeOf(typed.items()) == []heap.LeafElement(kind)) typed.items() else unreachable,
            };
            @memcpy(items, heap.leafElements(kind, input)[control.index..][0..control.width]);
            _ = work.take(control.width);
            return .{ .built = .{ .list = builder.finish() } };
        },
        .generic_spine => {
            var materializer = heap.Owned(list.ValueMaterializer).init(boxedWindow(fiber, control));
            errdefer materializer.deinit(fiber.releases, fiber.allocator);
            return switch (try materializer.borrowMut().advance(fiber.workBudget())) {
                .pending => .{ .profiling = materializer },
                .complete => |window| blk: {
                    materializer.deinit(fiber.releases, fiber.allocator);
                    break :blk .{ .built = window };
                },
            };
        },
        .dict, .task, .port, .address, .reserved_mask => unreachable,
    }
}

/// Profiles the boxed window at `control.index` from the input's own cells.
fn boxedWindow(fiber: *Fiber, control: *const StencilControl) list.ValueMaterializer {
    const cells = heap.valuesConst(control.input.borrow().list)[control.index..][0..control.width];
    return .init(fiber.allocator, cells);
}

fn stencil(fiber: *Fiber) MachineError!void {
    return fiber.continueWithIdiom(.stencil, stencilGeneric);
}
fn stencilGeneric(fiber: *Fiber) MachineError!void {
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
