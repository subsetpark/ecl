//! What a quotation does to the stack, read from its words before it runs:
//! how many values it takes from beneath and how many it leaves. A summary
//! exists only when every word's effect is exact, so whatever acts on one may
//! skip the dynamic accounting that would have found the same counts.
const std = @import("std");
const value = @import("value.zig");
const list = @import("list.zig");
const env = @import("env.zig");
const machine = @import("machine.zig");
const combinators = @import("combinators.zig");

const Header = value.ListHandle;
const Fiber = machine.Fiber;

pub const Summary = struct {
    /// Values the quotation takes from beneath where it starts.
    consumed: u32,
    /// Values it leaves where those were.
    produced: u32,
};

/// A quotation longer than this is not summarized.
const max_forms = 16;
/// Forms one summary may visit across the quotations and word bodies it
/// descends into, which bounds the walk by a constant rather than by the
/// program.
const max_visited = 48;
/// How far a summary descends through nested quotations and word bodies.
const max_depth = 3;
/// The most a summary may consume or leave.
const max_values = 32;

/// The summary of a quotation about to run at `site`, or null when any word
/// leaves the counts to run time: a local, a word that does not resolve to a
/// static definition, a native word, a builtin whose effect holds a row and
/// has no rule here, or a combinator whose quotation is not a literal.
pub fn of(fiber: *Fiber, site: machine.ExecutionSite, quotation: *Header) error{OutOfMemory}!?Summary {
    var walk: Walk = .{ .fiber = fiber, .site = site };
    return walk.summarize(quotation, 0);
}

const Walk = struct {
    fiber: *Fiber,
    /// Where the quotation runs. A quotation a combinator applies inside it
    /// and a homeless word's body run at the same site.
    site: machine.ExecutionSite,
    visited: usize = 0,

    fn summarize(self: *Walk, quotation: *Header, depth: usize) error{OutOfMemory}!?Summary {
        const length: usize = @intCast(quotation.length());
        if (length > max_forms or depth > max_depth) return null;
        self.visited += length;
        if (self.visited > max_visited) return null;
        var stack: Abstract = .{};
        for (0..length) |index| {
            const form = list.atUnchecked(.{ .list = quotation }, index);
            const word = switch (form) {
                .symbol => |reference| reference,
                .list => |literal| {
                    stack.push(literal);
                    continue;
                },
                else => {
                    stack.push(null);
                    continue;
                },
            };
            if (env.isQuoted(word.slot)) {
                stack.push(null);
                continue;
            }
            if (env.wordTarget(word.slot) == .local) return null;
            const resolved = try self.fiber.resolveAt(word, self.site) orelse return null;
            const definition = resolved.definition;
            const applied: Summary = switch (definition.code()) {
                .native => return null,
                // A word with no home has no effect boundary, so its body
                // meets the stack as if written where the word is.
                .source => |executable| if (definition.home != null)
                    return null
                else
                    try self.summarize(executable.code(), depth + 1) orelse return null,
                // An exact declared effect says everything; only a builtin
                // whose effect holds a row can have a rule of its own.
                .builtin => |primitive| if (exact(definition)) |declared| declared else switch (combinators.flow(primitive)) {
                    .declared => return null,
                    .apply => try self.operand(&stack, depth) orelse return null,
                    .dip => {
                        const inner = try self.operand(&stack, depth) orelse return null;
                        stack.pop(1);
                        stack.apply(inner);
                        stack.push(null);
                        continue;
                    },
                    .branch => branch: {
                        const otherwise = try self.operand(&stack, depth) orelse return null;
                        const then = try self.operand(&stack, depth) orelse return null;
                        stack.pop(1);
                        // Which branch runs is data, so the counts are known
                        // only when the branches agree.
                        if (!std.meta.eql(then, otherwise)) return null;
                        break :branch then;
                    },
                    // A paging word leaves its quotation's results and the
                    // inputs it consumed.
                    .paging => paging: {
                        const inner = try self.operand(&stack, depth) orelse return null;
                        break :paging .{ .consumed = inner.consumed, .produced = inner.produced + inner.consumed };
                    },
                    .cleave => |count| cleave: {
                        var total: Summary = .{ .consumed = 0, .produced = 0 };
                        for (0..count) |_| {
                            const inner = try self.operand(&stack, depth) orelse return null;
                            total.consumed = @max(total.consumed, inner.consumed);
                            total.produced += inner.produced;
                        }
                        break :cleave total;
                    },
                },
            };
            stack.apply(applied);
            if (stack.reach > max_values or stack.height > max_values) return null;
        }
        return .{ .consumed = @intCast(stack.reach), .produced = @intCast(stack.height) };
    }

    fn exact(definition: *const env.Definition) ?Summary {
        const effect = definition.effect orelse return null;
        if (effect.result_depth != .exact) return null;
        return .{ .consumed = effect.inputs, .produced = effect.outputs };
    }

    /// The summary of the quotation on top of the abstract stack, which a
    /// combinator is about to take: known only when it is a literal the
    /// quotation pushed and nothing has moved since.
    fn operand(self: *Walk, stack: *Abstract, depth: usize) error{OutOfMemory}!?Summary {
        const taken = stack.take() orelse return null;
        return self.summarize(taken, depth + 1);
    }
};

/// The stack as a summary sees it: how far beneath its start the quotation
/// has reached, how many values stand above that point, and which of those
/// are list literals the quotation pushed.
const Abstract = struct {
    reach: usize = 0,
    height: usize = 0,
    // SAFETY: a slot is read only below `height`, and `push` writes every
    // slot it raises `height` past.
    literals: [max_values + 1]?*Header = undefined,

    fn push(self: *Abstract, literal: ?*Header) void {
        if (self.height < self.literals.len) self.literals[self.height] = literal;
        self.height += 1;
    }
    fn pop(self: *Abstract, count: usize) void {
        if (count > self.height) {
            self.reach += count - self.height;
            self.height = 0;
        } else self.height -= count;
    }
    /// Pops one value, returning it when it is a known literal.
    fn take(self: *Abstract) ?*Header {
        if (self.height == 0) {
            self.reach += 1;
            return null;
        }
        self.height -= 1;
        return if (self.height < self.literals.len) self.literals[self.height] else null;
    }
    fn apply(self: *Abstract, summary: Summary) void {
        self.pop(summary.consumed);
        for (0..summary.produced) |_| self.push(null);
    }
};
