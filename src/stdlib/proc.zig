//! Capability-gated subprocess ports and bounded process execution.
//!
//! Parsing, byte validation, pipe transfer, and result construction all run
//! as scheduler drivers. The POSIX controller itself lives in process_port;
//! this module is only the value-level adapter and never exposes a PID.

const std = @import("std");
const dict = @import("../dict.zig");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const kernel_storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const process = @import("../process_port.zig");
const value = @import("../value.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Value = value.Value;

pub const words = [_]env.BuiltinWord{
    .{ .name = "spawn", .doc = "( spec -- port ) Spawn an explicitly authorized absolute executable.", .primitive = spawn },
    .{ .name = "write", .doc = "( port bytes -- ) Queue exact bytes for the process stdin.", .primitive = write },
    .{ .name = "close-input", .doc = "( port -- ) Close stdin after queued bytes are written.", .primitive = closeInput },
    .{ .name = "read-stdout", .doc = "( port max -- bytes ) Read at most max exact stdout bytes.", .primitive = readStdout },
    .{ .name = "read-stderr", .doc = "( port max -- bytes ) Read at most max exact stderr bytes.", .primitive = readStderr },
    .{ .name = "wait", .doc = "( port -- termination ) Wait for the stable terminal result.", .primitive = wait },
    .{ .name = "terminate", .doc = "( port -- ) Request process-group termination.", .primitive = terminate },
    .{ .name = "kill", .doc = "( port -- ) Force process-group termination.", .primitive = kill },
    .{ .name = "run", .doc = "( spec -- result ) Run with bounded stdin and concurrent output capture.", .primitive = run },
};

const Keys = struct {
    executable: u32,
    args: u32,
    cwd: u32,
    env: u32,
    stdin: u32,
    stdout_limit: u32,
    stderr_limit: u32,
    timeout_ms: u32,
    kind: u32,
    code: u32,
    signal: u32,
    status: u32,
    term: u32,
    stdout: u32,
    stderr: u32,
    exited: u32,
    signaled: u32,
    stopped: u32,
    unknown: u32,

    fn init() error{OutOfMemory}!Keys {
        return .{
            .executable = try intern.intern("executable"),
            .args = try intern.intern("args"),
            .cwd = try intern.intern("cwd"),
            .env = try intern.intern("env"),
            .stdin = try intern.intern("stdin"),
            .stdout_limit = try intern.intern("stdout-limit"),
            .stderr_limit = try intern.intern("stderr-limit"),
            .timeout_ms = try intern.intern("timeout-ms"),
            .kind = try intern.intern("kind"),
            .code = try intern.intern("code"),
            .signal = try intern.intern("signal"),
            .status = try intern.intern("status"),
            .term = try intern.intern("term"),
            .stdout = try intern.intern("stdout"),
            .stderr = try intern.intern("stderr"),
            .exited = try intern.intern("exited"),
            .signaled = try intern.intern("signaled"),
            .stopped = try intern.intern("stopped"),
            .unknown = try intern.intern("unknown"),
        };
    }
};

fn spawn(evaluator: *Machine) MachineError!void {
    return beginSpec(evaluator, .spawn);
}

fn run(evaluator: *Machine) MachineError!void {
    return beginSpec(evaluator, .run);
}

fn beginSpec(evaluator: *Machine, mode: SpecDriver.Mode) MachineError!void {
    var spec = try evaluator.popValue();
    errdefer spec.deinit();
    if (spec.borrow() != .dict) return evaluator.typeError("a process specification dict");
    const access = evaluator.unit.inherited.process_access orelse
        return evaluator.fail(.domain, "process creation is unavailable");
    const driver = try evaluator.allocator().create(SpecDriver);
    errdefer evaluator.allocator().destroy(driver);
    const keys = try Keys.init();
    driver.* = .{
        .allocator = evaluator.allocator(),
        .releases = evaluator.releaseDomain(),
        .access = access,
        .mode = mode,
        .keys = keys,
        .spec_value = spec.take(),
    };
    evaluator.adoptDriver(driver);
}

const Range = struct { start: usize, len: usize };
const EnvRange = struct { name: Range, value: Range };

const SpecDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;

    const Mode = enum { spawn, run };
    const Phase = enum {
        fields,
        args,
        env_name,
        env_value,
        encode,
        copy_string,
        stdin,
        launch,
        run_io,
        stdout_value,
        stderr_value,
        finish,
    };
    const StringTarget = enum { executable, cwd, arg, env_name, env_value };
    const RunFailure = enum { overflow, timeout, io };

    const TimeoutDuration = struct {
        milliseconds: u64,
    };

    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    access: *@import("../external.zig").ProcessAccess,
    mode: Mode,
    keys: Keys,
    spec_value: ?Value,
    phase: Phase = .fields,
    field_index: usize = 0,
    collection: ?Value = null,
    collection_index: usize = 0,
    string_target: StringTarget = .executable,
    encoder: ?kernel_storage.StringEncoder = null,
    copy_bytes: ?[]u8 = null,
    copy_index: usize = 0,
    blob: std.ArrayList(u8) = .empty,
    executable: ?Range = null,
    cwd: ?Range = null,
    arguments: std.ArrayList(Range) = .empty,
    environment: std.ArrayList(EnvRange) = .empty,
    pending_env_name: ?Range = null,
    stdin_encoder: ?kernel_storage.ByteVectorEncoder = null,
    stdin_bytes: ?kernel_storage.ByteVector = null,
    stdout_limit: usize = 0,
    stderr_limit: usize = 0,
    stdout_limit_set: bool = false,
    stderr_limit_set: bool = false,
    timeout: ?TimeoutDuration = null,
    port_value: ?Value = null,
    write_permit: ?*process.WritePermit = null,
    stdin_offset: usize = 0,
    stdout_capture: std.ArrayList(u8) = .empty,
    stderr_capture: std.ArrayList(u8) = .empty,
    stdout_eof: bool = false,
    stderr_eof: bool = false,
    run_cursor: ?*process.RunCursor = null,
    stdout_reader: bool = false,
    stderr_reader: bool = false,
    failed: ?RunFailure = null,
    termination: ?process.Termination = null,
    byte_materializer: ?list.ByteListMaterializer = null,
    stdout_value_owned: ?Value = null,
    stderr_value_owned: ?Value = null,

    pub fn deinit(self: *SpecDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.encoder) |*encoder| encoder.deinit();
        if (self.copy_bytes) |bytes| allocator.free(bytes);
        if (self.stdin_encoder) |*encoder| encoder.deinit();
        if (self.stdin_bytes) |*bytes| bytes.retire(releases, allocator);
        if (self.byte_materializer) |*materializer| materializer.retire(releases);
        if (self.port_value) |port| {
            const cell = process.fromValue(port).?;
            if (self.write_permit) |permit| cell.abandonWrite(permit);
            if (self.run_cursor) |cursor| cell.endRun(cursor);
            if (self.stdout_reader) cell.endRead(.stdout);
            if (self.stderr_reader) cell.endRead(.stderr);
            if (self.mode == .run and self.termination == null) cell.kill();
            releases.releaseValue(port);
        }
        if (self.spec_value) |spec| releases.releaseValue(spec);
        if (self.stdout_value_owned) |item| releases.releaseValue(item);
        if (self.stderr_value_owned) |item| releases.releaseValue(item);
        self.blob.deinit(allocator);
        self.arguments.deinit(allocator);
        self.environment.deinit(allocator);
        self.stdout_capture.deinit(allocator);
        self.stderr_capture.deinit(allocator);
    }

    pub fn advance(evaluator: *Machine, self: *SpecDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        var budget: usize = machine.kernel_poll_quantum;
        while (budget != 0) switch (self.phase) {
            .fields => try self.advanceFields(evaluator, &budget),
            .args => try self.advanceArgs(evaluator, &budget),
            .env_name => try self.advanceEnvName(evaluator, &budget),
            .env_value => try self.advanceEnvValue(evaluator, &budget),
            .encode => return try self.advanceString(evaluator),
            .copy_string => try self.copyString(&budget),
            .stdin => return try self.advanceStdin(evaluator),
            .launch => return try self.launch(evaluator),
            .run_io => return try self.advanceRun(evaluator),
            .stdout_value => return try self.materializeBytes(.stdout),
            .stderr_value => return try self.materializeBytes(.stderr),
            .finish => return try self.finishRun(),
        };
        return .yielded;
    }

    fn advanceFields(self: *SpecDriver, evaluator: *Machine, budget: *usize) MachineError!void {
        const header = self.spec_value.?.dict;
        const count: usize = @intCast(header.length());
        if (self.field_index == count) {
            if (self.executable == null) return evaluator.fail(.domain, "process spec requires 'executable");
            self.phase = .launch;
            return;
        }
        const key = dict.keyAt(header, self.field_index);
        if (key != .symbol) return evaluator.typeError("symbol process specification keys");
        const item = dict.valueAt(header, self.field_index);
        budget.* -= 1;
        if (key.symbol == self.keys.executable) return self.beginString(evaluator, item, .executable);
        if (key.symbol == self.keys.cwd) return self.beginString(evaluator, item, .cwd);
        if (key.symbol == self.keys.args) {
            if (item != .list) return evaluator.typeError("'args to be a list of strings");
            self.collection = item;
            self.collection_index = 0;
            self.phase = .args;
            return;
        }
        if (key.symbol == self.keys.env) {
            if (item != .dict) return evaluator.typeError("'env to be a string-to-string dict");
            self.collection = item;
            self.collection_index = 0;
            self.phase = .env_name;
            return;
        }
        const run_only = key.symbol == self.keys.stdin or key.symbol == self.keys.stdout_limit or
            key.symbol == self.keys.stderr_limit or key.symbol == self.keys.timeout_ms;
        if (run_only and self.mode == .spawn)
            return evaluator.fail(.domain, "run-only field in proc.spawn specification");
        if (key.symbol == self.keys.stdin) {
            if (item != .list) return evaluator.typeError("'stdin to be a byte list");
            self.stdin_encoder = .init(self.allocator, item);
            self.phase = .stdin;
            return;
        }
        if (key.symbol == self.keys.stdout_limit) {
            self.stdout_limit = try captureLimit(evaluator, item, "'stdout-limit");
            self.stdout_limit_set = true;
        } else if (key.symbol == self.keys.stderr_limit) {
            self.stderr_limit = try captureLimit(evaluator, item, "'stderr-limit");
            self.stderr_limit_set = true;
        } else if (key.symbol == self.keys.timeout_ms) {
            self.timeout = .{ .milliseconds = try timeoutValue(evaluator, item) };
        } else {
            return evaluator.fail(.domain, "unknown process specification field");
        }
        self.field_index += 1;
    }

    fn advanceArgs(self: *SpecDriver, evaluator: *Machine, budget: *usize) MachineError!void {
        const source = self.collection.?;
        const count: usize = @intCast(source.list.length());
        if (self.collection_index == count) {
            self.collection = null;
            self.field_index += 1;
            self.phase = .fields;
            return;
        }
        budget.* -= 1;
        return self.beginString(evaluator, list.atUnchecked(source, self.collection_index), .arg);
    }

    fn advanceEnvName(self: *SpecDriver, evaluator: *Machine, budget: *usize) MachineError!void {
        const source = self.collection.?;
        const count: usize = @intCast(source.dict.length());
        if (self.collection_index == count) {
            self.collection = null;
            self.field_index += 1;
            self.phase = .fields;
            return;
        }
        budget.* -= 1;
        return self.beginString(evaluator, dict.keyAt(source.dict, self.collection_index), .env_name);
    }

    fn advanceEnvValue(self: *SpecDriver, evaluator: *Machine, budget: *usize) MachineError!void {
        budget.* -= 1;
        return self.beginString(
            evaluator,
            dict.valueAt(self.collection.?.dict, self.collection_index),
            .env_value,
        );
    }

    fn beginString(
        self: *SpecDriver,
        evaluator: *Machine,
        item: Value,
        target: StringTarget,
    ) MachineError!void {
        if (!item.isString()) return evaluator.typeError("process string fields to contain strings");
        self.encoder = .init(self.allocator, item);
        self.string_target = target;
        self.phase = .encode;
    }

    fn advanceString(self: *SpecDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const progress = self.encoder.?.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return evaluator.fail(.domain, "process string contains an invalid Unicode scalar"),
        };
        return switch (progress) {
            .pending => .yielded,
            .complete => |bytes| complete: {
                self.encoder.?.deinit();
                self.encoder = null;
                // The completed encoder buffer becomes driver-owned before
                // the next allocation, so an OOM growing the destination
                // blob cannot strand it outside either destructor.
                self.copy_bytes = bytes;
                try self.blob.ensureUnusedCapacity(self.allocator, bytes.len);
                self.copy_index = 0;
                self.phase = .copy_string;
                break :complete .yielded;
            },
        };
    }

    fn copyString(self: *SpecDriver, budget: *usize) error{OutOfMemory}!void {
        const bytes = self.copy_bytes.?;
        const amount = @min(budget.*, bytes.len - self.copy_index);
        self.blob.appendSliceAssumeCapacity(bytes[self.copy_index..][0..amount]);
        self.copy_index += amount;
        budget.* -= amount;
        if (self.copy_index != bytes.len) return;
        const range = Range{ .start = self.blob.items.len - bytes.len, .len = bytes.len };
        self.allocator.free(bytes);
        self.copy_bytes = null;
        switch (self.string_target) {
            .executable => {
                self.executable = range;
                self.field_index += 1;
                self.phase = .fields;
            },
            .cwd => {
                self.cwd = range;
                self.field_index += 1;
                self.phase = .fields;
            },
            .arg => {
                try self.arguments.append(self.allocator, range);
                self.collection_index += 1;
                self.phase = .args;
            },
            .env_name => {
                self.pending_env_name = range;
                self.phase = .env_value;
            },
            .env_value => {
                try self.environment.append(self.allocator, .{
                    .name = self.pending_env_name.?,
                    .value = range,
                });
                self.pending_env_name = null;
                self.collection_index += 1;
                self.phase = .env_name;
            },
        }
    }

    fn advanceStdin(self: *SpecDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const progress = self.stdin_encoder.?.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.fail(.domain, "'stdin contains a value outside 0...255"),
        };
        return switch (progress) {
            .pending => .yielded,
            .complete => |bytes| complete: {
                self.stdin_encoder.?.deinit();
                self.stdin_encoder = null;
                self.stdin_bytes = bytes;
                self.field_index += 1;
                self.phase = .fields;
                break :complete .yielded;
            },
        };
    }

    fn launch(self: *SpecDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.mode == .run) {
            if (!self.stdout_limit_set) self.stdout_limit = process.stdoutCaptureLimit(self.access);
            if (!self.stderr_limit_set) self.stderr_limit = process.stderrCaptureLimit(self.access);
            if (self.stdout_limit > process.stdoutCaptureLimit(self.access) or
                self.stderr_limit > process.stderrCaptureLimit(self.access))
                return evaluator.fail(.domain, "process capture limit exceeds host policy");
        }
        const args = try self.allocator.alloc([]const u8, self.arguments.items.len);
        defer self.allocator.free(args);
        for (self.arguments.items, args) |range, *slot| slot.* = self.slice(range);
        const environment = try self.allocator.alloc(process.EnvironmentEntry, self.environment.items.len);
        defer self.allocator.free(environment);
        for (self.environment.items, environment) |entry, *slot| slot.* = .{
            .name = self.slice(entry.name),
            .value = self.slice(entry.value),
        };
        const port = process.spawnFromUnit(
            self.access,
            evaluator.unit.scheduler.?,
            evaluator.unit.task_scope.?,
            .{
                .executable = self.slice(self.executable.?),
                .args = args,
                .cwd = if (self.cwd) |cwd| self.slice(cwd) else null,
                .environment = environment,
            },
        ) catch |err| return spawnFailure(evaluator, err);
        if (self.mode == .spawn) {
            self.releases.releaseValue(self.spec_value.?);
            self.spec_value = null;
            return .{ .output = port };
        }
        self.port_value = port;
        const cell = process.fromValue(port).?;
        self.write_permit = try cell.beginWrite();
        self.run_cursor = cell.beginRun();
        cell.beginRead(.stdout) catch return evaluator.fail(.contract, "stdout already has a pending reader");
        self.stdout_reader = true;
        cell.beginRead(.stderr) catch return evaluator.fail(.contract, "stderr already has a pending reader");
        self.stderr_reader = true;
        if (self.timeout) |timeout| cell.armTimeout(timeout.milliseconds) catch
            return evaluator.fail(.io, "could not start process deadline");
        self.phase = .run_io;
        return .yielded;
    }

    fn advanceRun(self: *SpecDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const cell = process.fromValue(self.port_value.?).?;
        var progressed = false;
        if (cell.timedOut()) self.failed = .timeout;
        if (self.write_permit) |permit| {
            const input = if (self.stdin_bytes) |*bytes| bytes.bytes() else &.{};
            if (self.stdin_offset == input.len) {
                cell.finishWrite(permit);
                self.write_permit = null;
                cell.closeInput();
                progressed = true;
            } else switch (cell.write(permit, input[self.stdin_offset..])) {
                .pending => {},
                .written => |count| {
                    self.stdin_offset += count;
                    progressed = true;
                },
                .io => self.noteFailure(.io),
            }
        }
        if (!self.stdout_eof) progressed = (try self.drain(evaluator, cell, .stdout)) or progressed;
        if (!self.stderr_eof) progressed = (try self.drain(evaluator, cell, .stderr)) or progressed;
        const poll = cell.pollRun(self.run_cursor.?);
        progressed = self.observeRunPoll(poll) or progressed;
        if (cell.timedOut()) self.failed = .timeout;
        if (self.failed != null) {
            if (self.write_permit) |permit| {
                cell.abandonWrite(permit);
                self.write_permit = null;
            }
            cell.kill();
        }
        if (self.termination != null and self.stdout_eof and self.stderr_eof and
            poll.input != .pending)
        {
            if (self.write_permit) |permit| {
                cell.abandonWrite(permit);
                self.write_permit = null;
            }
            cell.endRead(.stdout);
            cell.endRead(.stderr);
            self.stdout_reader = false;
            self.stderr_reader = false;
            if (self.failed) |failure| return switch (failure) {
                .overflow => evaluator.fail(.overflow, "process capture limit exceeded"),
                .timeout => evaluator.fail(.timeout, "process deadline expired"),
                .io => evaluator.fail(.io, "process pipe operation failed"),
            };
            self.byte_materializer = .init(self.allocator, self.stdout_capture.items);
            self.phase = .stdout_value;
            return .yielded;
        }
        if (progressed) return .yielded;
        try evaluator.park(.{ .external = cell.runSource(self.run_cursor.?, self.write_permit) });
        return .yielded;
    }

    fn observeRunPoll(self: *SpecDriver, poll: process.RunPoll) bool {
        var progressed = false;
        inline for (std.enums.values(process.RunEdge)) |edge| {
            if (poll.edges.contains(edge)) switch (edge) {
                .stdout_terminal => if (!self.stdout_eof) {
                    self.stdout_eof = true;
                    progressed = true;
                },
                .stderr_terminal => if (!self.stderr_eof) {
                    self.stderr_eof = true;
                    progressed = true;
                },
                .input_terminal => if (poll.input == .broken) self.noteFailure(.io),
                .io_failure => self.noteFailure(.io),
                .reaped => self.termination = poll.termination.?,
            };
        }
        return progressed;
    }

    fn drain(
        self: *SpecDriver,
        evaluator: *Machine,
        cell: *process.ProcessCell,
        stream: process.Stream,
    ) MachineError!bool {
        var buffer: [4096]u8 = undefined;
        return switch (cell.read(stream, &buffer)) {
            .pending => false,
            .eof => eof: {
                self.noteStreamTerminal(stream);
                break :eof true;
            },
            .io => {
                self.noteStreamTerminal(stream);
                self.noteFailure(.io);
                return true;
            },
            .data => |count| data: {
                const output, const limit = switch (stream) {
                    .stdout => .{ &self.stdout_capture, self.stdout_limit },
                    .stderr => .{ &self.stderr_capture, self.stderr_limit },
                };
                if (count > limit -| output.items.len) {
                    self.noteFailure(.overflow);
                    break :data true;
                }
                output.appendSlice(self.allocator, buffer[0..count]) catch return error.OutOfMemory;
                _ = evaluator;
                break :data true;
            },
        };
    }

    fn noteStreamTerminal(self: *SpecDriver, stream: process.Stream) void {
        switch (stream) {
            .stdout => self.stdout_eof = true,
            .stderr => self.stderr_eof = true,
        }
    }

    fn noteFailure(self: *SpecDriver, failure: RunFailure) void {
        if (self.failed == null) self.failed = failure;
    }

    fn materializeBytes(self: *SpecDriver, stream: process.Stream) error{OutOfMemory}!machine.WorkProgress {
        const progress = try self.byte_materializer.?.advance(machine.kernel_poll_quantum);
        return switch (progress) {
            .pending => .yielded,
            .complete => |item| complete: {
                self.byte_materializer.?.deinit();
                self.byte_materializer = null;
                switch (stream) {
                    .stdout => {
                        self.stdout_value_owned = item;
                        self.byte_materializer = .init(self.allocator, self.stderr_capture.items);
                        self.phase = .stderr_value;
                    },
                    .stderr => {
                        self.stderr_value_owned = item;
                        self.phase = .finish;
                    },
                }
                break :complete .yielded;
            },
        };
    }

    fn finishRun(self: *SpecDriver) error{OutOfMemory}!machine.WorkProgress {
        const term = try terminationValue(self.allocator, self.releases, self.keys, self.termination.?);
        defer self.releases.releaseValue(term);
        const result = try dict.fromUniquePairs(self.allocator, self.releases, &.{
            .{ .{ .symbol = self.keys.term }, term },
            .{ .{ .symbol = self.keys.stdout }, self.stdout_value_owned.? },
            .{ .{ .symbol = self.keys.stderr }, self.stderr_value_owned.? },
        });
        self.releases.releaseValue(self.stdout_value_owned.?);
        self.releases.releaseValue(self.stderr_value_owned.?);
        self.stdout_value_owned = null;
        self.stderr_value_owned = null;
        self.termination = self.termination.?;
        return .{ .output = result };
    }

    fn slice(self: *const SpecDriver, range: Range) []const u8 {
        return self.blob.items[range.start..][0..range.len];
    }
};

fn captureLimit(evaluator: *Machine, item: Value, name: []const u8) MachineError!usize {
    if (item != .int) return evaluator.typeError("capture limits to be nonnegative integers");
    if (item.int < 0 or item.int > std.math.maxInt(usize))
        return evaluator.failFmt(.domain, "{s} is outside the supported range", .{name});
    return @intCast(item.int);
}

fn timeoutValue(evaluator: *Machine, item: Value) MachineError!u64 {
    if (item != .int) return evaluator.typeError("'timeout-ms to be a nonnegative integer");
    if (item.int < 0) return evaluator.fail(.domain, "'timeout-ms must be nonnegative");
    return @intCast(item.int);
}

fn spawnFailure(evaluator: *Machine, failure: process.SpawnError) MachineError {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => evaluator.fail(.domain, "process ports are unsupported on this target"),
        error.Denied => evaluator.fail(.domain, "process specification denied by host policy"),
        error.InvalidSpec => evaluator.fail(.domain, "invalid process specification"),
        error.LiveLimit => evaluator.fail(.domain, "host process-port limit reached"),
        error.ScopeClosing => evaluator.fail(.cancelled, "process scope is closing"),
        error.Io => evaluator.fail(.io, "could not spawn process"),
    };
}

fn portCell(evaluator: *Machine, item: Value) MachineError!*process.ProcessCell {
    return process.fromValue(item) orelse evaluator.typeError("a process port");
}

fn closeInput(evaluator: *Machine) MachineError!void {
    var port = try evaluator.popValue();
    defer port.deinit();
    (try portCell(evaluator, port.borrow())).closeInput();
}

fn terminate(evaluator: *Machine) MachineError!void {
    var port = try evaluator.popValue();
    defer port.deinit();
    (try portCell(evaluator, port.borrow())).terminate();
}

fn kill(evaluator: *Machine) MachineError!void {
    var port = try evaluator.popValue();
    defer port.deinit();
    (try portCell(evaluator, port.borrow())).kill();
}

fn write(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var bytes = try evaluator.popValue();
    errdefer bytes.deinit();
    if (bytes.borrow() != .list) return evaluator.typeError("a byte list");
    var port = try evaluator.popValue();
    errdefer port.deinit();
    const cell = try portCell(evaluator, port.borrow());
    const permit = try cell.beginWrite();
    errdefer cell.abandonWrite(permit);
    const bytes_borrowed = bytes.borrow();
    const driver = try evaluator.allocator().create(WriteDriver);
    driver.* = .{
        .port = port.take(),
        .bytes_value = bytes.take(),
        .encoder = .init(evaluator.allocator(), bytes_borrowed),
        .cell = cell,
        .permit = permit,
    };
    evaluator.adoptDriver(driver);
}

const WriteDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    port: Value,
    bytes_value: Value,
    encoder: ?kernel_storage.ByteVectorEncoder,
    bytes: ?kernel_storage.ByteVector = null,
    cell: *process.ProcessCell,
    permit: ?*process.WritePermit = null,
    offset: usize = 0,

    pub fn deinit(self: *WriteDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.permit) |permit| self.cell.abandonWrite(permit);
        if (self.encoder) |*encoder| encoder.deinit();
        if (self.bytes) |*bytes| bytes.retire(releases, allocator);
        releases.releaseValue(self.bytes_value);
        releases.releaseValue(self.port);
    }

    pub fn advance(evaluator: *Machine, self: *WriteDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.bytes == null) switch (self.encoder.?.advance(machine.kernel_poll_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.fail(.domain, "write contains a value outside 0...255"),
        }) {
            .pending => return .yielded,
            .complete => |bytes| {
                self.encoder.?.deinit();
                self.encoder = null;
                self.bytes = bytes;
            },
        };
        const source = self.bytes.?.bytes();
        if (self.offset == source.len) {
            self.cell.finishWrite(self.permit.?);
            self.permit = null;
            return .completed;
        }
        return switch (self.cell.write(self.permit.?, source[self.offset..])) {
            .written => |count| progressed: {
                self.offset += count;
                break :progressed .yielded;
            },
            .io => evaluator.fail(.io, "process stdin is closed"),
            .pending => parked: {
                try evaluator.park(.{ .external = self.cell.writeSource(self.permit.?) });
                break :parked .yielded;
            },
        };
    }
};

fn readStdout(evaluator: *Machine) MachineError!void {
    return beginRead(evaluator, .stdout);
}

fn readStderr(evaluator: *Machine) MachineError!void {
    return beginRead(evaluator, .stderr);
}

fn beginRead(evaluator: *Machine, stream: process.Stream) MachineError!void {
    try evaluator.require(2);
    var maximum = try evaluator.popValue();
    defer maximum.deinit();
    if (maximum.borrow() != .int) return evaluator.typeError("a positive byte count");
    if (maximum.borrow().int <= 0 or maximum.borrow().int > std.math.maxInt(usize))
        return evaluator.fail(.domain, "process read count must be positive");
    var port = try evaluator.popValue();
    errdefer port.deinit();
    const cell = try portCell(evaluator, port.borrow());
    const count = @min(@as(usize, @intCast(maximum.borrow().int)), cell.readCapacity(stream));
    cell.beginRead(stream) catch return evaluator.fail(.contract, "process stream already has a pending reader");
    errdefer cell.endRead(stream);
    const buffer = try evaluator.allocator().alloc(u8, count);
    errdefer evaluator.allocator().free(buffer);
    const driver = try evaluator.allocator().create(ReadDriver);
    errdefer evaluator.allocator().destroy(driver);
    driver.* = .{
        .allocator = evaluator.allocator(),
        .port = port.take(),
        .cell = cell,
        .stream = stream,
        .buffer = buffer,
    };
    evaluator.adoptDriver(driver);
}

const ReadDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    allocator: std.mem.Allocator,
    port: Value,
    cell: *process.ProcessCell,
    stream: process.Stream,
    buffer: []u8,
    count: ?usize = null,
    materializer: ?list.ByteListMaterializer = null,

    pub fn deinit(self: *ReadDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.materializer) |*materializer| materializer.retire(releases);
        self.cell.endRead(self.stream);
        allocator.free(self.buffer);
        releases.releaseValue(self.port);
    }

    pub fn advance(evaluator: *Machine, self: *ReadDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.count == null) switch (self.cell.read(self.stream, self.buffer)) {
            .pending => {
                try evaluator.park(.{ .external = self.cell.readSource(self.stream) });
                return .yielded;
            },
            .io => return evaluator.fail(.io, "process output pipe failed"),
            .eof => self.count = 0,
            .data => |count| self.count = count,
        };
        if (self.materializer == null)
            self.materializer = .init(self.allocator, self.buffer[0..self.count.?]);
        return switch (try self.materializer.?.advance(machine.kernel_poll_quantum)) {
            .pending => .yielded,
            .complete => |item| complete: {
                self.materializer.?.deinit();
                self.materializer = null;
                break :complete .{ .output = item };
            },
        };
    }
};

fn wait(evaluator: *Machine) MachineError!void {
    var port = try evaluator.popValue();
    errdefer port.deinit();
    const cell = try portCell(evaluator, port.borrow());
    const keys = try Keys.init();
    try evaluator.startDriver(WaitDriver{
        .port = .init(port.take()),
        .cell = cell,
        .keys = keys,
    });
}

const WaitDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    port: heap.Owned(Value),
    cell: *process.ProcessCell,
    keys: Keys,

    pub fn advance(evaluator: *Machine, self: *WaitDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        const termination = self.cell.termination() orelse {
            try evaluator.park(.{ .external = self.cell.waitSource() });
            return .yielded;
        };
        return .{ .output = try terminationValue(evaluator.allocator(), evaluator.releaseDomain(), self.keys, termination) };
    }
};

fn terminationValue(
    allocator: std.mem.Allocator,
    releases: *heap.ReleaseDomain,
    keys: Keys,
    termination: process.Termination,
) error{OutOfMemory}!Value {
    const fields: struct { tag: u32, field: u32, number: i64 } = switch (termination) {
        .exited => |code| .{ .tag = keys.exited, .field = keys.code, .number = code },
        .signaled => |signal_value| .{ .tag = keys.signaled, .field = keys.signal, .number = signal_value },
        .stopped => |signal_value| .{ .tag = keys.stopped, .field = keys.signal, .number = signal_value },
        .unknown => |status| .{ .tag = keys.unknown, .field = keys.status, .number = status },
    };
    return dict.fromUniquePairs(allocator, releases, &.{
        .{ .{ .symbol = keys.kind }, .{ .symbol = fields.tag } },
        .{ .{ .symbol = fields.field }, .{ .int = fields.number } },
    });
}
