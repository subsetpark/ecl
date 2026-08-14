//! UTF-8 cursor, source spans, diagnostics, and whole-token classification.

const std = @import("std");
const poll = @import("poll.zig");

pub const Span = struct {
    line: u32 = 1,
    col: u32 = 1,
};

/// Allocation-free parse diagnostic storage. Messages longer than the fixed
/// buffer fall back to a stable generic diagnostic rather than allocating on
/// an error path.
pub const Diag = struct {
    span: Span = .{},
    message_buffer: [512]u8 = [_]u8{0} ** 512,
    message_len: usize = 0,

    pub fn text(self: *const Diag) []const u8 {
        return self.message_buffer[0..self.message_len];
    }

    pub fn set(self: *Diag, span: Span, message: []const u8) void {
        self.span = span;
        if (message.len > self.message_buffer.len) {
            const fallback = "parse error (diagnostic too long)";
            @memcpy(self.message_buffer[0..fallback.len], fallback);
            self.message_len = fallback.len;
            return;
        }
        @memcpy(self.message_buffer[0..message.len], message);
        self.message_len = message.len;
    }

    pub fn setFmt(
        self: *Diag,
        span: Span,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.span = span;
        const rendered = std.fmt.bufPrint(&self.message_buffer, format, args) catch {
            self.set(span, "parse error (diagnostic too long)");
            return;
        };
        self.message_len = rendered.len;
    }
};

pub const NumberKind = enum { integer, float };

pub const Classification = union(enum) {
    int: i64,
    float: f64,
    word,
    out_of_range: NumberKind,
};

/// Cursor positions count Unicode scalar values, matching the language's
/// codepoint semantics. Construct only after `utf8ValidateSlice` succeeds.
pub const Cursor = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    col: u32 = 1,

    pub fn init(source: []const u8) Cursor {
        return .{ .source = source };
    }

    pub fn atEnd(self: *const Cursor) bool {
        return self.index == self.source.len;
    }

    pub fn span(self: *const Cursor) Span {
        return .{ .line = self.line, .col = self.col };
    }

    pub fn byteIndex(self: *const Cursor) usize {
        return self.index;
    }

    pub fn peek(self: *const Cursor) ?u21 {
        if (self.atEnd()) return null;
        const length = std.unicode.utf8ByteSequenceLength(self.source[self.index]) catch
            @panic("validated UTF-8 cursor reached an invalid start byte");
        return std.unicode.utf8Decode(self.source[self.index..][0..length]) catch
            @panic("validated UTF-8 cursor reached an invalid sequence");
    }

    pub fn peekN(self: *const Cursor, offset: usize) ?u21 {
        return self.peekNPolling(offset, .unlimited()) catch @panic("non-polling lexer cursor failed");
    }

    pub fn peekNPolling(self: *const Cursor, offset: usize, work: poll.WorkContext) poll.Error!?u21 {
        var copy = self.*;
        for (0..offset) |_| _ = try copy.bumpPolling(work) orelse return null;
        return copy.peek();
    }

    pub fn bump(self: *Cursor) ?u21 {
        return self.bumpPolling(.unlimited()) catch @panic("non-polling lexer cursor failed");
    }

    pub fn bumpPolling(self: *Cursor, work: poll.WorkContext) poll.Error!?u21 {
        const codepoint = self.peek() orelse return null;
        try work.step();
        const length = std.unicode.utf8ByteSequenceLength(self.source[self.index]) catch
            @panic("validated UTF-8 cursor reached an invalid start byte");
        self.index += length;
        if (codepoint == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return codepoint;
    }

    pub fn skipIgnored(self: *Cursor) void {
        self.skipIgnoredPolling(.unlimited()) catch @panic("non-polling lexer cursor failed");
    }

    pub fn skipIgnoredPolling(self: *Cursor, work: poll.WorkContext) poll.Error!void {
        while (true) {
            while (self.peek()) |codepoint| {
                if (!isWhitespace(codepoint) and codepoint != ',') break;
                _ = try self.bumpPolling(work);
            }
            if (self.peek() != '#') return;
            while (self.peek()) |codepoint| {
                if (codepoint == '\n') break;
                _ = try self.bumpPolling(work);
            }
        }
    }

    /// Takes one maximal atom token. Quote and backslash dispatch only when
    /// token-initial; inside a token, symbol validation diagnoses them.
    pub fn takeToken(self: *Cursor) []const u8 {
        return self.takeTokenPolling(.unlimited()) catch @panic("non-polling lexer cursor failed");
    }

    pub fn takeTokenPolling(self: *Cursor, work: poll.WorkContext) poll.Error![]const u8 {
        const start = self.index;
        while (self.peek()) |codepoint| {
            if (isTokenBoundary(codepoint) or
                codepoint == ';' or codepoint == '|') break;
            _ = try self.bumpPolling(work);
        }
        return self.source[start..self.index];
    }
};

pub fn classify(token: []const u8) Classification {
    return classifyPolling(token, .unlimited()) catch unreachable;
}

pub fn classifyPolling(token: []const u8, work: poll.WorkContext) poll.Error!Classification {
    if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) {
        return .{ .float = std.math.inf(f64) };
    }
    if (std.mem.eql(u8, token, "-inf")) return .{ .float = -std.math.inf(f64) };

    var unsigned = token;
    var negative = false;
    if (unsigned.len > 1 and (unsigned[0] == '+' or unsigned[0] == '-')) {
        negative = unsigned[0] == '-';
        unsigned = unsigned[1..];
    }

    if (std.mem.startsWith(u8, unsigned, "0x")) {
        const digits = unsigned[2..];
        if (digits.len == 0 or !try allHexDigitsPolling(digits, work)) return .word;
        const magnitude = (try parseMagnitudePolling(digits, 16, work)) orelse
            return .{ .out_of_range = .integer };
        if (negative) {
            const min_magnitude = @as(u64, std.math.maxInt(i64)) + 1;
            if (magnitude == min_magnitude) return .{ .int = std.math.minInt(i64) };
            if (magnitude > std.math.maxInt(i64)) return .{ .out_of_range = .integer };
            return .{ .int = -@as(i64, @intCast(magnitude)) };
        }
        if (magnitude > std.math.maxInt(i64)) return .{ .out_of_range = .integer };
        return .{ .int = @intCast(magnitude) };
    }

    if (try validDecimalIntPolling(unsigned, work)) {
        const magnitude = (try parseMagnitudeSkippingUnderscoresPolling(unsigned, 10, work)) orelse
            return .{ .out_of_range = .integer };
        if (negative) {
            const min_magnitude = @as(u64, std.math.maxInt(i64)) + 1;
            if (magnitude == min_magnitude) return .{ .int = std.math.minInt(i64) };
            if (magnitude > std.math.maxInt(i64)) return .{ .out_of_range = .integer };
            return .{ .int = -@as(i64, @intCast(magnitude)) };
        }
        if (magnitude > std.math.maxInt(i64)) return .{ .out_of_range = .integer };
        return .{ .int = @intCast(magnitude) };
    }

    if (try validFloatPolling(unsigned, work)) {
        const number = parseFloatPolling(token, work) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => return error.Ecl,
            error.InvalidCharacter => return .{ .out_of_range = .float },
        };
        if (!std.math.isFinite(number)) return .{ .out_of_range = .float };
        return .{ .float = number };
    }
    return .word;
}

pub fn validSymbol(token: []const u8) bool {
    return validSymbolPolling(token, .unlimited()) catch unreachable;
}

pub fn validSymbolPolling(token: []const u8, work: poll.WorkContext) poll.Error!bool {
    if (token.len == 0 or token[0] == '\'' or token[0] == '\\') return false;
    if (token[0] == '.' or token[token.len - 1] == '.') return false;
    var previous_dot = false;
    for (token) |byte| {
        try work.step();
        if (byte == '.') {
            if (previous_dot) return false;
            previous_dot = true;
            continue;
        }
        previous_dot = false;
        if (byte < 0x80 and (std.ascii.isWhitespace(byte) or
            byte == ',' or switch (byte) {
            '(', ')', '[', ']', '{', '}', '"', '#', '\'', '\\', ';', '|' => true,
            else => false,
        })) return false;
    }
    return true;
}

pub fn isTokenBoundary(codepoint: u21) bool {
    return isWhitespace(codepoint) or codepoint == ',' or switch (codepoint) {
        '(', ')', '[', ']', '{', '}', '"', '#' => true,
        else => false,
    };
}

pub fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d,
        0x0020,
        0x0085,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

fn validDecimalIntPolling(token: []const u8, work: poll.WorkContext) poll.Error!bool {
    var previous_digit = false;
    var any = false;
    for (token) |byte| {
        try work.step();
        if (std.ascii.isDigit(byte)) {
            any = true;
            previous_digit = true;
        } else if (byte == '_' and previous_digit) {
            previous_digit = false;
        } else return false;
    }
    return any and previous_digit;
}

fn validFloatPolling(token: []const u8, work: poll.WorkContext) poll.Error!bool {
    var exponent_index: ?usize = null;
    for (token, 0..) |byte, index| {
        try work.step();
        if (byte == '_') return false;
        if (byte != 'e' and byte != 'E') continue;
        if (exponent_index != null) return false;
        exponent_index = index;
    }
    const mantissa = token[0 .. exponent_index orelse token.len];
    if (exponent_index) |index| {
        var exponent = token[index + 1 ..];
        if (exponent.len > 0 and (exponent[0] == '+' or exponent[0] == '-')) {
            exponent = exponent[1..];
        }
        if (exponent.len == 0 or !try allDecimalDigitsPolling(exponent, work)) return false;
    }
    var dot: ?usize = null;
    for (mantissa, 0..) |byte, index| {
        try work.step();
        if (byte != '.') continue;
        if (dot != null) return false;
        dot = index;
    }
    if (dot) |index| {
        if (index == 0 or index + 1 == mantissa.len) return false;
        if (!try allDecimalDigitsPolling(mantissa[0..index], work) or
            !try allDecimalDigitsPolling(mantissa[index + 1 ..], work)) return false;
    } else if (!try allDecimalDigitsPolling(mantissa, work)) return false;
    return dot != null or exponent_index != null;
}

fn allDecimalDigitsPolling(bytes: []const u8, work: poll.WorkContext) poll.Error!bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| {
        try work.step();
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn allHexDigitsPolling(bytes: []const u8, work: poll.WorkContext) poll.Error!bool {
    for (bytes) |byte| {
        try work.step();
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn parseMagnitudePolling(bytes: []const u8, base: u8, work: poll.WorkContext) poll.Error!?u64 {
    var result: u64 = 0;
    for (bytes) |byte| {
        try work.step();
        const digit = std.fmt.charToDigit(byte, base) catch return null;
        result = std.math.mul(u64, result, base) catch return null;
        result = std.math.add(u64, result, digit) catch return null;
    }
    return result;
}

fn parseMagnitudeSkippingUnderscoresPolling(
    bytes: []const u8,
    base: u8,
    work: poll.WorkContext,
) poll.Error!?u64 {
    var result: u64 = 0;
    for (bytes) |byte| {
        try work.step();
        if (byte == '_') continue;
        const digit = std.fmt.charToDigit(byte, base) catch return null;
        result = std.math.mul(u64, result, base) catch return null;
        result = std.math.add(u64, result, digit) catch return null;
    }
    return result;
}

fn parseFloatPolling(
    token: []const u8,
    work: poll.WorkContext,
) (poll.Error || std.fmt.ParseFloatError)!f64 {
    const bounded_scan = 4096;
    if (token.len <= bounded_scan) return std.fmt.parseFloat(f64, token);

    const negative = token[0] == '-';
    const mantissa_start: usize = @intFromBool(token[0] == '-' or token[0] == '+');
    var exponent_start = token.len;
    for (token[mantissa_start..], mantissa_start..) |byte, index| {
        try work.step();
        if (byte == 'e' or byte == 'E') {
            exponent_start = index;
            break;
        }
    }
    var explicit_exponent: i64 = 0;
    if (exponent_start < token.len) {
        var index = exponent_start + 1;
        const exponent_negative = token[index] == '-';
        if (token[index] == '-' or token[index] == '+') index += 1;
        while (index < token.len) : (index += 1) {
            try work.step();
            explicit_exponent = @min(
                1_000_000,
                explicit_exponent * 10 + @as(i64, token[index] - '0'),
            );
        }
        if (exponent_negative) explicit_exponent = -explicit_exponent;
    }

    const significant_limit = 1024;
    var significant: [significant_limit + 1]u8 = undefined;
    var significant_len: usize = 0;
    var omitted_nonzero = false;
    var digit_position: i64 = 0;
    var digits_before_dot: i64 = 0;
    var first_nonzero: ?i64 = null;
    var saw_dot = false;
    for (token[mantissa_start..exponent_start]) |byte| {
        try work.step();
        if (byte == '.') {
            saw_dot = true;
            digits_before_dot = digit_position;
            continue;
        }
        if (byte != '0' and first_nonzero == null) first_nonzero = digit_position;
        if (first_nonzero != null) {
            if (significant_len < significant_limit) {
                significant[significant_len] = byte;
                significant_len += 1;
            } else if (byte != '0') omitted_nonzero = true;
        }
        digit_position += 1;
    }
    if (!saw_dot) digits_before_dot = digit_position;
    if (first_nonzero == null) return if (negative) -0.0 else 0.0;
    if (omitted_nonzero) {
        significant[significant_len] = '1';
        significant_len += 1;
    }
    const exponent = std.math.clamp(
        explicit_exponent + digits_before_dot - first_nonzero.? - 1,
        -1_000_000,
        1_000_000,
    );
    var normalized: [significant_limit + 40]u8 = undefined;
    var output: usize = 0;
    if (negative) {
        normalized[output] = '-';
        output += 1;
    }
    normalized[output] = significant[0];
    output += 1;
    normalized[output] = '.';
    output += 1;
    @memcpy(normalized[output..][0 .. significant_len - 1], significant[1..significant_len]);
    output += significant_len - 1;
    const suffix = std.fmt.bufPrint(normalized[output..], "e{d}", .{exponent}) catch unreachable;
    output += suffix.len;
    return std.fmt.parseFloat(f64, normalized[0..output]);
}

test "token classification matrix" {
    try std.testing.expectEqual(@as(i64, -3), classify("-3").int);
    try std.testing.expectEqual(@as(i64, 1_000_000), classify("1_000_000").int);
    try std.testing.expectEqual(@as(i64, 16), classify("0x10").int);
    try std.testing.expectEqual(std.math.minInt(i64), classify("-0x8000000000000000").int);
    try std.testing.expectEqual(@as(f64, 3.5), classify("3.5").float);
    try std.testing.expectEqual(@as(f64, 2000.0), classify("2e3").float);
    try std.testing.expect(std.math.isPositiveInf(classify("+inf").float));
    try std.testing.expect(std.math.isNegativeInf(classify("-inf").float));
    try std.testing.expect(classify("2dup") == .word);
    try std.testing.expect(classify("1+") == .word);
    try std.testing.expect(classify("-") == .word);
    try std.testing.expect(classify(".5") == .word);
    try std.testing.expect(classify("5.") == .word);
    try std.testing.expectEqual(NumberKind.integer, classify("9223372036854775808").out_of_range);
    try std.testing.expectEqual(NumberKind.float, classify("1e9999").out_of_range);
}

test "long float normalization preserves scale without an unbounded library scan" {
    const allocator = std.testing.allocator;
    const zero_count = 5000;
    const token = try allocator.alloc(u8, 2 + zero_count + 1 + 5);
    defer allocator.free(token);
    token[0] = '0';
    token[1] = '.';
    @memset(token[2 .. 2 + zero_count], '0');
    token[2 + zero_count] = '1';
    @memcpy(token[3 + zero_count ..], "e5000");
    try std.testing.expectEqual(@as(f64, 0.1), classify(token).float);
}

test "spans track lines and columns" {
    var cursor = Cursor.init("λ x\ny");
    try std.testing.expectEqual(Span{ .line = 1, .col = 1 }, cursor.span());
    _ = cursor.bump();
    try std.testing.expectEqual(Span{ .line = 1, .col = 2 }, cursor.span());
    _ = cursor.bump();
    _ = cursor.bump();
    _ = cursor.bump();
    try std.testing.expectEqual(Span{ .line = 2, .col = 1 }, cursor.span());
}

test "comments and comma whitespace" {
    var cursor = Cursor.init(" , # comment\n\u{2003}next");
    cursor.skipIgnored();
    try std.testing.expectEqual(Span{ .line = 2, .col = 2 }, cursor.span());
    try std.testing.expectEqualStrings("next", cursor.takeToken());
}
