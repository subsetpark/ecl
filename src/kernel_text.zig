//! Unicode text kernels: core `str`, and the `str.core` split, join, and format.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const support = @import("kernel_support.zig");
const storage = @import("kernel_storage.zig");
const kernel_flat = @import("kernel_flat.zig");

const Value = value.Value;
const Fiber = support.Fiber;
const MachineError = support.MachineError;

const Op = support.TextOp;

pub fn install(core: *env.BuildingEnv) error{OutOfMemory}!void {
    inline for (comptime std.meta.tags(Op)) |operation| {
        try core.installBuiltin(comptime definition(operation));
    }
}

fn definition(comptime operation: Op) env.BuiltinWord {
    return switch (operation) {
        .str => .{ .name = operation.spelling(), .primitive = bind(operation), .effect = "value -- string", .doc = "Render `value` as a string." },
    };
}

fn bind(comptime operation: Op) env.PrimitiveImpl {
    return support.headed(operation.spelling(), struct {
        fn run(fiber: *Fiber) MachineError!void {
            return switch (operation) {
                .str => strPrimitive(fiber),
            };
        }
    }.run);
}

fn strPrimitive(fiber: *Fiber) MachineError!void {
    var item = try fiber.popValue();
    defer item.deinit();
    const renderer = try printer.OwnedStringCursor.init(fiber.allocator, item.borrow());
    try fiber.startDriver(StrDriver{
        .item = .init(item.take()),
        .work = .init(.{ .rendering = renderer }),
    });
}

const StrPhase = union(enum) {
    rendering: printer.OwnedStringCursor,
    materializing: struct {
        bytes: []u8,
        cursor: storage.Utf8Materializer,
    },
    complete,

    pub fn retire(
        self: *StrPhase,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .rendering => |*renderer| renderer.deinit(),
            .materializing => |*materializing| {
                materializing.cursor.retire(releases);
                allocator.free(materializing.bytes);
            },
            .complete => {},
        }
        self.* = .complete;
    }
};

const StrDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;
    pub const inline_driver = true;
    item: heap.Owned(Value),
    work: heap.Owned(StrPhase),

    pub fn advance(fiber: *Fiber, self: *StrDriver) MachineError!machine.WorkProgress {
        const phase = self.work.borrowMut();
        return switch (phase.*) {
            .rendering => |*renderer| switch (try renderer.advance(fiber.workBudget())) {
                .pending => .stepped,
                .complete => |bytes| transitioned: {
                    renderer.deinit();
                    phase.* = .{ .materializing = .{
                        .bytes = bytes,
                        .cursor = .init(fiber.allocator, bytes),
                    } };
                    break :transitioned .stepped;
                },
            },
            .materializing => |*materializing| switch (materializing.cursor.advance(fiber.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return fiber.fail(
                    .domain,
                    "canonical rendering is not valid UTF-8",
                ),
            }) {
                .pending => .stepped,
                .complete => |result| completed: {
                    materializing.cursor.deinit();
                    fiber.allocator.free(materializing.bytes);
                    phase.* = .complete;
                    break :completed .{ .output = result };
                },
            },
            .complete => unreachable,
        };
    }
};

/// `str.split`, exported by `str.core` and re-exported by `str`.
pub fn splitPrimitive(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var separator = try fiber.popValue();
    defer separator.deinit();
    var text = try fiber.popValue();
    defer text.deinit();
    if (!text.borrow().isString() or !separator.borrow().isString()) return fiber.typeError("two strings");
    const text_len: usize = @intCast(text.borrow().list.length());
    const separator_len: usize = @intCast(separator.borrow().list.length());
    // The scan has one position per comparison it may make: each candidate
    // start costs up to one comparison per separator codepoint. An empty
    // separator makes every codepoint a part, one position each.
    const scan_length = if (separator_len == 0)
        text_len
    else if (separator_len > text_len)
        0
    else
        // No two allocatable strings overflow this.
        std.math.mul(usize, text_len - separator_len + 1, separator_len) catch
            return error.OutOfMemory;
    const text_kind = text.borrow().list.kind();
    const separator_kind = separator.borrow().list.kind();
    if (text_kind == .leaf_char1 and separator_kind == .leaf_char1 and separator_len != 0)
        return support.Kernel(NarrowSplitKernel).run(fiber, .{ &text, &separator }, {}, text_len);
    inline for (char_leaf_kinds) |candidate_text| {
        if (text_kind == candidate_text) inline for (char_leaf_kinds) |candidate_separator| {
            if (separator_kind == candidate_separator) return support.Kernel(SplitKernel(candidate_text, candidate_separator)).run(
                fiber,
                .{ &text, &separator },
                {},
                scan_length,
            );
        };
    }
    unreachable;
}

const char_leaf_kinds = [_]value.HeapKind{ .leaf_char1, .leaf_char2, .leaf_char4 };

/// `split` of a one-byte-wide string at a one-byte-wide separator: the
/// common case (`"\n"` on ASCII text), and the one where no part can be
/// narrower than the text, so no part needs profiling. Two phases: a count
/// of the separators, which sizes the result spine exactly, and a fill that
/// finds each separator again and copies the part before it straight into a
/// one-byte-wide leaf. Both searches are the standard library's vectorized
/// ones; no bounds table is kept. The scan length is the text's length; the
/// fill charges one unit per part plus one per codepoint copied.
const NarrowSplitKernel = struct {
    pub const arity = 2;
    pub const Params = void;
    pub const Output = struct {
        phase: enum { count, fill } = .count,
        text_len: usize,
        separator_len: usize,
        /// Count: the first position a search may start at, so a separator
        /// straddling a chunk boundary is counted once. Fill: where the next
        /// part starts.
        cursor: usize = 0,
        /// Count: separators seen. After the count: parts to emit.
        part_count: usize = 0,
        emitted: usize = 0,
        spine: ?heap.OwnedValueBuffer = null,

        pub fn retire(self: *Output, _: *heap.ReleaseDomain) void {
            if (self.spine) |*spine| spine.deinit();
        }
    };

    pub fn prepare(_: *Fiber, operands: [2]Value, _: void, _: usize) error{OutOfMemory}!Output {
        return .{
            .text_len = @intCast(operands[0].list.length()),
            .separator_len = @intCast(operands[1].list.length()),
        };
    }

    pub fn chunk(_: void, operands: [2]Value, output: *Output, range: kernel_flat.Chunk, fiber: *Fiber) MachineError!void {
        const text = heap.leafElements(.leaf_char1, operands[0].list);
        const separator = heap.leafElements(.leaf_char1, operands[1].list);
        switch (output.phase) {
            .count => count(output, text, separator, range),
            .fill => try fill(output, fiber, text, separator, range.len()),
        }
    }

    pub fn next(fiber: *Fiber, output: *Output) MachineError!?usize {
        switch (output.phase) {
            .count => {
                output.part_count += 1;
                output.spine = try heap.OwnedValueBuffer.init(fiber.releases, output.part_count);
                output.cursor = 0;
                output.phase = .fill;
                return output.text_len + output.part_count;
            },
            .fill => return null,
        }
    }

    pub fn finish(output: *Output) Value {
        return output.spine.?.takeList();
    }

    /// The next separator at or after `from`, or the text's end.
    fn find(text: []const u8, separator: []const u8, from: usize) usize {
        if (separator.len == 1) return std.mem.indexOfScalarPos(u8, text, from, separator[0]) orelse text.len;
        return std.mem.indexOfPos(u8, text, from, separator) orelse text.len;
    }

    /// Counts the separators whose start lies in `range`. A match may run
    /// past the range's end; the cursor then keeps the next chunk from
    /// starting inside it.
    fn count(output: *Output, text: []const u8, separator: []const u8, range: kernel_flat.Chunk) void {
        var position = @max(output.cursor, range.start);
        const visible = text[0..@min(text.len, range.end + separator.len - 1)];
        while (position < range.end) {
            const hit = find(visible, separator, position);
            if (hit >= range.end) break;
            output.part_count += 1;
            position = hit + separator.len;
        }
        output.cursor = @max(position, range.end);
    }

    /// Emits whole parts while `units` last: one unit to begin a part, one
    /// per codepoint copied. The part that exhausts the budget is still
    /// emitted whole, so a part is never left half built across steps.
    fn fill(output: *Output, fiber: *Fiber, text: []const u8, separator: []const u8, units: usize) error{OutOfMemory}!void {
        var remaining = units;
        while (remaining != 0 and output.emitted != output.part_count) {
            const end = find(text, separator, output.cursor);
            const part = text[output.cursor..end];
            var builder = try heap.ListBuilder(.leaf_char1).init(fiber.allocator, part.len, part.len);
            @memcpy(builder.items()[0..part.len], part);
            output.spine.?.appendOwned(.{ .list = builder.finish() });
            output.emitted += 1;
            output.cursor = end + separator.len;
            remaining -|= 1 + part.len;
        }
    }
};

/// Splits a string at every occurrence of a separator, in three phases: the
/// scan records each part's bounds, the profile finds each part's widest
/// codepoint, and the fill writes each part at exactly that width into the
/// result spine. Operand 0 is the text, operand 1 the separator.
fn SplitKernel(comptime text_kind: value.HeapKind, comptime separator_kind: value.HeapKind) type {
    const Part = struct { start: usize, end: usize, max_codepoint: u32 = 0 };
    return struct {
        pub const arity = 2;
        pub const Params = void;
        pub const Output = struct {
            allocator: std.mem.Allocator,
            phase: enum { scan, profile, fill } = .scan,
            text_len: usize,
            separator_len: usize,
            /// Room for every part's bounds, at most one more than the
            /// text's length; the first `part_count` are recorded.
            parts: []Part,
            part_count: usize = 0,
            /// Where the part being scanned starts, and the first candidate
            /// start not inside a separator already matched.
            part_start: usize = 0,
            next_candidate: usize = 0,
            /// The part a profile or fill is in, and how far into it.
            part: usize = 0,
            offset: usize = 0,
            writer: ?kernel_flat.CodepointWriter = null,
            spine: ?heap.OwnedValueBuffer = null,

            fn record(self: *Output, part: Part) void {
                self.parts[self.part_count] = part;
                self.part_count += 1;
            }

            pub fn retire(self: *Output, releases: *heap.ReleaseDomain) void {
                self.allocator.free(self.parts);
                if (self.writer) |*writer| writer.retire(releases);
                if (self.spine) |*spine| spine.deinit();
            }
        };

        pub fn prepare(fiber: *Fiber, operands: [2]Value, _: void, _: usize) error{OutOfMemory}!Output {
            const text_len: usize = @intCast(operands[0].list.length());
            return .{
                .allocator = fiber.allocator,
                .text_len = text_len,
                .separator_len = @intCast(operands[1].list.length()),
                .parts = try fiber.allocator.alloc(Part, text_len + 1),
            };
        }

        pub fn chunk(_: void, operands: [2]Value, output: *Output, range: kernel_flat.Chunk, fiber: *Fiber) MachineError!void {
            const text = heap.leafElements(text_kind, operands[0].list);
            switch (output.phase) {
                .scan => scan(output, text, heap.leafElements(separator_kind, operands[1].list), range),
                .profile => profile(output, text, range.len()),
                .fill => try fill(output, fiber, text, range.len()),
            }
        }

        pub fn next(fiber: *Fiber, output: *Output) MachineError!?usize {
            switch (output.phase) {
                .scan => {
                    if (output.separator_len != 0) output.record(.{
                        .start = output.part_start,
                        .end = output.text_len,
                    });
                    output.phase = .profile;
                    return partCodepoints(output);
                },
                .profile => {
                    output.spine = try heap.OwnedValueBuffer.init(fiber.releases, output.part_count);
                    output.part = 0;
                    output.offset = 0;
                    output.phase = .fill;
                    // A part also costs one position to begin, so an empty
                    // part is not free.
                    return partCodepoints(output) + output.part_count;
                },
                .fill => return null,
            }
        }

        pub fn finish(output: *Output) Value {
            output.allocator.free(output.parts);
            return output.spine.?.takeList();
        }

        /// What the parts hold: the text less every matched separator.
        fn partCodepoints(output: *const Output) usize {
            if (output.separator_len == 0) return output.text_len;
            return output.text_len - (output.part_count - 1) * output.separator_len;
        }

        fn matchesAt(text: anytype, separator: anytype, start: usize) bool {
            for (separator, text[start..][0..separator.len]) |expected, actual| {
                if (@as(u32, expected) != @as(u32, actual)) return false;
            }
            return true;
        }

        /// Tries each candidate start whose first comparison lies in `range`.
        fn scan(output: *Output, text: anytype, separator: anytype, range: kernel_flat.Chunk) void {
            if (output.separator_len == 0) {
                for (range.start..range.end) |index| output.record(.{ .start = index, .end = index + 1 });
                return;
            }
            const width = output.separator_len;
            var candidate = range.start / width + @intFromBool(range.start % width != 0);
            while (candidate * width < range.end) : (candidate += 1) {
                if (candidate < output.next_candidate or !matchesAt(text, separator, candidate)) continue;
                output.record(.{ .start = output.part_start, .end = candidate });
                output.part_start = candidate + width;
                output.next_candidate = candidate + width;
            }
        }

        /// Finds the widest codepoint of the next `units` codepoints of the parts.
        fn profile(output: *Output, text: anytype, units: usize) void {
            var remaining = units;
            while (remaining != 0) {
                const part = &output.parts[output.part];
                const length = part.end - part.start;
                if (output.offset == length) {
                    output.part += 1;
                    output.offset = 0;
                    continue;
                }
                const take = @min(length - output.offset, remaining);
                for (text[part.start + output.offset ..][0..take]) |codepoint| part.max_codepoint = @max(part.max_codepoint, codepoint);
                output.offset += take;
                remaining -= take;
            }
        }

        /// Spends `units` on the fill: one to begin each part, then one per
        /// codepoint written; a part is appended to the spine once full.
        fn fill(output: *Output, fiber: *Fiber, text: anytype, units: usize) error{OutOfMemory}!void {
            var remaining = units;
            while (true) {
                if (output.writer) |*writer| {
                    const part = output.parts[output.part];
                    const length = part.end - part.start;
                    if (output.offset == length) {
                        output.spine.?.appendOwned(writer.finish());
                        output.writer = null;
                        output.part += 1;
                        output.offset = 0;
                        continue;
                    }
                    if (remaining == 0) return;
                    const take = @min(kernel_flat.block_size, length - output.offset, remaining);
                    var block: [kernel_flat.block_size]u32 = undefined;
                    for (text[part.start + output.offset ..][0..take], block[0..take]) |codepoint, *out| out.* = codepoint;
                    writer.writeCodepoints(output.offset, block[0..take]);
                    output.offset += take;
                    remaining -= take;
                    continue;
                }
                if (remaining == 0 or output.part == output.part_count) return;
                const part = output.parts[output.part];
                output.writer = try kernel_flat.CodepointWriter.init(fiber.allocator, part.end - part.start, part.max_codepoint);
                remaining -= 1;
            }
        }
    };
}

const AnyCharReader = union(enum) {
    char1: heap.LeafReader(.leaf_char1),
    char2: heap.LeafReader(.leaf_char2),
    char4: heap.LeafReader(.leaf_char4),

    pub const owned_disposal: heap.OwnedDisposal = .retire;

    fn acquire(string: Value) AnyCharReader {
        return switch (string.list.kind()) {
            .leaf_char1 => .{ .char1 = .acquire(string.list) },
            .leaf_char2 => .{ .char2 = .acquire(string.list) },
            .leaf_char4 => .{ .char4 = .acquire(string.list) },
            else => unreachable,
        };
    }

    fn len(self: *const AnyCharReader) usize {
        return switch (self.*) {
            inline else => |*reader| reader.len(),
        };
    }

    /// The representation switch happens once per bounded range, outside the
    /// copy loop; every loop body reads one monomorphic typed slice.
    fn copyCodepoints(self: *const AnyCharReader, start: usize, destination: []u32) void {
        switch (self.*) {
            inline else => |*reader| for (reader.slice()[start..][0..destination.len], destination) |codepoint, *out| {
                out.* = codepoint;
            },
        }
    }

    pub fn retire(self: *AnyCharReader, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            inline else => |*reader| reader.release(releases),
        }
    }
};

/// `str.join`, exported by `str.core` and re-exported by `str`.
pub fn joinPrimitive(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var separator = try fiber.popValue();
    defer separator.deinit();
    var parts = try fiber.popValue();
    defer parts.deinit();
    if (parts.borrow() != .list or !separator.borrow().isString()) {
        return fiber.typeError("a list of strings and a string separator");
    }
    try fiber.startDriver(JoinDriver{
        .parts = .init(parts.take()),
        .separator = .init(separator.take()),
    });
}

const JoinDriver = struct {
    /// One string built from a list, then it publishes.
    pub const inline_driver = true;
    pub const ownership: heap.DriverOwnership = .fields;
    parts: heap.Owned(Value),
    separator: heap.Owned(Value),
    phase: enum { count, fill } = .count,
    part_index: usize = 0,
    total: usize = 0,
    max_codepoint: u32 = 0,
    separator_profiled: bool = false,
    writer: ?heap.Owned(kernel_flat.CodepointWriter) = null,
    output_index: usize = 0,
    source_index: usize = 0,
    separator_mode: bool = false,
    source: ?heap.Owned(AnyCharReader) = null,

    pub fn advance(fiber: *Fiber, self: *JoinDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        var block: [kernel_flat.block_size]u32 = undefined;
        while (!work.exhausted()) switch (self.phase) {
            .count => {
                const count: usize = @intCast(self.parts.borrow().list.length());
                if (self.part_index == count) {
                    if (!self.separator_profiled and count > 1) {
                        if (self.source == null) self.source = .init(AnyCharReader.acquire(self.separator.borrow()));
                        const source_count = self.source.?.borrow().len();
                        const copied = work.take(@min(kernel_flat.block_size, source_count - self.source_index));
                        self.source.?.borrow().copyCodepoints(self.source_index, block[0..copied]);
                        for (block[0..copied]) |codepoint| self.max_codepoint = @max(self.max_codepoint, codepoint);
                        self.source_index += copied;
                        if (self.source_index != source_count) return .stepped;
                        self.source.?.deinit(fiber.releases, fiber.allocator);
                        self.source = null;
                        self.source_index = 0;
                        self.separator_profiled = true;
                        if (!work.spend()) return .stepped;
                        continue;
                    }
                    self.separator_profiled = true;
                    self.writer = .init(try kernel_flat.CodepointWriter.init(
                        fiber.allocator,
                        self.total,
                        self.max_codepoint,
                    ));
                    self.part_index = 0;
                    self.phase = .fill;
                    continue;
                }
                if (self.source == null) {
                    const part = list.atUnchecked(self.parts.borrow(), self.part_index);
                    if (!part.isString()) return fiber.failAtIndex(
                        .type,
                        "join expected a list of strings",
                        self.part_index,
                    );
                    self.total = std.math.add(usize, self.total, @intCast(part.list.length())) catch
                        return fiber.fail(.overflow, "joined string is too large");
                    if (self.part_index + 1 < count) self.total = std.math.add(
                        usize,
                        self.total,
                        @intCast(self.separator.borrow().list.length()),
                    ) catch return fiber.fail(.overflow, "joined string is too large");
                    self.source = .init(AnyCharReader.acquire(part));
                }
                const source_count = self.source.?.borrow().len();
                const copied = work.take(@min(kernel_flat.block_size, source_count - self.source_index));
                self.source.?.borrow().copyCodepoints(self.source_index, block[0..copied]);
                for (block[0..copied]) |codepoint| self.max_codepoint = @max(self.max_codepoint, codepoint);
                self.source_index += copied;
                if (self.source_index != source_count) return .stepped;
                self.source.?.deinit(fiber.releases, fiber.allocator);
                self.source = null;
                self.source_index = 0;
                self.part_index += 1;
                if (!work.spend()) return .stepped;
            },
            .fill => {
                const count: usize = @intCast(self.parts.borrow().list.length());
                if (self.part_index == count) {
                    std.debug.assert(self.output_index == self.total);
                    return .{ .output = self.writer.?.borrowMut().finish() };
                }
                if (self.source == null) {
                    const source = if (self.separator_mode)
                        self.separator.borrow()
                    else
                        list.atUnchecked(self.parts.borrow(), self.part_index);
                    self.source = .init(AnyCharReader.acquire(source));
                }
                const source_count = self.source.?.borrow().len();
                if (self.source_index == source_count) {
                    self.source.?.deinit(fiber.releases, fiber.allocator);
                    self.source = null;
                    self.source_index = 0;
                    if (self.separator_mode or self.part_index + 1 == count) {
                        self.separator_mode = false;
                        self.part_index += 1;
                    } else self.separator_mode = true;
                    _ = work.spend();
                    continue;
                }
                const copied = work.take(@min(kernel_flat.block_size, source_count - self.source_index));
                self.source.?.borrow().copyCodepoints(
                    self.source_index,
                    block[0..copied],
                );
                self.writer.?.borrowMut().writeCodepoints(self.output_index, block[0..copied]);
                self.output_index += copied;
                self.source_index += copied;
            },
        };
        return .stepped;
    }
};

/// `str.format`, exported by `str.core` and re-exported by `str`.
pub fn formatPrimitive(fiber: *Fiber) MachineError!void {
    try fiber.require(2);
    var template = try fiber.popValue();
    defer template.deinit();
    var values = try fiber.popValue();
    defer values.deinit();
    if (values.borrow() != .list or !template.borrow().isString()) {
        return fiber.typeError("a value list and a template string");
    }
    const value_count: usize = @intCast(values.borrow().list.length());
    const replacements = try fiber.allocator.alloc(RenderedReplacement, value_count);
    var replacements_owner: ?[]RenderedReplacement = replacements;
    errdefer if (replacements_owner) |owned| fiber.allocator.free(owned);
    const replacement_values = try heap.OwnedValueBuffer.init(fiber.releases, value_count);
    replacements_owner = null;
    try fiber.startDriver(FormatDriver{
        .values = .init(values.take()),
        .template = .init(template.take()),
        .replacements = .init(replacements),
        .replacement_values = .init(replacement_values),
        .state = .init(.{ .scan = .{} }),
    });
}

const RenderedReplacement = struct { text: Value };

const FormatDriver = struct {
    /// One rendering, then it publishes.
    pub const inline_driver = true;
    values: heap.Owned(Value),
    template: heap.Owned(Value),
    replacements: heap.Owned([]RenderedReplacement),
    replacement_values: heap.Owned(heap.OwnedValueBuffer),
    state: heap.Owned(State),
    const Scan = struct {
        cursor: usize = 0,
        replacement_index: usize = 0,
        output_count: usize = 0,
    };
    const FillMode = union(enum) {
        template,
        replacement: usize,
    };
    const Fill = struct {
        output: heap.Owned([]u32),
        cursor: usize = 0,
        replacement_index: usize = 0,
        output_index: usize = 0,
        mode: FillMode = .template,
    };
    const State = union(enum) {
        scan: Scan,
        render: struct {
            scan: Scan,
            renderer: heap.Owned(printer.OwnedStringCursor),
        },
        materialize_replacement: struct {
            scan: Scan,
            rendered: heap.Owned([]u8),
            materializer: heap.Owned(storage.Utf8Materializer),
        },
        fill: Fill,
        materialize: struct {
            output: heap.Owned([]u32),
            materializer: heap.Owned(list.CodepointMaterializer),
        },
        complete: heap.Owned([]u32),

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .scan => {},
                .render => |*render| render.renderer.deinit(releases, allocator),
                .materialize_replacement => |*materialize| {
                    materialize.materializer.deinit(releases, allocator);
                    materialize.rendered.deinit(releases, allocator);
                },
                .fill => |*fill| fill.output.deinit(releases, allocator),
                .materialize => |*materialize| {
                    materialize.materializer.deinit(releases, allocator);
                    materialize.output.deinit(releases, allocator);
                },
                .complete => |*output| output.deinit(releases, allocator),
            }
        }
    };
    fn templatePair(self: *const FormatDriver, cursor: usize) struct { codepoint: u32, next: ?u32 } {
        const count: usize = @intCast(self.template.borrow().list.length());
        return .{
            .codepoint = list.atUnchecked(self.template.borrow(), cursor).char,
            .next = if (cursor + 1 < count)
                list.atUnchecked(self.template.borrow(), cursor + 1).char
            else
                null,
        };
    }

    pub fn advance(fiber: *Fiber, self: *FormatDriver) MachineError!machine.WorkProgress {
        const work = fiber.workBudget();
        while (!work.exhausted()) switch (self.state.borrowMut().*) {
            .scan => |*scan| {
                const count: usize = @intCast(self.template.borrow().list.length());
                if (scan.cursor == count) {
                    if (scan.replacement_index != self.replacements.borrow().len) {
                        return fiber.fail(.contract, "format has more values than placeholders");
                    }
                    const output = try fiber.allocator.alloc(u32, scan.output_count);
                    self.state.borrowMut().* = .{ .fill = .{ .output = .init(output) } };
                    continue;
                }
                const pair = self.templatePair(scan.cursor);
                if ((pair.codepoint == '{' and pair.next == '{') or
                    (pair.codepoint == '}' and pair.next == '}'))
                {
                    try addFormatCount(fiber, &scan.output_count, 1);
                    scan.cursor += 2;
                } else if (pair.codepoint == '{' and pair.next == '}') {
                    if (scan.replacement_index == self.replacements.borrow().len) {
                        return fiber.fail(.contract, "format has more placeholders than values");
                    }
                    scan.cursor += 2;
                    const replacement = list.atUnchecked(
                        self.values.borrow(),
                        scan.replacement_index,
                    );
                    if (replacement.isString()) {
                        self.replacements.borrow()[scan.replacement_index] = .{ .text = replacement };
                        try addFormatCount(
                            fiber,
                            &scan.output_count,
                            @intCast(replacement.list.length()),
                        );
                        scan.replacement_index += 1;
                    } else {
                        const renderer = try printer.OwnedStringCursor.init(
                            fiber.allocator,
                            replacement,
                        );
                        self.state.borrowMut().* = .{ .render = .{
                            .scan = scan.*,
                            .renderer = .init(renderer),
                        } };
                    }
                } else if (pair.codepoint == '{' or pair.codepoint == '}') {
                    return fiber.fail(.domain, "format contains an unmatched brace");
                } else {
                    try addFormatCount(fiber, &scan.output_count, 1);
                    scan.cursor += 1;
                }
                _ = work.spend();
            },
            .render => |*render| switch (try render.renderer.borrowMut().advance(work)) {
                .pending => return .stepped,
                .complete => |bytes| {
                    const scan = render.scan;
                    render.renderer.deinit(fiber.releases, fiber.allocator);
                    self.state.borrowMut().* = .{ .materialize_replacement = .{
                        .scan = scan,
                        .rendered = .init(bytes),
                        .materializer = .init(.init(fiber.allocator, bytes)),
                    } };
                    return .stepped;
                },
            },
            .materialize_replacement => |*materialize| switch (materialize.materializer.borrowMut().advance(work) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return fiber.fail(.domain, "rendered value is not valid UTF-8"),
            }) {
                .pending => return .stepped,
                .complete => |text| {
                    var scan = materialize.scan;
                    materialize.materializer.deinit(
                        fiber.releases,
                        fiber.allocator,
                    );
                    materialize.rendered.deinit(fiber.releases, fiber.allocator);
                    self.replacements.borrow()[scan.replacement_index] = .{ .text = text };
                    self.replacement_values.borrowMut().appendOwned(text);
                    try addFormatCount(fiber, &scan.output_count, @intCast(text.list.length()));
                    scan.replacement_index += 1;
                    self.state.borrowMut().* = .{ .scan = scan };
                    return .stepped;
                },
            },
            .fill => |*fill| {
                switch (fill.mode) {
                    .replacement => |replacement_cursor| {
                        const replacement = self.replacements.borrow()[fill.replacement_index];
                        if (replacement_cursor == replacement.text.list.length()) {
                            fill.mode = .template;
                            fill.replacement_index += 1;
                            continue;
                        }
                        fill.output.borrow()[fill.output_index] = list.atUnchecked(
                            replacement.text,
                            replacement_cursor,
                        ).char;
                        fill.mode = .{ .replacement = replacement_cursor + 1 };
                        fill.output_index += 1;
                        _ = work.spend();
                        continue;
                    },
                    .template => {},
                }
                const count: usize = @intCast(self.template.borrow().list.length());
                if (fill.cursor == count) {
                    std.debug.assert(fill.output_index == fill.output.borrow().len);
                    const materializer = list.CodepointMaterializer.init(
                        fiber.allocator,
                        fill.output.borrow(),
                    );
                    self.state.borrowMut().* = .{ .materialize = .{
                        .output = .init(fill.output.take()),
                        .materializer = .init(materializer),
                    } };
                    continue;
                }
                const pair = self.templatePair(fill.cursor);
                if ((pair.codepoint == '{' and pair.next == '{') or
                    (pair.codepoint == '}' and pair.next == '}'))
                {
                    fill.output.borrow()[fill.output_index] = pair.codepoint;
                    fill.output_index += 1;
                    fill.cursor += 2;
                } else if (pair.codepoint == '{' and pair.next == '}') {
                    fill.mode = .{ .replacement = 0 };
                    fill.cursor += 2;
                } else {
                    fill.output.borrow()[fill.output_index] = pair.codepoint;
                    fill.output_index += 1;
                    fill.cursor += 1;
                }
                _ = work.spend();
            },
            .materialize => |*materialize| return switch (try materialize.materializer.borrowMut().advance(work)) {
                .pending => .stepped,
                .complete => |result| completed: {
                    materialize.materializer.deinit(fiber.releases, fiber.allocator);
                    self.state.borrowMut().* = .{ .complete = .init(materialize.output.take()) };
                    break :completed .{ .output = result };
                },
            },
            .complete => unreachable,
        };
        return .stepped;
    }

    pub const ownership: heap.DriverOwnership = .fields;
};

fn addFormatCount(
    fiber: *Fiber,
    count: *usize,
    amount: usize,
) MachineError!void {
    count.* = std.math.add(usize, count.*, amount) catch
        return fiber.fail(.overflow, "formatted string is too large");
}
