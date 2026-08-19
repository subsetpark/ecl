//! The embedded standard library manifest.
//!
//! Every first-party module ships inside the binary, so the auto-load driver
//! consults this table before it ever touches the filesystem. That order is
//! the ruling, not an optimization: a stray `csv.ecl` on `ECL_PATH` must not
//! silently replace the stdlib, and `use` of a stdlib name must work with no
//! `ECL_PATH` and no readable working directory at all.
//!
//! In-session shadowing and explicit `module` registration remain the
//! documented ways to override one of these names.
const std = @import("std");
const abi = @import("native-abi");
const env = @import("env.zig");
const Csv = @import("stdlib/csv.zig").Extension;
const json_module = @import("stdlib/json.zig");
const http_module = @import("stdlib/http.zig");

/// One complete transport for one embedded module. Each arm carries
//  everything its publication path needs, so no loader has to repair a
/// partial entry.
pub const Entry = union(enum) {
    /// ECL source evaluated through the ordinary reader and module path.
    source: Source,
    /// A first-party native module linked into this image, published through
    /// the same descriptor and capability contract as an external one. Only
    /// the image pin differs: there is nothing to open or close.
    native: *const abi.Descriptor,
    /// Host primitives published under a module name. Reserved for authority
    /// the SDK deliberately withholds — an allocator, sockets, TLS — which no
    /// external module may hold and no ECL program can express.
    builtin: []const env.BuiltinWord,
};

/// Embedded ECL source plus the provenance name errors raised inside it
/// report. The name is angle-bracketed because it is not a readable path.
pub const Source = struct {
    name: []const u8,
    text: []const u8,
};

const Module = struct {
    name: []const u8,
    entry: Entry,
};

const modules = [_]Module{
    .{ .name = "result", .entry = .{ .source = .{
        .name = "<stdlib:result>",
        .text = @embedFile("stdlib/result.ecl"),
    } } },
    .{ .name = "str", .entry = .{ .source = .{
        .name = "<stdlib:str>",
        .text = @embedFile("stdlib/str.ecl"),
    } } },
    .{ .name = "csv", .entry = .{ .native = Csv.descriptor() } },
    .{ .name = "json", .entry = .{ .builtin = &json_module.words } },
    .{ .name = "table", .entry = .{ .source = .{
        .name = "<stdlib:table>",
        .text = @embedFile("stdlib/table.ecl"),
    } } },
    .{ .name = "http", .entry = .{ .builtin = &http_module.words } },
    .{ .name = "rng", .entry = .{ .source = .{
        .name = "<stdlib:rng>",
        .text = @embedFile("stdlib/rng.ecl"),
    } } },
};

comptime {
    for (modules, 0..) |module, index| {
        if (module.name.len == 0) @compileError("embedded module names must be nonempty");
        for (module.name) |byte| {
            if (byte == '.' or std.ascii.isWhitespace(byte))
                @compileError("embedded module name is not a single atom: " ++ module.name);
        }
        for (modules[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, module.name))
                @compileError("duplicate embedded module: " ++ module.name);
        }
        switch (module.entry) {
            .source => |source| {
                if (source.text.len == 0)
                    @compileError("embedded module source is empty: " ++ module.name);
                if (source.name.len == 0)
                    @compileError("embedded module provenance is empty: " ++ module.name);
            },
            .native => {},
            .builtin => |words| {
                if (words.len == 0)
                    @compileError("embedded builtin module has no words: " ++ module.name);
                for (words) |word| {
                    if (word.doc.len == 0)
                        @compileError("embedded builtin word is undocumented: " ++ word.name);
                    env.assertStaticNamespace(word.name);
                }
            },
        }
    }
}

/// The table is a fixed comptime list of at most a handful of names, so this
/// scan is bounded by construction rather than by a polled budget.
pub fn find(name: []const u8) ?Entry {
    for (modules) |module| {
        if (std.mem.eql(u8, module.name, name)) return module.entry;
    }
    return null;
}

/// Every embedded module name, in manifest order. Reflection and tests
/// enumerate the stdlib through this rather than repeating the list.
pub fn names() [modules.len][]const u8 {
    var result: [modules.len][]const u8 = undefined;
    for (modules, &result) |module, *slot| slot.* = module.name;
    return result;
}
