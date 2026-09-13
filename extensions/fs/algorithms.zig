//! Descriptor-relative filesystem algorithms owned by the native extension.
const std = @import("std");
const builtin = @import("builtin");
const storage = @import("storage.zig");

pub const Limits = struct {
    max_transfer_bytes: u64 = 1 << 30,
    /// Explicit streams retain the archival 1 GiB default independently of
    /// a host's whole-file convenience-operation limit.
    max_stream_transfer_bytes: u64 = 1 << 30,
    max_directory_entries: usize = 100_000,
    max_directory_name_bytes: usize = 64 << 20,
    max_live_operations: usize = 64,
    max_symlink_expansions: usize = 40,
    max_resolved_path_bytes: usize = 64 << 10,
};

/// One borrowed root description. The eager native instance copies the name and
/// opens the directory once; the path is never consulted again.
pub const Root = struct {
    name: []const u8,
    absolute_path: []const u8,
};

pub const InitError = error{ OutOfMemory, InvalidConfig };

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

pub fn validateLimits(limits: Limits) InitError!void {
    if (limits.max_transfer_bytes == 0 or limits.max_stream_transfer_bytes == 0 or limits.max_directory_entries == 0 or
        limits.max_directory_name_bytes == 0 or limits.max_live_operations == 0 or
        limits.max_symlink_expansions == 0 or limits.max_resolved_path_bytes == 0)
        return error.InvalidConfig;
    if (limits.max_transfer_bytes > std.math.maxInt(usize) or limits.max_stream_transfer_bytes > std.math.maxInt(usize)) return error.InvalidConfig;
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

pub const Reason = enum {
    invalid_path,
    unknown_root,
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
            .changed => "entry changed during the operation",
            .io => "host filesystem operation failed",
        };
    }
};

/// The one mapping from Zig host errors to the portable vocabulary.
pub fn reasonForError(err: anyerror) Reason {
    return switch (err) {
        error.EntryChanged => .changed,
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
    const Text = union(enum) {
        borrowed: []const u8,
        owned: []u8,
        fn bytes(self: Text) []const u8 {
            return switch (self) {
                .borrowed => |text| text,
                .owned => |text| text,
            };
        }
        fn release(self: Text, allocator: std.mem.Allocator) void {
            switch (self) {
                .borrowed => {},
                .owned => |text| allocator.free(text),
            }
        }
    };
    allocator: std.mem.Allocator,
    storage: union(enum) {
        ready: Text,
        copying: struct { previous: Text, next: []u8, source_offset: usize, written: usize },
    },
    index: usize = 0,
    charged: usize,
    limit: usize,

    /// Borrows the original path until resolver retirement. Spliced paths own
    /// their replacement storage; no user-sized copy is hidden in initialization.
    fn init(allocator: std.mem.Allocator, path: []const u8, limit: usize) ResolverInitError!BoundedPath {
        if (path.len > limit) return error.PathTooLong;
        return .{ .allocator = allocator, .storage = .{ .ready = .{ .borrowed = path } }, .charged = path.len, .limit = limit };
    }
    fn bytes(self: *const BoundedPath) []const u8 {
        return self.storage.ready.bytes();
    }
    fn deinit(self: *BoundedPath) void {
        switch (self.storage) {
            .ready => |text| text.release(self.allocator),
            .copying => |copying| {
                copying.previous.release(self.allocator);
                self.allocator.free(copying.next);
            },
        }
    }
    const SpliceOutcome = enum { spliced, limit };
    fn splice(self: *BoundedPath, target: []const u8, component_end: usize) error{OutOfMemory}!SpliceOutcome {
        const total = std.math.add(usize, self.charged, target.len) catch return .limit;
        if (total > self.limit) return .limit;
        const previous = self.storage.ready;
        const rest = previous.bytes()[component_end..];
        const prefix = std.math.add(usize, target.len, 1) catch return .limit;
        const length = std.math.add(usize, prefix, rest.len) catch return .limit;
        const next = try self.allocator.alloc(u8, length);
        // The caller supplies one fixed-size readlink buffer. Remaining path
        // bytes copy in subsequent slices and remain owned until completion.
        @memcpy(next[0..target.len], target);
        next[target.len] = '/';
        self.storage = .{ .copying = .{ .previous = previous, .next = next, .source_offset = component_end, .written = prefix } };
        self.charged = total;
        return .spliced;
    }
    fn advanceCopy(self: *BoundedPath) void {
        const copying = &self.storage.copying;
        const count = @min(transfer_quantum, copying.next.len - copying.written);
        @memcpy(copying.next[copying.written..][0..count], copying.previous.bytes()[copying.source_offset..][0..count]);
        copying.written += count;
        copying.source_offset += count;
        if (copying.written == copying.next.len) {
            const next = copying.next;
            copying.previous.release(self.allocator);
            self.storage = .{ .ready = .{ .owned = next } };
            self.index = 0;
        }
    }
};

/// Resumable descriptor-relative resolution. `path` holds the remaining,
/// budgeted path text, into which symlink targets are spliced; `stack` holds
/// a borrowed root and a chunked stack of owned parent descriptors.
pub const Resolver = struct {
    state: *ResolverState,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path_text: []const u8, resolver_limits: Limits, mode: ResolveMode) ResolverInitError!Resolver {
        const state = try allocator.create(ResolverState);
        errdefer allocator.destroy(state);
        state.* = try ResolverState.init(allocator, io, root, path_text, resolver_limits, mode);
        return .{ .state = state };
    }

    pub fn step(self: *Resolver) error{OutOfMemory}!StepProgress {
        return self.state.step();
    }
    pub fn createParents(self: *Resolver) void {
        self.state.createParents();
    }

    /// Consumes the resolver when complete. Each retirement slice closes at
    /// most one descriptor and never allocates, including partial startup.
    pub fn retireStep(self: *Resolver) bool {
        return self.state.retireStep();
    }
};

const ResolverState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limits: Limits,
    mode: ResolveMode,
    root: std.Io.Dir,
    stack: storage.Stack(std.Io.Dir),
    path: BoundedPath,
    expansions: usize = 0,
    create_missing: bool = false,
    component: ?struct { start: usize, end: usize, after: usize } = null,

    /// `error.PathTooLong` reports a path over the resolver byte limit before
    /// any handle is opened.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: std.Io.Dir,
        path_text: []const u8,
        resolver_limits: Limits,
        mode: ResolveMode,
    ) ResolverInitError!ResolverState {
        var path = try BoundedPath.init(allocator, path_text, resolver_limits.max_resolved_path_bytes);
        errdefer path.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .limits = resolver_limits,
            .mode = mode,
            .root = root,
            .stack = .init(allocator),
            .path = path,
        };
    }

    fn retireStep(self: *ResolverState) bool {
        if (self.stack.pop()) |dir| {
            dir.close(self.io);
            return false;
        }
        self.path.deinit();
        self.allocator.destroy(self);
        return true;
    }

    /// Create absent intermediate directories, retaining the same descriptor
    /// containment and symlink validation as ordinary resolution.
    pub fn createParents(self: *ResolverState) void {
        self.create_missing = true;
    }

    fn top(self: *ResolverState) std.Io.Dir {
        return if (self.stack.topPtr()) |dir| dir.* else self.root;
    }

    /// Removes the innermost owned handle; the root remains borrowed.
    fn takeTop(self: *ResolverState) ParentHandle {
        return if (self.stack.pop()) |dir| .{ .dir = dir, .owned = true } else .{ .dir = self.root, .owned = false };
    }

    /// Performs at most one metadata or open syscall.
    pub fn step(self: *ResolverState) error{OutOfMemory}!StepProgress {
        if (self.path.storage == .copying) {
            self.path.advanceCopy();
            return .pending;
        }
        const pending = self.path.bytes();
        if (self.component == null) {
            var skipped: usize = 0;
            while (self.path.index < pending.len and pending[self.path.index] == '/' and skipped < 256) : (skipped += 1)
                self.path.index += 1;
            if (skipped == 256) return .pending;
            if (self.path.index == pending.len) return .{ .complete = .{ .directory = self.takeTop() } };
            const start = self.path.index;
            const window = pending[start..][0..@min(pending.len - start, std.Io.Dir.max_name_bytes + 1)];
            const length = std.mem.indexOfScalar(u8, window, '/') orelse window.len;
            if (length > std.Io.Dir.max_name_bytes) return .{ .failed = .limit };
            self.component = .{ .start = start, .end = start + length, .after = start + length };
        }
        const scanning = &self.component.?;
        var skipped: usize = 0;
        while (scanning.after < pending.len and pending[scanning.after] == '/' and skipped < 256) : (skipped += 1)
            scanning.after += 1;
        if (skipped == 256) return .pending;
        const end = scanning.end;
        const component = pending[scanning.start..end];
        const last = scanning.after == pending.len;
        self.component = null;
        if (std.mem.eql(u8, component, ".")) {
            self.path.index = end;
            if (last) return .{ .complete = .{ .directory = self.takeTop() } };
            return .pending;
        }
        if (std.mem.eql(u8, component, "..")) {
            if (self.stack.isEmpty()) return .{ .failed = .symlink_escape };
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
                if (self.create_missing) {
                    self.top().createDir(self.io, component, .default_dir) catch |create_err| switch (create_err) {
                        error.PathAlreadyExists => {},
                        else => return .{ .failed = reasonForError(create_err) },
                    };
                    // Reinspect before opening: a competing creator may have
                    // published a symlink rather than a directory.
                    return .pending;
                }
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
                self.stack.push(child) catch |err| {
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

    fn completeEntry(self: *ResolverState, component: []const u8) error{OutOfMemory}!StepProgress {
        const name = try self.allocator.dupe(u8, component);
        return .{ .complete = .{ .entry = .{ .parent = self.takeTop(), .name = name } } };
    }

    fn spliceLink(self: *ResolverState, component: []const u8, end: usize) error{OutOfMemory}!StepProgress {
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

pub const OpenOutcome = union(enum) {
    file: std.Io.File,
    failed: Reason,
};

/// Exclusive creation never truncates an existing file. An existing entry is
/// opened without following links, then validated through the descriptor.
pub fn openLockFile(io: std.Io, parent: std.Io.Dir, name: []const u8) OpenOutcome {
    const file = parent.createFile(io, name, .{ .exclusive = true, .truncate = false, .read = true }) catch |err| switch (err) {
        error.PathAlreadyExists => parent.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }) catch |open_err| return .{ .failed = reasonForError(open_err) },
        else => return .{ .failed = reasonForError(err) },
    };
    switch (regularFileInfo(io, file, std.math.maxInt(u64))) {
        .regular => return .{ .file = file },
        .failed => |reason| {
            file.close(io);
            return .{ .failed = reason };
        },
    }
}

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

const staging_attempts = 4;

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

    /// Atomically publish complete derived metadata, whether or not it existed.
    /// Failure leaves the old entry intact and this staging file owned by the caller.
    pub fn commitReplace(self: *StagedFile, final_name: []const u8) ?Reason {
        if (self.seal()) |reason| return reason;
        self.parent.rename(&self.name, self.parent, final_name, self.io) catch |err|
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

/// Destructive, allocation-free tree emptying. Flattening each selected child
/// into the root avoids a depth-sized descriptor or allocation stack. This is
/// also usable during rollback when no allocator can make further progress.
/// The caller retains the root's parent and removes the root after completion.
pub const TreeRemoval = struct {
    io: std.Io,
    root: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
    child: ?struct {
        dir: std.Io.Dir,
        iterator: std.Io.Dir.Iterator,
        name: [std.fs.max_name_bytes]u8,
        length: usize,
    } = null,

    /// Consumes the open, iterable root directory.
    pub fn init(io: std.Io, root: std.Io.Dir) TreeRemoval {
        return .{ .io = io, .root = root, .iterator = root.iterate() };
    }

    pub fn restart(self: *TreeRemoval) void {
        self.iterator = self.root.iterate();
    }

    pub fn step(self: *TreeRemoval) ReadProgress {
        if (self.child) |*child| {
            const entry = child.iterator.next(self.io) catch |err| return .{ .failed = reasonForError(err) };
            if (entry) |item| {
                var name: [24]u8 = undefined;
                _ = stagingDirectoryName(self.io, &name);
                renameNoReplace(self.io, child.dir, item.name, self.root, &name) catch |err| switch (err) {
                    error.PathAlreadyExists, error.FileNotFound => child.iterator = child.dir.iterate(),
                    else => return .{ .failed = reasonForError(err) },
                };
                return .pending;
            }
            self.root.deleteDir(self.io, child.name[0..child.length]) catch |err| switch (err) {
                error.DirNotEmpty => {
                    child.iterator = child.dir.iterate();
                    return .pending;
                },
                error.FileNotFound => {},
                else => return .{ .failed = reasonForError(err) },
            };
            child.dir.close(self.io);
            self.child = null;
            self.restart();
            return .pending;
        }
        const entry = self.iterator.next(self.io) catch |err| return .{ .failed = reasonForError(err) };
        const item = entry orelse return .complete;
        const info = self.root.statFile(self.io, item.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .pending,
            else => return .{ .failed = reasonForError(err) },
        };
        if (info.kind == .directory) {
            if (item.name.len > std.fs.max_name_bytes) return .{ .failed = .limit };
            const dir = self.root.openDir(self.io, item.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return .{ .failed = reasonForError(err) };
            var child: @typeInfo(@FieldType(TreeRemoval, "child")).optional.child = .{ .dir = dir, .iterator = dir.iterate(), .name = undefined, .length = item.name.len };
            @memcpy(child.name[0..item.name.len], item.name);
            self.child = child;
        } else self.root.deleteFile(self.io, item.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return .{ .failed = reasonForError(err) },
        };
        return .pending;
    }

    pub fn deinit(self: *TreeRemoval) void {
        if (self.child) |child| child.dir.close(self.io);
        self.root.close(self.io);
        self.* = undefined;
    }
};

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
