//! Pure UTC time words: tagged Unix timestamps, checked millisecond
//! arithmetic, proleptic Gregorian calendar decomposition, and RFC 3339 text.
//!
//! Every quantity is a whole number of milliseconds. A timestamp is the
//! one-key dictionary `{'unix ms}`; a monotonic instant from `clock.now` is
//! `{'monotonic ms}`. The tag is the clock domain, and each word accepts only
//! its own, so an instant handed to `format` is a `'type` error rather than a
//! date in 1970. Nothing here reads a clock; the effectful words live in
//! `clock`.
const std = @import("std");
const dict = @import("../dict.zig");
const env = @import("../env.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const value = @import("../value.zig");

const Machine = machine.Machine;
const MachineError = machine.MachineError;
const Value = value.Value;

pub const words = [_]env.BuiltinWord{
    .{ .name = "add", .doc = "( timestamp milliseconds -- timestamp ) Shift a timestamp by a signed millisecond duration.", .primitive = add },
    .{ .name = "cmp", .doc = "( left right -- ordering ) Three-way compare two timestamps as -1, 0, or 1.", .primitive = cmp },
    .{ .name = "days", .doc = "( n -- milliseconds ) Convert whole days of 86,400 seconds to milliseconds.", .primitive = days },
    .{ .name = "diff", .doc = "( later earlier -- milliseconds ) Return later minus earlier in milliseconds.", .primitive = diff },
    .{ .name = "format", .doc = "( timestamp -- string ) Render a timestamp as YYYY-MM-DDTHH:MM:SS.mmmZ.", .primitive = format },
    .{ .name = "from-unix", .doc = "( milliseconds -- timestamp ) Tag an integer Unix millisecond count as {'unix milliseconds}.", .primitive = fromUnix },
    .{ .name = "from-utc", .doc = "( fields -- timestamp ) Build a timestamp from UTC calendar fields.", .primitive = fromUtc },
    .{ .name = "hours", .doc = "( n -- milliseconds ) Convert whole hours to milliseconds.", .primitive = hours },
    .{ .name = "minutes", .doc = "( n -- milliseconds ) Convert whole minutes to milliseconds.", .primitive = minutes },
    .{ .name = "parse", .doc = "( string -- timestamp ) Parse an RFC 3339 date-time, converting any offset to UTC.", .primitive = parse },
    .{ .name = "seconds", .doc = "( n -- milliseconds ) Convert whole seconds to milliseconds.", .primitive = seconds },
    .{ .name = "to-unix", .doc = "( timestamp -- milliseconds ) Return the Unix millisecond count inside a timestamp.", .primitive = toUnix },
    .{ .name = "to-utc", .doc = "( timestamp -- fields ) Decompose a timestamp into UTC calendar fields.", .primitive = toUtc },
};

/// The two clock domains a tagged value can name. The tag is the dictionary's
/// only key, so the two never compare equal and neither passes for the other.
pub const Domain = enum { unix, monotonic };

/// Build `{'<domain> milliseconds}`.
pub fn tagged(evaluator: *Machine, domain: Domain, milliseconds: i64) error{OutOfMemory}!Value {
    const key = try intern.intern(@tagName(domain));
    return dict.fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{
        .{ .{ .symbol = key }, .{ .int = milliseconds } },
    });
}

/// Read `{'<domain> milliseconds}`. Anything else, including a well-formed
/// value from the other domain, is null; callers turn that into `'type`.
pub fn untag(domain: Domain, item: Value) error{OutOfMemory}!?i64 {
    if (item != .dict) return null;
    const header = item.dict;
    if (header.length() != 1) return null;
    const key = dict.keyAt(header, 0);
    if (key != .symbol or key.symbol != try intern.intern(@tagName(domain))) return null;
    const payload = dict.valueAt(header, 0);
    if (payload != .int) return null;
    return payload.int;
}

const timestamp_expectation = "a {'unix milliseconds} timestamp";

fn popTimestamp(evaluator: *Machine) MachineError!i64 {
    var item = try evaluator.popValue();
    defer item.deinit();
    return (try untag(.unix, item.borrow())) orelse evaluator.typeError(timestamp_expectation);
}

fn popInt(evaluator: *Machine, expected: []const u8) MachineError!i64 {
    var item = try evaluator.popValue();
    defer item.deinit();
    if (item.borrow() != .int) return evaluator.typeError(expected);
    return item.borrow().int;
}

fn fromUnix(evaluator: *Machine) MachineError!void {
    const milliseconds = try popInt(evaluator, "an integer Unix millisecond count");
    try evaluator.pushOwned(try tagged(evaluator, .unix, milliseconds));
}

fn toUnix(evaluator: *Machine) MachineError!void {
    try evaluator.pushOwned(.{ .int = try popTimestamp(evaluator) });
}

fn add(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const duration = try popInt(evaluator, "a timestamp followed by integer milliseconds");
    const base = try popTimestamp(evaluator);
    const shifted = std.math.add(i64, base, duration) catch
        return evaluator.fail(.overflow, "time.add left the millisecond range");
    try evaluator.pushOwned(try tagged(evaluator, .unix, shifted));
}

fn diff(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const earlier = try popTimestamp(evaluator);
    const later = try popTimestamp(evaluator);
    const difference = std.math.sub(i64, later, earlier) catch
        return evaluator.fail(.overflow, "time.diff left the millisecond range");
    try evaluator.pushOwned(.{ .int = difference });
}

fn cmp(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try popTimestamp(evaluator);
    const left = try popTimestamp(evaluator);
    const ordering: i64 = if (left < right) -1 else if (left > right) 1 else 0;
    try evaluator.pushOwned(.{ .int = ordering });
}

fn scaled(evaluator: *Machine, comptime word: []const u8, comptime factor: i64) MachineError!void {
    const count = try popInt(evaluator, "an integer count");
    const milliseconds = std.math.mul(i64, count, factor) catch
        return evaluator.fail(.overflow, "time." ++ word ++ " left the millisecond range");
    try evaluator.pushOwned(.{ .int = milliseconds });
}

fn seconds(evaluator: *Machine) MachineError!void {
    return scaled(evaluator, "seconds", std.time.ms_per_s);
}

fn minutes(evaluator: *Machine) MachineError!void {
    return scaled(evaluator, "minutes", std.time.ms_per_min);
}

fn hours(evaluator: *Machine) MachineError!void {
    return scaled(evaluator, "hours", std.time.ms_per_hour);
}

fn days(evaluator: *Machine) MachineError!void {
    return scaled(evaluator, "days", std.time.ms_per_day);
}

// ── Proleptic Gregorian calendar ─────────────────────────────────────────

/// One decomposed UTC instant. `weekday` counts from Monday as 0.
const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,
    weekday: u8,
};

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable,
    };
}

/// Days since 1970-01-01 for a valid civil date (Hinnant's algorithm). The
/// arithmetic runs in i128 so any i64 year is representable; the caller
/// checks the final millisecond count against i64.
fn daysFromCivil(year: i64, month: u8, day: u8) i128 {
    const shifted_year: i128 = if (month <= 2) @as(i128, year) - 1 else year;
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const shifted_month: i128 = if (month > 2) @as(i128, month) - 3 else @as(i128, month) + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn civilFromDays(days_since_epoch: i64) struct { year: i64, month: u8, day: u8 } {
    const shifted: i128 = @as(i128, days_since_epoch) + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096),
        365,
    );
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1;
    const month: i128 = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
    const year = year_of_era + era * 400 + @as(i128, if (month <= 2) 1 else 0);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

fn civilFromMilliseconds(milliseconds: i64) Civil {
    // `@mod` never overflows, where `ms - days * ms_per_day` does at the
    // minimum int because the floored product lies below it.
    const day_count = @divFloor(milliseconds, std.time.ms_per_day);
    const remainder: u32 = @intCast(@mod(milliseconds, std.time.ms_per_day));
    const date = civilFromDays(day_count);
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .hour = @intCast(remainder / std.time.ms_per_hour),
        .minute = @intCast(remainder % std.time.ms_per_hour / std.time.ms_per_min),
        .second = @intCast(remainder % std.time.ms_per_min / std.time.ms_per_s),
        .millisecond = @intCast(remainder % std.time.ms_per_s),
        // 1970-01-01 was a Thursday, three days after Monday.
        .weekday = @intCast(@mod(day_count + 3, 7)),
    };
}

/// Milliseconds for validated fields, or null when the count leaves i64.
fn millisecondsFromCivil(civil: Civil) ?i64 {
    const day_count = daysFromCivil(civil.year, civil.month, civil.day);
    const total = day_count * std.time.ms_per_day +
        @as(i128, civil.hour) * std.time.ms_per_hour +
        @as(i128, civil.minute) * std.time.ms_per_min +
        @as(i128, civil.second) * std.time.ms_per_s +
        civil.millisecond;
    return std.math.cast(i64, total);
}

const Field = enum {
    year,
    month,
    day,
    hour,
    minute,
    second,
    millisecond,
    weekday,

    fn symbols() error{OutOfMemory}![std.enums.values(Field).len]u32 {
        var result: [std.enums.values(Field).len]u32 = undefined;
        inline for (std.enums.values(Field), 0..) |field, index|
            result[index] = try intern.intern(@tagName(field));
        return result;
    }
};

fn toUtc(evaluator: *Machine) MachineError!void {
    const civil = civilFromMilliseconds(try popTimestamp(evaluator));
    const symbols = try Field.symbols();
    const fields = try dict.fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{
        .{ .{ .symbol = symbols[@intFromEnum(Field.year)] }, .{ .int = civil.year } },
        .{ .{ .symbol = symbols[@intFromEnum(Field.month)] }, .{ .int = civil.month } },
        .{ .{ .symbol = symbols[@intFromEnum(Field.day)] }, .{ .int = civil.day } },
        .{ .{ .symbol = symbols[@intFromEnum(Field.hour)] }, .{ .int = civil.hour } },
        .{ .{ .symbol = symbols[@intFromEnum(Field.minute)] }, .{ .int = civil.minute } },
        .{ .{ .symbol = symbols[@intFromEnum(Field.second)] }, .{ .int = civil.second } },
        .{ .{ .symbol = symbols[@intFromEnum(Field.millisecond)] }, .{ .int = civil.millisecond } },
        .{ .{ .symbol = symbols[@intFromEnum(Field.weekday)] }, .{ .int = civil.weekday } },
    });
    try evaluator.pushOwned(fields);
}

fn fromUtc(evaluator: *Machine) MachineError!void {
    var fields = try evaluator.popValue();
    defer fields.deinit();
    if (fields.borrow() != .dict) return evaluator.typeError("a dictionary of UTC calendar fields");
    const header = fields.borrow().dict;
    const symbols = try Field.symbols();
    // Every key must be one of the eight field names; the dictionary is small
    // by construction, so this pass is bounded by the field count times the
    // entry count rather than by any program-sized input.
    const entry_count: usize = @intCast(header.length());
    var present = std.EnumArray(Field, ?i64).initFill(null);
    var index: usize = 0;
    while (index != entry_count) : (index += 1) {
        const key = dict.keyAt(header, index);
        if (key != .symbol) return evaluator.typeError("symbol field names");
        const field = for (std.enums.values(Field), 0..) |field, position| {
            if (symbols[position] == key.symbol) break field;
        } else return evaluator.fail(.domain, "time.from-utc accepts only year, month, day, hour, minute, second, millisecond, and weekday fields");
        const item = dict.valueAt(header, index);
        if (item != .int) return evaluator.typeError("integer calendar fields");
        present.set(field, item.int);
    }
    const year = present.get(.year) orelse return evaluator.fail(.domain, "time.from-utc requires year, month, and day");
    const month = present.get(.month) orelse return evaluator.fail(.domain, "time.from-utc requires year, month, and day");
    const day = present.get(.day) orelse return evaluator.fail(.domain, "time.from-utc requires year, month, and day");
    if (month < 1 or month > 12) return evaluator.fail(.domain, "time.from-utc month must be 1 through 12");
    if (day < 1 or day > daysInMonth(year, @intCast(month)))
        return evaluator.fail(.domain, "time.from-utc day is outside its month");
    const hour = present.get(.hour) orelse 0;
    const minute = present.get(.minute) orelse 0;
    const second = present.get(.second) orelse 0;
    const millisecond = present.get(.millisecond) orelse 0;
    if (hour < 0 or hour > 23) return evaluator.fail(.domain, "time.from-utc hour must be 0 through 23");
    if (minute < 0 or minute > 59) return evaluator.fail(.domain, "time.from-utc minute must be 0 through 59");
    if (second < 0 or second > 59) return evaluator.fail(.domain, "time.from-utc second must be 0 through 59; leap seconds are not representable");
    if (millisecond < 0 or millisecond > 999) return evaluator.fail(.domain, "time.from-utc millisecond must be 0 through 999");
    const civil: Civil = .{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .millisecond = @intCast(millisecond),
        .weekday = @intCast(@mod(daysFromCivil(year, @intCast(month), @intCast(day)) + 3, 7)),
    };
    if (present.get(.weekday)) |weekday| if (weekday != civil.weekday)
        return evaluator.fail(.domain, "time.from-utc weekday disagrees with the date");
    const milliseconds = millisecondsFromCivil(civil) orelse
        return evaluator.fail(.overflow, "time.from-utc left the millisecond range");
    try evaluator.pushOwned(try tagged(evaluator, .unix, milliseconds));
}

// ── RFC 3339 ─────────────────────────────────────────────────────────────

/// Longest accepted text: a nine-digit fraction and a numeric offset.
const max_rfc3339_len = "YYYY-MM-DDTHH:MM:SS.nnnnnnnnn+HH:MM".len;

const Rfc3339Error = error{ Malformed, FieldRange };

const Rfc3339Cursor = struct {
    text: []const u8,
    index: usize = 0,

    fn digits(self: *Rfc3339Cursor, comptime count: usize) Rfc3339Error!u32 {
        if (self.text.len - self.index < count) return error.Malformed;
        var result: u32 = 0;
        for (self.text[self.index..][0..count]) |byte| {
            if (byte < '0' or byte > '9') return error.Malformed;
            result = result * 10 + (byte - '0');
        }
        self.index += count;
        return result;
    }

    fn expect(self: *Rfc3339Cursor, byte: u8) Rfc3339Error!void {
        if (self.index == self.text.len or self.text[self.index] != byte) return error.Malformed;
        self.index += 1;
    }

    fn peek(self: *const Rfc3339Cursor) ?u8 {
        return if (self.index == self.text.len) null else self.text[self.index];
    }
};

/// `date-time` from RFC 3339 section 5.6: `T` and `Z` may be lower case, the
/// fraction has one or more digits of which the first three are kept, and a
/// numeric offset is subtracted to reach UTC. Second 60 is out of range
/// because Unix time has no leap seconds.
fn parseRfc3339(text: []const u8) Rfc3339Error!i64 {
    var cursor: Rfc3339Cursor = .{ .text = text };
    const year = try cursor.digits(4);
    try cursor.expect('-');
    const month = try cursor.digits(2);
    try cursor.expect('-');
    const day = try cursor.digits(2);
    switch (cursor.peek() orelse return error.Malformed) {
        'T', 't' => cursor.index += 1,
        else => return error.Malformed,
    }
    const hour = try cursor.digits(2);
    try cursor.expect(':');
    const minute = try cursor.digits(2);
    try cursor.expect(':');
    const second = try cursor.digits(2);
    var millisecond: u32 = 0;
    if (cursor.peek() == '.') {
        cursor.index += 1;
        var digit_count: usize = 0;
        var weight: u32 = 100;
        while (cursor.peek()) |byte| : (cursor.index += 1) {
            if (byte < '0' or byte > '9') break;
            if (digit_count < 3) millisecond += (byte - '0') * weight;
            weight /= 10;
            digit_count += 1;
        }
        if (digit_count == 0) return error.Malformed;
    }
    var offset_milliseconds: i64 = 0;
    switch (cursor.peek() orelse return error.Malformed) {
        'Z', 'z' => cursor.index += 1,
        '+', '-' => |sign| {
            cursor.index += 1;
            const offset_hour = try cursor.digits(2);
            try cursor.expect(':');
            const offset_minute = try cursor.digits(2);
            if (offset_hour > 23 or offset_minute > 59) return error.FieldRange;
            const magnitude: i64 = @as(i64, offset_hour) * std.time.ms_per_hour +
                @as(i64, offset_minute) * std.time.ms_per_min;
            offset_milliseconds = if (sign == '+') magnitude else -magnitude;
        },
        else => return error.Malformed,
    }
    if (cursor.index != text.len) return error.Malformed;
    if (month < 1 or month > 12) return error.FieldRange;
    if (day < 1 or day > daysInMonth(year, @intCast(month))) return error.FieldRange;
    if (hour > 23 or minute > 59 or second > 59) return error.FieldRange;
    const local = millisecondsFromCivil(.{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .millisecond = @intCast(millisecond),
        .weekday = 0,
    }) orelse unreachable;
    // Four-digit years keep every intermediate far inside i64.
    return local - offset_milliseconds;
}

fn parse(evaluator: *Machine) MachineError!void {
    var text = try evaluator.popString();
    defer text.deinit();
    const malformed = "time.parse expected an RFC 3339 date-time such as 1970-01-01T00:00:00Z";
    const length = text.borrow().list.length();
    if (length > max_rfc3339_len) return evaluator.fail(.parse, malformed);
    // The grammar is ASCII, so the bounded copy needs no encoder; any other
    // scalar makes the text malformed before a byte is inspected.
    var buffer: [max_rfc3339_len]u8 = undefined;
    var index: usize = 0;
    while (index != length) : (index += 1) {
        const codepoint = list.atUnchecked(text.borrow(), index).char;
        if (codepoint >= 0x80) return evaluator.fail(.parse, malformed);
        buffer[index] = @intCast(codepoint);
    }
    const milliseconds = parseRfc3339(buffer[0..index]) catch |err| switch (err) {
        error.Malformed => return evaluator.fail(.parse, malformed),
        error.FieldRange => return evaluator.fail(.domain, "time.parse found a calendar field outside its range"),
    };
    try evaluator.pushOwned(try tagged(evaluator, .unix, milliseconds));
}

fn format(evaluator: *Machine) MachineError!void {
    const civil = civilFromMilliseconds(try popTimestamp(evaluator));
    if (civil.year < 0 or civil.year > 9999)
        return evaluator.fail(.domain, "time.format requires a year from 0000 through 9999");
    // The range check above makes the year unsigned; a signed operand would
    // render its sign into the zero padding.
    const year: u16 = @intCast(civil.year);
    var buffer: [max_rfc3339_len]u8 = undefined;
    const rendered = std.fmt.bufPrint(
        &buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{ year, civil.month, civil.day, civil.hour, civil.minute, civil.second, civil.millisecond },
    ) catch |err| switch (err) {
        // 24 bytes of output into a buffer sized for the longest parse input.
        error.NoSpaceLeft => unreachable,
    };
    try evaluator.pushOwned(try machine.stringValue(evaluator.allocator(), evaluator.releaseDomain(), rendered));
}
