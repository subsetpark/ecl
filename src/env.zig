//! Definitions, sealed executables, name directories, and scope links.
const std = @import("std");
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
/// In-tree primitives use Fiber's ergonomic error helpers. This binding
/// kind is not part of the native-extension ABI.
pub const PrimitiveImpl = *const fn (*machine.Fiber) machine.MachineError!void;

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
        .dict, .task, .port, .address => null,
    };
}

pub fn quotationHeader(body: *const Quotation) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(body)));
}

pub fn documentation(header: *value.ListHandle) ?*DocumentationString {
    return switch (header.kind()) {
        .leaf_char1, .leaf_char2, .leaf_char4 => @ptrCast(@alignCast(header)),
        .generic_spine, .leaf_u8, .leaf_i64, .leaf_f64, .dict, .task, .port, .address => null,
    };
}

pub fn documentationHeader(document: *const DocumentationString) *value.ListHandle {
    return @ptrCast(@alignCast(@constCast(document)));
}

pub const Visibility = enum { public, private };
pub const ValidatedEffect = struct {
    quotation: *EffectQuotation,
    /// The named before slots: exactly what the word consumes, or the minimum
    /// when the before portion holds a row.
    inputs: u32,
    /// The named after slots: exactly what the word leaves, or the minimum
    /// when the after portion holds a row.
    outputs: u32,
    result_depth: ResultDepth = .exact,

    /// What a boundary can check of the depth a word leaves. A before row
    /// leaves the consumed count unknown, so nothing about the result depth
    /// can be checked; an after row alone still fixes a minimum.
    pub const ResultDepth = enum { exact, at_least, unchecked };
    pub fn header(self: ValidatedEffect) *value.ListHandle {
        return @ptrCast(@alignCast(self.quotation));
    }
    pub fn retain(self: ValidatedEffect) void {
        heap.incRef(self.header());
    }
    pub fn retire(self: ValidatedEffect, releases: *heap.ReleaseDomain) void {
        releases.releaseHeader(self.header());
    }
    pub fn fromValidated(effect_header: *value.ListHandle, shape: EffectShape) ValidatedEffect {
        const split = shape.split;
        std.debug.assert(effect_header.kind() == .generic_spine and split < effect_header.length());
        return .{
            .quotation = @ptrCast(@alignCast(effect_header)),
            .inputs = @intCast(split - @intFromBool(shape.before_row)),
            .outputs = @intCast(@as(usize, @intCast(effect_header.length())) - split - 1 -
                @intFromBool(shape.after_row)),
            .result_depth = if (shape.before_row)
                .unchecked
            else if (shape.after_row)
                .at_least
            else
                .exact,
        };
    }
    pub fn parse(effect_header: *value.ListHandle) ?ValidatedEffect {
        var cursor = EffectGrammar.init(
            effect_header,
            @intCast(effect_header.length()),
        ) orelse return null;
        const shape = poll.drive(?EffectShape, &cursor, .{}) orelse return null;
        return fromValidated(effect_header, shape);
    }
};

pub const Effect = ValidatedEffect;

/// Deepest nesting of quotation slots an effect may declare.
pub const max_effect_depth = 8;

/// Where a validated level's separator sits, and which portions hold a row,
/// making that portion's named slots a minimum.
pub const EffectShape = struct {
    split: usize,
    before_row: bool,
    after_row: bool,
};

/// One level of an effect under validation. The slot grammar lives here alone:
/// the runtime cursor over values and the comptime check of builtin effect
/// text both drive these rules, so the two cannot disagree. A slot is a word
/// or a nested effect; each level has exactly one `--`, `...` at most once in
/// each portion, and a label word ending in `:` only first in a nested effect. Every slot is one element, so the top level's separator index
/// alone determines arity.
pub const EffectLevel = struct {
    nested: bool,
    index: usize = 0,
    split: ?usize = null,
    before_row: bool = false,
    after_row: bool = false,

    pub fn admitWord(self: *EffectLevel, spelling: []const u8) bool {
        const index = self.index;
        self.index += 1;
        if (std.mem.eql(u8, spelling, "--")) {
            if (self.split != null) return false;
            self.split = index;
            return true;
        }
        if (std.mem.eql(u8, spelling, lexer.row_token)) {
            const row = if (self.split == null) &self.before_row else &self.after_row;
            if (row.*) return false;
            row.* = true;
            return true;
        }
        // A lone `:` would be a documentation marker, which only a top-level
        // annotation carries, and that ends the effect before it.
        if (std.mem.endsWith(u8, spelling, ":"))
            return self.nested and index == 0 and spelling.len > 1;
        return true;
    }

    pub fn admitNested(self: *EffectLevel) void {
        self.index += 1;
    }

    /// The level's shape, or null when the level is malformed.
    pub fn close(self: EffectLevel) ?EffectShape {
        const split = self.split orelse return null;
        return .{ .split = split, .before_row = self.before_row, .after_row = self.after_row };
    }
};

/// Validates an effect value one element per step, with nesting as an
/// explicit frame stack.
pub const EffectGrammar = struct {
    // SAFETY: frames below `depth` are initialized; the rest are never read.
    frames: [max_effect_depth]Frame = undefined,
    depth: usize = 1,

    const Frame = struct {
        items: *value.ListHandle,
        end: usize,
        level: EffectLevel,
    };

    /// Validate the first `end` elements of `effect`; a definition's
    /// annotation ends its effect before the documentation marker.
    pub fn init(effect: *value.ListHandle, end: usize) ?EffectGrammar {
        if (effect.kind() != .generic_spine) return null;
        var grammar: EffectGrammar = .{};
        grammar.frames[0] = .{ .items = effect, .end = end, .level = .{ .nested = false } };
        return grammar;
    }

    /// Completes with the top level's shape, or null when any level is
    /// malformed.
    pub fn advance(self: *EffectGrammar) poll.Progress(?EffectShape) {
        const frame = &self.frames[self.depth - 1];
        if (frame.level.index == frame.end) {
            const shape = frame.level.close() orelse return .{ .complete = null };
            self.depth -= 1;
            return if (self.depth == 0) .{ .complete = shape } else .pending;
        }
        switch (list.atUnchecked(.{ .list = frame.items }, frame.level.index)) {
            .list => |nested| {
                if (nested.kind() != .generic_spine or self.depth == max_effect_depth)
                    return .{ .complete = null };
                frame.level.admitNested();
                self.frames[self.depth] = .{
                    .items = nested,
                    .end = @intCast(nested.length()),
                    .level = .{ .nested = true },
                };
                self.depth += 1;
            },
            .symbol => |symbol| if (!frame.level.admitWord(intern.get(symbol.name)))
                return .{ .complete = null },
            else => return .{ .complete = null },
        }
        return .pending;
    }
};

/// Splits builtin effect text into words and parentheses. Usable at comptime.
pub const EffectTokens = struct {
    source: []const u8,
    position: usize = 0,

    pub fn next(self: *EffectTokens) ?[]const u8 {
        while (self.position < self.source.len and self.source[self.position] == ' ') self.position += 1;
        if (self.position == self.source.len) return null;
        const start = self.position;
        if (self.source[start] == '(' or self.source[start] == ')') {
            self.position += 1;
            return self.source[start..self.position];
        }
        while (self.position < self.source.len) : (self.position += 1) switch (self.source[self.position]) {
            ' ', '(', ')' => break,
            else => {},
        };
        return self.source[start..self.position];
    }
};

/// Build the effect value that builtin effect text spells, nested lists for
/// its parenthesized slots. The text must already satisfy
/// `validateBuiltinEffect`, which bounds its depth and level widths.
pub fn builtinEffectValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    source: []const u8,
) error{OutOfMemory}!value.Value {
    var tokens: EffectTokens = .{ .source = source };
    return buildEffectLevel(allocator, releases, &tokens);
}

fn buildEffectLevel(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    tokens: *EffectTokens,
) error{OutOfMemory}!value.Value {
    // SAFETY: only the first `count` items are read or released.
    var items: [max_builtin_effect_tokens]value.Value = undefined;
    var count: usize = 0;
    defer for (items[0..count]) |item| releases.releaseValue(item);
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, ")")) break;
        items[count] = if (std.mem.eql(u8, token, "("))
            try buildEffectLevel(allocator, releases, tokens)
        else
            .{ .symbol = .{ .name = try intern.intern(token) } };
        count += 1;
    }
    return list.fromValuesGeneric(allocator, items[0..count]);
}

/// One word of a builtin-backed module: a host primitive published under a
/// module name. The metadata is authored as plain text because these modules
/// are compiled in and therefore have no loader descriptor to carry it.
/// Elements in one level of a builtin word's declared effect, `--` included.
/// Fixed because these effects are compiled-in text outside the user-data path.
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

/// A module of host primitives. Its documentation is required for the same
/// reason a builtin word's is; `module-doc` normalizes it when read, so it may
/// be written as wrapped prose.
pub const BuiltinModule = struct {
    words: []const BuiltinWord,
    doc: []const u8,
};

pub fn assertStaticBuiltinModule(comptime name: []const u8, comptime module: BuiltinModule) void {
    if (module.words.len == 0) @compileError("embedded builtin module has no words: " ++ name);
    if (module.doc.len == 0) @compileError("empty builtin module documentation: " ++ name);
    for (module.words) |word| assertStaticBuiltin(word);
}

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
    // SAFETY: levels below `depth` are initialized; the rest are never read.
    var levels: [max_effect_depth]EffectLevel = undefined;
    levels[0] = .{ .nested = false };
    var depth: usize = 1;
    var tokens: EffectTokens = .{ .source = effect };
    while (tokens.next()) |token| {
        const level = &levels[depth - 1];
        if (std.mem.eql(u8, token, ")")) {
            if (depth == 1 or level.close() == null) @compileError("malformed primitive effect: " ++ name);
            depth -= 1;
            continue;
        }
        if (std.mem.eql(u8, token, "(")) {
            level.admitNested();
        } else if (!level.admitWord(token)) @compileError("malformed primitive effect: " ++ name);
        if (level.index > max_builtin_effect_tokens)
            @compileError("primitive effect level is too wide: " ++ name);
        if (std.mem.eql(u8, token, "(")) {
            if (depth == max_effect_depth) @compileError("primitive effect nests too deeply: " ++ name);
            levels[depth] = .{ .nested = true };
            depth += 1;
        }
    }
    if (depth != 1 or levels[0].close() == null) @compileError("malformed primitive effect: " ++ name);
}

pub const ModulePublication = union(enum) {
    word: struct {
        body: *Quotation,
        source: ?reader_types.SourceSlice = null,
        visibility: Visibility,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
        attribution: Attribution = .own,
    },
    native: struct {
        callable: NativeCallable,
        effect: ValidatedEffect,
        doc: *DocumentationString,
    },
    /// A primitive published as a module word.
    builtin: struct {
        primitive: PrimitiveImpl,
        effect: ?ValidatedEffect = null,
        doc: *DocumentationString,
    },
};

/// A module as running code refers to it: the scope of the module's name,
/// which fixes same-module dispatch and diagnostic spelling, and the source
/// one registration of the module was made under. It holds nothing of an
/// image.
pub const ModuleRoot = struct {
    scope: *Scope,
    provenance: SourceId,

    pub fn name(self: ModuleRoot) intern.ModuleName {
        return self.scope.moduleName().?;
    }
};

/// The root a definition belongs to, which also says who keeps it alive. A
/// core definition lives as long as the `Env`. Every other definition is
/// counted: the session's directory or a module image owns one reference,
/// and replacement can make it unreachable from any directory while
/// activations still hold it.
///
/// A module's definition carries what an activation of it runs as, by value,
/// and its own name in the module, which with the module's name is how a
/// trace identifies it.
pub const DefinitionRoot = union(enum) {
    core,
    session,
    module: struct { home: ModuleRoot, name: intern.BindingName },
};

/// Where a failure inside a word is reported. A `caller` word is a helper,
/// like an assertion: its failures point at the code that called it rather
/// than at its own body. The definition's body was marked with `helper`.
pub const Attribution = enum(u8) { own, caller };

/// One immutable definition, sealed when it is created: every holder of a
/// `*Definition` holds code that execution, publication, and reflection read
/// through `code`. Creating one checks nothing about the words of its body;
/// each resolves when it is reached.
pub const Definition = struct {
    retirement: heap.ReleaseDomain.Retirement = .{},
    refs: std.atomic.Value(u32) = .init(1),
    allocator: std.mem.Allocator,
    sealed: Code,
    visibility: Visibility = .public,
    effect: ?ValidatedEffect = null,
    doc: ?*DocumentationString = null,
    source: ?reader_types.SourceSlice = null,
    root: DefinitionRoot,
    attribution: Attribution = .own,

    /// What a sealed definition runs.
    pub const Code = union(enum) {
        source: Executable.Storage,
        builtin: PrimitiveImpl,
        native: NativeCallable,
    };

    /// A host callback a definition runs.
    pub const Callback = union(enum) {
        builtin: PrimitiveImpl,
        native: NativeCallable,
    };

    pub const Metadata = struct {
        visibility: Visibility = .public,
        effect: ?ValidatedEffect = null,
        doc: ?*DocumentationString = null,
        source: ?reader_types.SourceSlice = null,
        root: DefinitionRoot,
        attribution: Attribution = .own,
    };

    /// A definition around a host callback, owning one reference to each
    /// metadata value.
    pub fn create(
        allocator: std.mem.Allocator,
        callback: Callback,
        metadata: Metadata,
    ) error{OutOfMemory}!*Definition {
        const sealed: Code = switch (callback) {
            .builtin => |primitive| .{ .builtin = primitive },
            .native => |callable| .{ .native = callable },
        };
        const result = try allocate(allocator, sealed, metadata);
        if (callback == .native) callback.native.instance.retain();
        return result;
    }

    /// A definition whose code is a quotation, owning one reference to each
    /// metadata value. `body` is retained here; the caller keeps its own.
    pub fn createSource(
        allocator: std.mem.Allocator,
        body: *value.ListHandle,
        metadata: Metadata,
    ) error{OutOfMemory}!*Definition {
        const result = try allocate(allocator, .{ .source = .{ .code = body, .owner = .static } }, metadata);
        // A counted definition's activations hold the definition itself.
        if (result.counted()) result.sealed.source.owner = .{ .definition = result };
        heap.incRef(body);
        return result;
    }

    fn allocate(
        allocator: std.mem.Allocator,
        sealed: Code,
        metadata: Metadata,
    ) error{OutOfMemory}!*Definition {
        const result = try allocator.create(Definition);
        if (metadata.effect) |effect| effect.retain();
        if (metadata.doc) |doc| heap.incRef(documentationHeader(doc));
        if (metadata.source) |source| source.retain();
        result.* = .{
            .allocator = allocator,
            .sealed = sealed,
            .visibility = metadata.visibility,
            .effect = metadata.effect,
            .doc = metadata.doc,
            .source = metadata.source,
            .root = metadata.root,
            .attribution = metadata.attribution,
        };
        return result;
    }

    /// What the definition runs.
    pub inline fn code(self: *const Definition) Run {
        return switch (self.sealed) {
            .source => |*storage| .{ .source = Executable.of(storage) },
            .builtin => |primitive| .{ .builtin = primitive },
            .native => |callable| .{ .native = callable },
        };
    }

    /// A sealed definition's code as its consumers see it: a source body is
    /// an executable handle.
    pub const Run = union(enum) {
        source: *const Executable,
        builtin: PrimitiveImpl,
        native: NativeCallable,
    };

    /// The source quotation a definition's body is shown as.
    pub fn quotationBody(self: *const Definition) ?*value.ListHandle {
        return switch (self.code()) {
            .source => |executable| executable.code(),
            .builtin, .native => null,
        };
    }

    inline fn counted(self: *const Definition) bool {
        return self.root != .core;
    }

    /// Takes one reference. Nothing for a core definition.
    pub fn retain(self: *Definition) void {
        if (self.counted()) self.hold();
    }

    /// `retain` of a definition known to be counted.
    inline fn hold(self: *Definition) void {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old != 0 and old != std.math.maxInt(u32));
    }

    /// Drops one reference; the last schedules bounded retirement. Nothing
    /// for a core definition.
    pub fn release(self: *Definition, releases: *heap.ReleaseDomain) void {
        if (self.counted()) self.drop(releases);
    }

    /// `release` of a definition known to be counted.
    inline fn drop(self: *Definition, releases: *heap.ReleaseDomain) void {
        const old = self.refs.fetchSub(1, .release);
        std.debug.assert(old != 0);
        if (old != 1) return;
        _ = self.refs.load(.acquire);
        releases.retire(self, &self.retirement);
    }

    /// Retires a core definition with its owning table.
    pub fn retireStatic(self: *Definition, releases: *heap.ReleaseDomain) void {
        std.debug.assert(!self.counted());
        releases.retire(self, &self.retirement);
    }

    /// Constant work: the dependencies retire as their own owner, one
    /// reference per step, so no definition walks a user-sized graph here.
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Definition,
    ) bool {
        switch (self.sealed) {
            .source => |storage| storage.free(releases),
            .builtin => {},
            .native => |callable| callable.instance.releasePin(),
        }
        self.freeMetadata(releases, allocator);
        return true;
    }

    fn freeMetadata(self: *Definition, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.effect) |effect| effect.retire(releases);
        if (self.doc) |doc| releases.releaseHeader(documentationHeader(doc));
        if (self.source) |source| {
            var owned = source;
            owned.deinit();
        }
        allocator.destroy(self);
    }
};

/// What a running activation must hold to keep its definition alive. A static
/// owner needs nothing. A counted definition is retained by each
/// activation running it and released when the activation ends; a tail call
/// secures the callee's owner before the caller's is released.
pub const Owner = union(enum) {
    static,
    /// Always a counted definition.
    definition: *Definition,

    // Inline, with the counted halves: every call of a source word takes
    // and drops its owner.
    pub inline fn retain(self: Owner) void {
        switch (self) {
            .static => {},
            .definition => |definition| definition.hold(),
        }
    }

    pub inline fn release(self: Owner, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .static => {},
            .definition => |definition| definition.drop(releases),
        }
    }

    pub fn eql(self: Owner, other: Owner) bool {
        return switch (self) {
            .static => other == .static,
            .definition => |definition| other == .definition and other.definition == definition,
        };
    }
};

/// A sealed definition body: its quotation, which keeps the literals and
/// source provenance, and the owner an activation running it holds. Each word
/// resolves when it is reached.
///
/// Opaque: its storage is embedded in its definition and reached only through
/// this handle, so nothing but creating a definition can make one.
pub const Executable = opaque {
    const Storage = struct {
        code: *value.ListHandle,
        owner: Owner,

        fn free(self: Storage, releases: *heap.ReleaseDomain) void {
            releases.releaseHeader(self.code);
        }
    };

    fn of(held: *const Storage) *const Executable {
        return @ptrCast(held);
    }

    inline fn storage(self: *const Executable) *const Storage {
        return @ptrCast(@alignCast(self));
    }

    /// The quotation it runs, which keeps its literals and provenance.
    pub inline fn code(self: *const Executable) *value.ListHandle {
        return self.storage().code;
    }

    /// What an activation running it must hold.
    pub inline fn owner(self: *const Executable) Owner {
        return self.storage().owner;
    }
};

/// A name's entry in a directory: a definition, or a name alias that every
/// later binding or lookup follows through the registry. An alias freezes
/// the mapping, never the target it selects.
pub const Entry = union(enum) {
    definition: *Definition,
    alias: Alias,

    pub fn retain(self: Entry) void {
        switch (self) {
            .definition => |definition| definition.retain(),
            .alias => {},
        }
    }

    pub fn release(self: Entry, releases: *heap.ReleaseDomain) void {
        switch (self) {
            .definition => |definition| definition.release(releases),
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
/// readers can reach them.
pub const NameMap = poll.FixedMap(intern.BindingName, Entry);

/// Core's directory, filled only while core is built. Core never imports or
/// aliases, so it holds definitions alone.
pub const CoreMap = poll.FixedMap(intern.BindingName, *Definition);

/// Which root a scope is. A session or core-building scope denotes the one
/// directory of its kind; a module root is the one scope of a module name,
/// which the `Env` owns and every registration of the name shares.
pub const ScopeStorage = union(enum) {
    session,
    core_build: CorePublisher,
    module_root: ModuleIdentity,
};

/// What a module root's scope records: the module's name and the id words
/// written in the module carry as their root.
pub const ModuleIdentity = struct {
    name: intern.ModuleName,
    id: ScopeId,
};

pub const Scope = struct {
    storage: ScopeStorage,
    /// Identifies this scope for as long as the process runs, which its
    /// address does not: a scope freed unpublished leaves its address to the
    /// next one. A cache that outlives a scope keys on this, never on the
    /// pointer.
    serial: u64,

    var next_serial: std.atomic.Value(u64) = .init(1);

    pub fn isModuleRoot(self: *const Scope) bool {
        return self.storage == .module_root;
    }

    /// The module whose root this scope is, or null for any other root.
    pub fn moduleName(self: *const Scope) ?intern.ModuleName {
        return switch (self.storage) {
            .module_root => |module| module.name,
            .session, .core_build => null,
        };
    }

    fn direct(storage: ScopeStorage) Scope {
        return .{ .storage = storage, .serial = next_serial.fetchAdd(1, .monotonic) };
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
    /// a static definition is never reclaimed, and core's meaning must not
    /// change under code that has already resolved it.
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
    heap.requireOpaqueMutation(CellPublisher);
}

/// Authority to write the cells of one `Env`, claimed once: by the registry
/// whose directories the cells answer from. The registry calls every method
/// with its writer lock held, which is what serializes cell stores.
pub const CellPublisher = enum(usize) {
    invalid = 0,
    _,

    fn target(self: CellPublisher) *EnvState {
        std.debug.assert(self != .invalid);
        return @ptrFromInt(@backingInt(self));
    }

    /// Stores what the cell `id` resolved to.
    pub fn fill(self: CellPublisher, id: CellId, definition: *Definition) void {
        self.target().word_cells.content(@backingInt(id)).store(definition);
    }

    /// Stores `definition`, or nothing, in every cell of the session's
    /// top-level name `name`. Bounded by the sources that wrote the name.
    pub fn define(self: CellPublisher, name: intern.BindingName, definition: ?*Definition) void {
        const state = self.target();
        state.word_cells.storeNamed(state.session_cell.id, name, definition);
    }

    /// Empties up to `count` cells from `from` that a registration can
    /// change, and returns the cell to continue from, or null at the end.
    pub fn emptyRegistered(self: CellPublisher, from: u32, count: u32) ?u32 {
        const state = self.target();
        return state.word_cells.emptyRegistered(state.core_cell.id, from, count);
    }
};

/// A root's stable public name: what a word's cell records as its root,
/// rather than a pointer. Zero means "no written-in scope" and resolves in
/// core.
///
/// Ids are issued monotonically and never recycled: one for core, one for
/// the session, and one for each module name, whatever number of times the
/// module is registered.
pub const ScopeId = enum(u32) { none = 0, _ };

/// How many bits of a `ScopeId` the scope directory indexes.
pub const id_bits: u5 = 24;

/// The root a `ScopeId` denotes.
pub const Root = union(enum) {
    /// Core alone: also what id zero, a word with no written-in scope, means.
    core,
    /// The session's top-level directory.
    session,
    /// The module registered under this name when the word is reached.
    module: intern.ModuleName,
};

/// The source a word was written in, or a module was registered under. `env`
/// stores and compares it and never interprets it.
pub const SourceId = @import("modules.zig").RegistrationProvenance;

/// Identifies one cell of the Session's `Env`: the link of a word occurrence.
/// Issued from 1, never reused, and always below `value.quote_flag`.
pub const CellId = enum(u32) { _ };

/// Where a linked word was written: the root it resolves in, the source
/// whose view of the module map it resolves under, and its spelling.
pub const Place = struct {
    root: ScopeId,
    name: u32,
    source: SourceId,
};

/// What a word's cell answers: the definition its place resolves to now, or
/// nothing, when the word is resolved by lookup. `primitive` is the code of
/// a builtin definition that belongs to no module, so running one reads no
/// definition. A cell borrows: a directory or an image owns the definition.
///
/// Written only under the registry's writer lock, or by the bootstrap fiber
/// while it is the only fiber; read by any fiber during a turn, with no
/// lock. Every load and store is sequentially consistent, by the proof of
/// `snapshot.Publisher`: a store made in the critical section that
/// supersedes a directory, followed by a rotation's read of the reader
/// counts, and a turn's count of itself followed by its load here, are two
/// store-then-load pairs on different atomics. In one total order either
/// the turn loads what the store left, or the rotation observes the turn,
/// so a turn never holds a definition whose last owner is reclaimed under
/// it. The two fields are stored separately, definition first, and each
/// is, alone, an answer that was current: a reader that finds the newer
/// `primitive` finds the newer `definition` after it.
pub const CellContent = struct {
    primitive: std.atomic.Value(?PrimitiveImpl) = .init(null),
    definition: std.atomic.Value(?*Definition) = .init(null),

    fn store(self: *CellContent, definition: ?*Definition) void {
        const primitive: ?PrimitiveImpl = if (definition) |found| switch (found.sealed) {
            .builtin => |code| if (found.root == .module) null else code,
            .source, .native => null,
        } else null;
        self.definition.store(definition, .seq_cst);
        self.primitive.store(primitive, .seq_cst);
    }
};

/// A fiber's way to the content of a cell from a word's link: one shift,
/// one load of a shelf address that never changes once set, and an index.
pub const WordCells = struct {
    shelves: *const [@bitSizeOf(u32)]std.atomic.Value(usize),

    /// The content of the cell `link` identifies. `link` is a cell id: not
    /// zero, and with no flag.
    pub inline fn of(self: WordCells, link: u32) *const CellContent {
        const biased = link + CellTable.first_id_bias;
        // A shelf's address is stored before any id in it is issued, and an
        // id reaches another thread only through a synchronized hand-off of
        // the symbol carrying it, which orders that store before this load.
        const base = self.shelves[@clz(biased)].load(.monotonic);
        return @ptrFromInt(base +% @as(usize, biased) * @sizeOf(CellContent));
    }
};

/// The cells of one `Env`: one per distinct place, appended and never moved
/// or freed before the `Env`.
///
/// A cell is in two parts, each on shelves that double in size, so a shelf
/// never relocates and an id decodes to a shelf and an offset by its leading
/// bit. What dispatch reads, the content, is sixteen bytes on shelves of its
/// own, four cells to a cache line; where the word was written and what its
/// spelling is, which only a lookup reads, is beside it under the same id.
/// A cell is complete before its id is returned.
///
/// The cell of a place is found, or minted, under `mutex`, which the
/// registry also takes inside its writer lock, never the reverse. A hash trie
/// threaded through the cells finds the first cell of a root and name: each
/// such cell heads up to four subtrees, chosen by successive two-bit digits
/// of the hash, so nothing is ever rehashed or relocated. The cells of one
/// root and name, one per source that wrote the name there, chain from it.
const CellTable = struct {
    const first_shelf_bits = 6;
    const first_id_bias = 1 << first_shelf_bits;
    const shelf_count = @bitSizeOf(u32) - @clz(value.quote_flag) - first_shelf_bits;

    const Cell = struct {
        place: Place,
        /// The cells heading the subtrees below this one; zero where none.
        children: [4]u32 = @splat(0),
        /// What the place's spelling is as a word, copied from the interned
        /// name when the cell is minted.
        spelling: intern.Spelling,
        /// The next cell of the same root and name; zero at the last.
        next_source: u32 = 0,
    };

    mutex: std.Io.Mutex = .init,
    shelves: [shelf_count]std.atomic.Value(?[*]Cell) = @splat(.init(null)),
    /// Each content shelf's address less the offset of the first biased id
    /// it holds, at the leading-zero count of those ids: a biased id scaled
    /// by the content's size and added lands on its content.
    contents: [@bitSizeOf(u32)]std.atomic.Value(usize) = @splat(.init(0)),
    /// The id the next minted cell takes.
    next: u32 = 1,
    /// The cell heading the trie; zero while there is none.
    head: u32 = 0,

    comptime {
        // The last id below the flag bits falls in the last shelf.
        if (coordinates(value.quote_flag - 1).shelf != shelf_count - 1)
            @compileError("cell shelves do not cover the link's id space");
    }

    fn coordinates(raw: u32) struct { shelf: usize, offset: usize } {
        const biased = raw + first_id_bias;
        const top: u5 = @intCast(@bitSizeOf(u32) - 1 - @clz(biased));
        return .{ .shelf = top - first_shelf_bits, .offset = biased - (@as(u32, 1) << top) };
    }

    fn shelfLength(shelf: usize) usize {
        return @as(usize, 1) << @intCast(shelf + first_shelf_bits);
    }

    fn reader(self: *const CellTable) WordCells {
        return .{ .shelves = &self.contents };
    }

    /// The cell `raw` identifies. `raw` was issued by this table.
    fn at(self: *const CellTable, raw: u32) *Cell {
        const where = coordinates(raw);
        return &self.shelves[where.shelf].load(.acquire).?[where.offset];
    }

    fn content(self: *const CellTable, raw: u32) *CellContent {
        return @constCast(self.reader().of(raw));
    }

    fn hash(root: ScopeId, name: u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&[2]u32{ @backingInt(root), name }));
    }

    /// The link to the first cell of `root` and `name`: zero where there is
    /// none yet. Under `mutex`.
    fn named(self: *CellTable, root: ScopeId, name: u32) *u32 {
        var link: *u32 = &self.head;
        var digits = hash(root, name);
        while (link.* != 0) : (digits <<= 2) {
            const cell = self.at(link.*);
            if (cell.place.root == root and cell.place.name == name) break;
            link = &cell.children[@intCast(digits >> 62)];
        }
        return link;
    }

    fn findOrMint(self: *CellTable, allocator: std.mem.Allocator, place: Place) error{OutOfMemory}!CellId {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        var link = self.named(place.root, place.name);
        while (link.* != 0) {
            const cell = self.at(link.*);
            if (cell.place.source == place.source) return @fromBackingInt(link.*);
            link = &cell.next_source;
        }
        const raw = self.next;
        if (raw >= value.quote_flag) return error.OutOfMemory;
        const where = coordinates(raw);
        const shelf = self.shelves[where.shelf].load(.acquire) orelse fresh: {
            const length = shelfLength(where.shelf);
            const cells = try allocator.alloc(Cell, length);
            errdefer allocator.free(cells);
            const contents = try allocator.alloc(CellContent, length);
            @memset(contents, .{});
            self.shelves[where.shelf].store(cells.ptr, .release);
            // The shelf holds the biased ids from its own length up.
            self.contents[@clz(raw + first_id_bias)].store(
                @intFromPtr(contents.ptr) -% length * @sizeOf(CellContent),
                .release,
            );
            break :fresh cells.ptr;
        };
        shelf[where.offset] = .{ .place = place, .spelling = intern.spelling(place.name) };
        self.next = raw + 1;
        link.* = raw;
        return @fromBackingInt(raw);
    }

    /// Stores `definition`, or nothing, as the answer of every cell of
    /// `root` and the plain name `name`: one per source that wrote it.
    fn storeNamed(self: *CellTable, root: ScopeId, name: intern.BindingName, definition: ?*Definition) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        var raw = self.named(root, intern.bindingId(name)).*;
        while (raw != 0) : (raw = self.at(raw).next_source) self.content(raw).store(definition);
    }

    /// Empties up to `count` cells from `from` whose answer a registration
    /// can change: every cell but a name of core, which is a `core.`
    /// spelling anywhere or a plain one written in core. Returns the cell
    /// to continue from, or null once every cell issued has been passed.
    fn emptyRegistered(self: *CellTable, core: ScopeId, from: u32, count: u32) ?u32 {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const end = @min(self.next, from +| count);
        for (from..end) |raw| {
            const cell = self.at(@intCast(raw));
            const of_core = switch (cell.spelling) {
                .core => true,
                .plain => cell.place.root == core,
                .qualified, .malformed => false,
            };
            if (!of_core) self.content(@intCast(raw)).store(null);
        }
        return if (end == self.next) null else end;
    }

    fn deinit(self: *CellTable, allocator: std.mem.Allocator) void {
        for (&self.shelves, 0..) |*shelf, index| if (shelf.load(.acquire)) |cells| {
            const length = shelfLength(index);
            allocator.free(cells[0..length]);
            const base = self.contents[@clz(@as(u32, @intCast(length)))].load(.monotonic);
            const contents: [*]CellContent = @ptrFromInt(base +% length * @sizeOf(CellContent));
            allocator.free(contents[0..length]);
        };
        self.* = undefined;
    }
};

/// How a producer of symbol occurrences links each one to the place it is
/// written in: a root and a source. A reader that links nothing carries
/// none, and every symbol it produces resolves in core.
pub const SymbolLinker = struct {
    state: *EnvState,
    root: ScopeId,
    source: SourceId,

    /// The link of the word `name` written here: the id of its cell, minted
    /// on first use.
    pub fn link(self: SymbolLinker, name: u32) error{OutOfMemory}!u32 {
        const id = try self.state.word_cells.findOrMint(
            self.state.host.allocator(),
            .{ .root = self.root, .name = name, .source = self.source },
        );
        return @backingInt(id);
    }
};

/// One issued scope id and the root it denotes, complete before its id is
/// registered and immutable after. The `Env` owns every one until teardown.
const ScopeCell = struct {
    id: ScopeId,
    root: Root,
};

/// One module name's root: its id and its scope, which live from the name's
/// first use to the `Env`'s teardown at one address.
const ModuleCell = struct {
    cell: ScopeCell,
    scope: Scope,
    /// The cells heading the subtrees below this one in the trie that finds
    /// a module's cell by name, read and written under
    /// `EnvState.modules_mutex`: successive two-bit digits of the name's
    /// hash choose the subtree, so nothing is rehashed or relocated.
    children: [4]?*ModuleCell = @splat(null),
    /// The module cell issued before this one, for teardown.
    previous: ?*ModuleCell = null,
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
/// drop. It denotes no place. Cell ids stay below it.
pub const local_operand_flag: u32 = 1 << 30;

/// See `value.quote_flag`. Cell ids stay below it. A locals operation carries
/// it only once it has been stored as data, where it pushes itself.
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
/// The quote flag is occurrence metadata beside the operand, so a quoted copy
/// of an operation decodes to the same operand.
pub fn localOperand(raw: u32) ?u32 {
    if (raw & local_operand_flag == 0) return null;
    return raw & ~(local_operand_flag | quote_flag);
}

/// What a word's link denotes.
pub const WordTarget = union(enum) {
    /// Built by the implementation for itself: resolves in core.
    unlinked,
    /// A lowered locals operation, with its count or index.
    local: u32,
    /// The cell recording where the word was written.
    cell: CellId,
};

/// Whether a link is the id of a cell: not zero, and with no flag.
pub inline fn isCell(link: u32) bool {
    return link -% 1 < quote_flag - 1;
}

/// A quoted occurrence's target is its link's: the flag says how it runs, not
/// where its name resolves.
pub fn wordTarget(raw_occurrence: u32) WordTarget {
    const raw = unquoted(raw_occurrence);
    if (raw == 0) return .unlinked;
    if (localOperand(raw)) |operand| return .{ .local = operand };
    return .{ .cell = @fromBackingInt(raw) };
}

const core_capacity_hint: usize = 2048;

const EnvState = struct {
    host: *const heap.HostCleanup,
    /// Core's directory: filled while core is built, immutable once frozen.
    core: CoreMap,
    core_frozen: bool = false,
    core_cell: ScopeCell,
    session_cell: ScopeCell,
    /// The cell heading the trie of module cells; null while there is none.
    modules_head: ?*ModuleCell = null,
    /// The module cell issued last, which chains every earlier one.
    modules_last: ?*ModuleCell = null,
    modules_mutex: std.Io.Mutex = .init,
    scopes: ScopeIndex = .{},
    word_cells: CellTable = .{},
    cells_claimed: bool = false,
    locals_words: intern.LocalsWords,
    idiom_names: idioms.Names,

    fn publishCore(self: *EnvState, name: intern.BindingName, definition: *Definition) CorePublisher.Error!void {
        // Core is fixed bootstrap input sized well inside its table, so a full
        // table is a bootstrap defect rather than a runtime condition.
        if (self.core.count() * 2 >= self.core.slots.len) return error.OutOfMemory;
        var lookup = self.core.rawLookup(name);
        const existing = poll.drive(?*Definition, &lookup, .{});
        if (existing != null) return error.Duplicate;
        var put = self.core.putCursor(name, definition);
        _ = poll.drive(bool, &put, .{});
        // The bootstrap fiber is the only fiber while core is built, so
        // this store races no reader and no other writer. A private
        // binding is not what a word of its name resolves to.
        if (definition.visibility == .public) self.word_cells.storeNamed(self.core_cell.id, name, definition);
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
        const idiom_names = try idioms.Names.mint();
        var core_init = CoreMap.initCursor(allocator, core_capacity_hint);
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
            .idiom_names = idiom_names,
            .core_cell = .{ .id = .none, .root = .core },
            .session_cell = .{ .id = .none, .root = .session },
        };
        errdefer {
            backing.scopes.deinit(allocator);
            backing.core.deinit();
            allocator.destroy(backing);
        }
        // Core and the session need real ids: a word linked to either refers
        // to it, and id zero would mean "unscoped".
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
            .item => |entry| entry.value.retireStatic(releases),
            .complete => break,
        };
        // Drain completely before freeing: a retiring definition may release
        // headers whose destruction reaches Env-owned cells.
        backing.host.drain();
        backing.core.deinit();
        var issued = backing.modules_last;
        while (issued) |cell| {
            issued = cell.previous;
            allocator.destroy(cell);
        }
        backing.scopes.deinit(allocator);
        backing.word_cells.deinit(allocator);
        allocator.destroy(backing);
        self.* = .consumed;
    }

    pub fn coreScopeId(self: *const Env) ScopeId {
        return self.privateState().core_cell.id;
    }

    pub fn sessionScopeId(self: *const Env) ScopeId {
        return self.privateState().session_cell.id;
    }

    /// The scope of module `name`, made on first use and kept until
    /// teardown: every registration of the name, and all code running as
    /// the module, shares it.
    pub fn moduleScope(self: *Env, name: intern.ModuleName) error{OutOfMemory}!*Scope {
        const backing = self.privateState();
        const allocator = backing.host.allocator();
        std.Io.Threaded.mutexLockUncancelable(&backing.modules_mutex);
        defer std.Io.Threaded.mutexUnlock(&backing.modules_mutex);
        var link: *?*ModuleCell = &backing.modules_head;
        var digits = std.hash.Wyhash.hash(0, std.mem.asBytes(&name));
        while (link.*) |module| : (digits <<= 2) {
            if (module.cell.root.module == name) return &module.scope;
            link = &module.children[@intCast(digits >> 62)];
        }
        const module = try allocator.create(ModuleCell);
        errdefer allocator.destroy(module);
        module.* = .{
            .cell = .{ .id = .none, .root = .{ .module = name } },
            .scope = Scope.direct(.{ .module_root = .{ .name = name, .id = .none } }),
            .previous = backing.modules_last,
        };
        // The cell is complete before its id exists: `register` is the one
        // point at which an id escapes into the lock-free directory. The
        // scope is found only through the trie, after it records the id.
        module.cell.id = try backing.scopes.register(allocator, &module.cell);
        module.scope.storage.module_root.id = module.cell.id;
        backing.modules_last = module;
        link.* = module;
        return &module.scope;
    }

    /// The domain definitions retire into.
    pub fn releaseDomain(self: *const Env) *heap.ReleaseDomain {
        return heap.hostDomain(self.privateState().host);
    }

    /// Links words written into the root `root` identifies by the source
    /// `source`.
    pub fn linker(self: *const Env, root: ScopeId, source: SourceId) SymbolLinker {
        return .{ .state = self.privateState(), .root = root, .source = source };
    }

    /// Where the word whose link is `id` was written. An index: no hash and
    /// no lock.
    pub fn place(self: *const Env, id: CellId) Place {
        return self.privateState().word_cells.at(@backingInt(id)).place;
    }

    /// A fiber's way to the content of this `Env`'s cells.
    pub fn wordCells(self: *const Env) WordCells {
        return self.privateState().word_cells.reader();
    }

    /// The one authority to write this `Env`'s cells, for its registry.
    pub fn claimCells(self: *Env) CellPublisher {
        const backing = self.privateState();
        std.debug.assert(!backing.cells_claimed);
        backing.cells_claimed = true;
        return @fromBackingInt(@intCast(@intFromPtr(backing)));
    }

    /// What the spelling of the word whose link is `id` is.
    pub fn spelling(self: *const Env, id: CellId) intern.Spelling {
        return self.privateState().word_cells.at(@backingInt(id)).spelling;
    }

    /// The root a word's root id denotes.
    pub fn scopeOf(self: *const Env, id: ScopeId) Root {
        if (id == .none) return .core;
        return self.privateState().scopes.get(id).?.root;
    }

    /// One lookup in core's directory. Core is immutable once frozen, and
    /// written only by the bootstrap fiber before then.
    pub fn coreLookup(self: *const Env, name: intern.BindingName) CoreMap.RawLookupCursor {
        return self.privateState().core.rawLookup(name);
    }

    /// Whether `name` is a public core word: what a definition of the same
    /// name in another root shadows for the code written there. One probe of
    /// core's frozen directory.
    pub fn isPublicCoreName(self: *const Env, name: intern.BindingName) bool {
        var cursor = self.coreLookup(name);
        while (true) switch (cursor.advance()) {
            .pending => {},
            .complete => |found| return if (found) |definition| definition.visibility == .public else false,
        };
    }

    /// Core's names, for enumeration.
    pub fn coreEntries(self: *const Env) CoreMap.RawEntryCursor {
        return self.privateState().core.rawEntries();
    }

    /// The reserved locals backend, bindable without a lookup in any scope.
    pub fn localsWords(self: *const Env) intern.LocalsWords {
        return self.privateState().locals_words;
    }

    /// The words idiom recognition compares, by interned name.
    pub fn idiomNames(self: *const Env) *const idioms.Names {
        return &self.privateState().idiom_names;
    }

    /// A fresh Env together with the one capability that may build its core.
    pub fn initBuilding(host_owner: *heap.HostOwner) error{OutOfMemory}!struct { Env, BuildingEnv } {
        const environment = try init(host_owner);
        return .{ environment, BuildingEnv.init(environment) };
    }

    /// A session root. Its holder owns the storage and frees it once no
    /// fiber runs in it.
    pub fn sessionRoot(_: *Env) Scope {
        return Scope.direct(.session);
    }

    pub fn createSessionRoot(self: *Env, allocator: std.mem.Allocator) error{OutOfMemory}!*Scope {
        const root = try allocator.create(Scope);
        root.* = self.sessionRoot();
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

    /// Only the static factory can pair authored metadata with its validated
    /// effect builder. Runtime installation never accepts an unchecked word.
    const StaticBuiltin = opaque {
        const Data = struct {
            definition: BuiltinWord,
        };

        fn init(comptime definition: BuiltinWord) *const StaticBuiltin {
            const data = comptime blk: {
                assertStaticBuiltin(definition);
                break :blk Data{ .definition = definition };
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
            const effect_value: ?value.Value = if (definition.effect) |source|
                try builtinEffectValue(allocator, releases, source)
            else
                null;
            defer if (effect_value) |item| releases.releaseValue(item);
            const created = try Definition.create(allocator, .{ .builtin = definition.primitive }, .{
                // assertStaticBuiltin checked this text against the same grammar.
                .effect = if (effect_value) |item| ValidatedEffect.parse(item.list).? else null,
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

    /// The Env under construction, for the bootstrap Fiber that evaluates the
    /// prelude against it. It grants no core publication; that stays here.
    pub fn runtime(self: *const BuildingEnv) Env {
        return self.target();
    }

    /// The root the bootstrap Fiber evaluates the prelude in. Its storage is the
    /// core publisher, which refuses once core is frozen.
    pub fn rootScope(self: *BuildingEnv) Scope {
        var environment = self.target();
        return Scope.direct(.{ .core_build = .init(environment.privateState()) });
    }

    /// Freezes core.
    pub fn finish(self: *BuildingEnv) void {
        var environment = self.target();
        environment.privateState().core_frozen = true;
        self.* = .invalid;
    }
};

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

test "env: a module name keeps one scope id, issued monotonically" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var container = try Env.init(&host);
    defer container.deinit();

    const issued = ScopeIndex.radix + 3;
    var previous: u32 = @backingInt(container.sessionScopeId());
    for (0..issued) |index| {
        var spelling: [24]u8 = undefined;
        const name = try intern.internModuleName(try std.fmt.bufPrint(&spelling, "scope-probe-{d}", .{index}));
        const scope = try container.moduleScope(name);
        // A name keeps the scope, and the id, it was first issued.
        try std.testing.expectEqual(scope, try container.moduleScope(name));
        try std.testing.expectEqual(name, scope.moduleName().?);
        const id = scope.storage.module_root.id;
        try std.testing.expectEqual(Root{ .module = name }, container.scopeOf(id));
        const raw = @backingInt(id);
        try std.testing.expect(raw != 0);
        try std.testing.expect(raw <= ScopeIndex.max_id);
        try std.testing.expect(raw > previous);
        previous = raw;
    }
}

test "env: a root, source and name link to one cell below the flag bits" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var container = try Env.init(&host);
    defer container.deinit();

    const here: SourceId = @fromBackingInt(1);
    const elsewhere: SourceId = @fromBackingInt(2);
    const session = container.linker(container.sessionScopeId(), here);
    // Enough names to spill past the first shelves of the table.
    var names: [1000]u32 = undefined;
    for (&names, 0..) |*name, index| {
        var spelled: [16]u8 = undefined;
        name.* = try intern.intern(try std.fmt.bufPrint(&spelled, "cell-test-{d}", .{index}));
    }
    var previous: u32 = 0;
    for (names) |name| {
        const link = try session.link(name);
        try std.testing.expect(link > previous);
        try std.testing.expect(link < value.quote_flag);
        try std.testing.expectEqual(WordTarget{ .cell = @fromBackingInt(link) }, wordTarget(link | quote_flag));
        previous = link;
    }
    for (names) |name| {
        const link = try session.link(name);
        try std.testing.expect(link <= previous);
        const written = container.place(@fromBackingInt(link));
        try std.testing.expectEqual(container.sessionScopeId(), written.root);
        try std.testing.expectEqual(here, written.source);
        try std.testing.expectEqual(name, written.name);
    }
    // Another source, and another root, write the same name somewhere else.
    const other_source = try container.linker(container.sessionScopeId(), elsewhere).link(names[0]);
    const other_root = try container.linker(container.coreScopeId(), here).link(names[0]);
    try std.testing.expect(other_source > previous);
    try std.testing.expect(other_root > other_source);
    try std.testing.expectEqual(elsewhere, container.place(@fromBackingInt(other_source)).source);
    try std.testing.expectEqual(container.coreScopeId(), container.place(@fromBackingInt(other_root)).root);
}
