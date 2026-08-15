//! One publication/reader handoff for immutable runtime snapshots.
//!
//! The reader announcement and pointer load, and the pointer publication and
//! reader observation, participate in one sequentially-consistent order. A
//! lease is the only public way to obtain a traversable pointer. Payload
//! retention and reclamation remain the owner's responsibility because their
//! work must be routed through the owner's bounded cursor/release domain.
const std = @import("std");

pub fn Publisher(comptime T: type) type {
    return struct {
        const Self = @This();

        current: std.atomic.Value(?*T),
        readers: std.atomic.Value(u32) = .init(0),

        pub const Lease = struct {
            publisher: *const Self,
            snapshot: ?*const T,
            active: bool = true,

            /// Returns true when this reader made the publisher quiescent.
            /// The caller may then detach retired records under its writer
            /// lock, but must reclaim them after releasing that lock.
            pub fn deinit(self: *Lease) bool {
                std.debug.assert(self.active);
                self.active = false;
                const old = @constCast(self.publisher).readers.fetchSub(1, .seq_cst);
                std.debug.assert(old != 0);
                self.* = undefined;
                return old == 1;
            }
        };

        pub fn init(initial: ?*T) Self {
            return .{ .current = .init(initial) };
        }

        pub fn acquire(self: *const Self) Lease {
            const old = @constCast(self).readers.fetchAdd(1, .seq_cst);
            std.debug.assert(old != std.math.maxInt(u32));
            return .{
                .publisher = self,
                .snapshot = self.current.load(.seq_cst),
            };
        }

        /// Writer-serialized publication. The owner validates the expected
        /// pointer before calling this method.
        pub fn publish(self: *Self, next: ?*T) void {
            self.current.store(next, .seq_cst);
        }

        pub fn isCurrent(self: *const Self, expected: ?*const T) bool {
            return self.current.load(.seq_cst) == @constCast(expected);
        }

        /// Owner-only access for writer-locked reclamation and final teardown.
        pub fn currentOwned(self: *const Self) ?*T {
            return self.current.load(.seq_cst);
        }

        pub fn readerCount(self: *const Self) u32 {
            return self.readers.load(.seq_cst);
        }

        pub fn quiescent(self: *const Self) bool {
            return self.readerCount() == 0;
        }
    };
}

test "snapshot publisher lease protects one self-consistent pointer" {
    const Item = struct { version: u64 };
    const ItemPublisher = Publisher(Item);
    var first = Item{ .version = 1 };
    var second = Item{ .version = 2 };
    var publisher = ItemPublisher.init(&first);

    var old = publisher.acquire();
    try std.testing.expectEqual(@as(u64, 1), old.snapshot.?.version);
    publisher.publish(&second);
    var current = publisher.acquire();
    try std.testing.expectEqual(@as(u64, 2), current.snapshot.?.version);
    try std.testing.expect(!current.deinit());
    try std.testing.expect(old.deinit());
    try std.testing.expect(publisher.quiescent());
}
