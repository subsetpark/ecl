//! Session-owned filesystem authority behind named root directory handles.
//!
//! A `FilesystemPolicy` names directories once, at Session construction; every
//! later operation is descriptor-relative to the retained handle for the root
//! an ECL program names by symbol. The resolver walks one component per step
//! with `O_NOFOLLOW`, splices symlink targets into its own bounded input, and
//! keeps a handle stack anchored at the root so a relative `..` can pop only
//! within the capability. No path string is ever turned back into an absolute
//! host path after construction, and no operation reopens a root by name.
//!
//! The same file also owns the bounded read, staging, and atomic publication
//! primitives shared by the `fs` module, archive extraction, and the package
//! store, so the no-clobber and exchange contracts have exactly one
//! implementation per platform.

const std = @import("std");
const builtin = @import("builtin");
const external = @import("external.zig");
const intern = @import("intern.zig");

pub const Permission = enum {
    read_data,
    inspect,
    list,
    create,
    replace,
    rename,
    remove,

    pub fn symbol(self: Permission) []const u8 {
        return switch (self) {
            .read_data => "read-data",
            else => @tagName(self),
        };
    }
};

pub const Permissions = packed struct {
    read_data: bool = false,
    inspect: bool = false,
    list: bool = false,
    create: bool = false,
    replace: bool = false,
    rename: bool = false,
    remove: bool = false,

    pub const all: Permissions = .{
        .read_data = true,
        .inspect = true,
        .list = true,
        .create = true,
        .replace = true,
        .rename = true,
        .remove = true,
    };
    pub const none: Permissions = .{};

    pub fn allows(self: Permissions, permission: Permission) bool {
        return switch (permission) {
            .read_data => self.read_data,
            .inspect => self.inspect,
            .list => self.list,
            .create => self.create,
            .replace => self.replace,
            .rename => self.rename,
            .remove => self.remove,
        };
    }
};

pub const Limits = struct {
    max_transfer_bytes: u64 = 1 << 30,
    max_directory_entries: usize = 100_000,
    max_directory_name_bytes: usize = 64 << 20,
    max_live_operations: usize = 64,
    max_symlink_expansions: usize = 40,
    max_resolved_path_bytes: usize = 64 << 10,
};

/// One borrowed root description. `FilesystemOwner.init` copies the name and
/// opens the directory once; the path is never consulted again.
pub const Root = struct {
    name: []const u8,
    absolute_path: []const u8,
    permissions: Permissions,
};

/// Borrowed host policy. Every slice is copied during Session construction.
pub const FilesystemPolicy = struct {
    roots: []const Root,
    limits: Limits = .{},
};

pub const PolicyError = error{ OutOfMemory, InvalidPolicy };

pub fn backendSupported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

/// The bounded transfer quantum for reads, writes, and copies.
pub const transfer_quantum: usize = 64 * 1024;
/// Directory entries observed per driver advance.
pub const listing_batch_entries: usize = 256;
/// Directory name bytes observed per driver advance.
pub const listing_batch_bytes: usize = 64 * 1024;

const OwnedRoot = struct {
    name: []u8,
    symbol: u32,
    permissions: Permissions,
    dir: std.Io.Dir,
};

/// Session-owned authority. Units never receive this owner; they receive the
/// opaque `external.FilesystemAccess` and the narrow functions below.
pub const FilesystemOwner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: []OwnedRoot,
    limits: Limits,
    live: std.atomic.Value(usize) = .init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        policy: FilesystemPolicy,
    ) PolicyError!FilesystemOwner {
        if (comptime !backendSupported()) return error.InvalidPolicy;
        try validateLimits(policy.limits);
        for (policy.roots, 0..) |root, index| {
            if (!validRootName(root.name)) return error.InvalidPolicy;
            if (!std.fs.path.isAbsolute(root.absolute_path) or
                std.mem.indexOfScalar(u8, root.absolute_path, 0) != null)
                return error.InvalidPolicy;
            for (policy.roots[0..index]) |prior| {
                if (std.mem.eql(u8, prior.name, root.name)) return error.InvalidPolicy;
            }
        }
        const roots = try allocator.alloc(OwnedRoot, policy.roots.len);
        var initialized: usize = 0;
        errdefer {
            for (roots[0..initialized]) |*root| {
                root.dir.close(io);
                allocator.free(root.name);
            }
            allocator.free(roots);
        }
        for (policy.roots, roots) |root, *owned| {
            const name = try allocator.dupe(u8, root.name);
            errdefer allocator.free(name);
            const symbol = try intern.intern(root.name);
            // A configured root path is trusted host input and may resolve
            // through host symlinks exactly once, here. Authority is the
            // retained handle from this point on.
            const dir = std.Io.Dir.cwd().openDir(io, root.absolute_path, .{ .iterate = true }) catch
                return error.InvalidPolicy;
            owned.* = .{
                .name = name,
                .symbol = symbol,
                .permissions = root.permissions,
                .dir = dir,
            };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .roots = roots,
            .limits = policy.limits,
        };
    }

    pub fn deinit(self: *FilesystemOwner) void {
        std.debug.assert(self.live.load(.acquire) == 0);
        for (self.roots) |*root| {
            root.dir.close(self.io);
            self.allocator.free(root.name);
        }
        self.allocator.free(self.roots);
        self.* = undefined;
    }

    pub fn access(self: *FilesystemOwner) *external.FilesystemAccess {
        return @ptrCast(self);
    }

    fn reserveLive(self: *FilesystemOwner) bool {
        var observed = self.live.load(.acquire);
        while (observed < self.limits.max_live_operations) {
            if (self.live.cmpxchgWeak(observed, observed + 1, .acq_rel, .acquire)) |actual|
                observed = actual
            else
                return true;
        }
        return false;
    }

    fn releaseLive(self: *FilesystemOwner) void {
        const old = self.live.fetchSub(1, .acq_rel);
        std.debug.assert(old != 0);
    }
};

fn validateLimits(limits: Limits) PolicyError!void {
    if (limits.max_transfer_bytes == 0 or limits.max_directory_entries == 0 or
        limits.max_directory_name_bytes == 0 or limits.max_live_operations == 0 or
        limits.max_symlink_expansions == 0 or limits.max_resolved_path_bytes == 0)
        return error.InvalidPolicy;
    if (limits.max_transfer_bytes > std.math.maxInt(usize)) return error.InvalidPolicy;
}

/// A root name is spelled as an ECL symbol by programs, so it must be a
/// printable, delimiter-free, valid-UTF-8 atom.
pub fn validRootName(name: []const u8) bool {
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| {
        if (byte <= ' ' or byte == 0x7f) return false;
        if (std.mem.indexOfScalar(u8, "()[]{}\"'#", byte) != null) return false;
    }
    return true;
}

fn ownerFromAccess(access_value: *external.FilesystemAccess) *FilesystemOwner {
    return @ptrCast(@alignCast(access_value));
}

/// A resolved root selection: an index into the owner's table. It carries no
/// handle authority of its own beyond the borrowed directory it names.
pub const RootHandle = struct {
    owner: *FilesystemOwner,
    index: usize,

    pub fn dir(self: RootHandle) std.Io.Dir {
        return self.owner.roots[self.index].dir;
    }

    pub fn allows(self: RootHandle, permission: Permission) bool {
        return self.owner.roots[self.index].permissions.allows(permission);
    }

    pub fn name(self: RootHandle) []const u8 {
        return self.owner.roots[self.index].name;
    }

    pub fn same(self: RootHandle, other: RootHandle) bool {
        return self.owner == other.owner and self.index == other.index;
    }
};

pub fn findRoot(access_value: *external.FilesystemAccess, symbol: u32) ?RootHandle {
    const owner = ownerFromAccess(access_value);
    for (owner.roots, 0..) |root, index| {
        if (root.symbol == symbol) return .{ .owner = owner, .index = index };
    }
    return null;
}

pub fn limitsOf(access_value: *external.FilesystemAccess) Limits {
    return ownerFromAccess(access_value).limits;
}

pub fn hostIo(access_value: *external.FilesystemAccess) std.Io {
    return ownerFromAccess(access_value).io;
}

/// A live-operation slot is a consuming capability released exactly once
/// after the operation's terminal cleanup.
pub const OperationSlot = struct {
    owner: ?*FilesystemOwner,

    pub fn release(self: *OperationSlot) void {
        const owner = self.owner orelse return;
        self.owner = null;
        owner.releaseLive();
    }
};

pub fn reserveOperation(access_value: *external.FilesystemAccess) ?OperationSlot {
    const owner = ownerFromAccess(access_value);
    if (!owner.reserveLive()) return null;
    return .{ .owner = owner };
}

/// The closed portable failure vocabulary. Host error names never reach a
/// program as data; every syscall failure maps here exactly once.
pub const Reason = enum {
    invalid_path,
    unknown_root,
    denied,
    not_found,
    already_exists,
    not_directory,
    is_directory,
    not_regular,
    not_empty,
    symlink_loop,
    symlink_escape,
    invalid_utf8,
    limit,
    access_denied,
    read_only,
    no_space,
    busy,
    cross_device,
    unsupported,
    unavailable,
    changed,
    io,

    pub fn symbol(self: Reason) []const u8 {
        return switch (self) {
            .invalid_path => "invalid-path",
            .unknown_root => "unknown-root",
            .not_found => "not-found",
            .already_exists => "already-exists",
            .not_directory => "not-directory",
            .is_directory => "is-directory",
            .not_regular => "not-regular",
            .not_empty => "not-empty",
            .symlink_loop => "symlink-loop",
            .symlink_escape => "symlink-escape",
            .invalid_utf8 => "invalid-utf8",
            .access_denied => "access-denied",
            .read_only => "read-only",
            .no_space => "no-space",
            .cross_device => "cross-device",
            else => @tagName(self),
        };
    }

    pub fn message(self: Reason) []const u8 {
        return switch (self) {
            .invalid_path => "path is not a canonical relative path",
            .unknown_root => "unknown filesystem root",
            .denied => "filesystem root denies the operation",
            .not_found => "entry does not exist",
            .already_exists => "entry already exists",
            .not_directory => "entry is not a directory",
            .is_directory => "entry is a directory",
            .not_regular => "entry is not a regular file",
            .not_empty => "directory is not empty",
            .symlink_loop => "symlink expansion limit reached",
            .symlink_escape => "symlink target escapes the root",
            .invalid_utf8 => "bytes are not valid UTF-8",
            .limit => "filesystem operation limit reached",
            .access_denied => "host denied access",
            .read_only => "filesystem is read-only",
            .no_space => "filesystem has no space",
            .busy => "entry is busy",
            .cross_device => "operation crosses devices",
            .unsupported => "operation is unsupported by the host",
            .unavailable => "filesystem access is unavailable",
            .changed => "entry changed during the operation",
            .io => "host filesystem operation failed",
        };
    }
};

/// The one mapping from Zig host errors to the portable vocabulary.
pub fn reasonForError(err: anyerror) Reason {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.PathAlreadyExists => .already_exists,
        error.NotDir => .not_directory,
        error.IsDir => .is_directory,
        error.DirNotEmpty => .not_empty,
        error.SymLinkLoop => .symlink_loop,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.ReadOnlyFileSystem => .read_only,
        error.NoSpaceLeft, error.DiskQuota => .no_space,
        error.FileBusy, error.DeviceBusy, error.PipeBusy, error.WouldBlock => .busy,
        error.CrossDevice => .cross_device,
        error.OperationUnsupported, error.Unsupported, error.FileLocksUnsupported => .unsupported,
        error.NameTooLong,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.LinkQuotaExceeded,
        error.FileTooBig,
        => .limit,
        else => .io,
    };
}

pub const PathClass = enum { root, entry };

/// The canonical `fs` path grammar. `.` names the root itself; every other
/// path is one or more nonempty components separated by exactly one `/`, with
/// no `.`, `..`, NUL, leading, trailing, or repeated separators. Normalization
/// is never applied here: a caller normalizes first and accepts the result
/// separately, so a string is never treated as proof of containment.
pub fn classifyPath(path: []const u8) error{InvalidPath}!PathClass {
    if (std.mem.eql(u8, path, ".")) return .root;
    if (path.len == 0 or path[0] == '/' or path[path.len - 1] == '/') return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..") or
            std.mem.indexOfScalar(u8, component, 0) != null)
            return error.InvalidPath;
    }
    return .entry;
}

/// One directory handle reached by resolution. The configured root is
/// borrowed from its owner; every other handle was opened by the resolver and
/// is closed by whoever takes it.
pub const ParentHandle = struct {
    dir: std.Io.Dir,
    owned: bool,

    pub fn close(self: *ParentHandle, io: std.Io) void {
        if (self.owned) self.dir.close(io);
        self.owned = false;
    }
};

pub const Resolved = union(enum) {
    /// The path denotes a directory the walker already holds open: the root
    /// itself, or a directory reached through a symlink target ending in `.`
    /// or `..`.
    directory: ParentHandle,
    /// The path denotes `name` inside `parent`; the final entry has not been
    /// followed and may be absent.
    entry: struct {
        parent: ParentHandle,
        name: []u8,
    },

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            .directory => |*handle| handle.close(io),
            .entry => |*entry| {
                entry.parent.close(io);
                allocator.free(entry.name);
            },
        }
        self.* = undefined;
    }
};

pub const ResolveMode = enum {
    /// Follow a final symlink within the root; the result names the object
    /// the link chain reaches.
    follow_final,
    /// Return the final entry unfollowed, so the operation acts on the link.
    no_follow_final,
};

pub const StepProgress = union(enum) {
    pending,
    complete: Resolved,
    failed: Reason,
};

pub const ResolverInitError = error{ OutOfMemory, PathTooLong };

/// The resolver's remaining input, charged against one byte budget. The
/// initial path pays into the budget at construction and every spliced link
/// target pays before it replaces the text, so no resolver ever holds bytes
/// the host limit did not admit.
const BoundedPath = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    index: usize = 0,
    charged: usize,
    limit: usize,

    fn init(allocator: std.mem.Allocator, path: []const u8, limit: usize) ResolverInitError!BoundedPath {
        if (path.len > limit) return error.PathTooLong;
        const bytes = try allocator.dupe(u8, path);
        return .{ .allocator = allocator, .bytes = bytes, .charged = path.len, .limit = limit };
    }

    fn deinit(self: *BoundedPath) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn remaining(self: *const BoundedPath) []const u8 {
        return self.bytes[self.index..];
    }

    const SpliceOutcome = enum { spliced, limit };

    /// Replaces the text from `component_end` onward with `target/rest`,
    /// charging the target's length; refuses when the budget is exhausted.
    fn splice(self: *BoundedPath, target: []const u8, component_end: usize) error{OutOfMemory}!SpliceOutcome {
        const total = std.math.add(usize, self.charged, target.len) catch return .limit;
        if (total > self.limit) return .limit;
        const rest = self.bytes[component_end..];
        const spliced = try self.allocator.alloc(u8, target.len + 1 + rest.len);
        @memcpy(spliced[0..target.len], target);
        spliced[target.len] = '/';
        @memcpy(spliced[target.len + 1 ..], rest);
        self.allocator.free(self.bytes);
        self.bytes = spliced;
        self.index = 0;
        self.charged = total;
        return .spliced;
    }
};

/// Resumable descriptor-relative resolution. `path` holds the remaining,
/// budgeted path text, into which symlink targets are spliced; `stack` holds
/// one open handle per traversed directory, with the borrowed root at index
/// zero.
pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: Limits,
    mode: ResolveMode,
    stack: std.ArrayList(std.Io.Dir) = .empty,
    path: BoundedPath,
    expansions: usize = 0,

    /// `error.PathTooLong` reports a path over the resolver byte limit before
    /// any handle is opened.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: std.Io.Dir,
        path_text: []const u8,
        resolver_limits: Limits,
        mode: ResolveMode,
    ) ResolverInitError!Resolver {
        var path = try BoundedPath.init(allocator, path_text, resolver_limits.max_resolved_path_bytes);
        errdefer path.deinit();
        var stack: std.ArrayList(std.Io.Dir) = .empty;
        errdefer stack.deinit(allocator);
        try stack.append(allocator, root);
        return .{
            .allocator = allocator,
            .io = io,
            .limits = resolver_limits,
            .mode = mode,
            .stack = stack,
            .path = path,
        };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.stack.items[1..]) |dir| dir.close(self.io);
        self.stack.deinit(self.allocator);
        self.path.deinit();
        self.* = undefined;
    }

    fn top(self: *const Resolver) std.Io.Dir {
        return self.stack.items[self.stack.items.len - 1];
    }

    /// Removes the innermost handle as an owned result; the root is borrowed.
    fn takeTop(self: *Resolver) ParentHandle {
        if (self.stack.items.len == 1) return .{ .dir = self.stack.items[0], .owned = false };
        return .{ .dir = self.stack.pop().?, .owned = true };
    }

    /// Performs at most one metadata or open syscall.
    pub fn step(self: *Resolver) error{OutOfMemory}!StepProgress {
        const pending = self.path.bytes;
        while (self.path.index < pending.len and pending[self.path.index] == '/')
            self.path.index += 1;
        if (self.path.index == pending.len) {
            // A spliced target ended in a separator or dot component; the
            // object is the directory currently held.
            return .{ .complete = .{ .directory = self.takeTop() } };
        }
        const start = self.path.index;
        const end = std.mem.indexOfScalarPos(u8, pending, start, '/') orelse pending.len;
        const component = pending[start..end];
        const last = std.mem.indexOfNone(u8, pending[end..], "/") == null;
        if (std.mem.eql(u8, component, ".")) {
            self.path.index = end;
            if (last) return .{ .complete = .{ .directory = self.takeTop() } };
            return .pending;
        }
        if (std.mem.eql(u8, component, "..")) {
            if (self.stack.items.len == 1) return .{ .failed = .symlink_escape };
            const popped = self.stack.pop().?;
            popped.close(self.io);
            self.path.index = end;
            if (last) return .{ .complete = .{ .directory = self.takeTop() } };
            return .pending;
        }
        if (std.mem.indexOfScalar(u8, component, 0) != null) return .{ .failed = .invalid_path };
        if (last and self.mode == .no_follow_final) return self.completeEntry(component);
        const info = self.top().statFile(self.io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (last) return self.completeEntry(component);
                return .{ .failed = .not_found };
            },
            else => return .{ .failed = reasonForError(err) },
        };
        switch (info.kind) {
            .sym_link => return self.spliceLink(component, end),
            .directory => {
                if (last) return self.completeEntry(component);
                const child = self.top().openDir(self.io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.SymLinkLoop => return .{ .failed = .changed },
                    else => return .{ .failed = reasonForError(err) },
                };
                self.stack.append(self.allocator, child) catch |err| {
                    child.close(self.io);
                    return err;
                };
                self.path.index = end;
                return .pending;
            },
            else => {
                if (last) return self.completeEntry(component);
                return .{ .failed = .not_directory };
            },
        }
    }

    fn completeEntry(self: *Resolver, component: []const u8) error{OutOfMemory}!StepProgress {
        const name = try self.allocator.dupe(u8, component);
        return .{ .complete = .{ .entry = .{ .parent = self.takeTop(), .name = name } } };
    }

    fn spliceLink(self: *Resolver, component: []const u8, end: usize) error{OutOfMemory}!StepProgress {
        if (self.expansions == self.limits.max_symlink_expansions) return .{ .failed = .symlink_loop };
        self.expansions += 1;
        var buffer: [std.posix.PATH_MAX]u8 = undefined;
        const length = self.top().readLink(self.io, component, &buffer) catch |err| switch (err) {
            error.NotLink => return .{ .failed = .changed },
            error.NameTooLong => return .{ .failed = .limit },
            else => return .{ .failed = reasonForError(err) },
        };
        const target = buffer[0..length];
        if (target.len == 0) return .{ .failed = .io };
        if (target[0] == '/') return .{ .failed = .symlink_escape };
        if (std.mem.indexOfScalar(u8, target, 0) != null) return .{ .failed = .io };
        return switch (try self.path.splice(target, end)) {
            .spliced => .pending,
            .limit => .{ .failed = .limit },
        };
    }
};

/// Runs a resolver to completion. Only trusted host-side callers with no
/// scheduler to yield to use this; drivers step the resolver themselves.
pub fn resolveBlocking(resolver: *Resolver) error{OutOfMemory}!StepProgress {
    while (true) switch (try resolver.step()) {
        .pending => {},
        else => |terminal| return terminal,
    };
}

pub const OpenOutcome = union(enum) {
    file: std.Io.File,
    failed: Reason,
};

/// Opens the final entry for reading without following a symlink; an entry
/// that became a link since resolution is a race failure, not a follow.
pub fn openRegularForRead(io: std.Io, parent: std.Io.Dir, name: []const u8) OpenOutcome {
    const file = parent.openFile(io, name, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.SymLinkLoop => return .{ .failed = .changed },
        else => return .{ .failed = reasonForError(err) },
    };
    return .{ .file = file };
}

pub const RegularInfo = struct {
    size: u64,
    permissions: std.Io.File.Permissions,
};

pub const InfoOutcome = union(enum) {
    regular: RegularInfo,
    failed: Reason,
};

/// Requires an opened entry to be a regular file no larger than `limit`.
pub fn regularFileInfo(io: std.Io, file: std.Io.File, limit: u64) InfoOutcome {
    const info = file.stat(io) catch |err| return .{ .failed = reasonForError(err) };
    if (info.kind != .file) return .{ .failed = .not_regular };
    if (info.size > limit) return .{ .failed = .limit };
    return .{ .regular = .{ .size = info.size, .permissions = info.permissions } };
}

pub const ReadProgress = union(enum) {
    pending,
    complete,
    failed: Reason,
};

/// Reads exactly the size observed when the file was opened, one quantum per
/// step, and treats any growth or shrink observed meanwhile as a change.
pub fn readQuantum(
    io: std.Io,
    file: std.Io.File,
    destination: []u8,
    offset: *usize,
) ReadProgress {
    if (offset.* == destination.len) {
        var probe: [1]u8 = undefined;
        const extra = file.readPositionalAll(io, &probe, destination.len) catch |err|
            return .{ .failed = reasonForError(err) };
        if (extra != 0) return .{ .failed = .changed };
        return .complete;
    }
    const end = @min(offset.* + transfer_quantum, destination.len);
    const amount = file.readPositionalAll(io, destination[offset.*..end], offset.*) catch |err|
        return .{ .failed = reasonForError(err) };
    if (amount != end - offset.*) return .{ .failed = .changed };
    offset.* = end;
    return .pending;
}

pub const WriteProgress = union(enum) {
    pending,
    complete,
    failed: Reason,
};

/// Writes one quantum of `source` at `offset`.
pub fn writeQuantum(
    io: std.Io,
    file: std.Io.File,
    source: []const u8,
    offset: *usize,
) WriteProgress {
    if (offset.* == source.len) return .complete;
    const end = @min(offset.* + transfer_quantum, source.len);
    file.writePositionalAll(io, source[offset.*..end], offset.*) catch |err|
        return .{ .failed = reasonForError(err) };
    offset.* = end;
    return .pending;
}

const staging_attempts = 4;

/// One private sibling staging entry inside a resolved parent. Its name is
/// unguessable and never returned to a program; the driver that created it is
/// the only thing that recognizes it, through this value.
pub const StagedFile = struct {
    io: std.Io,
    parent: std.Io.Dir,
    name: [24]u8,
    file: ?std.Io.File,
    /// After an exchange commit the displaced destination lives under the
    /// staging name until `dispose` removes it.
    displaced: bool = false,

    pub const CreateOutcome = union(enum) {
        staged: StagedFile,
        failed: Reason,
    };

    /// Exclusively creates a fresh staging file; a colliding name is retried
    /// a fixed number of times.
    pub fn create(io: std.Io, parent: std.Io.Dir, permissions: std.Io.File.Permissions) CreateOutcome {
        var attempt: usize = 0;
        while (attempt < staging_attempts) : (attempt += 1) {
            var name: [24]u8 = undefined;
            fillStagingName(io, &name);
            const file = parent.createFile(io, &name, .{
                .exclusive = true,
                .permissions = permissions,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return .{ .failed = reasonForError(err) },
            };
            return .{ .staged = .{ .io = io, .parent = parent, .name = name, .file = file } };
        }
        return .{ .failed = .limit };
    }

    pub fn stagingName(self: *const StagedFile) []const u8 {
        return &self.name;
    }

    /// Closes the handle before publication; contents are complete.
    pub fn closeHandle(self: *StagedFile) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    /// Flushes the staged contents to the device and closes the handle, so
    /// a crash after publication cannot leave an empty file under the final
    /// name. Directory-entry durability is not promised: `std.Io.Dir` has no
    /// sync, and the words guarantee atomic visibility, not persistence.
    fn seal(self: *StagedFile) ?Reason {
        if (self.file) |file| file.sync(self.io) catch |err| return reasonForError(err);
        self.closeHandle();
        return null;
    }

    /// Publishes without replacing an existing destination. On success the
    /// staging name is consumed and nothing remains to dispose.
    pub fn commitNoReplace(self: *StagedFile, final_name: []const u8) ?Reason {
        if (self.seal()) |reason| return reason;
        renameNoReplace(self.io, self.parent, &self.name, self.parent, final_name) catch |err|
            return reasonForError(err);
        return null;
    }

    /// Atomically exchanges the staging entry with an existing destination.
    /// The displaced entry now sits under the staging name and must be
    /// disposed by the caller.
    pub fn commitExchange(self: *StagedFile, final_name: []const u8) ?Reason {
        if (self.seal()) |reason| return reason;
        renameExchange(self.io, self.parent, &self.name, self.parent, final_name) catch |err|
            return reasonForError(err);
        self.displaced = true;
        return null;
    }

    /// Removes whatever the staging name currently holds: an unpublished
    /// staging file, or the displaced entry after an exchange. Disposal runs
    /// after the operation's outcome is already decided, so a host refusal is
    /// reported to the log rather than turned into a second failure.
    pub fn dispose(self: *StagedFile) void {
        self.closeHandle();
        self.parent.deleteFile(self.io, &self.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.err("filesystem staging entry could not be removed: {s}", .{@errorName(err)}),
        };
        self.displaced = false;
    }
};

fn fillStagingName(io: std.Io, name: *[24]u8) void {
    var random: [8]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    @memcpy(name[0..8], ".ecl-fs-");
    @memcpy(name[8..24], &hex);
}

/// A private sibling staging directory name for tree publication.
pub fn stagingDirectoryName(io: std.Io, buffer: *[24]u8) []const u8 {
    fillStagingName(io, buffer);
    return buffer;
}

pub const RenameError = std.Io.Dir.RenamePreserveError;

const darwin = struct {
    extern "c" fn renameatx_np(
        old_dir: c_int,
        old_path: [*:0]const u8,
        new_dir: c_int,
        new_path: [*:0]const u8,
        flags: c_uint,
    ) c_int;
    const RENAME_SWAP: c_uint = 0x00000002;
    const RENAME_EXCL: c_uint = 0x00000004;
};

/// Atomic no-clobber rename. Unsupported hosts fail rather than degrade to a
/// check-then-rename sequence.
pub fn renameNoReplace(
    io: std.Io,
    old_parent: std.Io.Dir,
    old_name: []const u8,
    new_parent: std.Io.Dir,
    new_name: []const u8,
) RenameError!void {
    if (comptime builtin.os.tag == .linux)
        return old_parent.renamePreserve(old_name, new_parent, new_name, io);
    if (comptime builtin.os.tag.isDarwin())
        return darwinRename(old_parent, old_name, new_parent, new_name, darwin.RENAME_EXCL);
    return error.OperationUnsupported;
}

/// Atomic exchange of two existing entries.
pub fn renameExchange(
    io: std.Io,
    old_parent: std.Io.Dir,
    old_name: []const u8,
    new_parent: std.Io.Dir,
    new_name: []const u8,
) RenameError!void {
    _ = io;
    if (comptime builtin.os.tag == .linux) {
        const old_path = try std.posix.toPosixPath(old_name);
        const new_path = try std.posix.toPosixPath(new_name);
        while (true) switch (std.os.linux.errno(std.os.linux.renameat2(
            old_parent.handle,
            &old_path,
            new_parent.handle,
            &new_path,
            .{ .EXCHANGE = true },
        ))) {
            .SUCCESS => return,
            .INTR => continue,
            else => |code| return mapRenameErrno(code),
        };
    }
    if (comptime builtin.os.tag.isDarwin())
        return darwinRename(old_parent, old_name, new_parent, new_name, darwin.RENAME_SWAP);
    return error.OperationUnsupported;
}

fn darwinRename(
    old_parent: std.Io.Dir,
    old_name: []const u8,
    new_parent: std.Io.Dir,
    new_name: []const u8,
    flags: c_uint,
) RenameError!void {
    const old_path = try std.posix.toPosixPath(old_name);
    const new_path = try std.posix.toPosixPath(new_name);
    while (true) switch (std.c.errno(darwin.renameatx_np(
        old_parent.handle,
        &old_path,
        new_parent.handle,
        &new_path,
        flags,
    ))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |code| return mapRenameErrno(code),
    };
}

fn mapRenameErrno(code: anytype) RenameError {
    return switch (code) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .EXIST, .NOTEMPTY => error.PathAlreadyExists,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .BUSY => error.FileBusy,
        .DQUOT => error.DiskQuota,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .NOSPC => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        .XDEV => error.CrossDevice,
        .NAMETOOLONG => error.NameTooLong,
        .INVAL, .NOSYS, .OPNOTSUPP => error.OperationUnsupported,
        else => error.Unexpected,
    };
}

/// The public metadata classification of one host object.
pub const EntryKind = enum {
    file,
    directory,
    symlink,
    other,

    pub fn fromHost(kind: std.Io.File.Kind) EntryKind {
        return switch (kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        };
    }

    pub fn symbol(self: EntryKind) []const u8 {
        return @tagName(self);
    }
};

test "canonical path grammar accepts only slash-separated relative components" {
    try std.testing.expectEqual(PathClass.root, try classifyPath("."));
    try std.testing.expectEqual(PathClass.entry, try classifyPath("a"));
    try std.testing.expectEqual(PathClass.entry, try classifyPath("a/b.txt"));
    try std.testing.expectEqual(PathClass.entry, try classifyPath("back\\slash"));
    for ([_][]const u8{ "", "/", "/a", "a/", "a//b", "./a", "a/.", "..", "a/../b", "a\x00b", "\xff" }) |path| {
        try std.testing.expectError(error.InvalidPath, classifyPath(path));
    }
}

test "root names are printable delimiter-free atoms" {
    try std.testing.expect(validRootName("cwd"));
    try std.testing.expect(validRootName("project"));
    try std.testing.expect(!validRootName(""));
    try std.testing.expect(!validRootName("has space"));
    try std.testing.expect(!validRootName("quo'te"));
    try std.testing.expect(!validRootName("(paren"));
}

test "resolver refuses an initial path over the byte limit before opening anything" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    var root = try scratch.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer root.close(std.testing.io);
    const limits: Limits = .{ .max_resolved_path_bytes = 8 };
    try std.testing.expectError(error.PathTooLong, Resolver.init(std.testing.allocator, std.testing.io, root, "abcdefghi", limits, .follow_final));
    var resolver = try Resolver.init(std.testing.allocator, std.testing.io, root, "abcdefgh", limits, .follow_final);
    resolver.deinit();
}

test "filesystem policy rejects relative roots, duplicate names, and zero limits" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.InvalidPolicy, FilesystemOwner.init(std.testing.allocator, std.testing.io, .{
        .roots = &.{.{ .name = "cwd", .absolute_path = "relative/dir", .permissions = .all }},
    }));
    try std.testing.expectError(error.InvalidPolicy, FilesystemOwner.init(std.testing.allocator, std.testing.io, .{
        .roots = &.{
            .{ .name = "cwd", .absolute_path = path, .permissions = .all },
            .{ .name = "cwd", .absolute_path = path, .permissions = .all },
        },
    }));
    try std.testing.expectError(error.InvalidPolicy, FilesystemOwner.init(std.testing.allocator, std.testing.io, .{
        .roots = &.{.{ .name = "cwd", .absolute_path = path, .permissions = .all }},
        .limits = .{ .max_live_operations = 0 },
    }));
    var owner = try FilesystemOwner.init(std.testing.allocator, std.testing.io, .{
        .roots = &.{.{ .name = "cwd", .absolute_path = path, .permissions = .all }},
    });
    defer owner.deinit();
    const symbol = try intern.intern("cwd");
    try std.testing.expect(findRoot(owner.access(), symbol) != null);
    try std.testing.expect(findRoot(owner.access(), try intern.intern("other")) == null);
}

test "live-operation reservations are exhausted and released exactly" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var owner = try FilesystemOwner.init(std.testing.allocator, std.testing.io, .{
        .roots = &.{.{ .name = "cwd", .absolute_path = path, .permissions = .all }},
        .limits = .{ .max_live_operations = 2 },
    });
    defer owner.deinit();
    var first = reserveOperation(owner.access()).?;
    var second = reserveOperation(owner.access()).?;
    try std.testing.expect(reserveOperation(owner.access()) == null);
    first.release();
    first.release();
    var third = reserveOperation(owner.access()).?;
    try std.testing.expect(reserveOperation(owner.access()) == null);
    second.release();
    third.release();
}

test "resolver confines symlink targets to the root" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const io = std.testing.io;
    try scratch.dir.createDir(io, "root", .default_dir);
    try scratch.dir.createDir(io, "root/a", .default_dir);
    try scratch.dir.createDir(io, "root/a/b", .default_dir);
    try scratch.dir.writeFile(io, .{ .sub_path = "root/a/b/file", .data = "x" });
    try scratch.dir.writeFile(io, .{ .sub_path = "outside", .data = "secret" });
    try scratch.dir.symLink(io, "../outside", "root/escape", .{});
    const scratch_path = try scratch.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(scratch_path);
    const absolute_outside = try std.fmt.allocPrint(std.testing.allocator, "{s}/outside", .{scratch_path});
    defer std.testing.allocator.free(absolute_outside);
    try scratch.dir.symLink(io, absolute_outside, "root/absolute", .{});
    try scratch.dir.symLink(io, "a/b", "root/inside", .{});
    try scratch.dir.symLink(io, "../../outside", "root/a/deep-escape", .{});
    try scratch.dir.symLink(io, "loop", "root/loop", .{});
    var root = try scratch.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);

    const cases = [_]struct { path: []const u8, mode: ResolveMode, expect: union(enum) { entry: []const u8, directory, failed: Reason } }{
        .{ .path = "a/b/file", .mode = .follow_final, .expect = .{ .entry = "file" } },
        .{ .path = "inside/file", .mode = .follow_final, .expect = .{ .entry = "file" } },
        .{ .path = "inside", .mode = .follow_final, .expect = .{ .entry = "b" } },
        .{ .path = "inside", .mode = .no_follow_final, .expect = .{ .entry = "inside" } },
        .{ .path = "escape", .mode = .follow_final, .expect = .{ .failed = .symlink_escape } },
        .{ .path = "escape", .mode = .no_follow_final, .expect = .{ .entry = "escape" } },
        .{ .path = "absolute", .mode = .follow_final, .expect = .{ .failed = .symlink_escape } },
        .{ .path = "absolute/child", .mode = .no_follow_final, .expect = .{ .failed = .symlink_escape } },
        .{ .path = "a/deep-escape", .mode = .follow_final, .expect = .{ .failed = .symlink_escape } },
        .{ .path = "loop", .mode = .follow_final, .expect = .{ .failed = .symlink_loop } },
        .{ .path = "missing/file", .mode = .follow_final, .expect = .{ .failed = .not_found } },
        .{ .path = "a/b/file/child", .mode = .follow_final, .expect = .{ .failed = .not_directory } },
        .{ .path = "absent", .mode = .follow_final, .expect = .{ .entry = "absent" } },
    };
    for (cases) |case| {
        var resolver = try Resolver.init(std.testing.allocator, io, root, case.path, .{}, case.mode);
        defer resolver.deinit();
        var outcome = try resolveBlocking(&resolver);
        switch (case.expect) {
            .entry => |name| {
                try std.testing.expectEqualStrings(name, outcome.complete.entry.name);
                outcome.complete.deinit(std.testing.allocator, io);
            },
            .directory => {
                try std.testing.expect(outcome.complete == .directory);
                outcome.complete.deinit(std.testing.allocator, io);
            },
            .failed => |reason| try std.testing.expectEqual(reason, outcome.failed),
        }
    }
}
