//! Reusable shrinking recipes for value and reader property suites.

const std = @import("std");
const minish = @import("minish");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const dict = @import("../dict.zig");

pub const Value = value.Value;
pub const Dicts = enum { allowed, excluded };

/// A serialized construction tree. Removing or simplifying bytes shrinks both
/// the shape of composite values and their scalar leaves.
pub const ValueRecipe = struct {
    bytes: []const u8,
};

const max_recipe_bytes = 96;
const RecipeGenerator = minish.gen.Generator(ValueRecipe);
const RecipeShrinkFnPointer = @typeInfo(@FieldType(RecipeGenerator, "shrinkFn")).optional.child;
const RecipeShrinkFn = @typeInfo(RecipeShrinkFnPointer).pointer.child;
const RecipeShrinkIterator = @typeInfo(RecipeShrinkFn).@"fn".return_type.?;

fn generateRecipe(test_case: *minish.TestCase) minish.GenError!ValueRecipe {
    const length: usize = @intCast(try test_case.choice(max_recipe_bytes));
    const bytes = try test_case.allocator.alloc(u8, length);
    errdefer test_case.allocator.free(bytes);
    for (bytes) |*byte| byte.* = @intCast(try test_case.choice(255));
    return .{ .bytes = bytes };
}

fn freeRecipe(allocator: std.mem.Allocator, recipe: ValueRecipe) void {
    allocator.free(recipe.bytes);
}

const RecipeShrinkContext = struct {
    allocator: std.mem.Allocator,
    original: ValueRecipe,
    phase: Phase = .empty,
    index: usize = 0,

    const Phase = enum { empty, prefix, remove_one, simplify, done };

    fn allocate(self: *RecipeShrinkContext, length: usize) ?[]u8 {
        return self.allocator.alloc(u8, length) catch null;
    }

    fn next(context_ptr: *anyopaque) ?ValueRecipe {
        const self: *RecipeShrinkContext = @ptrCast(@alignCast(context_ptr));
        while (true) switch (self.phase) {
            .empty => {
                self.phase = .prefix;
                if (self.original.bytes.len == 0) continue;
                return .{ .bytes = self.allocate(0) orelse return null };
            },
            .prefix => {
                self.phase = .remove_one;
                if (self.original.bytes.len < 2) continue;
                const length = self.original.bytes.len / 2;
                const bytes = self.allocate(length) orelse return null;
                @memcpy(bytes, self.original.bytes[0..length]);
                return .{ .bytes = bytes };
            },
            .remove_one => {
                if (self.original.bytes.len <= 1 or self.index >= self.original.bytes.len) {
                    self.phase = .simplify;
                    self.index = 0;
                    continue;
                }
                const removed = self.index;
                self.index += 1;
                const bytes = self.allocate(self.original.bytes.len - 1) orelse return null;
                @memcpy(bytes[0..removed], self.original.bytes[0..removed]);
                @memcpy(bytes[removed..], self.original.bytes[removed + 1 ..]);
                return .{ .bytes = bytes };
            },
            .simplify => {
                while (self.index < self.original.bytes.len and self.original.bytes[self.index] == 0) {
                    self.index += 1;
                }
                if (self.index == self.original.bytes.len) {
                    self.phase = .done;
                    continue;
                }
                const simplified = self.index;
                self.index += 1;
                const bytes = self.allocate(self.original.bytes.len) orelse return null;
                @memcpy(bytes, self.original.bytes);
                bytes[simplified] /= 2;
                return .{ .bytes = bytes };
            },
            .done => return null,
        };
    }

    fn deinit(context_ptr: *anyopaque) void {
        const self: *RecipeShrinkContext = @ptrCast(@alignCast(context_ptr));
        self.allocator.destroy(self);
    }
};

fn shrinkRecipe(allocator: std.mem.Allocator, recipe: ValueRecipe) RecipeShrinkIterator {
    const context = allocator.create(RecipeShrinkContext) catch return RecipeShrinkIterator.empty();
    context.* = .{ .allocator = allocator, .original = recipe };
    return .{
        .context = context,
        .nextFn = RecipeShrinkContext.next,
        .deinitFn = RecipeShrinkContext.deinit,
    };
}

pub const value_recipe_generator: RecipeGenerator = .{
    .generateFn = generateRecipe,
    .shrinkFn = shrinkRecipe,
    .freeFn = freeRecipe,
};

const RecipeCursor = struct {
    bytes: []const u8,
    index: usize = 0,
    salt: u8,

    fn next(self: *RecipeCursor) u8 {
        if (self.bytes.len == 0) return self.salt;
        const result = self.bytes[self.index % self.bytes.len] ^ self.salt;
        self.index += 1;
        return result;
    }
};

pub fn valueFromRecipe(
    allocator: std.mem.Allocator,
    recipe: ValueRecipe,
    depth: usize,
    dicts: Dicts,
    salt: u8,
) error{OutOfMemory}!Value {
    var cursor = RecipeCursor{ .bytes = recipe.bytes, .salt = salt };
    return materializeValue(allocator, &cursor, depth, dicts);
}

pub fn dictFromRecipe(
    allocator: std.mem.Allocator,
    recipe: ValueRecipe,
    depth: usize,
    salt: u8,
) error{OutOfMemory}!Value {
    var cursor = RecipeCursor{ .bytes = recipe.bytes, .salt = salt };
    return materializeDict(allocator, &cursor, depth);
}

fn materializeValue(
    allocator: std.mem.Allocator,
    cursor: *RecipeCursor,
    depth: usize,
    dicts: Dicts,
) error{OutOfMemory}!Value {
    const choices: u8 = if (depth == 0) 5 else switch (dicts) {
        .allowed => 7,
        .excluded => 6,
    };
    return switch (cursor.next() % choices) {
        0 => .{ .int = signedInteger(cursor) },
        1 => .{ .float = @as(f64, @floatFromInt(signedInteger(cursor))) / 8.0 },
        2 => .{ .char = codepoint(cursor.next()) },
        3 => .{ .symbol = try internedId(cursor.next()) },
        4 => .{ .word = try internedId(cursor.next()) },
        5 => materializeList(allocator, cursor, depth - 1, dicts),
        6 => materializeDict(allocator, cursor, depth - 1),
        else => unreachable,
    };
}

fn materializeList(
    allocator: std.mem.Allocator,
    cursor: *RecipeCursor,
    depth: usize,
    dicts: Dicts,
) error{OutOfMemory}!Value {
    const count = cursor.next() % 5;
    const items = try allocator.alloc(Value, count);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |item| heap.testing.releaseValue(allocator, item);
    for (items) |*item| {
        item.* = try materializeValue(allocator, cursor, depth, dicts);
        initialized += 1;
    }
    return list.fromValues(allocator, items);
}

fn materializeDict(
    allocator: std.mem.Allocator,
    cursor: *RecipeCursor,
    depth: usize,
) error{OutOfMemory}!Value {
    var cleanup = heap.testing.Cleanup.init(allocator);
    defer cleanup.deinit();
    const count = cursor.next() % 4;
    const pairs = try allocator.alloc(dict.Pair, count);
    defer allocator.free(pairs);
    var initialized: usize = 0;
    defer for (pairs[0..initialized]) |pair| {
        heap.testing.releaseValue(allocator, pair[0]);
        heap.testing.releaseValue(allocator, pair[1]);
    };
    const base = signedInteger(cursor);
    for (pairs, 0..) |*pair, index| {
        pair[0] = .{ .int = base + @as(i64, @intCast(index)) };
        pair[1] = try materializeValue(allocator, cursor, depth, .allowed);
        initialized += 1;
    }
    return dict.fromUniquePairs(allocator, cleanup.domain(), pairs);
}

pub fn codepoint(encoded: u8) u32 {
    const samples = [_]u32{ 'a', ' ', '\n', 0xff, 0x100, 0x20ac, 0x10000, 0x1f642 };
    return samples[encoded % samples.len];
}

pub fn internedId(encoded: u8) error{OutOfMemory}!u32 {
    const names = [_][]const u8{ "alpha", "beta", "gamma", "+", "dup" };
    return intern.intern(names[encoded % names.len]);
}

fn signedInteger(cursor: *RecipeCursor) i64 {
    const magnitude: i64 = (@as(i64, cursor.next()) << 8) | cursor.next();
    return if (cursor.next() & 1 == 0) magnitude else -magnitude;
}
