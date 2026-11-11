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
const stdlib = @import("stdlib.zig");
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
const paging_api = @import("paging.zig");
const PagingFloor = paging_api.PagingFloor;
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
    /// The fiber's own root scope.
    own,
    /// A root the fiber does not own: a task in its spawner's, or a Session's
    /// root fiber in the Session's. The scope's owner outlives the fiber, or
    /// the fiber pins it.
    scope: *env.Scope,
    /// One registered module generation's own code, under that image's
    /// provenance. The fiber pins the generation before entering it.
    image: *modules.ModuleHome,
};
/// Who runs a fiber, and so what it may do. A root fiber runs a submission
/// or a host-driven load and may define. A task fiber runs in its spawner's
/// scope without being a root of its own, so it may not define. The bootstrap
/// fiber builds the prelude before any scheduler exists.
pub const Role = union(enum) {
    bootstrap,
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
    left,
    right,
    @"destination-exists",
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
    importer,
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
    var cursor = ErrorValueCursor.init(allocator, failure, resolved, location);
    defer cursor.retire(releases);
    var work = poll_api.unbounded();
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
/// How an evaluation's words reach their targets.
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
    traced_word: intern.TraceWord,
    /// The word whose body this is, set only when dispatch entered that body.
    /// `traced_word` cannot answer this: a tail position clears it, and an
    /// application may borrow a word for attribution. A locals binder opening
    /// the body is that word's arity check, so its failure is the word's.
    body_owner: intern.TraceWord = no_word,
    /// Nominal authority to replace one source effect check's completion
    /// provenance. A non-tail call and every application quotation receive
    /// no authority, so their internal tail calls cannot overwrite the
    /// checked activation's authored control choice.
    effect_tail: ?EffectCheckIndex = null,
    /// Authority for the current generic application's selection boundary.
    /// Iterative continuations mint a fresh boundary per element; explicitly
    /// tail-transparent control quotations inherit the enclosing boundary.
    application_tail: ?ApplicationFrameIndex = null,
    /// This Eval was entered through a dynamic `call` while in the named
    /// application. If it completes or transfers tail control, its existing
    /// code-header ownership becomes the application's selected quotation.
    application_selection: ?ApplicationFrameIndex = null,

    /// Releases what this evaluation owns.
    inline fn release(self: Eval, releases: *heap.ReleaseDomain) void {
        switch (self.program) {
            .owned => releases.releaseHeader(self.code),
            .definition => |executable| executable.owner().release(releases),
            .borrowed => {},
        }
    }

    /// Takes one more reference for a copy of this evaluation.
    fn retainCopy(self: Eval) void {
        switch (self.program) {
            .owned => heap.incRef(self.code),
            .definition => |executable| executable.owner().retain(),
            .borrowed => {},
        }
    }

    /// Moves this evaluation's ownership into one code reference, for a
    /// holder that keeps only the quotation.
    fn intoCode(self: Eval, releases: *heap.ReleaseDomain) *Header {
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
    fn scope(self: Eval) *env.Scope {
        return self.site.scope;
    }
};
/// A module construction boundary. The body builds the image `@defm` named
/// before it ran; completion seals and publishes that image.
const ModuleBoundary = struct {
    image: modules.OwnedImage,
    /// The construction body `@defm` runs, after re-scoping. A declaration
    /// is module-level only while this is the current activation; quotations
    /// called by the body may inherit its home but not its declaration site.
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
    beneath: paging_api.Beneath,
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
        /// time: a guard alternates its tests over a paging floor with its
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
    /// Over a paging floor the application's context owns and keeps in place
    /// until the application resumes, with the region above the lowered
    /// floor as its window.
    paging: *PagingFloor,
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

pub const ExecutionSite = struct {
    /// The current root: where this body's own definitions land, and, when it
    /// is a module image's root scope, the module whose code is running. A
    /// module word runs in its image's scope; every other word, and every
    /// quotation applied as a value, runs in its caller's. Where a word
    /// resolves is carried by the word itself.
    scope: *env.Scope,
    /// Authority carried only while evaluating an embedded source module.
    /// A named module constructed by that source moves it into the immutable
    /// registration; ordinary source always carries ordinary provenance.
    registration_provenance: modules.RegistrationProvenance = .ordinary,
    /// Whether definitions may land in `scope`. Set where a root is entered:
    /// true for a root fiber and a module construction body, false for a
    /// task, which runs in its spawner's root without owning it. Everything
    /// else, every combinator application and `@attempt` included, inherits
    /// it unchanged.
    defining: bool,

    /// The base case: a fiber's root activation, built from nothing.
    fn root(fiber: *Fiber) ExecutionSite {
        const defining = fiber.role != .task;
        return switch (fiber.root_entry) {
            .image => |home| image(home, fiber.module_access, defining),
            .own, .scope => .{
                .scope = fiber.lexicalScope(),
                .defining = defining,
                .registration_provenance = if (fiber.inherited.module_snapshot) |module_snapshot|
                    .{ .root_scope = module_snapshot.localScope() }
                else
                    .ordinary,
            },
        };
    }

    /// Code running as one module image: the image's own definitions, then
    /// core, under the image's provenance.
    fn image(
        home: *modules.ModuleHome,
        access: *const modules.ExecutionAccess,
        defining: bool,
    ) ExecutionSite {
        return .{
            .scope = home.scope(access),
            .defining = defining,
            .registration_provenance = home.registrationProvenance(),
        };
    }

    /// The site of a quotation this activation applies as a value: a dynamic
    /// `call`, a combinator's quotation, an `@attempt` body, or a resumed
    /// qualified load. It runs in the same root with the same right to
    /// define. The value may have come from any caller, so it does not
    /// inherit embedded registration trust; a resumed load sets the
    /// provenance it registers under itself.
    fn applied(self: ExecutionSite) ExecutionSite {
        return .{
            .scope = self.scope,
            .registration_provenance = self.registration_provenance.applied(),
            .defining = self.defining,
        };
    }
};

pub const ApplicationProvenance = union(enum) {
    boundary,
    selected_target: *const ApplicationProvenanceTarget,
};
pub const Application = struct {
    quotation: *Header,
    context: *anyopaque,
    resume_fn: *const fn (*Fiber, *anyopaque, StackWindow, *ApplicationContractSite) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ExecutionSite,
    seeded: u32,
    provenance: ApplicationProvenance,
    /// Where a finite iteration keeps what its call has decided for its
    /// quotation's words.
    plan: ?*ResolutionPlan = null,

    /// Releases an application that never became a frame.
    fn discard(self: Application, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        self.deinit_fn(releases, allocator, self.context);
    }
};

const WordResolutions = @import("word_resolutions.zig").WordResolutions;

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
    const adapters = ApplicationAdapters(Driver);
    return .{
        .quotation = quotation,
        .context = @ptrCast(driver),
        .resume_fn = adapters.run,
        .deinit_fn = adapters.deinit,
        .site = site,
        .seeded = seeded,
        .provenance = .boundary,
    };
}
const ApplicationMode = union(enum) {
    in_place: StackWindow,
    /// The floor the application's hard floor was set over.
    isolated: paging_api.Beneath,
    /// The floor lives in the combinator state the frame's context names,
    /// which stays in place until the application resumes.
    paging: *PagingFloor,
};
const ApplicationFrame = struct {
    context: *anyopaque,
    resume_fn: *const fn (*Fiber, *anyopaque, StackWindow, *ApplicationContractSite) MachineError!?ApplicationStep,
    deinit_fn: *const fn (*heap.ReleaseDomain, std.mem.Allocator, *anyopaque) void,
    site: ExecutionSite,
    mode: ApplicationMode,
    traced_word: intern.TraceWord,
    selection: ApplicationSelection,
    provenance_nonce: ?ApplicationProvenanceNonce = null,
    /// Borrowed from the combinator state `context` names.
    plan: ?*ResolutionPlan = null,
    fn deinit(self: ApplicationFrame, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        var selection = self.selection;
        selection.deinit(releases);
        switch (self.mode) {
            // A paging floor's lists belong to the context that holds it.
            .in_place, .isolated, .paging => {},
        }
        self.deinit_fn(releases, allocator, self.context);
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
    // on correlated Fiber fields. Application frames likewise own the lexical scope
    // provenance every sibling resumption must preserve.
    // File-owned execution provenance carries a Session-scoped source capability.
    if (@sizeOf(Frame) > 144) @compileError("machine frames must remain at most 144 bytes");
}
/// A user quotation offered to a combinator, recognized where it is applied.
pub const IdiomRequest = enum { each, zip_with, fold, fold1, scan, lex_cmp };
/// The combinator's generic path, run when recognition declines its quotation.
pub const IdiomFallback = *const fn (*Fiber) MachineError!void;

/// Configuration and semantic services inherited by every spawned Fiber.
/// Keeping this as one value makes addition of a new inherited service an
/// atomic parent-to-child copy instead of a scheduler-site field checklist.
const InheritedContext = struct {
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

    fn libraries(self: *const InheritedContext) EmbeddedLibraries {
        return switch (self.phase) {
            .bootstrap => .bundled,
            .runtime => |context| .{ .registered = context.native_loader },
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
/// through `fd.in`, or the program source itself, which `fd.in` refuses.
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
/// `stepped` and `yielded` separate progress from surrender, and a yield names
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
    trace_parent: ?intern.TraceWord = null,

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

fn WorkDriverAdapters(comptime Driver: type) type {
    return struct {
        fn advance(fiber: *Fiber, raw: *anyopaque) MachineError!WorkProgress {
            const driver: *Driver = @ptrCast(@alignCast(raw));
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
    qualified_cache_hits: u64 = 0,
    qualified_cache_misses: u64 = 0,
    qualified_cache_heals: u64 = 0,
    local_cache_hits: u64 = 0,
    local_cache_misses: u64 = 0,
    plain_cache_hits: u64 = 0,
    plain_cache_misses: u64 = 0,
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
            try fiber.pollKernel();
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
    pub fn openLoad(self: *Loading, body: *Header, word: intern.TraceWord, provenance: modules.RegistrationProvenance) error{OutOfMemory}!void {
        return self.fiber().openLoad(body, word, provenance);
    }

    /// Runs `body` as a registering source in place of the running
    /// evaluation, which resumes through `after` once the body returns.
    /// Consumes `body` and `after` on success and failure.
    pub fn enterRegistration(
        self: *Loading,
        body: *Header,
        provenance: modules.RegistrationProvenance,
        after: load.AfterLoad,
    ) error{OutOfMemory}!void {
        return self.fiber().enterRegistration(body, provenance, after);
    }

    /// Dispatches the word a completed load was started for, by explicit
    /// lookup under the provenance that asked for it.
    pub fn dispatchAfterLoad(
        self: *Loading,
        word: value.Symbol,
        site: ?ErrorSite,
        trace_parent: ?intern.TraceWord,
        provenance: modules.RegistrationProvenance,
    ) error{OutOfMemory}!void {
        return self.fiber().dispatchAfterLoad(word, site, trace_parent, provenance);
    }

    /// Puts back the symbol operand a primitive consumed before its module
    /// turned out to be unloaded, and rewinds so the primitive runs again.
    pub fn replayOperand(self: *Loading, requested: value.Symbol) error{OutOfMemory}!void {
        return self.fiber().replayOperand(requested);
    }

    /// The embedded or registered standard library named `name`, if any.
    pub fn embeddedLibrary(self: *Loading, name: intern.ModuleName) ?stdlib.Entry {
        return self.fiber().inherited.libraries().find(name);
    }

    /// Names the module whose deferred import the pending failure is about.
    pub fn addErrorImporter(self: *Loading, importer: intern.ModuleName) void {
        self.fiber().pendingFailure().addData(.importer, .{ .symbol = .{ .name = intern.moduleId(importer) } });
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

    const LifetimeGuard = struct {
        const State = union(enum) {
            active: std.ArrayList(modules.GenerationPin),
            scope: struct {
                cursor: ?env.Scope.EmbeddedTeardownCursor = null,
                generation_pins: std.ArrayList(modules.GenerationPin),
            },
            pins: std.ArrayList(modules.GenerationPin),
            complete,
        };
        // Activations point at this address, so it must never move while the
        // fiber is alive. Teardown state moves around it instead.
        root_scope: env.Scope,
        state: State,

        fn init(allocator: std.mem.Allocator, environment: *env.Env) LifetimeGuard {
            return .{
                .root_scope = environment.sessionRoot(allocator),
                .state = .{ .active = .empty },
            };
        }

        fn replaceRoot(self: *LifetimeGuard, root: env.Scope) void {
            std.debug.assert(self.state == .active);
            self.root_scope.releaseTrivial();
            self.root_scope = root;
        }

        fn pin(
            self: *LifetimeGuard,
            allocator: std.mem.Allocator,
            generation: *modules.ModuleHome,
            access: *const modules.ExecutionAccess,
        ) error{OutOfMemory}!void {
            const pins = &self.state.active;
            for (pins.items) |pinned| if (pinned.matches(generation, access)) return;
            var owned_pin = generation.pin(access);
            errdefer owned_pin.deinit();
            try pins.append(allocator, owned_pin);
        }

        /// Takes ownership of a pin acquired elsewhere -- the borrow at
        /// dispatch. Deduplicates the same way `pin` does, releasing the
        /// incoming reference when one is already held, so adopting is
        /// idempotent per owner.
        fn adopt(
            self: *LifetimeGuard,
            allocator: std.mem.Allocator,
            owned: *modules.GenerationPin,
        ) error{OutOfMemory}!void {
            const pins = &self.state.active;
            for (pins.items) |pinned| if (pinned.sameOwner(owned.*)) {
                owned.deinit();
                return;
            };
            errdefer owned.deinit();
            try pins.append(allocator, owned.*);
            owned.* = .consumed;
        }

        fn rootScope(self: *LifetimeGuard) *env.Scope {
            std.debug.assert(self.state == .active);
            return &self.root_scope;
        }

        fn advanceTeardown(
            self: *LifetimeGuard,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) bool {
            return switch (self.state) {
                .active => |pins| result: {
                    self.state = .{ .scope = .{
                        .generation_pins = pins,
                    } };
                    break :result false;
                },
                .scope => |*scope| result: {
                    _ = releases;
                    if (scope.cursor == null)
                        scope.cursor = .init(&self.root_scope);
                    if (!scope.cursor.?.advance()) break :result false;
                    const pins = scope.generation_pins;
                    self.state = .{ .pins = pins };
                    break :result false;
                },
                .pins => |*pins| if (pins.pop()) |pin_value| result: {
                    var owned_pin = pin_value;
                    owned_pin.deinit();
                    break :result false;
                } else result: {
                    pins.deinit(allocator);
                    self.state = .complete;
                    break :result true;
                },
                .complete => true,
            };
        }

        fn deinit(
            self: *LifetimeGuard,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            while (!self.advanceTeardown(releases, allocator)) {}
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    module_access: *const modules.ExecutionAccess,
    frames: std.ArrayList(Frame) = .empty,
    stack: std.ArrayList(Value),
    environment: *env.Env,
    inherited: InheritedContext,
    lifetime: LifetimeGuard,
    archive: *spans.SpanArchive,
    arguments: Value,
    cancelled: *const std.atomic.Value(bool),
    fuel: u32 = fuel_quantum,
    /// The fiber's one allowance for logical kernel work in a turn. Cursors
    /// doing this fiber's work draw on it through `Fiber.workBudget`, and
    /// exhausting it ends the turn: only the start of the next turn refills it.
    kernel_budget: poll_api.WorkBudget = .init(kernel_poll_quantum),
    polls: u64 = 0,
    root_execution_metrics: if (root_execution_metrics_enabled) RootExecutionMetrics else void = if (root_execution_metrics_enabled) .{} else {},
    /// What this fiber's code resolved its words to.
    resolutions: WordResolutions = .{},
    entry_base: usize,
    /// How far down a word may reach, and what `require` compares against.
    floor: paging_api.StackFloor = .{},
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
        module_access: *const modules.ExecutionAccess,
        stack: std.ArrayList(Value),
        environment: *env.Env,
        archive: *spans.SpanArchive,
        inherited: InheritedContext,
        arguments: Value,
        cancelled: *const std.atomic.Value(bool),
        role: Role,
        root_entry: RootEntry,
    ) Fiber {
        return .{
            .allocator = allocator,
            .releases = releases,
            .module_access = module_access,
            .stack = stack,
            .environment = environment,
            .lifetime = .init(allocator, environment),
            .archive = archive,
            .inherited = inherited,
            .arguments = arguments,
            .cancelled = cancelled,
            .role = role,
            .root_entry = root_entry,
            .entry_base = stack.items.len,
            // SAFETY: this field supplies storage only. `driver_slot_busy` is the only
            // thing that says a driver lives here, and every read of the slot
            // goes through `acquireInlineDriver`, which writes the whole
            // driver before the pointer escapes.
            .driver_slot = undefined,
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

    pub fn replaceRootScope(self: *Fiber, root: env.Scope) void {
        self.lifetime.replaceRoot(root);
    }

    fn rootScope(self: *Fiber) *env.Scope {
        return self.lifetime.rootScope();
    }

    /// The chain a homeless binding — a primitive or an embedded prelude
    /// definition — resolves against. It is the session root over core, so
    /// session-level redefinition still reaches prelude bodies while a module
    /// body executing further down the stack does not.
    pub fn lexicalScope(self: *Fiber) *env.Scope {
        return switch (self.root_entry) {
            .own => self.rootScope(),
            .scope => |scope| scope,
            .image => |home| home.scope(self.module_access),
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
    /// of budget retires at most one continuation, operand, native owner, or
    /// generation pin. Array storage is released by `deinit` after this cursor
    /// reports complete.
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
            if (!self.lifetime.advanceTeardown(self.releases, self.allocator)) {
                consumed += 1;
                continue;
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
    /// root's top-level directory, or a published image's.
    pub fn visibleNameRoot(self: *Fiber) reflection.VisibleNameRoot {
        const scope = self.currentScope();
        if (scope.isModuleRoot()) if (modules.homeForModuleRootScope(scope)) |home| {
            if (home.isPublished()) return .{ .image = .{
                .entries = home.publishedEntries(),
                .pin = home.pin(self.module_access),
            } };
            return .core;
        };
        if (scope.storage == .core_build) return .core;
        return .{ .session = self.inherited.registry.view() };
    }

    /// The image under construction whose root is `scope`, found through the
    /// open module boundaries: the one place its staged names are written.
    pub fn stagingImage(self: *Fiber, scope: *env.Scope) ?*modules.OwnedImage {
        var index = self.boundary_index;
        while (index) |frame_index| {
            const boundary = &self.frames.items[@backingInt(frame_index)].boundary;
            switch (boundary.mode) {
                .module => |*module| {
                    if (module.image.executionHome(self.module_access).scope(self.module_access) == scope)
                        return &module.image;
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
    pub fn pinGeneration(self: *Fiber, generation: *modules.ModuleHome) error{OutOfMemory}!void {
        try self.lifetime.pin(self.allocator, generation, self.module_access);
    }

    /// Sized to the drivers that opt in, checked by `inlineDriverCapable`.
    /// Includes native registration authority and a reference to the Fiber's
    /// bounded lexical observations for lookup and idiom recognition. Preserve the
    /// complete ownership state without allocating on ordinary resolution.
    const driver_slot_len = 736;
    const driver_slot_align = 16;

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
        self.resolutions.deinit(self.allocator, self.releases);
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
        self.lifetime.deinit(self.releases, self.allocator);
        self.* = undefined;
    }

    fn deinitPoppedFrame(self: *Fiber, popped: Frame) void {
        var frame = popped;
        if (frame == .effect_check) frame.effect_check.restoreActive(self);
        // An unwind pops a paging frame before it restores the boundary's
        // floor; nothing requires operands in between, but the pointer must
        // not outlive the state the frame's context owns.
        if (frame == .application and frame.application.mode == .paging and
            self.floor.paging == frame.application.mode.paging)
            self.floor.restore(frame.application.mode.paging.beneath);
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
    pub fn currentScope(self: *const Fiber) *env.Scope {
        return self.current.?.scope();
    }
    /// Links words written into `scope`, a root, to that root. An image's
    /// cell carries its owner anchor, so a word that escapes the image proves
    /// the image live before reading its directory.
    pub fn rootLinker(self: *Fiber, scope: *env.Scope) error{OutOfMemory}!env.SymbolLinker {
        return switch (scope.storage) {
            .session => self.environment.linker(self.environment.sessionScopeId()),
            .core_build => self.environment.linker(self.environment.coreScopeId()),
            .module_root => self.environment.linker((try self.environment.scopeCell(
                scope,
                modules.anchorHandle(modules.homeForModuleRootScope(scope).?, self.module_access),
            )).id),
        };
    }
    /// The word `name` linked to its slot in the running activation's root, as
    /// a word built at run time on that activation's behalf is.
    pub fn linkedWord(self: *Fiber, name: u32) error{OutOfMemory}!value.Symbol {
        const linker = try self.rootLinker(self.currentScope());
        return .{ .name = name, .slot = try linker.link(name) };
    }
    /// The word `name` linked to its core slot, as a word the implementation
    /// builds for itself is: it means core's binding wherever it runs.
    pub fn coreWord(self: *Fiber, name: u32) error{OutOfMemory}!value.Symbol {
        const linker = self.environment.linker(self.environment.coreScopeId());
        return .{ .name = name, .slot = try linker.link(name) };
    }
    /// The root a definition, removal, or import writes. Refused inside a
    /// task, which runs in its spawner's root without owning it.
    pub fn definitionScope(self: *Fiber) MachineError!*env.Scope {
        const scope = self.currentScope();
        if (!self.current.?.site.defining) return self.fail(
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
        const located = self.archive.locate(current.code, self.active_index) orelse
            return null;
        return located.source_name;
    }
    /// The module whose code is running, if the current root is an image.
    pub fn currentHome(self: *const Fiber) ?*modules.ModuleHome {
        return modules.homeForModuleRootScope(self.currentScope());
    }
    /// Begin publishing one first-class test into the candidate owned by the
    /// immediately enclosing module-construction boundary. Requiring that
    /// boundary to be the top frame distinguishes the construction body's
    /// direct root from quotations or child fibers that merely inherit its
    /// scope and private home.
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
        const home = candidate.executionHome(self.module_access);
        if (self.currentScope() != home.scope(self.module_access))
            return self.fail(.domain, "test is legal only at a direct module construction root");
        if (self.inherited.test_execution == null)
            return .discard();
        return candidate.testDeclarationCursor(name, body, effect, doc);
    }
    /// The site a combinator's quotation runs at, captured when it launches.
    pub fn applicationSite(self: *const Fiber) ExecutionSite {
        return self.current.?.site.applied();
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
        const progress = Driver.advance(self, pending) catch |err| {
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
            .context = self.current.?.site.registration_provenance,
            .continuation = .load_only,
        });
    }

    /// A reflection primitive already consumed its symbol before discovering
    /// a cold qualified module. Restore that operand and rewind the primitive
    /// call, then use the same loader/retry protocol as executable dispatch.
    pub fn retryQualifiedOperandAfterLoad(
        self: *Fiber,
        requested: value.Symbol,
        outcome: binder.Miss,
    ) MachineError!WorkProgress {
        if (self.current == null)
            return self.undefinedNameIn(requested.name, .qualified);
        switch (outcome) {
            .unknown_module_prefix => |prefix| {
                try load.prepareQualified(
                    .of(self),
                    prefix,
                    .{ .qualified = requested.name, .context = self.current.?.site.registration_provenance, .continuation = .replay },
                    .{ .operand = requested },
                );
                return .detached;
            },
            .unregistered_module => |name| {
                try self.replayOperand(requested);
                try self.autoLoadModule(name, .{
                    .qualified = requested.name,
                    .context = self.current.?.site.registration_provenance,
                    .continuation = .replay,
                });
                return .detached;
            },
            .unresolved => |chain| return self.undefinedNameIn(requested.name, chain),
            .retired => return self.failUnbound(requested, .retired),
            .alias_cycle => return self.failUnbound(requested, .alias_cycle),
        }
    }
    /// A batch import consumes its module symbol and requested-name list before
    /// discovering a cold module. Restore both operands, rewind the primitive,
    /// and share the ordinary qualified-name auto-load/retry path.
    pub fn retryImportAfterLoad(
        self: *Fiber,
        module_id: u32,
        requested: Value,
        module_name: intern.ModuleName,
        requested_word: u32,
    ) MachineError!WorkProgress {
        if (self.current == null) {
            self.releases.releaseValue(requested);
            return self.undefinedNameIn(requested_word, .qualified);
        }
        try self.restoreImportOperands(module_id, requested);
        self.current.?.rewind(self.active_index);
        try self.autoLoadModule(module_name, .{
            .qualified = requested_word,
            .context = self.current.?.site.registration_provenance,
            .continuation = .replay,
        });
        return .detached;
    }
    /// Consumes the requested-name list on both success and allocation
    /// failure. Keeping the exact stack commit outside the driver-returning
    /// retry function preserves the WorkProgress output boundary audited for
    /// every driver.
    fn restoreImportOperands(self: *Fiber, module_id: u32, requested: Value) error{OutOfMemory}!void {
        var owned = heap.Owned(Value).init(requested);
        defer owned.deinit(self.releases, self.allocator);
        var reservation = try self.reserveStack(2);
        reservation.pushBorrowed(.{ .symbol = .{ .name = module_id } });
        reservation.pushOwned(owned.take());
        std.debug.assert(reservation.complete());
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
    /// whether or not it has loaded. User registration, aliasing, and removal
    /// under one are `'domain`.
    pub fn refuseReservedModule(self: *Fiber, name: intern.ModuleName, provenance: modules.RegistrationProvenance) MachineError!void {
        if (provenance == .standard_library) return;
        if (self.inherited.libraries().find(name) == null) return;
        return self.failFmt(
            .domain,
            "module name `{s}` is reserved for the standard library",
            .{intern.get(intern.moduleId(name))},
        );
    }

    /// A named module lookup as the running activation sees it.
    pub fn moduleLookup(self: *Fiber, name: intern.ModuleName) ModuleLookupCursor {
        return .init(self.inherited.registry, self.inherited.module_snapshot, self.inherited.libraries(), self.current.?.site.registration_provenance, name);
    }

    pub fn publicationRegistry(self: *const Fiber, name: intern.ModuleName, provenance: modules.RegistrationProvenance) *modules.Registry {
        if (provenance == .source and !provenance.source.exports(name)) return provenance.source.registry();
        return self.inherited.registry;
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
    /// Tags the one absent-only publication conflict that an immutable
    /// caller may recover after independently confirming the winner.
    pub fn addErrorDestinationExists(self: *Fiber) void {
        self.pendingFailure().addData(.@"destination-exists", .{ .int = 1 });
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
    pub fn undefinedModule(self: *Fiber, name: u32) MachineError {
        const failure = self.failFmt(.undefined_word, "undefined module `{s}`", .{intern.get(name)});
        self.pendingFailure().addData(.name, .{ .symbol = .{ .name = name } });
        return failure;
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
        // innermost paging floor has returned originals above it.
        if (count > self.stack.items.len - self.floor.guard) return self.requireAcross(count);
    }
    noinline fn requireAcross(self: *Fiber, count: usize) MachineError!void {
        @branchHint(.cold);
        if (!try paging_api.cover(self, count)) return self.failUnderflow(count);
    }
    noinline fn failUnderflow(self: *Fiber, count: usize) MachineError {
        @branchHint(.cold);
        return self.failUnderflowOf(self.activeWordName(), count);
    }
    /// A locals binder that cannot take its values. The reader lowered it into
    /// the reserved `_ll`, which names nothing a program wrote. Opening a
    /// word's body, the binder is that word's arity check, so the word fails
    /// as a primitive would: it is the failing word, and its body activation,
    /// which never got past entry, is not repeated in the trace. Opening any
    /// other quotation, there is no word to blame, and the binding itself is
    /// what fails.
    noinline fn failBinding(self: *Fiber, count: usize) MachineError {
        @branchHint(.cold);
        const current = &self.current.?;
        const owner = current.body_owner;
        self.active_word = owner;
        if (owner == no_word) return self.failUnderflowOf("local binding", count);
        current.traced_word = no_word;
        return self.failUnderflowOf(self.activeWordName(), count);
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
    fn setWorkDriverTraceParent(self: *Fiber, word: intern.TraceWord) void {
        if (self.workDriver()) |driver| driver.trace_parent = word;
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
    /// Whether the words after a numeric operation continue an arithmetic
    /// chain, which then ran in its place.
    pub fn continuesChain(self: *Fiber, operation: idioms.Operation) MachineError!bool {
        return idioms.applyChain(self, operation);
    }
    /// The forms after the dispatching word in its own code, when it was
    /// dispatched from a source position and `count` of them follow. A word
    /// reached any other way (an invocation, a replay) has no phrase after it.
    pub fn followingForms(self: *const Fiber, count: u32) ?FollowingForms {
        const current = self.current orelse return null;
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
        if (self.current.?.nextIndex() >= self.current.?.code.length()) self.current.?.traced_word = no_word;
    }
    /// Traces the pending failure through `word`, the definition whose frame
    /// the failing path elided, unless an inner one already holds it.
    fn setFailureTraceParent(self: *Fiber, word: intern.TraceWord) void {
        if (self.pendingFailureOptional()) |pending| if (pending.trace_parent == null) {
            pending.trace_parent = word;
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
            return self.fail(.cancelled, "unit cancelled");
        }
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
        const effect_tail = self.replaceTailEffectCandidate(quotation);
        const application_tail = self.tailApplicationIndex();
        if (application_tail) |application_index| {
            const frame = &self.frames.items[@backingInt(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(quotation);
        }
        const site = self.current.?.site.applied();
        const inherited_trace = self.suspendCurrent() catch {
            self.releases.releaseHeader(quotation);
            return error.OutOfMemory;
        };
        self.current = .{
            .code = quotation,
            .program = program,
            .position = .{ .source = 0 },
            .site = site,
            .traced_word = inherited_trace,
            .effect_tail = effect_tail,
            .application_tail = application_tail,
            .application_selection = application_tail,
        };
    }

    /// A completion contract follows authored tail control. Generic application
    /// machinery deliberately does not call this helper:
    /// their continuation restarts once per element and must not add a pair of
    /// code-header atomics to that hot path.
    fn replaceTailEffectCandidate(self: *Fiber, code: *Header) ?EffectCheckIndex {
        const current = self.current orelse return null;
        const check_index = current.effect_tail orelse return null;
        if (!self.isSourceTailPosition(current)) return null;
        std.debug.assert(self.effect_check_index == check_index);
        const frame = &self.frames.items[@backingInt(check_index)];
        std.debug.assert(frame.* == .effect_check);
        frame.effect_check.replaceSourceCandidate(self.releases, code);
        return check_index;
    }

    /// Propagates one application's authority through ordinary tail word
    /// dispatch without changing its selected quotation. Only a dynamic
    /// `call` marks code for ownership transfer into the candidate.
    fn tailApplicationIndex(self: *Fiber) ?ApplicationFrameIndex {
        const current = self.current orelse return null;
        const application_index = current.application_tail orelse return null;
        if (!self.isSourceTailPosition(current)) return null;
        return application_index;
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
        const index = self.tailApplicationIndex() orelse return null;
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
    fn retireCompletedEval(self: *Fiber, current: Eval) void {
        if (current.application_selection) |application_index| {
            const frame = &self.frames.items[@backingInt(application_index)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.completeOwned(self.releases, current.intoCode(self.releases));
        } else {
            current.release(self.releases);
        }
    }

    /// Reader-lowered locals end in a `_dl` operation. That cleanup must run
    /// after the authored final form, but it does not make a final control
    /// transfer semantically non-tail. The exact reserved epilogue is the only
    /// continuation shape granted this exception.
    fn isSourceTailPosition(self: *const Fiber, current: Eval) bool {
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
        return self.launchApplication(application, launch, null);
    }
    /// Hands back an isolated application scope. One that never bound and is
    /// unshared is parked for the next application over the same parent rather
    /// than retired; anything else takes the ordinary path.
    fn launchApplication(
        self: *Fiber,
        application: Application,
        launch: Launch,
        inherited: ?intern.TraceWord,
    ) MachineError!void {
        self.require(application.seeded) catch |err| {
            application.discard(self.releases, self.allocator);
            return err;
        };
        const base = StackWindow.init(self.stack.items.len, application.seeded) orelse unreachable;
        const provenance_target: ?ApplicationFrameIndex = switch (application.provenance) {
            .boundary => null,
            .selected_target => |target| self.validateApplicationProvenanceTarget(target) orelse {
                application.discard(self.releases, self.allocator);
                return self.fail(.domain, "application provenance target is stale or foreign");
            },
        };
        const select_initial = application.provenance != .boundary;
        var inherited_trace = inherited orelse no_word;
        if (self.current != null) {
            std.debug.assert(inherited == null);
            inherited_trace = self.suspendCurrent() catch {
                application.discard(self.releases, self.allocator);
                return error.OutOfMemory;
            };
        }
        const application_index: ApplicationFrameIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        var continuation = OwnedFrame.init(.{ .application = .{
            .context = application.context,
            .resume_fn = application.resume_fn,
            .deinit_fn = application.deinit_fn,
            .site = application.site,
            .mode = switch (launch) {
                .in_place => .{ .in_place = base },
                .isolated => .{ .isolated = self.floor.beneath() },
                .paging => |floor| .{ .paging = floor },
            },
            .traced_word = inherited_trace,
            .selection = .{},
            .plan = application.plan,
        } });
        defer continuation.deinit(self.releases, self.allocator);
        try self.appendFrame(&continuation);
        switch (launch) {
            .in_place => {},
            .isolated => self.floor.set(base.base(), null),
            .paging => |floor| self.floor.enter(floor, base.base()),
        }
        if (select_initial) {
            const target = provenance_target.?;
            const frame = &self.frames.items[@backingInt(target)];
            std.debug.assert(frame.* == .application);
            frame.application.selection.selectBorrowed(application.quotation);
        }
        // The combinator state the frame holds keeps the quotation for the
        // whole invocation, so each application borrows it.
        self.current = .{
            .code = application.quotation,
            .program = .borrowed,
            .position = .{ .source = 0 },
            .site = application.site,
            .traced_word = inherited_trace,
            .application_tail = provenance_target orelse application_index,
            .application_selection = if (select_initial) provenance_target else null,
        };
    }
    /// Opens `@attempt`'s boundary on an owned body. Consuming on success and
    /// failure alike.
    pub fn attemptOwned(self: *Fiber, body: *Header) error{OutOfMemory}!void {
        return self.openAttempt(body);
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
    ) MachineError!void {
        return module_construction.begin(.of(self), name, body_header, doc);
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
        const home = candidate.executionHome(self.module_access);
        const site = ExecutionSite.image(home, self.module_access, true);
        _ = self.suspendCurrent() catch {
            self.releases.releaseHeader(body_header);
            return error.OutOfMemory;
        };
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
            .traced_word = no_word,
        };
    }
    /// The context a binding or explicit lookup resolves under, over `view`,
    /// which the context then owns.
    pub fn resolutionContext(self: *Fiber, view: modules.View) binder.Context {
        return .{
            .environment = self.environment,
            .view = view,
            .module_access = self.module_access,
            .registry = self.inherited.registry,
            .project = self.inherited.module_snapshot,
            .libraries = self.inherited.libraries(),
            .provenance = self.current.?.site.registration_provenance,
        };
    }

    /// What a plain word resolves to now, for idiom recognition: the fiber's
    /// remembered resolution when it has one, otherwise a fresh lookup that
    /// is not remembered. Only a static definition outlives the lookup, and
    /// recognition only ever declines, so anything else is simply not a
    /// match.
    pub fn peekWord(self: *Fiber, word: value.Symbol) ?PeekedWord {
        if (binder.executableWord(.{ .symbol = word }) == null) return null;
        if (self.reusedResolution(word)) |definition| return peeked(definition, word);
        return self.resolveFresh(word, false);
    }

    /// `peekWord`, remembering what a fresh lookup resolves, so a word a
    /// recognized phrase consumes instead of dispatching is looked up once
    /// per publication rather than on every recognition.
    pub fn resolveForRecognition(self: *Fiber, word: value.Symbol) error{OutOfMemory}!?PeekedWord {
        if (binder.executableWord(.{ .symbol = word }) == null) return null;
        if (self.reusedResolution(word)) |definition| return peeked(definition, word);
        return try self.resolveFresh(word, true);
    }

    /// Resolves `word` against the current view in one call, remembering the
    /// result when `remember` is set. The definition is inspected before the
    /// lookup's lease is released, since a concurrent replacement may retire
    /// a counted definition afterwards.
    fn resolveFresh(
        self: *Fiber,
        word: value.Symbol,
        comptime remember: bool,
    ) if (remember) error{OutOfMemory}!?PeekedWord else ?PeekedWord {
        var context = self.resolutionContext(self.inherited.registry.view());
        defer context.deinit();
        var resolver = binder.Resolver.init(&context, word);
        defer resolver.deinit();
        const found = switch (poll_api.drive(binder.Outcome, &resolver, .{&context})) {
            .resolved => |definition| definition,
            .missed => return null,
        };
        if (remember) try self.rememberResolution(word, context.view.publication, context.provenance, found);
        return peeked(found, word);
    }

    fn peeked(definition: *env.Definition, word: value.Symbol) ?PeekedWord {
        if (definition.lifetime != .static) return null;
        const home = modules.definitionHome(definition);
        return .{
            .definition = definition,
            .trace_word = definitionTraceWord(definition, home, word.name),
            .origin = definitionOrigin(definition, home),
        };
    }

    /// The plan of the finite iteration applying the running code, when that
    /// code is the combinator's own quotation.
    fn applicationPlan(self: *Fiber) ?*ResolutionPlan {
        const current = &self.current.?;
        const index = current.application_tail orelse return null;
        const plan = switch (self.frames.items[@backingInt(index)]) {
            .application => |application| application.plan orelse return null,
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
            if (operand > self.stack.items.len - self.floor.guard and !try paging_api.cover(self, operand))
                return self.failBinding(operand);
            return self.bindLocals(operand);
        }
        if (name == locals.drop) {
            if (operand > self.locals.items.len) return self.fail(.domain, "_dl count exceeds the live locals");
            return self.unbindLocals(operand);
        }
        return self.fail(.domain, "a locals operand on a word that is not a locals operation");
    }

    /// Runs an occurrence by explicit lookup, against the current publication
    /// view: incremental top-level source, `execute`, and a word resumed after
    /// loading. `dispatch` pushes a quoted occurrence instead, and `execute`
    /// strips the quote before calling here.
    pub fn executeWord(self: *Fiber, word: value.Symbol) MachineError!void {
        std.debug.assert(!env.isQuoted(word.slot));
        if (env.localOperand(word.slot)) |operand| return self.localOperation(word.name, operand);
        self.active_word = .plain(word.name);
        if (self.reusedResolution(word)) |definition| return invokeDefinition(self, definition, word.name);
        const site: ?ErrorSite = if (self.current) |current| .{ .code = current.code, .index = self.active_index } else null;
        try self.startDriver(LookupDispatchDriver{
            .word = word,
            .site = site,
            .context = .init(self.resolutionContext(self.inherited.registry.view())),
            .resolver = .none,
        });
    }

    /// What this fiber last resolved `word` to, if no publication has
    /// happened since. Bootstrap resolves every word afresh, since core's
    /// directory changes without a publication.
    inline fn reusedResolution(self: *Fiber, word: value.Symbol) ?*env.Definition {
        if (self.inherited.phase == .bootstrap) return null;
        return self.resolutions.find(
            word,
            self.inherited.registry.currentPublication(),
            WordResolutions.provenanceKey(self.current.?.site.registration_provenance),
        );
    }

    /// Records what an explicit lookup resolved `word` to.
    fn rememberResolution(self: *Fiber, word: value.Symbol, publication: u64, provenance: modules.RegistrationProvenance, definition: *env.Definition) error{OutOfMemory}!void {
        if (self.inherited.phase == .bootstrap) return;
        return self.resolutions.remember(
            self.allocator,
            self.releases,
            word,
            publication,
            WordResolutions.provenanceKey(provenance),
            definition,
        );
    }

    /// The failure for a word that did not bind and will not after a load.
    pub fn failUnbound(self: *Fiber, word: value.Symbol, miss: binder.Unbound) MachineError {
        self.active_word = .plain(word.name);
        return switch (miss) {
            .unresolved => |chain| self.undefinedWordIn(word.name, chain),
            .retired => self.failRetiredWord(word.name),
            .alias_cycle => self.failFmt(.domain, "the aliases from `{s}` never reach a definition", .{intern.get(word.name)}),
        };
    }

    /// Fails a lookup miss for `word`, starting a module load when one may
    /// make it resolvable. `continuation` says how to resume after the load.
    fn missOrLoad(
        self: *Fiber,
        word: value.Symbol,
        miss: binder.Miss,
        continuation: load.QualifiedLoadContinuation,
    ) MachineError!void {
        self.active_word = .plain(word.name);
        const request = load.QualifiedLoadRequest{
            .qualified = word.name,
            .context = self.current.?.site.registration_provenance,
            .continuation = continuation,
        };
        switch (miss) {
            .unknown_module_prefix => |prefix| try load.prepareQualified(.of(self), prefix, request, .none),
            .unregistered_module => |name| try self.autoLoadModule(name, request),
            .unresolved => |chain| return self.failUnbound(word, .{ .unresolved = chain }),
            .retired => return self.failUnbound(word, .retired),
            .alias_cycle => return self.failUnbound(word, .alias_cycle),
        }
    }

    fn failRetiredWord(self: *Fiber, name: u32) MachineError {
        self.active_word = .plain(name);
        return self.fail(.domain, "the scope this word was written in has retired");
    }

    pub fn raiseOwned(self: *Fiber, raised: Value) MachineError {
        self.installPendingFailure(EclErr.init(.user, "raised error"));
        if (self.active_word != no_word) self.pendingFailure().word = self.active_word;
        self.pendingFailure().raised = raised;
        return error.Ecl;
    }
    /// Opens one `@attempt` boundary. Consuming: the body is owned by the
    /// boundary on success and released here on every failure.
    fn openAttempt(self: *Fiber, body: *Header) error{OutOfMemory}!void {
        const invoker = self.current.?;
        const word = self.active_word;
        _ = self.suspendCurrent() catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        if (self.frames.items.len >= max_frame_count) {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        }
        // The body runs in its invoker's scope with its invoker's right to
        // define. A failure restores the stack, not the environment: like IO,
        // a definition the body made survives it.
        const site = invoker.site.applied();
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
            .traced_word = no_word,
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
        provenance: modules.RegistrationProvenance,
    ) error{OutOfMemory}!void {
        const invoker = self.current.?;
        _ = self.suspendCurrent() catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        if (self.frames.items.len >= max_frame_count) {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        }
        var site = invoker.site.applied();
        site.registration_provenance = provenance;
        try self.openBoundary(.load, @intCast(self.stack.items.len), word, body);
        self.current = .{
            .code = body,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = site,
            .traced_word = no_word,
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
    fn enterRegistration(self: *Fiber, body: *Header, provenance: modules.RegistrationProvenance, after: load.AfterLoad) error{OutOfMemory}!void {
        var continuation = OwnedFrame.init(.{ .qualified_after_load = after });
        defer continuation.deinit(self.releases, self.allocator);
        var site = self.current.?.site.applied();
        site.registration_provenance = provenance;
        _ = (if (after.request.preservesCaller())
            self.suspendCurrentForQualifiedLoad()
        else
            self.suspendCurrent()) catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        self.appendFrame(&continuation) catch {
            self.releases.releaseHeader(body);
            return error.OutOfMemory;
        };
        self.current = .{
            .code = body,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = site,
            .traced_word = no_word,
        };
    }
    fn dispatchAfterLoad(self: *Fiber, word: value.Symbol, site: ?ErrorSite, trace_parent: ?intern.TraceWord, provenance: modules.RegistrationProvenance) error{OutOfMemory}!void {
        self.active_word = .plain(word.name);
        var context = self.resolutionContext(self.inherited.registry.view());
        context.provenance = provenance;
        try self.startDriver(LookupDispatchDriver{
            .word = word,
            .site = site,
            .context = .init(context),
            .resolver = .none,
        });
        if (site) |at| self.setWorkDriverSite(at.code, at.index);
        if (trace_parent) |parent| self.setWorkDriverTraceParent(parent);
    }
    fn replayOperand(self: *Fiber, requested: value.Symbol) error{OutOfMemory}!void {
        try self.pushBorrowed(.{ .symbol = requested });
        self.current.?.rewind(self.active_index);
    }
    fn beginModuleSeal(self: *Fiber) MachineError!*modules.OwnedImage {
        const frame = &self.frames.items[self.frames.items.len - 1].boundary;
        const observed = self.stack.items.len - frame.stack_base;
        if (observed != 0) {
            const boundary = self.popFrame(.boundary);
            self.boundary_index = boundary.previous_boundary;
            self.floor.restore(boundary.beneath);
            self.active_word = boundary.word;
            boundary.deinit();
            return self.failFmt(
                .domain,
                "@defm body left {d} value{s} on its stack; a module body defines words and keeps no state",
                .{ observed, if (observed == 1) "" else "s" },
            );
        }
        self.active_word = frame.word;
        const built = &frame.mode.module.image;
        const home = built.executionHome(self.module_access);
        const placeholder = try list.fromValuesGeneric(self.allocator, &.{});
        self.current = .{
            .code = placeholder.list,
            .program = .owned,
            .position = .{ .source = 0 },
            .site = .image(home, self.module_access, false),
            .traced_word = no_word,
        };
        return built;
    }
    fn closeModuleBoundary(self: *Fiber) modules.OwnedImage {
        releaseCurrent(self);
        const boundary = self.popFrame(.boundary);
        self.boundary_index = boundary.previous_boundary;
        self.floor.restore(boundary.beneath);
        self.active_word = boundary.word;
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
        var invocation = caller;
        invocation.position = .{ .invocation = caller.nextIndex() };
        invocation.traced_word = no_word;
        if (!self.isSourceTailPosition(caller)) {
            invocation.effect_tail = null;
            invocation.application_tail = null;
        }
        // Selection follows the invoked tail quotation. Resuming the caller
        // later must not overwrite that selection with its original body.
        caller.application_selection = null;
        invocation.retainCopy();
        self.frames.appendAssumeCapacity(.{ .eval = caller });
        self.frames.appendAssumeCapacity(.{ .effect_check = check });
        self.noteFrameDepth();
        self.current = invocation;
    }
    /// Suspends a non-tail continuation. An exhausted anonymous quotation
    /// inherits its named trace owner so inline control does not erase the
    /// activation that selected it.
    fn suspendCurrent(self: *Fiber) error{OutOfMemory}!intern.TraceWord {
        const current = &self.current.?;
        if (current.hasInstructions()) {
            // Built in place: an appended frame was a stack temporary copied
            // into the array.
            const frame = try self.frames.addOne(self.allocator);
            frame.* = .{ .eval = current.* };
            self.noteFrameDepth();
            self.current = null;
            return no_word;
        }
        const inherited_trace = current.traced_word;
        self.retireCompletedEval(current.*);
        self.current = null;
        return inherited_trace;
    }
    /// A source-backed module load nests inside the requesting evaluation.
    /// Preserve even an exhausted caller: after publication the qualified
    /// request still needs its resolution scope, home, and continuation, and
    /// only the eventual dispatched word may consume the tail position.
    fn suspendCurrentForQualifiedLoad(self: *Fiber) error{OutOfMemory}!intern.TraceWord {
        const current = self.current.?;
        try self.frames.append(self.allocator, .{ .eval = current });
        self.noteFrameDepth();
        self.current = null;
        return no_word;
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
    heap.incRef(code);
    fiber.current = .{
        .code = code,
        .program = program,
        .position = .{ .source = 0 },
        .site = .root(fiber),
        .traced_word = no_word,
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
    // the previous one already polled cancellation, and every driver polls
    // before it draws.
    fiber.kernel_budget = turn_core.beginTurn(kernel_poll_quantum);
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
                        if (err == error.Ecl) if (driver.trace_parent) |word| self.setFailureTraceParent(word);
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
            self.retireCompletedEval(current.*);
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
        // A word this fiber has resolved in the current publication runs
        // directly; a quoted or lowered occurrence is a form, as is
        // everything else, and an unresolved word resolves when dispatched.
        const dispatched = resolved: {
            const form = formAt(current.code, index);
            if (form == .symbol and form.symbol.slot & (env.quote_flag | env.local_operand_flag) == 0)
                if (self.reusedResolution(form.symbol)) |definition|
                    break :resolved invokeDefinition(self, definition, form.symbol.name);
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
/// Resolves one word against the current view and invokes what it finds.
const LookupDispatchDriver = struct {
    word: value.Symbol,
    site: ?ErrorSite,
    context: heap.Owned(binder.Context),
    resolver: heap.Owned(binder.Resolver),

    /// Started once per explicitly looked-up word, so it uses the inline slot.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;

    fn advance(fiber: *Fiber, self: *LookupDispatchDriver) MachineError!WorkProgress {
        if (!self.resolver.isPresent()) self.resolver = .init(binder.Resolver.init(self.context.borrowMut(), self.word));
        const work = fiber.workBudget();
        while (work.spend()) switch (self.resolver.borrowMut().advance(self.context.borrowMut())) {
            .pending => {},
            .complete => |outcome| {
                const word = self.word;
                switch (outcome) {
                    .resolved => |definition| {
                        // The view keeps a counted definition alive; hold it
                        // across the invocation, which retains what it keeps.
                        const counted = definition.lifetime == .counted;
                        if (counted) definition.retain();
                        defer if (counted) definition.release(fiber.releases);
                        try fiber.rememberResolution(
                            word,
                            self.context.borrow().view.publication,
                            self.context.borrow().provenance,
                            definition,
                        );
                        fiber.retireDriver(self);
                        try invokeDefinition(fiber, definition, word.name);
                        return .detached;
                    },
                    .missed => |miss| {
                        const site = self.site;
                        fiber.retireDriver(self);
                        try fiber.missOrLoad(word, miss, .{ .dispatch = .{ .word = word, .site = site, .trace_parent = null } });
                        return .detached;
                    },
                }
            },
        };
        return .stepped;
    }
};

/// One explicit lookup of a supplied symbol, in the root its link names and
/// against the current view: what reflection and `execute` resolve.
pub const ExplicitLookup = struct {
    context: binder.Context,
    resolver: binder.Resolver,

    pub fn init(fiber: *Fiber, word: value.Symbol) ExplicitLookup {
        const context = fiber.resolutionContext(fiber.inherited.registry.view());
        return .{ .context = context, .resolver = binder.Resolver.init(&context, word) };
    }

    pub fn deinit(self: *ExplicitLookup) void {
        self.resolver.deinit();
        self.context.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *ExplicitLookup) binder.Resolver.Progress {
        return self.resolver.advance(&self.context);
    }
};

/// A definition an explicit lookup selected, held while reflection reads it.
pub const Reflected = struct {
    definition: *env.Definition,
    trace_word: intern.TraceWord,
    home: ?*modules.ModuleHome,
    releases: *heap.ReleaseDomain,

    /// Holds a definition the lookup's view kept alive.
    pub fn hold(fiber: *Fiber, definition: *env.Definition, name: u32) Reflected {
        if (definition.lifetime == .counted) definition.retain();
        const home = modules.definitionHome(definition);
        return .{
            .definition = definition,
            .trace_word = definitionTraceWord(definition, home, name),
            .home = home,
            .releases = fiber.releases,
        };
    }

    pub fn deinit(self: *Reflected) void {
        if (self.definition.lifetime == .counted) self.definition.release(self.releases);
        self.* = undefined;
    }

    /// The core definition this one shadows, if any: what `which` reports.
    pub fn shadows(self: *const Reflected, environment: *env.Env, name: u32) ?intern.TraceWord {
        if (self.definition.root == .core) return null;
        var cursor = environment.coreLookup(@fromBackingInt(name));
        const entry = poll_api.drive(?env.Entry, &cursor, .{}) orelse return null;
        return switch (entry) {
            .definition => |definition| if (definition != self.definition and definition.visibility == .public)
                .plain(name)
            else
                null,
            .alias => null,
        };
    }
};

/// What one definition is, as dispatch and recognition see it.
pub const PeekedWord = struct {
    definition: *env.Definition,
    trace_word: intern.TraceWord,
    origin: ResolutionOrigin,
};

const ResolutionOrigin = enum { direct, module, standard_library, core };

fn definitionOrigin(definition: *const env.Definition, home: ?*const modules.ModuleHome) ResolutionOrigin {
    if (home) |owner| return moduleResolutionOrigin(owner);
    return switch (definition.root) {
        .core => .core,
        .session, .image => .direct,
    };
}

/// How a call names a definition: a module-local one by its home's spelling,
/// anything else by the name the call used.
fn definitionTraceWord(definition: *const env.Definition, home: ?*const modules.ModuleHome, name: u32) intern.TraceWord {
    if (home) |owner| if (definition.traceWord()) |local| return homeTraceWord(owner, local);
    return .plain(name);
}

/// Invokes one fixed target. A module word's declared effect is a contract
/// checked where a call crosses into its module, except a standard-library
/// word's: its effects are reflective metadata, and its arity failures are
/// those of the code it runs.
fn invokeDefinition(self: *Fiber, definition: *env.Definition, name: u32) MachineError!void {
    // A homeless builtin has no effect boundary: the common case, run
    // directly.
    if (definition.home == null) switch (definition.code()) {
        .builtin => |primitive| return invokeBuiltin(self, .plain(name), primitive),
        else => {},
    };
    const home = modules.definitionHome(definition);
    const trace_word = definitionTraceWord(definition, home, name);
    self.active_word = trace_word;
    const origin = definitionOrigin(definition, home);
    const cross_home = if (home) |target|
        target.scope(self.module_access) != self.current.?.scope()
    else
        false;
    const checked = cross_home and origin != .standard_library;
    const cross_home_effect = if (checked) definition.effect else null;
    switch (definition.code()) {
        .source => |executable| try scheduleWord(self, executable, trace_word, home, cross_home_effect),
        .builtin => |primitive| {
            // A declared effect is the called word's contract, so its check
            // names that word; a failure inside the builtin names it too.
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

fn moduleResolutionOrigin(home: *const modules.ModuleHome) ResolutionOrigin {
    return switch (home.registrationProvenance()) {
        .ordinary => .module,
        .standard_library => .standard_library,
        .root_scope, .source => .module,
    };
}

/// How a module-local definition is spelled when reached through `home`: by
/// the name the image was built for, during construction as well as after.
fn homeTraceWord(home: *const modules.ModuleHome, local: intern.BindingName) intern.TraceWord {
    return .moduleLocal(home.name(), local);
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
pub const EmbeddedLibraries = module_lookup.EmbeddedLibraries;
pub const ModuleLookupCursor = module_lookup.ModuleLookupCursor;

fn scheduleWord(
    self: *Fiber,
    executable: *const env.Executable,
    word: intern.TraceWord,
    resolved_home: ?*modules.ModuleHome,
    effect: ?env.Effect,
) MachineError!void {
    // A module word runs as its image; any other word runs at its caller's
    // site. Either way it defines where its caller could, and no further.
    const caller = self.current.?.site;
    const site: ExecutionSite = if (resolved_home) |home|
        .image(home, self.module_access, caller.defining)
    else
        caller;
    const check = if (effect != null) try prepareEffectCheck(self, effect, word) else null;
    return enterBody(self, executable, word, site, check);
}
/// Suspends the caller and makes `executable` the running evaluation at
/// `site`, under its effect check if it has one. The callee's owner is secured
/// before the caller can retire: in tail position the caller's executable may
/// hold the callee's last reference.
fn enterBody(self: *Fiber, executable: *const env.Executable, word: intern.TraceWord, site: ExecutionSite, effect: ?EffectCheck) MachineError!void {
    var check = effect;
    executable.owner().retain();
    var entered = false;
    defer if (!entered) executable.owner().release(self.releases);
    var effect_tail = self.replaceTailEffectCandidate(executable.code());
    const application_tail = self.tailApplicationIndex();
    _ = self.suspendCurrent() catch return error.OutOfMemory;
    if (check) |*effect_check| {
        const check_index: EffectCheckIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.frames.items.len))));
        effect_check.activateSource(executable.code(), check_index, self.effect_check_index);
        var continuation = OwnedFrame.init(.{ .effect_check = effect_check.* });
        defer continuation.deinit(self.releases, self.allocator);
        try self.appendFrame(&continuation);
        self.effect_check_index = check_index;
        effect_tail = check_index;
    }
    entered = true;
    self.current = .{
        .code = executable.code(),
        .program = .{ .definition = executable },
        .position = .{ .source = 0 },
        .site = site,
        .traced_word = word,
        .body_owner = word,
        .effect_tail = effect_tail,
        .application_tail = application_tail,
    };
}
fn prepareEffectCheck(
    self: *Fiber,
    effect: ?env.Effect,
    word: intern.TraceWord,
) MachineError!EffectCheck {
    const declared = effect orelse {
        self.active_word = word;
        return self.fail(.domain, "module word has no effect declaration");
    };
    // Inputs beneath a paging floor count: the word pages them in as
    // originals, like any operand check across the floor.
    if (self.available() < declared.inputs) _ = try paging_api.cover(self, declared.inputs);
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
            const launch: Launch, const base: StackWindow = switch (continuation.mode) {
                .in_place => |window| .{ .in_place, window },
                .isolated => |isolated| blk: {
                    const window: StackWindow = @fromBackingInt(@intCast(@as(u32, @intCast(self.floor.base))));
                    self.floor.restore(isolated);
                    break :blk .{ .isolated, window };
                },
                .paging => |floor| blk: {
                    // The window is the region above the lowered floor; the
                    // driver's finalize reads it with the floor beneath active.
                    const window: StackWindow = @fromBackingInt(@intCast(@as(u32, @intCast(floor.floor))));
                    self.floor.restore(floor.beneath);
                    break :blk .{ .{ .paging = floor }, window };
                },
            };
            if (comptime root_execution_metrics_enabled)
                self.root_execution_metrics.application_resumes += 1;
            const next = continuation.resume_fn(
                self,
                continuation.context,
                base,
                @ptrCast(&application_selection),
            ) catch |err| {
                if (continuation.traced_word != no_word) {
                    self.setFailureTraceParent(continuation.traced_word);
                }
                continuation.deinit_fn(self.releases, self.allocator, continuation.context);
                return err;
            };
            if (next) |step| switch (step) {
                .apply => |application| {
                    try self.launchApplication(.{
                        .quotation = application.quotation,
                        .context = continuation.context,
                        .resume_fn = continuation.resume_fn,
                        .deinit_fn = continuation.deinit_fn,
                        .site = continuation.site,
                        .seeded = application.seeded,
                        .provenance = application.provenance,
                        .plan = continuation.plan,
                    }, application.launch, continuation.traced_word);
                    return true;
                },
                .suspend_inline => |suspension| {
                    const installed = self.workDriver() orelse {
                        continuation.deinit_fn(
                            self.releases,
                            self.allocator,
                            continuation.context,
                        );
                        return self.fail(.domain, "application suspension has no installed work");
                    };
                    // A frame resumed over a paging floor suspends in place:
                    // the floor beneath is active again, and the frame names
                    // the launch of whatever it applies next.
                    if (launch == .isolated or
                        @intFromPtr(suspension) != @intFromPtr(installed.context))
                    {
                        continuation.deinit_fn(
                            self.releases,
                            self.allocator,
                            continuation.context,
                        );
                        clearWorkDriver(self);
                        return self.fail(.domain, "application suspension is stale or foreign");
                    }
                    var suspended = OwnedFrame.init(.{ .application = .{
                        .context = continuation.context,
                        .resume_fn = continuation.resume_fn,
                        .deinit_fn = continuation.deinit_fn,
                        .site = continuation.site,
                        .mode = .{ .in_place = base },
                        .traced_word = continuation.traced_word,
                        .selection = application_selection,
                        .provenance_nonce = continuation.provenance_nonce,
                        .plan = continuation.plan,
                    } });
                    application_selection = .{};
                    defer suspended.deinit(self.releases, self.allocator);
                    try self.appendFrame(&suspended);
                    return true;
                },
            };
            continuation.deinit_fn(self.releases, self.allocator, continuation.context);
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
                // The image stays in its frame until it is sealed: binding the
                // group may load modules, which run above the frame.
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
        try fiber.pollKernel();
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

    /// The image the innermost frame, a construction boundary, is building.
    pub fn image(self: *Construction) *modules.OwnedImage {
        const frames = self.fiber().frames.items;
        return &frames[frames.len - 1].boundary.mode.module.image;
    }

    /// Begins sealing the module whose construction boundary is the top
    /// frame. A module body defines words and keeps no state, so a residual
    /// operand window closes the boundary and fails. Otherwise a placeholder
    /// evaluation at the image's site becomes the caller that a module load
    /// during the seal suspends and returns to.
    pub fn beginSeal(self: *Construction) MachineError!*modules.OwnedImage {
        return self.fiber().beginModuleSeal();
    }

    /// Closes the construction boundary once its group is bound, and returns
    /// the image it held.
    pub fn closeBoundary(self: *Construction) modules.OwnedImage {
        return self.fiber().closeModuleBoundary();
    }
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

    /// The word the running evaluation is traced under, if any.
    pub fn currentTrace(self: *Unwinding) ?intern.TraceWord {
        const current = self.fiber().current orelse return null;
        return if (current.traced_word != no_word) current.traced_word else null;
    }

    /// The word saved frame `index` is traced under, if it is a traced
    /// evaluation.
    pub fn frameTrace(self: *Unwinding, index: usize) ?intern.TraceWord {
        return switch (self.fiber().frames.items[index]) {
            .eval => |frame| if (frame.traced_word != no_word) frame.traced_word else null,
            .effect_check, .application, .qualified_after_load, .boundary => null,
        };
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
            .token => |token| .{ .locating = archive.locateCursor(token.code, token.index) },
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
            beneath: paging_api.Beneath,
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
        fn beneath(self: Target) paging_api.Beneath {
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
