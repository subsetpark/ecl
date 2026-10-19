//! Backend-independent, compile-time port declarations. Bridges generate their
//! private selectors from these names; neither authors nor ECL coordinate IDs.
const std = @import("std");

pub const max_activities = 4;

pub const Direction = enum { input, output };
pub const Transport = enum { bytes, messages };
pub const Owner = enum { resource, exchange };
pub const Cancellation = enum { close_resource, acknowledge };
pub const ControllerError = error{ Cancelled, Failed, OutOfMemory, InvalidValue };

pub const Endpoint = struct {
    name: ?[]const u8 = null,
    doc: []const u8,
    transport: Transport,
    direction: Direction,
    owner: Owner = .exchange,
};

/// Entries are a named struct, not a tuple. Names are the public binding names.
/// The containing declaration supplies nominal identity for each selector.
pub fn Endpoints(comptime entries: anytype) type {
    const fields = @typeInfo(@TypeOf(entries)).@"struct".field_names;
    if (fields.len > 64) @compileError("port: at most 64 endpoints may be declared");
    for (fields) |field_name| {
        const item: Endpoint = @field(entries, field_name);
        if (item.doc.len == 0) @compileError("port: endpoint documentation is required");
    }
    return struct {
        pub const Name = std.meta.FieldEnum(@TypeOf(entries));
        pub const count = fields.len;
        pub fn get(comptime name: Name) Endpoint {
            return @field(entries, @tagName(name));
        }
        pub fn publicName(comptime name: Name) []const u8 {
            return get(name).name orelse @tagName(name);
        }
        pub fn id(name: Name) u6 {
            return @intCast(@intFromEnum(name));
        }
        pub fn mask(comptime names: anytype) u64 {
            var bits: u64 = 0;
            for (names) |name| {
                const selected: Name = name;
                if (get(selected).owner != .exchange)
                    @compileError("port: operation endpoints must belong to the exchange");
                const bit = @as(u64, 1) << id(selected);
                if (bits & bit != 0) @compileError("port: duplicate operation endpoint");
                bits |= bit;
            }
            return bits;
        }
    };
}

/// Each entry declares doc, handler, lane, and endpoints together. Handler
/// signatures are checked by the consuming typed or ABI bridge.
pub fn Operations(comptime Lane: type, comptime EndpointSet: type, comptime entries: anytype) type {
    const lanes = @typeInfo(Lane).@"enum";
    if (lanes.field_values.len == 0 or lanes.field_values.len > 16 or lanes.mode != .exhaustive)
        @compileError("port: declare 1 to 16 exhaustive lanes");
    for (lanes.field_values, 0..) |value, index| {
        if (value != index) @compileError("port: lane values must be contiguous from zero");
    }
    const fields = @typeInfo(@TypeOf(entries)).@"struct".field_names;
    for (fields) |field_name| {
        const entry = @field(entries, field_name);
        if (entry.doc.len == 0) @compileError("port: operation documentation is required");
        _ = @as(Lane, entry.lane);
        _ = EndpointSet.mask(entry.endpoints);
        if (@typeInfo(@TypeOf(entry.handler)) != .@"fn") @compileError("port: operation requires a handler");
    }
    return struct {
        pub const Name = std.meta.FieldEnum(@TypeOf(entries));
        pub const count = fields.len;
        pub const lane_count = lanes.len;
        pub fn get(comptime name: Name) @TypeOf(@field(entries, @tagName(name))) {
            return @field(entries, @tagName(name));
        }
        pub fn exported(comptime name: Name) bool {
            const entry = get(name);
            const visibility: enum { public, private } = if (@hasField(@TypeOf(entry), "visibility")) entry.visibility else .public;
            return visibility == .public;
        }
        pub fn publicName(comptime name: Name) []const u8 {
            const entry = get(name);
            return if (@hasField(@TypeOf(entry), "name")) entry.name else @tagName(name);
        }
        pub fn lane(name: Name) Lane {
            inline for (fields) |field_name| {
                if (name == @field(Name, field_name)) return @field(entries, field_name).lane;
            }
            unreachable;
        }
        pub fn endpointMask(comptime name: Name) u64 {
            return EndpointSet.mask(get(name).endpoints);
        }
    };
}

/// Every bit pattern denotes a positive, bounded amount of scheduler work.
/// Storing count-minus-one makes zero and unbounded grants unrepresentable.
pub const WorkQuantum = enum(u16) {
    q1 = 0,
    q64 = 63,
    q256 = 255,
    q65536 = 65535,
    _,
    pub fn fromCount(amount: u32) error{InvalidLimits}!WorkQuantum {
        if (amount == 0 or amount > 65536) return error.InvalidLimits;
        return @enumFromInt(@as(u16, @intCast(amount - 1)));
    }
    pub fn count(self: WorkQuantum) u32 {
        return @as(u32, @intFromEnum(self)) + 1;
    }
};
