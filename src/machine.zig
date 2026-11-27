//! Defunctionalized CEK evaluator, boundary unwinding, and error dicts.
const std = @import("std");
const session_options = @import("session_options");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const native_call = @import("native_call.zig");
const native_module = @import("native_module.zig");
const reader = @import("reader.zig");
const poll_api = @import("poll.zig");
const turn_core = @import("turn_core.zig");
const kernel_storage = @import("kernel_storage.zig");
const console_api = @import("console.zig");
const standard_streams = @import("standard_streams.zig");
const map_state = @import("module_snapshot.zig");
const external = @import("external.zig");
const scheduler_api = @import("scheduler.zig");
const idioms = @import("idioms.zig");
const binder = @import("binder.zig");
const reflection = @import("reflection.zig");
const error_values = @import("error_value.zig");
const park_api = @import("park.zig");
const resolution_plan = @import("resolution_plan.zig");
const module_lookup = @import("module_lookup.zig");
const load = @import("load.zig");
const failure_driver = @import("failure.zig");
const module_construction = @import("module_construction.zig");
const floor_api = @import("floor.zig");
const SoftFloor = floor_api.SoftFloor;
pub const Value = value.Value;
pub const Header = value.ListHandle;
pub const MachineError = error{ OutOfMemory, Ecl };
/// The absence of a named activation. A trace word is either a plain atom or
/// a module-local name qualified by the registration it was reached through,
/// so `none` is the one value that spells neither.
const no_word: intern.TraceWord = .none;
const max_frame_count = std.math.maxInt(u32);
const FrameIndex = enum(u32) { _ };
const EffectCheckIndex = enum(u32) { _ };
const ApplicationFrameIndex = enum(u32) { _ };
const ApplicationProvenanceNonce = enum(u32) { _ };
var next_application_provenance_nonce: std.atomic.Value(u64) = .init(1);
const fuel_quantum: u32 = 1024;
pub const kernel_poll_quantum: u32 = 65_536;
pub const IdiomMode = enum { automatic, generic_only };
pub const ErrorKind = enum {
    underflow,
    undefined_word,
    type,
    shape,
    conform,
    overflow,
    domain,
    contract,
    parse,
    io,
    cancelled,
    timeout,
    user,
    /// The spec closes this set, so `else` cannot silently absorb a new kind.
    /// A hyphenated addition would still need its own arm.
    pub fn symbol(self: ErrorKind) []const u8 {
        return switch (self) {
            .undefined_word => "undefined-word",
            else => @tagName(self),
        };
    }
};
pub const ErrorSite = struct {
    code: *Header,
    index: u32,
};
const OwnedCode = struct {
    header: ?*Header,

    fn retain(header: *Header) OwnedCode {
        heap.incRef(header);
        return .{ .header = header };
    }
    fn initOwned(header: *Header) OwnedCode {
        return .{ .header = header };
    }
    fn borrow(self: *const OwnedCode) *Header {
        return self.header.?;
    }
    fn take(self: *OwnedCode) *Header {
        const header = self.header.?;
        self.header = null;
        return header;
    }
    fn replaceBorrowed(self: *OwnedCode, releases: *heap.ReleaseDomain, header: *Header) void {
        heap.incRef(header);
        releases.releaseHeader(self.header.?);
        self.header = header;
    }
    fn deinit(self: *OwnedCode, releases: *heap.ReleaseDomain) void {
        if (self.header) |header| releases.releaseHeader(header);
        self.header = null;
    }
};
/// An optional dynamically selected quotation owned by exactly one
/// application frame. The driver continues to own the original quotation;
/// this field is populated only by moving an existing Eval-owned reference.
const ApplicationSelection = struct {
    /// Borrowed from the newest dynamically applied Eval until that Eval
    /// completes; pointer identity lets older suspended selections recognize
    /// that they are stale without a counter or another owned reference.
    latest: ?*Header = null,
    owned: ?*Header = null,

    fn selectBorrowed(self: *ApplicationSelection, code: *Header) void {
        self.latest = code;
    }

    /// Moves an Eval-owned reference into the application frame. Releasing a
    /// prior selection here is the release it would otherwise have received
    /// when its Eval completed, so selection tracking adds no reference-count
    /// operations to a successful application.
    fn completeOwned(
        self: *ApplicationSelection,
        releases: *heap.ReleaseDomain,
        code: *Header,
    ) void {
        if (self.latest != code) {
            releases.releaseHeader(code);
            return;
        }
        if (self.owned) |previous| releases.releaseHeader(previous);
        self.owned = code;
    }
    fn takeFailureSite(self: *ApplicationSelection, fallback: *Header) OwnedCode {
        if (self.takeSelected()) |selected| return selected;
        return .retain(fallback);
    }
    fn takeSelected(self: *ApplicationSelection) ?OwnedCode {
        const selected = self.owned orelse return null;
        self.owned = null;
        return .initOwned(selected);
    }
    fn deinit(self: *ApplicationSelection, releases: *heap.ReleaseDomain) void {
        if (self.owned) |selected| releases.releaseHeader(selected);
        self.* = .{};
    }
};
/// Opaque callback capability for consuming the candidate of exactly the
/// application that just completed. Generic drivers can return it to the
/// machine on a contract failure but cannot construct or retarget it.
pub const ApplicationContractSite = opaque {};
const ApplicationDepths = struct {
    seeded: usize,
    expected: usize,
    observed: usize,
};
const FailureSite = union(enum) {
    token: ErrorSite,
    contract_quotation: OwnedCode,
    explicit_location: struct {
        source_name: []u8,
        span: reader.Span,
    },

    fn deinit(self: *FailureSite, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .token => {},
            .contract_quotation => |*candidate| candidate.deinit(releases),
            .explicit_location => |location| releases.allocator.free(location.source_name),
        }
        self.* = undefined;
    }
};
/// Where a fiber's root activation runs.
const RootEntry = union(enum) {
    /// A root by its scope: the session's for a root fiber, core's for the
    /// bootstrap fiber, and a task's spawner's.
    scope: env.ScopeId,
    /// One registered module's own code, under the provenance of the
    /// registration it was read from.
    module: modules.ModuleRoot,
};
/// Who runs a fiber, and so what it may do. A root fiber runs a submission
/// or a host-driven load and may define. A task fiber runs in its spawner's
/// scope without being a root of its own, so it may not define. The bootstrap
/// fiber builds the prelude before any scheduler exists, and alone holds the
/// authority to publish into core while it does.
pub const Role = union(enum) {
    bootstrap: env.CorePublisher,
    root: Membership,
    task: Membership,

    /// The scheduler a fiber runs under and the task scope it owns.
    pub const Membership = struct {
        scheduler: *const scheduler_api.WorkerScheduler,
        scope: *scheduler_api.TaskScope,
    };
};

const ErrorDataKey = enum {
    needed,
    available,
    name,
    path,
    seeded,
    observed,
    expected,
    index,
    key,
    left,
    right,
    scope,
    operation,
    root,
    reason,
    @"source-root",
    @"source-path",
    @"destination-root",
    @"destination-path",
    address,
    port,
};
const ErrorData = struct {
    key: union(enum) { builtin: ErrorDataKey, symbol: u32 },
    value: Value,
};
const empty_error_data = ErrorData{ .key = .{ .builtin = .needed }, .value = .{ .int = 0 } };
/// Provenance attached to one filesystem failure. Values are borrowed; the
/// pending failure retains what it records.
const FilesystemErrorData = struct {
    operation: Value,
    reason: Value,
    target: union(enum) {
        single: struct { root: Value, path: Value },
        transfer: struct {
            source_root: Value,
            source_path: Value,
            destination_root: Value,
            destination_path: Value,
        },
    },
};
/// Zig errors carry no payload. The fiber owns this allocation-free payload
/// until an unwind materializes the language dict.
pub const EclErr = struct {
    kind: ErrorKind,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    word: ?intern.TraceWord = null,
    trace_parent: ?intern.TraceWord = null,
    /// Whether a failure in `word` is reported at its caller. The call site
    /// itself is not kept when the activation that held it is released first.
    word_attribution: env.Attribution = .own,
    /// The same for `trace_parent`.
    trace_parent_attribution: env.Attribution = .own,
    site: ?FailureSite = null,
    data: [6]ErrorData = @splat(empty_error_data),
    data_len: usize = 0,
    raised: ?Value = null,
    pub fn init(kind: ErrorKind, message: []const u8) EclErr {
        var result = EclErr{ .kind = kind };
        result.setMessage(message);
        return result;
    }
    fn initFmt(
        kind: ErrorKind,
        comptime format: []const u8,
        args: anytype,
    ) EclErr {
        var result = EclErr{ .kind = kind };
        result.setMessageFmt(format, args);
        return result;
    }
    pub fn text(self: *const EclErr) []const u8 {
        return self.message[0..self.message_len];
    }
    fn addData(self: *EclErr, key: ErrorDataKey, item: Value) void {
        std.debug.assert(self.data_len < self.data.len);
        heap.retainValue(item);
        self.data[self.data_len] = .{ .key = .{ .builtin = key }, .value = item };
        self.data_len += 1;
    }
    fn setMessage(self: *EclErr, message: []const u8) void {
        const fallback = "language error (diagnostic too long)";
        const selected = if (message.len <= self.message.len) message else fallback;
        @memcpy(self.message[0..selected.len], selected);
        self.message_len = selected.len;
    }
    fn setMessageFmt(
        self: *EclErr,
        comptime format: []const u8,
        args: anytype,
    ) void {
        const rendered = std.fmt.bufPrint(&self.message, format, args) catch {
            self.setMessage("language error (diagnostic too long)");
            return;
        };
        self.message_len = rendered.len;
    }
    pub fn retire(self: *EclErr, releases: *heap.ReleaseDomain) void {
        for (self.data[0..self.data_len]) |entry| releases.releaseValue(entry.value);
        if (self.raised) |raised| releases.releaseValue(raised);
        if (self.site) |*site| site.deinit(releases);
        self.site = null;
    }
};

const ErrorValueCursor = error_values.ErrorValueCursor;
const ResolvedTrace = error_values.ResolvedTrace;
pub fn errorValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    failure: *EclErr,
    resolved: ResolvedTrace,
    location: ?spans.LocatedSpan,
) error{OutOfMemory}!Value {
    var work = poll_api.unbounded();
    // An error always carries `sites`, parallel to its trace, even an empty one.
    var sites_cursor = error_values.SitesCursor.init(allocator, releases, &.{});
    defer sites_cursor.retire();
    var complete = resolved;
    var sites: ?Value = null;
    defer if (sites) |item| releases.releaseValue(item);
    if (resolved.sites == null and resolved.trace.len == 0) {
        sites = try poll_api.driveFallible(Value, &sites_cursor, .{&work});
        complete.sites = sites;
    }
    var cursor = ErrorValueCursor.init(allocator, failure, complete, location);
    defer cursor.retire(releases);
    return poll_api.driveFallible(Value, &cursor, .{&work});
}
pub fn stringValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    bytes: []const u8,
) error{OutOfMemory}!Value {
    var materializer = kernel_storage.TextMaterializer.init(allocator, bytes);
    defer materializer.retire(releases);
    var work = poll_api.unbounded();
    return poll_api.driveFallible(Value, &materializer, .{&work});
}
/// How an evaluation holds the code it runs. Every evaluation resolves each
/// word when it is reached, against the definitions current then.
const Program = union(enum) {
    /// The evaluation owns one reference to its code: top-level source, or a
    /// quotation applied at run time.
    owned,
    /// The enclosing application frame owns the code for its whole
    /// invocation. The frame sits beneath this evaluation and outlives it, so
    /// the evaluation borrows the code.
    borrowed,
    /// A definition's body. Its code is borrowed from the definition, which
    /// the evaluation keeps alive by holding the executable's owner.
    definition: *const env.Executable,

    fn release(self: Program, releases: *heap.ReleaseDomain, code: *Header) void {
        switch (self) {
            .owned => releases.releaseHeader(code),
            .definition => |executable| executable.owner().release(releases),
            .borrowed => {},
        }
    }
};
/// The code a call site points into, held the way its evaluation held it. A
/// caller that stays suspended beneath its callee lends its code; a caller
/// that a tail call retires hands its reference to the callee instead of
/// releasing it, so recording the site costs no reference count.
const CallerCode = struct {
    code: *Header,
    program: Program,

    fn release(self: CallerCode, releases: *heap.ReleaseDomain) void {
        self.program.release(releases, self.code);
    }
};
/// A word about to run and where its failures are reported.
const EnteredWord = struct {
    word: intern.TraceWord,
    attribution: env.Attribution,
};
/// The named word an evaluation is traced under, where that word was called
/// from, and whether a failure inside it is reported at that call site.
/// Every eval and application frame carries one and every call writes one, so
/// it packs into three words: the code hold's address sits beside its tag, and
/// only `entered` and `borrowed` set them, which the accessors below read.
const Activation = struct {
    word: intern.TraceWord,
    /// The address `hold` refers to: a `*Header` for `borrowed` and `owned`, a
    /// `*const env.Executable` for `definition`, and zero for `none`.
    origin: usize = 0,
    /// The calling form's index in that code.
    index: u32 = 0,
    hold: Hold = .none,
    attribution: env.Attribution = .own,
    /// The evaluation carrying this activation is `word`'s own body, entered
    /// by dispatch. A locals binder opening that body is the word's arity
    /// check, so its failure is the word's. An activation handed on to a
    /// quotation or an application describes a word whose body that is not.
    body: bool = false,

    /// How the code holding the call is kept alive. The live tags follow
    /// `Program`'s order, so recording a caller copies its hold.
    const Hold = enum(u8) {
        /// One header reference moved from a retired caller.
        owned,
        /// A frame beneath this activation's evaluation keeps the code.
        borrowed,
        /// A retired caller's definition, kept alive by its owner.
        definition,
        none,
        /// A definition's code that a frame beneath keeps alive, as
        /// `borrowed` is for a header.
        lent_definition,
    };

    const none: Activation = .{ .word = no_word };

    /// `word`'s body entered from `caller` at `index`, taking over the
    /// caller's hold.
    inline fn entered(word: intern.TraceWord, attribution: env.Attribution, caller: CallerCode, index: u32) Activation {
        return .{
            .word = word,
            .origin = switch (caller.program) {
                .owned, .borrowed => @intFromPtr(caller.code),
                .definition => |definition| @intFromPtr(definition),
            },
            .index = index,
            .hold = @fromBackingInt(@intCast(@backingInt(caller.program))),
            .attribution = attribution,
            .body = true,
        };
    }

    inline fn traced(self: Activation) ?intern.TraceWord {
        return if (self.word != no_word) self.word else null;
    }

    /// This activation handed to code that is not the word's body.
    inline fn handedOn(self: Activation) Activation {
        var copy = self;
        copy.body = false;
        return copy;
    }

    /// The word whose body the carrying evaluation is, if any.
    inline fn bodyOwner(self: Activation) intern.TraceWord {
        return if (self.body) self.word else no_word;
    }

    /// Where the word was called, valid while this activation is alive.
    fn site(self: Activation) ?ErrorSite {
        const code: *Header = switch (self.hold) {
            .none => return null,
            .borrowed, .owned => @ptrFromInt(self.origin),
            .definition, .lent_definition => (@as(*const env.Executable, @ptrFromInt(self.origin))).code(),
        };
        return .{ .code = code, .index = self.index };
    }

    /// This activation lent to an evaluation running above its owner.
    inline fn borrowed(self: Activation) Activation {
        var copy = self.handedOn();
        copy.hold = switch (self.hold) {
            .owned, .borrowed => .borrowed,
            .definition, .lent_definition => .lent_definition,
            .none => .none,
        };
        return copy;
    }

    inline fn release(self: Activation, releases: *heap.ReleaseDomain) void {
        switch (self.hold) {
            .none, .borrowed, .lent_definition => {},
            .owned => releases.releaseHeader(@as(*Header, @ptrFromInt(self.origin))),
            .definition => (@as(*const env.Executable, @ptrFromInt(self.origin))).owner().release(releases),
        }
    }
};
comptime {
    if (@sizeOf(Activation) != 24) @compileError("an activation must remain three words");
    if (@sizeOf(Eval) > 80) @compileError("an evaluation must remain at most 80 bytes: every call copies one");
    // `entered` copies a `Program` tag into a `Hold`.
    const ProgramTag = @typeInfo(Program).@"union".tag_type.?;
    for ([_][]const u8{ "owned", "borrowed", "definition" }) |name| {
        if (@backingInt(@field(Activation.Hold, name)) != @backingInt(@field(ProgramTag, name)))
            @compileError("Activation.Hold must follow Program's tag order");
    }
}
/// A frame index, or none, in one word: three of these ride on every
/// evaluation, where an optional would spend a second word on each flag.
/// Frame counts stay below `max_frame_count`, so its value never denotes a
/// frame.
fn MaybeIndex(comptime Index: type) type {
    return enum(u32) {
        none = max_frame_count,
        _,

        const Self = @This();

        inline fn some(index: Index) Self {
            return @fromBackingInt(@intCast(@backingInt(index)));
        }

        inline fn of(index: ?Index) Self {
            return if (index) |found| @fromBackingInt(@intCast(@backingInt(found))) else .none;
        }

        inline fn get(self: Self) ?Index {
            return if (self == .none) null else @fromBackingInt(@backingInt(self));
        }
    };
}
/// What suspending the running evaluation leaves: the activation an exhausted
/// quotation hands to whatever runs next, and the caller's code, which a
/// retired caller transfers rather than releases.
const Suspension = struct {
    inherited: Activation,
    caller: CallerCode,

    fn release(self: Suspension, releases: *heap.ReleaseDomain) void {
        self.inherited.release(releases);
        self.caller.release(releases);
    }
};

const Eval = struct {
    code: *Header,
    program: Program,
    position: union(enum) {
        source: u32,
        // Carries the call site's next source index, but dispatches no caller
        // forms. Its completion frame must run before the caller can resume.
        invocation: u32,
        // Loader retry dispatches just the restored invocation, not the rest
        // of its caller's quotation.
        replay: u32,
        // The replayed word is being resolved. Its existing completion frame
        // is reused when dispatch reaches that invocation again.
        redispatch: u32,
    },

    /// The root this body runs in, the provenance it registers under, and
    /// whether it may define. One value, so a construction site cannot set
    /// one part and leave another describing different code.
    site: ExecutionSite,
    /// The word this evaluation is traced under, and that word's call site.
    /// The evaluation owns it: retiring the evaluation releases it, and an
    /// exhausted quotation moves it to whatever runs in its place.
    activation: Activation,
    /// Nominal authority to replace one source effect check's completion
    /// provenance. A non-tail call and every application quotation receive
    /// no authority, so their internal tail calls cannot overwrite the
    /// checked activation's authored control choice.
    effect_tail: MaybeIndex(EffectCheckIndex) = .none,
    /// Authority for the current generic application's selection boundary.
    /// Iterative continuations mint a fresh boundary per element; explicitly
    /// tail-transparent control quotations inherit the enclosing boundary.
    application_tail: MaybeIndex(ApplicationFrameIndex) = .none,
    /// This Eval was entered through a dynamic `apply` while in the named
    /// application. If it completes or transfers tail control, its existing
    /// code-header ownership becomes the application's selected quotation.
    application_selection: MaybeIndex(ApplicationFrameIndex) = .none,
    /// `code` is a flattened list: the fiber's table has the record of where
    /// its forms were written.
    flattened: bool = false,

    /// Releases what this evaluation owns.
    inline fn release(self: *const Eval, releases: *heap.ReleaseDomain) void {
        self.activation.release(releases);
        self.program.release(releases, self.code);
    }

    /// A copy of this evaluation holding its own reference to the code. The
    /// copy is traced under no word: the activation stays with the original.
    fn untracedCopy(self: Eval) Eval {
        switch (self.program) {
            .owned => heap.incRef(self.code),
            .definition => |executable| executable.owner().retain(),
            .borrowed => {},
        }
        var copy = self;
        copy.activation = .none;
        return copy;
    }

    /// Moves this evaluation's ownership into one code reference, for a
    /// holder that keeps only the quotation.
    /// The activation is not part of it: the caller has released or taken it.
    fn intoCode(self: *const Eval, releases: *heap.ReleaseDomain) *Header {
        switch (self.program) {
            .owned => return self.code,
            .definition => |executable| {
                heap.incRef(self.code);
                executable.owner().release(releases);
                return self.code;
            },
            .borrowed => {
                heap.incRef(self.code);
                return self.code;
            },
        }
    }

    fn nextIndex(self: Eval) u32 {
        return switch (self.position) {
            .source, .invocation, .replay, .redispatch => |index| index,
        };
    }
    fn hasInstructions(self: Eval) bool {
        return switch (self.position) {
            .source, .replay => |index| index < self.code.length(),
            .invocation, .redispatch => false,
        };
    }
    /// The index of the next form to dispatch, moving past it, or null when
    /// none remains: one test of the position where checking and advancing
    /// tested it twice.
    fn takeInstruction(self: *Eval) ?u32 {
        switch (self.position) {
            .source => |index| {
                if (index >= self.code.length()) return null;
                self.position = .{ .source = index + 1 };
                return index;
            },
            .replay => |index| {
                if (index >= self.code.length()) return null;
                self.position = .{ .redispatch = index + 1 };
                return index;
            },
            .invocation, .redispatch => return null,
        }
    }
    fn rewind(self: *Eval, index: u32) void {
        self.position = switch (self.position) {
            .source => .{ .source = index },
            .invocation, .replay, .redispatch => .{ .replay = index },
        };
    }

    /// The root this body runs in: where its own definitions land.
    fn scope(self: Eval) env.ScopeId {
        return self.site;
    }
};
/// A module construction boundary. The body builds the image `@defm` declared
/// before it ran; completion seals and publishes that image.
const ModuleBoundary = struct {
    image: modules.OwnedImage,
    /// The construction body `@defm` runs, after re-scoping. A declaration
    /// is module-level only while this is the current activation; quotations
    /// called by the body may inherit its scope but not its declaration site.
    root_code: *Header,

    fn deinit(self: ModuleBoundary) void {
        var owned = self.image;
        owned.deinit();
    }
};
const BoundaryMode = union(enum) {
    attempt,
    module: ModuleBoundary,
    /// `@load`: the loaded file's stack-isolated unit. Its failure is not
    /// caught here; it propagates to the enclosing unit.
    load,
};
const Boundary = struct {
    mode: BoundaryMode,
    stack_base: u32,
    /// The locals depth on entry. `_dl` balances the normal path; a
    /// body that fails never reaches it, so unwinding restores this instead.
    locals_base: u32,
    /// The floor this boundary's was set over.
    beneath: floor_api.Beneath,
    previous_boundary: ?FrameIndex,
    word: intern.TraceWord,
    fn deinit(self: Boundary) void {
        switch (self.mode) {
            .module => |boundary| boundary.deinit(),
            .attempt, .load => {},
        }
    }
};
const SourceEffectProvenance = struct {
    candidate: OwnedCode,
    frame_index: EffectCheckIndex,
    previous: ?EffectCheckIndex,
};
const EffectProvenance = union(enum) {
    none,
    source: SourceEffectProvenance,
    invocation: ErrorSite,
};
const EffectCheck = struct {
    expected_depth: u32,
    entry_depth: u32,
    inputs: u32,
    outputs: u32,
    word: intern.TraceWord,
    /// How the post-condition compares the observed depth with
    /// `expected_depth`; entry consumption is verified regardless.
    result_depth: env.Effect.ResultDepth = .exact,
    provenance: EffectProvenance = .none,

    fn activateSource(
        self: *EffectCheck,
        body: *Header,
        frame_index: EffectCheckIndex,
        previous: ?EffectCheckIndex,
    ) void {
        std.debug.assert(self.provenance == .none);
        self.provenance = .{ .source = .{
            .candidate = .retain(body),
            .frame_index = frame_index,
            .previous = previous,
        } };
    }
    fn replaceSourceCandidate(
        self: *EffectCheck,
        releases: *heap.ReleaseDomain,
        code: *Header,
    ) void {
        switch (self.provenance) {
            .none, .invocation => unreachable,
            .source => self.provenance.source.candidate.replaceBorrowed(releases, code),
        }
    }
    fn restoreActive(self: *const EffectCheck, fiber: *Fiber) void {
        switch (self.provenance) {
            .none, .invocation => {},
            .source => |source| {
                std.debug.assert(fiber.effect_check_index == source.frame_index);
                fiber.effect_check_index = source.previous;
            },
        }
    }
    fn takeCandidate(self: *EffectCheck) ?OwnedCode {
        return switch (self.provenance) {
            .none, .invocation => null,
            .source => .initOwned(self.provenance.source.candidate.take()),
        };
    }
    pub fn deinit(self: *EffectCheck, releases: *heap.ReleaseDomain) void {
        switch (self.provenance) {
            .none, .invocation => {},
            .source => self.provenance.source.candidate.deinit(releases),
        }
        self.provenance = .none;
    }
};
pub const StackWindow = enum(u32) {
    _,

    fn init(depth: usize, seeded: u32) ?StackWindow {
        if (depth < seeded) return null;
        return @fromBackingInt(@intCast(@as(u32, @intCast(depth - seeded))));
    }
    pub fn base(self: StackWindow) u32 {
        return @backingInt(self);
    }
    pub fn observed(self: StackWindow, depth: usize) ?usize {
        const start: usize = self.base();
        if (depth < start) return null;
        return depth - start;
    }
};
pub const ApplicationStep = union(enum) {
    apply: struct {
        quotation: *Header,
        seeded: u32,
        provenance: ApplicationProvenance = .boundary,
        /// How the quotation runs. One frame may launch differently each
        /// time: a guard alternates its tests over a soft floor with its
        /// actions in place.
        launch: Launch,
    },
    /// The callback installed bounded work which will launch a nested inline
    /// application. Reinsert this exact application continuation beneath that
    /// work so the child returns to it instead of replacing it.
    suspend_inline: *const ApplicationSuspension,
};
const ApplicationSuspension = opaque {};
/// How an application's quotation meets the stack beneath it. The three
/// differ only in the floor: none, a hard one, or one that lowers on demand.
const Launch = union(enum) {
    /// On the caller's stack, with everything beneath in reach.
    in_place,
    /// Behind a hard floor at its seeded operands.
    isolated,
    /// Over a soft floor the application's context owns and keeps in place
    /// until the application resumes, with the region above the lowered
    /// floor as its window.
    measured: *SoftFloor,
};
/// Opaque, non-dereferenced capability for one live application frame. The
/// Fiber encodes a process-unique nonce with the frame index and validates
/// both before use; ordinary callers can neither construct nor inspect it.
pub const ApplicationProvenanceTarget = opaque {};

fn mintApplicationProvenanceNonce() error{OutOfMemory}!ApplicationProvenanceNonce {
    var next = next_application_provenance_nonce.load(.monotonic);
    while (next <= std.math.maxInt(u32)) {
        if (next_application_provenance_nonce.cmpxchgWeak(
            next,
            next + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            next = observed;
        } else return @fromBackingInt(@intCast(@as(u32, @intCast(next))));
    }
    return error.OutOfMemory;
}

fn encodeApplicationProvenanceTarget(
    index: ApplicationFrameIndex,
    nonce: ApplicationProvenanceNonce,
) *const ApplicationProvenanceTarget {
    comptime if (@sizeOf(usize) != 8)
        @compileError("application provenance capabilities require a 64-bit target");
    const raw = (@as(usize, @backingInt(nonce)) << 32) |
        @as(usize, @backingInt(index));
    std.debug.assert(raw != 0);
    return @ptrFromInt(raw);
}

/// The current root of an activation: where its own definitions land, and,
/// when it is a module's scope, the module whose code is running. A module
/// word runs in its module's scope; every other word, and every quotation
/// applied as a value, runs in its caller's. Where a word resolves, what it
/// may register, and whether its call is checked are carried by the word.
pub const ExecutionSite = env.ScopeId;

/// The site of a fiber's root activation, built from nothing.
fn rootSite(fiber: *const Fiber) ExecutionSite {
    return switch (fiber.root_entry) {
        .module => |home| home.scope,
        .scope => |scope| scope,
    };
}

pub const ApplicationProvenance = union(enum) {
    boundary,
    selected_target: *const ApplicationProvenanceTarget,
};
/// What stays the same across every quotation one application runs: the
/// combinator state, how to resume and free it, and where its quotations
/// run. An application carries it to its frame, and the frame to the next
/// application, whole.
pub const ApplicationDriver = struct {
    context: *anyopaque,
    resume_fn: *const fn (*Fiber, *anyopaque, StackWindow, *ApplicationContractSite) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ExecutionSite,
    /// Where a finite iteration keeps what its call remembers of its
    /// quotation's words. Borrowed from the state `context` points to.
    plan: ?*ResolutionPlan = null,

    fn deinit(self: ApplicationDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.deinit_fn(releases, allocator, self.context);
    }
};

pub const Application = struct {
    quotation: *Header,
    driver: ApplicationDriver,
    seeded: u32,
    provenance: ApplicationProvenance,

    /// Releases an application that never became a frame.
    fn discard(self: Application, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.driver.deinit(releases, allocator);
    }
};

const stack_summary = @import("stack_summary.zig");
const flatten = @import("flatten.zig");

fn ApplicationAdapters(comptime Driver: type) type {
    return struct {
        fn run(
            fiber: *Fiber,
            raw: *anyopaque,
            window: StackWindow,
            site: *ApplicationContractSite,
        ) MachineError!?ApplicationStep {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            return Driver.resumeApplication(fiber, driver, window, site);
        }

        fn deinit(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            heap.destroyDriver(releases, allocator, driver);
        }

        /// Teardown for state `houseApplication` placed: the same field
        /// ownership, then the slot freed or the allocation destroyed.
        fn deinitHoused(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            heap.deinitDriverFields(releases, allocator, driver);
            const housing: *ApplicationHousing(Driver) = @fieldParentPtr("driver", driver);
            if (housing.vacancy) |busy| busy.* = false else allocator.destroy(housing);
        }
    };
}

/// An application's state where `houseApplication` put it: in one of the
/// fiber's slots, or in an allocation when every slot is taken. Which one is
/// recorded beside the state, so its teardown needs no fiber.
fn ApplicationHousing(comptime Driver: type) type {
    return struct {
        /// The occupancy flag of the slot this state lives in, cleared to
        /// free it; null when the state has an allocation of its own.
        vacancy: ?*bool,
        driver: Driver,
    };
}

/// Opt-in fiber storage for application state. A driver declares
/// `housed_application` to be constructed in a fiber slot instead of the
/// allocator, and is then launched only through the handle `houseApplication`
/// returns. The declaration is checked here, so a driver that outgrows a
/// slot or stops owning its fields fails the build.
///
/// An application holds its slot for as long as its quotations run, and
/// applications nest, so there are a few slots and no promise of one:
/// correctness never depends on a slot being free, only the allocation does.
fn housedApplicationCapable(comptime Driver: type) bool {
    if (!@hasDecl(Driver, "housed_application")) return false;
    if (heap.validateDriverOwnership(Driver) != .fields)
        @compileError(@typeName(Driver) ++ " housed application storage requires field ownership");
    const Housing = ApplicationHousing(Driver);
    if (@sizeOf(Housing) > Fiber.application_slot_len)
        @compileError(std.fmt.comptimePrint("{s} ({d} bytes housed) exceeds the fiber application slot ({d} bytes)", .{ @typeName(Driver), @sizeOf(Housing), Fiber.application_slot_len }));
    if (@alignOf(Housing) > Fiber.application_slot_align)
        @compileError(@typeName(Driver) ++ " exceeds the fiber application slot alignment");
    return true;
}

/// The handle to a housed application's state. Opaque, so the only way to
/// hold one is to have housed the state.
pub fn HousedApplication(comptime Driver: type) type {
    return opaque {
        const Self = @This();

        /// The application of `quotation` this state resumes after. It owns
        /// the state from here.
        pub fn application(self: *Self, quotation: *Header, site: ExecutionSite, seeded: u32) Application {
            const housing: *ApplicationHousing(Driver) = @ptrCast(@alignCast(self));
            return .{
                .quotation = quotation,
                .driver = .{
                    .context = @ptrCast(&housing.driver),
                    .resume_fn = ApplicationAdapters(Driver).run,
                    .deinit_fn = ApplicationAdapters(Driver).deinitHoused,
                    .site = site,
                },
                .seeded = seeded,
                .provenance = .boundary,
            };
        }
    };
}

pub fn typedApplication(
    driver: anytype,
    quotation: *Header,
    site: ExecutionSite,
    seeded: u32,
) Application {
    const Context = @TypeOf(driver);
    const pointer = switch (@typeInfo(Context)) {
        .pointer => |info| info,
        else => @compileError("application driver must be a pointer"),
    };
    if (pointer.size != .one) @compileError("application driver must be a single-item pointer");
    const Driver = pointer.child;
    if (@hasDecl(Driver, "housed_application"))
        @compileError(@typeName(Driver) ++ " is launched through the handle houseApplication returns");
    const adapters = ApplicationAdapters(Driver);
    return .{
        .quotation = quotation,
        .driver = .{ .context = @ptrCast(driver), .resume_fn = adapters.run, .deinit_fn = adapters.deinit, .site = site },
        .seeded = seeded,
        .provenance = .boundary,
    };
}
const ApplicationMode = union(enum) {
    in_place: StackWindow,
    /// The floor the application's hard floor was set over.
    isolated: floor_api.Beneath,
    /// The floor lives in the combinator state the frame's context points to,
    /// which stays in place until the application resumes.
    measured: *SoftFloor,
};
const ApplicationFrame = struct {
    driver: ApplicationDriver,
    mode: ApplicationMode,
    /// The activation every quotation this application runs is traced under.
    /// The frame owns it; each launched evaluation borrows it.
    activation: Activation,
    selection: ApplicationSelection,
    provenance_nonce: ?ApplicationProvenanceNonce = null,
    fn deinit(self: ApplicationFrame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.activation.release(releases);
        var selection = self.selection;
        selection.deinit(releases);
        // A measured mode's soft floor belongs to the context, which frees it.
        self.driver.deinit(releases, allocator);
    }
};
const Frame = union(enum(u8)) {
    eval: Eval,
    effect_check: EffectCheck,
    application: ApplicationFrame,
    qualified_after_load: load.AfterLoad,
    boundary: Boundary,
    fn deinit(self: Frame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self) {
            .eval => |frame| frame.release(releases),
            .effect_check => |owned| {
                var check = owned;
                check.deinit(releases);
            },
            .application => |frame| frame.deinit(releases, allocator),
            .qualified_after_load => |frame| frame.deinit(releases),
            .boundary => |boundary| boundary.deinit(),
        }
    }
};
/// A linear frame-construction capability. `appendFrame` consumes it only
/// after ArrayList growth succeeds; on failure the caller still owns exactly
/// one capability whose deinit releases the frame cargo.
const OwnedFrame = struct {
    frame: ?Frame,

    fn init(frame: Frame) OwnedFrame {
        return .{ .frame = frame };
    }

    fn deinit(
        self: *OwnedFrame,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        if (self.frame) |frame| frame.deinit(releases, allocator);
        self.frame = null;
    }

    fn take(self: *OwnedFrame) Frame {
        const frame = self.frame.?;
        self.frame = null;
        return frame;
    }
};
comptime {
    // The tagged application mode and immutable driver identity are worth the
    // extra words: invalid correlated continuation states are unrepresentable.
    // A load-return frame owns the complete qualified-operation continuation
    // across nested source execution. Keeping that tagged state in the frame
    // makes replay-vs-dispatch ownership unrepresentable rather than relying
    // on correlated Fiber fields. Every eval and application frame records
    // its activation's execution site and call site; the activation packs
    // into three words to stay within this.
    if (@sizeOf(Frame) > 120) @compileError("machine frames must remain at most 120 bytes");
}
/// A user quotation offered to a combinator, recognized where it is applied.
pub const IdiomRequest = enum { each, zip_with, fold, fold1, scan, lex_cmp, stencil };
/// The combinator's generic path, run when recognition declines its quotation.
pub const IdiomFallback = *const fn (*Fiber) MachineError!void;

/// Configuration and semantic services inherited by every spawned Fiber.
/// Keeping this as one value makes addition of a new inherited service an
/// atomic parent-to-child copy instead of a scheduler-site field checklist.
pub const InheritedContext = struct {
    registry: *modules.Registry,
    test_observation: ?*const modules.TestObservationAccess = null,
    test_execution: ?*const modules.TestExecutionAccess = null,
    native_diagnostics: bool = false,
    tls_trust: ?TlsTrust = null,
    ecl_path: ?[]const u8 = null,
    module_snapshot: ?*const map_state.Snapshot = null,
    idiom_mode: IdiomMode = .automatic,
    phase: union(enum) { bootstrap, runtime: RuntimeContext },

    fn console(self: *const InheritedContext) ?*console_api.Console {
        return switch (self.phase) {
            .bootstrap => null,
            .runtime => |context| context.console,
        };
    }

    pub fn runtime(self: *const InheritedContext) *const RuntimeContext {
        return switch (self.phase) {
            .runtime => |*context| context,
            .bootstrap => @panic("runtime service requested during prelude construction"),
        };
    }
};

/// Complete runtime services, borrowed from the Session that encloses every
/// Fiber and descendant. Bootstrap evaluation has no runtime services.
const RuntimeContext = struct {
    native_loader: *native_module.Loader,
    console: *console_api.Console,
    host_io: std.Io,
    startup_cwd: []const u8,
    filesystem_access: *external.FilesystemAccess,
    http_access: *@import("http_service.zig").Access,
    wall_clock: WallClock,
    environ: Environ,
    standard_streams: *standard_streams.Devices,
    /// The process arguments following the script, borrowed from the
    /// Session.
    arguments: Value,
};

/// Wall time is always available at runtime. Overrides are deterministic
/// testing inputs, independent of permissions. Values are Unix milliseconds.
pub const WallClock = union(enum) {
    host: std.Io,
    fixed: i64,
    anchored: i64,
};

/// Immutable HTTPS verification inputs inherited by every Fiber. The CA path
/// borrows Session-owned storage, whose lifetime encloses all Fibers.
pub const TlsTrust = struct {
    ca_file: []const u8,
    now: std.Io.Timestamp,
};

/// One immutable snapshot of the host environment, captured once at session
/// init. `getenv` reads only this snapshot, so a session observes one
/// deterministic environment and no primitive ever races a host `setenv`.
pub const Environ = @import("startup_environment.zig").View;

/// Where standard input stands at session start: data a program may read
/// through `stream.in`, or the program source itself, which `stream.in` refuses.
pub const StandardInput = struct {
    pub const Availability = standard_streams.Availability;
};

pub const ParkRequest = park_api.ParkRequest;
const TaskWaitResume = park_api.TaskWaitResume;
pub const ParkResume = park_api.ParkResume;

/// A driver transfers an owned result through this completion state. The
/// fiber destroys the driver before committing that value to the stack,
/// so stack-growth failure always has exactly one resumable owner.
///
/// `stepped` and `yielded` separate progress from surrender, and a yield states
/// why the driver ends its turn; `turn_core` decides what the fiber does
/// with either.
pub const WorkProgress = union(enum) {
    completed,
    output: Value,
    reserved_output: struct { reservation: StackReservation, value: Value },
    stepped,
    yielded: turn_core.Yield,
    detached,
    failed,
};
const CleanupProgress = struct { complete: bool, consumed: usize };

/// A validated capability for a fixed number of non-fallible stack commits.
/// The expected length makes stale copies fail before they can transfer a
/// value twice.
pub const StackReservation = struct {
    fiber: *Fiber,
    next_len: usize,
    remaining: usize,

    fn init(fiber: *Fiber, count: usize) StackReservation {
        std.debug.assert(fiber.stack.capacity - fiber.stack.items.len >= count);
        return .{ .fiber = fiber, .next_len = fiber.stack.items.len, .remaining = count };
    }

    fn pushOwned(self: *StackReservation, item: Value) void {
        std.debug.assert(self.remaining != 0);
        std.debug.assert(self.fiber.stack.items.len == self.next_len);
        self.fiber.stack.appendAssumeCapacity(item);
        self.next_len += 1;
        self.remaining -= 1;
    }

    pub fn pushBorrowed(self: *StackReservation, item: Value) void {
        heap.retainValue(item);
        self.pushOwned(item);
    }

    pub fn complete(self: *const StackReservation) bool {
        return self.remaining == 0;
    }

    /// Moves one already-reserved output through the fiber's driver
    /// completion boundary. No allocation can follow a consuming result claim.
    pub fn output(self: StackReservation, item: Value) WorkProgress {
        std.debug.assert(self.remaining == 1);
        return .{ .reserved_output = .{ .reservation = self, .value = item } };
    }
};

/// Validated exact replacement of the current operand suffix. Capacity is
/// secured before this capability is returned; `commitOwned` is the only
/// splice that releases the inputs and transfers the completed outputs.
const StackReplacement = struct {
    fiber: *Fiber,
    base: usize,
    input_count: usize,
    output_count: usize,

    pub fn commitOwned(self: *StackReplacement, outputs: []const Value) void {
        std.debug.assert(outputs.len == self.output_count);
        std.debug.assert(self.fiber.stack.items.len == self.base + self.input_count);
        for (self.fiber.stack.items[self.base..]) |item| self.fiber.releases.releaseValue(item);
        self.fiber.floor.noteShrink(self.base);
        self.fiber.stack.items.len = self.base;
        for (outputs) |item| self.fiber.stack.appendAssumeCapacity(item);
    }
};

/// Type-erased owned continuation for native work that must return to the
/// scheduler between bounded slices.
const WorkDriver = struct {
    context: *anyopaque,
    resume_fn: *const fn (*Fiber, *anyopaque) MachineError!WorkProgress,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ?ErrorSite,

    fn advance(self: WorkDriver, fiber: *Fiber) MachineError!WorkProgress {
        return self.resume_fn(fiber, self.context);
    }

    fn deinit(self: WorkDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.deinit_fn(releases, allocator, self.context);
    }
};

/// The scheduler-visible native continuation owned by a fiber. A work driver
/// carries its wait request or delivered result in the same variant, so the
/// fiber cannot represent an unrelated driver and park at once.
const NativeContinuation = union(enum) {
    idle,
    work: WorkDriver,
    work_park_request: struct { driver: WorkDriver, request: ParkRequest },
    work_park_resume: struct { driver: WorkDriver, result: ParkResume },
    park_request: ParkRequest,
    park_resume: ParkResume,
};

/// What a driver's `advance` receives: the fiber, or the machine-minted view
/// of it that the driver's own subsystem is trusted with.
fn DriverAuthority(comptime Driver: type) type {
    return @typeInfo(@TypeOf(Driver.advance)).@"fn".param_types[0] orelse *Fiber;
}

/// A driver may be started by a holder of the authority it asks for, and by
/// no one else: the public start paths pass `*Fiber`, so a driver that asks
/// for a view is refused there at compile time.
fn requireDriverAuthority(comptime Driver: type, comptime Held: type) void {
    const Asked = DriverAuthority(Driver);
    if (Asked != *Fiber and Asked != Held)
        @compileError(@typeName(Driver) ++ " asks for " ++ @typeName(Asked) ++ ", which its starter does not hold");
}

/// Who observes cancellation between a driver's steps. The machine polls
/// before every step of an ordinary driver, so no driver body restates the
/// rule and a new driver is cancellable without asking. A driver declares
/// `cancellation = .own` when a step must run despite cancellation, or must
/// do something before observing it; it then polls where its own protocol
/// allows, or not at all.
pub const DriverCancellation = enum { each_step, own };

/// Observes cancellation ahead of one step of `Driver`, unless the driver
/// owns that. Both places a step begins, the installed driver's resumption
/// and `runDriverAt`'s first step, come through here.
inline fn pollBeforeStep(comptime Driver: type, fiber: *Fiber) MachineError!void {
    const policy: DriverCancellation = if (@hasDecl(Driver, "cancellation")) Driver.cancellation else .each_step;
    if (policy == .each_step) try fiber.pollKernel();
}

fn WorkDriverAdapters(comptime Driver: type) type {
    return struct {
        fn advance(fiber: *Fiber, raw: *anyopaque) MachineError!WorkProgress {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            try pollBeforeStep(Driver, fiber);
            return Driver.advance(switch (DriverAuthority(Driver)) {
                *Fiber => fiber,
                *Loading => Loading.of(fiber),
                *Unwinding => Unwinding.of(fiber),
                *Construction => Construction.of(fiber),
                else => @compileError(@typeName(Driver) ++ " asks for an authority the machine does not mint"),
            }, driver);
        }

        fn deinit(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            heap.destroyDriver(releases, allocator, driver);
        }

        /// Teardown for a driver living in the fiber's inline slot: the same
        /// field ownership, without the destroy that storage never had.
        /// Releasing the slot belongs to the caller, which knows the fiber:
        /// `clearWorkDriver` frees it, and fiber teardown does not bother
        /// because it invalidates the fiber immediately afterward.
        fn deinitInline(
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
            raw: *anyopaque,
        ) void {
            const driver: *Driver = @ptrCast(@alignCast(raw));
            heap.deinitDriverFields(releases, allocator, driver);
        }
    };
}

/// Opt-in inline driver storage. A driver declares `inline_driver` to be
/// constructed in the fiber's slot instead of the allocator; the declaration is
/// checked here rather than assumed, so a driver that outgrows the slot or
/// stops owning its fields fails the build instead of silently reverting to an
/// allocation.
///
/// What the compiler cannot check is the one rule that decides whether the
/// annotation helps: **declare it on short-lived drivers, never on long-lived
/// ones.** There is a single slot per fiber and its holder keeps it until the
/// driver is retired, so a driver that spans an iteration would hold the slot
/// for the iteration's whole length and push every driver started inside it
/// back to the allocator. That is worse than not declaring it at all, and it
/// is invisible: the annotation still compiles, the slot is still used, and the
/// allocations simply move rather than disappear. A combinator's own iteration
/// driver is the shape to leave alone; the leaf drivers it starts per element
/// are the shape this is for.
fn inlineDriverCapable(comptime Driver: type) bool {
    if (!@hasDecl(Driver, "inline_driver")) return false;
    if (heap.validateDriverOwnership(Driver) != .fields)
        @compileError(@typeName(Driver) ++ " inline driver storage requires field ownership");
    if (@sizeOf(Driver) > Fiber.driver_slot_len)
        @compileError(std.fmt.comptimePrint("{s} ({d} bytes) exceeds the fiber inline driver slot ({d} bytes)", .{ @typeName(Driver), @sizeOf(Driver), Fiber.driver_slot_len }));
    if (@alignOf(Driver) > Fiber.driver_slot_align)
        @compileError(@typeName(Driver) ++ " exceeds the fiber inline driver alignment");
    return true;
}

comptime {
    if (@sizeOf(WorkDriver) > 80) @compileError("WorkDriver exceeds its fixed frame budget");
}

/// Opt-in root-Fiber counters for release-mode runtime characterization.
/// Ordinary runtime and test modules compile every recording branch away; a
/// separate benchmark module enables them so counters cannot perturb timing.
pub const RootExecutionMetrics = struct {
    logical_transitions: u64 = 0,
    driver_resumes: u64 = 0,
    application_resumes: u64 = 0,
    scheduler_handoffs: u64 = 0,
    /// The deepest the frame stack grew.
    max_frames: usize = 0,
    /// Recognized idiom applications.
    idiom_hits: u64 = 0,
    /// The idiom hits that were phrases continued by following words.
    phrase_hits: u64 = 0,
};

pub const root_execution_metrics_enabled = session_options.instrument_root_execution;

/// One driver for a primitive that must encode a path argument to bytes before
/// it can act. Encoding and its failure are the same work whatever follows, so
/// the action is the only thing that varies; the ownership order — take the
/// path, take the value, retire, then act — is stated once here rather than
/// copied per primitive.
pub fn PathActionDriver(
    comptime action: fn (*Fiber, []u8, Value) MachineError!void,
) type {
    return struct {
        const Self = @This();
        pub const ownership: heap.DriverOwnership = .fields;
        path_value: heap.Owned(Value),
        encoder: heap.Owned(kernel_storage.StringEncoder),
        path: ?heap.Owned([]u8) = null,

        fn advance(fiber: *Fiber, self: *Self) MachineError!WorkProgress {
            if (self.path == null) switch (self.encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCodepoint => return fiber.fail(.domain, "path contains an invalid Unicode scalar"),
            }) {
                .pending => return .stepped,
                .complete => |path| self.path = .init(path),
            };
            const path = self.path.?.take();
            const path_value = self.path_value.take();
            self.path = null;
            fiber.retireDriver(self);
            try action(fiber, path, path_value);
            return .detached;
        }
    };
}

/// The fiber as its module loader sees it, plus the handful of
/// continuation operations a load needs and a primitive must not have. It is
/// the fiber's own address under an opaque type, so holding one is the
/// authority; only the machine mints it, handing it to the loader's entry
/// points and to the drivers that ask for it in `advance`.
pub const Loading = opaque {
    fn of(target: *Fiber) *Loading {
        return @ptrCast(target);
    }

    pub fn fiber(self: *Loading) *Fiber {
        return @ptrCast(@alignCast(self));
    }

    /// `Fiber.startDriver` for a driver that asks for this view.
    pub fn startDriver(self: *Loading, initial: anytype) error{OutOfMemory}!void {
        return self.fiber().startDriverAs(*Loading, initial);
    }

    /// Fails with a parse error located in a source that never reached the
    /// archive.
    pub fn failAtSource(self: *Loading, message: []const u8, source_name: []const u8, span: reader.Span) MachineError {
        return self.fiber().failAtSource(message, source_name, span);
    }

    /// Ends the fiber on a source that stopped mid-form, which a session
    /// reports as a request for more input rather than a failure.
    pub fn finishIncomplete(self: *Loading, incomplete: reader.Incomplete) void {
        self.fiber().finishIncomplete(incomplete);
    }

    /// Opens one `@load` boundary over a read source. Consumes `body` on
    /// success and failure.
    pub fn openLoad(self: *Loading, body: *Header, word: intern.TraceWord) error{OutOfMemory}!void {
        return self.fiber().openLoad(body, word);
    }

    /// Runs `body` as a registering source in place of the running
    /// evaluation, which resumes through `after` once the body returns.
    /// Consumes `body` and `after` on success and failure.
    pub fn enterRegistration(
        self: *Loading,
        body: *Header,
        after: load.AfterLoad,
    ) error{OutOfMemory}!void {
        return self.fiber().enterRegistration(body, after);
    }

    /// Dispatches the word a completed load was started for, by explicit
    /// lookup.
    pub fn dispatchAfterLoad(
        self: *Loading,
        word: value.Symbol,
        site: ?ErrorSite,
    ) error{OutOfMemory}!void {
        return self.fiber().dispatchAfterLoad(word, site);
    }
};

pub const Fiber = struct {
    const TerminalState = union(enum) {
        evaluating,
        pending: EclErr,
        unwinding,
        failed: Value,
        incomplete: reader.Incomplete,
        exit: u8,

        fn deinit(self: *TerminalState, releases: *heap.ReleaseDomain) void {
            switch (self.*) {
                .pending => |*failure| failure.retire(releases),
                .failed => |item| releases.releaseValue(item),
                .evaluating, .unwinding, .incomplete, .exit => {},
            }
            self.* = .evaluating;
        }
    };

    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    frames: std.ArrayList(Frame) = .empty,
    stack: std.ArrayList(Value),
    environment: *env.Env,
    /// The way to the content of `environment`'s word cells.
    cells: env.WordCells,
    inherited: InheritedContext,
    archive: *spans.SpanArchive,
    cancelled: *const std.atomic.Value(bool),
    fuel: u32 = fuel_quantum,
    /// The fiber's one allowance for logical kernel work in a turn. Cursors
    /// doing this fiber's work draw on it through `Fiber.workBudget`, and
    /// exhausting it ends the turn: only the start of the next turn refills it.
    kernel_budget: poll_api.WorkBudget = .init(kernel_poll_quantum),
    polls: u64 = 0,
    root_execution_metrics: if (root_execution_metrics_enabled) RootExecutionMetrics else void = if (root_execution_metrics_enabled) .{} else {},
    /// The stack summaries read for the source words this fiber's summaries
    /// called.
    bodies: stack_summary.Bodies = .{},
    /// The stack summaries read for the quotations this fiber applied.
    summaries: stack_summary.Cache = .{},
    /// What this fiber made of the code lists it ran.
    flattened: flatten.Cache = .{},
    entry_base: usize,
    /// How far down a word may reach, and what `require` compares against.
    floor: floor_api.StackFloor = .{},
    boundary_index: ?FrameIndex = null,
    /// The innermost active source effect check. Effect-check frames form an
    /// intrusive chain so nested checks restore their predecessor exactly.
    effect_check_index: ?EffectCheckIndex = null,
    terminal: TerminalState = .evaluating,
    role: Role,
    root_entry: RootEntry,
    native: NativeContinuation = .idle,
    current: ?Eval = null,
    active_index: u32 = 0,
    active_word: intern.TraceWord = no_word,
    /// The word being dispatched when it is not the occurrence at
    /// `active_index`: one `execute` runs, or one a resumed lookup invokes.
    /// Null otherwise.
    dispatched: ?value.Symbol = null,
    /// Scratch for spelling one qualified trace word in a diagnostic message.
    /// A module-local word's qualified spelling is never interned, so there is
    /// no string to point at. Written before it is read on
    /// every path; zeroed rather than left `undefined` so no default here can
    /// become a read of uninitialized bytes.
    word_scratch: [intern.trace_word_bytes]u8 = @splat(0),
    /// Storage for the one work driver a fiber runs at a time. `installDriver`
    /// accepts a driver only from `idle` or `yielded`, so a second live driver
    /// is not representable; a driver that has detached but not yet destroyed
    /// itself can still be holding the slot when the next one starts, and that
    /// one falls back to the allocator. Correctness never depends on the slot
    /// being free — only the allocation does.
    driver_slot: [driver_slot_len]u8 align(driver_slot_align),
    driver_slot_busy: bool = false,
    /// Storage for the state of applications that opt in. See
    /// `housedApplicationCapable`.
    application_slots: [application_slot_count]ApplicationSlot,
    /// Locals. The declared names live here for the length of the
    /// quotation body that introduced them, never on the operand stack, so a
    /// body's declared stack effect describes its operands alone and an
    /// ordinary form between two local reads needs no shuffling to see past
    /// them. Reads are top-relative: the last local introduced is
    /// index 0.
    locals: std.ArrayList(Value) = .empty,
    pub fn init(
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        stack: std.ArrayList(Value),
        environment: *env.Env,
        archive: *spans.SpanArchive,
        inherited: InheritedContext,
        cancelled: *const std.atomic.Value(bool),
        role: Role,
        root_entry: RootEntry,
    ) Fiber {
        return .{
            .allocator = allocator,
            .releases = releases,
            .stack = stack,
            .environment = environment,
            .cells = environment.wordCells(),
            .archive = archive,
            .inherited = inherited,
            .cancelled = cancelled,
            .role = role,
            .root_entry = root_entry,
            .entry_base = stack.items.len,
            // SAFETY: this field supplies storage only. `driver_slot_busy` is the only
            // thing that says a driver lives here, and every read of the slot
            // goes through `acquireInlineDriver`, which writes the whole
            // driver before the pointer escapes.
            .driver_slot = undefined,
            // SAFETY: storage only. A slot's `busy` flag is the only thing
            // that says state lives there, and `houseApplication` writes the
            // whole state before the pointer escapes.
            .application_slots = @splat(.{ .bytes = undefined }),
        };
    }

    /// The scheduler this fiber runs under and the task scope it owns. Only
    /// the bootstrap fiber has neither, and it runs no word that asks.
    pub fn scheduling(self: *const Fiber) Role.Membership {
        return switch (self.role) {
            .root, .task => |membership| membership,
            .bootstrap => @panic("scheduler requested during prelude construction"),
        };
    }

    /// Transfers the top operand out of the fiber without interpreting stack
    /// boundaries. Scheduler teardown uses this after evaluation has stopped.
    fn takeStackOwned(self: *Fiber) ?Value {
        return self.stack.pop();
    }

    /// The chain a homeless binding — a primitive or an embedded prelude
    /// definition — resolves against. It is the session root over core, so
    /// session-level redefinition still reaches prelude bodies while a module
    /// body executing further down the stack does not.
    pub fn lexicalScope(self: *Fiber) env.ScopeId {
        return switch (self.root_entry) {
            .scope => |scope| scope,
            .module => |root| root.scope,
        };
    }

    /// Replaces a stopped root fiber's operands from a stable borrowed
    /// checkpoint. Capacity was reserved by the checkpoint source.
    pub fn restoreStackBorrowedAssumeCapacity(self: *Fiber, checkpoint: []const Value) void {
        for (self.stack.items) |item| self.releases.releaseValue(item);
        self.stack.clearRetainingCapacity();
        std.debug.assert(self.stack.capacity >= checkpoint.len);
        var reservation = StackReservation.init(self, checkpoint.len);
        for (checkpoint) |item| reservation.pushBorrowed(item);
        std.debug.assert(reservation.complete());
    }
    pub fn takeStack(self: *Fiber) std.ArrayList(Value) {
        const result = self.stack;
        self.stack = .empty;
        return result;
    }
    pub fn takeError(self: *Fiber) ?Value {
        return switch (self.terminal) {
            .failed => |item| result: {
                self.terminal = .evaluating;
                break :result item;
            },
            else => null,
        };
    }
    pub fn takeSourceIncomplete(self: *Fiber) ?reader.Incomplete {
        return switch (self.terminal) {
            .incomplete => |value_incomplete| result: {
                self.terminal = .evaluating;
                break :result value_incomplete;
            },
            else => null,
        };
    }
    pub fn exitStatus(self: *const Fiber) ?u8 {
        return switch (self.terminal) {
            .exit => |status| status,
            else => null,
        };
    }
    pub fn hasRequestedExit(self: *const Fiber) bool {
        return self.terminal == .exit;
    }
    fn pendingFailureOptional(self: *Fiber) ?*EclErr {
        return switch (self.terminal) {
            .pending => |*failure| failure,
            else => null,
        };
    }
    fn pendingFailure(self: *Fiber) *EclErr {
        return self.pendingFailureOptional() orelse unreachable;
    }
    fn hasPendingFailure(self: *const Fiber) bool {
        return self.terminal == .pending;
    }
    fn installPendingFailure(self: *Fiber, failure: EclErr) void {
        std.debug.assert(self.terminal == .evaluating);
        self.terminal = .{ .pending = failure };
    }
    fn takePendingForUnwind(self: *Fiber) EclErr {
        return switch (self.terminal) {
            .pending => |failure| result: {
                self.terminal = .unwinding;
                break :result failure;
            },
            else => unreachable,
        };
    }
    fn finishUnwindCaught(self: *Fiber) void {
        std.debug.assert(self.terminal == .unwinding);
        self.terminal = .evaluating;
    }
    fn finishUnwindFailed(self: *Fiber, error_value: Value) void {
        std.debug.assert(self.terminal == .unwinding);
        self.terminal = .{ .failed = error_value };
    }
    fn finishIncomplete(self: *Fiber, value_incomplete: reader.Incomplete) void {
        std.debug.assert(self.terminal == .evaluating);
        self.terminal = .{ .incomplete = value_incomplete };
    }
    fn requestExit(self: *Fiber, status: u8) void {
        std.debug.assert(self.terminal == .evaluating);
        self.terminal = .{ .exit = status };
    }
    pub fn hasParkRequest(self: *const Fiber) bool {
        return self.native == .park_request or self.native == .work_park_request;
    }
    pub fn parkRequest(self: *const Fiber) ?ParkRequest {
        return switch (self.native) {
            .park_request => |request| request,
            .work_park_request => |state| state.request,
            else => null,
        };
    }
    pub fn takeParkRequest(self: *Fiber) ?ParkRequest {
        return switch (self.native) {
            .park_request => |request| result: {
                self.native = .idle;
                break :result request;
            },
            .work_park_request => |state| result: {
                self.native = .{ .work = state.driver };
                break :result state.request;
            },
            else => null,
        };
    }
    fn installParkRequest(self: *Fiber, request: ParkRequest) void {
        self.native = switch (self.native) {
            .idle => .{ .park_request = request },
            .work => |driver| .{ .work_park_request = .{ .driver = driver, .request = request } },
            else => unreachable,
        };
    }
    pub fn installParkResume(self: *Fiber, result: ParkResume) void {
        self.native = switch (self.native) {
            .idle => .{ .park_resume = result },
            .work => |driver| .{ .work_park_resume = .{ .driver = driver, .result = result } },
            else => unreachable,
        };
    }
    fn takeParkResume(self: *Fiber) ?ParkResume {
        return switch (self.native) {
            .park_resume => |result| delivery: {
                self.native = .idle;
                break :delivery result;
            },
            .work_park_resume => |state| delivery: {
                self.native = .{ .work = state.driver };
                break :delivery state.result;
            },
            else => null,
        };
    }
    fn workDriver(self: *Fiber) ?*WorkDriver {
        return switch (self.native) {
            .work => |*driver| driver,
            .work_park_request => |*state| &state.driver,
            .work_park_resume => |*state| &state.driver,
            else => null,
        };
    }
    fn takeWorkDriver(self: *Fiber) ?WorkDriver {
        return switch (self.native) {
            .work => |driver| result: {
                self.native = .idle;
                break :result driver;
            },
            .work_park_request => |state| result: {
                state.request.deinit(self.releases);
                self.native = .idle;
                break :result state.driver;
            },
            .work_park_resume => |state| result: {
                state.result.deinit(self.releases);
                self.native = .idle;
                break :result state.driver;
            },
            else => null,
        };
    }
    /// The kind of the innermost saved frame, or null with none saved.
    fn topFrameTag(self: *const Fiber) ?std.meta.Tag(Frame) {
        const frames = self.frames.items;
        return if (frames.len == 0) null else std.meta.activeTag(frames[frames.len - 1]);
    }
    /// Removes the innermost saved frame, which is a `tag`, and returns its
    /// payload. Popping the whole frame copied the union's largest variant.
    fn popFrame(self: *Fiber, comptime tag: std.meta.Tag(Frame)) @FieldType(Frame, @tagName(tag)) {
        const payload = @field(self.frames.items[self.frames.items.len - 1], @tagName(tag));
        self.frames.items.len -= 1;
        return payload;
    }
    fn hasWorkDriver(self: *const Fiber) bool {
        return self.native == .work or self.native == .work_park_request or
            self.native == .work_park_resume;
    }
    /// Scheduler-owned teardown of all user-sized fiber cargo. Each fiber
    /// of budget retires at most one continuation, operand, or native owner.
    /// Array storage is released by `deinit` after this cursor reports
    /// complete.
    pub fn advanceSchedulerTeardown(self: *Fiber, budget: usize) CleanupProgress {
        std.debug.assert(budget != 0);
        var consumed: usize = 0;
        while (consumed != budget) {
            switch (self.native) {
                .work, .work_park_request, .work_park_resume => {
                    const driver = self.takeWorkDriver().?;
                    driver.deinit(self.releases, self.allocator);
                    consumed += 1;
                    continue;
                },
                .park_request => |request| {
                    self.native = .idle;
                    request.deinit(self.releases);
                    consumed += 1;
                    continue;
                },
                .park_resume => |result| {
                    self.native = .idle;
                    result.deinit(self.releases);
                    consumed += 1;
                    continue;
                },
                .idle => {},
            }
            if (self.current) |current| {
                self.current = null;
                current.release(self.releases);
                consumed += 1;
                continue;
            }
            if (self.frames.pop()) |frame| {
                self.deinitPoppedFrame(frame);
                consumed += 1;
                continue;
            }
            if (self.stack.pop()) |item| {
                self.releases.releaseValue(item);
                consumed += 1;
                continue;
            }
            switch (self.terminal) {
                .pending, .failed => {
                    self.terminal.deinit(self.releases);
                    consumed += 1;
                    continue;
                },
                .evaluating, .unwinding, .incomplete, .exit => {},
            }
            self.boundary_index = null;
            self.floor.set(0, null);
            return .{ .complete = true, .consumed = consumed };
        }
        return .{ .complete = false, .consumed = consumed };
    }
    pub fn inAttempt(self: *const Fiber) bool {
        var index = self.boundary_index;
        while (index) |frame_index| {
            const boundary = self.frames.items[@backingInt(frame_index)].boundary;
            if (boundary.mode == .attempt) return true;
            index = boundary.previous_boundary;
        }
        return false;
    }
    /// Whether a module construction is open anywhere in this fiber's frame
    /// stack. Unlike the direct-root test `testDeclarationCursor` applies, any
    /// depth counts: a helper word the body calls and an `@attempt` nested in
    /// the body are still construction, so a body cannot launder a task launch
    /// through code it defines first.
    /// The names `words` lists from where this activation runs: a session
    /// root's top-level directory, or the directory of the running module's
    /// current registration.
    pub fn visibleNameRoot(self: *Fiber) reflection.VisibleNameRoot {
        return switch (self.environment.scopeOf(self.currentScope())) {
            .module => |name| {
                var view = self.inherited.registry.view();
                const generation = view.moduleFind(name) orelse {
                    view.deinit();
                    return .core;
                };
                return .{ .image = .{ .entries = generation.entries(), .view = view } };
            },
            .core => .core,
            .session => .{ .session = self.inherited.registry.view() },
        };
    }

    /// The image under construction whose root is `scope`, found through the
    /// open module boundaries: the one place its staged names are written.
    pub fn stagingImage(self: *Fiber, scope: env.ScopeId) ?*modules.OwnedImage {
        var index = self.boundary_index;
        while (index) |frame_index| {
            const boundary = &self.frames.items[@backingInt(frame_index)].boundary;
            switch (boundary.mode) {
                .module => |*module| {
                    if (module.image.root().scope == scope) return &module.image;
                },
                .attempt, .load => {},
            }
            index = boundary.previous_boundary;
        }
        return null;
    }
    pub fn inModuleConstruction(self: *const Fiber) bool {
        var index = self.boundary_index;
        while (index) |frame_index| {
            const boundary = self.frames.items[@backingInt(frame_index)].boundary;
            if (boundary.mode == .module) return true;
            index = boundary.previous_boundary;
        }
        return false;
    }

    /// Sized to the largest driver that opts in, a numeric reduction, and
    /// checked by `inlineDriverCapable`.
    const driver_slot_len = 648;
    const driver_slot_align = 16;

    /// Sized to the application states that opt in, checked by
    /// `housedApplicationCapable`.
    const application_slot_len = 224;
    const application_slot_align = 8;
    const application_slot_count = 4;
    const ApplicationSlot = struct {
        busy: bool = false,
        bytes: [application_slot_len]u8 align(application_slot_align),
    };

    /// Gives `initial` a place to live for the length of its application:
    /// a free slot, or an allocation when none is free. Consuming: a failed
    /// allocation retires the state.
    pub fn houseApplication(self: *Fiber, initial: anytype) error{OutOfMemory}!*HousedApplication(@TypeOf(initial)) {
        const Driver = @TypeOf(initial);
        if (comptime !housedApplicationCapable(Driver))
            @compileError(@typeName(Driver) ++ " does not declare housed_application");
        const Housing = ApplicationHousing(Driver);
        for (&self.application_slots) |*slot| {
            if (slot.busy) continue;
            slot.busy = true;
            const housing: *Housing = @ptrCast(@alignCast(&slot.bytes));
            housing.* = .{ .vacancy = &slot.busy, .driver = initial };
            return @ptrCast(housing);
        }
        var pending = initial;
        const housing = self.allocator.create(Housing) catch |err| {
            heap.deinitDriverFields(self.releases, self.allocator, &pending);
            return err;
        };
        housing.* = .{ .vacancy = null, .driver = pending };
        return @ptrCast(housing);
    }

    fn acquireInlineDriver(self: *Fiber, comptime Driver: type) ?*Driver {
        if (self.driver_slot_busy) return null;
        self.driver_slot_busy = true;
        return @ptrCast(@alignCast(&self.driver_slot));
    }

    fn ownsInlineDriver(self: *const Fiber, driver: *const anyopaque) bool {
        return @intFromPtr(driver) == @intFromPtr(&self.driver_slot);
    }

    fn releaseInlineDriver(self: *Fiber) void {
        std.debug.assert(self.driver_slot_busy);
        self.driver_slot_busy = false;
    }

    pub fn deinit(self: *Fiber) void {
        self.bodies.deinit(self.allocator);
        self.summaries.deinit(self.allocator, self.releases);
        if (self.current) |current| current.release(self.releases);
        while (self.frames.pop()) |frame| self.deinitPoppedFrame(frame);
        self.frames.deinit(self.allocator);
        for (self.stack.items) |item| self.releases.releaseValue(item);
        self.stack.deinit(self.allocator);
        self.terminal.deinit(self.releases);
        switch (self.native) {
            .idle => {},
            .work => |driver| driver.deinit(self.releases, self.allocator),
            .work_park_request => |state| {
                state.request.deinit(self.releases);
                state.driver.deinit(self.releases, self.allocator);
            },
            .work_park_resume => |state| {
                state.result.deinit(self.releases);
                state.driver.deinit(self.releases, self.allocator);
            },
            .park_request => |request| request.deinit(self.releases),
            .park_resume => |result| result.deinit(self.releases),
        }
        for (self.locals.items) |item| self.releases.releaseValue(item);
        self.locals.deinit(self.allocator);
        // After every evaluation, frame, driver and failure that could hold a
        // flattened list's code.
        self.flattened.deinit(self.allocator, self.releases);
        self.* = undefined;
    }

    fn deinitPoppedFrame(self: *Fiber, popped: Frame) void {
        var frame = popped;
        if (frame == .effect_check) frame.effect_check.restoreActive(self);
        // An unwind pops a measured frame before it restores the boundary's
        // floor; nothing requires operands in between, but the pointer must
        // not outlive the state the frame's context owns.
        if (frame == .application and frame.application.mode == .measured and
            self.floor.soft == frame.application.mode.measured)
            self.floor.restore(frame.application.mode.measured.beneath);
        frame.deinit(self.releases, self.allocator);
    }

    pub fn beginNativeTiming(self: *const Fiber) ?i128 {
        if (!self.inherited.native_diagnostics) return null;
        const io = self.inherited.runtime().host_io;
        return std.Io.Clock.awake.now(io).nanoseconds;
    }

    /// Reports that a definition or import of `name` shadows the public core
    /// word of that name: for top-level code, or within `module`. Advisory:
    /// the binding stands either way, `core.name` still reaches core, and a
    /// failed write changes nothing.
    pub fn warnCoreShadowing(self: *Fiber, name: intern.BindingName, module: ?intern.ModuleName) void {
        if (!self.environment.isPublicCoreName(name)) return;
        const console = self.inherited.console() orelse return;
        const spelling = intern.get(intern.bindingId(name));
        const P = console_api.Console.Piece;
        settleAdvisoryDiagnostic(if (module) |owner| console.writeDiagnosticPieces(&.{
            P{ .literal = "warning: module `" },
            P{ .untrusted = intern.get(intern.moduleId(owner)) },
            P{ .literal = "` defines `" },
            P{ .untrusted = spelling },
            P{ .literal = "`, shadowing the core word within the module; `core." },
            P{ .untrusted = spelling },
            P{ .literal = "` still reaches it" },
        }) else console.writeDiagnosticPieces(&.{
            P{ .literal = "warning: `" },
            P{ .untrusted = spelling },
            P{ .literal = "` now shadows the core word for top-level code; `core." },
            P{ .untrusted = spelling },
            P{ .literal = "` still reaches it" },
        }));
    }

    fn settleAdvisoryDiagnostic(result: error{WriteFailed}!void) void {
        if (result) |_| {} else |err| switch (err) {
            error.WriteFailed => {},
        }
    }

    /// Native code cannot be preempted. This optional observation reports a
    /// long slice after it returns; it provides no sandboxing or instruction
    /// reduction, and the default path does not sample the clock at all.
    pub fn finishNativeTiming(
        self: *Fiber,
        instance: *native_module.ModuleInstance,
        started: ?i128,
    ) void {
        const start = started orelse return;
        const io = self.inherited.runtime().host_io;
        const end = std.Io.Clock.awake.now(io).nanoseconds;
        const elapsed: u64 = @intCast(@max(end - start, 0));
        if (!instance.recordDuration(elapsed)) return;
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "native module `{s}` returned after an over-quantum slice ({d} ns)\n",
            .{ intern.get(intern.moduleId(instance.name())), elapsed },
        ) catch return;
        if (self.inherited.console()) |console| {
            settleAdvisoryDiagnostic(console.writeDiagnostics(line, false));
        }
    }
    pub fn currentScope(self: *const Fiber) env.ScopeId {
        return self.current.?.scope();
    }
    /// Links words written into `scope`, a root, by code of `provenance`. A
    /// word written in a module's root refers to the module by name.
    pub fn rootLinker(
        self: *Fiber,
        scope: env.ScopeId,
        provenance: modules.RegistrationProvenance,
    ) env.SymbolLinker {
        return self.environment.linker(scope, provenance);
    }
    /// The word `name` as the running activation would have written it in
    /// `source`: in that activation's root.
    pub fn linkedWord(self: *Fiber, name: u32, source: modules.RegistrationProvenance) error{OutOfMemory}!value.Symbol {
        const linker = self.rootLinker(self.currentScope(), source);
        return .{ .name = name, .slot = try linker.link(name) };
    }
    /// The source of the word being dispatched, which is the authority a
    /// primitive registers, loads, and links words under: the occurrence the
    /// running code reached, or the word `execute` or a resumed lookup
    /// dispatched in its place. A primitive whose work outlives its call
    /// asks when it is called.
    pub fn dispatchedSource(self: *Fiber) error{OutOfMemory}!modules.RegistrationProvenance {
        const word = self.dispatched orelse occurrence: {
            const current = self.current orelse return self.rootSource();
            const at = self.written(current.code, self.active_index);
            const form = formAt(at.code, at.index);
            if (form != .symbol) return .ordinary;
            break :occurrence form.symbol;
        };
        return self.sourceOf(word);
    }
    /// The source a root's own text is written in when it names no file:
    /// the project's local scope under a module map, and ordinary code
    /// otherwise.
    pub fn rootSource(self: *const Fiber) modules.RegistrationProvenance {
        return if (self.inherited.module_snapshot) |snapshot| .rootScope(snapshot.localScope()) else .ordinary;
    }
    /// Runs `word` as the word being dispatched, for a dispatch that does
    /// not run the occurrence at the current position.
    pub fn executeAs(self: *Fiber, word: value.Symbol) MachineError!void {
        const outer = self.dispatched;
        self.dispatched = word;
        defer self.dispatched = outer;
        return self.executeWord(word);
    }
    /// The word `name` linked to core as standard-library source, as a word
    /// the implementation builds for itself is: it means core's binding
    /// wherever it runs.
    pub fn coreWord(self: *Fiber, name: u32) error{OutOfMemory}!value.Symbol {
        const linker = self.environment.linker(self.environment.coreScopeId(), .standard_library);
        return .{ .name = name, .slot = try linker.link(name) };
    }
    /// The root a definition, removal, or import writes. Refused inside a
    /// task, which runs in its spawner's root without owning it.
    /// What publishes a definition made in core: the bootstrap fiber's
    /// authority, and nothing for any other fiber.
    pub fn corePublisher(self: *const Fiber) ?env.CorePublisher {
        return switch (self.role) {
            .bootstrap => |publisher| publisher,
            .root, .task => null,
        };
    }
    pub fn definitionScope(self: *Fiber) MachineError!env.ScopeId {
        const scope = self.currentScope();
        // A task runs in its spawner's root without owning it. A module
        // scope admits definitions only while its construction stages them,
        // which the definition word checks.
        if (self.role == .task and scope == self.environment.sessionScopeId()) return self.fail(
            .domain,
            "definitions are not legal inside a task; a task runs in its spawner's root without owning it",
        );
        return scope;
    }
    /// The source name attached to the occurrence being dispatched. The
    /// archive owns the returned bytes for at least as long as the current
    /// code header, which the activation retains across any driver this call
    /// starts. Runtime-built code has no entry and returns null.
    pub fn activeSourceName(self: *const Fiber) ?[]const u8 {
        const current = self.current orelse return null;
        const site = self.written(current.code, self.active_index);
        const located = self.archive.locate(site.code, site.index) orelse
            return null;
        return located.source_name;
    }
    /// The module whose code is running, if the current root is a module's.
    pub fn currentModule(self: *const Fiber) ?intern.ModuleName {
        return switch (self.environment.scopeOf(self.currentScope())) {
            .module => |name| name,
            .core, .session => null,
        };
    }
    /// Begin publishing one first-class test into the candidate owned by the
    /// immediately enclosing module-construction boundary. Requiring that
    /// boundary to be the top frame distinguishes the construction body's
    /// direct root from quotations or child fibers that merely inherit its
    /// scope.
    pub fn testDeclarationCursor(
        self: *Fiber,
        name: intern.BindingName,
        body: *env.Quotation,
        effect: ?env.ValidatedEffect,
        doc: ?*env.DocumentationString,
    ) MachineError!modules.TestDeclarationCursor {
        const boundary_index = self.boundary_index orelse
            return self.fail(.domain, "test is legal only at a direct module construction root");
        if (@backingInt(boundary_index) + 1 != self.frames.items.len)
            return self.fail(.domain, "test is legal only at a direct module construction root");
        const frame = &self.frames.items[@backingInt(boundary_index)];
        if (frame.* != .boundary or frame.boundary.mode != .module)
            return self.fail(.domain, "test is legal only at a direct module construction root");
        const candidate = &frame.boundary.mode.module.image;
        if (self.current.?.code != frame.boundary.mode.module.root_code)
            return self.fail(.domain, "test is legal only at a direct module construction root");
        if (self.currentScope() != candidate.root().scope)
            return self.fail(.domain, "test is legal only at a direct module construction root");
        if (self.inherited.test_execution == null)
            return .discard();
        return candidate.testDeclarationCursor(name, body, effect, doc);
    }
    /// The site a combinator's quotation runs at, captured when it launches.
    pub fn applicationSite(self: *const Fiber) ExecutionSite {
        return self.current.?.site;
    }
    fn installDriver(self: *Fiber, context: anytype) void {
        const Context = @TypeOf(context);
        const pointer = switch (@typeInfo(Context)) {
            .pointer => |info| info,
            else => @compileError("work driver context must be a pointer"),
        };
        if (pointer.size != .one) @compileError("work driver context must be a single-item pointer");
        const Driver = pointer.child;
        const adapters = WorkDriverAdapters(Driver);
        const installed = WorkDriver{
            .context = @ptrCast(context),
            .resume_fn = adapters.advance,
            .deinit_fn = if (comptime inlineDriverCapable(Driver))
                (if (self.ownsInlineDriver(context)) adapters.deinitInline else adapters.deinit)
            else
                adapters.deinit,
            .site = if (self.current) |current| .{
                .code = current.code,
                .index = self.active_index,
            } else null,
        };
        std.debug.assert(self.native == .idle);
        self.native = .{ .work = installed };
    }
    /// Consumes a fully initialized, heap-allocated continuation whose type
    /// explicitly requires address-stable construction. Ordinary drivers use
    /// `startDriver`, which owns allocation failure as well as installation.
    pub fn adoptDriver(self: *Fiber, context: anytype) void {
        return self.adoptDriverAs(*Fiber, context);
    }
    fn adoptDriverAs(self: *Fiber, comptime Held: type, context: anytype) void {
        const Driver = @typeInfo(@TypeOf(context)).pointer.child;
        comptime requireDriverAuthority(Driver, Held);
        if (!@hasDecl(Driver, "address_stable_driver"))
            @compileError("adoptDriver requires an address-stable driver declaration");
        _ = comptime heap.validateDriverOwnership(Driver);
        self.installDriver(context);
    }
    /// Allocate and install a continuation as one ownership transfer. Driver
    /// values accepted here opt into field-derived ownership, so allocation
    /// failure retires the still-uninstalled value without a bespoke cleanup
    /// path.
    pub fn startDriver(self: *Fiber, initial: anytype) error{OutOfMemory}!void {
        return self.startDriverAs(*Fiber, initial);
    }
    fn startDriverAs(self: *Fiber, comptime Held: type, initial: anytype) error{OutOfMemory}!void {
        const Driver = @TypeOf(initial);
        comptime requireDriverAuthority(Driver, Held);
        switch (comptime heap.validateDriverOwnership(Driver)) {
            .fields, .bounded_retirement => {},
            .self_owned => @compileError("self-owned drivers require address-stable construction"),
        }
        var pending = initial;
        if (comptime inlineDriverCapable(Driver)) {
            if (self.acquireInlineDriver(Driver)) |slot| {
                slot.* = pending;
                self.installDriver(slot);
                return;
            }
        }
        const driver = self.allocator.create(Driver) catch |err| {
            heap.deinitDriverFields(self.releases, self.allocator, &pending);
            return err;
        };
        driver.* = pending;
        self.installDriver(driver);
    }

    /// Starts a driver by running its first step where it is started, and
    /// installs it only when that step leaves work for a later one. The step
    /// draws on the same budget, and a failure surfaces at the same site, as
    /// it would from the machine loop, so a driver whose work fits the rest of
    /// the turn costs no installation and no loop round trip. A driver started
    /// here completes or steps; it never detaches or parks, since it has not
    /// been installed.
    pub fn runDriver(self: *Fiber, initial: anytype) MachineError!void {
        var pending = initial;
        return self.runDriverAt(&pending);
    }

    /// `runDriver` over a driver its caller built in place, which consumes
    /// the driver's fields exactly as `runDriver` does without copying it.
    pub fn runDriverAt(self: *Fiber, pending: anytype) MachineError!void {
        const Driver = @typeInfo(@TypeOf(pending)).pointer.child;
        if (!turn_core.mayDispatch(self.kernel_budget)) return self.startDriver(pending.*);
        const progress = first: {
            pollBeforeStep(Driver, self) catch |err| break :first err;
            break :first Driver.advance(self, pending);
        } catch |err| {
            heap.deinitDriverFields(self.releases, self.allocator, pending);
            return err;
        };
        switch (progress) {
            .stepped => return self.startDriver(pending.*),
            .output => |item| {
                heap.deinitDriverFields(self.releases, self.allocator, pending);
                return self.pushOwned(item);
            },
            .completed => heap.deinitDriverFields(self.releases, self.allocator, pending),
            .yielded, .reserved_output, .detached, .failed => unreachable,
        }
    }

    /// Destroy a driver that may be living in the fiber's inline slot. A driver
    /// that opts into inline storage must retire itself through this rather
    /// than `heap.destroyDriver`, which would hand slot memory to the
    /// allocator.
    fn finishDriver(self: *Fiber, driver: anytype) void {
        const Driver = @typeInfo(@TypeOf(driver)).pointer.child;
        if (comptime inlineDriverCapable(Driver)) {
            if (self.ownsInlineDriver(driver)) {
                heap.deinitDriverFields(self.releases, self.allocator, driver);
                self.releaseInlineDriver();
                return;
            }
        }
        heap.destroyDriver(self.releases, self.allocator, driver);
    }
    /// Moves the top `count` operands into the fiber's locals, the
    /// first declared local ending on top. The operand stack is machine-owned,
    /// so the move lives here and the primitive keeps only its validation.
    fn bindLocals(self: *Fiber, count: usize) error{OutOfMemory}!void {
        try self.locals.ensureUnusedCapacity(self.allocator, count);
        const base = self.stack.items.len - count;
        var remaining = count;
        while (remaining != 0) {
            remaining -= 1;
            self.locals.appendAssumeCapacity(self.stack.items[base + remaining]);
        }
        self.stack.shrinkRetainingCapacity(base);
    }

    fn readLocal(self: *Fiber, index: usize) error{OutOfMemory}!void {
        const depth = self.locals.items.len;
        try self.pushBorrowed(self.locals.items[depth - 1 - index]);
    }

    fn unbindLocals(self: *Fiber, count: usize) void {
        for (0..count) |_| {
            const item = self.locals.pop().?;
            self.releases.releaseValue(item);
        }
    }

    /// Detach the installed continuation and destroy it. A driver that has
    /// finished its own work ends exactly this way, and routing every one of
    /// them through a single place is what keeps inline-slot storage from ever
    /// reaching the allocator.
    pub fn retireDriver(self: *Fiber, driver: anytype) void {
        self.detachWorkDriver(driver);
        self.finishDriver(driver);
    }
    /// Consumes the currently installed erased continuation without invoking
    /// its destructor. Self-replacing drivers use this before destroying their
    /// concrete state and installing the typed successor.
    pub fn detachWorkDriver(self: *Fiber, context: anytype) void {
        const driver = self.takeWorkDriver().?;
        std.debug.assert(driver.context == @as(*anyopaque, @ptrCast(context)));
    }
    /// Charges one finished application continuation to the fiber's dispatch
    /// fuel, exactly as fetching a form does. A body that dispatches nothing
    /// still spends fuel here, so an empty iteration reaches the exhaustion
    /// safe point where cancellation is observed and the slice ends. The
    /// continuation itself never ends a slice: the same bound that limits a
    /// run of forms limits a run of resumed continuations.
    pub fn chargeContinuationStep(self: *Fiber) void {
        self.fuel -|= 1;
    }

    /// Mints the nominal proof that this callback installed the work which
    /// will launch its nested inline child. The machine validates the proof
    /// against the still-installed driver before preserving the parent frame.
    pub fn suspendInlineApplication(self: *Fiber) ApplicationStep {
        const driver = self.workDriver() orelse unreachable;
        return .{ .suspend_inline = @ptrCast(driver.context) };
    }
    /// Start the ordinary qualified-name loader without executing or importing
    /// an export. The caller supplies an initialized root and drives it through
    /// `runInitializedRoot`; reflection and completion use this same path.
    pub fn loadModuleOnly(self: *Fiber, name: intern.ModuleName) MachineError!void {
        self.active_word = .plain(intern.moduleId(name));
        try self.autoLoadModule(name, .{
            .qualified = intern.moduleId(name),
            .context = self.rootSource(),
            .continuation = .load_only,
        });
    }

    /// A reflection primitive already consumed its symbol before discovering
    /// a cold qualified module. Restore that operand, link included, and
    /// rewind the primitive call, then use the same loader/retry protocol as
    /// executable dispatch.
    pub fn retryQualifiedOperandAfterLoad(
        self: *Fiber,
        requested: value.Symbol,
        module: binder.UnregisteredModule,
    ) MachineError!WorkProgress {
        try self.replayOperand(requested);
        try self.autoLoadModule(module.name, .{
            .qualified = requested.name,
            .context = module.searcher,
            .continuation = .replay,
        });
        return .detached;
    }
    /// A completed auto-load registers the module before resuming the tagged
    /// qualified operation. The requested spelling also identifies a
    /// misspelled export in the final undefined-word error.
    fn autoLoadModule(
        self: *Fiber,
        name: intern.ModuleName,
        request: load.QualifiedLoadRequest,
    ) MachineError!void {
        return load.autoLoadModule(.of(self), name, request);
    }
    pub fn loadSourceOnly(self: *Fiber, source: *const map_state.SourceScope) MachineError!void {
        return load.loadSource(.of(self), source);
    }

    /// Standard-library names are reserved, like `core`: only embedded loading
    /// registers them, so a stdlib name means the same module in every scope,
    /// whether or not it has loaded. User registration and removal under one
    /// are `'domain`.
    pub fn refuseReservedModule(self: *Fiber, name: intern.ModuleName, provenance: modules.RegistrationProvenance) MachineError!void {
        if (provenance == .standard_library) return;
        if (module_lookup.embeddedLibrary(name) == null) return;
        return self.failFmt(
            .domain,
            "module name `{s}` is reserved for the standard library",
            .{intern.get(intern.moduleId(name))},
        );
    }

    /// A named module lookup as the source that wrote `operand`, the symbol
    /// that refers to the module, sees it.
    pub fn moduleLookup(self: *Fiber, operand: value.Symbol, name: intern.ModuleName) error{OutOfMemory}!module_lookup.HeldModuleLookup {
        const searcher = try self.sourceOf(operand);
        const view = self.inherited.registry.view();
        return .{ .view = view, .cursor = .init(&view, self.inherited.module_snapshot, searcher, name) };
    }

    /// The source `operand` was written in: what its cell records.
    pub fn sourceOf(self: *Fiber, operand: value.Symbol) error{OutOfMemory}!modules.RegistrationProvenance {
        return binder.sourceOf(self.environment, try self.cellOf(operand));
    }

    /// A mapped source file registers only the modules its artifact exports;
    /// code with no source identity registers any name.
    pub fn refuseUnexportedModule(self: *Fiber, name: intern.ModuleName, provenance: modules.RegistrationProvenance) MachineError!void {
        const source = provenance.sourceScope() orelse return;
        if (source.exports(name)) return;
        return self.failFmt(
            .domain,
            "module `{s}` is not exported by its source file `{s}`",
            .{ intern.get(intern.moduleId(name)), source.location().relative_path },
        );
    }
    /// Consumes `source` on success and failure.
    pub fn parseSourceOwned(self: *Fiber, source: []u8) MachineError!void {
        return load.parseSource(.of(self), source);
    }
    /// `path @load`: the file runs as a stack-isolated unit on an empty stack.
    pub fn loadFileOwned(self: *Fiber, path: []u8, path_value: Value) MachineError!void {
        return load.loadFile(.of(self), path, path_value, self.active_word);
    }
    /// Records the offending path or url on the failure being raised, which is
    /// the shape every host-IO error reports. Keeps `ErrorDataKey` private
    /// while letting a builtin module attach the one datum it owns.
    pub fn addErrorPath(self: *Fiber, path: Value) void {
        self.pendingFailure().addData(.path, path);
    }
    /// The stable data dictionary every capability-gated filesystem failure
    /// carries: the public operation, the named root and path (or both ends of
    /// a transfer), and a closed portable reason symbol.
    pub fn addErrorFilesystem(self: *Fiber, data: FilesystemErrorData) void {
        const failure = self.pendingFailure();
        failure.addData(.operation, data.operation);
        switch (data.target) {
            .single => |single| {
                failure.addData(.root, single.root);
                failure.addData(.path, single.path);
            },
            .transfer => |transfer| {
                failure.addData(.@"source-root", transfer.source_root);
                failure.addData(.@"source-path", transfer.source_path);
                failure.addData(.@"destination-root", transfer.destination_root);
                failure.addData(.@"destination-path", transfer.destination_path);
            },
        }
        failure.addData(.reason, data.reason);
    }
    /// Attach the closed-vocabulary `'reason` symbol a capability refusal
    /// reports, so programs branch on the symbol rather than the message.
    pub fn addErrorReason(self: *Fiber, reason: Value) void {
        self.pendingFailure().addData(.reason, reason);
    }
    /// The one absence-is-absence failure for `getenv`: an unset variable is
    /// an error carrying the requested name, never an empty string.
    pub fn unsetEnvironVariable(
        self: *Fiber,
        name: []const u8,
        name_value: Value,
    ) MachineError {
        const failure = self.failFmt(.io, "environment variable `{s}` is not set", .{name});
        self.pendingFailure().addData(.name, name_value);
        return failure;
    }
    /// Resolves one environment variable against the session snapshot.
    pub fn environLookup(self: *Fiber, name: []const u8) Environ.LookupCursor {
        const entries: []const Environ.Entry =
            self.inherited.runtime().environ.entries;
        return .{ .entries = entries, .name = name };
    }
    /// A resolution miss, reported as the reference the program actually
    /// wrote, including a dotted one whose module never loaded, with the
    /// lookup chain that was searched.
    pub fn undefinedWordIn(self: *Fiber, word: u32, chain: LookupChain) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined word `{s}`", .{intern.get(word)});
        self.pendingFailure().addData(.name, .{ .symbol = .{ .name = word } });
        self.addLookupChain(chain) catch return error.OutOfMemory;
        return failure;
    }
    /// The same failure as `undefinedWordIn`, for a name that is not the word
    /// currently being traced: the active word becomes the requested name so
    /// the diagnostic reports what was asked for.
    pub fn undefinedNameIn(self: *Fiber, name: u32, chain: LookupChain) MachineError {
        self.active_word = .plain(name);
        return self.undefinedWordIn(name, chain);
    }
    fn addLookupChain(self: *Fiber, chain: LookupChain) error{OutOfMemory}!void {
        const named = try intern.intern(chain.spelling());
        self.pendingFailure().addData(.scope, .{ .symbol = .{ .name = named } });
    }
    pub fn available(self: *const Fiber) usize {
        return self.stack.items.len - self.floor.base;
    }
    pub inline fn require(self: *Fiber, count: usize) MachineError!void {
        // One compare on the hot path: `guard` is the stack base unless the
        // innermost soft floor has returned originals above it.
        if (count > self.stack.items.len - self.floor.guard) return self.requireAcross(count);
    }
    noinline fn requireAcross(self: *Fiber, count: usize) MachineError!void {
        @branchHint(.cold);
        if (!try floor_api.cover(self, count)) return self.failUnderflow(count);
    }
    noinline fn failUnderflow(self: *Fiber, count: usize) MachineError {
        @branchHint(.cold);
        return self.failUnderflowOf(self.activeWordName(), count);
    }
    /// A locals binder that cannot take its values. The reader lowered it into
    /// the reserved `_ll`, which refers to nothing a program wrote. Opening a
    /// word's body, the binder is that word's arity check, so the word fails
    /// as a primitive would: it is the failing word, and its body activation,
    /// which never got past entry, is not repeated in the trace. Opening any
    /// other quotation, there is no word to blame, and the binding itself is
    /// what fails.
    noinline fn failBinding(self: *Fiber, count: usize) MachineError {
        @branchHint(.cold);
        const current = &self.current.?;
        const owner = current.activation.bodyOwner();
        self.active_word = owner;
        if (owner == no_word) return self.failUnderflowOf("local binding", count);
        const attribution = current.activation.attribution;
        current.activation.release(self.releases);
        current.activation = .none;
        const failure = self.failUnderflowOf(self.activeWordName(), count);
        // A helper's arity check fails at its caller; the call site went with
        // the released activation, so the report omits a position instead.
        self.pendingFailure().word_attribution = attribution;
        return failure;
    }
    fn failUnderflowOf(self: *Fiber, subject: []const u8, count: usize) MachineError {
        const failure = self.failFmt(
            .underflow,
            "{s} needs {d} stack value{s}, but found {d}",
            .{
                subject,
                count,
                if (count == 1) "" else "s",
                self.available(),
            },
        );
        self.pendingFailure().addData(.needed, .{ .int = @intCast(count) });
        self.pendingFailure().addData(.available, .{ .int = @intCast(self.available()) });
        return failure;
    }
    /// Fails as an operand check short by `count` values would.
    pub fn failShort(self: *Fiber, count: usize) MachineError {
        return self.failUnderflow(count);
    }
    pub fn popValue(self: *Fiber) MachineError!heap.OwnedValue {
        try self.require(1);
        return .init(self.releases, self.takeStackOwned().?);
    }
    /// The top operand as the element a list built at run time stores: see
    /// `value.datum`. Every word that moves a stack value into a list cell
    /// pops it this way.
    pub fn popDatum(self: *Fiber) MachineError!heap.OwnedValue {
        try self.require(1);
        return .init(self.releases, value.datum(self.takeStackOwned().?));
    }
    /// The top two operands, the lower first, after one underflow check.
    pub fn popPair(self: *Fiber) MachineError!struct { heap.OwnedValue, heap.OwnedValue } {
        try self.require(2);
        const right = self.takeStackOwned().?;
        const left = self.takeStackOwned().?;
        return .{ .init(self.releases, left), .init(self.releases, right) };
    }
    fn popChecked(
        self: *Fiber,
        comptime expected: []const u8,
        comptime accepts: fn (Value) bool,
    ) MachineError!heap.OwnedValue {
        var item = try self.popValue();
        errdefer item.deinit();
        if (!accepts(item.borrow())) return self.typeError(expected);
        return item;
    }
    pub fn popList(self: *Fiber) MachineError!heap.OwnedValue {
        return self.popChecked("a list", struct {
            fn accepts(item: Value) bool {
                return item == .list;
            }
        }.accepts);
    }
    pub fn popDict(self: *Fiber) MachineError!heap.OwnedValue {
        return self.popChecked("a dict", struct {
            fn accepts(item: Value) bool {
                return item == .dict;
            }
        }.accepts);
    }
    pub fn popQuotation(self: *Fiber) MachineError!heap.OwnedValue {
        return self.popChecked("a quotation/list", struct {
            fn accepts(item: Value) bool {
                return item == .list;
            }
        }.accepts);
    }
    pub fn popString(self: *Fiber) MachineError!heap.OwnedValue {
        return self.popChecked("a string", struct {
            fn accepts(item: Value) bool {
                return item.isString();
            }
        }.accepts);
    }
    /// A symbol operand with its link, as written: what an explicit lookup
    /// resolves in its own root.
    pub fn popWord(self: *Fiber) MachineError!value.Symbol {
        var item = try self.popValue();
        defer item.deinit();
        return switch (item.borrow()) {
            .symbol => |word| .{ .name = word.name, .slot = env.unquoted(word.slot) },
            else => self.typeError("a symbol name"),
        };
    }
    pub fn popSymbol(self: *Fiber) MachineError!u32 {
        var item = try self.popValue();
        defer item.deinit();
        return switch (item.borrow()) {
            .symbol => |name| name.name,
            else => self.typeError("a symbol name"),
        };
    }
    pub fn discard(self: *Fiber, count: usize) void {
        std.debug.assert(self.available() >= count);
        self.floor.noteShrink(self.stack.items.len - count);
        for (0..count) |_| self.releases.releaseValue(self.takeStackOwned().?);
    }
    pub fn reserveStack(self: *Fiber, count: usize) error{OutOfMemory}!StackReservation {
        try self.stack.ensureUnusedCapacity(self.allocator, count);
        return .init(self, count);
    }
    pub fn reserveStackReplacement(
        self: *Fiber,
        input_count: usize,
        output_count: usize,
    ) error{OutOfMemory}!StackReplacement {
        std.debug.assert(self.available() >= input_count);
        const base = self.stack.items.len - input_count;
        try self.stack.ensureTotalCapacity(self.allocator, base + output_count);
        return .{
            .fiber = self,
            .base = base,
            .input_count = input_count,
            .output_count = output_count,
        };
    }
    pub fn nativeInputBorrowed(self: *const Fiber, input_count: usize, index: usize) Value {
        std.debug.assert(index < input_count and self.available() >= input_count);
        return self.stack.items[self.stack.items.len - input_count + index];
    }
    /// Observes one value in the currently visible operand window, bottom
    /// first. Checkpoint cursors retain the returned borrow before yielding;
    /// no raw stack storage escapes this boundary.
    pub fn visibleOperandBorrowed(self: *const Fiber, index: usize) Value {
        std.debug.assert(index < self.available());
        return self.stack.items[self.floor.base + index];
    }
    /// Consumes `item`. The stack owns it on success; the release domain owns
    /// its constant-time retirement if stack growth fails.
    pub inline fn pushOwned(self: *Fiber, item: Value) error{OutOfMemory}!void {
        // A push is a capacity test and a store; only growth is a call.
        const stack = &self.stack;
        if (stack.items.len == stack.capacity) return self.pushOwnedGrowing(item);
        stack.appendAssumeCapacity(item);
    }
    fn pushOwnedGrowing(self: *Fiber, item: Value) error{OutOfMemory}!void {
        self.stack.append(self.allocator, item) catch {
            self.releases.releaseValue(item);
            return error.OutOfMemory;
        };
    }
    /// Consumes `item` into a slot this primitive freed by popping, which
    /// cannot grow the stack.
    pub fn pushIntoFreed(self: *Fiber, item: Value) void {
        self.stack.appendAssumeCapacity(item);
    }
    pub fn pushBorrowed(self: *Fiber, item: Value) error{OutOfMemory}!void {
        heap.retainValue(item);
        return self.pushOwned(item);
    }
    /// Places the pending failure at `code[index]`, the position the failing
    /// path ran in place of, unless an inner position already holds it.
    pub fn setFailureSite(self: *Fiber, code: *Header, index: u32) void {
        if (self.pendingFailureOptional()) |pending| if (pending.site == null) {
            pending.site = .{ .token = .{ .code = code, .index = index } };
        };
    }
    pub fn setWorkDriverSite(self: *Fiber, code: *Header, index: u32) void {
        if (self.workDriver()) |driver| driver.site = .{ .code = code, .index = index };
    }

    /// The single parking choke point. A parked fiber would hold its slot's
    /// turn across an unbounded wait, so a state application refuses to park
    /// here — before any wait — rather than in each parking word, which is
    /// what makes the prohibition total as new parking words are added.
    pub fn park(self: *Fiber, request: ParkRequest) MachineError!void {
        self.installParkRequest(request);
    }

    /// Whether the words after a phrase head continue a recognized phrase,
    /// which then ran in its place.
    pub fn continuesPhrase(self: *Fiber, first_entry: u16) MachineError!bool {
        return idioms.applyHeaded(self, first_entry);
    }
    /// The forms after the dispatching word in its own code, when it was
    /// dispatched from a source position and `count` of them follow. A word
    /// reached any other way (an invocation, a replay) has no phrase after it.
    pub fn followingForms(self: *const Fiber, count: u32) ?FollowingForms {
        const current = if (self.current) |*running| running else return null;
        const next = switch (current.position) {
            .source => |index| index,
            .invocation, .replay, .redispatch => return null,
        };
        if (next == 0 or next - 1 != self.active_index) return null;
        if (@as(u64, next) + count > current.code.length()) return null;
        return .{ .code = current.code, .start = next };
    }
    const FollowingForms = struct {
        code: *Header,
        start: u32,

        pub fn at(self: FollowingForms, offset: u32) Value {
            return list.atUnchecked(.{ .list = self.code }, self.start + offset);
        }
    };
    /// Consumes `count` following forms that a recognized phrase executed.
    pub fn skipFollowingForms(self: *Fiber, count: u32) void {
        const current = &self.current.?;
        current.position = .{ .source = current.position.source + count };
    }
    /// A phrase that runs to the end of its code finishes that code as a
    /// tail call would, so the code's own word no longer traces.
    pub fn commitPhraseTrace(self: *Fiber) void {
        const current = &self.current.?;
        if (current.nextIndex() >= current.code.length()) {
            current.activation.release(self.releases);
            current.activation = .none;
        }
    }
    /// Traces the pending failure through `word`, the definition whose frame
    /// the failing path elided, unless an inner one already holds it.
    fn setFailureTraceParent(self: *Fiber, word: intern.TraceWord, attribution: env.Attribution) void {
        if (self.pendingFailureOptional()) |pending| if (pending.trace_parent == null) {
            pending.trace_parent = word;
            pending.trace_parent_attribution = attribution;
        };
    }
    fn takePrimitiveFailure(self: *Fiber) ?EclErr {
        if (!self.hasPendingFailure()) return null;
        const failure = self.takePendingForUnwind();
        self.finishUnwindCaught();
        return failure;
    }
    fn installPrimitiveFailure(self: *Fiber, failure_value: EclErr) MachineError {
        self.installPendingFailure(failure_value);
        if (self.pendingFailure().word == null and self.active_word != no_word) {
            self.pendingFailure().word = self.active_word;
        }
        return error.Ecl;
    }
    pub fn continueWithIdiom(self: *Fiber, request: IdiomRequest, fallback: IdiomFallback) MachineError!void {
        return idioms.tryApply(self, request, fallback);
    }
    /// The active word as a diagnostic spells it. A module-local word has no
    /// single interned spelling, so the rendering borrows the fiber's scratch;
    /// the returned slice is valid until the next call.
    pub fn activeWordName(self: *Fiber) []const u8 {
        if (self.active_word == no_word) return "evaluation";
        return self.active_word.render(&self.word_scratch);
    }
    pub fn fail(self: *Fiber, kind: ErrorKind, message: []const u8) MachineError {
        self.installPendingFailure(EclErr.init(kind, message));
        if (self.active_word != no_word) self.pendingFailure().word = self.active_word;
        return error.Ecl;
    }
    /// Diagnostic views are bounded and capability-free. Retain their values
    /// before the observing driver releases its resource or exchange.
    pub fn failWithErrorData(self: *Fiber, observation: @import("port_error_data.zig").Observation) MachineError {
        const report = switch (observation.report) {
            .out_of_memory => return error.OutOfMemory,
            .report => |report| report,
        };
        const failure = self.fail(report.kind, report.message[0..report.len]);
        const pending = self.pendingFailure();
        comptime {
            if (@import("port_error_data.zig").max_entries + 2 > @typeInfo(@FieldType(EclErr, "data")).array.len)
                @compileError("native diagnostics must reserve space for source diagnostics");
        }
        if (observation.details) |details| for (0..details.len()) |index| {
            const item = details.value(index);
            heap.retainValue(item);
            pending.data[pending.data_len] = .{ .key = .{ .symbol = details.key(index) }, .value = item };
            pending.data_len += 1;
        };
        return failure;
    }
    fn failAtSource(
        self: *Fiber,
        message: []const u8,
        source_name: []const u8,
        span: reader.Span,
    ) MachineError {
        const owned_source_name = self.allocator.dupe(u8, source_name) catch
            return error.OutOfMemory;
        const failure = self.fail(.parse, message);
        self.pendingFailure().site = .{ .explicit_location = .{
            .source_name = owned_source_name,
            .span = span,
        } };
        return failure;
    }
    pub fn failFmt(
        self: *Fiber,
        kind: ErrorKind,
        comptime format: []const u8,
        args: anytype,
    ) MachineError {
        self.installPendingFailure(EclErr.initFmt(kind, format, args));
        if (self.active_word != no_word) self.pendingFailure().word = self.active_word;
        return error.Ecl;
    }
    pub fn typeError(self: *Fiber, expected: []const u8) MachineError {
        return self.failFmt(
            .type,
            "{s} expected {s}",
            .{ self.activeWordName(), expected },
        );
    }
    /// Raises a language error at a zero-based logical data index. Kernels
    /// call this only after locating the first failing element.
    pub fn failAtIndex(
        self: *Fiber,
        kind: ErrorKind,
        message: []const u8,
        index: usize,
    ) MachineError {
        const failure = self.fail(kind, message);
        self.pendingFailure().addData(.index, .{ .int = @intCast(index) });
        return failure;
    }
    /// Raises a `` `domain `` failure for a dict lookup that missed, carrying
    /// the key that was not found.
    pub fn failMissingKey(self: *Fiber, message: []const u8, key: Value) MachineError {
        const failure = self.fail(.domain, message);
        self.pendingFailure().addData(.key, key);
        return failure;
    }
    /// Reports the two leading-axis lengths that failed to conform.
    pub fn conformError(self: *Fiber, left: usize, right: usize) MachineError {
        const failure = self.failFmt(
            .conform,
            "{s} cannot conform leading axes {d} and {d}",
            .{ self.activeWordName(), left, right },
        );
        self.pendingFailure().addData(.left, .{ .int = @intCast(left) });
        self.pendingFailure().addData(.right, .{ .int = @intCast(right) });
        return failure;
    }
    pub fn applicationContractError(
        self: *Fiber,
        opaque_site: *ApplicationContractSite,
        quotation: *Header,
        expected: Value,
        depths: ApplicationDepths,
        index: ?usize,
    ) MachineError {
        const failure = if (index) |element_index|
            self.failFmt(
                .contract,
                "{s} quotation at element {d} violated its stack effect; expected final depth {d} from {d} seeded value{s}, observed {d}",
                .{
                    self.activeWordName(),
                    element_index,
                    depths.expected,
                    depths.seeded,
                    if (depths.seeded == 1) "" else "s",
                    depths.observed,
                },
            )
        else
            self.failFmt(
                .contract,
                "{s} quotation violated its stack effect; expected final depth {d} from {d} seeded value{s}, observed {d}",
                .{
                    self.activeWordName(),
                    depths.expected,
                    depths.seeded,
                    if (depths.seeded == 1) "" else "s",
                    depths.observed,
                },
            );
        self.pendingFailure().addData(.expected, expected);
        self.pendingFailure().addData(.seeded, .{ .int = @intCast(depths.seeded) });
        self.pendingFailure().addData(.observed, .{ .int = @intCast(depths.observed) });
        if (index) |element_index| {
            self.pendingFailure().addData(.index, .{ .int = @intCast(element_index) });
        }
        const site: *ApplicationSelection = @ptrCast(@alignCast(opaque_site));
        self.pendingFailure().site = .{ .contract_quotation = site.takeFailureSite(quotation) };
        return failure;
    }
    /// Kernel safe point. A flat loop calls this between bounded chunks;
    /// kernels never create threads or make scheduling decisions themselves.
    pub fn pollKernel(self: *Fiber) MachineError!void {
        self.polls += 1;
        if (self.cancelled.load(.acquire)) {
            @branchHint(.cold);
            return self.failCancelled();
        }
    }
    /// Out of line: the poll is inlined wherever a driver step begins, and
    /// installing the failure is the path almost no poll takes.
    noinline fn failCancelled(self: *Fiber) MachineError {
        return self.fail(.cancelled, "unit cancelled");
    }
    /// Charges logical kernel work against the fiber's one budget for the turn.
    /// Keeping the remainder on Fiber means ragged recursion and consecutive
    /// short loops cannot evade the 65,536-element cancellation bound by
    /// resetting a local index. Calls are bounded to one quantum; a block that
    /// reaches the boundary polls before executing and exhausts the turn.
    pub fn advanceKernel(self: *Fiber, amount: usize) MachineError!void {
        _ = try self.chargeKernel(amount);
    }
    /// What a typed cursor may still charge before the interval ends. A loop
    /// bounds its next half-open range by this so the range it commits to is
    /// the range the budget can pay for, rather than discovering the boundary
    /// mid-chunk.
    pub fn remainingKernelFuel(self: *const Fiber) usize {
        return self.kernel_budget.remaining;
    }
    /// The fiber's kernel allowance for work done on its behalf in this turn.
    /// A cursor draws on it directly and hands the same pointer to any cursor
    /// it drives, so nested work cannot begin a quantum of its own. The
    /// machine settles exhaustion after the driver returns.
    /// The result for a step that may have installed a park request: the fiber
    /// parks if it did, and otherwise has more of its own work to do.
    pub fn afterStep(self: *const Fiber) WorkProgress {
        return if (self.hasParkRequest()) .{ .yielded = .park } else .stepped;
    }
    pub fn workBudget(self: *Fiber) *poll_api.WorkBudget {
        return &self.kernel_budget;
    }
    /// A cancellable completion settles its last charge before transferring
    /// execution. Committed delivery and failure cleanup must not use this.
    pub fn pollCancellableCompletion(self: *Fiber) MachineError!void {
        if (turn_core.completionPolls(self.workBudget().*)) try self.pollKernel();
    }
    /// Charges work that has already been committed, such as an inline kernel
    /// block that cannot stop part way. A charge that reaches the end of the
    /// turn's allowance polls cancellation and leaves the allowance exhausted:
    /// it never begins a second quantum within the same turn.
    fn chargeKernel(self: *Fiber, amount: usize) MachineError!bool {
        std.debug.assert(amount <= kernel_poll_quantum);
        if (amount == 0) return false;
        if (comptime root_execution_metrics_enabled)
            self.root_execution_metrics.logical_transitions += amount;
        if (!turn_core.charge(&self.kernel_budget, amount)) return false;
        try self.pollKernel();
        return true;
    }
    /// Consumes a quotation header and applies it inline. Its words resolve
    /// as they are reached.
    pub fn callOwned(self: *Fiber, quotation: *Header) error{OutOfMemory}!void {
        return self.callProgramOwned(quotation, .owned);
    }

    /// Runs `quotation` inline with the caller, resolving one form at a time.
    pub fn callProgramOwned(self: *Fiber, quotation: *Header, program: Program) error{OutOfMemory}!void {
        std.debug.assert(program == .owned);
        const site = self.current.?.site;
        const application_tail = self.tailApplicationIndex();
        // An application that selects its quotation for a contract is found
        // by that quotation's own code, so it runs as written.
        const flattened = if (application_tail == .none) flatten.of(self, site, quotation) catch {
            self.releases.releaseHeader(quotation);
            return error.OutOfMemory;
        } else null;
        const effect_tail = self.replaceTailEffectCandidate(quotation);
        if (application_tail.get()) |application_index| {
            const frame = &self.frames.items[@backingInt(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(quotation);
        }
        const inherited = self.suspendCurrent() catch {
            self.releases.releaseHeader(quotation);
            return error.OutOfMemory;
        };
        const code = if (flattened) |record| run: {
            heap.incRef(record.code);
            record.enter(self.frames.items.len + 1);
            self.releases.releaseHeader(quotation);
            break :run record.code;
        } else quotation;
        self.current = .{
            .code = code,
            .program = program,
            .position = .{ .source = 0 },
            .site = site,
            .activation = inherited,
            .effect_tail = effect_tail,
            .application_tail = application_tail,
            .application_selection = application_tail,
            .flattened = flattened != null,
        };
    }

    /// A completion contract follows authored tail control. Generic application
    /// machinery deliberately does not call this helper:
    /// their continuation restarts once per element and must not add a pair of
    /// code-header atomics to that hot path.
    fn replaceTailEffectCandidate(self: *Fiber, code: *Header) MaybeIndex(EffectCheckIndex) {
        const current = if (self.current) |*running| running else return .none;
        const check_index = current.effect_tail.get() orelse return .none;
        if (!self.isSourceTailPosition(current)) return .none;
        std.debug.assert(self.effect_check_index == check_index);
        const frame = &self.frames.items[@backingInt(check_index)];
        std.debug.assert(frame.* == .effect_check);
        frame.effect_check.replaceSourceCandidate(self.releases, code);
        return current.effect_tail;
    }

    /// Propagates one application's authority through ordinary tail word
    /// dispatch without changing its selected quotation. Only a dynamic
    /// `apply` marks code for ownership transfer into the candidate.
    fn tailApplicationIndex(self: *Fiber) MaybeIndex(ApplicationFrameIndex) {
        const current = if (self.current) |*running| running else return .none;
        if (current.application_tail == .none) return .none;
        if (!self.isSourceTailPosition(current)) return .none;
        return current.application_tail;
    }

    fn validateApplicationProvenanceTarget(
        self: *Fiber,
        target: *const ApplicationProvenanceTarget,
    ) ?ApplicationFrameIndex {
        const raw = @intFromPtr(target);
        const raw_index: u32 = @truncate(raw);
        const raw_nonce: u32 = @truncate(raw >> 32);
        if (raw_nonce == 0 or raw_index >= self.frames.items.len) return null;
        const index: ApplicationFrameIndex = @fromBackingInt(@intCast(raw_index));
        const frame = &self.frames.items[@backingInt(index)];
        if (frame.* != .application) return null;
        const nonce = frame.application.provenance_nonce orelse return null;
        if (@backingInt(nonce) != raw_nonce) return null;
        return index;
    }

    /// Captures the current tail-selection boundary for trusted control
    /// machinery that must suspend through bounded native work before it can
    /// launch the semantically selected quotation. The frame owns the nonce;
    /// relocation preserves it and frame retirement makes the handle stale.
    pub fn applicationProvenanceTarget(
        self: *Fiber,
    ) error{OutOfMemory}!?*const ApplicationProvenanceTarget {
        const index = self.tailApplicationIndex().get() orelse return null;
        const frame = &self.frames.items[@backingInt(index)];
        std.debug.assert(frame.* == .application);
        if (frame.application.provenance_nonce == null)
            frame.application.provenance_nonce = try mintApplicationProvenanceNonce();
        return encodeApplicationProvenanceTarget(index, frame.application.provenance_nonce.?);
    }

    /// Consumes an exhausted Eval. A dynamically applied quotation moves its
    /// already-owned header into the application frame; every other Eval uses
    /// the ordinary release. This delays one existing release but creates no
    /// additional retain/release pair.
    fn retireCompletedEval(self: *Fiber, current: *const Eval) void {
        current.activation.release(self.releases);
        self.retireCompletedCode(current);
    }
    /// `retireCompletedEval` for an evaluation whose activation has already
    /// been handed on, so only its code remains to retire.
    inline fn retireCompletedCode(self: *Fiber, current: *const Eval) void {
        if (current.application_selection.get()) |application_index| {
            const frame = &self.frames.items[@backingInt(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.completeOwned(self.releases, current.intoCode(self.releases));
        } else {
            current.program.release(self.releases, current.code);
        }
    }

    /// Reader-lowered locals end in a `_dl` operation. That cleanup must run
    /// after the authored final form, but it does not make a final control
    /// transfer semantically non-tail. The exact reserved epilogue is the only
    /// continuation shape granted this exception.
    fn isSourceTailPosition(self: *const Fiber, current: *const Eval) bool {
        const length = current.code.length();
        if (current.nextIndex() == length) return true;
        if (length - current.nextIndex() == 1) {
            const drop = list.atUnchecked(.{ .list = current.code }, current.nextIndex());
            // A quoted copy of the operation pushes itself rather than dropping.
            if (drop != .symbol or env.isQuoted(drop.symbol.slot) or drop.symbol.name != self.environment.localsWords().drop) return false;
            const count = env.localOperand(drop.symbol.slot) orelse return false;
            return count <= self.locals.items.len;
        }
        return false;
    }
    /// Starts one quotation application. `application.context` is consumed
    /// on every path. Its callback either returns null (finished) or
    /// transfers that same ownership into the next application.
    pub fn beginApplication(self: *Fiber, application: Application, launch: Launch) MachineError!void {
        return self.launchApplication(.fresh, application, launch, .none);
    }
    /// Hands back an isolated application scope. One that never bound and is
    /// unshared is parked for the next application over the same parent rather
    /// than retired; anything else takes the ordinary path.
    fn launchApplication(
        self: *Fiber,
        /// A fresh application suspends the running evaluation and takes the
        /// activation it hands on; a relaunch brings its frame's activation.
        comptime kind: enum { fresh, relaunch },
        application: Application,
        launch: Launch,
        /// A relaunch's activation, moved into the frame on every path.
        inherited: Activation,
    ) MachineError!void {
        self.require(application.seeded) catch |err| {
            inherited.release(self.releases);
            application.discard(self.releases, self.allocator);
            return err;
        };
        const base = StackWindow.init(self.stack.items.len, application.seeded) orelse unreachable;
        const provenance_target: ?ApplicationFrameIndex = switch (application.provenance) {
            .boundary => null,
            .selected_target => |target| self.validateApplicationProvenanceTarget(target) orelse {
                inherited.release(self.releases);
                application.discard(self.releases, self.allocator);
                return self.fail(.domain, "application provenance target is stale or foreign");
            },
        };
        const select_initial = application.provenance != .boundary;
        // An application that selects its quotation for a contract is found
        // by that quotation's own code, so it runs as written.
        const flattened = if (select_initial) null else flatten.of(self, application.driver.site, application.quotation) catch {
            inherited.release(self.releases);
            application.discard(self.releases, self.allocator);
            return error.OutOfMemory;
        };
        const activation = switch (kind) {
            .relaunch => inherited,
            .fresh => if (self.current != null) self.suspendCurrent() catch {
                application.discard(self.releases, self.allocator);
                return error.OutOfMemory;
            } else Activation.none,
        };
        // From here the frame owns the activation, so a failed append
        // releases it with the rest of the frame.
        const lent = activation.borrowed();
        const application_index: ApplicationFrameIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        // Built in place, as `pushCurrent` builds an evaluation's: a frame
        // assembled apart is copied whole into the array.
        const frame_slot = self.frames.addOne(self.allocator) catch {
            activation.release(self.releases);
            application.discard(self.releases, self.allocator);
            return error.OutOfMemory;
        };
        frame_slot.* = .{ .application = .{
            .driver = application.driver,
            .mode = switch (launch) {
                .in_place => .{ .in_place = base },
                .isolated => .{ .isolated = self.floor.beneath() },
                .measured => |floor| .{ .measured = floor },
            },
            .activation = activation,
            .selection = .{},
        } };
        self.noteFrameDepth();
        switch (launch) {
            .in_place => {},
            .isolated => self.floor.set(base.base(), null),
            .measured => |floor| self.floor.enter(floor, base.base()),
        }
        if (select_initial) {
            const target = provenance_target.?;
            const frame = &self.frames.items[@backingInt(target)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(application.quotation);
        }
        // The combinator state the frame holds keeps the quotation for the
        // whole invocation, so each application borrows it.
        // A flattened list is held by the evaluation that runs it, since the
        // table that made it may let it go first.
        if (flattened) |record| {
            heap.incRef(record.code);
            record.enter(self.frames.items.len + 1);
        }
        self.current = .{
            .code = if (flattened) |record| record.code else application.quotation,
            .program = if (flattened != null) .owned else .borrowed,
            .flattened = flattened != null,
            .position = .{ .source = 0 },
            .site = application.driver.site,
            .activation = lent,
            .application_tail = .some(provenance_target orelse application_index),
            .application_selection = if (select_initial) .some(provenance_target.?) else .none,
        };
    }
    /// Opens a construction boundary for `@defm`. The name has already been
    /// validated; the body evaluates against a fresh image, and completion
    /// publishes that image under the name. The image retains `doc`; the
    /// caller keeps its own reference.
    pub fn moduleOwned(
        self: *Fiber,
        name: intern.ModuleName,
        body_header: *Header,
        doc: ?*env.DocumentationString,
        provenance: modules.RegistrationProvenance,
    ) MachineError!void {
        return module_construction.begin(.of(self), name, body_header, doc, provenance);
    }
    /// Opens one construction boundary. Consuming: the body is owned by the
    /// boundary on success and released here on every failure, and the image is
    /// consumed only once the boundary owns it.
    fn openImageBoundary(
        self: *Fiber,
        candidate: *modules.OwnedImage,
        word: intern.TraceWord,
        body_header: *Header,
    ) MachineError!void {
        const site: ExecutionSite = candidate.root().scope;
        const dropped = self.suspendCurrent() catch {
            self.releases.releaseHeader(body_header);
            return error.OutOfMemory;
        };
        dropped.release(self.releases);
        if (self.frames.items.len >= max_frame_count) {
            self.releases.releaseHeader(body_header);
            return error.OutOfMemory;
        }
        try self.openBoundary(
            .{ .module = .{
                .image = candidate.move(),
                .root_code = body_header,
            } },
            @intCast(self.stack.items.len),
            word,
            body_header,
        );
        self.current = .{
            .code = body_header,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = site,
            .activation = .none,
        };
    }
    /// The context an explicit lookup resolves under: the current view, which
    /// the context owns, and how this fiber finds modules.
    fn resolutionContext(self: *Fiber) binder.Context {
        return .{
            .environment = self.environment,
            .view = self.inherited.registry.view(),
            .project = self.inherited.module_snapshot,
        };
    }

    /// The cell of `word`: the one its link identifies, or, for a word the
    /// implementation built for itself, the cell of its spelling written in
    /// core by no source, which is the place such a word resolves in. So
    /// every word that runs has a cell, and one rule answers for it.
    pub fn cellOf(self: *Fiber, word: value.Symbol) error{OutOfMemory}!env.CellId {
        return switch (env.wordTarget(word.slot)) {
            .cell => |id| id,
            // A lowered locals operation handed over as a value is a name
            // like any other.
            .unlinked, .local => @fromBackingInt(try self.environment.linker(self.environment.coreScopeId(), .ordinary).link(word.name)),
        };
    }

    /// What `word` denotes now, for a reader that looks before the word
    /// runs: what its cell answers, or, when the cell is empty, what one
    /// resolution against the current view finds, which the registry is
    /// asked to keep in the cell. The turn is what keeps the definition: it
    /// is a reader of the directory that owns it.
    pub inline fn denoted(self: *Fiber, word: value.Symbol) error{OutOfMemory}!?*env.Definition {
        if (env.isCell(word.slot)) if (self.cells.of(word.slot).definition.load(.seq_cst)) |definition| return definition;
        return self.resolveDenoted(word);
    }

    noinline fn resolveDenoted(self: *Fiber, word: value.Symbol) error{OutOfMemory}!?*env.Definition {
        var lookup = try ExplicitLookup.init(self, word);
        defer lookup.deinit();
        return switch (poll_api.drive(binder.Outcome, &lookup, .{self})) {
            .resolved => |definition| definition,
            .missed => null,
        };
    }

    /// The trace word of `word` when it denotes, now, a builtin of core or
    /// of the standard library, and `primitive` when one is given: what
    /// idiom recognition trusts. Null for anything else.
    pub fn trustedBuiltin(self: *Fiber, word: value.Symbol, primitive: ?env.PrimitiveImpl) error{OutOfMemory}!?intern.TraceWord {
        if (binder.executableWord(.{ .symbol = word }) == null) return null;
        const definition = try self.denoted(word) orelse return null;
        if (definition.root == .session or (definition.root == .module and !ofStandardLibrary(definition))) return null;
        const code = definition.code();
        if (code != .builtin or (primitive != null and code.builtin != primitive.?)) return null;
        return definitionTraceWord(definition, word.name);
    }

    /// What a stack summary reads of one word. A summary reads its words
    /// before the quotation runs, which may be while no evaluation is
    /// current, and wherever it runs.
    pub fn summaryTarget(self: *Fiber, word: value.Symbol) error{OutOfMemory}!SummaryTarget {
        if (binder.executableWord(.{ .symbol = word }) == null) return .none;
        const definition = try self.denoted(word) orelse return .none;
        // Asked after the cell is read: a summary made of words read on both
        // sides of a store would be kept under a counter value that outlasts
        // the store. A walk that began earlier fails its own closing check.
        if (self.inherited.registry.publishing()) return .none;
        // A checked call's failure reports the depth it found: only the call
        // itself can say that.
        const home = modules.definitionModule(definition);
        if (crossesChecked(self.environment, home, word)) return .none;
        return switch (definition.code()) {
            .native => .none,
            .builtin => |primitive| .{ .builtin = .{ .primitive = primitive, .effect = definition.effect } },
            .source => |executable| .{ .source = .{
                .definition = definition,
                .code = executable.code(),
                .home = home,
                .trace_word = definitionTraceWord(definition, word.name),
                .attribution = definition.attribution,
            } },
        };
    }

    /// The publication a summary's resolutions were all read under, when it
    /// is still the current one at the end of the walk.
    pub fn currentPublication(self: *const Fiber) u64 {
        return self.inherited.registry.currentPublication();
    }

    /// The plan of the finite iteration applying the running code, when that
    /// code is the combinator's own quotation.
    fn applicationPlan(self: *Fiber) ?*ResolutionPlan {
        const current = &self.current.?;
        const index = current.application_tail.get() orelse return null;
        const plan = switch (self.frames.items[@backingInt(index)]) {
            .application => |application| application.driver.plan orelse return null,
            else => return null,
        };
        return if (plan.code == current.code) plan else null;
    }

    /// The running finite iteration's entry for the position executing now,
    /// made on first use, or null when no plan applies.
    pub fn planEntry(self: *Fiber) error{OutOfMemory}!?*PlanEntry {
        const plan = self.applicationPlan() orelse return null;
        return try plan.entry(self.allocator, self.active_index);
    }

    /// Runs a lowered locals operation: bind the top `operand` values, read
    /// local `operand`, or drop `operand` locals. The lowerer computed the
    /// operand, so the checks only guard a word built or moved by hand.
    fn localOperation(self: *Fiber, name: u32, operand: u32) MachineError!void {
        const locals = self.environment.localsWords();
        self.active_word = .plain(name);
        if (name == locals.get) {
            if (operand >= self.locals.items.len) return self.fail(.domain, "_gl index is out of bounds");
            return self.readLocal(operand);
        }
        if (name == locals.load) {
            if (operand > self.stack.items.len - self.floor.guard and !try floor_api.cover(self, operand))
                return self.failBinding(operand);
            return self.bindLocals(operand);
        }
        if (name == locals.drop) {
            if (operand > self.locals.items.len) return self.fail(.domain, "_dl count exceeds the live locals");
            return self.unbindLocals(operand);
        }
        if (name == locals.guard) return self.guardFlattened(operand);
        if (name == locals.recheck) return self.recheckFlattened();
        return self.fail(.domain, "a locals operand on a word that is not a locals operation");
    }

    /// How many evaluations the fiber has, running and suspended: the
    /// height a flattened list's record is entered and retired by.
    pub fn height(self: *const Fiber) usize {
        return self.frames.items.len + @intFromBool(self.current != null);
    }

    /// The guard at the start of a flattened phrase. It holds when the phrase
    /// may run as flattened: the list was flattened in the current
    /// publication, the values the expansion takes for itself are in reach,
    /// and a tail application is not owed the evaluation's tail authority.
    /// Otherwise the phrase runs as it was written: its operands are pushed,
    /// its expansion is passed over, and its word is dispatched from here.
    fn guardFlattened(self: *Fiber, row: u32) MachineError!void {
        const current = &self.current.?;
        const record = self.flattened.record(current.code) orelse
            return self.fail(.domain, "a flattened phrase's guard outside a flattened list");
        if (row >= record.guards.len) return self.fail(.domain, "a flattened phrase's guard has no entry");
        const guard = record.guards[row];
        const owed = guard.tail and (current.effect_tail != .none or current.application_tail != .none);
        if (!owed and record.publication == self.currentPublication() and floor_api.reachable(self, guard.needed)) return;
        const after = switch (current.position) {
            .source => |index| index,
            .invocation, .replay, .redispatch => return self.fail(.domain, "a flattened list was resumed at a guard"),
        };
        // An operand is a literal, or a read of a local that holds one.
        for (record.operands[guard.operands_start..][0..guard.operands_len]) |operand| {
            const read = if (operand == .symbol) env.localOperand(operand.symbol.slot) else null;
            if (read) |index| try self.localOperation(operand.symbol.name, index) else try self.pushBorrowed(operand);
        }
        self.current.?.position = .{ .source = after + guard.skip };
        return self.executeWord(guard.word);
    }

    /// The `nth` word an evaluation is traced under, innermost first, or
    /// null past the last. An evaluation as written has one, its activation.
    /// A flattened list stands for the evaluations of every list written in
    /// it: of each word inlined around the form it is at, then its own. A
    /// word is in the trace when an evaluation of one of its lists would
    /// still exist: at a failing form the innermost always does, and
    /// otherwise only one with forms left would, the rest having handed
    /// their activation on.
    fn tracedUnder(self: *const Fiber, evaluation: *const Eval, form: u32, suspended: bool, nth: usize) ?TraceEntry {
        const record = (if (evaluation.flattened) self.flattened.recordOf(evaluation.code) else null) orelse
            return if (nth == 0) Unwinding.traceEntry(evaluation.activation) else null;
        if (form >= record.origins.len) return if (nth == 0) Unwinding.traceEntry(evaluation.activation) else null;
        const origin = record.origins[form];
        var visible = !suspended or origin.continues;
        var word = origin.word;
        var seen: usize = 0;
        while (word != flatten.no_word) {
            const inlined = record.chain[word];
            if (visible) {
                if (seen == nth) return .{
                    .word = inlined.word,
                    .site = .{ .code = inlined.code, .index = inlined.index },
                    .attribution = inlined.attribution,
                };
                seen += 1;
            }
            visible = inlined.call_continues;
            word = inlined.outer;
        }
        return if (visible and seen == nth) Unwinding.traceEntry(evaluation.activation) else null;
    }

    /// The check after each quotation of a flattened cleave or spread, whose
    /// expansion rests on the quotations' summaries. A publication since the
    /// list was flattened may have changed what the quotation just run did,
    /// so the phrase fails as one running by its summaries does.
    fn recheckFlattened(self: *Fiber) MachineError!void {
        const record = self.flattened.record(self.current.?.code) orelse
            return self.fail(.domain, "a flattened phrase's check outside a flattened list");
        if (record.publication == self.currentPublication()) return;
        const origin = record.origins[self.active_index];
        const word = list.atUnchecked(.{ .list = origin.code }, origin.index);
        if (word == .symbol) self.active_word = .plain(word.symbol.name);
        return stack_summary.failDefinitionsChanged(self);
    }

    /// Where a form the machine is running was written. A flattened list's
    /// forms came from the list it was made from and the quotations in it.
    fn written(self: *const Fiber, code: *Header, index: u32) ErrorSite {
        const record = self.flattened.recordOf(code) orelse return .{ .code = code, .index = index };
        if (index >= record.origins.len) return .{ .code = code, .index = index };
        const origin = record.origins[index];
        return .{ .code = origin.code, .index = origin.index };
    }

    /// Runs an occurrence: by what its cell answers, or, when the cell is
    /// empty, by a lookup against the current publication view, in bounded
    /// steps, that may load a module. `dispatch` pushes a quoted occurrence
    /// instead, and `execute` strips the quote before calling here.
    pub fn executeWord(self: *Fiber, word: value.Symbol) MachineError!void {
        std.debug.assert(!env.isQuoted(word.slot));
        if (env.localOperand(word.slot)) |operand| return self.localOperation(word.name, operand);
        self.active_word = .plain(word.name);
        if (env.isCell(word.slot)) if (self.cells.of(word.slot).definition.load(.seq_cst)) |definition|
            return invokeDefinition(self, definition, word);
        return self.executeUnfilled(word);
    }

    /// Runs a word whose cell is empty, or that has no link: by its cell if
    /// that is filled by now, and otherwise by a lookup.
    noinline fn executeUnfilled(self: *Fiber, word: value.Symbol) MachineError!void {
        const linked: value.Symbol = .{ .name = word.name, .slot = @backingInt(try self.cellOf(word)) };
        if (self.cells.of(linked.slot).definition.load(.seq_cst)) |definition|
            return invokeDefinition(self, definition, linked);
        const site: ?ErrorSite = if (self.current) |current| .{ .code = current.code, .index = self.active_index } else null;
        try self.startDriver(LookupDispatchDriver{ .word = linked, .site = site, .lookup = .init(try .init(self, linked)) });
    }

    /// The failure for a word whose imports never reach a definition.
    pub fn failAliasCycle(self: *Fiber, word: value.Symbol) MachineError {
        self.active_word = .plain(word.name);
        return self.failFmt(.domain, "the aliases from `{s}` never reach a definition", .{intern.get(word.name)});
    }

    pub fn raiseOwned(self: *Fiber, raised: Value) MachineError {
        self.installPendingFailure(EclErr.init(.user, "raised error"));
        if (self.active_word != no_word) self.pendingFailure().word = self.active_word;
        self.pendingFailure().raised = raised;
        return error.Ecl;
    }
    /// Opens one `@attempt` boundary. Consuming: the body is owned by the
    /// boundary on success and released here on every failure.
    pub fn attemptOwned(self: *Fiber, body: *Header) error{OutOfMemory}!void {
        const invoker = self.current.?;
        const word = self.active_word;
        const dropped = self.suspendCurrent() catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        dropped.release(self.releases);
        if (self.frames.items.len >= max_frame_count) {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        }
        // The body runs in its invoker's scope with its invoker's right to
        // define. A failure restores the stack, not the environment: like IO,
        // a definition the body made survives it.
        const site = invoker.site;
        try self.openBoundary(
            .attempt,
            @intCast(self.stack.items.len),
            word,
            body,
        );
        self.current = .{
            .code = body,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = site,
            .activation = .none,
        };
    }
    /// Opens one `@load` boundary over a read source. Consuming: the body is
    /// owned by the boundary on success and released here on every failure.
    /// The body keeps its invoker's authority to define, so a file loaded at
    /// the root defines into the session.
    fn openLoad(
        self: *Fiber,
        body: *Header,
        word: intern.TraceWord,
    ) error{OutOfMemory}!void {
        const invoker = self.current.?;
        const dropped = self.suspendCurrent() catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        dropped.release(self.releases);
        if (self.frames.items.len >= max_frame_count) {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        }
        const site = invoker.site;
        try self.openBoundary(.load, @intCast(self.stack.items.len), word, body);
        self.current = .{
            .code = body,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = site,
            .activation = .none,
        };
    }
    /// Opens one stack boundary: the frame recording where to return to, and
    /// the base its operands start from. The three boundary modes — a module
    /// body, a state application, and `@attempt` — differ in what they record
    /// and what runs inside them, never in how the boundary is opened. The
    /// caller keeps the frame-count check, because what it has to release on
    /// refusal differs; past that point failure releases the body here.
    fn openBoundary(
        self: *Fiber,
        mode: BoundaryMode,
        stack_base: u32,
        word: intern.TraceWord,
        quotation: *Header,
    ) error{OutOfMemory}!void {
        const index: FrameIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        var continuation = OwnedFrame.init(.{ .boundary = .{
            .mode = mode,
            .stack_base = stack_base,
            .locals_base = @intCast(self.locals.items.len),
            .beneath = self.floor.beneath(),
            .previous_boundary = self.boundary_index,
            .word = word,
        } });
        defer continuation.deinit(self.releases, self.allocator);
        self.appendFrame(&continuation) catch {
            self.releases.releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.boundary_index = index;
        self.floor.set(stack_base, null);
    }
    inline fn noteFrameDepth(self: *Fiber) void {
        if (comptime root_execution_metrics_enabled) {
            const metrics = &self.root_execution_metrics;
            metrics.max_frames = @max(metrics.max_frames, self.frames.items.len);
        }
    }
    fn appendFrame(self: *Fiber, owned: *OwnedFrame) error{OutOfMemory}!void {
        try self.frames.append(self.allocator, owned.frame.?);
        _ = owned.take();
        self.noteFrameDepth();
    }
    fn enterRegistration(self: *Fiber, body: *Header, after: load.AfterLoad) error{OutOfMemory}!void {
        var continuation = OwnedFrame.init(.{ .qualified_after_load = after });
        defer continuation.deinit(self.releases, self.allocator);
        const site = self.current.?.site;
        const dropped = (if (after.request.preservesCaller())
            self.suspendCurrentForQualifiedLoad()
        else
            self.suspendCurrent()) catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        dropped.release(self.releases);
        self.appendFrame(&continuation) catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        self.current = .{
            .code = body,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = site,
            .activation = .none,
        };
    }
    fn dispatchAfterLoad(self: *Fiber, word: value.Symbol, site: ?ErrorSite) error{OutOfMemory}!void {
        self.active_word = .plain(word.name);
        try self.startDriver(LookupDispatchDriver{ .word = word, .site = site, .lookup = .init(try .init(self, word)) });
        if (site) |at| self.setWorkDriverSite(at.code, at.index);
    }
    fn replayOperand(self: *Fiber, requested: value.Symbol) error{OutOfMemory}!void {
        try self.pushBorrowed(.{ .symbol = requested });
        self.current.?.rewind(self.active_index);
    }
    /// Closes the construction boundary on top once its body has run, and
    /// returns the image it held. A body that left values on its stack
    /// closes it and fails instead.
    fn closeModuleBoundary(self: *Fiber) MachineError!modules.OwnedImage {
        const boundary = self.popFrame(.boundary);
        self.boundary_index = boundary.previous_boundary;
        self.floor.restore(boundary.beneath);
        self.active_word = boundary.word;
        const observed = self.stack.items.len - boundary.stack_base;
        if (observed != 0) {
            boundary.deinit();
            return self.failFmt(
                .domain,
                "@defm body left {d} value{s} on its stack; a module body defines words and keeps no state",
                .{ observed, if (observed == 1) "" else "s" },
            );
        }
        releaseCurrent(self);
        return boundary.mode.module.image;
    }
    /// Establishes completion before invoking foreign implementation code.
    /// The saved caller owns the source lifetime for the check's diagnostic
    /// site; the invocation activation supplies execution context but cannot
    /// dispatch the caller's next form. Drivers, parks, and nested quotations
    /// therefore finish before the ordinary frame resumer checks outputs.
    /// Allocation failure leaves the caller unchanged.
    fn beginInvocation(self: *Fiber, effect: env.Effect, word: intern.TraceWord) MachineError!void {
        if (self.current.?.position == .redispatch) {
            const index = self.current.?.position.redispatch;
            self.current.?.position = .{ .invocation = index };
            return;
        }
        var check = try prepareEffectCheck(self, effect, word);
        try self.frames.ensureUnusedCapacity(self.allocator, 2);
        var caller = self.current.?;
        check.provenance = .{ .invocation = .{
            .code = caller.code,
            .index = self.active_index,
        } };
        var invocation = caller.untracedCopy();
        invocation.position = .{ .invocation = caller.nextIndex() };
        if (!self.isSourceTailPosition(&caller)) {
            invocation.effect_tail = .none;
            invocation.application_tail = .none;
        }
        // Selection follows the invoked tail quotation. Resuming the caller
        // later must not overwrite that selection with its original body.
        caller.application_selection = .none;
        self.frames.appendAssumeCapacity(.{ .eval = caller });
        self.frames.appendAssumeCapacity(.{ .effect_check = check });
        self.noteFrameDepth();
        self.current = invocation;
    }
    /// Suspends a non-tail continuation. An exhausted anonymous quotation
    /// inherits its named trace owner so inline control does not erase the
    /// activation that selected it. The caller owns the returned activation.
    fn suspendCurrent(self: *Fiber) error{OutOfMemory}!Activation {
        const current = &self.current.?;
        if (current.hasInstructions()) {
            const lent = self.lentPastFlattened(current);
            try self.pushCurrent();
            return lent;
        }
        const inherited = self.handedPastFlattened(current) orelse current.activation.handedOn();
        self.retireCompletedCode(current);
        self.current = null;
        return inherited;
    }
    /// What an exhausted evaluation of a flattened list hands on when its
    /// last form ran inside an inlined word, or null when it hands on its
    /// own activation as any evaluation does. The word's body would have
    /// been the evaluation exhausted here, and the activation handed on the
    /// word's. The evaluation's own would have gone when the word was
    /// entered from a list with nothing left: released, or, for a helper
    /// leaving its body, given to the word with the helper's call site.
    /// The activation returned owns its call site's code, since the list
    /// that kept it is being retired.
    fn handedPastFlattened(self: *Fiber, current: *Eval) ?Activation {
        if (!current.flattened) return null;
        const record = self.flattened.record(current.code) orelse return null;
        if (self.active_index >= record.origins.len) return null;
        const word = record.origins[self.active_index].word;
        if (word == flatten.no_word) return null;
        const inlined = record.chain[word];
        const own = current.activation;
        current.activation = .none;
        if (own.attribution == .caller and own.site() != null) {
            var moved = own.handedOn();
            moved.word = inlined.word;
            moved.attribution = inlined.attribution;
            return moved;
        }
        own.release(self.releases);
        heap.incRef(inlined.code);
        return .{
            .word = inlined.word,
            .origin = @intFromPtr(inlined.code),
            .index = inlined.index,
            .hold = .owned,
            .attribution = inlined.attribution,
        };
    }
    /// What a suspended evaluation hands on although it has forms left. A
    /// flattened list keeps running after a form that ended every list it
    /// was written in: only what the rewrite inserted follows. The
    /// evaluations of those lists would have been exhausted there and handed
    /// their activation on, so this one lends it, and keeps it for the
    /// quotations still to come.
    fn lentPastFlattened(self: *Fiber, current: *const Eval) Activation {
        if (!current.flattened) return .none;
        const record = self.flattened.record(current.code) orelse return .none;
        if (self.active_index >= record.origins.len) return .none;
        const origin = record.origins[self.active_index];
        if (origin.continues) return .none;
        // The innermost word whose lists end here: an inlined one, whose
        // activation exists only in the record, or the evaluation's own.
        if (origin.word == flatten.no_word) return current.activation.borrowed();
        const inlined = record.chain[origin.word];
        return .{
            .word = inlined.word,
            .origin = @intFromPtr(inlined.code),
            .index = inlined.index,
            .hold = .borrowed,
            .attribution = inlined.attribution,
        };
    }
    /// `suspendCurrent` for a word about to run, which records where it was
    /// called. A caller that stays suspended lends its code; one that has no
    /// forms left gives its reference to the call site instead of releasing
    /// it, so a tail call pays no extra reference count. The caller owns both
    /// parts of the result.
    fn suspendCaller(self: *Fiber) error{OutOfMemory}!Suspension {
        const current = &self.current.?;
        const code = current.code;
        if (current.hasInstructions()) {
            const lent = self.lentPastFlattened(current);
            try self.pushCurrent();
            return .{ .inherited = lent, .caller = .{ .code = code, .program = .borrowed } };
        }
        // Read in place: retiring an exhausted caller releases nothing here,
        // so copying the evaluation out would be the whole cost of the call.
        const inherited = self.handedPastFlattened(current) orelse current.activation;
        if (current.application_selection != .none) {
            // The selection takes the evaluation's reference; the call site
            // needs its own, because a later selection can replace this one.
            heap.incRef(code);
            self.retireCompletedCode(current);
            self.current = null;
            return .{ .inherited = inherited, .caller = .{ .code = code, .program = .owned } };
        }
        const program = current.program;
        self.current = null;
        return .{ .inherited = inherited, .caller = .{ .code = code, .program = program } };
    }
    fn pushCurrent(self: *Fiber) error{OutOfMemory}!void {
        // Built in place: an appended frame was a stack temporary copied into
        // the array.
        const current = &self.current.?;
        const frame = try self.frames.addOne(self.allocator);
        frame.* = .{ .eval = current.* };
        self.noteFrameDepth();
        self.current = null;
    }
    /// A source-backed module load nests inside the requesting evaluation.
    /// Preserve even an exhausted caller: after publication the qualified
    /// request still needs its resolution scope, home, and continuation, and
    /// only the eventual dispatched word may consume the tail position.
    fn suspendCurrentForQualifiedLoad(self: *Fiber) error{OutOfMemory}!Activation {
        const current = self.current.?;
        try self.frames.append(self.allocator, .{ .eval = current });
        self.noteFrameDepth();
        self.current = null;
        return .none;
    }
};

/// Why a slice returned. `exhausted` means the turn's quantum ran out with
/// work still runnable: the fiber can continue at once. `yielded` means it
/// stopped for something outside itself (a wait, settlement, unfinished
/// cleanup, or backpressure), so its executor should let other work run.
const RunStatus = enum { completed, exhausted, yielded, parked };

/// A `@give` moves at most this many ports. Validation is resumable, but
/// preparation and commit run inside `spawn` and cannot yield, so the count is
/// capped rather than unbounded: that is what keeps the phases which must be
/// atomic inside one scheduler step, what lets the transfer cursor hold its
/// ports in fixed storage, and what lets the commit put them on the child's
/// stack in constant work. Realistic calls move one port.
pub const max_given_ports: usize = 16;

/// Starts a fiber on code that resolves one form at a time: top-level source,
/// or a task's body.
pub fn initialize(fiber: *Fiber, code: *Header) void {
    const program: Program = .owned;
    std.debug.assert(fiber.frames.items.len == 0);
    std.debug.assert(fiber.terminal == .evaluating);
    std.debug.assert(fiber.current == null);
    // Nothing is running, so every flattened list set aside can go.
    fiber.flattened.sweep(fiber.allocator, fiber.releases, 0);
    heap.incRef(code);
    fiber.current = .{
        .code = code,
        .program = program,
        .position = .{ .source = 0 },
        .site = rootSite(fiber),
        .activation = .none,
    };
}

/// Installs one borrowed Session source as the root fiber's first scheduled
/// work. The source bytes need only remain live until `runInitializedRoot`
/// returns; driver teardown is completed before that blocking call exits.
pub fn initializeSource(
    fiber: *Fiber,
    source_name: []const u8,
    source: []const u8,
) error{OutOfMemory}!void {
    var empty = heap.OwnedValue.init(
        fiber.releases,
        try list.fromValuesGeneric(fiber.allocator, &.{}),
    );
    defer empty.deinit();
    initialize(fiber, empty.borrow().list);
    try load.sessionSource(.of(fiber), source_name, source);
}

pub fn runSlice(fiber: *Fiber) MachineError!RunStatus {
    // Each turn begins with one full kernel quantum. The charge that exhausted
    // the previous one already polled cancellation, and a driver's step polls
    // before it draws.
    fiber.kernel_budget = turn_core.beginTurn(kernel_poll_quantum);
    // The turn is a reader of the registry's directories: a definition this
    // turn reads from one stays valid until the turn ends, replaced or not.
    const turn = fiber.inherited.registry.enterTurn();
    defer turn.deinit();
    const status = loop(fiber) catch |err| switch (err) {
        error.Ecl => return error.Ecl,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (comptime root_execution_metrics_enabled) {
        if (status != .completed) fiber.root_execution_metrics.scheduler_handoffs += 1;
    }
    return status;
}

/// Makes the next fiber entry observe cancellation before executing a
/// ready fiber's first form.
pub fn armCancellationBeforeDispatch(fiber: *Fiber) void {
    fiber.fuel = 0;
}

pub fn run(fiber: *Fiber, code: *Header) MachineError!void {
    initialize(fiber, code);
    while (true) {
        const status = try runSlice(fiber);
        _ = fiber.releases.advance(kernel_poll_quantum);
        switch (status) {
            .completed => return,
            .exhausted, .yielded => {},
            .parked => unreachable,
        }
    }
}

fn loop(self: *Fiber) MachineError!RunStatus {
    var first_step = true;
    while (true) {
        // Completion and output delivery may spend the last unit too. Never
        // enter another driver, continuation, or Eval with an empty allowance.
        if (!turn_core.mayDispatch(self.kernel_budget)) return .exhausted;
        // Admission reserves progress, not a whole instruction quantum of
        // allocation after pressure rises. Complete at least one transition
        // before yielding so a granted waiter cannot repeatedly lose its turn.
        // Cancellation must continue through failure and terminal cleanup.
        if (!first_step and !self.cancelled.load(.acquire) and
            self.releases.evaluationBackpressured()) return .yielded;
        first_step = false;
        switch (self.native) {
            // Nothing native is pending: no cleanup, resumption, park
            // request, or work driver precedes the next evaluation step.
            .idle => {},
            else => {
                if (self.native == .park_resume or self.native == .work_park_resume) {
                    resumePark(self) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Ecl => {
                            try startFailure(self);
                            continue;
                        },
                    };
                }
                if (self.hasParkRequest()) return .parked;
                if (self.workDriver()) |driver_ptr| {
                    const driver = driver_ptr.*;
                    if (comptime root_execution_metrics_enabled)
                        self.root_execution_metrics.driver_resumes += 1;
                    const progress = driver.advance(self) catch |err| {
                        // `setFailureSite`'s rule, spelled inline: calling it
                        // here grew the run loop's frame (fannkuch +0.08%).
                        if (err == error.Ecl and self.pendingFailure().site == null) {
                            if (driver.site) |site| self.pendingFailure().site = .{ .token = site };
                        }
                        clearWorkDriver(self);
                        switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.Ecl => {
                                try startFailure(self);
                                continue;
                            },
                        }
                    };
                    switch (progress) {
                        inline .stepped, .yielded => |_, tag| {
                            const outcome: turn_core.Outcome = switch (tag) {
                                .stepped => .stepped,
                                .yielded => .{ .yielded = progress.yielded },
                                else => comptime unreachable,
                            };
                            const decision = turn_core.afterDriver(
                                outcome,
                                &self.kernel_budget,
                                self.hasParkRequest(),
                            ) catch @panic("driver outcome contradicts its park request");
                            if (decision.poll_cancellation) self.pollKernel() catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                error.Ecl => {
                                    try startFailure(self);
                                    continue;
                                },
                            };
                            switch (decision.action) {
                                .resume_driver => continue,
                                .end_turn => return .exhausted,
                                .surrender => return .yielded,
                                .park => return .parked,
                            }
                        },
                        .completed => {
                            clearWorkDriver(self);
                            continue;
                        },
                        .output => |item| {
                            clearWorkDriver(self);
                            try self.pushOwned(item);
                            continue;
                        },
                        .reserved_output => |reserved| {
                            clearWorkDriver(self);
                            var destination = reserved.reservation;
                            destination.pushOwned(reserved.value);
                            continue;
                        },
                        // The driver destroyed and detached itself before invoking a
                        // continuation which may have installed its successor.
                        .detached => continue,
                        .failed => {
                            clearWorkDriver(self);
                            return error.Ecl;
                        },
                    }
                }
            },
        }
        if (self.hasRequestedExit()) {
            return .completed;
        }
        if (self.current == null) {
            const resumed = resumeFrames(self) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Ecl => {
                    try startFailure(self);
                    continue;
                },
            };
            if (!resumed) return .completed;
        }
        // Exhaustion is checked before another continuation, an owned driver,
        // or an exhausted Eval runs. A body that dispatched nothing spent its
        // fuel in its continuation.
        if (self.fuel == 0) {
            self.polls += 1;
            self.fuel = fuel_quantum;
            if (self.cancelled.load(.acquire)) {
                self.active_word = no_word;
                self.installPendingFailure(EclErr.init(.cancelled, "unit cancelled"));
                try startFailure(self);
                continue;
            }
            return .exhausted;
        }
        // A frame continuation may replace its native-stack tail with an
        // owned driver. Let that driver run before dispatching the parent
        // Eval which resumeFrames may also have restored.
        if (self.hasWorkDriver()) continue;
        const current = &self.current.?;
        const index = current.takeInstruction() orelse {
            self.retireCompletedEval(current);
            self.current = null;
            continue;
        };
        poll(self) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                try startFailure(self);
                continue;
            },
        };
        self.active_index = index;
        if (comptime root_execution_metrics_enabled)
            self.root_execution_metrics.logical_transitions += 1;
        // A word whose cell is filled runs what the cell answers; a quoted
        // or lowered occurrence is a form, as is everything else, and a word
        // with an empty cell or none resolves when dispatched. The turn
        // keeps the definition read here alive until what runs holds it.
        const dispatched = resolved: {
            const form = formAt(current.code, index);
            if (form == .symbol and env.isCell(form.symbol.slot)) {
                const cell = self.cells.of(form.symbol.slot);
                if (cell.primitive.load(.seq_cst)) |primitive|
                    break :resolved invokeBuiltin(self, .plain(form.symbol.name), primitive);
                if (cell.definition.load(.seq_cst)) |definition|
                    break :resolved invokeDefinition(self, definition, form.symbol);
            }
            break :resolved dispatch(self, form);
        };
        dispatched catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => {
                if (self.current) |failed| self.setFailureSite(failed.code, self.active_index);
                try startFailure(self);
                continue;
            },
        };
    }
}

fn clearWorkDriver(fiber: *Fiber) void {
    const driver = fiber.takeWorkDriver() orelse return;
    const inline_storage = fiber.ownsInlineDriver(driver.context);
    driver.deinit(fiber.releases, fiber.allocator);
    // A driver that finishes by handing back a result is torn down here rather
    // than retiring itself, so this is the other place the slot comes free.
    // Without it an inline driver that completed this way would hold the slot
    // for the rest of the fiber's life and every later driver would allocate.
    if (inline_storage) fiber.releaseInlineDriver();
}

fn resumePark(self: *Fiber) MachineError!void {
    const delivery = self.takeParkResume().?;
    switch (delivery) {
        .task_wait => |wait| return resumeTaskWait(self, wait),
        .sleep => |sleep| {
            // Successful timer waits resume the driver that requested them,
            // just as successful external readiness waits do.
            if (sleep == .elapsed) return;
            // A work-driver park owns backend state across the wait. Move its
            // cleanup through the ordinary driver destructor before raising;
            // the failure unwinder requires that no native continuation still
            // owns the operands or external registration it is abandoning.
            clearWorkDriver(self);
            return switch (sleep) {
                .elapsed => unreachable,
                .cancelled => self.fail(.cancelled, "unit cancelled while sleeping"),
                .io => self.fail(.io, "could not start the scheduler timer service"),
                .overflow => self.fail(.overflow, "sleep deadline lies beyond the clock's range"),
                .out_of_memory => error.OutOfMemory,
            };
        },
        .external => |ready| switch (ready) {
            .wake => {},
            .timeout => {
                clearWorkDriver(self);
                return self.fail(.timeout, "host operation deadline expired");
            },
            .cancelled => {
                clearWorkDriver(self);
                return self.fail(.cancelled, "unit cancelled while awaiting host readiness");
            },
            .io => {
                clearWorkDriver(self);
                return self.fail(.io, "could not start a scheduler wait service");
            },
            .out_of_memory => {
                clearWorkDriver(self);
                return error.OutOfMemory;
            },
        },
        .mailbox => |ready| switch (ready) {
            .ready => {},
            .cancelled => {
                clearWorkDriver(self);
                return self.fail(.cancelled, "unit cancelled while awaiting a message");
            },
            .io => {
                clearWorkDriver(self);
                return self.fail(.io, "could not start a scheduler wait service");
            },
            .out_of_memory => {
                clearWorkDriver(self);
                return error.OutOfMemory;
            },
        },
        .scope_closed => |status| self.requestExit(status),
    }
}

fn resumeTaskWait(self: *Fiber, wait: TaskWaitResume) MachineError!void {
    switch (wait) {
        .outcome => |outcome| try self.pushOwned(outcome),
        .indexed => |indexed| {
            var window = self.reserveStack(2) catch {
                self.releases.releaseValue(indexed.outcome);
                return error.OutOfMemory;
            };
            window.pushOwned(.{ .int = indexed.index });
            window.pushOwned(indexed.outcome);
        },
        .timeout => {
            clearWorkDriver(self);
            var timeout = EclErr.init(.timeout, "task wait timed out");
            defer timeout.retire(self.releases);
            const failure = try errorValue(
                self.allocator,
                self.releases,
                &timeout,
                .{},
                null,
            );
            try self.pushOwned(try outcomeDict(
                self.allocator,
                self.releases,
                "err",
                failure,
            ));
        },
        .cancelled => {
            clearWorkDriver(self);
            return self.fail(.cancelled, "unit cancelled while awaiting a task");
        },
        .io => {
            clearWorkDriver(self);
            return self.fail(.io, "could not start a scheduler wait service");
        },
        .overflow => {
            clearWorkDriver(self);
            return self.fail(.overflow, "task.await-for deadline lies beyond the clock's range");
        },
        .out_of_memory => {
            clearWorkDriver(self);
            return error.OutOfMemory;
        },
    }
}

/// The form at `index`. Code is nearly always a spine of forms; any other
/// list runs too.
fn formAt(code: *Header, index: u32) Value {
    return if (code.kind() == .generic_spine)
        heap.valuesConst(code)[index]
    else
        list.atUnchecked(.{ .list = code }, index);
}

fn poll(self: *Fiber) MachineError!void {
    self.fuel -= 1;
}
inline fn dispatch(self: *Fiber, form: Value) MachineError!void {
    const word = switch (form) {
        .symbol => |reference| reference,
        .int, .float, .char, .list, .dict, .task, .port, .address => return self.pushBorrowed(form),
    };
    // A quoted occurrence pushes its symbol, linked as written and unmarked:
    // the value `(x) first` pushes.
    if (env.isQuoted(word.slot))
        return self.pushBorrowed(.{ .symbol = .{ .name = word.name, .slot = env.unquoted(word.slot) } });
    try self.executeWord(word);
}

/// Runs a builtin under `trace_word`, translating its failure payload the one
/// way resolved execution does.
fn invokeBuiltin(self: *Fiber, trace_word: intern.TraceWord, primitive: env.PrimitiveImpl) MachineError!void {
    self.active_word = trace_word;
    primitive(self) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Ecl => {
            const failure_value = self.takePrimitiveFailure() orelse
                EclErr.init(.domain, "builtin primitive returned error.Ecl without a failure payload");
            return self.installPrimitiveFailure(failure_value);
        },
    };
    if (self.takePrimitiveFailure()) |failure_value| {
        return self.installPrimitiveFailure(failure_value);
    }
}
/// Resolves one word that has a cell against the current view, in bounded
/// steps, and invokes what it finds.
const LookupDispatchDriver = struct {
    word: value.Symbol,
    site: ?ErrorSite,
    lookup: heap.Owned(ExplicitLookup),

    /// Started once per explicitly looked-up word, so it uses the inline slot.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;

    /// Resolves and invokes one word without a cancellation point of its own.
    pub const cancellation: DriverCancellation = .own;

    fn advance(fiber: *Fiber, self: *LookupDispatchDriver) MachineError!WorkProgress {
        const work = fiber.workBudget();
        while (work.spend()) switch (self.lookup.borrowMut().advance(fiber)) {
            .pending => {},
            .complete => |outcome| {
                const word = self.word;
                switch (outcome) {
                    .resolved => |definition| {
                        // The turn keeps the definition alive once the view
                        // is released; the invocation retains what it keeps.
                        const site = self.site;
                        fiber.retireDriver(self);
                        // A module load ran other code in between, so the
                        // form being dispatched is the one this lookup began
                        // at, which the entered word records as its call site.
                        if (site) |at| if (fiber.current) |current| if (current.code == at.code) {
                            fiber.active_index = at.index;
                        };
                        const outer = fiber.dispatched;
                        fiber.dispatched = word;
                        defer fiber.dispatched = outer;
                        try invokeDefinition(fiber, definition, word);
                        return .detached;
                    },
                    .missed => |miss| {
                        const site = self.site;
                        fiber.retireDriver(self);
                        fiber.active_word = .plain(word.name);
                        switch (miss) {
                            // A load may make the word resolvable: dispatch
                            // it again once the module is registered.
                            .unregistered_module => |module| try fiber.autoLoadModule(module.name, .{
                                .qualified = word.name,
                                .context = module.searcher,
                                .continuation = .{ .dispatch = .{ .word = word, .site = site } },
                            }),
                            .unresolved => |chain| return fiber.undefinedWordIn(word.name, chain),
                            .alias_cycle => return fiber.failAliasCycle(word),
                        }
                        return .detached;
                    },
                }
            },
        };
        return .stepped;
    }
};

/// One explicit lookup of a word: what its cell answers, or, when the cell
/// is empty, what a resolution against the current view finds, which the
/// registry is then asked to keep in the cell. Dispatch of an empty cell,
/// `execute`, and reflection ask this way. What it answers is borrowed for
/// the turn that answered.
pub const ExplicitLookup = struct {
    cell: env.CellId,
    resolution: ?struct {
        context: binder.Context,
        resolver: binder.Resolver,
    } = null,

    pub fn init(fiber: *Fiber, word: value.Symbol) error{OutOfMemory}!ExplicitLookup {
        return .{ .cell = try fiber.cellOf(word) };
    }

    pub fn deinit(self: *ExplicitLookup) void {
        if (self.resolution) |*resolution| {
            resolution.resolver.deinit();
            resolution.context.deinit();
        }
        self.* = undefined;
    }

    pub fn advance(self: *ExplicitLookup, fiber: *Fiber) binder.Resolver.Progress {
        const resolution = if (self.resolution) |*resolving| resolving else {
            if (fiber.cells.of(@backingInt(self.cell)).definition.load(.seq_cst)) |definition|
                return .{ .complete = .{ .resolved = definition } };
            const context = fiber.resolutionContext();
            self.resolution = .{ .context = context, .resolver = .init(&context, self.cell) };
            return .pending;
        };
        const progress = resolution.resolver.advance(&resolution.context);
        switch (progress) {
            .complete => |outcome| switch (outcome) {
                .resolved => |definition| fiber.inherited.registry.fillCell(&resolution.context.view, self.cell, definition),
                .missed => {},
            },
            .pending => {},
        }
        return progress;
    }
};

/// A definition an explicit lookup selected, held while reflection reads it.
pub const Reflected = struct {
    definition: *env.Definition,
    trace_word: intern.TraceWord,
    releases: *heap.ReleaseDomain,

    /// Holds, across turns, a definition the turn that resolved it kept
    /// alive.
    pub fn hold(fiber: *Fiber, definition: *env.Definition, name: u32) Reflected {
        definition.retain();
        return .{
            .definition = definition,
            .trace_word = definitionTraceWord(definition, name),
            .releases = fiber.releases,
        };
    }

    pub fn deinit(self: *Reflected) void {
        self.definition.release(self.releases);
        self.* = undefined;
    }
};

/// One word as a stack summary reads it.
pub const SummaryTarget = union(enum) {
    /// Nothing a summary can read: unresolved, native, or behind a checked
    /// module boundary.
    none,
    builtin: struct { primitive: env.PrimitiveImpl, effect: ?env.ValidatedEffect },
    source: Source,

    pub const Source = struct {
        definition: *const env.Definition,
        code: *Header,
        /// The word's module, which its body runs as; null for a word that
        /// runs where its caller does.
        home: ?modules.ModuleRoot,
        /// What an activation of the word is traced under, and whose
        /// failure a failure in it is.
        trace_word: intern.TraceWord,
        attribution: env.Attribution,
    };
};

/// Whether a definition belongs to a standard-library module.
inline fn ofStandardLibrary(definition: *const env.Definition) bool {
    return switch (definition.root) {
        .core, .session => false,
        .module => |module| module.home.provenance == .standard_library,
    };
}

/// Whether a call by `word` of a definition whose module is `home` crosses
/// into that module under a check of the definition's declared effect: when
/// the word was written anywhere but that module, wherever it runs. A
/// standard-library word's effects are reflective metadata, and its arity
/// failures are those of the code it runs.
inline fn crossesChecked(environment: *const env.Env, home: ?modules.ModuleRoot, word: value.Symbol) bool {
    const owner = home orelse return false;
    if (owner.provenance == .standard_library) return false;
    const written: env.ScopeId = switch (env.wordTarget(word.slot)) {
        .cell => |id| environment.place(id).root,
        .unlinked, .local => environment.coreScopeId(),
    };
    return written != owner.scope;
}

/// How a trace identifies a called definition: a module's by its module's
/// name and its own there, during construction as well as after, and
/// anything else by the name the call used.
fn definitionTraceWord(definition: *const env.Definition, name: u32) intern.TraceWord {
    return switch (definition.root) {
        .core, .session => .plain(name),
        .module => |module| .moduleLocal(module.home.name(), module.name),
    };
}

/// Invokes one fixed target. A module word's declared effect is a contract
/// checked where `crossesChecked` says the call crosses into its module.
fn invokeDefinition(self: *Fiber, definition: *env.Definition, word: value.Symbol) MachineError!void {
    const name = word.name;
    // One read of the root says both where the word runs and what it is
    // traced as; `definitionTraceWord` is the same rule for other readers.
    var home: ?modules.ModuleRoot = null;
    var trace_word: intern.TraceWord = .plain(name);
    switch (definition.root) {
        // A builtin of no module has no effect boundary: the common case,
        // run directly.
        .core, .session => switch (definition.code()) {
            .builtin => |primitive| return invokeBuiltin(self, trace_word, primitive),
            else => {},
        },
        .module => |module| {
            home = module.home;
            trace_word = .moduleLocal(module.home.name(), module.name);
        },
    }
    self.active_word = trace_word;
    const checked = crossesChecked(self.environment, home, word);
    const cross_home_effect = if (checked) definition.effect else null;
    switch (definition.code()) {
        .source => |executable| try enterBody(self, executable, .{ .word = trace_word, .attribution = definition.attribution }, home, cross_home_effect),
        .builtin => |primitive| {
            // A declared effect is the called word's contract, so its check
            // reports that word; a failure inside the builtin reports it too.
            if (cross_home_effect) |effect| try self.beginInvocation(effect, trace_word);
            try invokeBuiltin(self, trace_word, primitive);
        },
        .native => |callable| {
            if (checked) {
                const effect = cross_home_effect orelse
                    return self.fail(.domain, "module word has no effect declaration");
                try self.beginInvocation(effect, trace_word);
            }
            try native_call.begin(self, callable);
        },
    }
}

pub const LookupChain = enum {
    /// The activation's own lexical chain over core.
    session,
    /// A module image's own definitions over core.
    module,
    /// Core alone, which is what a primitive or embedded prelude definition
    /// resolves against.
    core,
    /// A registered module's exports, reached through a dotted name.
    qualified,

    fn spelling(self: LookupChain) []const u8 {
        return switch (self) {
            .session => "session",
            .module => "module",
            .core => "core",
            .qualified => "qualified",
        };
    }
};

pub const PlanEntry = resolution_plan.PlanEntry;
pub const ResolutionPlan = resolution_plan.ResolutionPlan;
pub const ModuleLookupCursor = module_lookup.ModuleLookupCursor;
pub const HeldModuleLookup = module_lookup.HeldModuleLookup;

/// Suspends the caller and makes `executable` the running evaluation, under
/// a check of `effect` if it has one. The callee's owner is secured before
/// the caller can retire: in tail position the caller's executable may hold
/// the callee's last reference.
fn enterBody(
    self: *Fiber,
    executable: *const env.Executable,
    word: EnteredWord,
    resolved_home: ?modules.ModuleRoot,
    effect: ?env.Effect,
) MachineError!void {
    // A module word runs as its module; any other word runs at its caller's
    // site.
    const site: ExecutionSite = if (resolved_home) |home| home.scope else self.current.?.site;
    // Beside `effect` rather than an optional of its own, which is copied
    // whole on every call that has none.
    // SAFETY: read only when `effect` is present, which sets it first.
    var effect_check: EffectCheck = undefined;
    if (effect) |declared| effect_check = try prepareEffectCheck(self, declared, word.word);
    // Held before the turn can end: a definition read from a word's cell
    // is kept by the turn alone, and the evaluation outlives the turn.
    executable.owner().retain();
    var entered = false;
    defer if (!entered) executable.owner().release(self.releases);
    // A body under an effect check is found by its own code when the check
    // fails, so it runs as written.
    const flattened = if (effect == null) try flatten.of(self, site, executable.code()) else null;
    if (flattened) |record| record.hold(executable.owner());
    var effect_tail = self.replaceTailEffectCandidate(executable.code());
    const application_tail = self.tailApplicationIndex();
    const call_index = self.active_index;
    const suspension = self.suspendCaller() catch return error.OutOfMemory;
    // The word's own activation replaces any a retired quotation passed on:
    // a tail call does not keep its caller's frame. Leaving a helper's body
    // that way, the word takes the helper's call site in place of its own,
    // which lay inside the body whose failures belong to the helper's caller.
    const activation = if (suspension.inherited.attribution == .caller and suspension.inherited.site() != null) inherited: {
        suspension.caller.release(self.releases);
        var moved = suspension.inherited;
        moved.word = word.word;
        moved.attribution = word.attribution;
        moved.body = true;
        break :inherited moved;
    } else entered: {
        suspension.inherited.release(self.releases);
        break :entered Activation.entered(word.word, word.attribution, suspension.caller, call_index);
    };
    var installed = false;
    defer if (!installed) activation.release(self.releases);
    if (effect != null) {
        const check_index: EffectCheckIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        effect_check.activateSource(executable.code(), check_index, self.effect_check_index);
        var continuation = OwnedFrame.init(.{ .effect_check = effect_check });
        defer continuation.deinit(self.releases, self.allocator);
        try self.appendFrame(&continuation);
        self.effect_check_index = check_index;
        effect_tail = .some(check_index);
    }
    installed = true;
    if (flattened) |record| {
        // The record holds the definition for as long as its list can run,
        // so the evaluation holds only the list: `entered` stays false and
        // the retain above is released.
        heap.incRef(record.code);
        record.enter(self.frames.items.len + 1);
        self.current = .{
            .code = record.code,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = site,
            .activation = activation,
            .effect_tail = effect_tail,
            .application_tail = application_tail,
            .flattened = true,
        };
        return;
    }
    entered = true;
    self.current = .{
        .code = executable.code(),
        .program = .{ .definition = executable },
        .position = .{ .source = 0 },
        .site = site,
        .activation = activation,
        .effect_tail = effect_tail,
        .application_tail = application_tail,
    };
}
fn prepareEffectCheck(
    self: *Fiber,
    declared: env.Effect,
    word: intern.TraceWord,
) MachineError!EffectCheck {
    // Inputs beneath a soft floor count: the word admits them as
    // originals, like any operand check across the floor.
    if (self.available() < declared.inputs) _ = try floor_api.cover(self, declared.inputs);
    const available: u32 = @intCast(self.available());
    if (available < declared.inputs) {
        self.active_word = word;
        const failure = self.failFmt(
            .contract,
            "{s} declared {d} input{s}, but found {d}",
            .{ self.activeWordName(), declared.inputs, if (declared.inputs == 1) "" else "s", available },
        );
        self.pendingFailure().addData(.seeded, .{ .int = available });
        self.pendingFailure().addData(.observed, .{ .int = available });
        return failure;
    }
    return .{
        .expected_depth = @intCast(self.stack.items.len - declared.inputs + declared.outputs),
        .entry_depth = available,
        .inputs = declared.inputs,
        .outputs = declared.outputs,
        .result_depth = declared.result_depth,
        .word = word,
    };
}
fn resumeFrames(self: *Fiber) MachineError!bool {
    while (self.fuel != 0) switch (self.topFrameTag() orelse return false) {
        .eval => {
            const continuation = self.popFrame(.eval);
            self.current = continuation;
            return true;
        },
        .effect_check => {
            const owned = self.popFrame(.effect_check);
            var check = owned;
            defer check.deinit(self.releases);
            try finishEffectCheck(self, &check);
        },
        .application => {
            const continuation = self.popFrame(.application);
            var application_selection = continuation.selection;
            defer application_selection.deinit(self.releases);
            // The popped frame's activation: moved into the next frame when
            // the application continues, and released on every other path.
            const activation = continuation.activation;
            const launch: Launch, const base: StackWindow = switch (continuation.mode) {
                .in_place => |window| .{ .in_place, window },
                .isolated => |isolated| blk: {
                    const window: StackWindow = @fromBackingInt(@intCast(@as(u32, @intCast(self.floor.base))));
                    self.floor.restore(isolated);
                    break :blk .{ .isolated, window };
                },
                .measured => |floor| blk: {
                    // The window is the region above the lowered floor; the
                    // driver's finalize reads it with the floor beneath active.
                    const window: StackWindow = @fromBackingInt(@intCast(@as(u32, @intCast(floor.floor))));
                    self.floor.restore(floor.beneath);
                    break :blk .{ .{ .measured = floor }, window };
                },
            };
            if (comptime root_execution_metrics_enabled)
                self.root_execution_metrics.application_resumes += 1;
            const driver = continuation.driver;
            const next = driver.resume_fn(
                self,
                driver.context,
                base,
                @ptrCast(&application_selection),
            ) catch |err| {
                if (activation.traced()) |word| self.setFailureTraceParent(word, activation.attribution);
                activation.release(self.releases);
                driver.deinit(self.releases, self.allocator);
                return err;
            };
            if (next) |step| switch (step) {
                .apply => |application| {
                    try self.launchApplication(.relaunch, .{
                        .quotation = application.quotation,
                        .driver = driver,
                        .seeded = application.seeded,
                        .provenance = application.provenance,
                    }, application.launch, activation);
                    return true;
                },
                .suspend_inline => |suspension| {
                    const installed = self.workDriver() orelse {
                        activation.release(self.releases);
                        driver.deinit(self.releases, self.allocator);
                        return self.fail(.domain, "application suspension has no installed work");
                    };
                    // A frame resumed over a soft floor suspends in place:
                    // the floor beneath is active again, and the frame determines
                    // the launch of whatever it applies next.
                    if (launch == .isolated or
                        @intFromPtr(suspension) != @intFromPtr(installed.context))
                    {
                        activation.release(self.releases);
                        driver.deinit(self.releases, self.allocator);
                        clearWorkDriver(self);
                        return self.fail(.domain, "application suspension is stale or foreign");
                    }
                    var suspended = OwnedFrame.init(.{ .application = .{
                        .driver = driver,
                        .mode = .{ .in_place = base },
                        .activation = activation,
                        .selection = application_selection,
                        .provenance_nonce = continuation.provenance_nonce,
                    } });
                    application_selection = .{};
                    defer suspended.deinit(self.releases, self.allocator);
                    try self.appendFrame(&suspended);
                    return true;
                },
            };
            activation.release(self.releases);
            driver.deinit(self.releases, self.allocator);
            // Native work installed by an application continuation is the
            // continuation's tail. Do not cross later continuation frames until
            // that owned work has produced its stack result. A continuation
            // that installed nothing has charged its fuel; the next frame is
            // resumed only while fuel remains.
            if (self.hasWorkDriver()) return true;
        },
        .qualified_after_load => {
            const continuation = self.popFrame(.qualified_after_load);
            // Source loading temporarily replaces the caller's evaluation.
            // Replay requests resume at their restored primitive operands;
            // dispatch requests resume the exact stored word without replay.
            if (continuation.request.preservesCaller()) {
                const caller = self.frames.pop().?;
                self.current = switch (caller) {
                    .eval => |evaluation| evaluation,
                    else => unreachable,
                };
            }
            if (try load.verifyAfterLoad(.of(self), continuation)) return true;
        },
        .boundary => {
            if (self.frames.items[self.frames.items.len - 1].boundary.mode == .module) {
                try module_construction.startSeal(.of(self));
                return true;
            }
            const boundary = self.popFrame(.boundary);
            std.debug.assert(@backingInt(self.boundary_index.?) == self.frames.items.len);
            self.boundary_index = boundary.previous_boundary;
            self.floor.restore(boundary.beneath);
            self.active_word = boundary.word;
            switch (boundary.mode) {
                .attempt => {
                    defer boundary.deinit();
                    try finishAttempt(self, boundary.stack_base);
                    return true;
                },
                .module => unreachable,
                .load => try finishLoad(self, boundary.stack_base),
            }
        },
    };
    // Even if this was the last frame, the fiber must poll cancellation
    // and yield before reporting completion.
    return true;
}
fn finishEffectCheck(self: *Fiber, check: *EffectCheck) MachineError!void {
    check.restoreActive(self);
    const observed = self.stack.items.len;
    switch (check.result_depth) {
        .unchecked => return,
        .exact => if (observed == check.expected_depth) return,
        .at_least => if (observed >= check.expected_depth) return,
    }
    self.active_word = check.word;
    const observed_relative = observed - self.floor.base;
    const failure = self.failFmt(
        .contract,
        "{s} declared ({d} -- {s}{d}); seeded {d}, observed {d}",
        .{
            self.activeWordName(),
            check.inputs,
            if (check.result_depth == .at_least) "at least " else "",
            check.outputs,
            check.entry_depth,
            observed_relative,
        },
    );
    self.pendingFailure().addData(.seeded, .{ .int = check.entry_depth });
    self.pendingFailure().addData(.observed, .{ .int = @intCast(observed_relative) });
    if (check.provenance == .invocation)
        self.pendingFailure().site = .{ .token = check.provenance.invocation };
    if (check.takeCandidate()) |candidate|
        self.pendingFailure().site = .{ .contract_quotation = candidate };
    return failure;
}
/// Finishes one `@load` boundary. Like a module body, a loaded file defines
/// and keeps no stack state, so a residual operand window is refused.
fn finishLoad(self: *Fiber, base: u32) MachineError!void {
    const observed = self.stack.items.len - base;
    if (observed != 0) return self.failFmt(
        .domain,
        "@load file left {d} value{s} on its stack; a loaded file defines words and keeps no state",
        .{ observed, if (observed == 1) "" else "s" },
    );
}
fn finishAttempt(self: *Fiber, base: u32) MachineError!void {
    // The attempt's stack becomes the outcome's list, so each value enters
    // as data (`value.datum`); the operands are released once materialized.
    for (self.stack.items[base..]) |*item| item.* = value.datum(item.*);
    try self.startDriver(AttemptResultDriver.init(
        self.allocator,
        base,
        self.stack.items[base..],
    ));
}
const AttemptResultDriver = struct {
    allocator: std.mem.Allocator,
    base: usize,
    materializer: heap.Owned(list.ValueMaterializer),
    results: ?heap.Owned(Value) = null,
    phase: enum { materialize, release, outcome } = .materialize,

    fn init(
        allocator: std.mem.Allocator,
        base: u32,
        values: []const Value,
    ) AttemptResultDriver {
        return .{
            .allocator = allocator,
            .base = base,
            .materializer = .init(.init(allocator, values)),
        };
    }
    fn advance(fiber: *Fiber, self: *AttemptResultDriver) MachineError!WorkProgress {
        const work = fiber.workBudget();
        while (!work.exhausted()) switch (self.phase) {
            .materialize => switch (try self.materializer.borrowMut().advance(work)) {
                .pending => return .stepped,
                .complete => |results| {
                    self.results = .init(results);
                    self.phase = .release;
                    return .stepped;
                },
            },
            .release => {
                if (fiber.stack.items.len == self.base) {
                    self.phase = .outcome;
                    continue;
                }
                fiber.releases.releaseValue(fiber.stack.pop().?);
                _ = work.spend();
            },
            .outcome => {
                const results = self.results.?.take();
                self.results = null;
                const outcome = try outcomeDict(self.allocator, fiber.releases, "ok", results);
                return .{ .output = outcome };
            },
        };
        return .stepped;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
pub fn outcomeDict(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    name: []const u8,
    payload: Value,
) error{OutOfMemory}!Value {
    defer releases.releaseValue(payload);
    const key = try intern.intern(name);
    return dict.fromUniquePairs(allocator, releases, &.{.{ .{ .symbol = .{ .name = key } }, payload }});
}
fn startFailure(self: *Fiber) error{OutOfMemory}!void {
    std.debug.assert(self.hasPendingFailure());
    // Failure entry owns the native tail too: it must be detached before the
    // frame unwinder can replace it with the failure driver.
    clearWorkDriver(self);
    return failure_driver.start(.of(self));
}

/// The fiber as module construction sees it, plus the
/// construction boundary that holds the image being built. Minted only by the
/// machine, like `Loading`.
pub const Construction = opaque {
    fn of(target: *Fiber) *Construction {
        return @ptrCast(target);
    }

    pub fn fiber(self: *Construction) *Fiber {
        return @ptrCast(@alignCast(self));
    }

    /// `Fiber.startDriver` for a driver that asks for this view.
    pub fn startDriver(self: *Construction, initial: anytype) error{OutOfMemory}!void {
        return self.fiber().startDriverAs(*Construction, initial);
    }

    /// `Fiber.adoptDriver` for a driver that asks for this view.
    pub fn adoptDriver(self: *Construction, context: anytype) void {
        self.fiber().adoptDriverAs(*Construction, context);
    }

    /// Opens one construction boundary. Consuming: the body is owned by the
    /// boundary on success and released on every failure, and the image is
    /// consumed only once the boundary owns it.
    pub fn openImageBoundary(self: *Construction, candidate: *modules.OwnedImage, word: intern.TraceWord, body: *Header) MachineError!void {
        return self.fiber().openImageBoundary(candidate, word, body);
    }

    /// Closes the construction boundary on top once its body has run, and
    /// returns the image it held. A module body defines words and keeps no
    /// state, so a residual operand window closes the boundary and fails.
    pub fn closeBoundary(self: *Construction) MachineError!modules.OwnedImage {
        return self.fiber().closeModuleBoundary();
    }
};

/// One activation as a failure's trace sees it: the word, where it was
/// called, and where its failures are reported. The site borrows code the
/// fiber's frames keep alive until the unwind.
pub const TraceEntry = struct {
    word: intern.TraceWord,
    site: ?ErrorSite,
    attribution: env.Attribution,
};
/// The fiber as its failure driver sees it, plus what building
/// and delivering an error value needs of the continuation — the activation
/// trace, the pending failure, and the unwind itself. Minted only by the
/// machine, like `Loading`.
pub const Unwinding = opaque {
    fn of(target: *Fiber) *Unwinding {
        return @ptrCast(target);
    }

    pub fn fiber(self: *Unwinding) *Fiber {
        return @ptrCast(@alignCast(self));
    }

    /// `Fiber.adoptDriver` for a driver that asks for this view.
    pub fn adoptDriver(self: *Unwinding, context: anytype) void {
        self.fiber().adoptDriverAs(*Unwinding, context);
    }

    /// Moves the pending failure out; the fiber is unwinding from here.
    pub fn takeFailure(self: *Unwinding) EclErr {
        return self.fiber().takePendingForUnwind();
    }

    /// The `nth` word the running evaluation is traced under, innermost
    /// first, or null past the last.
    pub fn currentTrace(self: *Unwinding, nth: usize) ?TraceEntry {
        const current = if (self.fiber().current) |*running| running else return null;
        return self.fiber().tracedUnder(current, self.fiber().active_index, false, nth);
    }

    /// The `nth` word saved frame `index` is traced under, if it is a traced
    /// evaluation, or null past the last.
    pub fn frameTrace(self: *Unwinding, index: usize, nth: usize) ?TraceEntry {
        return switch (self.fiber().frames.items[index]) {
            .eval => |*frame| trace: {
                const next = frame.nextIndex();
                break :trace self.fiber().tracedUnder(frame, if (next == 0) 0 else next - 1, true, nth);
            },
            .effect_check, .application, .qualified_after_load, .boundary => null,
        };
    }

    fn traceEntry(activation: Activation) ?TraceEntry {
        return .{
            .word = activation.traced() orelse return null,
            .site = activation.site(),
            .attribution = activation.attribution,
        };
    }

    /// Where a failure is reported: the failing token, or the call site a
    /// helper's failure is attributed to.
    pub fn locateSite(self: *Unwinding, site: ErrorSite) spans.SpanArchive.LocateCursor {
        const origin = self.fiber().written(site.code, site.index);
        return self.fiber().archive.locateCursor(origin.code, origin.index);
    }

    /// Where the failure happened: already known, or a cursor that finds it
    /// in the archive.
    pub fn locate(self: *Unwinding, failure: *const EclErr) union(enum) {
        locating: spans.SpanArchive.LocateCursor,
        located: ?spans.LocatedSpan,
    } {
        const archive = self.fiber().archive;
        const site = failure.site orelse return .{ .located = null };
        return switch (site) {
            .token => |token| token: {
                const origin = self.fiber().written(token.code, token.index);
                break :token .{ .locating = archive.locateCursor(origin.code, origin.index) };
            },
            .contract_quotation => |candidate| .{ .locating = archive.locateQuotationCursor(candidate.borrow()) },
            .explicit_location => |location| .{ .located = .{
                .source_name = location.source_name,
                .span = location.span,
            } },
        };
    }

    pub fn beginUnwind(self: *Unwinding) Unwind {
        return .{ .phase = .{ .nearest = self.fiber().boundary_index } };
    }

    /// Ends an uncaught unwind: the fiber has failed with `error_value`,
    /// which it now owns.
    pub fn finishFailed(self: *Unwinding, error_value: Value) void {
        self.fiber().finishUnwindFailed(error_value);
    }

    /// Ends a caught unwind: the fiber evaluates again.
    pub fn finishCaught(self: *Unwinding) void {
        self.fiber().finishUnwindCaught();
    }
};

/// Resumable unwinding of a fiber to the boundary that catches its failure,
/// or to its entry: the running evaluation, then saved frames, locals, and
/// operands, one per step, and last the floor and boundary beneath. It owns
/// nothing; what it removes, the fiber owned.
pub const Unwind = struct {
    const Target = union(enum) {
        uncaught: struct { stack_base: usize },
        caught: struct {
            boundary_index: FrameIndex,
            stack_base: usize,
            locals_base: usize,
            beneath: floor_api.Beneath,
            previous_boundary: ?FrameIndex,
        },

        fn frameTarget(self: Target) usize {
            return switch (self) {
                .uncaught => 0,
                .caught => |caught| @as(usize, @backingInt(caught.boundary_index)) + 1,
            };
        }
        fn localsTarget(self: Target) usize {
            return switch (self) {
                .uncaught => 0,
                .caught => |caught| caught.locals_base,
            };
        }
        fn stackTarget(self: Target) usize {
            return switch (self) {
                .uncaught => |uncaught| uncaught.stack_base,
                .caught => |caught| caught.stack_base,
            };
        }
        fn beneath(self: Target) floor_api.Beneath {
            return switch (self) {
                .uncaught => .{ .hard = 0 },
                .caught => |caught| caught.beneath,
            };
        }
        fn previousBoundary(self: Target) ?FrameIndex {
            return switch (self) {
                .uncaught => null,
                .caught => |caught| caught.previous_boundary,
            };
        }
    };

    const Progress = enum { pending, uncaught, caught };

    phase: union(enum) {
        /// The boundary being asked whether it catches.
        nearest: ?FrameIndex,
        current: Target,
        frames: Target,
        boundary: Target,
        locals: Target,
        stack: Target,
    },

    /// One step: one boundary examined, or one frame, local, or operand
    /// released.
    pub fn advance(self: *Unwind, via: *Unwinding) Progress {
        const fiber = via.fiber();
        switch (self.phase) {
            .nearest => |*nearest| {
                const boundary_index = nearest.* orelse {
                    self.phase = .{ .current = .{ .uncaught = .{
                        .stack_base = fiber.entry_base,
                    } } };
                    return .pending;
                };
                const boundary = fiber.frames.items[@backingInt(boundary_index)].boundary;
                if (boundary.mode == .attempt and !fiber.cancelled.load(.acquire)) {
                    self.phase = .{ .current = .{ .caught = .{
                        .boundary_index = boundary_index,
                        .stack_base = boundary.stack_base,
                        .locals_base = boundary.locals_base,
                        .beneath = boundary.beneath,
                        .previous_boundary = boundary.previous_boundary,
                    } } };
                } else nearest.* = boundary.previous_boundary;
            },
            .current => |target| {
                releaseCurrent(fiber);
                self.phase = .{ .frames = target };
            },
            .frames => |target| {
                if (fiber.frames.items.len != target.frameTarget()) {
                    fiber.deinitPoppedFrame(fiber.frames.pop().?);
                } else self.phase = .{ .boundary = target };
            },
            .boundary => |target| {
                if (target == .caught) fiber.deinitPoppedFrame(fiber.frames.pop().?);
                self.phase = .{ .locals = target };
            },
            .locals => |target| {
                const depth = @min(target.localsTarget(), fiber.locals.items.len);
                if (fiber.locals.items.len != depth) {
                    fiber.releases.releaseValue(fiber.locals.pop().?);
                } else self.phase = .{ .stack = target };
            },
            .stack => |target| {
                const depth = @min(target.stackTarget(), fiber.stack.items.len);
                if (fiber.stack.items.len != depth) {
                    fiber.releases.releaseValue(fiber.stack.pop().?);
                    return .pending;
                }
                fiber.floor.restore(target.beneath());
                fiber.boundary_index = target.previousBoundary();
                return switch (target) {
                    .uncaught => .uncaught,
                    .caught => .caught,
                };
            },
        }
        return .pending;
    }
};
fn releaseCurrent(self: *Fiber) void {
    if (self.current) |current| current.release(self.releases);
    self.current = null;
}
