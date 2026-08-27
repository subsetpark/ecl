//! The internal `json` module: RFC 8259 over `std.json`.
//!
//! This is a builtin-backed module rather than an SDK one because the SDK
//! deliberately withholds what a JSON parser needs — an allocator, and state
//! that can outlive a yield without fitting in a fixed POD record. Holding
//! that authority is also what lets the parsing half be `std.json.Scanner`
//! instead of a hand-written grammar.
//!
//! Value mapping. Objects become dicts with string keys, arrays become lists,
//! and integral in-range numbers become ints while everything else numeric
//! becomes a float. JSON's three literals become the ordinary symbols `'null`,
//! `'true`, and `'false`: data, not language nil or language booleans, so a
//! document round-trips instead of collapsing into 0 and 1.
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const list = @import("../list.zig");
const dict = @import("../dict.zig");
const intern = @import("../intern.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const kernel_storage = @import("../kernel_storage.zig");
const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

pub const words = [_]env.BuiltinWord{
    // These words state their stack shape in prose rather than as a declared
    // effect. A declared effect is checked the instant a builtin primitive
    // returns, but both of these hand their work to a scheduler driver and
    // produce their output later, so a declaration would fail a contract it
    // actually honors. Documenting the shape keeps `doc` informative without
    // asserting something the binding kind cannot enforce.
    .{
        .name = "parse",
        .doc = "( text -- value ) Parse RFC 8259 text into ECL values, " ++
            "mapping null, true, and false to the symbols of those names.",
        .primitive = parse,
    },
    .{
        .name = "emit",
        .doc = "( value -- text ) Render an ECL value as RFC 8259 text, " ++
            "requiring string or symbol dictionary keys.",
        .primitive = emit,
    },
};

/// How many scanner tokens or output bytes one scheduler turn may process.
const token_quantum: usize = 4096;

fn parse(evaluator: *Machine) MachineError!void {
    var text = try evaluator.popString();
    defer text.deinit();
    const encoder = kernel_storage.StringEncoder.init(evaluator.allocator(), text.borrow());
    try evaluator.startDriver(ParseDriver{
        .allocator = evaluator.allocator(),
        .text = .init(text.take()),
        .encoder = .init(encoder),
    });
}

/// One partly built container. The values are host-side scratch, which is
/// exactly the state an SDK module could not keep across a yield.
const Frame = struct {
    kind: enum { array, object },
    values: std.ArrayList(Value) = .empty,
    /// An object's pending key, held until its value arrives.
    key: ?Value = null,
};

const ParseDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;
    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    text: heap.Owned(Value),
    encoder: heap.Owned(kernel_storage.StringEncoder),
    bytes: ?[]u8 = null,
    arena: ?std.heap.ArenaAllocator = null,
    scanner: ?std.json.Scanner = null,
    frames: std.ArrayList(Frame) = .empty,
    root: ?Value = null,
    /// Set while a container or string is being materialized in bounded steps.
    building: ?Building = null,

    /// A materialization in progress. The materializers *retain* what they
    /// copy, so the collected values stay owned here and are released once the
    /// container exists — on the success path and on teardown alike.
    const Building = struct {
        target: union(enum) {
            values: list.ValueMaterializer,
            pairs: dict.Materializer,
            text: kernel_storage.TextMaterializer,
        },
        values: ?[]Value = null,
        pairs: ?[]dict.Pair = null,
    };

    pub fn advance(evaluator: *Machine, self: *ParseDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.bytes == null) {
            switch (self.encoder.borrowMut().advance(machine.kernel_poll_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidCodepoint => return evaluator.fail(
                    .domain,
                    "string contains an invalid Unicode scalar",
                ),
            }) {
                .pending => return .yielded,
                .complete => |encoded| {
                    self.bytes = encoded;
                    self.arena = .init(self.allocator);
                    self.scanner = .initCompleteInput(self.arena.?.allocator(), encoded);
                    return .yielded;
                },
            }
        }
        var budget: usize = token_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.building != null) {
                if (try self.advanceBuilding(evaluator)) |item| try self.place(evaluator, item);
                continue;
            }
            if (self.root) |root| {
                // A well-formed document holds exactly one value; the scanner
                // still has to confirm nothing follows it.
                switch (self.scanner.?.next() catch return self.failParse(evaluator)) {
                    .end_of_document => {
                        self.root = null;
                        return .{ .output = root };
                    },
                    else => return evaluator.fail(.parse, "json.parse found trailing content"),
                }
            }
            const token = self.scanner.?.nextAlloc(self.arena.?.allocator(), .alloc_if_needed) catch
                return self.failParse(evaluator);
            switch (token) {
                .object_begin => try self.frames.append(self.allocator, .{ .kind = .object }),
                .array_begin => try self.frames.append(self.allocator, .{ .kind = .array }),
                .object_end, .array_end => try self.closeFrame(evaluator.releaseDomain()),
                .null => try self.place(evaluator, .{ .symbol = try intern.intern("null") }),
                .true => try self.place(evaluator, .{ .symbol = try intern.intern("true") }),
                .false => try self.place(evaluator, .{ .symbol = try intern.intern("false") }),
                .number, .allocated_number => |text| try self.place(
                    evaluator,
                    try numberValue(evaluator, text),
                ),
                .string, .allocated_string => |text| self.beginText(text),
                .end_of_document => return evaluator.fail(.parse, "json.parse found no value"),
                // Partial tokens only occur while streaming; complete input
                // never produces them.
                else => return evaluator.fail(.parse, "json.parse could not tokenize the input"),
            }
        }
        return .yielded;
    }

    fn failParse(self: *ParseDriver, evaluator: *Machine) MachineError {
        _ = self;
        return evaluator.fail(.parse, "json.parse rejected malformed JSON");
    }

    fn beginText(self: *ParseDriver, text: []const u8) void {
        self.building = .{ .target = .{ .text = .init(self.allocator, text) } };
    }

    /// Closes the innermost container by handing its collected values to the
    /// ordinary resumable materializer, so a large array or object is built in
    /// bounded steps like every other aggregate.
    fn closeFrame(
        self: *ParseDriver,
        releases: *heap.ReleaseDomain,
    ) error{OutOfMemory}!void {
        if (self.frames.items.len == 0) return error.OutOfMemory;
        var frame = self.frames.pop().?;
        // Cleanup is explicit rather than an errdefer: both arms hand the
        // collected values to storage that outlives the list, after which the
        // list itself is spent and must not be walked again.
        switch (frame.kind) {
            .array => {
                const values = frame.values.toOwnedSlice(self.allocator) catch |err| {
                    self.releaseFrame(releases, &frame);
                    return err;
                };
                self.building = .{
                    .target = .{ .values = .init(self.allocator, values) },
                    .values = values,
                };
            },
            .object => {
                const entries = frame.values.items.len / 2;
                const pairs = self.allocator.alloc(dict.Pair, entries) catch |err| {
                    self.releaseFrame(releases, &frame);
                    return err;
                };
                for (0..entries) |index| pairs[index] = .{
                    frame.values.items[index * 2],
                    frame.values.items[index * 2 + 1],
                };
                const materializer = dict.Materializer.init(
                    self.allocator,
                    pairs,
                    true,
                ) catch |err| {
                    self.allocator.free(pairs);
                    self.releaseFrame(releases, &frame);
                    return err;
                };
                frame.values.deinit(self.allocator);
                self.building = .{
                    .target = .{ .pairs = materializer },
                    .pairs = pairs,
                };
            },
        }
    }

    fn releaseFrame(self: *ParseDriver, releases: *heap.ReleaseDomain, frame: *Frame) void {
        for (frame.values.items) |item| releases.releaseValue(item);
        frame.values.deinit(self.allocator);
    }

    fn advanceBuilding(self: *ParseDriver, evaluator: *Machine) MachineError!?Value {
        const building = &self.building.?;
        const result: ?Value = switch (building.target) {
            .values => |*materializer| switch (try materializer.advance(machine.kernel_poll_quantum)) {
                .pending => null,
                .complete => |item| item,
            },
            .pairs => |*materializer| switch (try materializer.advance(machine.kernel_poll_quantum)) {
                .pending => null,
                .duplicate_key => {
                    // RFC 8259 leaves duplicate names to the implementation;
                    // ECL dicts have unique keys, so the last one wins.
                    return evaluator.fail(.domain, "json.parse found a duplicate object name");
                },
                .complete => |item| item,
            },
            .text => |*materializer| switch (try materializer.advance(machine.kernel_poll_quantum)) {
                .pending => null,
                .complete => |item| item,
            },
        };
        const built = result orelse return null;
        const building_done = &self.building.?;
        switch (building_done.target) {
            .values => |*materializer| materializer.deinit(),
            .pairs => |*materializer| materializer.deinit(),
            .text => |*materializer| materializer.deinit(),
        }
        self.releaseCollected(evaluator.releaseDomain());
        return built;
    }

    /// Releases the values a finished or abandoned materialization borrowed.
    fn releaseCollected(self: *ParseDriver, releases: *heap.ReleaseDomain) void {
        const building = &self.building.?;
        if (building.values) |values| {
            for (values) |item| releases.releaseValue(item);
            self.allocator.free(values);
        }
        if (building.pairs) |pairs| {
            for (pairs) |pair| {
                releases.releaseValue(pair[0]);
                releases.releaseValue(pair[1]);
            }
            self.allocator.free(pairs);
        }
        self.building = null;
    }

    /// Installs one finished value as an object key, an object value, an array
    /// element, or the document root. The value is owned on entry, so a failed
    /// append releases it rather than stranding it.
    fn place(self: *ParseDriver, evaluator: *Machine, item: Value) error{OutOfMemory}!void {
        if (self.frames.items.len == 0) {
            self.root = item;
            return;
        }
        const frame = &self.frames.items[self.frames.items.len - 1];
        frame.values.append(self.allocator, item) catch |err| {
            evaluator.releaseDomain().releaseValue(item);
            return err;
        };
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
        self: *ParseDriver,
    ) bool {
        if (self.building) |*building| {
            switch (building.target) {
                .values => |*materializer| materializer.retire(releases),
                .pairs => |*materializer| materializer.retire(releases),
                .text => |*materializer| materializer.retire(releases),
            }
            self.releaseCollected(releases);
        }
        for (self.frames.items) |*frame| {
            for (frame.values.items) |item| releases.releaseValue(item);
            frame.values.deinit(self.allocator);
        }
        self.frames.deinit(self.allocator);
        if (self.root) |root| releases.releaseValue(root);
        self.root = null;
        if (self.scanner) |*scanner| scanner.deinit();
        self.scanner = null;
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.bytes = null;
        self.encoder.deinit(releases, storage_allocator);
        self.text.deinit(releases, storage_allocator);
        storage_allocator.destroy(self);
        return true;
    }
};

/// Integral in-range numbers become ints; everything else becomes a float.
fn numberValue(evaluator: *Machine, text: []const u8) MachineError!Value {
    if (std.json.isNumberFormattedLikeAnInteger(text)) {
        if (std.fmt.parseInt(i64, text, 10)) |number| {
            return .{ .int = number };
        } else |_| {}
    }
    const number = std.fmt.parseFloat(f64, text) catch
        return evaluator.fail(.parse, "json.parse could not represent a number");
    return .{ .float = number };
}

fn emit(evaluator: *Machine) MachineError!void {
    var item = try evaluator.popValue();
    defer item.deinit();
    try evaluator.startDriver(EmitDriver{
        .allocator = evaluator.allocator(),
        .item = .init(item.take()),
    });
}

/// One position in the value being rendered. Objects sit on the stack across
/// their key and value sub-renders, so nesting costs stack depth rather than
/// native recursion.
const EmitFrame = union(enum) {
    /// A value whose rendering has not started.
    value: Value,
    /// Elements of an array, `[` already written.
    array: struct { item: Value, index: u64 },
    /// Entries of an object, `{` already written.
    object: struct {
        item: Value,
        index: u64,
        part: enum { key, colon, value } = .key,
    },
    /// Characters of a string, the opening quote already written.
    text: struct { item: Value, index: u64 },
    /// Bytes of a symbol rendered as a JSON string, opening quote written.
    name: struct { id: u32, index: usize },
};

const EmitDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;
    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    item: heap.Owned(Value),
    out: std.ArrayList(u8) = .empty,
    frames: std.ArrayList(EmitFrame) = .empty,
    started: bool = false,
    materializer: ?kernel_storage.TextMaterializer = null,

    pub fn advance(evaluator: *Machine, self: *EmitDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.materializer) |*materializer| {
            return switch (try materializer.advance(machine.kernel_poll_quantum)) {
                .pending => .yielded,
                .complete => |text| output: {
                    materializer.deinit();
                    self.materializer = null;
                    break :output .{ .output = text };
                },
            };
        }
        if (!self.started) {
            self.started = true;
            try self.frames.append(self.allocator, .{ .value = self.item.borrow() });
        }
        var budget: usize = token_quantum;
        while (budget != 0) : (budget -= 1) {
            if (self.frames.items.len == 0) {
                self.materializer = .init(self.allocator, self.out.items);
                return .yielded;
            }
            try self.step(evaluator);
        }
        return .yielded;
    }

    fn step(self: *EmitDriver, evaluator: *Machine) MachineError!void {
        const frame = &self.frames.items[self.frames.items.len - 1];
        switch (frame.*) {
            .value => |item| {
                _ = self.frames.pop().?;
                try self.begin(evaluator, item);
            },
            .array => |*cursor| {
                const length: u64 = @intCast(cursor.item.list.length());
                if (cursor.index == length) {
                    _ = self.frames.pop().?;
                    try self.out.append(self.allocator, ']');
                    return;
                }
                if (cursor.index != 0) try self.out.append(self.allocator, ',');
                const element = list.atUnchecked(cursor.item, @intCast(cursor.index));
                cursor.index += 1;
                try self.frames.append(self.allocator, .{ .value = element });
            },
            .object => |*cursor| {
                const entries: u64 = @intCast(dict.keysOf(cursor.item.dict).list.length());
                switch (cursor.part) {
                    .key => {
                        if (cursor.index == entries) {
                            _ = self.frames.pop().?;
                            try self.out.append(self.allocator, '}');
                            return;
                        }
                        if (cursor.index != 0) try self.out.append(self.allocator, ',');
                        const key = dict.keyAt(cursor.item.dict, @intCast(cursor.index));
                        cursor.part = .colon;
                        try self.beginKey(evaluator, key);
                    },
                    .colon => {
                        try self.out.append(self.allocator, ':');
                        cursor.part = .value;
                        const item = dict.valueAt(cursor.item.dict, @intCast(cursor.index));
                        try self.frames.append(self.allocator, .{ .value = item });
                    },
                    .value => {
                        cursor.index += 1;
                        cursor.part = .key;
                    },
                }
            },
            .text => |*cursor| {
                const length: u64 = @intCast(cursor.item.list.length());
                if (cursor.index == length) {
                    _ = self.frames.pop().?;
                    try self.out.append(self.allocator, '"');
                    return;
                }
                const codepoint = list.atUnchecked(cursor.item, @intCast(cursor.index)).char;
                cursor.index += 1;
                try self.appendEscaped(evaluator, codepoint);
            },
            .name => |*cursor| {
                const bytes = intern.get(cursor.id);
                if (cursor.index == bytes.len) {
                    _ = self.frames.pop().?;
                    try self.out.append(self.allocator, '"');
                    return;
                }
                // Interned names are valid UTF-8, so a byte at a time is safe
                // for everything an escape does not touch.
                const byte = bytes[cursor.index];
                cursor.index += 1;
                if (byte < 0x80) try self.appendEscaped(evaluator, byte) else try self.out.append(self.allocator, byte);
            },
        }
    }

    /// Starts rendering one value, writing scalars outright and pushing a
    /// cursor for anything user-sized.
    fn begin(self: *EmitDriver, evaluator: *Machine, item: Value) MachineError!void {
        switch (item) {
            .int => |number| {
                // SAFETY: written by bufPrint before it is read.
                var buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch
                    return evaluator.fail(.domain, "json.emit cannot represent a number");
                try self.out.appendSlice(self.allocator, text);
            },
            .float => |number| {
                if (std.math.isNan(number) or std.math.isInf(number))
                    return evaluator.fail(.domain, "json.emit cannot represent an infinite or NaN number");
                var buffer: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch
                    return evaluator.fail(.domain, "json.emit cannot represent a number");
                try self.out.appendSlice(self.allocator, text);
            },
            .symbol => |id| {
                const bytes = intern.get(id);
                // The three JSON literals round-trip through symbols; every
                // other symbol has no JSON form.
                if (std.mem.eql(u8, bytes, "null") or std.mem.eql(u8, bytes, "true") or
                    std.mem.eql(u8, bytes, "false"))
                {
                    try self.out.appendSlice(self.allocator, bytes);
                    return;
                }
                return evaluator.failFmt(
                    .type,
                    "json.emit cannot represent the symbol `{s}`",
                    .{bytes},
                );
            },
            .list => {
                if (item.isString()) {
                    try self.out.append(self.allocator, '"');
                    try self.frames.append(self.allocator, .{ .text = .{ .item = item, .index = 0 } });
                    return;
                }
                try self.out.append(self.allocator, '[');
                try self.frames.append(self.allocator, .{ .array = .{ .item = item, .index = 0 } });
            },
            .dict => {
                try self.out.append(self.allocator, '{');
                try self.frames.append(self.allocator, .{ .object = .{ .item = item, .index = 0 } });
            },
            .char, .word, .task, .module, .unit_plan => return evaluator.fail(
                .type,
                "json.emit expects numbers, strings, lists, dicts, and the JSON literal symbols",
            ),
        }
    }

    /// Object names are the one place a symbol renders as a string.
    fn beginKey(self: *EmitDriver, evaluator: *Machine, key: Value) MachineError!void {
        if (key.isString()) {
            try self.out.append(self.allocator, '"');
            try self.frames.append(self.allocator, .{ .text = .{ .item = key, .index = 0 } });
            return;
        }
        if (key == .symbol) {
            try self.out.append(self.allocator, '"');
            try self.frames.append(self.allocator, .{ .name = .{ .id = key.symbol, .index = 0 } });
            return;
        }
        return evaluator.fail(.type, "json.emit requires string or symbol dictionary keys");
    }

    fn appendEscaped(self: *EmitDriver, evaluator: *Machine, codepoint: u32) MachineError!void {
        switch (codepoint) {
            '"' => try self.out.appendSlice(self.allocator, "\\\""),
            '\\' => try self.out.appendSlice(self.allocator, "\\\\"),
            '\n' => try self.out.appendSlice(self.allocator, "\\n"),
            '\r' => try self.out.appendSlice(self.allocator, "\\r"),
            '\t' => try self.out.appendSlice(self.allocator, "\\t"),
            0x08 => try self.out.appendSlice(self.allocator, "\\b"),
            0x0c => try self.out.appendSlice(self.allocator, "\\f"),
            else => {
                if (codepoint < 0x20) {
                    // SAFETY: written by bufPrint before it is read.
                    var buffer: [6]u8 = undefined;
                    const text = std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{codepoint}) catch
                        return evaluator.fail(.domain, "json.emit cannot escape a scalar");
                    try self.out.appendSlice(self.allocator, text);
                    return;
                }
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(
                    value.unicodeScalar(codepoint) orelse
                        return evaluator.fail(.domain, "json.emit found an invalid Unicode scalar"),
                    &encoded,
                ) catch return evaluator.fail(.domain, "json.emit found an invalid Unicode scalar");
                try self.out.appendSlice(self.allocator, encoded[0..length]);
            },
        }
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
        self: *EmitDriver,
    ) bool {
        if (self.materializer) |*materializer| materializer.retire(releases);
        self.materializer = null;
        self.frames.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.item.deinit(releases, storage_allocator);
        storage_allocator.destroy(self);
        return true;
    }
};
