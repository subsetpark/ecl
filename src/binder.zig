//! Reader-time lowering of head binders into ordinary point-free forms.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const lexer = @import("lexer.zig");

pub const Value = value.Value;
pub const Span = lexer.Span;
pub const Diag = lexer.Diag;

pub const Name = struct {
    bytes: []const u8,
    span: Span,
};

pub const SpannedValue = struct {
    value: Value,
    span: Span,
};

pub const Error = error{ OutOfMemory, Parse };

/// Borrows `body` and returns a newly-owned slice whose heap values each own
/// one reference. The caller frees the slice and releases those values.
pub fn lower(
    allocator: std.mem.Allocator,
    names: []const Name,
    body: []const SpannedValue,
    binder_span: Span,
    diag: *Diag,
) Error![]SpannedValue {
    if (names.len == 0) {
        diag.set(binder_span, "a binder must contain at least one name");
        return error.Parse;
    }

    const name_ids = try allocator.alloc(u32, names.len);
    defer allocator.free(name_ids);
    for (names, 0..) |name, index| {
        const classification = lexer.classify(name.bytes);
        const valid_class = classification == .word;
        if (!valid_class or !lexer.validSymbol(name.bytes) or
            std.mem.indexOfScalar(u8, name.bytes, '.') != null)
        {
            diag.setFmt(name.span, "invalid binder name `{s}`", .{name.bytes});
            return error.Parse;
        }
        for (names[0..index]) |prior| {
            if (!std.mem.eql(u8, prior.bytes, name.bytes)) continue;
            diag.setFmt(name.span, "duplicate binder name `{s}`", .{name.bytes});
            return error.Parse;
        }
        name_ids[index] = try intern.intern(name.bytes);
    }

    for (body) |form| switch (form.value) {
        .list, .dict => if (try nestedLocalReference(allocator, form.value, name_ids)) |id| {
            diag.setFmt(
                form.span,
                "local `{s}` crosses a quotation boundary; capture it explicitly with `cons`",
                .{intern.get(id)},
            );
            return error.Parse;
        },
        .int, .float, .char, .symbol, .word => {},
    };

    const words = struct {
        cons: u32,
        dup: u32,
        at: u32,
        swap: u32,
        dip: u32,
        pop: u32,
    }{
        .cons = try intern.intern("cons"),
        .dup = try intern.intern("dup"),
        .at = try intern.intern("at"),
        .swap = try intern.intern("swap"),
        .dip = try intern.intern("dip"),
        .pop = try intern.intern("pop"),
    };

    var output: std.ArrayList(SpannedValue) = .empty;
    errdefer {
        for (output.items) |form| heap.releaseValue(allocator, form.value);
        output.deinit(allocator);
    }

    // The lowering's locals accumulator is the canonical empty vector `[]`,
    // not the ordinary empty quotation `()`.
    const empty = try list.fromI64Slice(allocator, &.{});
    try appendOwned(allocator, &output, .{ .value = empty, .span = binder_span });
    for (names) |_| try appendAtom(allocator, &output, .{ .word = words.cons }, binder_span);

    for (body) |form| {
        if (form.value == .word) {
            if (findName(name_ids, form.value.word)) |index| {
                try appendAtom(allocator, &output, .{ .word = words.dup }, binder_span);
                try appendAtom(allocator, &output, .{ .int = @intCast(index) }, binder_span);
                try appendAtom(allocator, &output, .{ .word = words.at }, binder_span);
                try appendAtom(allocator, &output, .{ .word = words.swap }, binder_span);
                continue;
            }
        }
        const wrapper = try list.fromValues(allocator, &.{form.value});
        try appendOwned(allocator, &output, .{ .value = wrapper, .span = binder_span });
        try appendAtom(allocator, &output, .{ .word = words.dip }, binder_span);
    }
    try appendAtom(allocator, &output, .{ .word = words.pop }, binder_span);
    return output.toOwnedSlice(allocator);
}

fn appendOwned(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(SpannedValue),
    form: SpannedValue,
) error{OutOfMemory}!void {
    output.append(allocator, form) catch |err| {
        heap.releaseValue(allocator, form.value);
        return err;
    };
}

fn appendAtom(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(SpannedValue),
    item: Value,
    span: Span,
) error{OutOfMemory}!void {
    try output.append(allocator, .{ .value = item, .span = span });
}

fn findName(names: []const u32, id: u32) ?usize {
    for (names, 0..) |name, index| if (name == id) return index;
    return null;
}

fn nestedLocalReference(
    allocator: std.mem.Allocator,
    root: Value,
    names: []const u32,
) error{OutOfMemory}!?u32 {
    var work: std.ArrayList(Value) = .empty;
    defer work.deinit(allocator);
    try work.append(allocator, root);
    while (work.pop()) |current| switch (current) {
        .word => |id| if (findName(names, id) != null) return id,
        .list => |header| {
            var index: usize = @intCast(header.len);
            while (index > 0) {
                index -= 1;
                try work.append(allocator, list.atUnchecked(current, index));
            }
        },
        .dict => |header| {
            var index: usize = @intCast(header.len);
            while (index > 0) {
                index -= 1;
                try work.append(allocator, dict.valueAt(header, index));
                try work.append(allocator, dict.keyAt(header, index));
            }
        },
        .int, .float, .char, .symbol => {},
    };
    return null;
}

fn releaseForms(allocator: std.mem.Allocator, forms: []const SpannedValue) void {
    for (forms) |form| heap.releaseValue(allocator, form.value);
}

test "canonical lowering fixture" {
    const allocator = std.testing.allocator;
    const printer = @import("print.zig");
    const x = try intern.intern("x");
    const multiply = try intern.intern("*");
    var diag: Diag = .{};
    const lowered = try lower(
        allocator,
        &.{.{ .bytes = "x", .span = .{} }},
        &.{
            .{ .value = .{ .word = x }, .span = .{} },
            .{ .value = .{ .word = x }, .span = .{} },
            .{ .value = .{ .word = multiply }, .span = .{} },
        },
        .{},
        &diag,
    );
    defer allocator.free(lowered);
    defer releaseForms(allocator, lowered);
    const values = try allocator.alloc(Value, lowered.len);
    defer allocator.free(values);
    for (lowered, 0..) |form, index| values[index] = form.value;
    const quotation = try list.fromValues(allocator, values);
    defer heap.releaseValue(allocator, quotation);
    const rendered = try printer.toOwnedString(allocator, quotation);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "([] cons dup 0 at swap dup 0 at swap (*) dip pop)",
        rendered,
    );
}

test "name validation errors" {
    const allocator = std.testing.allocator;
    var diag: Diag = .{};
    try std.testing.expectError(error.Parse, lower(allocator, &.{}, &.{}, .{}, &diag));
    try std.testing.expectError(error.Parse, lower(
        allocator,
        &.{
            .{ .bytes = "x", .span = .{} },
            .{ .bytes = "x", .span = .{ .col = 4 } },
        },
        &.{},
        .{},
        &diag,
    ));
    try std.testing.expectError(error.Parse, lower(
        allocator,
        &.{.{ .bytes = "module.x", .span = .{} }},
        &.{},
        .{},
        &diag,
    ));
}

test "boundary-crossing rejection" {
    const allocator = std.testing.allocator;
    const x = try intern.intern("x");
    const nested = try list.fromValues(allocator, &.{.{ .word = x }});
    defer heap.releaseValue(allocator, nested);
    var diag: Diag = .{};
    try std.testing.expectError(error.Parse, lower(
        allocator,
        &.{.{ .bytes = "x", .span = .{} }},
        &.{.{ .value = nested, .span = .{ .col = 6 } }},
        .{},
        &diag,
    ));
    try std.testing.expectEqualStrings(
        "local `x` crosses a quotation boundary; capture it explicitly with `cons`",
        diag.text(),
    );
}
