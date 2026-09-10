// zlint-disable homeless-try -- zlint 0.9.1 does not resolve the SDK's aliased error union; Zig validates every callback signature.
//! The first-party `csv` module, authored against the public `ecl-native` SDK.
//!
//! A bounded lexical scan stages field spans by column. Final construction
//! decodes those spans into typed leaves, retaining original input spellings
//! until whole-column inference has settled. No row values are constructed.
const std = @import("std");
const ecl = @import("ecl-native");

pub const Extension = ecl.module(.{
    .name = "csv",
    // Linked into this image rather than loaded from one, so the ABI entry
    // symbol stays free for a real extension.
    .linkage = .static,
    .doc = "RFC 4180 comma-separated values with columnar parsing.",
    .words = .{
        ecl.word(
            "parse",
            "Parse CSV content and a positional schema into a list of columns.",
            parse,
        ),
        ecl.word("parse-header", "Parse CSV content and a positional schema into headers followed by columns.", parseHeader),
        ecl.word(
            "emit",
            "Render records of string fields as canonical CRLF-terminated RFC 4180 text.",
            emit,
        ),
    },
});

const max_columns = ecl.abi.max_builder_slots - 5;
const header_spans = max_columns;
const column_output = max_columns + 1;
const field_output = max_columns + 2;
const columns_output = max_columns + 3;
const Type = enum(u8) { auto, int, float, text };
const Column = struct { schema: Type = .auto, inferred: Type = .auto, exact: bool = true };
const Mode = enum(u8) { start, bare, quoted, quote_seen, cr_seen };
const Stop = enum(u8) { comma, record, input_end };
const Phase = enum(u8) { schema, scan, stage, begin_columns, begin_column, span, span_text, numeric_flush, render, flush, append_field, close_column, finish };

// Each descriptor keeps full-width offsets, decoded length, and numeric bits.
// Compact scalar metadata avoids paying a separate staging word per flag.
const SpanFlags = packed struct(u64) {
    max_character: u32,
    quoted: bool,
    escaped: bool,
    number_kind: enum(u2) { text, int, float },
    reserved: u28 = 0,
};

const ParseWork = struct {
    pub const State = struct {
        phase: Phase = .schema,
        columns: [max_columns]Column = @splat(.{}),
        schema_index: u32 = 0,
        width: u32 = 0,
        column: u32 = 0,
        records: u64 = 0,
        row: u64 = 0,
        mode: Mode = .start,
        stop: Stop = .input_end,
        position: u64 = 0,
        start: u64 = 0,
        end: u64 = 0,
        characters: u64 = 0,
        max_character: u32 = 0,
        cached_number: Number = .text,
        converted: bool = false,
        quoted: bool = false,
        escaped: bool = false,
        numeric: [256]u64,
        numeric_len: u32 = 0,
        token: NumericToken = NumericToken.init(),
        cache: [256]u32,
        cache_start: u64 = 0,
        cache_len: u32 = 0,
        input_mode: enum(u8) { unknown, bytes, text } = .unknown,
        utf_remaining: u8 = 0,
        utf_value: u32 = 0,
        utf_min: u32 = 0,
        rendering_header: bool = false,
        rendered: u64 = 0,
        pending: [128]u64,
        pending_len: u32 = 0,
        render_done: bool = false,
    };
    pub fn init() State {
        // SAFETY: cache_len and pending_len expose only prefixes written by the producer.
        return .{ .cache = undefined, .pending = undefined, .numeric = undefined };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const ParseSchedule = ecl.Reschedule(ParseWork);

fn parse(call: *ecl.Call("input schema -- columns"), build: *ecl.BuildValues, schedule: *ParseSchedule) ecl.CallbackResult {
    return parseColumns(false, call, build, schedule);
}
fn parseHeader(call: *ecl.Call("input schema -- headers columns"), build: *ecl.BuildValues, schedule: *ParseSchedule) ecl.CallbackResult {
    return parseColumns(true, call, build, schedule);
}

const Read = union(enum) { character: u32, end, exhausted, invalid, malformed };
fn character(call: anytype, s: *ParseWork.State, limit: u64) error{OutOfMemory}!Read {
    while (s.position < limit) {
        if (s.position < s.cache_start or s.position >= s.cache_start + s.cache_len) {
            const capacity: usize = @intCast(@min(limit - s.position, s.cache.len));
            switch (try call.readUnits(0, s.position, s.cache[0..capacity])) {
                .yield_required => return .exhausted,
                .invalid => return .invalid,
                .units => |units| {
                    const mode: @TypeOf(s.input_mode) = if (units.bytes) .bytes else .text;
                    if (s.input_mode != .unknown and s.input_mode != mode) return .invalid;
                    s.input_mode = mode;
                    s.cache_start = s.position;
                    s.cache_len = units.count;
                },
            }
        }
        const unit = s.cache[@intCast(s.position - s.cache_start)];
        s.position += 1;
        if (s.input_mode == .text) return .{ .character = unit };
        if (s.utf_remaining == 0) {
            if (unit < 128) return .{ .character = unit };
            if (unit >= 0xc2 and unit <= 0xdf) {
                s.utf_remaining = 1;
                s.utf_value = unit & 31;
                s.utf_min = 128;
            } else if (unit >= 0xe0 and unit <= 0xef) {
                s.utf_remaining = 2;
                s.utf_value = unit & 15;
                s.utf_min = 2048;
            } else if (unit >= 0xf0 and unit <= 0xf4) {
                s.utf_remaining = 3;
                s.utf_value = unit & 7;
                s.utf_min = 65536;
            } else return .malformed;
        } else {
            if (unit < 0x80 or unit > 0xbf) return .malformed;
            s.utf_value = (s.utf_value << 6) | (unit & 63);
            s.utf_remaining -= 1;
            if (s.utf_remaining == 0) {
                const cp = s.utf_value;
                if (cp < s.utf_min or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return .malformed;
                return .{ .character = cp };
            }
        }
    }
    return if (s.utf_remaining != 0) .malformed else .end;
}

const Scan = union(enum) { character: u32, field: Stop, exhausted, invalid, malformed };
fn scan(call: anytype, s: *ParseWork.State, limit: u64) error{OutOfMemory}!Scan {
    while (true) {
        const before = s.position;
        const cp = switch (try character(call, s, limit)) {
            .character => |cp| cp,
            .end => {
                if (s.mode == .quoted) return .malformed;
                if (s.mode != .cr_seen) s.end = s.position;
                return .{ .field = .input_end };
            },
            .exhausted => return .exhausted,
            .invalid => return .invalid,
            .malformed => return .malformed,
        };
        switch (s.mode) {
            .cr_seen => return if (cp == '\n') .{ .field = .record } else .malformed,
            .quoted => {
                if (cp == '"') {
                    s.mode = .quote_seen;
                    continue;
                }
                return .{ .character = cp };
            },
            .quote_seen => {
                if (cp == '"') {
                    s.mode = .quoted;
                    s.escaped = true;
                    return .{ .character = cp };
                }
                if (cp != ',' and cp != '\r' and cp != '\n') return .malformed;
            },
            .start => {
                if (cp == '"') {
                    s.mode = .quoted;
                    s.quoted = true;
                    continue;
                }
                s.mode = .bare;
            },
            .bare => if (cp == '"') {
                return .malformed;
            },
        }
        if (cp == ',' or cp == '\r' or cp == '\n') {
            s.end = before;
            if (cp == '\r') {
                s.mode = .cr_seen;
                continue;
            }
            return .{ .field = if (cp == ',') .comma else .record };
        }
        return .{ .character = cp };
    }
}

const Number = union(enum) { int: i64, float: f64, text };

/// Decimal normalization bounds scratch space, not accepted field length.
/// 768 significant digits cover binary64 rounding boundaries; a sticky digit
/// preserves the direction of any remaining nonzero decimal tail.
const NumericToken = struct {
    mode: enum(u8) { start, sign, integer, point, fraction, exponent, exponent_sign, exponent_digits, bad } = .start,
    negative: bool = false,
    plus: bool = false,
    leading_zero: bool = false,
    integer_digits: u64 = 0,
    integer: u64 = 0,
    integer_overflow: bool = false,
    fractional: i64 = 0,
    exponent: i64 = 0,
    exponent_negative: bool = false,
    digits: [768]u8,
    count: u16 = 0,
    ignored: i64 = 0,
    sticky: bool = false,

    fn init() NumericToken {
        // SAFETY: count exposes only digits initialized by digit().
        return .{ .digits = undefined };
    }

    fn digit(self: *NumericToken, cp: u32, fractional: bool) void {
        const d = cp - '0';
        if (fractional) self.fractional += 1 else {
            if (self.integer_digits == 0) self.leading_zero = d == 0;
            self.integer_digits += 1;
            if (!self.integer_overflow) {
                const bound: u64 = @as(u64, 1) << 63;
                if (self.integer > (bound - d) / 10) self.integer_overflow = true else self.integer = self.integer * 10 + d;
            }
        }
        if (self.count == 0 and d == 0) return;
        if (self.count < self.digits.len) {
            self.digits[self.count] = @intCast(cp);
            self.count += 1;
        } else {
            self.ignored += 1;
            self.sticky = self.sticky or d != 0;
        }
    }
    fn push(self: *NumericToken, cp: u32) void {
        const is_digit = cp >= '0' and cp <= '9';
        switch (self.mode) {
            .bad => {},
            .start, .sign => {
                if (self.mode == .start and (cp == '+' or cp == '-')) {
                    self.negative = cp == '-';
                    self.plus = cp == '+';
                    self.mode = .sign;
                } else if (is_digit) {
                    self.mode = .integer;
                    self.digit(cp, false);
                } else self.mode = .bad;
            },
            .integer => {
                if (is_digit) self.digit(cp, false) else if (cp == '.') self.mode = .point else if (cp == 'e' or cp == 'E') self.mode = .exponent else self.mode = .bad;
            },
            .point, .fraction => {
                if (is_digit) {
                    self.mode = .fraction;
                    self.digit(cp, true);
                } else if (self.mode == .fraction and (cp == 'e' or cp == 'E')) self.mode = .exponent else self.mode = .bad;
            },
            .exponent, .exponent_sign, .exponent_digits => {
                if (self.mode == .exponent and (cp == '+' or cp == '-')) {
                    self.exponent_negative = cp == '-';
                    self.mode = .exponent_sign;
                } else if (is_digit) {
                    self.exponent = @min(self.exponent * 10 + cp - '0', 1 << 40);
                    self.mode = .exponent_digits;
                } else self.mode = .bad;
            },
        }
    }
    fn result(self: *const NumericToken, conservative: bool) Number {
        switch (self.mode) {
            .integer, .fraction, .exponent_digits => {},
            else => return .text,
        }
        if (conservative and (self.plus or (self.leading_zero and self.integer_digits > 1))) return .text;
        if (self.mode == .integer) {
            const bound: u64 = if (self.negative) @as(u64, 1) << 63 else std.math.maxInt(i64);
            if (!self.integer_overflow and self.integer <= bound) {
                if (conservative and self.negative and self.integer == 0) return .text;
                const magnitude: i128 = self.integer;
                return .{ .int = @intCast(if (self.negative) -magnitude else magnitude) };
            }
            if (conservative) return .text;
        }
        if (self.count == 0) return .{ .float = if (self.negative) -0.0 else 0.0 };
        var buffer: [832]u8 = undefined;
        var index: usize = 0;
        if (self.negative) {
            buffer[index] = '-';
            index += 1;
        }
        @memcpy(buffer[index..][0..self.count], self.digits[0..self.count]);
        index += self.count;
        var exponent = (if (self.exponent_negative) -self.exponent else self.exponent) - self.fractional + self.ignored;
        if (self.sticky) {
            buffer[index] = '1';
            index += 1;
            exponent -= 1;
        }
        const suffix = std.fmt.bufPrint(buffer[index..], "e{d}", .{exponent}) catch @panic("bounded decimal rendering exceeded scratch buffer");
        const value = std.fmt.parseFloat(f64, buffer[0 .. index + suffix.len]) catch return .text;
        if (!std.math.isFinite(value)) return .text;
        return .{ .float = value };
    }
};
fn remember(s: *ParseWork.State, cp: u32) void {
    s.token.push(cp);
}
fn number(s: *const ParseWork.State, conservative: bool) Number {
    return s.token.result(conservative);
}
fn exactFloat(integer: i64) bool {
    const converted: f64 = @floatFromInt(integer);
    return @as(i128, @intFromFloat(converted)) == integer;
}
fn refine(column: *Column, result: Number) void {
    if (column.inferred == .text) return;
    switch (result) {
        .text => column.inferred = .text,
        .int => |integer| {
            column.exact = column.exact and exactFloat(integer);
            if (column.inferred == .auto) column.inferred = .int;
            if (column.inferred == .float and !column.exact) column.inferred = .text;
        },
        .float => column.inferred = if (column.exact) .float else .text,
    }
}
fn failure(call: anytype, s: *const ParseWork.State, kind: ecl.ErrorKind, reason: []const u8) ecl.CallbackResult {
    var buffer: [192]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "csv: {s} at record {d}, column {d}", .{ reason, s.records + 1, s.column + 1 }) catch reason;
    return call.fail(kind, message);
}
fn textKind(maximum: u32) ecl.BulkKind {
    return if (maximum <= 255) .char1 else if (maximum <= 65535) .char2 else .char4;
}
fn columnType(s: *const ParseWork.State) Type {
    if (s.rendering_header) return .text;
    const col = s.columns[s.column];
    return if (col.schema != .auto) col.schema else if (col.inferred == .auto) .text else col.inferred;
}
fn outputKind(s: *const ParseWork.State) ecl.BulkKind {
    return switch (columnType(s)) {
        .int => .integers,
        .float => .floats,
        else => .values,
    };
}
fn resetField(s: *ParseWork.State) void {
    s.mode = .start;
    s.start = s.position;
    s.characters = 0;
    s.max_character = 0;
    s.token = NumericToken.init();
    s.converted = false;
    s.cached_number = .text;
    s.quoted = false;
    s.escaped = false;
}

fn parseColumns(comptime header: bool, call: anytype, build: *ecl.BuildValues, schedule: *ParseSchedule) ecl.CallbackResult {
    const s = schedule.state();
    if (call.input(0).kind() != .list or call.input(1).kind() != .list) return call.fail(.type, "csv expects content and a schema list");
    const length = call.input(0).aggregateLength().?;
    const schema_len = call.input(1).aggregateLength().?;
    if (schema_len > max_columns) return call.fail(.shape, "csv exceeds the native column limit");
    while (true) switch (s.phase) {
        .schema => {
            if (s.schema_index == schema_len) {
                if (length == 0) {
                    if (header) return call.fail(.shape, "csv.parse-header requires a header record");
                    s.width = @intCast(schema_len);
                    s.phase = .begin_columns;
                } else s.phase = .scan;
                continue;
            }
            const cursor = call.listCursor(1, s.schema_index).?;
            switch (cursor.next()) {
                .yield_required => return schedule.yield(),
                .item => |item| {
                    if (item.kind() != .symbol) return call.fail(.domain, "csv schema entries must be auto, int, float, or text symbols");
                    const name = item.bytes().?;
                    s.columns[s.schema_index].schema = std.meta.stringToEnum(Type, name) orelse return call.fail(.domain, "csv schema entries must be auto, int, float, or text symbols");
                    s.schema_index += 1;
                },
                else => return call.fail(.domain, "csv schema is unreadable"),
            }
        },
        .scan => {
            if (s.column >= max_columns) return call.fail(.shape, "csv exceeds the native column limit");
            switch (try scan(call, s, length)) {
                .exhausted => return schedule.yield(),
                .invalid => return failure(call, s, .type, "expected text or UTF-8 bytes"),
                .malformed => return failure(call, s, .parse, "malformed quoting or UTF-8"),
                .character => |cp| {
                    s.characters += 1;
                    s.max_character = @max(s.max_character, cp);
                    const col = s.columns[s.column];
                    if (!(header and s.records == 0) and col.schema != .text and !(col.schema == .auto and col.inferred == .text)) remember(s, cp);
                },
                .field => |stop| {
                    s.stop = stop;
                    s.phase = .stage;
                },
            }
        },
        .stage => {
            const is_header = header and s.records == 0;
            const col = &s.columns[s.column];
            if (!is_header and !s.converted) {
                if (col.schema == .auto and col.inferred != .text) {
                    if (!schedule.consume(@as(u32, s.token.count) + 32)) return schedule.yield();
                    s.cached_number = number(s, true);
                    refine(col, s.cached_number);
                } else if (col.schema != .auto and col.schema != .text) {
                    if (!schedule.consume(@as(u32, s.token.count) + 32)) return schedule.yield();
                    const result = number(s, false);
                    s.cached_number = result;
                    if (result == .text or (col.schema == .int and result != .int)) return failure(call, s, .parse, "numeric schema conversion failed");
                }
            }
            s.converted = true;
            const flags = SpanFlags{
                .max_character = s.max_character,
                .quoted = s.quoted,
                .escaped = s.escaped,
                .number_kind = switch (s.cached_number) {
                    .text => .text,
                    .int => .int,
                    .float => .float,
                },
            };
            const number_bits: u64 = switch (s.cached_number) {
                .text => 0,
                .int => |v| @bitCast(v),
                .float => |v| @bitCast(v),
            };
            switch (try build.stage(if (is_header) header_spans else s.column, &.{ s.start, s.end, s.characters, @bitCast(flags), number_bits })) {
                .yield_required => return schedule.yield(),
                .invalid => return call.fail(.domain, "csv span staging rejected"),
                .appended => {},
            }
            s.column += 1;
            if (s.stop != .comma) {
                if (s.records == 0) s.width = s.column;
                if (s.column != s.width or (schema_len != 0 and schema_len != s.width)) return failure(call, s, .shape, "record or schema width mismatch");
                s.records += 1;
                s.column = 0;
            }
            s.phase = if (s.stop == .input_end or (s.stop == .record and s.position == length)) .begin_columns else .scan;
            resetField(s);
        },
        .begin_columns => {
            s.column = 0;
            s.rendering_header = header;
            s.phase = .begin_column;
        },
        .begin_column => {
            s.row = if (s.rendering_header) s.width else s.records - @intFromBool(header);
            s.phase = .span;
        },
        .span => {
            if (s.row == 0) {
                s.phase = .close_column;
                continue;
            }
            var span: [5]u64 = undefined;
            switch (try build.readStagedForward(if (s.rendering_header) header_spans else s.column, &span)) {
                .yield_required => return schedule.yield(),
                .invalid => return call.fail(.domain, "csv span read rejected"),
                .appended => {},
            }
            s.position = span[0];
            resetField(s);
            s.end = span[1];
            s.characters = span[2];
            const flags: SpanFlags = @bitCast(span[3]);
            s.max_character = flags.max_character;
            s.quoted = flags.quoted;
            s.escaped = flags.escaped;
            s.cached_number = switch (flags.number_kind) {
                .int => .{ .int = @bitCast(span[4]) },
                .float => .{ .float = @bitCast(span[4]) },
                .text => .text,
            };
            s.pending_len = 0;
            s.rendered = 0;
            s.render_done = false;
            s.phase = if (columnType(s) != .text) .append_field else if (!s.escaped) .span_text else .render;
        },
        .span_text => {
            const count = if (s.rendering_header) s.width else s.records - @intFromBool(header);
            const target = if (s.rendering_header) max_columns + 4 else column_output;
            const padding: u64 = @intFromBool(s.quoted);
            switch (try build.appendTextSpan(target, count, 0, s.start + padding, s.end - s.start - 2 * padding, s.characters, textKind(s.max_character))) {
                .yield_required => return schedule.yield(),
                .invalid => return call.fail(.parse, "csv staged text span is invalid"),
                .appended => {},
            }
            s.row -= 1;
            s.phase = .span;
        },
        .numeric_flush => {
            const count = s.records - @intFromBool(header);
            switch (try build.appendBulk(column_output, outputKind(s), count, false, s.numeric[0..s.numeric_len])) {
                .yield_required => return schedule.yield(),
                .invalid => return call.fail(.domain, "csv numeric append rejected"),
                .appended => {},
            }
            s.numeric_len = 0;
            s.phase = .span;
        },
        .render => {
            switch (try scan(call, s, s.end)) {
                .exhausted => return schedule.yield(),
                .invalid, .malformed => return call.fail(.parse, "csv staged field is invalid"),
                .field => {
                    s.render_done = true;
                    s.phase = .flush;
                },
                .character => |cp| {
                    if (columnType(s) == .text) {
                        s.pending[s.pending_len] = cp;
                        s.pending_len += 1;
                        if (s.pending_len == s.pending.len) s.phase = .flush;
                    } else remember(s, cp);
                },
            }
        },
        .flush => {
            if (columnType(s) == .text and s.pending_len != 0) {
                switch (try build.appendBulk(field_output, textKind(s.max_character), s.characters, false, s.pending[0..s.pending_len])) {
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv text append rejected"),
                    .appended => {},
                }
                s.rendered += s.pending_len;
                s.pending_len = 0;
            }
            s.phase = if (s.render_done) .append_field else .render;
        },
        .append_field => {
            const count = if (s.rendering_header) s.width else s.records - @intFromBool(header);
            const target = if (s.rendering_header) max_columns + 4 else column_output;
            if (columnType(s) == .text) {
                const candidate = switch (try build.finishBulk(field_output, textKind(s.max_character), s.characters, false)) {
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv text finish rejected"),
                    .candidate => |candidate| candidate,
                };
                switch (try build.appendBulkValue(target, count, false, candidate)) {
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv column append rejected"),
                    .appended => {},
                }
            } else {
                const result = s.cached_number;
                const bits: u64 = if (columnType(s) == .int) @bitCast(result.int) else @bitCast(switch (result) {
                    .int => |v| @as(f64, @floatFromInt(v)),
                    .float => |v| v,
                    .text => unreachable,
                });
                s.numeric[s.numeric_len] = bits;
                s.numeric_len += 1;
                s.row -= 1;
                s.phase = if (s.numeric_len == s.numeric.len or s.row == 0) .numeric_flush else .span;
                continue;
            }
            s.row -= 1;
            s.phase = .span;
        },
        .close_column => {
            if (s.rendering_header) {
                s.rendering_header = false;
                s.phase = if (s.width == 0) .finish else .begin_column;
                continue;
            }
            if (s.column == s.width) {
                s.phase = .finish;
                continue;
            }
            const candidate = switch (try build.finishBulk(column_output, outputKind(s), s.records - @intFromBool(header), false)) {
                .yield_required => return schedule.yield(),
                .invalid => return call.fail(.domain, "csv column finish rejected"),
                .candidate => |candidate| candidate,
            };
            switch (try build.appendList(columns_output, s.width, candidate)) {
                .yield_required => return schedule.yield(),
                .invalid => return call.fail(.domain, "csv columns append rejected"),
                .appended => {},
            }
            s.column += 1;
            s.phase = if (s.column == s.width) .finish else .begin_column;
        },
        .finish => {
            const columns = switch (try build.finishList(columns_output, s.width)) {
                .yield_required => return schedule.yield(),
                .invalid => return call.fail(.domain, "csv columns finish rejected"),
                .candidate => |candidate| candidate,
            };
            if (header) {
                const headers = switch (try build.finishBulk(max_columns + 4, .values, s.width, false)) {
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv headers finish rejected"),
                    .candidate => |candidate| candidate,
                };
                return call.complete(.{ headers, columns });
            } else return call.complete(.{columns});
        },
    };
}

/// Emission is the mirror of parsing and inherits the same two constraints:
/// the output character count must be exact before the first append, and
/// nothing about a field can be buffered across a yield. So the record set is
/// measured once — counting output characters, including the quotes and
/// doubling a quoted field needs — and then rendered from positions alone.
const EmitPhase = enum(u8) {
    /// Walk every field, validating shape and counting output characters.
    measure,
    /// Re-walk the same fields, appending each output character.
    render,
    /// Finish the output builder and complete the call.
    finish,
};

/// Where the renderer is inside one field. A quoted field emits an opening
/// quote, its body with quotes doubled, and a closing quote.
const FieldPart = enum(u8) {
    open_quote,
    body,
    doubled_quote,
    close_quote,
    comma,
    terminator_cr,
    terminator_lf,
};

const EmitWork = struct {
    pub const State = struct {
        phase: EmitPhase,
        part: FieldPart,
        /// Record and field being measured or rendered.
        record: u64,
        field: u64,
        /// Character position inside the current field's text.
        character: u64,
        /// Total output characters, and how many have been appended.
        characters: u64,
        emitted: u64,
        /// Whether the field being rendered requires quoting. Recomputed per
        /// field during the measure pass and again during the render pass.
        quoted: bool,
        /// Cached widths so the render pass does not re-derive them.
        record_count: u64,
        field_count: u64,
        text_length: u64,
    };
    pub fn init() State {
        return .{
            .phase = .measure,
            .part = .open_quote,
            .record = 0,
            .field = 0,
            .character = 0,
            .characters = 0,
            .emitted = 0,
            .quoted = false,
            .record_count = 0,
            .field_count = 0,
            .text_length = 0,
        };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const EmitSchedule = ecl.Reschedule(EmitWork);

const output_slot: u32 = 0;

/// A field must be quoted exactly when it contains a comma, a quote, a
/// carriage return, or a newline. Anything else is emitted bare, which is what
/// keeps the canonical output byte-stable.
fn requiresQuoting(codepoint: u32) bool {
    return codepoint == ',' or codepoint == '"' or codepoint == '\r' or codepoint == '\n';
}

fn emit(
    call: *ecl.Call("rows -- text"),
    build: *ecl.BuildValues,
    schedule: *EmitSchedule,
) ecl.CallbackResult {
    const rows = call.input(0);
    if (rows.kind() != .list) return call.fail(.type, "csv.emit expects a list of records");
    const state = schedule.state();
    state.record_count = rows.aggregateLength().?;
    while (true) switch (state.phase) {
        .measure => {
            if (state.record == state.record_count) {
                state.characters = state.emitted;
                state.emitted = 0;
                state.record = 0;
                state.field = 0;
                state.character = 0;
                state.part = .open_quote;
                state.phase = .render;
                continue;
            }
            switch (try measureStep(call, state)) {
                .keep_going => {},
                .failed => |outcome| return outcome,
            }
        },
        .render => {
            if (state.emitted == state.characters) {
                state.phase = .finish;
                continue;
            }
            switch (try renderStep(call, build, state)) {
                .keep_going => {},
                .failed => |outcome| return outcome,
            }
        },
        .finish => return switch (try build.finishList(output_slot, state.characters)) {
            .candidate => |candidate| call.complete(.{candidate}),
            .yield_required => schedule.yield(),
            .invalid => call.fail(.domain, "csv.emit output builder was rejected"),
        },
    };
}

const StepOutcome = union(enum) {
    keep_going,
    failed: ecl.Outcome,
};

/// Reads one field's view, validating the record and field shape on the way.
/// Every rejection here happens before a single output character is built.
fn fieldView(
    call: *ecl.Call("rows -- text"),
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!union(enum) { view: *const ecl.ValueView, failed: ecl.Outcome } {
    const record = switch (call.nested(0, &.{ecl.Path.item(state.record)})) {
        .item => |item| item,
        .yield_required => return .{ .failed = .yield },
        .invalid => return .{ .failed = try call.fail(.shape, "csv.emit record is unreadable") },
    };
    if (record.kind() != .list)
        return .{ .failed = try call.fail(.type, "csv.emit expects every record to be a list") };
    const fields = record.aggregateLength().?;
    if (fields == 0)
        return .{ .failed = try call.fail(.shape, "csv.emit rejects a record with no fields") };
    state.field_count = fields;
    const field = switch (call.nested(0, &.{
        ecl.Path.item(state.record),
        ecl.Path.item(state.field),
    })) {
        .item => |item| item,
        .yield_required => return .{ .failed = .yield },
        .invalid => return .{ .failed = try call.fail(.shape, "csv.emit field is unreadable") },
    };
    if (field.kind() != .list)
        return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
    state.text_length = field.aggregateLength().?;
    return .{ .view = field };
}

fn measureStep(
    call: *ecl.Call("rows -- text"),
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!StepOutcome {
    switch (try fieldView(call, state)) {
        .failed => |outcome| return .{ .failed = outcome },
        .view => {},
    }
    // One whole field per step: its length is already known, so the scan is
    // bounded by the field and charged by the nested reads it makes.
    var quoted = false;
    var body: u64 = 0;
    var index: u64 = 0;
    while (index != state.text_length) : (index += 1) {
        const cell = switch (call.nested(0, &.{
            ecl.Path.item(state.record),
            ecl.Path.item(state.field),
            ecl.Path.item(index),
        })) {
            .item => |item| item,
            .yield_required => return .{ .failed = .yield },
            .invalid => return .{ .failed = try call.fail(.shape, "csv.emit cell is unreadable") },
        };
        const codepoint = cell.char() orelse
            return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
        if (requiresQuoting(codepoint)) quoted = true;
        body += if (codepoint == '"') 2 else 1;
    }
    state.emitted += if (quoted) body + 2 else body;
    // A comma between fields, CRLF after the last one.
    state.emitted += if (state.field + 1 == state.field_count) 2 else 1;
    state.field += 1;
    if (state.field == state.field_count) {
        state.field = 0;
        state.record += 1;
    }
    return .keep_going;
}

fn renderStep(
    call: *ecl.Call("rows -- text"),
    build: *ecl.BuildValues,
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!StepOutcome {
    // Field widths and the quoting decision are cached in state, so only the
    // first step of a field pays for reading them back.
    if (state.part == .open_quote) {
        switch (try fieldView(call, state)) {
            .failed => |outcome| return .{ .failed = outcome },
            .view => {},
        }
        switch (try quotingRequired(call, state)) {
            .failed => |outcome| return .{ .failed = outcome },
            .required => |required| state.quoted = required,
        }
        state.part = .body;
        if (state.quoted) return append(build, state, '"');
    }
    switch (state.part) {
        .open_quote => unreachable,
        .body, .doubled_quote => {
            if (state.character == state.text_length) {
                state.part = .close_quote;
                return .keep_going;
            }
            const cell = switch (call.nested(0, &.{
                ecl.Path.item(state.record),
                ecl.Path.item(state.field),
                ecl.Path.item(state.character),
            })) {
                .item => |item| item,
                .yield_required => return .{ .failed = .yield },
                .invalid => return .{ .failed = try call.fail(.shape, "csv.emit cell is unreadable") },
            };
            const codepoint = cell.char() orelse
                return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
            const doubling = codepoint == '"' and state.part == .body;
            const outcome = try append(build, state, codepoint);
            if (outcome == .failed) return outcome;
            // A quote inside a quoted field is written twice, which is two
            // separate appends so a yield between them repeats neither.
            if (doubling) {
                state.part = .doubled_quote;
                return .keep_going;
            }
            state.part = .body;
            state.character += 1;
        },
        .close_quote => {
            state.part = if (state.field + 1 == state.field_count) .terminator_cr else .comma;
            if (state.quoted) return append(build, state, '"');
        },
        .comma => {
            const outcome = try append(build, state, ',');
            if (outcome == .failed) return outcome;
            advanceField(state);
        },
        .terminator_cr => {
            const outcome = try append(build, state, '\r');
            if (outcome == .failed) return outcome;
            state.part = .terminator_lf;
        },
        .terminator_lf => {
            const outcome = try append(build, state, '\n');
            if (outcome == .failed) return outcome;
            advanceField(state);
        },
    }
    return .keep_going;
}

fn advanceField(state: *EmitWork.State) void {
    state.character = 0;
    state.part = .open_quote;
    state.field += 1;
    if (state.field == state.field_count) {
        state.field = 0;
        state.record += 1;
    }
}

/// A field must be quoted exactly when it contains a comma, a quote, a
/// carriage return, or a newline. Both passes derive this the same way, which
/// is what keeps the measured length and the rendered length equal.
fn quotingRequired(
    call: *ecl.Call("rows -- text"),
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!union(enum) { required: bool, failed: ecl.Outcome } {
    var index: u64 = 0;
    while (index != state.text_length) : (index += 1) {
        const cell = switch (call.nested(0, &.{
            ecl.Path.item(state.record),
            ecl.Path.item(state.field),
            ecl.Path.item(index),
        })) {
            .item => |item| item,
            .yield_required => return .{ .failed = .yield },
            .invalid => return .{ .failed = try call.fail(.shape, "csv.emit cell is unreadable") },
        };
        const codepoint = cell.char() orelse
            return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
        if (requiresQuoting(codepoint)) return .{ .required = true };
    }
    return .{ .required = false };
}

fn append(
    build: *ecl.BuildValues,
    state: *EmitWork.State,
    codepoint: u32,
) error{ OutOfMemory, InvalidValue }!StepOutcome {
    const item = try build.scalar(ecl.Scalar.char(codepoint));
    return switch (try build.appendList(output_slot, state.characters, item)) {
        .appended => appended: {
            state.emitted += 1;
            break :appended .keep_going;
        },
        .yield_required => .{ .failed = .yield },
        .invalid => .{ .failed = .fail },
    };
}
