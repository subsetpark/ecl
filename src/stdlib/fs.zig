//! Capability-gated filesystem words over Session-named root directories.
//!
//! Every word names a root by symbol and a canonical relative path; the
//! Session's filesystem owner turns the symbol into a retained directory
//! handle and `filesystem_port` resolves the path beneath it one component
//! per scheduler step. Reads, writes, copies, and listings advance in fixed
//! quanta; mutation stages into a private sibling entry and publishes with one
//! atomic namespace operation. The driver owns every handle, staging entry,
//! and quota reservation until its bounded retirement releases them.

const std = @import("std");
const dict = @import("../dict.zig");
const directory_order = @import("../directory_order.zig");
const env = @import("../env.zig");
const external = @import("../external.zig");
const fsport = @import("../filesystem_port.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const kernel_storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const poll = @import("../poll.zig");
const value = @import("../value.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Value = value.Value;
const work_quantum = machine.kernel_poll_quantum;

pub const words = [_]env.BuiltinWord{
    .{ .name = "read-bytes", .doc = "( root path -- bytes ) Read one regular file's exact bytes beneath a named root.", .primitive = readBytes },
    .{ .name = "read-text", .doc = "( root path -- string ) Read one regular UTF-8 file beneath a named root.", .primitive = readText },
    .{ .name = "create-bytes", .doc = "( bytes root path -- ) Atomically create an absent file from exact bytes.", .primitive = createBytes },
    .{ .name = "create-text", .doc = "( string root path -- ) Atomically create an absent UTF-8 file.", .primitive = createText },
    .{ .name = "replace-bytes", .doc = "( bytes root path -- ) Atomically replace an existing regular file with exact bytes.", .primitive = replaceBytes },
    .{ .name = "replace-text", .doc = "( string root path -- ) Atomically replace an existing regular file with UTF-8 text.", .primitive = replaceText },
    .{ .name = "stat", .doc = "( root path -- metadata ) Describe the object a path reaches, following a final link within the root.", .primitive = stat },
    .{ .name = "lstat", .doc = "( root path -- metadata ) Describe the final entry itself without following a link.", .primitive = lstat },
    .{ .name = "exists?", .doc = "( root path -- bool ) Return 1 when the final entry exists, without following it.", .primitive = exists },
    .{ .name = "list", .doc = "( root path -- entries ) List a directory's children as sorted name/kind dictionaries.", .primitive = listDirectory },
    .{ .name = "mkdir", .doc = "( root path -- ) Create exactly one absent directory beneath an existing parent.", .primitive = mkdir },
    .{ .name = "copy", .doc = "( source-root source-path destination-root destination-path -- ) Copy a regular file to an absent destination.", .primitive = copy },
    .{ .name = "rename", .doc = "( root source-path destination-path -- ) Rename an entry within one root without replacing.", .primitive = rename },
    .{ .name = "remove-file", .doc = "( root path -- ) Remove a non-directory entry without following a link.", .primitive = removeFile },
    .{ .name = "remove-dir", .doc = "( root path -- ) Remove an empty directory without following a link.", .primitive = removeDir },
};

const Operation = enum {
    read_bytes,
    read_text,
    create_bytes,
    create_text,
    replace_bytes,
    replace_text,
    stat,
    lstat,
    exists,
    list,
    mkdir,
    copy,
    rename,
    remove_file,
    remove_dir,

    fn name(self: Operation) []const u8 {
        return switch (self) {
            .read_bytes => "read-bytes",
            .read_text => "read-text",
            .create_bytes => "create-bytes",
            .create_text => "create-text",
            .replace_bytes => "replace-bytes",
            .replace_text => "replace-text",
            .exists => "exists?",
            .remove_file => "remove-file",
            .remove_dir => "remove-dir",
            .stat, .lstat, .list, .mkdir, .copy, .rename => @tagName(self),
        };
    }

    const Shape = enum { unary, payload, copy, rename };

    fn shape(self: Operation) Shape {
        return switch (self) {
            .create_bytes, .create_text, .replace_bytes, .replace_text => .payload,
            .copy => .copy,
            .rename => .rename,
            else => .unary,
        };
    }

    fn textPayload(self: Operation) bool {
        return self == .create_text or self == .replace_text;
    }

    /// The semantic grant the primary root must carry.
    fn permission(self: Operation) fsport.Permission {
        return switch (self) {
            .read_bytes, .read_text, .copy => .read_data,
            .stat, .lstat, .exists => .inspect,
            .list => .list,
            .create_bytes, .create_text, .mkdir => .create,
            .replace_bytes, .replace_text => .replace,
            .rename => .rename,
            .remove_file, .remove_dir => .remove,
        };
    }

    fn resolveMode(self: Operation) fsport.ResolveMode {
        return switch (self) {
            .read_bytes, .read_text, .stat, .list, .copy => .follow_final,
            else => .no_follow_final,
        };
    }

    /// Words that act on a child entry reject `.`, which names the root.
    fn requiresEntry(self: Operation) bool {
        return switch (self) {
            .create_bytes, .create_text, .replace_bytes, .replace_text, .mkdir, .rename, .remove_file, .remove_dir => true,
            .read_bytes, .read_text, .stat, .lstat, .exists, .list, .copy => false,
        };
    }
};

fn readBytes(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .read_bytes);
}
fn readText(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .read_text);
}
fn createBytes(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .create_bytes);
}
fn createText(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .create_text);
}
fn replaceBytes(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .replace_bytes);
}
fn replaceText(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .replace_text);
}
fn stat(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .stat);
}
fn lstat(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .lstat);
}
fn exists(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .exists);
}
fn listDirectory(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .list);
}
fn mkdir(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .mkdir);
}
fn copy(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .copy);
}
fn rename(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .rename);
}
fn removeFile(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .remove_file);
}
fn removeDir(evaluator: *Machine) MachineError!void {
    return begin(evaluator, .remove_dir);
}

/// The owned argument values, retained for error provenance until retirement.
const Inputs = struct {
    root: Value,
    path: Value,
    second_root: ?Value = null,
    second_path: ?Value = null,
    payload: ?Value = null,

    fn deinit(self: *Inputs, releases: *heap.ReleaseDomain) void {
        releases.releaseValue(self.root);
        releases.releaseValue(self.path);
        if (self.second_root) |item| releases.releaseValue(item);
        if (self.second_path) |item| releases.releaseValue(item);
        if (self.payload) |item| releases.releaseValue(item);
        // SAFETY: every owned value has been released; poisoning prevents an
        // accidental second release through this value.
        self.* = undefined;
    }
};

const Payload = union(enum) {
    bytes: kernel_storage.ByteVector,
    text: []u8,

    fn slice(self: *const Payload) []const u8 {
        return switch (self.*) {
            .bytes => |*bytes| bytes.bytes(),
            .text => |text| text,
        };
    }

    fn retire(self: *Payload, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bytes => |*bytes| bytes.retire(releases, allocator),
            .text => |text| allocator.free(text),
        }
        // SAFETY: the active payload has been released; poisoning prevents an
        // accidental second disposal through this value.
        self.* = undefined;
    }
};

fn begin(evaluator: *Machine, operation: Operation) MachineError!void {
    const count: usize = switch (operation.shape()) {
        .unary => 2,
        .payload, .rename => 3,
        .copy => 4,
    };
    try evaluator.require(count);
    // SAFETY: every arm of the switch below assigns the whole value before
    // it is read, and an arm that fails returns before reaching a read.
    var inputs: Inputs = undefined;
    switch (operation.shape()) {
        .unary => {
            var path = try evaluator.popValue();
            errdefer path.deinit();
            if (!path.borrow().isString()) return evaluator.typeError("a string path");
            var root = try evaluator.popValue();
            errdefer root.deinit();
            if (root.borrow() != .symbol) return evaluator.typeError("a root symbol");
            inputs = .{ .root = root.take(), .path = path.take() };
        },
        .payload => {
            var path = try evaluator.popValue();
            errdefer path.deinit();
            if (!path.borrow().isString()) return evaluator.typeError("a string path");
            var root = try evaluator.popValue();
            errdefer root.deinit();
            if (root.borrow() != .symbol) return evaluator.typeError("a root symbol");
            var payload = try evaluator.popValue();
            errdefer payload.deinit();
            if (operation.textPayload()) {
                if (!payload.borrow().isString()) return evaluator.typeError("a string to write");
            } else if (payload.borrow() != .list) return evaluator.typeError("a byte list to write");
            inputs = .{ .root = root.take(), .path = path.take(), .payload = payload.take() };
        },
        .copy => {
            var destination_path = try evaluator.popValue();
            errdefer destination_path.deinit();
            if (!destination_path.borrow().isString()) return evaluator.typeError("a string destination path");
            var destination_root = try evaluator.popValue();
            errdefer destination_root.deinit();
            if (destination_root.borrow() != .symbol) return evaluator.typeError("a destination root symbol");
            var source_path = try evaluator.popValue();
            errdefer source_path.deinit();
            if (!source_path.borrow().isString()) return evaluator.typeError("a string source path");
            var source_root = try evaluator.popValue();
            errdefer source_root.deinit();
            if (source_root.borrow() != .symbol) return evaluator.typeError("a source root symbol");
            inputs = .{
                .root = source_root.take(),
                .path = source_path.take(),
                .second_root = destination_root.take(),
                .second_path = destination_path.take(),
            };
        },
        .rename => {
            var destination_path = try evaluator.popValue();
            errdefer destination_path.deinit();
            if (!destination_path.borrow().isString()) return evaluator.typeError("a string destination path");
            var source_path = try evaluator.popValue();
            errdefer source_path.deinit();
            if (!source_path.borrow().isString()) return evaluator.typeError("a string source path");
            var root = try evaluator.popValue();
            errdefer root.deinit();
            if (root.borrow() != .symbol) return evaluator.typeError("a root symbol");
            heap.retainValue(root.borrow());
            inputs = .{
                .root = root.borrow(),
                .path = source_path.take(),
                .second_root = root.take(),
                .second_path = destination_path.take(),
            };
        },
    }
    errdefer inputs.deinit(evaluator.releaseDomain());
    const symbols = try Symbols.init(operation);
    const access = evaluator.unit.inherited.filesystem_access orelse
        return failInputs(evaluator, .domain, .unavailable, operation, symbols, &inputs);
    const driver = try evaluator.allocator().create(Driver);
    errdefer evaluator.allocator().destroy(driver);
    const path_cursor = kernel_storage.ToUtf8Cursor.init(evaluator.allocator(), inputs.path);
    driver.* = .{
        .allocator = evaluator.allocator(),
        .io = fsport.hostIo(access),
        .access = access,
        .limits = fsport.limitsOf(access),
        .operation = operation,
        .symbols = symbols,
        .inputs = inputs,
        .state = .{ .encode_path = path_cursor },
    };
    evaluator.adoptDriver(driver);
}

/// Interned spellings a failure or result needs, resolved before the driver
/// exists so later steps never allocate for a name.
const Symbols = struct {
    operation: u32,
    kind: u32,
    size: u32,
    name: u32,
    file: u32,
    directory: u32,
    symlink: u32,
    other: u32,

    fn init(operation: Operation) error{OutOfMemory}!Symbols {
        return .{
            .operation = try intern.intern(operation.name()),
            .kind = try intern.intern("kind"),
            .size = try intern.intern("size"),
            .name = try intern.intern("name"),
            .file = try intern.intern("file"),
            .directory = try intern.intern("directory"),
            .symlink = try intern.intern("symlink"),
            .other = try intern.intern("other"),
        };
    }

    fn entryKind(self: Symbols, kind: fsport.EntryKind) u32 {
        return switch (kind) {
            .file => self.file,
            .directory => self.directory,
            .symlink => self.symlink,
            .other => self.other,
        };
    }
};

fn reasonSymbol(reason: fsport.Reason) error{OutOfMemory}!u32 {
    return intern.intern(reason.symbol());
}

fn errorKindFor(reason: fsport.Reason) machine.ErrorKind {
    return switch (reason) {
        .invalid_path, .unknown_root, .denied, .unavailable => .domain,
        .limit => .overflow,
        else => .io,
    };
}

fn failInputs(
    evaluator: *Machine,
    kind: machine.ErrorKind,
    reason: fsport.Reason,
    operation: Operation,
    symbols: Symbols,
    inputs: *const Inputs,
) MachineError {
    const reason_symbol = try reasonSymbol(reason);
    const failure = evaluator.fail(kind, reason.message());
    evaluator.addErrorFilesystem(.{
        .operation = .{ .symbol = symbols.operation },
        .reason = .{ .symbol = reason_symbol },
        .target = if (operation == .copy) .{ .transfer = .{
            .source_root = inputs.root,
            .source_path = inputs.path,
            .destination_root = inputs.second_root.?,
            .destination_path = inputs.second_path.?,
        } } else .{ .single = .{ .root = inputs.root, .path = inputs.path } },
    });
    return failure;
}

const Listed = struct {
    name: []u8,
    kind: fsport.EntryKind,

    /// Names are valid UTF-8, so byte order is Unicode scalar order.
    fn lessThan(left: *const Listed, right: *const Listed) bool {
        return std.mem.order(u8, left.name, right.name) == .lt;
    }
};
const EntryList = poll.ChunkList(Listed);
const Orderer = directory_order.Orderer(Listed, Listed.lessThan);

const Driver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    access: *external.FilesystemAccess,
    limits: fsport.Limits,
    operation: Operation,
    symbols: Symbols,
    inputs: Inputs,
    path: ?[]u8 = null,
    second_path: ?[]u8 = null,
    payload: ?Payload = null,
    root: ?fsport.RootHandle = null,
    second_root: ?fsport.RootHandle = null,
    slot: ?fsport.OperationSlot = null,
    resolved: ?fsport.Resolved = null,
    second: ?fsport.Resolved = null,
    /// Listing storage handed from a build state to the value-release
    /// retirement steps, freed after every built value is released.
    pending_entries: ?EntryList = null,
    state: State,

    const Read = struct {
        file: std.Io.File,
        buffer: []u8,
        offset: usize = 0,
    };
    const Collect = struct {
        dir: std.Io.Dir,
        iterator: std.Io.Dir.Iterator,
        entries: EntryList,
        name_bytes: usize = 0,
    };
    const Ordering = struct {
        entries: EntryList,
        orderer: Orderer,
    };
    const Build = struct {
        entries: EntryList,
        sorted: []*const Listed,
        values: []Value,
        built: usize = 0,
        name: ?kernel_storage.Utf8Materializer = null,
    };
    const Result = struct {
        entries: EntryList,
        sorted: []*const Listed,
        values: []Value,
        built: usize,
        materializer: list.ValueMaterializer,
    };
    const Release = struct {
        entries: EntryList,
        sorted: []*const Listed,
        values: []Value,
        built: usize,
        index: usize = 0,
        result: Value,
    };
    const Write = struct {
        staged: fsport.StagedFile,
        offset: usize = 0,
    };
    const Copy = struct {
        file: std.Io.File,
        size: usize,
        offset: usize = 0,
        staged: fsport.StagedFile,
        buffer: []u8,
    };
    const State = union(enum) {
        encode_path: kernel_storage.ToUtf8Cursor,
        encode_second_path: kernel_storage.ToUtf8Cursor,
        encode_text: kernel_storage.StringEncoder,
        encode_bytes: kernel_storage.ByteVectorEncoder,
        authorize,
        resolve: fsport.Resolver,
        resolve_second: fsport.Resolver,
        act,
        read: Read,
        bytes_value: struct { buffer: []u8, materializer: list.ByteListMaterializer },
        text_value: struct { buffer: []u8, materializer: kernel_storage.Utf8Materializer },
        list_collect: Collect,
        list_order: Ordering,
        list_build: Build,
        list_result: Result,
        list_release: Release,
        write: Write,
        commit: fsport.StagedFile,
        copy: Copy,
        complete,
        /// Retirement-only: free listing entries one per step.
        cleanup_entries: struct { entries: EntryList, iterator: EntryList.Iterator },
        /// Retirement-only: release built values one per step.
        cleanup_values: struct { values: []Value, built: usize, index: usize },
        cleanup_done,
    };

    pub fn advance(evaluator: *Machine, self: *Driver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .encode_path => |*cursor| self.encodePath(evaluator, cursor, .primary),
            .encode_second_path => |*cursor| self.encodePath(evaluator, cursor, .second),
            .encode_text => |*encoder| self.encodeText(evaluator, encoder),
            .encode_bytes => |*encoder| self.encodeBytes(evaluator, encoder),
            .authorize => self.authorize(evaluator),
            .resolve => |*resolver| self.resolve(evaluator, resolver, .primary),
            .resolve_second => |*resolver| self.resolve(evaluator, resolver, .second),
            .act => self.act(evaluator),
            .read => |*read| self.readStep(evaluator, read),
            .bytes_value => |*building| self.materializeBytes(building),
            .text_value => |*building| self.materializeText(evaluator, building),
            .list_collect => |*collect| self.collectEntries(evaluator, collect),
            .list_order => |*ordering| self.orderEntries(ordering),
            .list_build => |*build| self.buildEntries(evaluator, build),
            .list_result => |*result| self.materializeEntries(result),
            .list_release => |*release| self.releaseEntries(evaluator, release),
            .write => |*write| self.writeStep(evaluator, write),
            .commit => |*staged| self.commitStep(evaluator, staged),
            .copy => |*copying| self.copyStep(evaluator, copying),
            .complete, .cleanup_entries, .cleanup_values, .cleanup_done => unreachable,
        };
    }

    const Which = enum { primary, second };

    fn fail(self: *Driver, evaluator: *Machine, reason: fsport.Reason) MachineError {
        return failInputs(evaluator, errorKindFor(reason), reason, self.operation, self.symbols, &self.inputs);
    }

    fn failMessage(self: *Driver, evaluator: *Machine, kind: machine.ErrorKind, reason: fsport.Reason, message: []const u8) MachineError {
        const reason_symbol = try reasonSymbol(reason);
        const failure = evaluator.fail(kind, message);
        evaluator.addErrorFilesystem(.{
            .operation = .{ .symbol = self.symbols.operation },
            .reason = .{ .symbol = reason_symbol },
            .target = if (self.operation == .copy) .{ .transfer = .{
                .source_root = self.inputs.root,
                .source_path = self.inputs.path,
                .destination_root = self.inputs.second_root.?,
                .destination_path = self.inputs.second_path.?,
            } } else .{ .single = .{ .root = self.inputs.root, .path = self.inputs.path } },
        });
        return failure;
    }

    fn encodePath(
        self: *Driver,
        evaluator: *Machine,
        cursor: *kernel_storage.ToUtf8Cursor,
        which: Which,
    ) MachineError!machine.WorkProgress {
        switch (cursor.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failMessage(evaluator, .domain, .invalid_path, "path contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |bytes| {
                cursor.deinit();
                switch (which) {
                    .primary => {
                        self.path = bytes;
                        if (self.inputs.second_path) |second| {
                            self.state = .{ .encode_second_path = .init(self.allocator, second) };
                        } else if (self.inputs.payload) |payload| {
                            self.state = if (self.operation.textPayload())
                                .{ .encode_text = .init(self.allocator, payload) }
                            else
                                .{ .encode_bytes = .init(self.allocator, payload) };
                        } else self.state = .authorize;
                    },
                    .second => {
                        self.second_path = bytes;
                        self.state = .authorize;
                    },
                }
                return .yielded;
            },
        }
    }

    fn encodeText(
        self: *Driver,
        evaluator: *Machine,
        encoder: *kernel_storage.StringEncoder,
    ) MachineError!machine.WorkProgress {
        switch (encoder.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failMessage(evaluator, .domain, .invalid_utf8, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |text| {
                encoder.deinit();
                self.payload = .{ .text = text };
                self.state = .authorize;
                return .yielded;
            },
        }
    }

    fn encodeBytes(
        self: *Driver,
        evaluator: *Machine,
        encoder: *kernel_storage.ByteVectorEncoder,
    ) MachineError!machine.WorkProgress {
        switch (encoder.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.failAtIndex(
                .type,
                "byte list members must be integers from 0 through 255",
                encoder.invalid_index.?,
            ),
        }) {
            .pending => return .yielded,
            .complete => |bytes| {
                encoder.deinit();
                self.payload = .{ .bytes = bytes };
                self.state = .authorize;
                return .yielded;
            },
        }
    }

    /// Grammar, root lookup, permission, and quota checks happen before any
    /// host object is opened.
    fn authorize(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const class = fsport.classifyPath(self.path.?) catch return self.fail(evaluator, .invalid_path);
        if (class == .root and self.operation.requiresEntry() and self.operation != .rename)
            return self.fail(evaluator, .invalid_path);
        if (self.second_path) |second| {
            const second_class = fsport.classifyPath(second) catch return self.fail(evaluator, .invalid_path);
            if (second_class == .root) return self.fail(evaluator, .invalid_path);
            if (self.operation == .rename and class == .root) return self.fail(evaluator, .invalid_path);
        }
        const root = fsport.findRoot(self.access, self.inputs.root.symbol) orelse
            return self.fail(evaluator, .unknown_root);
        if (!root.allows(self.operation.permission())) return self.fail(evaluator, .denied);
        self.root = root;
        if (self.inputs.second_root) |second_root_value| {
            const second_root = fsport.findRoot(self.access, second_root_value.symbol) orelse
                return self.fail(evaluator, .unknown_root);
            if (self.operation == .copy and !second_root.allows(.create)) return self.fail(evaluator, .denied);
            self.second_root = second_root;
        }
        if (self.payload) |*payload| {
            if (payload.slice().len > self.limits.max_transfer_bytes) return self.fail(evaluator, .limit);
        }
        self.slot = fsport.reserveOperation(self.access) orelse return self.fail(evaluator, .limit);
        if (class == .root) {
            self.resolved = .{ .directory = .{ .dir = root.dir(), .owned = false } };
            self.state = .act;
            return .yielded;
        }
        // Built into a local first: writing `try` straight into the union
        // could tag the state before the payload exists, and retirement would
        // then retire a resolver that was never constructed.
        const resolver = fsport.Resolver.init(
            self.allocator,
            self.io,
            root.dir(),
            self.path.?,
            self.limits,
            self.operation.resolveMode(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PathTooLong => return self.fail(evaluator, .limit),
        };
        self.state = .{ .resolve = resolver };
        return .yielded;
    }

    fn resolve(
        self: *Driver,
        evaluator: *Machine,
        resolver: *fsport.Resolver,
        which: Which,
    ) MachineError!machine.WorkProgress {
        switch (try resolver.step()) {
            .pending => return .yielded,
            .failed => |reason| return self.fail(evaluator, reason),
            .complete => |completed| {
                // Every allocation happens before the finished resolver is
                // retired, so an allocation failure leaves the state owning
                // exactly what retirement expects to release.
                var resolved = completed;
                switch (which) {
                    .primary => {
                        if (self.second_path) |second| {
                            const next = fsport.Resolver.init(
                                self.allocator,
                                self.io,
                                self.second_root.?.dir(),
                                second,
                                self.limits,
                                .no_follow_final,
                            ) catch |err| {
                                resolved.deinit(self.allocator, self.io);
                                return switch (err) {
                                    error.OutOfMemory => error.OutOfMemory,
                                    error.PathTooLong => self.fail(evaluator, .limit),
                                };
                            };
                            resolver.deinit();
                            self.resolved = resolved;
                            self.state = .{ .resolve_second = next };
                            return .yielded;
                        }
                        resolver.deinit();
                        self.resolved = resolved;
                    },
                    .second => {
                        resolver.deinit();
                        self.second = resolved;
                    },
                }
                self.state = .act;
                return .yielded;
            },
        }
    }

    fn act(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        return switch (self.operation) {
            .read_bytes, .read_text => self.beginRead(evaluator),
            .stat => self.inspect(evaluator, true),
            .lstat => self.inspect(evaluator, false),
            .exists => self.testExistence(evaluator),
            .list => self.beginList(evaluator),
            .mkdir => self.makeDirectory(evaluator),
            .remove_file => self.removeEntry(evaluator, .file),
            .remove_dir => self.removeEntry(evaluator, .directory),
            .rename => self.renameEntry(evaluator),
            .create_bytes, .create_text => self.beginStage(evaluator, .create),
            .replace_bytes, .replace_text => self.beginStage(evaluator, .replace),
            .copy => self.beginCopy(evaluator),
        };
    }

    // -- reads --------------------------------------------------------------

    fn beginRead(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const entry = switch (self.resolved.?) {
            .directory => return self.fail(evaluator, .is_directory),
            .entry => |entry| entry,
        };
        const file = switch (fsport.openRegularForRead(self.io, entry.parent.dir, entry.name)) {
            .failed => |reason| return self.fail(evaluator, reason),
            .file => |file| file,
        };
        const size = switch (fsport.regularFileSize(self.io, file, self.limits.max_transfer_bytes)) {
            .failed => |reason| {
                file.close(self.io);
                return self.fail(evaluator, reason);
            },
            .size => |size| size,
        };
        const buffer = self.allocator.alloc(u8, @intCast(size)) catch |err| {
            file.close(self.io);
            return err;
        };
        self.state = .{ .read = .{ .file = file, .buffer = buffer } };
        return .yielded;
    }

    fn readStep(self: *Driver, evaluator: *Machine, read: *Read) MachineError!machine.WorkProgress {
        switch (fsport.readQuantum(self.io, read.file, read.buffer, &read.offset)) {
            .pending => return .yielded,
            .failed => |reason| return self.fail(evaluator, reason),
            .complete => {},
        }
        read.file.close(self.io);
        const buffer = read.buffer;
        self.state = if (self.operation == .read_bytes)
            .{ .bytes_value = .{ .buffer = buffer, .materializer = .init(self.allocator, buffer) } }
        else
            .{ .text_value = .{ .buffer = buffer, .materializer = .init(self.allocator, buffer) } };
        return .yielded;
    }

    fn materializeBytes(
        self: *Driver,
        building: *@FieldType(State, "bytes_value"),
    ) MachineError!machine.WorkProgress {
        return switch (try building.materializer.advance(work_quantum)) {
            .pending => .yielded,
            .complete => |result| complete: {
                building.materializer.deinit();
                self.allocator.free(building.buffer);
                self.state = .complete;
                break :complete .{ .output = result };
            },
        };
    }

    fn materializeText(
        self: *Driver,
        evaluator: *Machine,
        building: *@FieldType(State, "text_value"),
    ) MachineError!machine.WorkProgress {
        return switch (building.materializer.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return self.failMessage(evaluator, .io, .invalid_utf8, "file is not valid UTF-8"),
        }) {
            .pending => .yielded,
            .complete => |result| complete: {
                building.materializer.deinit();
                self.allocator.free(building.buffer);
                self.state = .complete;
                break :complete .{ .output = result };
            },
        };
    }

    // -- metadata -----------------------------------------------------------

    fn inspect(self: *Driver, evaluator: *Machine, followed: bool) MachineError!machine.WorkProgress {
        const info: std.Io.File.Stat = switch (self.resolved.?) {
            .directory => |handle| handle.dir.stat(self.io) catch |err| return self.fail(evaluator, fsport.reasonForError(err)),
            .entry => |entry| entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err)),
        };
        const kind = fsport.EntryKind.fromHost(info.kind);
        if (followed and kind == .symlink) return self.fail(evaluator, .changed);
        const result = if (kind == .file)
            try dict.fromUniquePairs(self.allocator, evaluator.releaseDomain(), &.{
                .{ .{ .symbol = self.symbols.kind }, .{ .symbol = self.symbols.file } },
                .{ .{ .symbol = self.symbols.size }, .{ .int = std.math.cast(i64, info.size) orelse std.math.maxInt(i64) } },
            })
        else
            try dict.fromUniquePairs(self.allocator, evaluator.releaseDomain(), &.{
                .{ .{ .symbol = self.symbols.kind }, .{ .symbol = self.symbols.entryKind(kind) } },
            });
        self.state = .complete;
        return .{ .output = result };
    }

    fn testExistence(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const present: i64 = switch (self.resolved.?) {
            .directory => 1,
            .entry => |entry| present: {
                _ = entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => break :present 0,
                    else => return self.fail(evaluator, fsport.reasonForError(err)),
                };
                break :present 1;
            },
        };
        self.state = .complete;
        return .{ .output = .{ .int = present } };
    }

    // -- listing ------------------------------------------------------------

    fn beginList(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const dir = switch (self.resolved.?) {
            .directory => |handle| handle.dir.openDir(self.io, ".", .{ .iterate = true }) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err)),
            .entry => |entry| entry.parent.dir.openDir(self.io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.SymLinkLoop => return self.fail(evaluator, .changed),
                else => return self.fail(evaluator, fsport.reasonForError(err)),
            },
        };
        self.state = .{ .list_collect = .{
            .dir = dir,
            .iterator = dir.iterate(),
            .entries = .init(self.allocator),
        } };
        return .yielded;
    }

    fn collectEntries(self: *Driver, evaluator: *Machine, collect: *Collect) MachineError!machine.WorkProgress {
        var observed: usize = 0;
        var observed_bytes: usize = 0;
        while (observed < fsport.listing_batch_entries and observed_bytes < fsport.listing_batch_bytes) {
            const entry = collect.iterator.next(self.io) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err));
            const item = entry orelse {
                const orderer = try Orderer.init(self.allocator, &collect.entries);
                collect.dir.close(self.io);
                const entries = collect.entries;
                self.state = .{ .list_order = .{ .entries = entries, .orderer = orderer } };
                return .yielded;
            };
            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
            if (!std.unicode.utf8ValidateSlice(item.name)) return self.fail(evaluator, .invalid_utf8);
            if (collect.entries.count == self.limits.max_directory_entries) return self.fail(evaluator, .limit);
            collect.name_bytes = std.math.add(usize, collect.name_bytes, item.name.len) catch
                return self.fail(evaluator, .limit);
            if (collect.name_bytes > self.limits.max_directory_name_bytes) return self.fail(evaluator, .limit);
            const kind = if (item.kind == .unknown) classify: {
                const info = collect.dir.statFile(self.io, item.name, .{ .follow_symlinks = false }) catch |err|
                    return self.fail(evaluator, fsport.reasonForError(err));
                break :classify fsport.EntryKind.fromHost(info.kind);
            } else fsport.EntryKind.fromHost(item.kind);
            const name = try self.allocator.dupe(u8, item.name);
            collect.entries.append(.{ .name = name, .kind = kind }) catch |err| {
                self.allocator.free(name);
                return err;
            };
            observed += 1;
            observed_bytes += item.name.len;
        }
        return .yielded;
    }

    /// Ordering advances one bounded quantum per step; only the completed
    /// cursor yields the sorted pointers.
    fn orderEntries(self: *Driver, ordering: *Ordering) MachineError!machine.WorkProgress {
        if (ordering.orderer.advance(work_quantum) == .pending) return .yielded;
        const values = try self.allocator.alloc(Value, ordering.entries.count);
        const entries = ordering.entries;
        const sorted = ordering.orderer.take();
        self.state = .{ .list_build = .{ .entries = entries, .sorted = sorted, .values = values } };
        return .yielded;
    }

    fn buildEntries(self: *Driver, evaluator: *Machine, build: *Build) MachineError!machine.WorkProgress {
        var budget: usize = 64;
        while (budget != 0) : (budget -= 1) {
            if (build.built == build.sorted.len) {
                const entries = build.entries;
                const sorted = build.sorted;
                const values = build.values;
                self.state = .{ .list_result = .{
                    .entries = entries,
                    .sorted = sorted,
                    .values = values,
                    .built = build.built,
                    .materializer = .init(self.allocator, values),
                } };
                return .yielded;
            }
            const entry = build.sorted[build.built];
            if (build.name == null) build.name = .init(self.allocator, entry.name);
            const name_value = switch (build.name.?.advance(work_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return self.fail(evaluator, .invalid_utf8),
            }) {
                .pending => return .yielded,
                .complete => |name_value| name_value,
            };
            build.name.?.deinit();
            build.name = null;
            defer evaluator.releaseDomain().releaseValue(name_value);
            build.values[build.built] = try dict.fromUniquePairs(self.allocator, evaluator.releaseDomain(), &.{
                .{ .{ .symbol = self.symbols.name }, name_value },
                .{ .{ .symbol = self.symbols.kind }, .{ .symbol = self.symbols.entryKind(entry.kind) } },
            });
            build.built += 1;
        }
        return .yielded;
    }

    fn materializeEntries(self: *Driver, result: *Result) MachineError!machine.WorkProgress {
        return switch (try result.materializer.advance(work_quantum)) {
            .pending => .yielded,
            .complete => |listing| complete: {
                result.materializer.deinit();
                const entries = result.entries;
                const sorted = result.sorted;
                const values = result.values;
                self.state = .{ .list_release = .{
                    .entries = entries,
                    .sorted = sorted,
                    .values = values,
                    .built = result.built,
                    .result = listing,
                } };
                break :complete .yielded;
            },
        };
    }

    /// The listing retains its element dictionaries, so the construction
    /// inputs release one per step before the result is published.
    fn releaseEntries(self: *Driver, evaluator: *Machine, release: *Release) MachineError!machine.WorkProgress {
        var budget: usize = 64;
        while (budget != 0 and release.index != release.built) : (budget -= 1) {
            evaluator.releaseDomain().releaseValue(release.values[release.index]);
            release.index += 1;
        }
        if (release.index != release.built) return .yielded;
        self.allocator.free(release.values);
        self.allocator.free(release.sorted);
        const result = release.result;
        const entries = release.entries;
        // Entry names are freed one per retirement step after the result is
        // published; nothing else remains to build.
        self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
        return .{ .output = result };
    }

    // -- single-entry mutation ----------------------------------------------

    fn requireEntry(self: *Driver, evaluator: *Machine, resolved: fsport.Resolved) MachineError!@FieldType(fsport.Resolved, "entry") {
        return switch (resolved) {
            .directory => self.fail(evaluator, .invalid_path),
            .entry => |entry| entry,
        };
    }

    fn makeDirectory(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        entry.parent.dir.createDir(self.io, entry.name, .default_dir) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        self.state = .complete;
        return .completed;
    }

    const RemoveKind = enum { file, directory };

    fn removeEntry(self: *Driver, evaluator: *Machine, kind: RemoveKind) MachineError!machine.WorkProgress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        const info = entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        switch (kind) {
            .file => {
                if (info.kind == .directory) return self.fail(evaluator, .is_directory);
                entry.parent.dir.deleteFile(self.io, entry.name) catch |err|
                    return self.fail(evaluator, fsport.reasonForError(err));
            },
            .directory => {
                if (info.kind != .directory) return self.fail(evaluator, .not_directory);
                entry.parent.dir.deleteDir(self.io, entry.name) catch |err|
                    return self.fail(evaluator, fsport.reasonForError(err));
            },
        }
        self.state = .complete;
        return .completed;
    }

    fn renameEntry(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const source = try self.requireEntry(evaluator, self.resolved.?);
        const destination = try self.requireEntry(evaluator, self.second.?);
        fsport.renameNoReplace(self.io, source.parent.dir, source.name, destination.parent.dir, destination.name) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        self.state = .complete;
        return .completed;
    }

    // -- staged publication -------------------------------------------------

    const StageMode = enum { create, replace };

    fn beginStage(self: *Driver, evaluator: *Machine, mode: StageMode) MachineError!machine.WorkProgress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        const existing = entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return self.fail(evaluator, fsport.reasonForError(err)),
        };
        switch (mode) {
            .create => if (existing != null) return self.fail(evaluator, .already_exists),
            .replace => {
                const info = existing orelse return self.fail(evaluator, .not_found);
                if (info.kind != .file) return self.fail(evaluator, .not_regular);
            },
        }
        const staged = switch (fsport.StagedFile.create(self.io, entry.parent.dir, .default_file)) {
            .failed => |reason| return self.fail(evaluator, reason),
            .staged => |staged| staged,
        };
        self.state = .{ .write = .{ .staged = staged } };
        return .yielded;
    }

    fn writeStep(self: *Driver, evaluator: *Machine, write: *Write) MachineError!machine.WorkProgress {
        switch (fsport.writeQuantum(self.io, write.staged.file.?, self.payload.?.slice(), &write.offset)) {
            .pending => return .yielded,
            .failed => |reason| return self.fail(evaluator, reason),
            .complete => {},
        }
        const staged = write.staged;
        self.state = .{ .commit = staged };
        return .yielded;
    }

    /// Publication is its own step so cancellation is observed after the
    /// last write and before the one commit syscall.
    fn commitStep(self: *Driver, evaluator: *Machine, staged: *fsport.StagedFile) MachineError!machine.WorkProgress {
        // A copy publishes into its destination entry; every other staged
        // word publishes into the primary one.
        const entry = if (self.operation == .copy) self.second.?.entry else self.resolved.?.entry;
        const failed: ?fsport.Reason = switch (self.operation) {
            .replace_bytes, .replace_text => staged.commitExchange(entry.name),
            else => staged.commitNoReplace(entry.name),
        };
        if (failed) |reason| return self.fail(evaluator, reason);
        // After an exchange the displaced original sits under the staging
        // name; the mutation has committed either way, so disposal failure is
        // not reported as operation failure.
        if (staged.displaced) staged.dispose();
        self.state = .complete;
        return .completed;
    }

    // -- copy ---------------------------------------------------------------

    fn beginCopy(self: *Driver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const source = switch (self.resolved.?) {
            .directory => return self.fail(evaluator, .not_regular),
            .entry => |entry| entry,
        };
        const destination = try self.requireEntry(evaluator, self.second.?);
        const existing = destination.parent.dir.statFile(self.io, destination.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return self.fail(evaluator, fsport.reasonForError(err)),
        };
        if (existing != null) return self.fail(evaluator, .already_exists);
        const file = switch (fsport.openRegularForRead(self.io, source.parent.dir, source.name)) {
            .failed => |reason| return self.fail(evaluator, reason),
            .file => |file| file,
        };
        const size = switch (fsport.regularFileSize(self.io, file, self.limits.max_transfer_bytes)) {
            .failed => |reason| {
                file.close(self.io);
                return self.fail(evaluator, reason);
            },
            .size => |size| size,
        };
        const buffer = self.allocator.alloc(u8, fsport.transfer_quantum) catch |err| {
            file.close(self.io);
            return err;
        };
        const staged = switch (fsport.StagedFile.create(self.io, destination.parent.dir, .default_file)) {
            .failed => |reason| {
                file.close(self.io);
                self.allocator.free(buffer);
                return self.fail(evaluator, reason);
            },
            .staged => |staged| staged,
        };
        self.state = .{ .copy = .{
            .file = file,
            .size = @intCast(size),
            .staged = staged,
            .buffer = buffer,
        } };
        return .yielded;
    }

    fn copyStep(self: *Driver, evaluator: *Machine, copying: *Copy) MachineError!machine.WorkProgress {
        if (copying.offset == copying.size) {
            var probe: [1]u8 = undefined;
            const extra = copying.file.readPositionalAll(self.io, &probe, copying.size) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err));
            if (extra != 0) return self.fail(evaluator, .changed);
            copying.file.close(self.io);
            self.allocator.free(copying.buffer);
            const staged = copying.staged;
            self.state = .{ .commit = staged };
            return .yielded;
        }
        const end = @min(copying.offset + fsport.transfer_quantum, copying.size);
        const chunk = copying.buffer[0 .. end - copying.offset];
        const amount = copying.file.readPositionalAll(self.io, chunk, copying.offset) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        if (amount != chunk.len) return self.fail(evaluator, .changed);
        copying.staged.file.?.writePositionalAll(self.io, chunk, copying.offset) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        copying.offset = end;
        return .yielded;
    }

    // -- retirement ---------------------------------------------------------

    /// Terminal cleanup, one bounded step per call. Handles close, an
    /// unpublished staging entry is unlinked, listing storage is freed one
    /// entry per step, and the quota slot is released last.
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Driver,
    ) bool {
        switch (self.state) {
            .encode_path, .encode_second_path => |*cursor| cursor.deinit(),
            .encode_text => |*encoder| encoder.deinit(),
            .encode_bytes => |*encoder| encoder.deinit(),
            .authorize, .act, .complete => {},
            .resolve, .resolve_second => |*resolver| resolver.deinit(),
            .read => |*read| {
                read.file.close(self.io);
                allocator.free(read.buffer);
            },
            .bytes_value => |*building| {
                building.materializer.retire(releases);
                allocator.free(building.buffer);
            },
            .text_value => |*building| {
                building.materializer.retire(releases);
                allocator.free(building.buffer);
            },
            .list_collect => |*collect| {
                collect.dir.close(self.io);
                const entries = collect.entries;
                self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
                return false;
            },
            .list_order => |*ordering| {
                ordering.orderer.deinit();
                const entries = ordering.entries;
                self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
                return false;
            },
            .list_build => |*build| {
                if (build.name) |*name| name.retire(releases);
                allocator.free(build.sorted);
                const entries = build.entries;
                const values = build.values;
                const built = build.built;
                self.state = .{ .cleanup_values = .{ .values = values, .built = built, .index = 0 } };
                self.pending_entries = entries;
                return false;
            },
            .list_result => |*result| {
                result.materializer.retire(releases);
                allocator.free(result.sorted);
                const entries = result.entries;
                self.state = .{ .cleanup_values = .{ .values = result.values, .built = result.built, .index = 0 } };
                self.pending_entries = entries;
                return false;
            },
            .list_release => |*release| {
                releases.releaseValue(release.result);
                allocator.free(release.sorted);
                const entries = release.entries;
                self.state = .{ .cleanup_values = .{ .values = release.values, .built = release.built, .index = release.index } };
                self.pending_entries = entries;
                return false;
            },
            .write => |*write| write.staged.dispose(),
            .commit => |*staged| staged.dispose(),
            .copy => |*copying| {
                copying.file.close(self.io);
                allocator.free(copying.buffer);
                copying.staged.dispose();
            },
            .cleanup_values => |*cleanup| {
                if (cleanup.index != cleanup.built) {
                    releases.releaseValue(cleanup.values[cleanup.index]);
                    cleanup.index += 1;
                    return false;
                }
                allocator.free(cleanup.values);
                const entries = self.pending_entries.?;
                self.pending_entries = null;
                self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
                return false;
            },
            .cleanup_entries => |*cleanup| {
                if (cleanup.iterator.next()) |entry| {
                    allocator.free(entry.name);
                    return false;
                }
                cleanup.entries.retire(releases);
                self.state = .cleanup_done;
                return false;
            },
            .cleanup_done => {},
        }
        if (self.resolved) |*resolved| resolved.deinit(allocator, self.io);
        if (self.second) |*resolved| resolved.deinit(allocator, self.io);
        if (self.payload) |*payload| payload.retire(releases, allocator);
        if (self.path) |path| allocator.free(path);
        if (self.second_path) |path| allocator.free(path);
        self.inputs.deinit(releases);
        if (self.slot) |*slot| slot.release();
        allocator.destroy(self);
        return true;
    }
};
