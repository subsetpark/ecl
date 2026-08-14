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
        var ignored = IgnoredCursor{ .source = self };
        while (ignored.advance() == .pending) {}
    }

    /// Takes one maximal atom token. Quote and backslash dispatch only when
    /// token-initial; inside a token, symbol validation diagnoses them.
    pub fn takeToken(self: *Cursor) []const u8 {
        var token = TokenCursor.init(self);
        while (true) switch (token.advance()) {
            .pending => {},
            .complete => |bytes| return bytes,
        };
    }
};

pub const ScanProgress = enum { pending, complete };
pub const IgnoredCursor = struct {
    source: *Cursor,
    comment: bool = false,
    pub fn advance(self: *IgnoredCursor) ScanProgress {
        const next = self.source.peek() orelse return .complete;
        if (self.comment) {
            if (next == '\n') self.comment = false else _ = self.source.bump();
            return .pending;
        }
        if (isWhitespace(next) or next == ',') {
            _ = self.source.bump();
            return .pending;
        }
        if (next == '#') {
            _ = self.source.bump();
            self.comment = true;
            return .pending;
        }
        return .complete;
    }
};

pub const TokenProgress = union(enum) { pending, complete: []const u8 };
pub const TokenCursor = struct {
    source: *Cursor,
    start: usize,
    pub fn init(source: *Cursor) TokenCursor {
        return .{ .source = source, .start = source.index };
    }
    pub fn advance(self: *TokenCursor) TokenProgress {
        const next = self.source.peek() orelse
            return .{ .complete = self.source.source[self.start..self.source.index] };
        if (isTokenBoundary(next) or next == ';' or next == '|')
            return .{ .complete = self.source.source[self.start..self.source.index] };
        _ = self.source.bump();
        return .pending;
    }
};

pub fn classify(token: []const u8) Classification {
    var cursor = ClassifyCursor.init(token);
    while (true) switch (cursor.advance()) {
        .pending => {},
        .complete => |classification| return classification,
    };
}

pub fn validSymbol(token: []const u8) bool {
    var cursor = SymbolCursor.init(token);
    while (true) switch (cursor.advance()) {
        .pending => {},
        .complete => |valid| return valid,
    };
}

pub const SymbolProgress = union(enum) { pending, complete: bool };
pub const SymbolCursor = struct {
    token: []const u8,
    index: usize = 0,
    previous_dot: bool = false,
    pub fn init(token: []const u8) SymbolCursor {
        return .{ .token = token };
    }
    pub fn advance(self: *SymbolCursor) SymbolProgress {
        if (self.token.len == 0 or self.token[0] == '\'' or self.token[0] == '\\' or
            self.token[0] == '.' or self.token[self.token.len - 1] == '.')
            return .{ .complete = false };
        if (self.index == self.token.len) return .{ .complete = true };
        const byte = self.token[self.index];
        self.index += 1;
        if (byte == '.') {
            if (self.previous_dot) return .{ .complete = false };
            self.previous_dot = true;
            return .pending;
        }
        self.previous_dot = false;
        if (byte < 0x80 and (std.ascii.isWhitespace(byte) or byte == ',' or switch (byte) {
            '(', ')', '[', ']', '{', '}', '"', '#', '\'', '\\', ';', '|' => true,
            else => false,
        })) return .{ .complete = false };
        return .pending;
    }
};

pub const ClassifyProgress = union(enum) { pending, complete: Classification };
pub const ClassifyCursor = struct {
    token: []const u8,
    unsigned: []const u8,
    negative: bool,
    index: usize = 0,
    hex: bool,
    decimal_valid: bool = true,
    decimal_any: bool = false,
    decimal_previous_digit: bool = false,
    magnitude: u64 = 0,
    magnitude_overflow: bool = false,
    float_valid: bool = true,
    dot_seen: bool = false,
    exponent_seen: bool = false,
    mantissa_before: usize = 0,
    mantissa_after: usize = 0,
    exponent_digits: usize = 0,
    exponent_sign_seen: bool = false,
    exponent_negative: bool = false,
    explicit_exponent: i64 = 0,
    significand: u64 = 0,
    significand_digits: usize = 0,
    significant_started: bool = false,
    total_significant: usize = 0,
    round_up: bool = false,

    pub fn init(token: []const u8) ClassifyCursor {
        var unsigned = token;
        var negative = false;
        if (unsigned.len > 1 and (unsigned[0] == '+' or unsigned[0] == '-')) {
            negative = unsigned[0] == '-';
            unsigned = unsigned[1..];
        }
        const hex = std.mem.startsWith(u8, unsigned, "0x");
        return .{
            .token = token,
            .unsigned = if (hex) unsigned[2..] else unsigned,
            .negative = negative,
            .hex = hex,
        };
    }
    fn finishInteger(self: *ClassifyCursor) Classification {
        if (self.magnitude_overflow) return .{ .out_of_range = .integer };
        if (self.negative) {
            const min_magnitude = @as(u64, std.math.maxInt(i64)) + 1;
            if (self.magnitude == min_magnitude) return .{ .int = std.math.minInt(i64) };
            if (self.magnitude > std.math.maxInt(i64)) return .{ .out_of_range = .integer };
            return .{ .int = -@as(i64, @intCast(self.magnitude)) };
        }
        if (self.magnitude > std.math.maxInt(i64)) return .{ .out_of_range = .integer };
        return .{ .int = @intCast(self.magnitude) };
    }
    fn finishFloat(self: *ClassifyCursor) Classification {
        if (!self.float_valid or self.mantissa_before == 0 or
            (self.dot_seen and self.mantissa_after == 0) or
            (self.exponent_seen and self.exponent_digits == 0) or
            (!self.dot_seen and !self.exponent_seen)) return .word;
        const omitted = self.total_significant - self.significand_digits;
        var significand = self.significand;
        if (self.round_up and significand != std.math.maxInt(u64)) significand += 1;
        const fraction_digits: i64 = @intCast(self.mantissa_after);
        const exponent = (if (self.exponent_negative) -self.explicit_exponent else self.explicit_exponent) -
            fraction_digits + @as(i64, @intCast(omitted));
        var number = @as(f64, @floatFromInt(significand)) * std.math.pow(f64, 10.0, @floatFromInt(exponent));
        if (self.negative) number = -number;
        return if (std.math.isFinite(number)) .{ .float = number } else .{ .out_of_range = .float };
    }
    pub fn advance(self: *ClassifyCursor) ClassifyProgress {
        if (std.mem.eql(u8, self.token, "inf") or std.mem.eql(u8, self.token, "+inf"))
            return .{ .complete = .{ .float = std.math.inf(f64) } };
        if (std.mem.eql(u8, self.token, "-inf"))
            return .{ .complete = .{ .float = -std.math.inf(f64) } };
        if (self.index == self.unsigned.len) {
            if (self.hex)
                return .{ .complete = if (self.unsigned.len != 0 and self.decimal_valid)
                    self.finishInteger()
                else
                    .word };
            if (self.decimal_valid and self.decimal_any and self.decimal_previous_digit)
                return .{ .complete = self.finishInteger() };
            return .{ .complete = self.finishFloat() };
        }
        const byte = self.unsigned[self.index];
        self.index += 1;
        if (self.hex) {
            const digit = std.fmt.charToDigit(byte, 16) catch {
                self.decimal_valid = false;
                return .pending;
            };
            self.magnitude = std.math.mul(u64, self.magnitude, 16) catch overflow: {
                self.magnitude_overflow = true;
                break :overflow self.magnitude;
            };
            if (!self.magnitude_overflow) self.magnitude = std.math.add(u64, self.magnitude, digit) catch overflow: {
                self.magnitude_overflow = true;
                break :overflow self.magnitude;
            };
            return .pending;
        }
        if (std.ascii.isDigit(byte)) {
            self.decimal_any = true;
            self.decimal_previous_digit = true;
            if (!self.magnitude_overflow) {
                self.magnitude = std.math.mul(u64, self.magnitude, 10) catch overflow: {
                    self.magnitude_overflow = true;
                    break :overflow self.magnitude;
                };
                if (!self.magnitude_overflow) self.magnitude = std.math.add(u64, self.magnitude, byte - '0') catch overflow: {
                    self.magnitude_overflow = true;
                    break :overflow self.magnitude;
                };
            }
            if (self.exponent_seen) {
                self.exponent_digits += 1;
                self.explicit_exponent = @min(1_000_000, self.explicit_exponent * 10 + byte - '0');
            } else {
                if (self.dot_seen) self.mantissa_after += 1 else self.mantissa_before += 1;
                if (byte != '0' or self.significant_started) {
                    self.significant_started = true;
                    self.total_significant += 1;
                    if (self.significand_digits < 19) {
                        self.significand = self.significand * 10 + byte - '0';
                        self.significand_digits += 1;
                    } else if (self.total_significant == 20 and byte >= '5') self.round_up = true;
                }
            }
            return .pending;
        }
        if (byte == '_') {
            if (!self.decimal_previous_digit) self.decimal_valid = false;
            self.decimal_previous_digit = false;
            self.float_valid = false;
            return .pending;
        }
        self.decimal_valid = false;
        if (!self.exponent_seen and byte == '.' and !self.dot_seen) {
            self.dot_seen = true;
            return .pending;
        }
        if (!self.exponent_seen and (byte == 'e' or byte == 'E')) {
            self.exponent_seen = true;
            return .pending;
        }
        if (self.exponent_seen and self.exponent_digits == 0 and !self.exponent_sign_seen and
            (byte == '+' or byte == '-'))
        {
            self.exponent_sign_seen = true;
            self.exponent_negative = byte == '-';
            return .pending;
        }
        self.float_valid = false;
        return .pending;
    }
};

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
