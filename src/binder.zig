//! Reader-time lowering of head binders into ordinary point-free forms.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const list = @import("list.zig");
const lexer = @import("lexer.zig");
const poll = @import("poll.zig");

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
const FormList = poll.ChunkList(SpannedValue);

/// Borrows `body` and returns a newly-owned slice whose heap values each own
/// one reference. The caller frees the slice and releases those values.
pub fn lower(
    allocator: std.mem.Allocator,
    names: []const Name,
    body: []const SpannedValue,
    binder_span: Span,
    diag: *Diag,
) Error![]SpannedValue {
    return lowerPolling(allocator, names, body, binder_span, diag, .unlimited()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Parse => error.Parse,
        error.Ecl => unreachable,
    };
}

pub fn lowerPolling(
    allocator: std.mem.Allocator,
    names: []const Name,
    body: []const SpannedValue,
    binder_span: Span,
    diag: *Diag,
    work: poll.WorkContext,
) (Error || error{Ecl})![]SpannedValue {
    if (names.len == 0) {
        diag.set(binder_span, "a binder must contain at least one name");
        return error.Parse;
    }

    var locals = try poll.U32Index.init(allocator, names.len, work);
    defer locals.deinit();
    for (names, 0..) |name, index| {
        try work.step();
        const classification = try lexer.classifyPolling(name.bytes, work);
        const valid_class = classification == .word;
        var qualified = false;
        for (name.bytes) |byte| {
            try work.step();
            if (byte == '.') qualified = true;
        }
        if (!valid_class or !try lexer.validSymbolPolling(name.bytes, work) or
            intern.isReservedBytes(name.bytes) or qualified)
        {
            diag.setFmt(name.span, "invalid binder name `{s}`", .{name.bytes});
            return error.Parse;
        }
        const name_id = try intern.internPolling(name.bytes, work.asPoller());
        if (!try locals.put(name_id, index, work)) {
            diag.setFmt(name.span, "duplicate binder name `{s}`", .{name.bytes});
            return error.Parse;
        }
    }

    for (body) |form| {
        try work.step();
        switch (form.value) {
            .list => if (try nestedLocalReference(allocator, form.value, &locals, work)) |id| {
                diag.setFmt(
                    form.span,
                    "local `{s}` crosses a quotation boundary; capture it explicitly with `literal` and `compose`",
                    .{intern.get(id)},
                );
                return error.Parse;
            },
            .int, .float, .char, .symbol, .word, .dict => {},
        }
    }

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

    var output = FormList.init(allocator);
    defer output.deinit();
    errdefer {
        var iterator = output.iterator();
        while (iterator.next()) |form| heap.releaseValue(allocator, form.value);
    }

    // The lowering's locals accumulator is the canonical empty vector `[]`,
    // not the ordinary empty quotation `()`.
    const empty = try list.fromI64Slice(allocator, &.{});
    try appendOwned(allocator, &output, .{ .value = empty, .span = binder_span });
    for (names) |_| {
        try work.step();
        try appendAtom(&output, .{ .word = words.cons }, binder_span);
    }

    for (body) |form| {
        try work.step();
        if (form.value == .word) {
            if (try locals.get(form.value.word, work)) |index| {
                try appendAtom(&output, .{ .word = words.dup }, binder_span);
                try appendAtom(&output, .{ .int = @intCast(index) }, binder_span);
                try appendAtom(&output, .{ .word = words.at }, binder_span);
                try appendAtom(&output, .{ .word = words.swap }, binder_span);
                continue;
            }
        }
        const wrapper = try list.fromValues(allocator, &.{form.value});
        try appendOwned(allocator, &output, .{ .value = wrapper, .span = binder_span });
        try appendAtom(&output, .{ .word = words.dip }, binder_span);
    }
    try appendAtom(&output, .{ .word = words.pop }, binder_span);
    return output.toOwnedSlice(work);
}

fn appendOwned(
    allocator: std.mem.Allocator,
    output: *FormList,
    form: SpannedValue,
) error{OutOfMemory}!void {
    output.append(form) catch |err| {
        heap.releaseValue(allocator, form.value);
        return err;
    };
}

fn appendAtom(
    output: *FormList,
    item: Value,
    span: Span,
) error{OutOfMemory}!void {
    try output.append(.{ .value = item, .span = span });
}

fn nestedLocalReference(
    allocator: std.mem.Allocator,
    root: Value,
    locals: *const poll.U32Index,
    work_context: poll.WorkContext,
) (error{OutOfMemory} || error{Ecl})!?u32 {
    var work = poll.ChunkStack(Value).init(allocator);
    defer work.deinit();
    try work.push(root);
    while (work.pop()) |current| switch (current) {
        .word => |id| {
            if (try locals.get(id, work_context) != null) return id;
        },
        .list => |header| {
            var index: usize = @intCast(header.length());
            while (index > 0) {
                try work_context.step();
                index -= 1;
                try work.push(list.atUnchecked(current, index));
            }
        },
        .int, .float, .char, .symbol, .dict => {},
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
        "local `x` crosses a quotation boundary; capture it explicitly with `literal` and `compose`",
        diag.text(),
    );
}
