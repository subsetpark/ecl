//! Package-authorized Git helper execution. The driver owns its private staging
//! tree through child reaping, artifact materialization, and bounded retirement.
const std = @import("std");
const machine = @import("../machine.zig");
const heap = @import("../heap.zig");
const Value = @import("../value.zig").Value;
const list = @import("../list.zig");
const storage = @import("../kernel_storage.zig");
const authority = @import("../package_authority.zig");
const process = @import("../process_port.zig");
const catalog = @import("../pkg_catalog.zig");
const quantum = machine.kernel_poll_quantum;
const max_artifact = 1024 * 1024 * 1024 + 1024 * 1024;

pub fn fetch(evaluator: *machine.Machine) machine.MachineError!void {
    try evaluator.require(3);
    const access = evaluator.unit.inherited.package_access orelse return evaluator.fail(.domain, "package Git authority is unavailable");
    const config = authority.gitConfig(access) orelse return evaluator.fail(.domain, "package Git authority is unavailable");
    const cache = authority.storeDir(access, .cache) orelse return evaluator.fail(.io, "package cache is unavailable");
    var revision = try evaluator.popValue();
    defer revision.deinit();
    var selector = try evaluator.popValue();
    defer selector.deinit();
    var url = try evaluator.popValue();
    defer url.deinit();
    const inputs = [3]Value{ url.borrow(), selector.borrow(), revision.borrow() };
    for (inputs, [_]usize{ 8192, 6, 1024 }) |input, limit| {
        if (!input.isString()) return evaluator.typeError("Git URL, selector, and revision strings");
        if (input.list.length() > limit) return evaluator.fail(.domain, "Git request exceeds its length limit");
    }
    try evaluator.startDriver(Driver{
        .allocator = evaluator.allocator(),
        .io = evaluator.unit.inherited.runtime().host_io,
        .cache = cache,
        .config = config,
        .inputs = .init(.{ .values = .{ url.take(), selector.take(), revision.take() } }),
    });
}

const Stage = struct {
    root: std.Io.Dir,
    path: [:0]u8,
    key: [43]u8,
    cleanup: ?struct { dir: std.Io.Dir, iterator: std.Io.Dir.Iterator } = null,
    relative: [4096]u8 = undefined,
    relative_len: usize = 0,

    fn create(allocator: std.mem.Allocator, io: std.Io, cache: std.Io.Dir) !Stage {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const key = ".git-fetch-".* ++ std.fmt.bytesToHex(nonce, .lower);
        try cache.createDir(io, &key, .fromMode(0o700));
        errdefer cache.deleteDir(io, &key) catch {};
        const root = try cache.openDir(io, &key, .{ .iterate = true, .follow_symlinks = false });
        errdefer root.close(io);
        const path = try root.realPathFileAlloc(io, ".", allocator);
        return .{ .root = root, .path = path, .key = key };
    }

    /// Deletes one entry or changes one directory level. The helper is already
    /// reaped, so no writer can race this private traversal. No allocation is
    /// needed on cancellation, even for arbitrarily many pack/refs files.
    fn cleanupStep(self: *Stage, io: std.Io, cache: std.Io.Dir) !bool {
        if (self.cleanup == null) self.cleanup = .{ .dir = self.root, .iterator = self.root.iterate() };
        const cursor = &self.cleanup.?;
        if (try cursor.iterator.next(io)) |entry| {
            if (entry.kind == .directory) {
                const child = try cursor.dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                errdefer child.close(io);
                if (self.relative_len + entry.name.len + 1 > self.relative.len) return error.NameTooLong;
                @memcpy(self.relative[self.relative_len..][0..entry.name.len], entry.name);
                self.relative_len += entry.name.len;
                self.relative[self.relative_len] = '/';
                self.relative_len += 1;
                if (cursor.dir.handle != self.root.handle) cursor.dir.close(io);
                cursor.* = .{ .dir = child, .iterator = child.iterate() };
            } else try cursor.dir.deleteFile(io, entry.name);
            return false;
        }
        if (self.relative_len == 0) {
            try cache.deleteDir(io, &self.key);
            self.root.close(io);
            self.cleanup = null;
            return true;
        }
        const parent = try cursor.dir.openDir(io, "..", .{ .iterate = true });
        errdefer parent.close(io);
        const end = self.relative_len - 1;
        const start = if (std.mem.lastIndexOfScalar(u8, self.relative[0..end], '/')) |i| i + 1 else 0;
        try parent.deleteDir(io, self.relative[start..end]);
        cursor.dir.close(io);
        self.relative_len = start;
        if (start == 0) {
            parent.close(io);
            cursor.* = .{ .dir = self.root, .iterator = self.root.iterate() };
        } else cursor.* = .{ .dir = parent, .iterator = parent.iterate() };
        return false;
    }
};

const Driver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;
    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: std.Io.Dir,
    config: authority.GitConfig,
    inputs: heap.Owned(Inputs),
    encoded: [3]?[]u8 = .{ null, null, null },
    results: [3]Value = @splat(.{ .int = 0 }),
    state: State = .{ .encode = .{ .index = 0 } },
    const Inputs = struct {
        values: [3]Value,
        pub fn retire(self: *Inputs, releases: *heap.ReleaseDomain) void {
            for (self.values) |value| releases.releaseValue(value);
        }
    };
    const Run = struct { stage: Stage, child: *process.IsolatedChild };
    const Reading = struct { stage: Stage, index: usize, file: std.Io.File, bytes: []u8, offset: usize = 0 };
    const Materializing = struct { stage: Stage, index: usize, bytes: []u8, work: union(enum) { text: storage.Utf8Materializer, bytes: list.ByteListMaterializer } };
    const State = union(enum) {
        encode: struct { index: usize, cursor: ?storage.StringEncoder = null },
        create,
        launch: Stage,
        running: Run,
        open: struct { stage: Stage, index: usize },
        read: Reading,
        materialize: Materializing,
        output: Stage,
        cleanup: Stage,
        destroy,
    };

    pub fn advance(evaluator: *machine.Machine, self: *Driver) machine.MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.state) {
            .encode => |*encoding| {
                if (encoding.cursor == null) encoding.cursor = storage.StringEncoder.init(self.allocator, self.inputs.borrow().values[encoding.index]);
                switch (encoding.cursor.?.advance(quantum) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidCodepoint => return evaluator.fail(.domain, "Git request is not valid Unicode"),
                }) {
                    .pending => {},
                    .complete => |bytes| {
                        self.encoded[encoding.index] = bytes;
                        encoding.cursor.?.deinit();
                        if (encoding.index == 2) self.state = .create else self.state = .{ .encode = .{ .index = encoding.index + 1 } };
                    },
                }
            },
            .create => {
                if (!catalog.validUrl(self.encoded[0].?)) return evaluator.fail(.domain, "Git requires an HTTPS URL without credentials");
                const selector = self.encoded[1].?;
                if (!std.mem.eql(u8, selector, "tag") and !std.mem.eql(u8, selector, "commit")) return evaluator.fail(.domain, "Git requires exactly one tag or full commit selector");
                const stage = Stage.create(self.allocator, self.io, self.cache) catch |err| return self.fail(evaluator, "cannot create private Git staging", err);
                self.state = .{ .launch = stage };
            },
            .launch => |stage| {
                const scope: *@import("../scheduler.zig").TaskScope = @ptrCast(@alignCast(evaluator.unit.task_scope orelse return evaluator.fail(.cancelled, "Git task scope is closing")));
                const child = process.spawnIsolated(evaluator.unit.inherited.runtime().process_access, scope, .{
                    .executable = self.config.executable,
                    .cwd = stage.path,
                    .args = &.{ "--ecl-private-git-helper", self.encoded[0].?, self.encoded[1].?, self.encoded[2].?, self.config.ca_file orelse "" },
                }) catch |err| return self.fail(evaluator, "cannot launch Git helper", err);
                child.closeInput();
                self.state = .{ .running = .{ .stage = stage, .child = child } };
            },
            .running => |*run| {
                const cell = run.child;
                // The helper writes only a bounded diagnostic to stderr, never
                // stdout. Waiting cannot deadlock against the process rings.
                const term = cell.termination() orelse {
                    try evaluator.park(.{ .external = cell.waitSource() });
                    return .yielded;
                };
                if (term != .exited or term.exited != 0) {
                    var message: [1024]u8 = undefined;
                    const count = switch (cell.readStderr(&message)) {
                        .data => |n| n,
                        else => 0,
                    };
                    return evaluator.failFmt(.io, "Git fetch failed: {s}", .{if (count == 0) "helper terminated or exceeded its time/storage limit" else message[0..count]});
                }
                const stage = run.stage;
                run.child.release();
                self.state = .{ .open = .{ .stage = stage, .index = 0 } };
            },
            .open => |opened| {
                const names = [_][]const u8{ "commit", "manifest", "artifact.tgz" };
                const file = opened.stage.root.openFile(self.io, names[opened.index], .{ .allow_directory = false }) catch |err| return self.fail(evaluator, "Git helper omitted its result", err);
                errdefer file.close(self.io);
                const info = file.stat(self.io) catch |err| return self.fail(evaluator, "cannot inspect Git artifact", err);
                const limits = [_]u64{ 40, 16 * 1024 * 1024, max_artifact };
                if (info.kind != .file or info.size > limits[opened.index]) return evaluator.fail(.domain, "Git result exceeds package limits");
                const bytes = try self.allocator.alloc(u8, @intCast(info.size));
                self.state = .{ .read = .{ .stage = opened.stage, .index = opened.index, .file = file, .bytes = bytes } };
            },
            .read => |*read| {
                const end = @min(read.bytes.len, read.offset + quantum);
                const count = read.file.readPositionalAll(self.io, read.bytes[read.offset..end], read.offset) catch |err| return self.fail(evaluator, "cannot read Git artifact", err);
                if (count != end - read.offset) return evaluator.fail(.io, "Git artifact was truncated");
                read.offset = end;
                if (end == read.bytes.len) {
                    read.file.close(self.io);
                    self.state = .{ .materialize = .{ .stage = read.stage, .index = read.index, .bytes = read.bytes, .work = if (read.index == 2) .{ .bytes = .init(self.allocator, read.bytes) } else .{ .text = .init(self.allocator, read.bytes) } } };
                }
            },
            .materialize => |*mat| {
                const progress = switch (mat.work) {
                    .bytes => |*bytes| try bytes.advance(quantum),
                    .text => |*text| text.advance(quantum) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidUtf8 => return evaluator.fail(.domain, "Git manifest is not valid UTF-8"),
                    },
                };
                switch (progress) {
                    .pending => {},
                    .complete => |result| {
                        self.results[mat.index] = result;
                        self.allocator.free(mat.bytes);
                        self.state = if (mat.index == 2) .{ .output = mat.stage } else .{ .open = .{ .stage = mat.stage, .index = mat.index + 1 } };
                    },
                }
            },
            .output => |stage| {
                const result = try list.fromValues(self.allocator, &self.results);
                self.state = .{ .cleanup = stage };
                return .{ .output = result };
            },
            .cleanup, .destroy => unreachable,
        }
        return .yielded;
    }

    fn fail(_: *Driver, evaluator: *machine.Machine, text: []const u8, err: anyerror) machine.MachineError {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return evaluator.failFmt(.io, "{s}: {s}", .{ text, @errorName(err) });
    }

    pub fn advanceRetirement(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *Driver) bool {
        switch (self.state) {
            .encode => |*encoding| {
                if (encoding.cursor) |*cursor| cursor.deinit();
                self.state = .destroy;
            },
            .create => self.state = .destroy,
            .launch, .output => |stage| self.state = .{ .cleanup = stage },
            .running => |*run| {
                run.child.cancel();
                if (run.child.termination() == null) return false;
                run.child.release();
                self.state = .{ .cleanup = run.stage };
            },
            .open => |opened| self.state = .{ .cleanup = opened.stage },
            .read => |read| {
                read.file.close(self.io);
                allocator.free(read.bytes);
                self.state = .{ .cleanup = read.stage };
            },
            .materialize => |*mat| {
                switch (mat.work) {
                    inline else => |*work| work.retire(releases),
                }
                allocator.free(mat.bytes);
                self.state = .{ .cleanup = mat.stage };
            },
            .cleanup => |*stage| {
                const done = stage.cleanupStep(self.io, self.cache) catch |err| {
                    std.log.err("cannot remove private Git staging: {s}", .{@errorName(err)});
                    if (stage.cleanup) |cursor| if (cursor.dir.handle != stage.root.handle) cursor.dir.close(self.io);
                    stage.root.close(self.io);
                    allocator.free(stage.path);
                    self.state = .destroy;
                    return false;
                };
                if (done) {
                    allocator.free(stage.path);
                    self.state = .destroy;
                }
            },
            .destroy => {
                self.inputs.deinit(releases, allocator);
                for (self.results) |result| releases.releaseValue(result);
                for (self.encoded) |encoded| if (encoded) |bytes| allocator.free(bytes);
                allocator.destroy(self);
                return true;
            },
        }
        return false;
    }
};
