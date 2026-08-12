//! M3 primitives. Scalar arithmetic is the explicit M5 kernel seam.

const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const list = @import("list.zig");
const dict = @import("dict.zig");
const equal = @import("equal.zig");
const intern = @import("intern.zig");
const printer = @import("print.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;

const Definition = struct {
    name: []const u8,
    primitive: env.Primitive,
};

/// Specializes a multi-operand body into one `env.Primitive` per operand, so
/// every word keeps a distinct function pointer.
fn bind(comptime body: anytype, comptime operand: anytype) env.Primitive {
    return struct {
        fn run(evaluator: *Machine) MachineError!void {
            return body(evaluator, operand);
        }
    }.run;
}

pub fn install(core: *env.Env) error{OutOfMemory}!void {
    const definitions = [_]Definition{
        .{ .name = "dup", .primitive = dup },
        .{ .name = "swap", .primitive = swap },
        .{ .name = "pop", .primitive = pop },
        .{ .name = "over", .primitive = over },
        .{ .name = "dip", .primitive = dip },
        .{ .name = "call", .primitive = call },
        .{ .name = "cons", .primitive = cons },
        .{ .name = "compose", .primitive = compose },
        .{ .name = "at", .primitive = at },
        .{ .name = "if", .primitive = ifWord },
        .{ .name = "while", .primitive = whileWord },
        .{ .name = "def", .primitive = bind(define, true) },
        .{ .name = "let", .primitive = bind(define, false) },
        .{ .name = "+", .primitive = bind(arithmetic, Arithmetic.add) },
        .{ .name = "-", .primitive = bind(arithmetic, Arithmetic.sub) },
        .{ .name = "*", .primitive = bind(arithmetic, Arithmetic.mul) },
        .{ .name = "/", .primitive = bind(arithmetic, Arithmetic.div) },
        .{ .name = "=", .primitive = bind(compare, Comparison.eq) },
        .{ .name = "<>", .primitive = bind(compare, Comparison.ne) },
        .{ .name = "<", .primitive = bind(compare, Comparison.lt) },
        .{ .name = ">", .primitive = bind(compare, Comparison.gt) },
        .{ .name = "<=", .primitive = bind(compare, Comparison.le) },
        .{ .name = ">=", .primitive = bind(compare, Comparison.ge) },
        .{ .name = "match", .primitive = match },
        .{ .name = "dict-of", .primitive = dictOf },
        .{ .name = "attempt", .primitive = attempt },
        .{ .name = "raise", .primitive = raise },
        .{ .name = "pp", .primitive = pp },
        .{ .name = "prin", .primitive = prin },
        .{ .name = "args", .primitive = args },
        .{ .name = "exit", .primitive = exit },
    };
    for (definitions) |definition| {
        const id = try intern.intern(definition.name);
        try core.installCore(id, .{ .primitive = definition.primitive });
    }
    core.sealCore();
}

fn dup(evaluator: *Machine) MachineError!void {
    try evaluator.require(1);
    try evaluator.pushBorrowed(evaluator.unit.stack.items[evaluator.unit.stack.items.len - 1]);
}

fn swap(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const items = evaluator.unit.stack.items;
    std.mem.swap(Value, &items[items.len - 1], &items[items.len - 2]);
}

fn pop(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    heap.releaseValue(evaluator.allocator(), item);
}

fn over(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const items = evaluator.unit.stack.items;
    try evaluator.pushBorrowed(items[items.len - 2]);
}

fn dip(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const quotation = try evaluator.popOwned();
    const protected = try evaluator.popOwned();
    const header = quotationHeader(evaluator, quotation) catch |err| {
        heap.releaseValue(evaluator.allocator(), protected);
        return err;
    };
    try evaluator.dipOwned(header, protected);
}

fn call(evaluator: *Machine) MachineError!void {
    const quotation = try evaluator.popOwned();
    try evaluator.callOwned(try quotationHeader(evaluator, quotation));
}

fn cons(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list) return evaluator.typeError("a list");
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    const count: usize = @intCast(collection.list.len);
    const values = try evaluator.allocator().alloc(Value, count + 1);
    defer evaluator.allocator().free(values);
    values[0] = item;
    for (0..count) |index| values[index + 1] = list.atUnchecked(collection, index);
    try evaluator.pushOwned(try list.fromValues(evaluator.allocator(), values));
}

fn compose(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    if (left != .list or right != .list) return evaluator.typeError("two lists");
    const left_len: usize = @intCast(left.list.len);
    const right_len: usize = @intCast(right.list.len);
    const values = try evaluator.allocator().alloc(Value, left_len + right_len);
    defer evaluator.allocator().free(values);
    for (0..left_len) |index| values[index] = list.atUnchecked(left, index);
    for (0..right_len) |index| values[left_len + index] = list.atUnchecked(right, index);
    try evaluator.pushOwned(try list.fromValues(evaluator.allocator(), values));
}

fn at(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const index_value = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), index_value);
    const collection = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), collection);
    if (collection != .list or index_value != .int) {
        return evaluator.typeError("a list and an integer index");
    }
    if (index_value.int < 0) {
        return evaluator.fail(.domain, "list index is out of bounds");
    }
    const index: usize = @intCast(index_value.int);
    const count: usize = @intCast(collection.list.len);
    if (index >= count) {
        return evaluator.fail(.domain, "list index is out of bounds");
    }
    const item = list.atUnchecked(collection, index);
    try evaluator.pushBorrowed(item);
}

fn ifWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    const otherwise = try evaluator.popOwned();
    const then = try evaluator.popOwned();
    const predicate = try evaluator.popOwned();
    if (then != .list or otherwise != .list) {
        releaseThree(evaluator.allocator(), predicate, then, otherwise);
        return evaluator.typeError("two quotation branches");
    }
    const is_true = switch (predicate) {
        .int => |integer| switch (integer) {
            0 => false,
            1 => true,
            else => {
                releaseThree(evaluator.allocator(), predicate, then, otherwise);
                return evaluator.typeError("a 0/1 bool");
            },
        },
        .float, .char, .symbol, .word, .list, .dict => {
            releaseThree(evaluator.allocator(), predicate, then, otherwise);
            return evaluator.typeError("a 0/1 bool");
        },
    };
    heap.releaseValue(evaluator.allocator(), predicate);
    const selected = if (is_true) then else otherwise;
    const discarded = if (is_true) otherwise else then;
    heap.releaseValue(evaluator.allocator(), discarded);
    try evaluator.callOwned(selected.list);
}

fn whileWord(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const body = try evaluator.popOwned();
    const condition = try evaluator.popOwned();
    const body_header = quotationHeader(evaluator, body) catch |err| {
        heap.releaseValue(evaluator.allocator(), condition);
        return err;
    };
    const condition_header = quotationHeader(evaluator, condition) catch |err| {
        heap.decRef(evaluator.allocator(), body_header);
        return err;
    };
    try evaluator.whileOwned(condition_header, body_header);
}

fn define(evaluator: *Machine, word_binding: bool) MachineError!void {
    try evaluator.require(2);
    const name_value = try evaluator.popOwned();
    const name = switch (name_value) {
        .symbol => |id| id,
        .int, .float, .char, .word, .list, .dict => {
            heap.releaseValue(evaluator.allocator(), name_value);
            return evaluator.typeError("an unqualified symbol name");
        },
    };
    if (std.mem.indexOfScalar(u8, intern.get(name), '.') != null) {
        return evaluator.fail(.domain, "def/let requires an unqualified name");
    }
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    if (word_binding and item != .list) {
        return evaluator.fail(.type, "def expected a list body; use let for values");
    }
    const binding: env.Binding = if (word_binding)
        .{ .word = item.list }
    else
        .{ .value = item };
    try evaluator.currentEnv().define(name, binding);
}

const Arithmetic = enum { add, sub, mul, div };

fn arithmetic(evaluator: *Machine, operation: Arithmetic) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    if (!left.isNumber() or !right.isNumber()) return evaluator.typeError("two numbers");

    if (operation != .div and left == .int and right == .int) {
        const result = switch (operation) {
            .add => std.math.add(i64, left.int, right.int),
            .sub => std.math.sub(i64, left.int, right.int),
            .mul => std.math.mul(i64, left.int, right.int),
            .div => unreachable,
        } catch return evaluator.fail(.overflow, "integer arithmetic overflow");
        return evaluator.pushOwned(.{ .int = result });
    }

    const left_float = asFloat(left);
    const right_float = asFloat(right);
    if (operation == .div and right_float == 0.0) {
        return evaluator.fail(.domain, "division by zero");
    }
    const result = switch (operation) {
        .add => left_float + right_float,
        .sub => left_float - right_float,
        .mul => left_float * right_float,
        .div => left_float / right_float,
    };
    if (std.math.isNan(result)) return evaluator.fail(.domain, "operation produced NaN");
    const propagating = !std.math.isFinite(left_float) or !std.math.isFinite(right_float);
    if (std.math.isInf(result) and !propagating) {
        return evaluator.fail(.overflow, "floating-point arithmetic overflow");
    }
    try evaluator.pushOwned(.{ .float = result });
}

const Comparison = enum { eq, ne, lt, gt, le, ge };

fn compare(evaluator: *Machine, operation: Comparison) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    const ordering = equal.compareScalars(left, right) catch
        return evaluator.typeError("two numbers or two chars");
    const result = switch (operation) {
        .eq => ordering == .eq,
        .ne => ordering != .eq,
        .lt => ordering == .lt,
        .gt => ordering == .gt,
        .le => ordering != .gt,
        .ge => ordering != .lt,
    };
    try evaluator.pushOwned(.{ .int = @intFromBool(result) });
}

fn match(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    const right = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), right);
    const left = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), left);
    const matches = try equal.matchWithAllocator(evaluator.allocator(), left, right);
    try evaluator.pushOwned(.{ .int = @intFromBool(matches) });
}

fn dictOf(evaluator: *Machine) MachineError!void {
    const quotation = try evaluator.popOwned();
    try evaluator.dictOwned(try quotationHeader(evaluator, quotation));
}

fn attempt(evaluator: *Machine) MachineError!void {
    const quotation = try evaluator.popOwned();
    try evaluator.attemptOwned(try quotationHeader(evaluator, quotation));
}

fn raise(evaluator: *Machine) MachineError!void {
    const raised = try evaluator.popOwned();
    var raised_owned = true;
    defer if (raised_owned) heap.releaseValue(evaluator.allocator(), raised);
    if (raised != .dict) {
        return evaluator.typeError("an error dict");
    }
    const kind_id = try intern.intern("kind");
    const kind = try dict.symbolField(evaluator.allocator(), raised, kind_id) orelse {
        return evaluator.typeError("an error dict containing a symbol at 'kind");
    };
    if (kind != .symbol) {
        return evaluator.typeError("an error dict containing a symbol at 'kind");
    }
    const msg_id = try intern.intern("msg");
    if (try dict.symbolField(evaluator.allocator(), raised, msg_id)) |message| {
        if (!message.isString()) {
            return evaluator.typeError("an error dict with a string at 'msg");
        }
    }
    const word_id = try intern.intern("word");
    if (try dict.symbolField(evaluator.allocator(), raised, word_id)) |word| {
        if (word != .symbol) {
            return evaluator.typeError("an error dict with a symbol at 'word");
        }
    }
    const trace_id = try intern.intern("trace");
    if (try dict.symbolField(evaluator.allocator(), raised, trace_id)) |trace| {
        if (trace != .list or !allSymbols(trace)) {
            return evaluator.typeError("an error dict with symbols at 'trace");
        }
    }
    const data_id = try intern.intern("data");
    if (try dict.symbolField(evaluator.allocator(), raised, data_id)) |data| {
        if (data != .dict) {
            return evaluator.typeError("an error dict with a dict at 'data");
        }
    }
    raised_owned = false;
    return evaluator.raiseOwned(raised);
}

fn allSymbols(item: Value) bool {
    if (item != .list) return false;
    const count: usize = @intCast(item.list.len);
    for (0..count) |index| if (list.atUnchecked(item, index) != .symbol) return false;
    return true;
}

fn pp(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    const output = evaluator.unit.output orelse
        return evaluator.fail(.io, "standard output is unavailable");
    printer.printWithAllocator(evaluator.allocator(), item, output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return evaluator.fail(.io, "standard output write failed"),
    };
    output.writeByte('\n') catch
        return evaluator.fail(.io, "standard output write failed");
    output.flush() catch
        return evaluator.fail(.io, "standard output flush failed");
}

fn prin(evaluator: *Machine) MachineError!void {
    const item = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), item);
    if (!item.isString()) return evaluator.typeError("a string");
    const output = evaluator.unit.output orelse
        return evaluator.fail(.io, "standard output is unavailable");
    const count: usize = @intCast(item.list.len);
    for (0..count) |index| {
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(
            @intCast(list.atUnchecked(item, index).char),
            &encoded,
        ) catch return evaluator.fail(.domain, "string contains an invalid Unicode scalar");
        output.writeAll(encoded[0..length]) catch
            return evaluator.fail(.io, "standard output write failed");
    }
    output.flush() catch
        return evaluator.fail(.io, "standard output flush failed");
}

fn args(evaluator: *Machine) MachineError!void {
    try evaluator.pushBorrowed(evaluator.unit.arguments);
}

fn exit(evaluator: *Machine) MachineError!void {
    const status = try evaluator.popOwned();
    defer heap.releaseValue(evaluator.allocator(), status);
    if (status != .int or status.int < 0 or status.int > 255) {
        return evaluator.typeError("an exit status from 0 through 255");
    }
    evaluator.unit.exit_status = @intCast(status.int);
}

fn quotationHeader(evaluator: *Machine, item: Value) MachineError!*value.Header {
    return switch (item) {
        .list => |header| header,
        .int, .float, .char, .symbol, .word, .dict => {
            heap.releaseValue(evaluator.allocator(), item);
            return evaluator.typeError("a quotation/list");
        },
    };
}

fn releaseThree(allocator: std.mem.Allocator, a: Value, b: Value, c: Value) void {
    heap.releaseValue(allocator, a);
    heap.releaseValue(allocator, b);
    heap.releaseValue(allocator, c);
}

fn asFloat(item: Value) f64 {
    return switch (item) {
        .int => |integer| @floatFromInt(integer),
        .float => |floating| floating,
        .char, .symbol, .word, .list, .dict => unreachable,
    };
}

const reader = @import("reader.zig");
const spans = @import("spans.zig");

const Fixture = struct {
    allocator: std.mem.Allocator,
    environment: env.Env,
    archive: spans.SpanArchive,
    stack: std.ArrayList(Value) = .empty,
    output: std.Io.Writer.Allocating,
    arguments: Value,
    cancelled: std.atomic.Value(bool) = .init(false),

    fn init(allocator: std.mem.Allocator) !Fixture {
        var environment = env.Env.init(allocator);
        errdefer environment.deinit();
        try install(&environment);
        const arguments = try list.fromValuesGeneric(allocator, &.{});
        return .{
            .allocator = allocator,
            .environment = environment,
            .archive = spans.SpanArchive.init(allocator),
            .output = .init(allocator),
            .arguments = arguments,
        };
    }

    fn deinit(self: *Fixture) void {
        for (self.stack.items) |item| heap.releaseValue(self.allocator, item);
        self.stack.deinit(self.allocator);
        self.output.deinit();
        heap.releaseValue(self.allocator, self.arguments);
        self.environment.deinit();
        self.archive.deinit();
        self.* = undefined;
    }

    fn execute(self: *Fixture, source: []const u8) !?Value {
        return self.executeTo(source, &self.output.writer);
    }

    fn executeTo(
        self: *Fixture,
        source: []const u8,
        output: ?*std.Io.Writer,
    ) !?Value {
        var diag: reader.Diag = .{};
        const read_result = try reader.read(self.allocator, "fixture.ecl", source, &diag);
        var parsed = read_result.complete;
        defer parsed.deinit();
        const root = try list.fromValuesGeneric(self.allocator, parsed.forms);
        var root_owned = true;
        defer if (root_owned) heap.releaseValue(self.allocator, root);
        const root_header = root.list;
        try self.archive.absorb(&parsed, root);
        root_owned = false;

        var unit = machine.Unit.init(
            self.allocator,
            self.stack,
            &self.environment,
            &self.archive,
            output,
            self.arguments,
            &self.cancelled,
        );
        self.stack = .empty;
        defer {
            self.stack = unit.takeStack();
            unit.deinit();
        }
        machine.run(&unit, root_header) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Ecl => return unit.takeError().?,
        };
        return null;
    }
};

fn errorKind(allocator: std.mem.Allocator, error_value: Value) ![]const u8 {
    const found = try namedField(allocator, error_value, "kind");
    return intern.get(found.symbol);
}

fn namedField(
    allocator: std.mem.Allocator,
    dictionary: Value,
    name: []const u8,
) !Value {
    const key = try intern.intern(name);
    return (try dict.symbolField(allocator, dictionary, key)).?;
}

test "provisional scalar primitives enforce the d.22 regime" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    const overflow = (try fixture.execute("9223372036854775806 2 +")).?;
    defer heap.releaseValue(allocator, overflow);
    try std.testing.expectEqualStrings("overflow", try errorKind(allocator, overflow));
    try std.testing.expect((try fixture.execute("inf 1 +")) == null);
    try std.testing.expect(std.math.isPositiveInf(fixture.stack.items[0].float));
    const domain = (try fixture.execute("inf inf -")).?;
    defer heap.releaseValue(allocator, domain);
    try std.testing.expectEqualStrings("domain", try errorKind(allocator, domain));
}

test "division and comparison remain exact across 2^53" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try std.testing.expect((try fixture.execute("1 2 /")) == null);
    try std.testing.expectEqual(@as(f64, 0.5), fixture.stack.items[0].float);
    try std.testing.expect((try fixture.execute("9007199254740993 9007199254740992.0 >")) == null);
    try std.testing.expectEqual(@as(i64, 1), fixture.stack.items[1].int);
}

test "attempt reifies failure and def rejects scalar bodies" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try std.testing.expect((try fixture.execute("7 (1 0 /) attempt")) == null);
    try std.testing.expectEqual(@as(i64, 7), fixture.stack.items[0].int);
    const err_key = try intern.intern("err");
    try std.testing.expect((try dict.getWithAllocator(
        allocator,
        fixture.stack.items[1],
        .{ .symbol = err_key },
    )) != null);
    try std.testing.expect((try fixture.execute("pop (pop) attempt")) == null);
    try std.testing.expectEqual(@as(i64, 7), fixture.stack.items[0].int);
    const isolated_error = (try dict.getWithAllocator(
        allocator,
        fixture.stack.items[1],
        .{ .symbol = err_key },
    )).?;
    try std.testing.expectEqualStrings("underflow", try errorKind(allocator, isolated_error));
    try std.testing.expect((try fixture.execute("(2 3 +) attempt")) == null);
    const ok_key = try intern.intern("ok");
    const ok_results = (try dict.getWithAllocator(
        allocator,
        fixture.stack.items[2],
        .{ .symbol = ok_key },
    )).?;
    try std.testing.expectEqual(@as(i64, 5), list.atUnchecked(ok_results, 0).int);
    const failure = (try fixture.execute("1 'x def")).?;
    defer heap.releaseValue(allocator, failure);
    try std.testing.expectEqualStrings("type", try errorKind(allocator, failure));
}

test "raise preserves valid user dicts and validates optional fields" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const raised = (try fixture.execute("{'kind 'custom 'msg \"hello\"} raise")).?;
    defer heap.releaseValue(allocator, raised);
    const rendered = try printer.toOwnedString(allocator, raised);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{'kind 'custom 'msg \"hello\" 'word 'raise 'trace ['raise] " ++
            "'data {'source \"fixture.ecl\" 'line 1 'col 30}}",
        rendered,
    );

    const defaulted = (try fixture.execute("{'kind 'custom} raise")).?;
    defer heap.releaseValue(allocator, defaulted);
    const defaulted_rendered = try printer.toOwnedString(allocator, defaulted);
    defer allocator.free(defaulted_rendered);
    try std.testing.expectEqualStrings(
        "{'kind 'custom 'msg \"raised 'custom\" 'word 'raise 'trace ['raise] " ++
            "'data {'source \"fixture.ecl\" 'line 1 'col 17}}",
        defaulted_rendered,
    );

    const merged = (try fixture.execute("{'kind 'custom 'data {'detail 7}} raise")).?;
    defer heap.releaseValue(allocator, merged);
    try std.testing.expectEqualStrings(
        "raise",
        intern.get((try namedField(allocator, merged, "word")).symbol),
    );
    const merged_trace = try namedField(allocator, merged, "trace");
    try std.testing.expectEqual(@as(u64, 1), merged_trace.list.len);
    try std.testing.expectEqualStrings(
        "raise",
        intern.get(list.atUnchecked(merged_trace, 0).symbol),
    );
    const merged_data = try namedField(allocator, merged, "data");
    try std.testing.expectEqual(@as(i64, 7), (try namedField(allocator, merged_data, "detail")).int);
    _ = try namedField(allocator, merged_data, "source");
    _ = try namedField(allocator, merged_data, "line");
    _ = try namedField(allocator, merged_data, "col");

    const complete = (try fixture.execute(
        "{'kind 'custom 'msg \"old\" 'word 'origin 'trace ['origin] " ++
            "'data {'source \"old.ecl\" 'line 9 'col 8} 'detail 7} raise",
    )).?;
    defer heap.releaseValue(allocator, complete);
    const complete_rendered = try printer.toOwnedString(allocator, complete);
    defer allocator.free(complete_rendered);
    try std.testing.expectEqualStrings(
        "{'kind 'custom 'msg \"old\" 'word 'origin 'trace ['origin] " ++
            "'data {'source \"old.ecl\" 'line 9 'col 8} 'detail 7}",
        complete_rendered,
    );

    const malformed = (try fixture.execute("{'kind 1} raise")).?;
    defer heap.releaseValue(allocator, malformed);
    try std.testing.expectEqualStrings("type", try errorKind(allocator, malformed));
}

test "over compose and at have exact stack effects" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    try std.testing.expect((try fixture.execute("1 2 over")) == null);
    try std.testing.expectEqualSlices(
        Value,
        &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 1 } },
        fixture.stack.items,
    );
    try std.testing.expect((try fixture.execute("pop pop pop (1 2) (3 4) compose")) == null);
    const composed = fixture.stack.items[0];
    try std.testing.expect(composed == .list);
    try std.testing.expectEqual(@as(i64, 1), list.atUnchecked(composed, 0).int);
    try std.testing.expectEqual(@as(i64, 2), list.atUnchecked(composed, 1).int);
    try std.testing.expectEqual(@as(i64, 3), list.atUnchecked(composed, 2).int);
    try std.testing.expectEqual(@as(i64, 4), list.atUnchecked(composed, 3).int);
    try std.testing.expect((try fixture.execute("pop [10 20] 1 at")) == null);
    try std.testing.expectEqual(@as(i64, 20), fixture.stack.items[0].int);
}

test "pp and prin write through and writer failures become io errors" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    try std.testing.expect((try fixture.execute("\"hi\" prin 'visible pp")) == null);
    try std.testing.expectEqualStrings("hi'visible\n", fixture.output.written());

    var failing: std.Io.Writer = .failing;
    const failure = (try fixture.executeTo("'broken pp", &failing)).?;
    defer heap.releaseValue(allocator, failure);
    try std.testing.expectEqualStrings("io", try errorKind(allocator, failure));
}

test "inline control and reader-lowered binders execute" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    try std.testing.expect((try fixture.execute("1 (2 +) call")) == null);
    try std.testing.expectEqual(@as(i64, 3), fixture.stack.items[0].int);
    try std.testing.expect((try fixture.execute("pop 1 9 (2 +) dip")) == null);
    try std.testing.expectEqual(@as(i64, 3), fixture.stack.items[0].int);
    try std.testing.expectEqual(@as(i64, 9), fixture.stack.items[1].int);
    try std.testing.expect((try fixture.execute("pop pop 3 (|x| x x *) call")) == null);
    try std.testing.expectEqual(@as(i64, 9), fixture.stack.items[0].int);
    try std.testing.expect((try fixture.execute("pop 3 (dup 0 >) (1 -) while pop")) == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.stack.items.len);
    const invalid_branch = (try fixture.execute("1 (2) 3 if")).?;
    defer heap.releaseValue(allocator, invalid_branch);
    try std.testing.expectEqualStrings("type", try errorKind(allocator, invalid_branch));
}

fn allocationFailureProbe(allocator: std.mem.Allocator) !void {
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    if (try fixture.execute(
        "(3 4 +) 'sum def sum (1 0 /) attempt (5 6 +) attempt " ++
            "({'kind 'custom 'data {'detail 7}} raise) attempt",
    )) |failure| {
        heap.releaseValue(allocator, failure);
    }
}

test "execution propagates every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureProbe,
        .{},
    );
}
