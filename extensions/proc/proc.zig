//! Bundled subprocess service authored only against the public native SDK.
const std = @import("std");
const builtin = @import("builtin");
const ecl = @import("ecl-native");

pub const Limits = struct {
    max_live_ports: usize = 32,
    stdin_capacity: usize = 64 * 1024,
    stdout_capacity: usize = 64 * 1024,
    stderr_capacity: usize = 64 * 1024,
    max_stdout_capture: usize = 8 * 1024 * 1024,
    max_stderr_capture: usize = 8 * 1024 * 1024,

    pub fn validate(self: Limits) error{InvalidConfig}!void {
        if (self.max_live_ports == 0 or self.stdin_capacity == 0 or
            self.stdout_capacity == 0 or self.stderr_capacity == 0 or
            self.max_stdout_capture == 0 or self.max_stderr_capture == 0)
            return error.InvalidConfig;
        const jobs = std.math.mul(usize, self.max_live_ports, 9) catch return error.InvalidConfig;
        _ = std.math.add(usize, jobs, 1) catch return error.InvalidConfig;
    }
};

/// Serializes immutable startup inputs before a Session can observe subsequent
/// host mutations. The returned bytes belong to the caller on success; failure
/// retains every input. Entry collections need only name/value byte slices.
pub const Configuration = struct {
    const header_bytes = 9 * 8;
    pub fn encode(memory: std.mem.Allocator, limits: Limits, cwd: []const u8, environment: anytype) error{ OutOfMemory, InvalidConfig }![]u8 {
        try limits.validate();
        if (!cleanAbsolutePath(cwd)) return error.InvalidConfig;
        var total = std.math.add(usize, header_bytes, cwd.len) catch return error.OutOfMemory;
        for (environment) |entry| {
            if (!std.process.Environ.Map.validateKeyForPut(entry.name) or std.mem.indexOfScalar(u8, entry.value, 0) != null) return error.InvalidConfig;
            total = std.math.add(usize, total, 16) catch return error.OutOfMemory;
            total = std.math.add(usize, total, entry.name.len) catch return error.OutOfMemory;
            total = std.math.add(usize, total, entry.value.len) catch return error.OutOfMemory;
        }
        const bytes = try memory.alloc(u8, total);
        for ([_]usize{ 1, limits.max_live_ports, limits.stdin_capacity, limits.stdout_capacity, limits.stderr_capacity, limits.max_stdout_capture, limits.max_stderr_capture, cwd.len, environment.len }, 0..) |value, index|
            std.mem.writeInt(u64, bytes[index * 8 ..][0..8], value, .little);
        @memcpy(bytes[header_bytes..][0..cwd.len], cwd);
        var offset = header_bytes + cwd.len;
        for (environment) |entry| {
            std.mem.writeInt(u64, bytes[offset..][0..8], entry.name.len, .little);
            std.mem.writeInt(u64, bytes[offset + 8 ..][0..8], entry.value.len, .little);
            offset += 16;
            @memcpy(bytes[offset..][0..entry.name.len], entry.name);
            offset += entry.name.len;
            @memcpy(bytes[offset..][0..entry.value.len], entry.value);
            offset += entry.value.len;
        }
        return bytes;
    }
};

fn cleanAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component|
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

const Service = ecl.Instance(struct {
    pub const State = struct {
        memory: ?*const ecl.NativeMemory = null,
        bytes: ?[]align(64) u8 = null,
        limits: Limits = .{},
        cwd_end: usize = 0,
        phase: union(enum) {
            start,
            copying: usize,
            header,
            cwd: struct { index: usize, component: usize, entries: usize },
            entry: struct { offset: usize, remaining: usize },
            name: struct { index: usize, end: usize, value_end: usize, remaining: usize },
            value: struct { index: usize, end: usize, remaining: usize },
            ready,
        } = .start,

        fn cwd(self: *const State) []const u8 {
            return self.bytes.?[Configuration.header_bytes..self.cwd_end];
        }
        fn readField(self: *const State, offset: usize) error{Failed}!usize {
            const bytes = self.bytes.?;
            if (offset > bytes.len or bytes.len - offset < 8) return error.Failed;
            return std.math.cast(usize, std.mem.readInt(u64, bytes[offset..][0..8], .little)) orelse error.Failed;
        }
    };
    pub fn init() State {
        return .{};
    }
    pub fn initialize(state: *State, context: *ecl.InstanceContext) ecl.InstanceResult {
        while (context.consume()) switch (state.phase) {
            .start => {
                const config = context.configuration();
                if (config.len < Configuration.header_bytes) return error.Failed;
                state.memory = context.memory();
                state.bytes = try context.allocate(config.len);
                state.phase = .{ .copying = 0 };
            },
            .copying => |index| {
                const source = context.configuration();
                const count = @min(256, source.len - index);
                @memcpy(state.bytes.?[index..][0..count], source[index..][0..count]);
                state.phase = if (index + count == source.len) .header else .{ .copying = index + count };
            },
            .header => {
                if (try state.readField(0) != 1) return error.Failed;
                state.limits = .{
                    .max_live_ports = try state.readField(8),
                    .stdin_capacity = try state.readField(16),
                    .stdout_capacity = try state.readField(24),
                    .stderr_capacity = try state.readField(32),
                    .max_stdout_capture = try state.readField(40),
                    .max_stderr_capture = try state.readField(48),
                };
                state.limits.validate() catch return error.Failed;
                const length = try state.readField(56);
                if (length == 0 or length > state.bytes.?.len - Configuration.header_bytes) return error.Failed;
                state.cwd_end = Configuration.header_bytes + length;
                if (!std.fs.path.isAbsolute(state.cwd())) return error.Failed;
                state.phase = .{ .cwd = .{ .index = Configuration.header_bytes, .component = Configuration.header_bytes, .entries = try state.readField(64) } };
            },
            .cwd => |cursor| {
                const end = cursor.index == state.cwd_end;
                const byte = if (end) '/' else state.bytes.?[cursor.index];
                if (byte == 0) return error.Failed;
                if (byte == '/' or byte == '\\') {
                    const length = cursor.index - cursor.component;
                    if ((length == 1 and state.bytes.?[cursor.component] == '.') or
                        (length == 2 and std.mem.eql(u8, state.bytes.?[cursor.component..cursor.index], ".."))) return error.Failed;
                }
                state.phase = if (end) .{ .entry = .{ .offset = state.cwd_end, .remaining = cursor.entries } } else .{ .cwd = .{
                    .index = cursor.index + 1,
                    .component = if (byte == '/' or byte == '\\') cursor.index + 1 else cursor.component,
                    .entries = cursor.entries,
                } };
            },
            .entry => |cursor| {
                if (cursor.remaining == 0) {
                    if (cursor.offset != state.bytes.?.len) return error.Failed;
                    state.phase = .ready;
                    continue;
                }
                if (cursor.offset > state.bytes.?.len or state.bytes.?.len - cursor.offset < 16) return error.Failed;
                const name_length = try state.readField(cursor.offset);
                const value_length = try state.readField(cursor.offset + 8);
                const start = cursor.offset + 16;
                if (name_length == 0 or name_length > state.bytes.?.len - start) return error.Failed;
                const end = start + name_length;
                if (value_length > state.bytes.?.len - end) return error.Failed;
                state.phase = .{ .name = .{ .index = start, .end = end, .value_end = end + value_length, .remaining = cursor.remaining } };
            },
            .name => |cursor| {
                if (cursor.index == cursor.end) {
                    state.phase = .{ .value = .{ .index = cursor.end, .end = cursor.value_end, .remaining = cursor.remaining } };
                    continue;
                }
                const byte = state.bytes.?[cursor.index];
                if (byte == 0 or byte == '=') return error.Failed;
                state.phase = .{ .name = .{ .index = cursor.index + 1, .end = cursor.end, .value_end = cursor.value_end, .remaining = cursor.remaining } };
            },
            .value => |cursor| {
                if (cursor.index == cursor.end) {
                    state.phase = .{ .entry = .{ .offset = cursor.end, .remaining = cursor.remaining - 1 } };
                    continue;
                }
                if (state.bytes.?[cursor.index] == 0) return error.Failed;
                state.phase = .{ .value = .{ .index = cursor.index + 1, .end = cursor.end, .remaining = cursor.remaining } };
            },
            .ready => {
                try context.configureEndpoint(Process, .stdin, state.limits.stdin_capacity);
                try context.configureEndpoint(Process, .stdout, state.limits.stdout_capacity);
                try context.configureEndpoint(Process, .stderr, state.limits.stderr_capacity);
                return .complete;
            },
        };
        return .pending;
    }
    pub fn retire(state: *State, context: *ecl.InstanceContext) bool {
        if (!context.consume()) return false;
        if (state.bytes) |bytes| context.release(bytes);
        state.bytes = null;
        return true;
    }
});

const Text = struct {
    storage: []u8,
    used: usize,
    fn bytes(self: Text) []const u8 {
        return self.storage[0..self.used];
    }
};
const EnvironmentEntry = struct { name: Text, value: Text };

/// The same resumable parser serves controller initialization and rejected
/// admission. Every partial string and collection is owned until retirement;
/// no scratch MessageView survives another SDK lookup.
const RequestParser = struct {
    memory: *const ecl.NativeMemory,
    executable: ?Text = null,
    directory: ?Text = null,
    arguments: ?[]Text = null,
    arguments_initialized: usize = 0,
    environment: ?[]EnvironmentEntry = null,
    environment_initialized: usize = 0,
    field_count: usize = 0,
    phase: union(enum) {
        start,
        fields: usize,
        arguments: Collection,
        environment: Collection,
        environment_value: NamedEnvironment,
        text: struct {
            path: [3]u64,
            depth: u2,
            count: usize,
            index: usize = 0,
            output: Text,
            continuation: Continuation,
        },
        ready,
        retiring,
    } = .start,
    const Collection = struct { field: usize, index: usize };
    const NamedEnvironment = struct { collection: Collection, name: Text };
    const Continuation = union(enum) {
        executable: usize,
        directory: usize,
        argument: Collection,
        environment_name: Collection,
        environment_value: NamedEnvironment,
    };
    const Progress = enum { pending, ready };

    fn allocator(self: *const RequestParser) std.mem.Allocator {
        return self.memory.allocator();
    }
    fn fail(context: anytype, kind: ecl.ErrorKind, message: []const u8) ecl.ControllerError {
        context.fail(kind, message);
        return error.Failed;
    }
    fn beginText(self: *RequestParser, context: anytype, path: []const u64, continuation: Continuation) ecl.ControllerError!void {
        const view = context.input(path).?;
        if (!view.isString()) return fail(context, .type, "process string fields must contain strings");
        const length: usize = @intCast(view.length().?);
        const capacity = std.math.mul(usize, length, 4) catch return error.OutOfMemory;
        const storage = try self.allocator().alloc(u8, capacity);
        var indices: [3]u64 = @splat(0);
        @memcpy(indices[0..path.len], path);
        self.phase = .{ .text = .{
            .path = indices,
            .depth = @intCast(path.len),
            .count = length,
            .output = .{ .storage = storage, .used = 0 },
            .continuation = continuation,
        } };
    }
    /// One bounded structural step. Semantic validation intentionally follows
    /// admission, matching the original process factory's precedence.
    fn step(self: *RequestParser, context: anytype) ecl.ControllerError!Progress {
        if (context.cancelled()) return error.Cancelled;
        switch (self.phase) {
            .start => {
                const root = context.input(&.{}).?;
                if (root.kind() != .dict) return fail(context, .type, "expected a process specification dict");
                self.field_count = @intCast(root.length().?);
                self.phase = .{ .fields = 0 };
            },
            .fields => |index| {
                if (index == self.field_count) {
                    if (self.executable == null) return fail(context, .domain, "process spec requires 'executable");
                    self.phase = .ready;
                    return .ready;
                }
                const key = context.input(&.{index * 2}).?.symbol() orelse return fail(context, .type, "expected symbol process specification keys");
                const field: enum { executable, cwd, args, env } = if (std.mem.eql(u8, key, "executable")) .executable else if (std.mem.eql(u8, key, "cwd")) .cwd else if (std.mem.eql(u8, key, "args")) .args else if (std.mem.eql(u8, key, "env")) .env else return fail(context, .domain, "unknown process specification field");
                switch (field) {
                    .executable => try self.beginText(context, &.{index * 2 + 1}, .{ .executable = index + 1 }),
                    .cwd => try self.beginText(context, &.{index * 2 + 1}, .{ .directory = index + 1 }),
                    .args => {
                        const view = context.input(&.{index * 2 + 1}).?;
                        if (view.kind() != .list) return fail(context, .type, "'args must be a list of strings");
                        self.arguments = try self.allocator().alloc(Text, @intCast(view.length().?));
                        self.phase = .{ .arguments = .{ .field = index, .index = 0 } };
                    },
                    .env => {
                        const view = context.input(&.{index * 2 + 1}).?;
                        if (view.kind() != .dict) return fail(context, .type, "'env must be a string-to-string dict");
                        self.environment = try self.allocator().alloc(EnvironmentEntry, @intCast(view.length().?));
                        self.phase = .{ .environment = .{ .field = index, .index = 0 } };
                    },
                }
            },
            .arguments => |collection| {
                if (collection.index == self.arguments.?.len) {
                    self.phase = .{ .fields = collection.field + 1 };
                } else try self.beginText(context, &.{ collection.field * 2 + 1, collection.index }, .{ .argument = collection });
            },
            .environment => |collection| {
                if (collection.index == self.environment.?.len) {
                    self.phase = .{ .fields = collection.field + 1 };
                } else try self.beginText(context, &.{ collection.field * 2 + 1, collection.index * 2 }, .{ .environment_name = collection });
            },
            .environment_value => |entry| try self.beginText(context, &.{ entry.collection.field * 2 + 1, entry.collection.index * 2 + 1 }, .{ .environment_value = entry }),
            .text => |*text| {
                if (text.index != text.count) {
                    var path = text.path;
                    path[text.depth] = text.index;
                    const scalar = context.input(path[0 .. text.depth + 1]).?.char() orelse return fail(context, .type, "process string fields must contain strings");
                    // SAFETY: utf8Encode fills precisely the returned prefix.
                    var encoded: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(scalar, &encoded) catch return fail(context, .domain, "process string contains an invalid Unicode scalar");
                    @memcpy(text.output.storage[text.output.used..][0..count], encoded[0..count]);
                    text.output.used += count;
                    text.index += 1;
                    return .pending;
                }
                // Copy every payload needed after replacing this union arm.
                const output = text.output;
                const continuation = text.continuation;
                switch (continuation) {
                    .executable => |field| {
                        self.executable = output;
                        self.phase = .{ .fields = field };
                    },
                    .directory => |field| {
                        self.directory = output;
                        self.phase = .{ .fields = field };
                    },
                    .argument => |collection| {
                        self.arguments.?[collection.index] = output;
                        self.arguments_initialized += 1;
                        self.phase = .{ .arguments = .{ .field = collection.field, .index = collection.index + 1 } };
                    },
                    .environment_name => |collection| self.phase = .{ .environment_value = .{ .collection = collection, .name = output } },
                    .environment_value => |entry| {
                        self.environment.?[entry.collection.index] = .{ .name = entry.name, .value = output };
                        self.environment_initialized += 1;
                        self.phase = .{ .environment = .{ .field = entry.collection.field, .index = entry.collection.index + 1 } };
                    },
                }
            },
            .ready => return .ready,
            .retiring => unreachable,
        }
        return .pending;
    }
    /// Each call consumes at most two string allocations or one collection.
    /// The caller keeps the instance pin until this returns true.
    fn retire(self: *RequestParser) bool {
        const memory = self.allocator();
        if (self.phase != .retiring) {
            switch (self.phase) {
                .text => |text| {
                    memory.free(text.output.storage);
                    if (text.continuation == .environment_value) memory.free(text.continuation.environment_value.name.storage);
                },
                .environment_value => |entry| memory.free(entry.name.storage),
                else => {},
            }
            self.phase = .retiring;
            return false;
        }
        if (self.arguments_initialized != 0) {
            self.arguments_initialized -= 1;
            memory.free(self.arguments.?[self.arguments_initialized].storage);
            return false;
        }
        if (self.environment_initialized != 0) {
            self.environment_initialized -= 1;
            const entry = self.environment.?[self.environment_initialized];
            memory.free(entry.name.storage);
            memory.free(entry.value.storage);
            return false;
        }
        if (self.arguments) |arguments| {
            memory.free(arguments);
            self.arguments = null;
            return false;
        }
        if (self.environment) |environment| {
            memory.free(environment);
            self.environment = null;
            return false;
        }
        if (self.executable) |executable| {
            memory.free(executable.storage);
            self.executable = null;
            return false;
        }
        if (self.directory) |directory| {
            memory.free(directory.storage);
            self.directory = null;
            return false;
        }
        return true;
    }
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn lock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexLock(mutex);
}
fn unlock(mutex: *std.Io.Mutex) void {
    std.Io.Threaded.mutexUnlock(mutex);
}
// Pipe writes must not depend on an embedding host's process-wide SIGPIPE
// disposition. Mask only the activity thread and consume only newly pending
// SIGPIPE before restoring the original mask.
const PipeSignals = struct {
    previous: std.posix.sigset_t,
    pending_before: bool,
    extern "c" fn sigpending(set: *std.posix.sigset_t) c_int;
    fn begin() PipeSignals {
        var only_pipe = std.posix.sigemptyset();
        std.posix.sigaddset(&only_pipe, .PIPE);
        var previous = std.posix.sigemptyset();
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &only_pipe, &previous);
        var pending = std.posix.sigemptyset();
        _ = sigpending(&pending);
        return .{ .previous = previous, .pending_before = std.posix.sigismember(&pending, .PIPE) };
    }
    fn end(self: PipeSignals) void {
        if (!self.pending_before) {
            var pending = std.posix.sigemptyset();
            if (sigpending(&pending) == 0 and std.posix.sigismember(&pending, .PIPE)) {
                var only_pipe = std.posix.sigemptyset();
                std.posix.sigaddset(&only_pipe, .PIPE);
                var caught: c_int = 0;
                _ = std.c.sigwait(&only_pipe, &caught);
            }
        }
        std.posix.sigprocmask(std.posix.SIG.SETMASK, &self.previous, null);
    }
};
const Request = enum { terminate, kill };
const GroupPhase = union(enum) {
    running,
    grace: i96,
    killed,
    reaping,
    reaped: std.process.Child.Term,
};
const Group = struct { child: std.process.Child, stdin: ?std.Io.File, stdout: ?std.Io.File, stderr: ?std.Io.File, pgid: std.posix.pid_t, phase: GroupPhase = .running, observed: bool = false };
const ProcessState = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    wake: std.Io.Event = .unset,
    joined: std.Io.Event = .unset,
    service: ?*Service.State = null,
    group: ?*Group = null,
    request: ?Request = null,
    stdin_done: bool = false,
    stdout_done: bool = false,
    stderr_done: bool = false,
    io_failed: bool = false,
    wait_cancelled: bool = false,

    fn notify(self: *ProcessState) void {
        self.changed.broadcast(io());
        self.wake.set(io());
    }
    fn signal(self: *ProcessState, group: *Group, signal_value: std.posix.SIG) bool {
        std.posix.kill(-group.pgid, signal_value) catch |err| {
            switch (err) {
                error.ProcessNotFound => return false,
                error.PermissionDenied => if (group.observed) return false,
                else => {},
            }
            self.io_failed = true;
        };
        return true;
    }
    /// The same mutex protects the last group signal and the transition that
    /// authorizes reaping. A waitable leader pins the numeric group identity.
    fn startGrace(self: *ProcessState, group: *Group) void {
        if (group.phase != .running) return;
        if (self.signal(group, .TERM)) {
            group.phase = .{ .grace = std.Io.Clock.awake.now(io()).nanoseconds + 250 * std.time.ns_per_ms };
        } else group.phase = .killed;
    }
    fn requestStop(self: *ProcessState, request: Request) void {
        lock(&self.mutex);
        defer unlock(&self.mutex);
        if (self.request != .kill) self.request = request;
        if (self.group) |group| switch (group.phase) {
            .running, .grace => if (request == .kill) {
                _ = self.signal(group, .KILL);
                group.phase = .killed;
            } else self.startGrace(group),
            .killed, .reaping, .reaped => {},
        };
        self.notify();
    }
    fn failed(self: *ProcessState) void {
        lock(&self.mutex);
        self.io_failed = true;
        self.notify();
        unlock(&self.mutex);
    }
};

const Process = ecl.Port(.{
    .controller = struct {
        pub const name = "process";
        pub const State = ProcessState;
        pub const CapacityFailure = ProcessCapacityFailure;
        pub const Lane = enum { wait, control };
        pub const cancellation = ecl.PortCancellation.acknowledge;
        pub const endpoints = .{
            .stdin = ecl.declarations.Endpoint{ .doc = "Select the process input byte stream.", .transport = .bytes, .direction = .input, .owner = .resource },
            .stdout = ecl.declarations.Endpoint{ .doc = "Select the process output byte stream.", .transport = .bytes, .direction = .output, .owner = .resource },
            .stderr = ecl.declarations.Endpoint{ .doc = "Select the process error byte stream.", .transport = .bytes, .direction = .output, .owner = .resource },
        };
        pub const activities = .{
            .input = .{ .handler = input, .endpoints = .{.stdin} },
            .output = .{ .handler = output, .endpoints = .{.stdout} },
            .errors = .{ .handler = errors, .endpoints = .{.stderr} },
            .supervisor = .{ .handler = supervise, .endpoints = .{} },
        };
        pub const operations = .{
            .wait = .{ .doc = "Wait for termination; request [].", .handler = wait, .lane = .wait, .endpoints = .{} },
            .terminate = .{ .doc = "Request process-group termination; request [].", .handler = terminate, .lane = .control, .endpoints = .{} },
            .kill = .{ .doc = "Kill the process group; request [].", .handler = kill, .lane = .control, .endpoints = .{} },
            .capture_limits = .{ .name = "capture-limits", .doc = "Read configured capture limits; request [].", .handler = captureLimits, .lane = .control, .endpoints = .{} },
        };
        pub fn init() State {
            return .{};
        }
        pub fn open(state: *State, context: *ecl.Controller) void {
            initialize(state, context) catch |err| switch (err) {
                error.OutOfMemory => context.failOutOfMemory(),
                error.Cancelled => {},
                error.Failed => {},
                error.InvalidValue => context.fail(.domain, "process specification is invalid"),
            };
        }
        fn initialize(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
            const service = context.instance(Service).?;
            var parser: RequestParser = .{ .memory = service.memory.? };
            defer while (!parser.retire()) {};
            while (try parser.step(context) != .ready) {}
            const executable = parser.executable.?.bytes();
            if (!std.fs.path.isAbsolute(executable) or std.mem.indexOfScalar(u8, executable, 0) != null)
                return RequestParser.fail(context, .domain, "process specification is invalid");
            for (parser.arguments orelse &.{}) |argument| {
                if (context.cancelled()) return error.Cancelled;
                if (std.mem.indexOfScalar(u8, argument.bytes(), 0) != null)
                    return RequestParser.fail(context, .domain, "process specification is invalid");
            }
            for (parser.environment orelse &.{}) |entry| {
                if (context.cancelled()) return error.Cancelled;
                if (!std.process.Environ.Map.validateKeyForPut(entry.name.bytes()) or std.mem.indexOfScalar(u8, entry.value.bytes(), 0) != null)
                    return RequestParser.fail(context, .domain, "process specification is invalid");
            }
            const cwd = if (parser.directory) |directory| directory.bytes() else service.cwd();
            if (!cleanAbsolutePath(cwd)) return RequestParser.fail(context, .domain, "process specification is invalid");
            const memory = service.memory.?.allocator();
            var environment = std.process.Environ.Map.init(memory);
            defer environment.deinit();
            var offset = service.cwd_end;
            while (offset != service.bytes.?.len) {
                if (context.cancelled()) return error.Cancelled;
                const name_length = try service.readField(offset);
                const value_length = try service.readField(offset + 8);
                offset += 16;
                const entry_name = service.bytes.?[offset..][0..name_length];
                offset += name_length;
                const value = service.bytes.?[offset..][0..value_length];
                offset += value_length;
                try environment.put(entry_name, value);
            }
            for (parser.environment orelse &.{}) |entry| {
                if (context.cancelled()) return error.Cancelled;
                try environment.put(entry.name.bytes(), entry.value.bytes());
            }
            const arguments = parser.arguments orelse &.{};
            const argv = try memory.alloc([]const u8, arguments.len + 1);
            defer memory.free(argv);
            argv[0] = executable;
            for (arguments, 0..) |argument, index| argv[index + 1] = argument.bytes();
            const group = try memory.create(Group);
            errdefer memory.destroy(group);
            if (context.cancelled()) return error.Cancelled;
            var spawn_io: std.Io.Threaded = .init_single_threaded;
            spawn_io.allocator = memory;
            defer spawn_io.deinit();
            const child = std.process.spawn(spawn_io.io(), .{
                .argv = argv,
                .cwd = .{ .path = cwd },
                .environ_map = &environment,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
                .pgid = 0,
            }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => RequestParser.fail(context, .io, "could not spawn process"),
            };
            group.* = .{ .child = child, .stdin = child.stdin, .stdout = child.stdout, .stderr = child.stderr, .pgid = child.id.? };
            group.child.stdin = null;
            group.child.stdout = null;
            group.child.stderr = null;
            lock(&state.mutex);
            state.service = service;
            state.group = group;
            const request = state.request;
            unlock(&state.mutex);
            if (request) |pending| state.requestStop(pending);
        }
        pub fn cancel(state: *State) void {
            state.requestStop(.kill);
        }
        pub fn cancelOperation(state: *State, lane: Lane) void {
            if (lane == .wait) {
                lock(&state.mutex);
                state.wait_cancelled = true;
                state.notify();
                unlock(&state.mutex);
            }
        }
        pub fn shutdown(state: *State, _: *ecl.Shutdown) void {
            state.requestStop(.terminate);
            state.joined.waitUncancelable(io());
        }
        pub fn deinit(state: *State) void {
            if (state.group) |group| {
                // Startup failure can prevent any activity from running. Destruction
                // owns the same child and consumes unclaimed pipe handles after join.
                if (group.phase != .reaped) {
                    _ = state.signal(group, .KILL);
                    group.child.kill(io());
                }
                if (group.stdin) |file| file.close(io());
                if (group.stdout) |file| file.close(io());
                if (group.stderr) |file| file.close(io());
                state.service.?.memory.?.allocator().destroy(group);
                state.group = null;
            }
        }
        fn takeFile(state: *State, comptime stream_name: []const u8) std.Io.File {
            lock(&state.mutex);
            defer unlock(&state.mutex);
            const file = @field(state.group.?, stream_name).?;
            @field(state.group.?, stream_name) = null;
            return file;
        }
        fn finishStream(state: *State, comptime stream_name: []const u8) void {
            lock(&state.mutex);
            @field(state, stream_name ++ "_done") = true;
            state.notify();
            unlock(&state.mutex);
        }
        fn input(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            const signals = PipeSignals.begin();
            defer signals.end();
            const file = takeFile(state, "stdin");
            defer finishStream(state, "stdin");
            defer file.close(io());
            const stream = try context.endpoint(Process, .stdin);
            // SAFETY: only the initialized prefix returned by read is consumed.
            var buffer: [4096]u8 = undefined;
            while (try stream.read(&buffer)) |count| {
                var offset: usize = 0;
                while (offset != count) {
                    const written = file.writeStreaming(io(), &.{}, &.{buffer[offset..count]}, 1) catch {
                        state.failed();
                        context.failStreams(.io, "process pipe operation failed");
                        return;
                    };
                    if (written == 0) {
                        state.failed();
                        return;
                    }
                    offset += written;
                }
            }
        }
        fn output(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            return drain(state, context, .stdout);
        }
        fn errors(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            return drain(state, context, .stderr);
        }
        fn drain(state: *State, context: *ecl.Activity, comptime endpoint: enum { stdout, stderr }) ecl.ControllerError!void {
            const file = takeFile(state, @tagName(endpoint));
            defer finishStream(state, @tagName(endpoint));
            defer file.close(io());
            const stream = try context.endpoint(Process, @field(Process.Endpoints.Name, @tagName(endpoint)));
            // SAFETY: only the initialized prefix returned by read is consumed.
            var buffer: [4096]u8 = undefined;
            while (true) {
                const count = file.readStreaming(io(), &.{&buffer}) catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => {
                        state.failed();
                        context.failStreams(.io, "process pipe operation failed");
                        return;
                    },
                };
                if (count == 0) continue;
                lock(&state.mutex);
                const discard = state.request != null;
                unlock(&state.mutex);
                if (!discard) stream.write(buffer[0..count]) catch |err| {
                    lock(&state.mutex);
                    const stopping = state.request != null;
                    unlock(&state.mutex);
                    if (!stopping) return err;
                };
            }
        }
        fn supervise(state: *State, context: *ecl.Activity) ecl.ControllerError!void {
            defer state.joined.set(io());
            const group = state.group.?;
            var stopped_outputs = false;
            while (true) {
                lock(&state.mutex);
                state.wake.reset();
                const stopping = state.request != null;
                const reaped = group.phase == .reaped;
                const done = state.stdin_done and state.stdout_done and state.stderr_done;
                unlock(&state.mutex);
                if (stopping and !stopped_outputs) {
                    context.finishInput(Process, .stdin) catch {};
                    context.stopOutput(Process, .stdout) catch {};
                    context.stopOutput(Process, .stderr) catch {};
                    stopped_outputs = true;
                }
                if (reaped and done) return;
                if (!reaped) {
                    const observed = observeLeader(group.pgid) catch failed: {
                        state.failed();
                        state.requestStop(.kill);
                        break :failed true;
                    };
                    lock(&state.mutex);
                    if (observed) {
                        group.observed = true;
                        state.startGrace(group);
                    }
                    if (group.phase == .grace and std.Io.Clock.awake.now(io()).nanoseconds >= group.phase.grace) {
                        _ = state.signal(group, .KILL);
                        group.phase = .killed;
                    }
                    const reap = group.observed and group.phase == .killed;
                    if (reap) group.phase = .reaping;
                    unlock(&state.mutex);
                    if (reap) {
                        const term = group.child.wait(io()) catch failed: {
                            group.child.kill(io());
                            state.failed();
                            break :failed std.process.Child.Term{ .unknown = 0 };
                        };
                        lock(&state.mutex);
                        group.phase = .{ .reaped = term };
                        state.notify();
                        unlock(&state.mutex);
                        context.finishInput(Process, .stdin) catch {};
                    }
                }
                state.wake.waitTimeout(io(), .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
            }
        }
        fn empty(context: *ecl.Controller) ecl.ControllerError!void {
            const value = context.input(&.{}).?;
            if (value.kind() != .list or value.length().? != 0)
                return RequestParser.fail(context, .domain, "process operations require an empty request list");
        }
        fn wait(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
            defer _ = context.acknowledgeCancellation();
            try empty(context);
            lock(&state.mutex);
            state.wait_cancelled = false;
            unlock(&state.mutex);
            if (context.cancelled()) return error.Cancelled;
            lock(&state.mutex);
            while (!(state.group.?.phase == .reaped and state.stdin_done) and !state.io_failed and !state.wait_cancelled)
                state.changed.waitUncancelable(io(), &state.mutex);
            const failed = state.io_failed;
            const term: ?std.process.Child.Term = if (state.group.?.phase == .reaped) state.group.?.phase.reaped else null;
            unlock(&state.mutex);
            if (context.cancelled()) return error.Cancelled;
            if (failed) return RequestParser.fail(context, .io, "process pipe operation failed");
            const info: struct { kind: []const u8, field: []const u8, number: i64 } = switch (term.?) {
                .exited => |number| .{ .kind = "exited", .field = "code", .number = number },
                .signal => |number| .{ .kind = "signaled", .field = "signal", .number = @intFromEnum(number) },
                .stopped => |number| .{ .kind = "stopped", .field = "signal", .number = @intFromEnum(number) },
                .unknown => |number| .{ .kind = "unknown", .field = "status", .number = number },
            };
            const builder = context.builder();
            try builder.symbol("kind");
            try builder.symbol(info.kind);
            try builder.symbol(info.field);
            try builder.int(info.number);
            try builder.dictionary(2);
            try builder.result();
        }
        fn terminate(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
            defer _ = context.acknowledgeCancellation();
            try empty(context);
            state.requestStop(.terminate);
        }
        fn kill(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
            defer _ = context.acknowledgeCancellation();
            try empty(context);
            state.requestStop(.kill);
        }
        fn captureLimits(state: *State, context: *ecl.Controller) ecl.ControllerError!void {
            defer _ = context.acknowledgeCancellation();
            try empty(context);
            const builder = context.builder();
            try builder.symbol("stdout");
            try builder.int(std.math.cast(i64, state.service.?.limits.max_stdout_capture) orelse return error.Failed);
            try builder.symbol("stderr");
            try builder.int(std.math.cast(i64, state.service.?.limits.max_stderr_capture) orelse return error.Failed);
            try builder.dictionary(2);
            try builder.result();
        }
    },
});

const wait_api = struct {
    extern "c" fn waitid(id_type: c_int, id: c_uint, info: *std.c.siginfo_t, options: c_int) c_int;
};
fn observeLeader(pid: std.posix.pid_t) error{Io}!bool {
    const options: c_int = switch (builtin.os.tag) {
        .linux => std.os.linux.W.EXITED | std.os.linux.W.NOWAIT | std.os.linux.W.NOHANG,
        .macos => 0x04 | 0x20 | 0x01,
        else => @compileError("process backend requires Linux or macOS"),
    };
    var info = std.mem.zeroes(std.c.siginfo_t);
    while (true) {
        const result = wait_api.waitid(1, @intCast(pid), &info, options);
        if (result == 0) return @intFromEnum(info.signo) != 0;
        switch (std.posix.errno(result)) {
            .INTR => continue,
            else => return error.Io,
        }
    }
}
const ProcessCapacityFailure = ecl.CapacityFailure(struct {
    pub const State = struct { parser: ?RequestParser = null };
    pub fn init() State {
        return .{};
    }
    pub fn step(state: *State, context: *ecl.RejectedOpen) ecl.RejectionResult {
        if (state.parser == null) state.parser = .{ .memory = context.instance(Service).?.memory.? };
        while (context.consume(1)) {
            if (try state.parser.?.step(context) == .ready) {
                context.fail(.domain, "host process-port limit reached");
                return .completed;
            }
        }
        return .yielded;
    }
    pub fn retire(state: *State, context: *ecl.RejectedOpen) bool {
        while (context.consume(1)) {
            if (state.parser) |*parser| {
                if (parser.retire()) return true;
            } else return true;
        }
        return false;
    }
});
pub const Extension = ecl.module(.{
    .linkage = .static,
    .name = "proc.core",
    .doc = "Supervised processes with bounded byte streams.",
    .instance = Service,
    .ports = .{Process},
    .words = .{ecl.factory("process", "Spawn a process from a specification.", Process)},
});
