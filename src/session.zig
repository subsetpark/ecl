//! Persistent calculator session with transactional stack units.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const reader = @import("reader.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const native_module = @import("native_module.zig");
const machine = @import("machine.zig");
const prims = @import("prims.zig");
const prelude = @import("prelude.zig");
const idioms = @import("idioms.zig");
const printer = @import("print.zig");
const intern = @import("intern.zig");
const poll = @import("poll.zig");
const reflection = @import("reflection.zig");
const scheduler_api = @import("scheduler.zig");
const console_api = @import("console.zig");
const session_options = @import("session_options");
pub const Value = value.Value;
pub const UnitOutcome = union(enum) {
    ok,
    incomplete: reader.Incomplete,
    err: Value,
};
pub const Config = union(enum) {
    default,
    cooperative,
    worker_pool: usize,

    fn schedulerConfig(self: Config) scheduler_api.Config {
        return switch (self) {
            .default => .{ .worker_pool = default_worker_count },
            .cooperative => .cooperative,
            .worker_pool => |count| .{ .worker_pool = count },
        };
    }
};
pub const default_worker_count: usize = session_options.default_worker_count;

const CompletionBacking = struct {
    allocator: std.mem.Allocator,
    candidates: [][]const u8,
    bytes: []u8,
};

/// Owned rendered completion candidates. Candidate slices borrow from this
/// result and remain valid independently of the Session until `deinit`.
pub const CompletionSet = enum(usize) {
    consumed = 0,
    empty = 1,
    _,

    fn fromBacking(owned: *CompletionBacking) CompletionSet {
        return @enumFromInt(@intFromPtr(owned));
    }
    fn backing(self: CompletionSet) *CompletionBacking {
        std.debug.assert(self != .consumed and self != .empty);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn items(self: CompletionSet) []const []const u8 {
        std.debug.assert(self != .consumed);
        return if (self == .empty) &.{} else self.backing().candidates;
    }
    pub fn deinit(self: *CompletionSet) void {
        if (self.* == .consumed) return;
        if (self.* != .empty) {
            const owned = self.backing();
            const allocator = owned.allocator;
            allocator.free(owned.bytes);
            allocator.free(owned.candidates);
            allocator.destroy(owned);
        }
        self.* = .consumed;
    }
};

const RenderedTextBacking = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
};

/// Opaque owned rendering. Bytes remain valid independently of the Session
/// until `deinit`, while the allocator and reclamation root stay private.
pub const RenderedText = enum(usize) {
    consumed = 0,
    empty = 1,
    _,

    fn fromOwned(allocator: std.mem.Allocator, owned_bytes: []u8) error{OutOfMemory}!RenderedText {
        if (owned_bytes.len == 0) {
            allocator.free(owned_bytes);
            return .empty;
        }
        const owned = allocator.create(RenderedTextBacking) catch |err| {
            allocator.free(owned_bytes);
            return err;
        };
        owned.* = .{ .allocator = allocator, .bytes = owned_bytes };
        return @enumFromInt(@intFromPtr(owned));
    }
    fn backing(self: RenderedText) *RenderedTextBacking {
        std.debug.assert(self != .consumed and self != .empty);
        return @ptrFromInt(@intFromEnum(self));
    }
    pub fn bytes(self: RenderedText) []const u8 {
        std.debug.assert(self != .consumed);
        return if (self == .empty) "" else self.backing().bytes;
    }
    pub fn deinit(self: *RenderedText) void {
        if (self.* == .consumed) return;
        if (self.* != .empty) {
            const owned = self.backing();
            const allocator = owned.allocator;
            allocator.free(owned.bytes);
            allocator.destroy(owned);
        }
        self.* = .consumed;
    }
};

const SessionCore = struct {
    module_access_seal: u8 = 0,
    host_owner: *heap.HostOwner,
    environment: env.Env,
    registry: modules.Registry,
    native_owner: *native_module.Owner,
    stack: std.ArrayList(Value) = .empty,
    archive: spans.SpanArchive,
    output: ?*std.Io.Writer,
    diagnostics: ?*std.Io.Writer,
    host_io: ?std.Io,
    ecl_path: ?[]u8,
    arguments: Value,
    console: console_api.Console,
    scheduler: scheduler_api.Scheduler,
    root_tasks: scheduler_api.TaskScope,
    root_scope: ?*env.Scope = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    requested_exit: ?u8 = null,
    last_max_frames: usize = 0,
    last_polls: u64 = 0,
    idiom_mode: machine.IdiomMode = .automatic,
    native_diagnostics: bool = false,
    last_idiom_hits: u64 = 0,

    fn moduleAccess(self: *const SessionCore) *const modules.ExecutionAccess {
        return @ptrCast(&self.module_access_seal);
    }

    fn allocator(self: *const SessionCore) std.mem.Allocator {
        return self.host_owner.cleanup().allocator();
    }

    fn releaseDomain(self: *const SessionCore) *heap.ReleaseDomain {
        return self.host_owner.domain();
    }
};
comptime {
    heap.requireSingleHostOwner(SessionCore);
}
const OpaqueSessionCore = opaque {};

/// Movable opaque handle for heap-stable runtime state. Mutable environment
/// and registry authority stays behind this handle so every publication turn
/// is coupled to retirement settlement.
pub const Session = enum(usize) {
    consumed = 0,
    _,

    const BlockingMutationTurn = struct {
        scheduler: *scheduler_api.Scheduler,

        fn deinit(self: *BlockingMutationTurn) void {
            self.scheduler.settleRootRetirement();
            self.* = undefined;
        }
    };

    fn coreState(self: *const Session) *SessionCore {
        std.debug.assert(self.* != .consumed);
        const erased: *OpaqueSessionCore = @ptrFromInt(@intFromEnum(self.*));
        return @ptrCast(@alignCast(erased));
    }
    pub fn init(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, null, null, null, null, .default);
    }
    pub fn initWithConfig(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        config: Config,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, null, null, null, null, config);
    }
    /// The output writer must outlive the session.
    pub fn initWithOutput(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: *std.Io.Writer,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, null, null, null, .default);
    }
    pub fn initWithHost(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        io: std.Io,
        output: *std.Io.Writer,
        diagnostics: *std.Io.Writer,
        ecl_path: ?[]const u8,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, diagnostics, io, ecl_path, .default);
    }
    pub fn initWithHostConfig(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        io: std.Io,
        output: *std.Io.Writer,
        diagnostics: *std.Io.Writer,
        ecl_path: ?[]const u8,
        config: Config,
    ) error{OutOfMemory}!Session {
        return initFull(allocator, arguments, output, diagnostics, io, ecl_path, config);
    }
    fn initFull(
        allocator: std.mem.Allocator,
        arguments: []const []const u8,
        output: ?*std.Io.Writer,
        diagnostics: ?*std.Io.Writer,
        host_io: ?std.Io,
        ecl_path: ?[]const u8,
        config: Config,
    ) error{OutOfMemory}!Session {
        const scheduler_config = config.schedulerConfig();
        scheduler_config.validate() catch return error.OutOfMemory;
        const host_owner = try allocator.create(heap.HostOwner);
        host_owner.* = .init(allocator);
        const release_domain = host_owner.domain();
        errdefer {
            host_owner.cleanup().drain();
            allocator.destroy(host_owner);
        }
        var environment = try env.Env.init(host_owner.cleanup());
        errdefer environment.deinit();
        var building = environment.beginCoreBuild();
        try prims.install(&building);
        var registry = try modules.Registry.init(host_owner.cleanup());
        errdefer registry.deinit();
        const native_owner = try native_module.Owner.init(host_owner.cleanup());
        errdefer native_owner.closeCalls().settle().deinit();
        var archive = try spans.SpanArchive.init(host_owner.cleanup());
        errdefer archive.deinit();
        var bootstrap_cancelled: std.atomic.Value(bool) = .init(false);
        prelude.install(host_owner.cleanup(), &building, &registry, &archive, &bootstrap_cancelled) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPrelude => @panic("embedded prelude is invalid"),
        };
        const owned_ecl_path = if (ecl_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned_ecl_path) |path| allocator.free(path);
        var argv = heap.OwnedValue.init(
            release_domain,
            try argumentsValue(allocator, release_domain, arguments),
        );
        errdefer argv.deinit();
        const core = try allocator.create(SessionCore);
        errdefer allocator.destroy(core);
        const scheduler = try scheduler_api.Scheduler.init(host_owner.cleanup(), scheduler_config);
        const root_tasks = scheduler_api.TaskScope.init(scheduler.worker());
        core.* = .{
            .host_owner = host_owner,
            .environment = environment,
            .registry = registry,
            .native_owner = native_owner,
            .archive = archive,
            .output = output,
            .diagnostics = diagnostics,
            .host_io = host_io,
            .ecl_path = owned_ecl_path,
            .arguments = argv.take(),
            .console = console_api.Console.init(output, diagnostics),
            .scheduler = scheduler,
            .root_tasks = root_tasks,
        };
        core.scheduler.attachRetirement();
        return @enumFromInt(@intFromPtr(core));
    }
    pub fn deinit(self: *Session) void {
        const core = self.coreState();
        const allocator = core.allocator();
        const host = core.host_owner.cleanup();
        const closing_native_owner = core.native_owner.closeCalls();
        core.scheduler.deinit(&core.root_tasks);
        if (core.root_scope) |root_scope| root_scope.retire();
        for (core.stack.items) |item| core.releaseDomain().releaseValue(item);
        core.stack.deinit(core.allocator());
        core.releaseDomain().releaseValue(core.arguments);
        if (core.ecl_path) |path| core.allocator().free(path);
        core.registry.deinit();
        core.environment.deinit();
        core.archive.deinit();
        // Environment and registry retirement own native image pins. Drain
        // them while the issuing Owner is still alive, then let that host-only
        // authority tear down descriptors/images and drain their ECL values.
        host.drain();
        const settled_native_owner = closing_native_owner.settle();
        host.drain();
        settled_native_owner.deinit();
        allocator.destroy(core.host_owner);
        allocator.destroy(core);
        self.* = .consumed;
    }
    pub fn runUnit(
        self: *Session,
        source_name: []const u8,
        source: []const u8,
    ) error{OutOfMemory}!UnitOutcome {
        const core = self.coreState();
        var mutation_turn = BlockingMutationTurn{ .scheduler = &core.scheduler };
        defer mutation_turn.deinit();
        if (core.root_scope == null)
            core.root_scope = try core.environment.createSessionRoot(core.allocator());
        var diag: reader.Diag = .{};
        const read_result = reader.read(core.host_owner.cleanup(), source_name, source, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => {
                var parse_error = machine.EclErr.init(.parse, diag.text());
                defer parse_error.retire(core.releaseDomain());
                const location = spans.LocatedSpan{
                    .source_name = source_name,
                    .span = diag.span,
                };
                return .{ .err = try machine.errorValue(
                    core.allocator(),
                    core.releaseDomain(),
                    &parse_error,
                    &.{},
                    location,
                ) };
            },
        };
        switch (read_result) {
            .incomplete => |incomplete| return .{ .incomplete = incomplete },
            .complete => |complete| {
                var parsed = complete;
                defer parsed.deinit();
                return self.executeParsed(parsed.borrow());
            },
        }
    }
    fn executeParsed(
        self: *Session,
        parsed: *reader.Parsed,
    ) error{OutOfMemory}!UnitOutcome {
        const core = self.coreState();
        var root = heap.OwnedValue.init(
            core.releaseDomain(),
            try list.fromValuesGeneric(core.allocator(), parsed.values()),
        );
        defer root.deinit();
        const root_header = root.borrow().list;
        try core.archive.absorb(parsed, root.borrow());
        _ = root.take();
        var checkpoint = try heap.OwnedValueBuffer.init(core.releaseDomain(), core.stack.items.len);
        defer checkpoint.deinit();
        for (core.stack.items) |item| checkpoint.appendBorrowed(item);
        var unit = machine.Unit.init(
            core.allocator(),
            core.releaseDomain(),
            core.moduleAccess(),
            core.stack,
            &core.environment,
            &core.archive,
            core.output,
            core.arguments,
            &core.cancelled,
        );
        unit.inherited = .{
            .registry = &core.registry,
            .native_loader = core.native_owner.loader(),
            .native_diagnostics = core.native_diagnostics,
            .diagnostics = core.diagnostics,
            .console = &core.console,
            .host_io = core.host_io,
            .ecl_path = core.ecl_path,
            .idiom_mode = core.idiom_mode,
            .phrase_recognizer = idioms.tryApply,
        };
        unit.scheduler = core.scheduler.worker();
        unit.task_scope = &core.root_tasks;
        unit.is_root_unit = true;
        unit.execution_scope = core.root_scope.?;
        core.stack = .empty;
        defer {
            core.stack = unit.takeStack();
            core.last_max_frames = unit.max_frames;
            core.last_polls = unit.polls;
            core.requested_exit = unit.exit_status;
            core.last_idiom_hits = unit.idiom_hits;
            unit.deinit();
        }
        core.scheduler.runRoot(&unit, root_header) catch |err| switch (err) {
            error.OutOfMemory => {
                restoreCheckpoint(&unit, checkpoint.values());
                return error.OutOfMemory;
            },
            error.Ecl => {
                restoreCheckpoint(&unit, checkpoint.values());
                return .{ .err = unit.takeError().? };
            },
        };
        return .ok;
    }
    pub fn stackDisplay(self: *const Session) error{OutOfMemory}!RenderedText {
        const core = self.coreState();
        var allocating = std.Io.Writer.Allocating.init(core.allocator());
        defer allocating.deinit();
        var previous_multiline = false;
        for (self.coreState().stack.items, 0..) |item, index| {
            const rendered = try printer.toOwnedDisplayString(core.allocator(), item);
            defer core.allocator().free(rendered);
            const multiline = std.mem.indexOfScalar(u8, rendered, '\n') != null;
            if (index > 0) allocating.writer.writeByte(
                if (previous_multiline or multiline) '\n' else ' ',
            ) catch return error.OutOfMemory;
            allocating.writer.writeAll(rendered) catch return error.OutOfMemory;
            previous_multiline = multiline;
        }
        return .fromOwned(core.allocator(), try allocating.toOwnedSlice());
    }
    pub fn renderValue(self: *const Session, item: Value) error{OutOfMemory}!RenderedText {
        const allocator = self.coreState().allocator();
        return .fromOwned(allocator, try printer.toOwnedString(allocator, item));
    }
    /// Runs one blocking observation turn without exposing environment,
    /// registry, or reclamation authority. The rendered result owns no lease
    /// and can therefore outlive this Session.
    pub fn completionCandidates(
        self: *Session,
        prefix: []const u8,
    ) error{OutOfMemory}!CompletionSet {
        const core = self.coreState();
        var turn = BlockingMutationTurn{ .scheduler = &core.scheduler };
        defer turn.deinit();
        var found = poll.ChunkList(u32).init(core.allocator());
        defer found.retire(core.releaseDomain());

        const dot = firstDot(prefix);
        if (dot) |separator| {
            if (separator == 0 or firstDot(prefix[separator + 1 ..]) != null) return .empty;
            const namespace_bytes = prefix[0..separator];
            const word_prefix = prefix[separator + 1 ..];
            const namespace_id = lookupInterned(namespace_bytes) orelse return .empty;
            if (!validNamespace(namespace_id)) return .empty;
            var acquisition = core.registry.acquireCursor(namespace_id);
            defer acquisition.deinit();
            const maybe_generation = poll.drive(?modules.GenerationLease, &acquisition, .{});
            const generation = maybe_generation orelse return .empty;
            var generation_lease = generation;
            defer generation_lease.deinit();
            var names = generation_lease.publicNameCursor();
            defer names.deinit();
            while (true) switch (names.advance()) {
                .pending => {},
                .complete => break,
                .item => |name| if (std.mem.startsWith(u8, intern.get(name), word_prefix))
                    try found.append(name),
            };
            return materializeCompletion(core.allocator(), &found, namespace_bytes);
        }

        const root: reflection.VisibleNameRoot = if (core.root_scope) |scope|
            .{ .scope = scope }
        else
            .{ .environment = core.environment.sessionView() };
        var visible = reflection.VisibleNameCursor.init(
            root,
            core.environment.coreView(),
            &core.registry,
        );
        defer visible.deinit();
        while (true) switch (visible.advance()) {
            .pending => {},
            .complete => break,
            .item => |name| if (std.mem.startsWith(u8, intern.get(name), prefix))
                try found.append(name),
        };
        var namespaces = core.registry.namespaceCursor();
        defer namespaces.deinit();
        while (true) switch (namespaces.advance()) {
            .pending => {},
            .complete => break,
            .item => |name| {
                const id = intern.namespaceId(name);
                if (std.mem.startsWith(u8, intern.get(id), prefix)) try found.append(id);
            },
        };
        return materializeCompletion(core.allocator(), &found, null);
    }
    pub fn writeOutput(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        return self.coreState().console.writeOutput(bytes, false);
    }
    /// Capabilities the REPL editor is given. It never receives the Session,
    /// the console, a writer, or a byte slice it could turn into a control
    /// sequence; the operations it can perform are the ones on these types.
    ///
    /// Both are rooted in the heap-stable core rather than in this handle,
    /// which is explicitly movable. A capability that captured the handle's
    /// address would dangle the moment the Session value was moved.
    pub fn editorTerminal(self: *const Session) EditorTerminal {
        return @enumFromInt(@intFromEnum(self.*));
    }
    pub fn completionObserve(self: *const Session) CompletionObserve {
        return @enumFromInt(@intFromEnum(self.*));
    }
    /// Releases a value returned by this Session into its reclamation domain.
    /// The value must not be used afterward; traversal remains scheduler-owned.
    pub fn release(self: *Session, item: Value) void {
        self.coreState().releaseDomain().releaseValue(item);
    }
    pub fn stackItems(self: *const Session) []const Value {
        return self.coreState().stack.items;
    }
    pub fn pushBorrowed(self: *Session, item: Value) error{OutOfMemory}!void {
        const core = self.coreState();
        heap.retainValue(item);
        core.stack.append(core.allocator(), item) catch |err| {
            core.releaseDomain().releaseValue(item);
            return err;
        };
    }
    pub fn pushOwned(self: *Session, item: Value) error{OutOfMemory}!void {
        const core = self.coreState();
        core.stack.append(core.allocator(), item) catch |err| {
            core.releaseDomain().releaseValue(item);
            return err;
        };
    }
    pub fn requestCancellation(self: *Session) void {
        self.coreState().cancelled.store(true, .release);
    }
    pub fn clearCancellation(self: *Session) void {
        self.coreState().cancelled.store(false, .release);
    }
    pub fn setIdiomMode(self: *Session, mode: machine.IdiomMode) void {
        self.coreState().idiom_mode = mode;
    }
    pub fn setNativeDiagnostics(self: *Session, enabled: bool) void {
        self.coreState().native_diagnostics = enabled;
    }
    pub fn requestedExit(self: *const Session) ?u8 {
        return self.coreState().requested_exit;
    }
    pub fn lastMaxFrames(self: *const Session) usize {
        return self.coreState().last_max_frames;
    }
    pub fn lastPolls(self: *const Session) u64 {
        return self.coreState().last_polls;
    }
    pub fn lastIdiomHits(self: *const Session) u64 {
        return self.coreState().last_idiom_hits;
    }
    pub fn writeOutputLine(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        return self.coreState().console.writeOutput(bytes, true);
    }
    pub fn writeDiagnostics(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        return self.coreState().console.writeDiagnostics(bytes, false);
    }
    pub fn writeDiagnosticsLine(self: *Session, bytes: []const u8) error{WriteFailed}!void {
        return self.coreState().console.writeDiagnostics(bytes, true);
    }
    pub fn define(
        self: *Session,
        name: intern.NamespaceName,
        publication: env.TopPublication,
    ) error{OutOfMemory}!void {
        const core = self.coreState();
        var mutation_turn = BlockingMutationTurn{ .scheduler = &core.scheduler };
        defer mutation_turn.deinit();
        return core.environment.define(name, publication);
    }
    pub fn schedulerWorkerThreadCount(self: *const Session) usize {
        return self.coreState().scheduler.workerThreadCount();
    }
    pub fn schedulerTimerThreadCount(self: *const Session) usize {
        return self.coreState().scheduler.timerThreadCount();
    }
    pub fn schedulerTimerEntryCount(self: *Session) usize {
        return self.coreState().scheduler.timerEntryCount();
    }
};

/// Terminal authority for the line editor: prompts, named effects, candidate
/// lists, and — only where the row can actually be measured — single-row
/// redraw. There is no operation that emits program output or accepts
/// caller-supplied control bytes, so their absence is a fact about the type
/// rather than a rule someone has to remember.
///
/// The payload is the heap-stable core, which is what makes the capability
/// outlive moves of the Session handle that minted it.
pub const EditorTerminal = enum(usize) {
    _,

    fn owner(self: EditorTerminal) Session {
        return @enumFromInt(@intFromEnum(self));
    }
    /// Single-row editing needs a measured row. Null means the caller must use
    /// the canonical reader; no width is ever invented on its behalf.
    pub fn row(self: EditorTerminal) ?RowTerminal {
        return switch (console_api.geometry()) {
            .known => |columns| .{ .terminal = self, .columns = columns },
            .unavailable => null,
        };
    }
    pub fn writePrompt(self: EditorTerminal, prompt: console_api.Prompt) error{WriteFailed}!void {
        var session = self.owner();
        return session.coreState().console.writePrompt(prompt);
    }
    pub fn signal(self: EditorTerminal, action: console_api.TerminalAction) error{WriteFailed}!void {
        var session = self.owner();
        return session.coreState().console.signal(action);
    }
    pub fn writeCandidates(
        self: EditorTerminal,
        candidates: []const []const u8,
    ) error{WriteFailed}!void {
        var session = self.owner();
        return session.coreState().console.writeCandidates(candidates);
    }
};

/// Row drawing, reachable only from a measured row width.
pub const RowTerminal = struct {
    terminal: EditorTerminal,
    columns: console_api.Columns,

    pub fn redraw(
        self: RowTerminal,
        prompt: console_api.Prompt,
        view: console_api.DisplayView,
    ) error{WriteFailed}!void {
        var session = self.terminal.owner();
        return session.coreState().console.redraw(self.columns, prompt, view);
    }
};

/// Name observation for completion. It can render matching names and nothing
/// else: no environment, registry, intern, or reclamation authority.
pub const CompletionObserve = enum(usize) {
    _,

    pub fn candidates(
        self: CompletionObserve,
        prefix: []const u8,
    ) error{OutOfMemory}!CompletionSet {
        var session: Session = @enumFromInt(@intFromEnum(self));
        return session.completionCandidates(prefix);
    }
};

const SessionAuthorityPosition = enum { parameter, result };

fn sessionTypeExposesAuthority(
    comptime T: type,
    comptime depth: u8,
    comptime position: SessionAuthorityPosition,
) bool {
    if (T == env.BindingLease or T == modules.GenerationLease) return true;
    if (position == .result and
        (T == std.mem.Allocator or
            T == std.Io or
            T == std.Io.Writer or
            T == SessionCore or
            T == OpaqueSessionCore or
            T == heap.HostOwner or
            T == heap.ReleaseDomain or
            T == env.Env or
            T == env.EnvironmentView or
            T == modules.Registry or
            T == machine.Unit or
            T == scheduler_api.Scheduler or
            T == console_api.Console))
        return true;
    if (depth == 0) return false;
    return switch (@typeInfo(T)) {
        .optional => |optional| sessionTypeExposesAuthority(optional.child, depth - 1, position),
        .pointer => |pointer| sessionTypeExposesAuthority(pointer.child, depth - 1, position),
        .array => |array| sessionTypeExposesAuthority(array.child, depth - 1, position),
        .vector => |vector| sessionTypeExposesAuthority(vector.child, depth - 1, position),
        .error_union => |error_union| sessionTypeExposesAuthority(error_union.payload, depth - 1, position),
        .@"struct" => |structure| exposed: {
            inline for (structure.fields) |field|
                if (sessionTypeExposesAuthority(field.type, depth - 1, position)) break :exposed true;
            break :exposed false;
        },
        .@"union" => |union_info| exposed: {
            inline for (union_info.fields) |field|
                if (sessionTypeExposesAuthority(field.type, depth - 1, position)) break :exposed true;
            break :exposed false;
        },
        else => false,
    };
}

comptime {
    @setEvalBranchQuota(4_000);
    for (std.meta.declarations(Session)) |declaration| {
        const declaration_info = @typeInfo(@TypeOf(@field(Session, declaration.name)));
        if (declaration_info != .@"fn") continue;
        const function = declaration_info.@"fn";
        for (function.params) |parameter| {
            const parameter_type = parameter.type orelse continue;
            if (sessionTypeExposesAuthority(parameter_type, 8, .parameter))
                @compileError("public Session parameter exposes owner authority: " ++ declaration.name);
        }
        const return_type = function.return_type orelse continue;
        if (sessionTypeExposesAuthority(return_type, 8, .result))
            @compileError("public Session return exposes owner authority: " ++ declaration.name);
    }
}

fn firstDot(bytes: []const u8) ?usize {
    var cursor = intern.dotCursor(bytes);
    return poll.drive(?usize, &cursor, .{});
}

fn lookupInterned(bytes: []const u8) ?u32 {
    var cursor = intern.lookupCursor(bytes);
    return poll.drive(?u32, &cursor, .{});
}

fn validNamespace(id: u32) bool {
    var cursor = intern.NamespaceCursor.init(id);
    return poll.drive(?intern.NamespaceName, &cursor, .{}) != null;
}

fn materializeCompletion(
    allocator: std.mem.Allocator,
    found: *poll.ChunkList(u32),
    qualifier: ?[]const u8,
) error{OutOfMemory}!CompletionSet {
    if (found.count == 0) return .empty;
    const names = try allocator.alloc(u32, found.count);
    defer allocator.free(names);
    var iterator = found.iterator();
    var index: usize = 0;
    while (iterator.next()) |name| : (index += 1) names[index] = name.*;
    if (names.len > 1) {
        var sorter = try reflection.NameSortCursor.init(allocator, names);
        defer sorter.deinit();
        while (sorter.advance(256) == .pending) {}
    }
    var unique_count: usize = 0;
    var byte_count: usize = 0;
    var previous: ?u32 = null;
    for (names) |name| {
        if (previous != null and previous.? == name) continue;
        previous = name;
        unique_count += 1;
        byte_count = std.math.add(usize, byte_count, intern.get(name).len) catch
            return error.OutOfMemory;
        if (qualifier) |namespace| {
            byte_count = std.math.add(usize, byte_count, namespace.len + 1) catch
                return error.OutOfMemory;
        }
    }
    const backing = try allocator.create(CompletionBacking);
    errdefer allocator.destroy(backing);
    const candidates = try allocator.alloc([]const u8, unique_count);
    errdefer allocator.free(candidates);
    const bytes = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(bytes);
    var written: usize = 0;
    var candidate_index: usize = 0;
    previous = null;
    for (names) |name| {
        if (previous != null and previous.? == name) continue;
        previous = name;
        const start = written;
        if (qualifier) |namespace| {
            @memcpy(bytes[written..][0..namespace.len], namespace);
            written += namespace.len;
            bytes[written] = '.';
            written += 1;
        }
        const atom = intern.get(name);
        @memcpy(bytes[written..][0..atom.len], atom);
        written += atom.len;
        candidates[candidate_index] = bytes[start..written];
        candidate_index += 1;
    }
    backing.* = .{ .allocator = allocator, .candidates = candidates, .bytes = bytes };
    return .fromBacking(backing);
}

fn restoreCheckpoint(unit: *machine.Unit, checkpoint: []const Value) void {
    unit.restoreStackBorrowedAssumeCapacity(checkpoint);
}
fn argumentsValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    arguments: []const []const u8,
) error{OutOfMemory}!Value {
    const items = try allocator.alloc(Value, arguments.len);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |item| releases.releaseValue(item);
    for (arguments) |argument| {
        items[initialized] = try machine.stringValue(allocator, releases, argument);
        initialized += 1;
    }
    return list.fromValuesGeneric(allocator, items);
}
fn dictSymbol(
    allocator: std.mem.Allocator,
    dictionary: Value,
    name: []const u8,
) ![]const u8 {
    const dict = @import("dict.zig");
    const key = try intern.intern(name);
    const found = (try dict.symbolField(allocator, dictionary, key)).?;
    return intern.get(found.symbol);
}
test "session runs the soul test" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("<test>", "3 4 +")) == .ok);
    var display = try session.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("7", display.bytes());
}
test "failed units roll back stack while definitions survive" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("<test>", "10")) == .ok);
    const failed = (try session.runUnit("<test>", "(2 *) 'double def 20 + missing")).err;
    session.release(failed);
    try std.testing.expectEqual(@as(usize, 1), session.stackItems().len);
    try std.testing.expectEqual(@as(i64, 10), session.stackItems()[0].int);
    const consumed = (try session.runUnit("<test>", "pop missing")).err;
    session.release(consumed);
    try std.testing.expectEqual(@as(usize, 1), session.stackItems().len);
    try std.testing.expectEqual(@as(i64, 10), session.stackItems()[0].int);
    try std.testing.expect((try session.runUnit("<test>", "double")) == .ok);
    try std.testing.expectEqual(@as(i64, 20), session.stackItems()[0].int);
}
test "parse diagnostics become parse error dicts" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    const error_value = (try session.runUnit("broken.ecl", "1 ]")).err;
    defer session.release(error_value);
    try std.testing.expectEqualStrings("parse", try dictSymbol(allocator, error_value, "kind"));
}
test "source-defined failures retain provenance after their unit" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, &.{});
    defer session.deinit();
    try std.testing.expect((try session.runUnit("defs.ecl", "(1 0 /) 'boom def")) == .ok);
    const error_value = (try session.runUnit("call.ecl", "boom")).err;
    defer session.release(error_value);
    const rendered = try printer.toOwnedString(allocator, error_value);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"defs.ecl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'word '/") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "'trace ['/ 'boom]") != null);
    const runtime_error = (try session.runUnit(
        "assembled.ecl",
        "1 0 (/) cons cons call",
    )).err;
    defer session.release(runtime_error);
    const runtime_rendered = try printer.toOwnedString(allocator, runtime_error);
    defer allocator.free(runtime_rendered);
    try std.testing.expect(std.mem.indexOf(u8, runtime_rendered, "'source") == null);
}
