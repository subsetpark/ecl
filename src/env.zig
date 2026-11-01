//! Definitions, sealed executables, name directories, and scope links.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const heap = @import("heap.zig");
const poll = @import("poll.zig");
const lexer = @import("lexer.zig");
const list = @import("list.zig");
const intern = @import("intern.zig");
const machine = @import("machine.zig");
const idioms = @import("idioms.zig");
const native_module = @import("native_module.zig");
const reader_types = @import("reader_types.zig");
/// In-tree primitives use Unit's ergonomic error helpers. This binding
/// kind is not part of the native-extension ABI.
pub const PrimitiveImpl = *const fn (*machine.Unit) machine.MachineError!void;

/// A native definition together with the nominal image pin that owns its
/// callback. Only the loader can construct the opaque `ModuleInstance`.
pub const NativeCallable = struct {
    instance: *native_module.ModuleInstance,
    definition: u32,
};

pub const Quotation = opaque {};
pub const DocumentationString = opaque {};
pub const EffectQuotation = opaque {};

pub fn quotation(header: *value.ListHandle) ?*Quotation {
    return switch (header.kind()) {
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .dict, .task, .port, .address, .reserved_mask => null,
    };
}

pub fn quotationHeader(body: *const Quotation) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(body)));
}

pub fn documentation(header: *value.ListHandle) ?*DocumentationString {
    return switch (header.kind()) {
        .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .dict, .task, .port, .address, .reserved_mask => null,
    };
}

pub fn documentationHeader(document: *const DocumentationString) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(document)));
}

pub const Visibility = enum { public, private };
/// Where a definition was published. A module definition records only its own
/// module-local name: the image it belongs to has no canonical name, and the
/// registration through which a call reached it is what supplies the qualified
/// spelling and the live state. Baking a name here would make one image
/// unregisterable twice; baking a slot here would put a cycle in the value
/// heap.
pub const BindingOrigin = union(enum) {
    top,
    module_local: struct { trace_word: intern.BindingName },

    pub fn traceWord(self: BindingOrigin) ?intern.BindingName {
        return switch (self) {
            .top => null,
            .module_local => |local| local.trace_word,
        };
    }
};
pub const ValidatedEffect = struct {
    quotation: *EffectQuotation,
    inputs: u32,
    outputs: u32,
    /// The after portion is the anonymous row token rather than named slots:
    /// the before row is checked at boundaries, the after row is not.
    row: bool = false,
    pub fn header(self: ValidatedEffect) *value.ListHandle {
        return @ptrCast(@alignCast(self.quotation));
    }
    pub fn retain(self: ValidatedEffect) void {
        heap.incRef(self.header());
    }
    pub fn retire(self: ValidatedEffect, releases: *heap.ReleaseDomain) void {
        releases.releaseHeader(self.header());
    }
    pub fn fromValidated(effect_header: *value.ListHandle, separator_index: usize) ValidatedEffect {
        std.debug.assert(effect_header.kind() == .generic_spine and separator_index < effect_header.length());
        return .{
            .quotation = @ptrCast(@alignCast(effect_header)),
            .inputs = @intCast(separator_index),
            .outputs = @intCast(@as(usize, @intCast(effect_header.length())) - separator_index - 1),
            .row = isRowEffect(effect_header, separator_index),
        };
    }
    /// The after portion is the row token exactly when it is that one word.
    pub fn isRowEffect(effect_header: *value.ListHandle, separator_index: usize) bool {
        const count: usize = @intCast(effect_header.length());
        if (count != separator_index + 2) return false;
        const after = list.atUnchecked(.{ .list = effect_header }, separator_index + 1);
        return after == .symbol and std.mem.eql(u8, intern.get(after.symbol.name), lexer.row_token);
    }
    pub const ParseProgress = poll.Progress(?ValidatedEffect);
    pub const ParseCursor = struct {
        header: *value.ListHandle,
        separator: u32,
        index: usize = 0,
        split: ?usize = null,
        pub fn advance(self: *ParseCursor) ParseProgress {
            if (self.header.kind() != .generic_spine) return .{ .complete = null };
            const count: usize = @intCast(self.header.length());
            if (self.index == count) {
                const split = self.split orelse return .{ .complete = null };
                return .{ .complete = .{
                    .quotation = @ptrCast(@alignCast(self.header)),
                    .inputs = @intCast(split),
                    .outputs = @intCast(count - split - 1),
                    .row = isRowEffect(self.header, split),
                } };
            }
            const atom = list.atUnchecked(.{ .list = self.header }, self.index);
            if (atom != .symbol) return .{ .complete = null };
            if (atom.symbol.name == self.separator) {
                if (self.split != null) return .{ .complete = null };
                self.split = self.index;
            }
            self.index += 1;
            return .pending;
        }
    };
    pub fn parse(effect_header: *value.ListHandle, separator: u32) ?ValidatedEffect {
        var cursor = ParseCursor{ .header = effect_header, .separator = separator };
        return poll.drive(?ValidatedEffect, &cursor, .{});
    }
};
pub const Effect = ValidatedEffect;

/// One word of a builtin-backed module: a host primitive published under a
/// module name. The metadata is authored as plain text because these modules
/// are compiled in and therefore have no loader descriptor to carry it.
/// Slots either side of `--` in a builtin word's declared effect. Fixed
/// because these effects are fixed compiled-in text outside the user-data path.
pub const max_builtin_effect_tokens: usize = 16;

pub const BuiltinWord = struct {
    name: []const u8,
    /// Required: the repository holds module words to a documentation policy
    /// even though M11 made annotations optional as language semantics.
    doc: []const u8,
    /// Slot names either side of `--`, when the successful effect is fixed.
    /// Module invocation checks include deferred work; callback return is not
    /// the completion boundary.
    effect: ?[]const u8 = null,
    primitive: PrimitiveImpl,
};

pub fn assertStaticBuiltin(comptime word: BuiltinWord) void {
    assertStaticNamespace(word.name);
    if (word.doc.len == 0) @compileError("empty builtin documentation: " ++ word.name);
    if (word.effect) |effect| validateBuiltinEffect(word.name, effect);
}

fn validateBuiltinEffect(comptime name: []const u8, comptime effect: []const u8) void {
    if (effect.len == 0 or effect[0] == ' ' or effect[effect.len - 1] == ' ') {
        @compileError("invalid primitive effect: " ++ name);
    }
    for (effect[1..], effect[0 .. effect.len - 1]) |byte, previous| {
        if (byte == ' ' and previous == ' ') @compileError("invalid primitive effect spacing: " ++ name);
    }
    var separators: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, effect, ' ');
    while (iterator.next()) |token| separators += @intFromBool(std.mem.eql(u8, token, "--"));
    if (separators != 1) @compileError("primitive effect requires exactly one separator: " ++ name);
}

pub const ModulePublication = union(enum) {
    word: struct {
        body: *Quotation,
        source: ?reader_types.SourceSlice = null,
        visibility: Visibility,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
    },
    native: struct {
        callable: NativeCallable,
        visibility: Visibility,
        effect: ValidatedEffect,
        doc: *DocumentationString,
    },
    /// A primitive published as a module word. `Binding` already had this
    /// arm; only the publication typestate was missing, which is why a
    /// primitive-backed module was unrepresentable.
    builtin: struct {
        primitive: PrimitiveImpl,
        visibility: Visibility,
        effect: ?ValidatedEffect = null,
        doc: *DocumentationString,
    },
};

/// What a trusted definition's body was recognized as, decided once when its
/// group sealed. A sealed body's targets cannot change, so the outcome is a
/// property of the definition; only whether a particular call's operands
/// admit it is left to that call. `env` stores the record for the recognizer
/// that produced it and does not interpret it.
pub const DirectIdiom = struct {
    entry: u16,
    /// Borrowed from the body, which the binding retains.
    constant: ?value.Value = null,
    active_word: ?u32 = null,
    active_index: ?u32 = null,
};

/// Who keeps a definition alive. Core definitions live as long as the `Env`;
/// a module image's definitions live as long as the image, which the Session
/// keeps until teardown once it is published. A top-level session definition
/// is the one counted kind: replacement can make it unreachable from the
/// directory while bound code, frames, and caches still hold it.
pub const Lifetime = enum { static, counted };

/// Where a definition's body was written: its activation resolves runtime
/// names and lands nested definitions there.
pub const DefinitionRoot = enum { core, session, image };

/// One immutable target. Construction reserves the identity before its body
/// is bound, so a body may call itself (and a module group's members one
/// another); sealing replaces `reserved` with the bound executable. A reserved
/// definition is reachable only through its construction owner and is never
/// executed or published.
pub const Definition = struct {
    retirement: heap.ReleaseDomain.Retirement = .{},
    refs: std.atomic.Value(u32) = .init(1),
    allocator: std.mem.Allocator,
    lifetime: Lifetime,
    body: Body,
    visibility: Visibility = .public,
    origin: BindingOrigin = .top,
    effect: ?ValidatedEffect = null,
    doc: ?*DocumentationString = null,
    source: ?reader_types.SourceSlice = null,
    direct_idiom: ?DirectIdiom = null,
    root: DefinitionRoot,
    /// The module image the definition belongs to, as `modules` names it.
    /// Opaque here: `env` never dereferences it.
    home: ?*anyopaque = null,
    /// Retirement progress over the bound body's dependencies.
    retiring: usize = 0,

    pub const Body = union(enum) {
        /// The quotation awaiting binding, retained by the definition.
        reserved: *value.ListHandle,
        source: Executable,
        builtin: PrimitiveImpl,
        native: NativeCallable,
    };

    pub const Metadata = struct {
        visibility: Visibility = .public,
        origin: BindingOrigin = .top,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
        source: ?reader_types.SourceSlice = null,
        root: DefinitionRoot,
        home: ?*anyopaque = null,
    };

    /// A definition owning one reference to each metadata value and to a
    /// reserved body. `body` is retained here; the caller keeps its own.
    pub fn create(
        allocator: std.mem.Allocator,
        lifetime: Lifetime,
        body: Body,
        metadata: Metadata,
    ) error{OutOfMemory}!*Definition {
        const result = try allocator.create(Definition);
        switch (body) {
            .reserved => |header| heap.incRef(header),
            .builtin => {},
            .native => |callable| callable.instance.retain(),
            .source => unreachable,
        }
        if (metadata.effect) |effect| effect.retain();
        if (metadata.doc) |doc| heap.incRef(documentationHeader(doc));
        if (metadata.source) |source| source.retain();
        result.* = .{
            .allocator = allocator,
            .lifetime = lifetime,
            .body = body,
            .visibility = metadata.visibility,
            .origin = metadata.origin,
            .effect = metadata.effect,
            .doc = metadata.doc,
            .source = metadata.source,
            .root = metadata.root,
            .home = metadata.home,
        };
        return result;
    }

    /// The quotation a reserved definition awaits binding for.
    pub fn reservedBody(self: *const Definition) *value.ListHandle {
        return self.body.reserved;
    }

    /// Seals a reserved definition with its bound body. The executable owns
    /// its targets' references; the reserved quotation's reference passes to
    /// the executable's code, which binding retained separately.
    pub fn seal(self: *Definition, releases: *heap.ReleaseDomain, bound: Executable.Parts) void {
        const reserved = self.body.reserved;
        self.body = .{ .source = .{
            .code = bound.code,
            .targets = bound.targets,
            .dependencies = bound.dependencies,
            .owner = switch (self.lifetime) {
                .static => .static,
                .counted => .{ .definition = self },
            },
        } };
        releases.releaseHeader(reserved);
    }

    /// The source quotation a definition's body is shown as.
    pub fn quotationBody(self: *const Definition) ?*value.ListHandle {
        return switch (self.body) {
            .reserved => |header| header,
            .source => |executable| executable.code,
            .builtin, .native => null,
        };
    }

    pub fn traceWord(self: *const Definition) ?intern.BindingName {
        return self.origin.traceWord();
    }

    pub fn retain(self: *Definition) void {
        std.debug.assert(self.lifetime == .counted);
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    /// Drops one counted reference; the last schedules bounded retirement.
    pub fn release(self: *Definition, releases: *heap.ReleaseDomain) void {
        std.debug.assert(self.lifetime == .counted);
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        releases.retire(self, &self.retirement);
    }

    /// Retires a static definition with its owning table.
    pub fn retireStatic(self: *Definition, releases: *heap.ReleaseDomain) void {
        std.debug.assert(self.lifetime == .static);
        releases.retire(self, &self.retirement);
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Definition,
    ) bool {
        switch (self.body) {
            .source => |*executable| if (self.retiring < executable.dependencies.len) {
                // A self-call is never a dependency, so this walk cannot
                // reach the definition it retires.
                executable.dependencies[self.retiring].release(releases);
                self.retiring += 1;
                return false;
            },
            else => {},
        }
        switch (self.body) {
            .reserved => |header| releases.releaseHeader(header),
            .source => |executable| executable.freeParts(releases, allocator),
            .builtin => {},
            .native => |callable| callable.instance.releasePin(),
        }
        if (self.effect) |effect| effect.retire(releases);
        if (self.doc) |doc| releases.releaseHeader(documentationHeader(doc));
        if (self.source) |source| {
            var owned = source;
            owned.deinit();
        }
        allocator.destroy(self);
        return true;
    }
};

/// What a running activation must hold to keep its executable's targets valid.
/// A static owner needs nothing. A counted definition or an anonymous
/// executable is retained by each activation running it and released when the
/// activation ends; a tail call secures the callee's owner before the caller's
/// is released.
pub const Owner = union(enum) {
    static,
    definition: *Definition,
    anonymous: *AnonymousCode,

    pub fn retain(self: Owner) void {
        switch (self) {
            .static => {},
            .definition => |definition| definition.retain(),
            .anonymous => |code| code.retain(),
        }
    }

    pub fn release(self: Owner, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .static => {},
            .definition => |definition| definition.release(releases),
            .anonymous => |code| code.release(releases),
        }
    }

    pub fn eql(self: Owner, other: Owner) bool {
        return switch (self) {
            .static => other == .static,
            .definition => |definition| other == .definition and other.definition == definition,
            .anonymous => |code| other == .anonymous and other.anonymous == code,
        };
    }
};

/// A sealed quotation. Its code keeps the literals and source provenance; the
/// target table gives each top-level unquoted word the definition it was bound
/// to. Positions that push a value, quoted symbols, and lowered locals
/// operations have no target. A quotation without executable words has an
/// empty table. Dispatch borrows targets; the executable holds one reference
/// for every counted target in `dependencies`, so dispatch adds no ownership
/// operation of its own.
pub const Executable = struct {
    code: *value.ListHandle,
    targets: []?*Definition,
    dependencies: []*Definition,
    owner: Owner,

    /// What binding produces: the retained code, the target table, and the
    /// references the table holds.
    pub const Parts = struct {
        code: *value.ListHandle,
        targets: []?*Definition,
        dependencies: []*Definition,

        /// Releases parts that were never sealed into an owner.
        pub fn discard(self: Parts, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
            for (self.dependencies) |dependency| dependency.release(releases);
            const executable: Executable = .{
                .code = self.code,
                .targets = self.targets,
                .dependencies = self.dependencies,
                .owner = .static,
            };
            executable.freeParts(releases, allocator);
        }
    };

    /// The definition bound at `index`, or null when the form there is data.
    pub fn target(self: *const Executable, index: u32) ?*Definition {
        if (self.targets.len == 0) return null;
        return self.targets[index];
    }

    fn freeParts(self: Executable, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.targets.len != 0) allocator.free(self.targets);
        if (self.dependencies.len != 0) allocator.free(self.dependencies);
        releases.releaseHeader(self.code);
    }
};

/// The counted owner of an executable bound for an anonymous application.
pub const AnonymousCode = struct {
    retirement: heap.ReleaseDomain.Retirement = .{},
    refs: std.atomic.Value(u32) = .init(1),
    executable: Executable,
    retiring: usize = 0,

    /// Seals bound parts as an anonymous executable with one reference.
    pub fn create(allocator: std.mem.Allocator, parts: Executable.Parts) error{OutOfMemory}!*AnonymousCode {
        const result = try allocator.create(AnonymousCode);
        result.* = .{ .executable = .{
            .code = parts.code,
            .targets = parts.targets,
            .dependencies = parts.dependencies,
            .owner = .static,
        } };
        result.executable.owner = .{ .anonymous = result };
        return result;
    }

    pub fn retain(self: *AnonymousCode) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    pub fn release(self: *AnonymousCode, releases: *heap.ReleaseDomain) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        releases.retire(self, &self.retirement);
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *AnonymousCode,
    ) bool {
        if (self.retiring < self.executable.dependencies.len) {
            self.executable.dependencies[self.retiring].release(releases);
            self.retiring += 1;
            return false;
        }
        self.executable.freeParts(releases, allocator);
        allocator.destroy(self);
        return true;
    }
};

/// A name's entry in a directory: a definition, or a name alias that every
/// later binding or lookup follows through the registry. An alias freezes the
/// mapping, never the target it selects.
pub const Entry = union(enum) {
    definition: *Definition,
    alias: Alias,

    pub fn retain(self: Entry) void {
        switch (self) {
            .definition => |definition| if (definition.lifetime == .counted) definition.retain(),
            .alias => {},
        }
    }

    pub fn release(self: Entry, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .definition => |definition| if (definition.lifetime == .counted) definition.release(releases),
            .alias => {},
        }
    }
};

/// `name -> module.binding`, followed at every binding or lookup.
pub const Alias = struct {
    module: intern.ModuleName,
    binding: intern.BindingName,
    visibility: Visibility = .public,
};

/// A directory of names. Session and image directories are immutable once
/// readers can reach them; core's is filled only while it is being built.
pub const NameMap = poll.FixedMap(intern.BindingName, Entry);

const ScopeAllocation = enum { embedded, heap };

/// Which root a scope is. A session or core-building scope names the one
/// directory of its kind; a module root is its image's own scope, which
/// `modules` reaches by field parent.
pub const ScopeStorage = union(enum) {
    session,
    core_build: CorePublisher,
    module_root,
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    storage: ScopeStorage,
    refs: std.atomic.Value(u32) = .init(1),
    allocation: ScopeAllocation = .embedded,
    /// A module image's cell, which its words name. Allocated on first use, so
    /// an image nothing links into costs nothing. Session and core words name
    /// the `Env`'s own cells instead.
    label_cell: std.atomic.Value(?*ScopeCell) = .init(null),
    retirement: heap.ReleaseDomain.Retirement = .{},
    retirement_state: ?RetireCursor.State = null,

    /// The id of a module root's cell, or `.none` if it has never minted one.
    pub fn cellId(self: *const Scope) ScopeId {
        const cell = self.label_cell.load(.acquire) orelse return .none;
        return cell.id;
    }

    pub fn isModuleRoot(self: *const Scope) bool {
        return self.storage == .module_root;
    }

    pub const RetireCursor = struct {
        scope: *Scope,
        state: State,

        const State = union(enum) {
            destroy,
            complete,
        };

        pub fn init(scope: *Scope) RetireCursor {
            const old = scope.refs.fetchSub(1, .release);
            std.debug.assert(old != 0);
            if (old != 1) return .{ .scope = scope, .state = .complete };
            _ = scope.refs.load(.acquire);
            // A word written in this scope names its cell and nothing else, so
            // the cell retires with it: binding such a word afterwards is a
            // definite failure rather than a silent change of meaning.
            const cleared = scope.label_cell.swap(null, .acq_rel);
            if (cleared) |cell| cell.retire();
            return .{ .scope = scope, .state = .destroy };
        }

        pub fn advance(self: *RetireCursor) bool {
            return switch (self.state) {
                .destroy => {
                    const allocator = self.scope.allocator;
                    switch (self.scope.allocation) {
                        .heap => allocator.destroy(self.scope),
                        .embedded => {},
                    }
                    self.state = .complete;
                    return true;
                },
                .complete => true,
            };
        }
    };

    /// Teardown owner for scopes embedded in a larger allocation. The
    /// embedding allocation is the scope's storage authority: it must remain
    /// present until every holder has released, and only then may the owner
    /// reference be consumed.
    pub const EmbeddedTeardownCursor = struct {
        scope: *Scope,
        state: State = .waiting_for_children,

        const State = union(enum) {
            waiting_for_children,
            retiring: RetireCursor,
            complete,
        };

        pub fn init(scope: *Scope) EmbeddedTeardownCursor {
            std.debug.assert(scope.allocation == .embedded);
            return .{ .scope = scope };
        }

        pub fn advance(self: *EmbeddedTeardownCursor) bool {
            return switch (self.state) {
                .waiting_for_children => result: {
                    if (self.scope.refs.load(.acquire) != 1) break :result false;
                    self.state = .{ .retiring = self.scope.retireCursor() };
                    break :result false;
                },
                .retiring => |*cursor| if (cursor.advance()) result: {
                    self.state = .complete;
                    break :result true;
                } else false,
                .complete => true,
            };
        }
    };

    fn direct(allocator: std.mem.Allocator, storage: ScopeStorage) Scope {
        return .{ .allocator = allocator, .storage = storage };
    }

    /// A module image's root. It carries no canonical name: the same sealed
    /// image may execute under any number of registrations.
    pub fn moduleRoot(allocator: std.mem.Allocator) Scope {
        return direct(allocator, .module_root);
    }

    pub fn retain(self: *Scope) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    pub fn retireCursor(self: *Scope) RetireCursor {
        return .init(self);
    }

    pub fn retire(self: *Scope, releases: *heap.ReleaseDomain) void {
        const cursor = self.retireCursor();
        if (cursor.state == .complete) return;
        std.debug.assert(self.allocation == .heap);
        self.retirement_state = cursor.state;
        releases.retire(self, &self.retirement);
    }

    pub fn advanceRetirement(
        _: *heap.ReleaseDomain,
        _: std.mem.Allocator,
        self: *Scope,
    ) bool {
        var cursor = RetireCursor{ .scope = self, .state = self.retirement_state.? };
        if (cursor.advance()) return true;
        self.retirement_state = cursor.state;
        return false;
    }

    /// Drops a root scope that was never really used: `replaceRoot`
    /// overwriting a freshly built one before the unit executed anything.
    pub fn releaseTrivial(self: *Scope) void {
        std.debug.assert(self.label_cell.load(.acquire) == null);
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old == 1);
        _ = self.refs.load(.acquire);
    }
};

/// Authority to publish into core while it is being built. Minted only by
/// `BuildingEnv.rootScope`, and refused once core is frozen.
pub const CorePublisher = enum(usize) {
    invalid = 0,
    _,

    fn init(state: *EnvState) CorePublisher {
        return @fromBackingInt(@intCast(@intFromPtr(state)));
    }

    fn target(self: CorePublisher) *EnvState {
        std.debug.assert(self != .invalid);
        return @ptrFromInt(@backingInt(self));
    }

    pub const Error = error{ OutOfMemory, Frozen, Duplicate };

    /// Publishes a sealed static definition. Core names are introduced once:
    /// a bound body may already target the earlier definition, so replacing
    /// it would leave that target dangling.
    pub fn publish(self: CorePublisher, name: intern.BindingName, definition: *Definition) Error!void {
        const state = self.target();
        if (state.core_frozen) return error.Frozen;
        return state.publishCore(name, definition);
    }

    /// The releases definitions retire into.
    pub fn releaseDomain(self: CorePublisher) *heap.ReleaseDomain {
        return heap.hostDomain(self.target().host);
    }
};

comptime {
    heap.requireOpaqueMutation(CorePublisher);
}

/// A scope's stable public name. A word occurrence carries one of these rather
/// than a pointer, because it has four bytes to spend and not eight. Zero means
/// "no written-in scope" and resolves in core.
///
/// Ids are issued monotonically and never recycled. A word token holds a bare
/// integer and takes no reference, so a reused id would let a stale token
/// resolve into an unrelated scope — a silent wrong answer, which is worse than
/// any failure this design can otherwise produce. Ids are consumed by core, the
/// session, and module images, so the space is spent on registrations and
/// reloads rather than on execution.
pub const ScopeId = enum(u32) { none = 0, _ };

/// A `ScopeId` is 24 bits of directory index plus a reserved high byte, kept
/// clear so a generation tag could later be added without colliding with a
/// live id.
pub const id_bits: u5 = 24;

comptime {
    const reserved_bits: u5 = 8;
    const budget: u16 = @as(u16, id_bits) + @as(u16, reserved_bits);
    if (budget != @bitSizeOf(@typeInfo(ScopeId).@"enum".tag_type))
        @compileError("scope id bit budget does not cover its tag type");
}

/// What a `ScopeId` names right now.
pub const ScopeResolution = union(enum) {
    /// Id zero: a word with no written-in scope, which resolves in core.
    unscoped,
    /// An id that was issued and whose image has since been torn down.
    retired,
    /// Core alone.
    core,
    /// The session's top-level directory.
    session,
    /// A live image cell. The scope is not handed over here: reaching it
    /// requires a `Liveness` proof, because a cell names its image without
    /// holding it.
    cell: *ScopeCell,
};

/// Proof that a borrowed image scope stays alive for the duration of the
/// borrow. Obtaining a `*Scope` from a cell is impossible without deciding
/// which arm applies.
pub const Liveness = union(enum) {
    /// The running activation already holds this image.
    activation_held,
    /// A reference was acquired for this borrow and is held for at least as
    /// long as the scope pointer is used.
    fresh_pin,
};

/// How a producer of symbol occurrences links each one to the root it writes
/// into. A reader that links nothing carries none, and every symbol it
/// produces resolves in core.
pub const SymbolLinker = struct {
    root: ScopeId,

    pub fn link(self: SymbolLinker, name: u32) error{OutOfMemory}!u32 {
        _ = name;
        return @backingInt(self.root);
    }
};

/// What a module image's scope cell names to prove the image live: its
/// reference anchor, which outlives the image. Opaque here so `env` never
/// dereferences it and holds no dependency on `modules`.
pub const ImageAnchor = opaque {};

pub const ScopeCell = struct {
    id: ScopeId,
    scope: std.atomic.Value(?*Scope) = .init(null),
    /// The image anchor this cell names; null for core and the session.
    owner: std.atomic.Value(?*ImageAnchor) = .init(null),
    kind: Kind = .image,

    pub const Kind = enum { core, session, image };

    /// Fills in what this cell names, before its id has escaped. The owner is
    /// stored before the scope, so a reader that can see the scope can already
    /// see what to acquire before touching it.
    pub fn publishOwned(self: *ScopeCell, scope: *Scope, owner: ?*ImageAnchor) void {
        if (owner) |handle| self.owner.store(handle, .release);
        self.scope.store(scope, .release);
    }

    pub fn ownerHandle(self: *const ScopeCell) ?*ImageAnchor {
        return self.owner.load(.acquire);
    }

    /// The borrowed scope, obtainable only against a liveness proof.
    pub fn scopeUnder(self: *const ScopeCell, _: Liveness) ?*Scope {
        return self.scope.load(.acquire);
    }

    /// Marks the cell as naming nothing. The `Env` owns every cell and frees
    /// them together at teardown, the one point at which no reader exists.
    pub fn retire(self: *ScopeCell) void {
        self.scope.store(null, .release);
    }
};

/// A three-level direct directory keyed by the 24 low bits of an id. Pages are
/// installed once and live for the directory's lifetime, so a reader needs no
/// lock and lookup is three atomic loads. Ids are never reused.
fn Directory(comptime Id: type, comptime Item: type) type {
    return struct {
        const Self = @This();
        const radix = 256;
        const Leaf = struct {
            entries: [radix]std.atomic.Value(?*Item) = @splat(.init(null)),
        };
        const Branch = struct {
            leaves: [radix]std.atomic.Value(?*Leaf) = @splat(.init(null)),
        };

        mutex: std.Io.Mutex = .init,
        next: std.atomic.Value(u32) = .init(1),
        branches: [radix]std.atomic.Value(?*Branch) = @splat(.init(null)),

        const max_id: u32 = (1 << id_bits) - 1;

        fn coordinates(id: Id) struct { usize, usize, usize } {
            const raw = @backingInt(id);
            std.debug.assert(raw != 0 and raw <= max_id);
            return .{
                @intCast((raw >> 16) & 0xff),
                @intCast((raw >> 8) & 0xff),
                @intCast(raw & 0xff),
            };
        }

        fn get(self: *const Self, id: Id) ?*Item {
            if (@backingInt(id) > max_id) return null;
            const branch_index, const leaf_index, const entry_index = coordinates(id);
            const branch = self.branches[branch_index].load(.acquire) orelse return null;
            const leaf = branch.leaves[leaf_index].load(.acquire) orelse return null;
            return leaf.entries[entry_index].load(.acquire);
        }

        /// Issues the next id and installs the entry. A missing page is
        /// allocated with the lock released and the target rechecked after.
        fn register(
            self: *Self,
            allocator: std.mem.Allocator,
            entry: *Item,
        ) error{OutOfMemory}!Id {
            var branch_candidate: ?*Branch = null;
            var leaf_candidate: ?*Leaf = null;
            defer {
                if (branch_candidate) |unused| allocator.destroy(unused);
                if (leaf_candidate) |unused| allocator.destroy(unused);
            }

            while (true) {
                std.Io.Threaded.mutexLockUncancelable(&self.mutex);
                const raw = self.next.load(.monotonic);
                const id: Id = @fromBackingInt(@intCast(@min(raw, max_id)));
                const branch_index, const leaf_index, _ = coordinates(id);
                const present = self.branches[branch_index].load(.acquire);
                const needs_branch = present == null and branch_candidate == null;
                const needs_leaf = leaf_candidate == null and
                    (present == null or present.?.leaves[leaf_index].load(.acquire) == null);
                if (raw > max_id or !(needs_branch or needs_leaf)) break;
                std.Io.Threaded.mutexUnlock(&self.mutex);
                if (needs_branch) {
                    branch_candidate = try allocator.create(Branch);
                    branch_candidate.?.* = .{};
                }
                if (needs_leaf) {
                    leaf_candidate = try allocator.create(Leaf);
                    leaf_candidate.?.* = .{};
                }
            }
            defer std.Io.Threaded.mutexUnlock(&self.mutex);
            const raw = self.next.load(.monotonic);
            if (raw > max_id) return error.OutOfMemory;
            const id: Id = @fromBackingInt(@intCast(raw));
            const branch_index, const leaf_index, const entry_index = coordinates(id);
            const branch = self.branches[branch_index].load(.acquire) orelse installed: {
                const chosen = branch_candidate.?;
                branch_candidate = null;
                self.branches[branch_index].store(chosen, .release);
                break :installed chosen;
            };
            const leaf = branch.leaves[leaf_index].load(.acquire) orelse installed: {
                const chosen = leaf_candidate.?;
                leaf_candidate = null;
                branch.leaves[leaf_index].store(chosen, .release);
                break :installed chosen;
            };
            std.debug.assert(leaf.entries[entry_index].load(.acquire) == null);
            leaf.entries[entry_index].store(entry, .release);
            self.next.store(raw + 1, .monotonic);
            std.debug.assert(raw >> id_bits == 0);
            return id;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.branches) |*branch_slot| if (branch_slot.load(.acquire)) |branch| {
                for (&branch.leaves) |*leaf_slot| if (leaf_slot.load(.acquire)) |leaf|
                    allocator.destroy(leaf);
                allocator.destroy(branch);
            };
            self.* = .{};
        }
    };
}
const ScopeIndex = Directory(ScopeId, ScopeCell);

/// A locals operation the reader lowered `|...|` into carries its count or
/// index in the link field with this flag set: one form per bind, read, or
/// drop. It names no root. Scope ids stay below it.
pub const local_operand_flag: u32 = 1 << 30;

/// See `value.quote_flag`. Scope ids stay below it, and a locals operation
/// never carries it.
pub const quote_flag: u32 = value.quote_flag;

/// Whether an occurrence is quoted.
pub const isQuoted = value.isQuotedSlot;

/// The link of an occurrence, without any quote flag.
pub fn unquoted(raw: u32) u32 {
    return if (isQuoted(raw)) raw & ~quote_flag else raw;
}

/// The link field of a locals operation with `operand`.
pub fn localOperandSlot(operand: u32) u32 {
    std.debug.assert(operand < quote_flag);
    return local_operand_flag | operand;
}

/// The count or index a locals operation carries, or null for any other word.
pub fn localOperand(raw: u32) ?u32 {
    if (raw & local_operand_flag == 0) return null;
    return raw & ~local_operand_flag;
}

/// What a word's link names.
pub const WordTarget = union(enum) {
    /// Built by the implementation for itself: resolves in core.
    unlinked,
    /// A lowered locals operation, with its count or index.
    local: u32,
    /// The root the word was written in.
    root: ScopeId,
};

/// A quoted occurrence's target is its link's: the flag says how it runs, not
/// where its name resolves.
pub fn wordTarget(raw_occurrence: u32) WordTarget {
    const raw = unquoted(raw_occurrence);
    if (raw == 0) return .unlinked;
    if (localOperand(raw)) |operand| return .{ .local = operand };
    return .{ .root = @fromBackingInt(raw) };
}

const core_capacity_hint: usize = 2048;

const EnvState = struct {
    host: *const heap.HostCleanup,
    /// Core's directory: filled while core is built, immutable once frozen.
    core: NameMap,
    core_frozen: bool = false,
    core_cell: ScopeCell,
    session_cell: ScopeCell,
    /// Every cell this Env has issued, freed together at teardown.
    cells: std.ArrayList(*ScopeCell) = .empty,
    cells_mutex: std.Io.Mutex = .init,
    scopes: ScopeIndex = .{},
    locals_words: intern.LocalsWords,

    fn publishCore(self: *EnvState, name: intern.BindingName, definition: *Definition) CorePublisher.Error!void {
        // Core is fixed bootstrap input sized well inside its table, so a full
        // table is a bootstrap defect rather than a runtime condition.
        if (self.core.count() * 2 >= self.core.slots.len) return error.OutOfMemory;
        var lookup = self.core.rawLookup(name);
        const existing = poll.drive(?Entry, &lookup, .{});
        if (existing != null) return error.Duplicate;
        var put = self.core.putCursor(name, .{ .definition = definition });
        _ = poll.drive(bool, &put, .{});
    }
};

pub const Env = enum(usize) {
    consumed = 0,
    _,

    fn privateState(self: *const Env) *EnvState {
        std.debug.assert(self.* != .consumed);
        return @ptrFromInt(@backingInt(self.*));
    }

    pub fn init(host_owner: *heap.HostOwner) error{OutOfMemory}!Env {
        const host = host_owner.cleanup();
        const allocator = host.allocator();
        const locals_words = try intern.LocalsWords.mint();
        var core_init = NameMap.initCursor(allocator, core_capacity_hint);
        errdefer core_init.deinit();
        const core = while (true) switch (try core_init.advance()) {
            .pending => {},
            .complete => |map| break map,
        };
        const backing = allocator.create(EnvState) catch |err| {
            var owned = core;
            owned.deinit();
            return err;
        };
        backing.* = .{
            .host = host,
            .core = core,
            .locals_words = locals_words,
            .core_cell = .{ .id = .none, .kind = .core },
            .session_cell = .{ .id = .none, .kind = .session },
        };
        errdefer {
            backing.scopes.deinit(allocator);
            backing.core.deinit();
            allocator.destroy(backing);
        }
        // Core and the session need real ids: a word linked to either names
        // it, and id zero would mean "unscoped".
        backing.core_cell.id = try backing.scopes.register(allocator, &backing.core_cell);
        backing.session_cell.id = try backing.scopes.register(allocator, &backing.session_cell);
        return @fromBackingInt(@intCast(@intFromPtr(backing)));
    }

    pub fn deinit(self: *Env) void {
        const backing = self.privateState();
        const allocator = backing.host.allocator();
        const releases = heap.hostDomain(backing.host);
        var entries = backing.core.rawEntries();
        while (true) switch (entries.advance()) {
            .pending => {},
            .item => |entry| switch (entry.value) {
                .definition => |definition| definition.retireStatic(releases),
                .alias => {},
            },
            .complete => break,
        };
        // Drain completely before freeing: a retiring definition may release
        // headers whose destruction reaches Env-owned cells.
        backing.host.drain();
        backing.core.deinit();
        for (backing.cells.items) |cell| allocator.destroy(cell);
        backing.cells.deinit(allocator);
        backing.scopes.deinit(allocator);
        allocator.destroy(backing);
        self.* = .consumed;
    }

    pub fn coreScopeId(self: *const Env) ScopeId {
        return self.privateState().core_cell.id;
    }

    pub fn sessionScopeId(self: *const Env) ScopeId {
        return self.privateState().session_cell.id;
    }

    /// The id of a module image's scope cell. `owner` is stored opaque and
    /// never dereferenced here; it is what lets a borrow acquire the image
    /// before reading the scope.
    pub fn scopeIdForOwned(
        self: *Env,
        scope: *Scope,
        owner: *ImageAnchor,
    ) error{OutOfMemory}!ScopeId {
        return (try self.scopeCell(scope, owner)).id;
    }

    /// The domain definitions retire into.
    pub fn releaseDomain(self: *const Env) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }

    /// Links words written into the root `root` names.
    pub fn linker(_: *const Env, root: ScopeId) SymbolLinker {
        return .{ .root = root };
    }

    /// The cell for one module root, created on first use. The scope retires
    /// it when its own refcount drops.
    pub fn scopeCell(
        self: *Env,
        scope: *Scope,
        owner: ?*ImageAnchor,
    ) error{OutOfMemory}!*ScopeCell {
        std.debug.assert(scope.isModuleRoot());
        if (scope.label_cell.load(.acquire)) |existing| {
            std.debug.assert(owner == null or existing.ownerHandle() == owner);
            return existing;
        }
        const cell = try self.newScopeCell(scope, owner);
        if (scope.label_cell.cmpxchgStrong(null, cell, .release, .acquire)) |raced| {
            cell.retire();
            return raced.?;
        }
        return cell;
    }

    /// A fresh cell complete before its id exists: `register` is the sole
    /// point at which an id escapes into the lock-free directory.
    pub fn newScopeCell(
        self: *Env,
        scope: ?*Scope,
        owner: ?*ImageAnchor,
    ) error{OutOfMemory}!*ScopeCell {
        const backing = self.privateState();
        const allocator = backing.host.allocator();
        const cell = try allocator.create(ScopeCell);
        cell.* = .{ .id = .none };
        if (scope) |named| cell.publishOwned(named, owner);
        {
            std.Io.Threaded.mutexLockUncancelable(&backing.cells_mutex);
            defer std.Io.Threaded.mutexUnlock(&backing.cells_mutex);
            backing.cells.append(allocator, cell) catch |err| {
                allocator.destroy(cell);
                return err;
            };
        }
        cell.id = try backing.scopes.register(allocator, cell);
        return cell;
    }

    /// What a word's root id names right now.
    pub fn scopeOf(self: *const Env, id: ScopeId) ScopeResolution {
        if (id == .none) return .unscoped;
        const cell = self.privateState().scopes.get(id) orelse return .retired;
        return switch (cell.kind) {
            .core => .core,
            .session => .session,
            .image => if (cell.scope.load(.acquire) == null) .retired else .{ .cell = cell },
        };
    }

    /// One lookup in core's directory. Core is immutable once frozen, and
    /// written only by the bootstrap unit before then.
    pub fn coreLookup(self: *const Env, name: intern.BindingName) NameMap.RawLookupCursor {
        return self.privateState().core.rawLookup(name);
    }

    /// Core's names, for enumeration.
    pub fn coreEntries(self: *const Env) NameMap.RawEntryCursor {
        return self.privateState().core.rawEntries();
    }

    /// The reserved locals backend, bindable without a lookup in any scope.
    pub fn localsWords(self: *const Env) intern.LocalsWords {
        return self.privateState().locals_words;
    }

    /// A fresh Env together with the one capability that may build its core.
    pub fn initBuilding(host_owner: *heap.HostOwner) error{OutOfMemory}!struct { Env, BuildingEnv } {
        const environment = try init(host_owner);
        return .{ environment, BuildingEnv.init(environment) };
    }

    pub fn sessionRoot(_: *Env, allocator: std.mem.Allocator) Scope {
        return Scope.direct(allocator, .session);
    }

    pub fn createSessionRoot(self: *Env, allocator: std.mem.Allocator) error{OutOfMemory}!*Scope {
        const root = try allocator.create(Scope);
        root.* = self.sessionRoot(allocator);
        root.allocation = .heap;
        return root;
    }
};

comptime {
    heap.requireOpaqueHostRoot(Env, EnvState);
    heap.requireOpaqueMutation(BuildingEnv);
}

/// Typestate capability for the only phase in which core publication is
/// legal. `finish` consumes the capability and freezes the core.
pub const BuildingEnv = enum(usize) {
    invalid = 0,
    _,

    fn init(environment: Env) BuildingEnv {
        return @fromBackingInt(@backingInt(environment));
    }

    fn target(self: BuildingEnv) Env {
        std.debug.assert(self != .invalid);
        return @fromBackingInt(@backingInt(self));
    }

    const BuiltinEffect = struct {
        value: value.Value,
        validated: ValidatedEffect,
    };

    /// Only the static factory can pair authored metadata with its validated
    /// effect builder. Runtime installation never accepts an unchecked word.
    const StaticBuiltin = opaque {
        const EffectData = struct {
            tokens: []const []const u8,
            separator: usize,
            build: *const fn (*BuildingEnv, *const EffectData) error{OutOfMemory}!BuiltinEffect,
        };
        const Data = struct {
            definition: BuiltinWord,
            effect: ?EffectData,
        };

        fn effectBuilder(comptime count: usize) @FieldType(EffectData, "build") {
            return struct {
                fn build(builder: *BuildingEnv, effect: *const EffectData) error{OutOfMemory}!BuiltinEffect {
                    return builder.builtinEffect(count, effect);
                }
            }.build;
        }

        fn init(comptime definition: BuiltinWord) *const StaticBuiltin {
            const data = comptime blk: {
                assertStaticBuiltin(definition);
                const effect: ?EffectData = if (definition.effect) |source| effect: {
                    const count = countEffectTokens(source);
                    var tokens: [count][]const u8 = undefined;
                    var iterator = std.mem.tokenizeScalar(u8, source, ' ');
                    // SAFETY: assertStaticBuiltin guarantees exactly one `--`
                    // token, so the loop assigns separator before it is read.
                    var separator: usize = undefined;
                    for (&tokens, 0..) |*token, index| {
                        token.* = iterator.next().?;
                        if (std.mem.eql(u8, token.*, "--")) separator = index;
                    }
                    const frozen = tokens;
                    break :effect .{ .tokens = &frozen, .separator = separator, .build = effectBuilder(count) };
                } else null;
                break :blk Data{ .definition = definition, .effect = effect };
            };
            return @ptrCast(&data);
        }

        fn install(self: *const StaticBuiltin, builder: *BuildingEnv) error{OutOfMemory}!void {
            const data: *const Data = @ptrCast(@alignCast(self));
            const definition = data.definition;
            const install_name = intern.internReservedNamespace(definition.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidName => unreachable,
            };
            var environment = builder.target();
            const state = environment.privateState();
            const allocator = state.host.allocator();
            const releases = heap.hostDomain(state.host);
            const document_value = try machine.stringValue(allocator, releases, definition.doc);
            defer releases.releaseValue(document_value);
            const builtin_effect: ?BuiltinEffect = if (data.effect) |*effect|
                try effect.build(builder, effect)
            else
                null;
            defer if (builtin_effect) |effect| releases.releaseValue(effect.value);
            const created = try Definition.create(allocator, .static, .{ .builtin = definition.primitive }, .{
                .effect = if (builtin_effect) |effect| effect.validated else null,
                .doc = documentation(document_value.list).?,
                .root = .core,
            });
            state.publishCore(install_name, created) catch |err| {
                created.retireStatic(releases);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Frozen, error.Duplicate => unreachable,
                };
            };
        }
    };

    fn builtinEffect(
        self: *BuildingEnv,
        comptime token_count: usize,
        effect: *const StaticBuiltin.EffectData,
    ) error{OutOfMemory}!BuiltinEffect {
        var environment = self.target();
        const allocator = environment.privateState().host.allocator();
        var tokens: [token_count]value.Value = undefined;
        for (effect.tokens, &tokens) |token, *destination| {
            const id = try intern.intern(token);
            destination.* = .{ .symbol = .{ .name = id } };
        }
        const effect_value = try list.fromValuesGeneric(allocator, &tokens);
        return .{
            .value = effect_value,
            .validated = .fromValidated(effect_value.list, effect.separator),
        };
    }

    pub fn installBuiltin(self: *BuildingEnv, comptime definition: BuiltinWord) error{OutOfMemory}!void {
        return StaticBuiltin.init(definition).install(self);
    }

    pub fn installBuiltins(self: *BuildingEnv, comptime definitions: []const BuiltinWord) error{OutOfMemory}!void {
        const descriptors = comptime blk: {
            @setEvalBranchQuota(100_000);
            var result: [definitions.len]*const StaticBuiltin = undefined;
            for (definitions, 0..) |definition, index| {
                for (definitions[0..index]) |prior| {
                    if (std.mem.eql(u8, prior.name, definition.name)) {
                        @compileError("duplicate builtin namespace name: " ++ definition.name);
                    }
                }
                result[index] = StaticBuiltin.init(definition);
            }
            break :blk result;
        };
        for (descriptors) |descriptor| {
            try descriptor.install(self);
        }
    }

    /// The Env under construction, for the bootstrap Unit that evaluates the
    /// prelude against it. It grants no core publication; that stays here.
    pub fn runtime(self: *const BuildingEnv) Env {
        return self.target();
    }

    /// The root the bootstrap Unit evaluates the prelude in. Its storage is the
    /// core publisher, which refuses once core is frozen.
    pub fn rootScope(self: *BuildingEnv, allocator: std.mem.Allocator) Scope {
        var environment = self.target();
        return Scope.direct(allocator, .{ .core_build = .init(environment.privateState()) });
    }

    /// Records recognition for core's trusted source definitions, then
    /// freezes core. `recognize` is handed each source definition by name.
    pub fn finish(
        self: *BuildingEnv,
        recognize: *const fn (Env, []const u8, *Definition) void,
    ) error{OutOfMemory}!void {
        var environment = self.target();
        const state = environment.privateState();
        for (idioms.direct_names) |spelling| {
            const id = try intern.intern(spelling);
            const name = intern.namespaceName(id) catch continue;
            var lookup = state.core.rawLookup(name);
            const entry = poll.drive(?Entry, &lookup, .{}) orelse continue;
            switch (entry) {
                .definition => |definition| if (definition.body == .source) recognize(environment, spelling, definition),
                .alias => {},
            }
        }
        state.core_frozen = true;
        self.* = .invalid;
    }
};

fn countEffectTokens(comptime source: []const u8) usize {
    if (source.len == 0) @compileError("primitive effect cannot be empty");
    var count: usize = 1;
    for (source) |byte| count += @intFromBool(byte == ' ');
    return count;
}

pub fn assertStaticNamespace(comptime name: []const u8) void {
    if (intern.isReservedBytes(name) or !lexer.validSymbolSegment(name)) {
        @compileError("invalid builtin namespace name: " ++ name);
    }
}

pub fn assertStaticModuleName(comptime name: []const u8) void {
    @setEvalBranchQuota(10_000);
    if (name.len == 0) @compileError("embedded module name must be nonempty");
    var segment_start: usize = 0;
    for (name, 0..) |byte, index| {
        if (byte != '.') continue;
        if (index == segment_start or
            intern.isReservedBytes(name[segment_start..index]) or
            !lexer.validSymbolSegment(name[segment_start..index]))
        {
            @compileError("invalid embedded module name: " ++ name);
        }
        segment_start = index + 1;
    }
    if (segment_start == name.len or
        intern.isReservedBytes(name[segment_start..]) or
        !lexer.validSymbolSegment(name[segment_start..]))
    {
        @compileError("invalid embedded module name: " ++ name);
    }
}

pub const testing = if (builtin.is_test) struct {
    pub fn deinitScope(scope: *Scope, releases: *heap.ReleaseDomain) void {
        switch (scope.allocation) {
            .embedded => {
                var cursor = Scope.EmbeddedTeardownCursor.init(scope);
                while (!cursor.advance()) _ = releases.advance(256);
            },
            .heap => {
                var cursor = scope.retireCursor();
                while (!cursor.advance()) _ = releases.advance(256);
            },
        }
    }
} else struct {};

test "env: issued scope ids leave their reserved high bits clear" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var container = try Env.init(&host);
    defer container.deinit();

    const issued = ScopeIndex.radix + 3;
    var previous: u32 = @backingInt(container.sessionScopeId());
    for (0..issued) |_| {
        const cell = try container.newScopeCell(null, null);
        const raw = @backingInt(cell.id);
        try std.testing.expect(raw != 0);
        try std.testing.expect(raw <= ScopeIndex.max_id);
        try std.testing.expectEqual(@as(u32, 0), raw >> id_bits);
        try std.testing.expect(raw > previous);
        previous = raw;
    }
}
