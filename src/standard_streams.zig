//! The standard streams as port endpoints. A Session owns one input device
//! and two output devices for the whole of its life; `fd.in`, `fd.out`, and
//! `fd.err` publish the same three endpoint values every time, so the console
//! is one device kind with every other byte stream and `fd.read` and
//! `fd.write` need to know nothing about it.
//!
//! The devices are not resources: no task scope owns them, nothing closes
//! them, and `@give` never moves them. What they share with a resource's
//! endpoints is the contract: a read is one host read returning what is
//! available, an exhausted stream reads as `[]` forever, one reader may be
//! pending at a time, and writers take FIFO turns so each call's bytes stay
//! contiguous however the scheduler interleaves their chunks.
const std = @import("std");
const heap = @import("heap.zig");
const external = @import("external.zig");
const bytes = @import("port_bytes.zig");
const endpoints = @import("port_endpoint.zig");
const console_api = @import("console.zig");
const Value = @import("value.zig").Value;

pub const Availability = enum { data, program_source };

pub const Device = enum { input, output, diagnostics };

/// The three devices and their published endpoint values. Values are made on
/// first use under the mutex and released once, by the Session, after every
/// unit has stopped.
pub const Devices = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    input: Input,
    output: Output,
    diagnostics: Output,
    values: [3]?Value = .{ null, null, null },

    pub fn init(
        allocator: std.mem.Allocator,
        host_io: std.Io,
        availability: Availability,
        console: *console_api.Console,
    ) Devices {
        return .{
            .allocator = allocator,
            .input = .{ .memory = allocator, .host_io = host_io, .availability = availability },
            .output = .{ .memory = allocator, .console = console, .stream = .output },
            .diagnostics = .{ .memory = allocator, .console = console, .stream = .diagnostics },
        };
    }

    /// Release the published values. Every endpoint borrowed from them must
    /// already be unreachable: the Session calls this after its scheduler has
    /// stopped and its stack is released.
    pub fn deinit(self: *Devices, releases: *heap.ReleaseDomain) void {
        for (&self.values) |*slot| if (slot.*) |item| {
            releases.releaseValue(item);
            slot.* = null;
        };
    }

    pub const ValueError = error{ OutOfMemory, ProgramSource };

    /// The endpoint value of one device, the same value on every call.
    pub fn value(self: *Devices, device: Device) ValueError!Value {
        if (device == .input and self.input.availability == .program_source) return error.ProgramSource;
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        const slot = &self.values[@backingInt(device)];
        if (slot.* == null) slot.* = switch (device) {
            .input => try endpoints.Endpoint.create(Input, .reader, 0, &self.input),
            .output => try endpoints.Endpoint.create(Output, .writer, 1, &self.output),
            .diagnostics => try endpoints.Endpoint.create(Output, .writer, 2, &self.diagnostics),
        };
        return slot.*.?;
    }
};

/// Standard input. Reads are host reads on the calling worker: the stream is
/// a pipe or a file, never a socket, so a reader parks on nothing and the
/// readiness source below is never registered.
pub const Input = struct {
    memory: std.mem.Allocator,
    host_io: std.Io,
    availability: Availability,
    busy: std.atomic.Value(bool) = .init(false),
    eof: std.atomic.Value(bool) = .init(false),

    const capacity: usize = 1024 * 1024;

    pub fn allocator(self: *Input) std.mem.Allocator {
        return self.memory;
    }
    pub fn releasePort(_: *Input) void {}

    pub fn beginRead(self: *Input) error{Busy}!void {
        if (self.busy.swap(true, .acq_rel)) return error.Busy;
    }
    pub fn endRead(self: *Input) void {
        self.busy.store(false, .release);
    }
    pub fn readCapacity(_: *Input) usize {
        return capacity;
    }
    pub fn read(self: *Input, destination: []u8) bytes.Read {
        if (self.eof.load(.acquire)) return .eof;
        const count = std.Io.File.stdin().readStreaming(self.host_io, &.{destination}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return .{ .failed = bytes.Failure.init(.io, @errorName(err)) },
        };
        if (count == 0) {
            self.eof.store(true, .release);
            return .eof;
        }
        return .{ .data = count };
    }
    pub fn readSource(self: *Input) external.ReadinessSource {
        return external.readinessSource(Input, self, 0);
    }
    pub fn retainReadiness(_: *Input) void {}
    pub fn releaseReadiness(_: *Input) void {}
    pub fn registerReadiness(_: *Input, _: u64, _: external.WakeTarget) external.RegisterError!external.RegisterResult {
        return .{ .ready = .ready };
    }
};

/// Standard output or diagnostics. A permit is one write turn; turns are
/// served in the order they were taken, and a permit that is not at the head
/// reports `pending` and is woken when it becomes the head.
pub const Output = struct {
    memory: std.mem.Allocator,
    console: *console_api.Console,
    stream: enum { output, diagnostics },
    mutex: std.Io.Mutex = .init,
    next_ticket: u64 = 0,
    head: u64 = 0,
    finished: bool = false,
    waiting: ?*Permit = null,
    /// Turns retired before reaching the head, kept until the head passes them.
    retired: ?*Permit = null,

    pub fn allocator(self: *Output) std.mem.Allocator {
        return self.memory;
    }
    pub fn releasePort(_: *Output) void {}

    pub fn beginWrite(self: *Output) error{ OutOfMemory, Finished }!*Permit {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        if (self.finished) return error.Finished;
        const permit = try self.memory.create(Permit);
        permit.* = .{ .device = self, .ticket = self.next_ticket };
        self.next_ticket += 1;
        return permit;
    }

    /// Finishing refuses new turns; admitted turns still complete, as a
    /// resource's output does.
    pub fn finish(self: *Output) void {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        self.finished = true;
    }

    pub fn writeBytes(permit: *Permit, source: []const u8) bytes.Write {
        const device = permit.device;
        std.Io.Threaded.mutexLockUncancelable(&device.mutex);
        const at_head = permit.ticket == device.head;
        std.Io.Threaded.mutexUnlock(&device.mutex);
        if (!at_head) return .pending;
        const result = switch (device.stream) {
            .output => device.console.writeOutput(source, false),
            .diagnostics => device.console.writeDiagnostics(source, false),
        };
        result catch return .{ .failed = bytes.Failure.init(.io, "standard stream write failed") };
        return .{ .written = source.len };
    }

    /// Advance past a retired head turn, then past every later turn that
    /// retired before it reached the head, and wake the turn that follows.
    /// A turn retired ahead of the head is adopted by the device, which
    /// drops the driver's reference once the head passes it; the result says
    /// whether that happened.
    fn retire(self: *Output, permit: *Permit) bool {
        std.Io.Threaded.mutexLockUncancelable(&self.mutex);
        if (permit.ticket != self.head) {
            permit.retired_next = self.retired;
            self.retired = permit;
            std.Io.Threaded.mutexUnlock(&self.mutex);
            return true;
        }
        var wake: ?external.WakeTarget = null;
        var passed: ?*Permit = null;
        self.head += 1;
        while (self.takeRetired(self.head)) |skipped| {
            self.head += 1;
            skipped.retired_next = passed;
            passed = skipped;
        }
        var cursor = self.waiting;
        while (cursor) |waiter| : (cursor = waiter.next) {
            if (waiter.ticket == self.head) {
                wake = waiter.target;
                waiter.target = null;
                break;
            }
        }
        std.Io.Threaded.mutexUnlock(&self.mutex);
        if (wake) |target| {
            target.wake(.ready);
            target.release();
        }
        while (passed) |skipped| {
            passed = skipped.retired_next;
            skipped.release();
        }
        return false;
    }

    fn takeRetired(self: *Output, ticket: u64) ?*Permit {
        var link = &self.retired;
        while (link.*) |candidate| : (link = &candidate.retired_next) {
            if (candidate.ticket == ticket) {
                link.* = candidate.retired_next;
                candidate.retired_next = null;
                return candidate;
            }
        }
        return null;
    }

    pub const Permit = struct {
        device: *Output,
        ticket: u64,
        /// One reference for the write driver, one per outstanding readiness
        /// source. The storage goes when the last is dropped.
        references: u32 = 1,
        target: ?external.WakeTarget = null,
        next: ?*Permit = null,
        retired: bool = false,
        retired_next: ?*Permit = null,

        pub fn source(self: *Permit) external.ReadinessSource {
            return external.readinessSource(Permit, self, self.ticket);
        }
        pub fn finish(self: *Permit) void {
            self.complete();
        }
        pub fn cancel(self: *Permit) void {
            self.complete();
        }
        fn complete(self: *Permit) void {
            const device = self.device;
            std.Io.Threaded.mutexLockUncancelable(&device.mutex);
            self.retired = true;
            std.Io.Threaded.mutexUnlock(&device.mutex);
            if (!device.retire(self)) self.release();
        }

        pub fn retainReadiness(self: *Permit) void {
            const device = self.device;
            std.Io.Threaded.mutexLockUncancelable(&device.mutex);
            defer std.Io.Threaded.mutexUnlock(&device.mutex);
            self.references += 1;
        }
        pub fn releaseReadiness(self: *Permit) void {
            self.release();
        }
        fn release(self: *Permit) void {
            const device = self.device;
            std.Io.Threaded.mutexLockUncancelable(&device.mutex);
            self.references -= 1;
            const last = self.references == 0;
            if (last) unlink(device, self);
            std.Io.Threaded.mutexUnlock(&device.mutex);
            if (last) {
                std.debug.assert(self.target == null);
                device.memory.destroy(self);
            }
        }
        /// Ready at once when this turn is the head; otherwise retained until
        /// the head retires into it or the registration is cancelled.
        pub fn registerReadiness(self: *Permit, _: u64, target: external.WakeTarget) external.RegisterError!external.RegisterResult {
            const device = self.device;
            std.Io.Threaded.mutexLockUncancelable(&device.mutex);
            defer std.Io.Threaded.mutexUnlock(&device.mutex);
            if (self.ticket == device.head or self.retired) return .{ .ready = .ready };
            std.debug.assert(self.target == null);
            target.retain();
            self.target = target;
            self.next = device.waiting;
            device.waiting = self;
            return .{ .registered = external.readinessRegistration(Permit, self) };
        }
        pub fn cancelReadiness(self: *Permit) void {
            const device = self.device;
            std.Io.Threaded.mutexLockUncancelable(&device.mutex);
            const target = self.target;
            self.target = null;
            unlink(device, self);
            std.Io.Threaded.mutexUnlock(&device.mutex);
            if (target) |retained| retained.release();
        }
        fn unlink(device: *Output, permit: *Permit) void {
            var link = &device.waiting;
            while (link.*) |waiter| : (link = &waiter.next) {
                if (waiter == permit) {
                    link.* = waiter.next;
                    waiter.next = null;
                    return;
                }
            }
        }
    };
};
