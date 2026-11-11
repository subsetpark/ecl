//! The decisions one finite-iteration call keeps for the word positions of its
//! quotation, stored so that no step does work in proportion to the quotation.
const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");
const machine = @import("machine.zig");
const Value = value.Value;
const Header = value.ListHandle;
const IdiomRequest = machine.IdiomRequest;

/// What one finite-iteration call has decided for a word position of its
/// quotation, kept for the rest of the call.
pub const PlanEntry = struct {
    /// For a word that offers a phrase to idiom recognition, the first phrase
    /// it offered in the call and what recognition made of it.
    offered: ?OfferedMatch = null,
};

/// The registry entry whose pattern an offered phrase matched, or none, with
/// what the match captured from the phrase. Whether the entry applies still
/// depends on each application's operands.
const OfferedMatch = struct {
    /// Which recognition the phrase was offered to: a dispatched word at one
    /// position may offer the same phrase to a different one.
    request: IdiomRequest,
    /// Retained, so a later phrase at the same address is this one.
    phrase: *Header,
    entry: ?u16,
    constant: ?Value,
    active_word: ?u32,
    active_index: ?u32,
};

/// The decisions one finite-iteration call has made for the words of its
/// quotation. A word's binding, and the idiom match of a phrase it was
/// offered, are decided at its first execution in the call and reused by every
/// later application, so the call is atomic under its bindings: a replacement
/// made while it runs takes effect at its next call.
pub const ResolutionPlan = struct {
    /// Borrowed: the combinator owns its quotation for the whole call.
    code: *Header,
    /// Allocated at the first entry.
    tree: ?*PlanTree = null,

    pub fn init(code: *Header) ResolutionPlan {
        return .{ .code = code };
    }

    /// The entry for word position `index`, made on first use.
    pub fn entry(self: *ResolutionPlan, allocator: std.mem.Allocator, index: u32) error{OutOfMemory}!*PlanEntry {
        const tree = self.tree orelse made: {
            const fresh = try allocator.create(PlanTree);
            fresh.* = .{ .allocator = allocator, .depth = PlanTree.depthFor(self.code.length()) };
            self.tree = fresh;
            break :made fresh;
        };
        return tree.entry(index);
    }

    /// Hands the entries to the release domain, which frees them a page or a
    /// node per turn.
    pub fn retire(self: *ResolutionPlan, releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        const tree = self.tree orelse return;
        self.tree = null;
        releases.retire(tree, &tree.retirement);
    }
};

/// A plan's entries by word position: pages of `page_len` entries under
/// `fanout`-way nodes, as many levels as the quotation's length needs. Every
/// node and page is allocated and cleared, a constant amount of work, by the
/// first entry that needs it, so no step does work in proportion to the
/// quotation, and a plan has no capacity.
const PlanTree = struct {
    const page_bits = 4;
    const page_len = 1 << page_bits;
    const fanout_bits = 6;
    const fanout = 1 << fanout_bits;
    /// Enough levels for any u32 position.
    const max_depth = (32 - page_bits + fanout_bits - 1) / fanout_bits;
    const Page = [page_len]PlanEntry;
    /// A node one level above the pages holds pages; any higher node holds
    /// nodes.
    const Node = struct {
        nodes: [fanout]?*Node = @splat(null),
        pages: [fanout]?*Page = @splat(null),
    };

    allocator: std.mem.Allocator,
    /// Node levels above the pages: zero when one page covers the code.
    depth: u8,
    root_page: ?*Page = null,
    root_node: ?*Node = null,
    retirement: heap.ReleaseDomain.Retirement = .{},
    /// Retirement's descent, one node per level.
    // SAFETY: only the first `stack_len` frames are read, each written first.
    stack: [max_depth]struct { node: *Node, next: u8 } = undefined,
    stack_len: u8 = 0,
    retiring: bool = false,

    fn depthFor(length: u64) u8 {
        if (length <= page_len) return 0;
        const bits: u8 = @intCast(64 - @clz(length - 1));
        return @intCast((bits - page_bits + fanout_bits - 1) / fanout_bits);
    }

    fn page(self: *PlanTree, slot: *?*Page) error{OutOfMemory}!*Page {
        if (slot.*) |held| return held;
        const fresh = try self.allocator.create(Page);
        fresh.* = @splat(.{});
        slot.* = fresh;
        return fresh;
    }

    fn node(self: *PlanTree, slot: *?*Node) error{OutOfMemory}!*Node {
        if (slot.*) |held| return held;
        const fresh = try self.allocator.create(Node);
        fresh.* = .{};
        slot.* = fresh;
        return fresh;
    }

    fn entry(self: *PlanTree, index: u32) error{OutOfMemory}!*PlanEntry {
        const offset = index & (page_len - 1);
        if (self.depth == 0) return &(try self.page(&self.root_page))[offset];
        var current = try self.node(&self.root_node);
        var level = self.depth;
        while (level != 1) : (level -= 1) {
            const shift: u5 = @intCast(page_bits + fanout_bits * (level - 1));
            current = try self.node(&current.nodes[(index >> shift) & (fanout - 1)]);
        }
        return &(try self.page(&current.pages[(index >> page_bits) & (fanout - 1)]))[offset];
    }

    fn retirePage(self: *PlanTree, releases: *heap.ReleaseDomain, held: *Page) void {
        for (held) |*planned| {
            if (planned.offered) |offered| releases.releaseHeader(offered.phrase);
        }
        self.allocator.destroy(held);
    }

    /// One page or one node edge per call.
    pub fn advanceRetirement(releases: *heap.ReleaseDomain, _: std.mem.Allocator, self: *PlanTree) bool {
        if (!self.retiring) {
            self.retiring = true;
            if (self.root_page) |held| self.retirePage(releases, held);
            if (self.root_node) |held| {
                self.stack[0] = .{ .node = held, .next = 0 };
                self.stack_len = 1;
            }
            return false;
        }
        if (self.stack_len == 0) {
            self.allocator.destroy(self);
            return true;
        }
        const top = &self.stack[self.stack_len - 1];
        if (top.next == fanout) {
            self.allocator.destroy(top.node);
            self.stack_len -= 1;
            return false;
        }
        const child = top.next;
        top.next += 1;
        if (self.stack_len == self.depth) {
            if (top.node.pages[child]) |held| self.retirePage(releases, held);
        } else if (top.node.nodes[child]) |held| {
            self.stack[self.stack_len] = .{ .node = held, .next = 0 };
            self.stack_len += 1;
        }
        return false;
    }
};
