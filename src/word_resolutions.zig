//! A fiber's memory of what its code resolved its words to.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");

/// What this fiber's code has resolved each word to, all in one
/// publication: every word resolves when it is reached, and reaching it again
/// in the same publication reuses that resolution. Any publication in the Session
/// invalidates every entry, so a redefinition reaches the next dispatch of
/// the word. An entry holds a counted definition, so a definition handed out
/// here outlives the invocation that retains it.
///
/// Open addressing with linear probing, kept at most half full and grown by
/// doubling up to a bound, beyond which it starts over empty; so a lookup
/// expects one probe and every operation, including growth and invalidation,
/// is bounded by that bound. Entries are placed by name alone: scope slots
/// are numbered process-wide, so hashing them would make which entries
/// collide, and so what a fiber allocates, depend on unrelated Sessions.
pub const WordResolutions = struct {
    const initial_capacity = 64;
    const max_capacity = 4096;
    const Entry = struct {
        word: value.Symbol,
        provenance: u64,
        definition: *env.Definition,
    };
    entries: []?Entry = &.{},
    /// How many entries are present, for the load bound.
    count: usize = 0,
    /// The publication every present entry was resolved in.
    publication: u64 = 0,

    fn home(self: *const WordResolutions, name: u32) usize {
        return @intCast((@as(u64, name) *% 0x9E3779B97F4A7C15 >> 32) & (self.entries.len - 1));
    }

    /// What `word` resolved to under `provenance` in `publication`.
    pub inline fn find(self: *const WordResolutions, word: value.Symbol, publication: u64, provenance: u64) ?*env.Definition {
        if (self.publication != publication or self.entries.len == 0) return null;
        const mask = self.entries.len - 1;
        var index = self.home(word.name);
        while (self.entries[index]) |entry| : (index = (index + 1) & mask) {
            if (entry.word.name == word.name and entry.word.slot == word.slot and entry.provenance == provenance)
                return entry.definition;
        }
        return null;
    }

    /// Records a resolution made in `publication`. Past `max_capacity` it
    /// starts over empty rather than growing.
    pub fn remember(
        self: *WordResolutions,
        allocator: std.mem.Allocator,
        releases: *heap.ReleaseDomain,
        word: value.Symbol,
        publication: u64,
        provenance: u64,
        definition: *env.Definition,
    ) error{OutOfMemory}!void {
        if (self.publication != publication) {
            self.clear(releases);
            self.publication = publication;
        }
        if ((self.count + 1) * 2 > self.entries.len) {
            const capacity = if (self.entries.len == 0) initial_capacity else self.entries.len * 2;
            if (capacity > max_capacity) self.clear(releases) else try self.grow(allocator, capacity);
        }
        if (definition.lifetime == .counted) definition.retain();
        self.place(.{ .word = word, .provenance = provenance, .definition = definition });
    }

    /// Puts `entry` in the first free place from its home. The caller keeps
    /// the table under half full, so one exists.
    fn place(self: *WordResolutions, entry: Entry) void {
        const mask = self.entries.len - 1;
        var index = self.home(entry.word.name);
        while (self.entries[index] != null) index = (index + 1) & mask;
        self.entries[index] = entry;
        self.count += 1;
    }

    /// Moves every entry into a table of `capacity`. Bounded by
    /// `max_capacity`. On failure the table is unchanged.
    fn grow(self: *WordResolutions, allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}!void {
        const grown = try allocator.alloc(?Entry, capacity);
        @memset(grown, null);
        const old = self.entries;
        self.entries = grown;
        self.count = 0;
        for (old) |maybe| if (maybe) |entry| self.place(entry);
        if (old.len != 0) allocator.free(old);
    }

    /// Bounded by `max_capacity`.
    fn clear(self: *WordResolutions, releases: *heap.ReleaseDomain) void {
        for (self.entries) |*slot| if (slot.*) |entry| {
            if (entry.definition.lifetime == .counted) entry.definition.release(releases);
            slot.* = null;
        };
        self.count = 0;
    }

    pub fn deinit(self: *WordResolutions, allocator: std.mem.Allocator, releases: *heap.ReleaseDomain) void {
        self.clear(releases);
        if (self.entries.len != 0) allocator.free(self.entries);
        self.* = .{};
    }

    /// The key a resolution depends on besides the word: where a qualified
    /// name or an alias searches registries.
    pub fn provenanceKey(provenance: modules.RegistrationProvenance) u64 {
        return switch (provenance) {
            .ordinary => 0,
            .standard_library => 1,
            .root_scope => |scope| 2 | (@as(u64, @backingInt(scope)) << 2),
            .source => |source| @intFromPtr(source),
        };
    }
};
