const std = @import("std");
const formatter = @import("../formatter.zig");
const print = @import("../print.zig");
const heap = @import("../heap.zig");
const console = @import("../console.zig");
const line_editor = @import("../line_editor.zig");
const reader = @import("../reader.zig");
const session = @import("../session.zig");
const native_abi = @import("native-abi");
const native_descriptor = @import("../native_descriptor.zig");
const intern = @import("../intern.zig");
const native_runtime = @import("native_runtime_options");

const max_source_bytes = 4096;
const max_edit_steps = 128;
const max_session_steps = 24;

fn fuzzMovedRenderCursor(_: void, smith: *std.testing.Smith) !void {
    const number = smith.value(i64);
    var cursor = try print.RenderCursor.init(std.testing.allocator, .{ .int = number });
    var moved = cursor;
    // SAFETY: `moved` owns the cursor's action stack now; the copied-from
    // local is never observed or deinitialized again.
    cursor = undefined;
    defer moved.deinit();

    var actual_storage: [64]u8 = undefined;
    var actual = std.Io.Writer.fixed(&actual_storage);
    while (true) switch (try moved.advance(&actual, 1)) {
        .pending => {},
        .complete => break,
    };

    var expected_storage: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_storage, "{d}", .{number});
    try std.testing.expectEqualStrings(expected, actual.buffered());
}

test "fuzz: moved render cursor preserves its inline first action" {
    try std.testing.fuzz({}, fuzzMovedRenderCursor, .{ .corpus = &.{
        "",
        "zero",
        "negative",
        "max-int",
    } });
}

fn fuzzReaderInput(_: void, smith: *std.testing.Smith) !void {
    var storage: [max_source_bytes]u8 = undefined;
    const source = storage[0..smith.slice(&storage)];
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    var diag: reader.Diag = .{};
    const result = reader.read(host.cleanup(), "fuzz-reader.ecl", source, &diag) catch |err| switch (err) {
        error.Parse => return,
        error.OutOfMemory => return err,
    };
    switch (result) {
        .incomplete => {},
        .complete => |complete| {
            var parsed = complete;
            parsed.deinit();
        },
    }
}

test "fuzz: reader accepts arbitrary bounded input" {
    try std.testing.fuzz({}, fuzzReaderInput, .{ .corpus = &.{
        "",
        "\xff",
        "(1 2)",
        "\"unterminated",
        "[] (1 'public set 2 'private setp) 'm @defm",
    } });
}

fn fuzzFormatterRoundTrip(_: void, smith: *std.testing.Smith) !void {
    var storage: [max_source_bytes]u8 = undefined;
    const source = storage[0..smith.slice(&storage)];
    const formatted = formatter.format(std.testing.allocator, source) catch |err| switch (err) {
        error.InvalidUtf8, error.InvalidSource => return,
        error.OutOfMemory => return err,
    };
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.unicode.utf8ValidateSlice(formatted));
    const repeated = try formatter.format(std.testing.allocator, formatted);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings(formatted, repeated);
}

test "fuzz: formatter is idempotent for every accepted source" {
    try std.testing.fuzz({}, fuzzFormatterRoundTrip, .{
        .corpus = &.{
            "",
            "1 2 +",
            "# comment\n(foo [bar] {baz})",
            "\"raw\n  string\" \\space",
            "(value -- value : \"documentation\") (dup) 'same def",
            // The `### module` header path: bare, seeded, and with a stale header
            // the formatter must rewrite from the registration itself.
            "[] ((1) 'x def) 'stats @defm",
            "[[0]] ((1 +) 'tick def) 'counter @defm",
            "### module wrong\n# attached\n[] ((1) 'x def) 'stats @defm",
            "(a -- ...) (dup) 'row def",
        },
    });
}

fn fuzzInvoke(
    _: *const native_abi.HostTable,
    _: *anyopaque,
    _: u32,
    output: *native_abi.InvokeResult,
) callconv(.c) void {
    output.* = .{ .tag = .fail };
}

fn isSizeField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "size") or std.mem.endsWith(u8, name, "_size");
}

/// Keep malformed-record coverage closed over the ABI record definitions:
/// every present and future integer size field is discovered from type info.
fn varyWireSizes(smith: *std.testing.Smith, record: anytype) void {
    const Pointer = @TypeOf(record);
    const T = @typeInfo(Pointer).pointer.child;
    inline for (@typeInfo(T).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .int => {
            if (isSizeField(field.name) and smith.value(bool))
                @field(record, field.name) = smith.value(field.type);
        },
        .@"struct" => varyWireSizes(smith, &@field(record, field.name)),
        else => {},
    };
}

fn fuzzNativeDescriptor(_: void, smith: *std.testing.Smith) !void {
    var name_storage = [_]u8{ 'f', 'u', 'z', 'z', 'n', 'a', 't', 'i', 'v', 'e' };
    const name_len = 1 + smith.index(name_storage.len);
    const module_name = name_storage[0..name_len];
    const module_doc = "Fuzz-owned descriptor documentation.";
    const word_name = "word";
    const word_doc = "Fuzz-owned word documentation.";
    const input_name = "input";
    const output_name = "output";
    var inputs = [_]native_abi.EffectSlot{.{
        .name_ptr = input_name.ptr,
        .name_len = input_name.len,
    }};
    var outputs = [_]native_abi.EffectSlot{.{
        .name_ptr = output_name.ptr,
        .name_len = output_name.len,
    }};
    var definitions = [_]native_abi.Definition{.{
        .callback_index = smith.value(u2),
        .name_ptr = word_name.ptr,
        .name_len = word_name.len,
        .doc_ptr = word_doc.ptr,
        .doc_len = word_doc.len,
        .input_count = inputs.len,
        .inputs_ptr = &inputs,
        .output_count = outputs.len,
        .outputs_ptr = &outputs,
    }};
    var requirements = [_]native_abi.CapabilityRequirement{.{
        .id = smith.value(u4),
    }};
    varyWireSizes(smith, &definitions[0]);
    varyWireSizes(smith, &inputs[0]);
    varyWireSizes(smith, &outputs[0]);
    varyWireSizes(smith, &requirements[0]);
    var raw = native_abi.Descriptor{
        .abi_version = if (smith.value(bool)) native_abi.abi_version else smith.value(u3),
        .module_name_ptr = module_name.ptr,
        .module_name_len = module_name.len,
        .module_doc_ptr = module_doc.ptr,
        .module_doc_len = module_doc.len,
        .definition_count = if (smith.value(bool)) definitions.len else 0,
        .definitions_ptr = &definitions,
        .capability_count = if (smith.value(bool)) requirements.len else 0,
        .capabilities_ptr = &requirements,
        .callback_count = smith.value(u3),
        .invoke = fuzzInvoke,
    };
    varyWireSizes(smith, &raw);

    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = intern.internModuleName(module_name) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidName => return,
    };
    var cursor = native_descriptor.ValidateCursor.init(host.cleanup(), requested, &raw);
    defer cursor.deinit();
    while (true) switch (cursor.advance(1 + smith.index(32)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    }) {
        .pending => {},
        .complete => |validated| {
            validated.deinit();
            return;
        },
    };
}

test "fuzz: native descriptor metadata never escapes validation" {
    try std.testing.fuzz({}, fuzzNativeDescriptor, .{ .corpus = &.{
        "",
        "\x01\x01\x01\x01\x01\x01\x01\x01",
        "descriptor metadata",
    } });
}

const over_limit_edit: [line_editor.max_line_bytes + 1]u8 = @splat('x');
/// Byte length of the scalar starting at `index`, or one byte when the
/// sequence there is malformed or truncated.
fn modelScalarAt(bytes: []const u8, index: usize) usize {
    if (index == bytes.len) return 0;
    const declared = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return 1;
    return if (modelDecodable(bytes, index, declared)) declared else 1;
}

/// Byte length of the scalar ending at `index`, found by trying every length
/// that could end there. At most one can decode, so the two directions agree.
fn modelScalarBefore(bytes: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var length: usize = 1;
    while (length <= 4 and length <= index) : (length += 1) {
        if (modelDecodable(bytes, index - length, length)) return length;
    }
    return 1;
}

fn modelDecodable(bytes: []const u8, index: usize, length: usize) bool {
    const declared = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return false;
    if (declared != length or bytes.len - index < length) return false;
    _ = std.unicode.utf8Decode(bytes[index..][0..length]) catch return false;
    return true;
}

/// The position a cursor must occupy after landing at `position`: never
/// inside a scalar, because a splice can form one across either seam.
fn modelAligned(bytes: []const u8, position: usize) usize {
    var back: usize = 1;
    while (back != 4 and back <= position) : (back += 1) {
        const length = modelScalarAt(bytes, position - back);
        if (modelDecodable(bytes, position - back, length) and length > back)
            return position - back + length;
    }
    return position;
}

const EditModel = struct {
    bytes: std.ArrayList(u8) = .empty,
    cursor: usize = 0,

    fn deinit(self: *EditModel) void {
        self.bytes.deinit(std.testing.allocator);
    }

    fn previous(self: *const EditModel, index: usize) usize {
        return index - modelScalarBefore(self.bytes.items, index);
    }

    fn next(self: *const EditModel, index: usize) usize {
        return index + modelScalarAt(self.bytes.items, index);
    }

    fn remove(self: *EditModel, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.bytes.items[start..], self.bytes.items[end..]);
        self.bytes.shrinkRetainingCapacity(self.bytes.items.len - (end - start));
        self.cursor = modelAligned(self.bytes.items, start);
    }

    fn insert(self: *EditModel, source: []const u8) !void {
        const start = self.cursor;
        try self.bytes.insertSlice(std.testing.allocator, start, source);
        self.cursor = modelAligned(self.bytes.items, start + source.len);
    }

    fn set(self: *EditModel, source: []const u8) !void {
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(std.testing.allocator, source);
        self.cursor = modelAligned(self.bytes.items, source.len);
    }

    fn moveLeft(self: *EditModel) void {
        self.cursor = self.previous(self.cursor);
    }

    fn moveRight(self: *EditModel) void {
        self.cursor = self.next(self.cursor);
    }

    fn backspace(self: *EditModel) void {
        if (self.cursor == 0) return;
        self.remove(self.previous(self.cursor), self.cursor);
    }

    fn delete(self: *EditModel) void {
        if (self.cursor == self.bytes.items.len) return;
        self.remove(self.cursor, self.next(self.cursor));
    }

    fn deleteWord(self: *EditModel) void {
        var start = self.cursor;
        while (start != 0) {
            const previous_index = self.previous(start);
            if (!std.ascii.isWhitespace(self.bytes.items[previous_index])) break;
            start = previous_index;
        }
        while (start != 0) {
            const previous_index = self.previous(start);
            if (std.ascii.isWhitespace(self.bytes.items[previous_index])) break;
            start = previous_index;
        }
        self.remove(start, self.cursor);
    }

    fn transpose(self: *EditModel) void {
        if (self.bytes.items.len < 2 or self.cursor == 0) return;
        const right_start = if (self.cursor == self.bytes.items.len)
            self.previous(self.cursor)
        else
            self.cursor;
        if (right_start == 0) return;
        const left_start = self.previous(right_start);
        const right_end = self.next(right_start);
        var temporary: [8]u8 = undefined;
        const left = self.bytes.items[left_start..right_start];
        const right = self.bytes.items[right_start..right_end];
        @memcpy(temporary[0..left.len], left);
        @memcpy(temporary[left.len..][0..right.len], right);
        @memcpy(self.bytes.items[left_start..][0..right.len], temporary[left.len..][0..right.len]);
        @memcpy(self.bytes.items[left_start + right.len ..][0..left.len], temporary[0..left.len]);
        self.cursor = modelAligned(self.bytes.items, right_end);
    }

    fn take(self: *EditModel) void {
        self.bytes.clearRetainingCapacity();
        self.cursor = 0;
    }
};

fn expectEditInvariant(buffer: line_editor.EditBuffer, model: *const EditModel) !void {
    const actual = buffer.bytes();
    const cursor = buffer.cursorIndex();
    try std.testing.expectEqualSlices(u8, model.bytes.items, actual);
    try std.testing.expectEqual(model.cursor, cursor);
    try std.testing.expect(cursor <= actual.len);
    try std.testing.expect(actual.len <= line_editor.max_line_bytes);
    if (std.unicode.utf8ValidateSlice(actual)) {
        try std.testing.expect(std.unicode.utf8ValidateSlice(actual[0..cursor]));
        try std.testing.expect(std.unicode.utf8ValidateSlice(actual[cursor..]));
    }
    // Independent of well-formedness elsewhere: a cursor never sits inside a
    // scalar, because every mutation re-derives it from the resulting bytes.
    try std.testing.expectEqual(cursor, modelAligned(actual, cursor));
}

/// Whether the run of `length` bytes at `index` is emitted verbatim by a
/// terminal write. Anything else is emitted as one escape per byte.
fn modelPrintable(bytes: []const u8, index: usize, length: usize) bool {
    if (!modelDecodable(bytes, index, length)) return false;
    const codepoint = std.unicode.utf8Decode(bytes[index..][0..length]) catch return false;
    return codepoint >= 0x20 and (codepoint < 0x7f or codepoint > 0x9f);
}

fn modelDisplay(out: *std.ArrayList(u8), bytes: []const u8) !void {
    var index: usize = 0;
    while (index != bytes.len) {
        const length = modelScalarAt(bytes, index);
        if (modelPrintable(bytes, index, length)) {
            try out.appendSlice(std.testing.allocator, bytes[index..][0..length]);
        } else {
            for (bytes[index..][0..length]) |byte|
                try out.print(std.testing.allocator, "\\x{x:0>2}", .{byte});
        }
        index += length;
    }
}

/// The window the console must select, derived independently. Both walks
/// start at the cursor and are bounded by the row budget and by one scalar
/// per cell.
fn modelWindow(
    columns: u16,
    prompt: console.Prompt,
    view: console.DisplayView,
) console.DisplayView {
    const reserved = prompt.text().len + 1;
    if (columns <= reserved) return .{ .before = "", .after = "" };
    const available = columns - reserved;

    var start = view.before.len;
    var budget: usize = 0;
    var scalars: usize = 0;
    while (start != 0 and scalars != available) : (scalars += 1) {
        const length = modelScalarBefore(view.before, start);
        const cost = modelBoundedCells(view.before, start - length, length);
        if (budget + cost > available) break;
        budget += cost;
        start -= length;
    }
    var end: usize = 0;
    scalars = 0;
    while (end != view.after.len and scalars != available) : (scalars += 1) {
        const length = modelScalarAt(view.after, end);
        const cost = modelBoundedCells(view.after, end, length);
        if (budget + cost > available) break;
        budget += cost;
        end += length;
    }
    return .{ .before = view.before[start..], .after = view.after[0..end] };
}

fn modelBoundedCells(bytes: []const u8, index: usize, length: usize) usize {
    if (!modelPrintable(bytes, index, length)) return 4 * length;
    return if (bytes[index] < 0x7f) 1 else 2;
}

/// Compare the exact bytes the console writes for a redraw with an
/// independently produced expectation. Checking that the output "looks
/// printable" is not enough: the framing the console owns contains control
/// bytes, so only an exact comparison can tell a legitimate erase sequence
/// from one that came out of the buffer.
fn expectRedraw(
    columns: u16,
    prompt: console.Prompt,
    view: console.DisplayView,
) !void {
    const window = modelWindow(columns, prompt, view);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    try expected.append(std.testing.allocator, '\r');
    try expected.appendSlice(std.testing.allocator, prompt.text());
    try modelDisplay(&expected, window.before);
    try modelDisplay(&expected, window.after);
    try expected.appendSlice(std.testing.allocator, "\x1b[0K\r");
    try expected.appendSlice(std.testing.allocator, prompt.text());
    try modelDisplay(&expected, window.before);

    // Sized from the expectation and one byte larger, so writing more than
    // expected overflows and fails rather than being skipped. A fixed buffer
    // with a `catch return` would pass silently on exactly the wide rows this
    // campaign exists to cover.
    const rendered = try std.testing.allocator.alloc(u8, expected.items.len + 1);
    defer std.testing.allocator.free(rendered);
    var writer = std.Io.Writer.fixed(rendered);
    var sink = console.Console.init(&writer, null);
    try sink.redraw(@enumFromInt(columns), prompt, view);
    try std.testing.expectEqualSlices(u8, expected.items, writer.buffered());

    // Whatever was selected fits the row it was planned for, so the redraw
    // cannot wrap and put the rewritten prefix on another line. A row with no
    // space beyond the prompt shows nothing at all rather than overflowing.
    const shown = console.boundedCells(window.before) + console.boundedCells(window.after);
    if (columns <= prompt.text().len + 1)
        try std.testing.expectEqual(@as(usize, 0), shown)
    else
        try std.testing.expect(shown + prompt.text().len < columns);
}

fn expectViewportInvariant(buffer: line_editor.EditBuffer, columns: u16) !void {
    for ([_]console.Prompt{ .primary, .continuation }) |prompt|
        try expectRedraw(columns, prompt, buffer.displayView());
}

fn fuzzEditActions(_: void, smith: *std.testing.Smith) !void {
    var buffer = try line_editor.EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    var model: EditModel = .{};
    defer model.deinit();

    var initial_storage: [128]u8 = undefined;
    const initial = initial_storage[0..smith.slice(&initial_storage)];
    try buffer.insert(initial);
    try model.insert(initial);
    try expectEditInvariant(buffer, &model);
    try expectViewportInvariant(buffer, 0);

    var steps: usize = 0;
    while (steps < max_edit_steps and !smith.eosWeightedSimple(15, 1)) : (steps += 1) {
        switch (@as(u8, smith.value(u5)) % 18) {
            0 => {
                var insertion_storage: [64]u8 = undefined;
                const insertion = insertion_storage[0..smith.slice(&insertion_storage)];
                try buffer.insert(insertion);
                try model.insert(insertion);
            },
            1 => {
                var replacement_storage: [128]u8 = undefined;
                const replacement = replacement_storage[0..smith.slice(&replacement_storage)];
                try buffer.set(replacement);
                try model.set(replacement);
            },
            2 => {
                buffer.moveLeft();
                model.moveLeft();
            },
            3 => {
                buffer.moveRight();
                model.moveRight();
            },
            4 => {
                buffer.moveHome();
                model.cursor = 0;
            },
            5 => {
                buffer.moveEnd();
                model.cursor = model.bytes.items.len;
            },
            6 => {
                buffer.backspace();
                model.backspace();
            },
            7 => {
                buffer.delete();
                model.delete();
            },
            8 => {
                buffer.killToEnd();
                model.remove(model.cursor, model.bytes.items.len);
            },
            9 => {
                buffer.deleteWord();
                model.deleteWord();
            },
            10 => {
                try buffer.transpose();
                model.transpose();
            },
            11 => {
                buffer.clear();
                model.remove(0, model.bytes.items.len);
            },
            12 => {
                // Zero-width, wide, and control scalars in one insertion.
                try buffer.insert("λ界🙂e\u{0301}\u{200b}\x1b[2J");
                try model.insert("λ界🙂e\u{0301}\u{200b}\x1b[2J");
            },
            13 => {
                var owned = try buffer.takeOwned();
                try std.testing.expectEqualSlices(u8, model.bytes.items, owned.bytes());
                owned.deinit();
                owned.deinit();
                model.take();
            },
            14 => {
                // A replacement that aliases the storage it rewrites. The
                // splice has to own it before touching the buffer, or an
                // interior cursor makes the copy overlap itself.
                const aliased = buffer.bytes();
                try buffer.insert(aliased);
                const copy = try std.testing.allocator.dupe(u8, model.bytes.items);
                defer std.testing.allocator.free(copy);
                try model.insert(copy);
            },
            15 => {
                const aliased = buffer.bytes();
                try buffer.set(aliased);
                const copy = try std.testing.allocator.dupe(u8, model.bytes.items);
                defer std.testing.allocator.free(copy);
                try model.set(copy);
            },
            16 => {
                const before = buffer.bytes();
                try std.testing.expectError(error.LineTooLong, buffer.insert(&over_limit_edit));
                try std.testing.expectEqualSlices(u8, before, buffer.bytes());
            },
            17 => {
                const before = try std.testing.allocator.dupe(u8, buffer.bytes());
                defer std.testing.allocator.free(before);
                try std.testing.expectError(error.LineTooLong, buffer.set(&over_limit_edit));
                try std.testing.expectEqualSlices(u8, before, buffer.bytes());
            },
            else => unreachable,
        }
        try expectEditInvariant(buffer, &model);
        try expectViewportInvariant(buffer, smith.value(u9));
        // A row too narrow for the prompt, a row narrower than one wide
        // scalar, and a row wider than any line the campaign builds.
        try expectViewportInvariant(buffer, 3);
        try expectViewportInvariant(buffer, 7);
        try expectViewportInvariant(buffer, 65535);
    }
    var owned = try buffer.takeOwned();
    try std.testing.expectEqualSlices(u8, model.bytes.items, owned.bytes());
    owned.deinit();
    owned.deinit();
    model.take();
    try expectEditInvariant(buffer, &model);
    try expectViewportInvariant(buffer, 80);
}

test "fuzz: editor action traces preserve scalar boundaries and ownership" {
    try std.testing.fuzz({}, fuzzEditActions, .{ .corpus = &.{
        "",
        "left-right-delete",
        "λ界🙂 transpose",
        "\x00\xff\x7f",
        "\x1b[2J\x1b]0;title\x07",
        "\xe0\xa0\x80\xc5\xb7\xc2",
        "界" ** 64,
        "e\u{0301}\u{200b}" ** 64,
    } });
}

/// A pending unit must accumulate exactly the lines appended to it, keep its
/// lexical state describing those bytes, and survive a caller appending a line
/// borrowed from the unit's own source.
fn fuzzPendingUnit(_: void, smith: *std.testing.Smith) !void {
    var unit = try reader.PendingUnit.init(std.testing.allocator);
    defer unit.deinit();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    var lines: usize = 0;

    var steps: usize = 0;
    while (steps < 24 and !smith.eosWeightedSimple(8, 1)) : (steps += 1) {
        switch (@as(u8, smith.value(u2))) {
            0 => {
                var storage: [512]u8 = undefined;
                const line = storage[0..smith.slice(&storage)];
                try appendBoth(unit, &expected, &joined, &lines, line);
            },
            1 => {
                // A line borrowed from the unit's own storage. Growing the
                // unit can move that storage, so the append has to own its
                // input before it grows.
                const borrowed = unit.source();
                try appendBoth(unit, &expected, &joined, &lines, borrowed);
            },
            2 => {
                unit.clear();
                expected.clearRetainingCapacity();
                joined.clearRetainingCapacity();
                lines = 0;
            },
            else => {},
        }
        try std.testing.expectEqualSlices(u8, expected.items, unit.source());
        try std.testing.expectEqual(expected.items.len == 0, unit.isEmpty());

        // Scanning the same source in one pass must reach the same state as
        // scanning it a line at a time, which is the whole claim the
        // incremental checkpoint makes.
        var single = try reader.PendingUnit.init(std.testing.allocator);
        defer single.deinit();
        if (lines != 0) try single.appendLine(joined.items);
        try std.testing.expectEqualSlices(u8, expected.items, single.source());
        var probe: [64]u8 = undefined;
        const prefix = probe[0..smith.slice(&probe)];
        try std.testing.expectEqual(unit.contextAfter(prefix), single.contextAfter(prefix));
        // Asking observes without mutating.
        try std.testing.expectEqualSlices(u8, expected.items, unit.source());
    }
}

fn appendBoth(
    unit: reader.PendingUnit,
    expected: *std.ArrayList(u8),
    joined: *std.ArrayList(u8),
    lines: *usize,
    line: []const u8,
) !void {
    const owned = try std.testing.allocator.dupe(u8, line);
    defer std.testing.allocator.free(owned);
    try unit.appendLine(line);
    if (lines.* != 0) try joined.append(std.testing.allocator, '\n');
    lines.* += 1;
    try joined.appendSlice(std.testing.allocator, owned);
    try expected.appendSlice(std.testing.allocator, owned);
    try expected.append(std.testing.allocator, '\n');
}

test "fuzz: pending unit accumulates lines and lexical state" {
    try std.testing.fuzz({}, fuzzPendingUnit, .{ .corpus = &.{
        "",
        "1 2 +",
        "\"unterminated",
        "# comment",
        "[] (1 'x set) 'stats @defm",
    } });
}

fn runOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("fuzz-session.ecl", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            runtime.release(failure);
            return error.UnexpectedLanguageError;
        },
    }
}

fn expectCompletionInvariant(prefix: []const u8, items: []const []const u8) !void {
    for (items, 0..) |item, index| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(item));
        try std.testing.expect(std.mem.startsWith(u8, item, prefix));
        if (index != 0)
            try std.testing.expect(std.mem.order(u8, items[index - 1], item) == .lt);
    }
}

fn fuzzCompletionMutation(_: void, smith: *std.testing.Smith) !void {
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .cooperative);
    defer runtime.deinit();

    var first_prefix_storage: [32]u8 = undefined;
    const first_prefix = first_prefix_storage[0..smith.slice(&first_prefix_storage)];
    var first_candidates = try runtime.completionCandidates(first_prefix);
    defer first_candidates.deinit();
    try expectCompletionInvariant(first_prefix, first_candidates.items());

    var initial = try runtime.completionCandidates("sq");
    defer initial.deinit();
    try expectCompletionInvariant("sq", initial.items());
    try std.testing.expectEqual(@as(usize, 1), initial.items().len);
    try std.testing.expectEqualStrings("sqrt", initial.items()[0]);
    try runOk(
        &runtime,
        "[] (1 'alpha set 2 'private setp) 'fuzzmod @defm " ++
            "'fm 'fuzzmod alias 'fuzzmod ('alpha) import 3 'fuzz-live set",
    );
    var steps: usize = 0;
    while (steps < max_session_steps and !smith.eosWeightedSimple(7, 1)) : (steps += 1) {
        switch (smith.value(u3)) {
            0 => try runOk(&runtime, "[] (4 'alpha set 5 'private setp) 'fuzzmod @defm"),
            1 => try runOk(&runtime, "[] (6 'beta set 7 'hidden setp) 'fuzzmod @defm"),
            2 => try runOk(&runtime, "8 'fuzz-live set"),
            3 => try runOk(&runtime, "9 'fuzz-second set"),
            4, 5, 6, 7 => |action| {
                var prefix_storage: [32]u8 = undefined;
                const prefix: []const u8 = switch (action) {
                    4 => prefix_storage[0..smith.slice(&prefix_storage)],
                    5 => "fuzzmod.",
                    6 => "fm.",
                    7 => "fuzz",
                    else => unreachable,
                };
                var candidates = try runtime.completionCandidates(prefix);
                defer candidates.deinit();
                try expectCompletionInvariant(prefix, candidates.items());
            },
        }
    }
}

test "fuzz: completion survives prefixes definitions aliases and reloads" {
    try std.testing.fuzz({}, fuzzCompletionMutation, .{ .corpus = &.{
        "",
        "fuzzmod.",
        "fm.alpha",
        "reload-reload-query",
        "\x00\xff.private",
    } });
}

fn validHistoryBytes(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, '\r') == null;
}

fn printableLine(prefix: u8, source: []const u8, storage: *[66]u8) []const u8 {
    storage[0] = prefix;
    storage[1] = '-';
    const length = @min(source.len, storage.len - 2);
    for (source[0..length], storage[2..][0..length]) |byte, *output|
        output.* = 33 + byte % 94;
    return storage[0 .. length + 2];
}

fn containsLine(lines: []const []const u8, expected: []const u8) bool {
    for (lines) |line| if (std.mem.eql(u8, line, expected)) return true;
    return false;
}

fn fuzzHistoryPersistence(_: void, smith: *std.testing.Smith) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/history",
        .{path_buffer[0..path_length]},
    );
    defer std.testing.allocator.free(path);

    var disk_storage: [512]u8 = undefined;
    const original = disk_storage[0..smith.slice(&disk_storage)];
    var file = try temporary.dir.createFile(std.testing.io, "history", .{});
    try file.writeStreamingAll(std.testing.io, original);
    file.close(std.testing.io);

    var first = try line_editor.History.init(std.testing.allocator, std.testing.io, path);
    defer first.deinit();
    var stale = try line_editor.History.init(std.testing.allocator, std.testing.io, path);
    defer stale.deinit();
    const valid_original = validHistoryBytes(original);
    try std.testing.expectEqual(!valid_original, first.takeWarning() != null);
    try std.testing.expect(first.takeWarning() == null);
    try std.testing.expectEqual(!valid_original, stale.takeWarning() != null);
    try std.testing.expect(stale.takeWarning() == null);

    var first_input: [64]u8 = undefined;
    const first_source = first_input[0..smith.slice(&first_input)];
    var second_input: [64]u8 = undefined;
    const second_source = second_input[0..smith.slice(&second_input)];
    var first_line_storage: [66]u8 = undefined;
    const first_line = printableLine('a', first_source, &first_line_storage);
    var second_line_storage: [66]u8 = undefined;
    const second_line = printableLine('b', second_source, &second_line_storage);
    try first.record(first_line);
    try stale.record(second_line);

    const disk = try temporary.dir.readFileAlloc(
        std.testing.io,
        "history",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(disk);
    if (!valid_original) {
        try std.testing.expectEqualSlices(u8, original, disk);
        try std.testing.expectEqualStrings(first_line, first.entries()[first.entries().len - 1]);
        try std.testing.expectEqualStrings(second_line, stale.entries()[stale.entries().len - 1]);
        return;
    }

    try std.testing.expect(std.unicode.utf8ValidateSlice(disk));
    var loaded = try line_editor.History.init(std.testing.allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expect(loaded.takeWarning() == null);
    try std.testing.expect(loaded.entries().len <= line_editor.max_history_entries);
    try std.testing.expect(containsLine(loaded.entries(), first_line));
    try std.testing.expectEqualStrings(second_line, loaded.entries()[loaded.entries().len - 1]);
}

test "fuzz: history parsing merging and corruption preservation" {
    try std.testing.fuzz({}, fuzzHistoryPersistence, .{ .corpus = &.{
        "",
        "one\ntwo\n",
        "duplicate\nduplicate\n",
        "valid λ history\n",
        "bad\rline\n",
        "\xff",
    } });
}

fn fuzzSchedulerRuntime(_: void, smith: *std.testing.Smith) !void {
    const programs = [_][]const u8{
        "[] (1) @spawn await pop",
        "[] (1) @spawn dup cancel await pop",
        "[] (1) @spawn dup await pop await pop",
        "[] [] (missing) @each pop",
        "[1 2 3] [] (dup *) @each pop",
        "[] ((1) () while) @spawn dup cancel await pop",
        "[] (7) @spawn 'fuzz-task set fuzz-task await pop",
    };
    var runtime = try session.Session.initWithConfig(std.testing.allocator, &.{}, .cooperative);
    defer runtime.deinit();
    var steps: usize = 0;
    while (steps < max_session_steps and !smith.eosWeightedSimple(7, 1)) : (steps += 1)
        try runOk(&runtime, programs[smith.index(programs.len)]);
    try std.testing.expectEqual(@as(usize, 0), runtime.schedulerWorkerThreadCount());
    var stack = try runtime.stackDisplay();
    defer stack.deinit();
    try std.testing.expectEqualStrings("", stack.bytes());
}

test "fuzz: real scheduler publication cancellation and join traces settle" {
    try std.testing.fuzz({}, fuzzSchedulerRuntime, .{ .corpus = &.{
        "",
        "spawn-await",
        "cancel-before-dispatch",
        "@each-order",
        "\x00\x01\x02\x03\x04\x05\x06",
    } });
}

fn fuzzNativeTransactions(_: void, smith: *std.testing.Smith) !void {
    const programs = [_][]const u8{
        "7 sample.forward pop",
        "7 sample.split pop pop",
        "7 sample.singleton pop",
        "[] (7 sample.draft-fail) @attempt pop",
        "sample.cooperative pop",
        "[] (9 sample.yield-forever) @spawn dup cancel await pop",
    };
    var source = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer source.deinit();
    var steps: usize = 0;
    while (steps < max_session_steps and !smith.eosWeightedSimple(7, 1)) : (steps += 1) {
        try source.writer.writeAll(programs[smith.index(programs.len)]);
        try source.writer.writeByte(' ');
    }
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("ECL_PATH", native_runtime.fixture_dir);
    try environment.put("ECL_WORKERS", "1");
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{ native_runtime.ecl_exe, "-e", source.written() },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // `kill` is idempotent after `wait`; on timeout it also reaps the child.
    defer child.kill(io);

    // SAFETY: `MultiReader.init` initializes every stream slot before use.
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    // SAFETY: `MultiReader.init` initializes the complete reader before use.
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        std.testing.allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .raw = .fromSeconds(10),
        .clock = .awake,
    });
    while (multi_reader.fill(64, .{ .deadline = deadline })) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    defer std.testing.allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    defer std.testing.allocator.free(stderr);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        .signal, .stopped, .unknown => return error.UnexpectedTermination,
    }
    try std.testing.expectEqualStrings("", stdout);
    try std.testing.expectEqualStrings("", stderr);
}

test "fuzz: native call transactions stay atomic under yield and cancellation" {
    try std.testing.fuzz({}, fuzzNativeTransactions, .{ .corpus = &.{
        "",
        "complete-forward-split",
        "draft-fail-after-yield",
        "cancel-yield-forever",
        "\x00\xff",
    } });
}
