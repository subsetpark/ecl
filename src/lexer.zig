//! UTF-8 cursor, source spans, diagnostics, and whole-token classification.

const std = @import("std");

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
        std.debug.assert(std.unicode.utf8ValidateSlice(source));
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
        var copy = self.*;
        for (0..offset) |_| _ = copy.bump() orelse return null;
        return copy.peek();
    }

    pub fn bump(self: *Cursor) ?u21 {
        const codepoint = self.peek() orelse return null;
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
        while (true) {
            while (self.peek()) |codepoint| {
                if (!isWhitespace(codepoint) and codepoint != ',') break;
                _ = self.bump();
            }
            if (self.peek() != '#') return;
            while (self.peek()) |codepoint| {
                if (codepoint == '\n') break;
                _ = self.bump();
            }
        }
    }

    /// Takes one maximal atom token. Quote and backslash dispatch only when
    /// token-initial; inside a token, symbol validation diagnoses them.
    pub fn takeToken(self: *Cursor) []const u8 {
        const start = self.index;
        while (self.peek()) |codepoint| {
            if (isTokenBoundary(codepoint) or
                codepoint == ';' or codepoint == '|') break;
            _ = self.bump();
        }
        return self.source[start..self.index];
    }
};

pub fn classify(token: []const u8) Classification {
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
        if (digits.len == 0 or !allHexDigits(digits)) return .word;
        const magnitude = parseMagnitude(digits, 16) orelse
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

    if (validDecimalInt(unsigned)) {
        const magnitude = parseMagnitudeSkippingUnderscores(unsigned, 10) orelse
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

    if (validFloat(unsigned)) {
        const number = std.fmt.parseFloat(f64, token) catch
            return .{ .out_of_range = .float };
        if (!std.math.isFinite(number)) return .{ .out_of_range = .float };
        return .{ .float = number };
    }
    return .word;
}

pub fn validSymbol(token: []const u8) bool {
    if (token.len == 0 or token[0] == '\'' or token[0] == '\\') return false;
    if (token[0] == '.' or token[token.len - 1] == '.') return false;
    var previous_dot = false;
    for (token) |byte| {
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

fn validDecimalInt(token: []const u8) bool {
    var previous_digit = false;
    var any = false;
    for (token) |byte| {
        if (std.ascii.isDigit(byte)) {
            any = true;
            previous_digit = true;
        } else if (byte == '_' and previous_digit) {
            previous_digit = false;
        } else return false;
    }
    return any and previous_digit;
}

fn validFloat(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '_') != null) return false;
    var exponent_index: ?usize = null;
    for (token, 0..) |byte, index| {
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
        if (exponent.len == 0 or !allDecimalDigits(exponent)) return false;
    }

    const dot = std.mem.indexOfScalar(u8, mantissa, '.');
    if (dot) |index| {
        if (std.mem.indexOfScalarPos(u8, mantissa, index + 1, '.') != null) return false;
        if (index == 0 or index + 1 == mantissa.len) return false;
        if (!allDecimalDigits(mantissa[0..index]) or
            !allDecimalDigits(mantissa[index + 1 ..])) return false;
    } else if (!allDecimalDigits(mantissa)) return false;
    return dot != null or exponent_index != null;
}

fn allDecimalDigits(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn allHexDigits(bytes: []const u8) bool {
    for (bytes) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn parseMagnitude(bytes: []const u8, base: u8) ?u64 {
    var result: u64 = 0;
    for (bytes) |byte| {
        const digit = std.fmt.charToDigit(byte, base) catch return null;
        result = std.math.mul(u64, result, base) catch return null;
        result = std.math.add(u64, result, digit) catch return null;
    }
    return result;
}

fn parseMagnitudeSkippingUnderscores(bytes: []const u8, base: u8) ?u64 {
    var result: u64 = 0;
    for (bytes) |byte| {
        if (byte == '_') continue;
        const digit = std.fmt.charToDigit(byte, base) catch return null;
        result = std.math.mul(u64, result, base) catch return null;
        result = std.math.add(u64, result, digit) catch return null;
    }
    return result;
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
