//! The embedded standard library manifest.
//!
//! Every first-party module ships inside the binary, so the auto-load driver
//! consults this table before it ever touches the filesystem. That order is
//! required behavior: a stray `csv.ecl` on `ECL_PATH` must not
//! silently replace the stdlib, and `import` of a stdlib word must work with no
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
const archive_module = @import("stdlib/archive.zig");
const pkg_store_module = @import("stdlib/pkg_store.zig");
const io_module = @import("stdlib/io.zig");
const dict_module = @import("stdlib/dict.zig");
const rand_module = @import("stdlib/rand.zig");
const proc_module = @import("stdlib/proc.zig");
const fs_module = @import("stdlib/fs.zig");
const net_module = @import("stdlib/net.zig");
const clock_module = @import("stdlib/clock.zig");
const time_module = @import("stdlib/time.zig");

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
    .{ .name = "dict", .entry = .{ .builtin = &dict_module.words } },
    .{ .name = "error", .entry = .{ .source = .{
        .name = "<stdlib:error>",
        .text = @embedFile("stdlib/error.ecl"),
    } } },
    .{ .name = "result", .entry = .{ .source = .{
        .name = "<stdlib:result>",
        .text = @embedFile("stdlib/result.ecl"),
    } } },
    .{ .name = "str", .entry = .{ .source = .{
        .name = "<stdlib:str>",
        .text = @embedFile("stdlib/str.ecl"),
    } } },
    .{ .name = "io", .entry = .{ .builtin = &io_module.words } },
    .{ .name = "csv", .entry = .{ .native = Csv.descriptor() } },
    .{ .name = "json", .entry = .{ .builtin = &json_module.words } },
    .{ .name = "table", .entry = .{ .source = .{
        .name = "<stdlib:table>",
        .text = @embedFile("stdlib/table.ecl"),
    } } },
    .{ .name = "http", .entry = .{ .builtin = &http_module.words } },
    .{ .name = "http.server", .entry = .{ .source = .{
        .name = "<stdlib:http.server>",
        .text = @embedFile("stdlib/http/server.ecl"),
    } } },
    .{ .name = "http.request", .entry = .{ .source = .{
        .name = "<stdlib:http.request>",
        .text = @embedFile("stdlib/http/request.ecl"),
    } } },
    .{ .name = "http.response", .entry = .{ .source = .{
        .name = "<stdlib:http.response>",
        .text = @embedFile("stdlib/http/response.ecl"),
    } } },
    .{ .name = "proc", .entry = .{ .builtin = &proc_module.words } },
    .{ .name = "fs", .entry = .{ .builtin = &fs_module.words } },
    .{ .name = "net", .entry = .{ .builtin = &net_module.words } },
    .{ .name = "path", .entry = .{ .source = .{
        .name = "<stdlib:path>",
        .text = @embedFile("stdlib/path.ecl"),
    } } },
    .{ .name = "archive", .entry = .{ .builtin = &archive_module.words } },
    .{ .name = "clock", .entry = .{ .builtin = &clock_module.words } },
    .{ .name = "time", .entry = .{ .builtin = &time_module.words } },
    .{ .name = "pkg.store", .entry = .{ .builtin = &pkg_store_module.words } },
    .{ .name = "rng", .entry = .{ .source = .{
        .name = "<stdlib:rng>",
        .text = @embedFile("stdlib/rng.ecl"),
    } } },
    .{ .name = "rand", .entry = .{ .builtin = &rand_module.words } },
    .{ .name = "pkg.version", .entry = .{ .source = .{
        .name = "<stdlib:pkg.version>",
        .text = @embedFile("stdlib/pkg/version.ecl"),
    } } },
    .{ .name = "pkg.name", .entry = .{ .source = .{
        .name = "<stdlib:pkg.name>",
        .text = @embedFile("stdlib/pkg/name.ecl"),
    } } },
    .{ .name = "pkg.data", .entry = .{ .source = .{
        .name = "<stdlib:pkg.data>",
        .text = @embedFile("stdlib/pkg/data.ecl"),
    } } },
    .{ .name = "pkg.manifest", .entry = .{ .source = .{
        .name = "<stdlib:pkg.manifest>",
        .text = @embedFile("stdlib/pkg/manifest.ecl"),
    } } },
    .{ .name = "pkg.lock", .entry = .{ .source = .{
        .name = "<stdlib:pkg.lock>",
        .text = @embedFile("stdlib/pkg/lock.ecl"),
    } } },
    .{ .name = "pkg.mvs", .entry = .{ .source = .{
        .name = "<stdlib:pkg.mvs>",
        .text = @embedFile("stdlib/pkg/mvs.ecl"),
    } } },
    .{ .name = "pkg.sync", .entry = .{ .source = .{
        .name = "<stdlib:pkg.sync>",
        .text = @embedFile("stdlib/pkg/sync.ecl"),
    } } },
    .{ .name = "pkg.cli", .entry = .{ .source = .{
        .name = "<stdlib:pkg.cli>",
        .text = @embedFile("stdlib/pkg/cli.ecl"),
    } } },
    .{ .name = "test.default", .entry = .{ .source = .{
        .name = "<stdlib:test.default>",
        .text = @embedFile("stdlib/test/default.ecl"),
    } } },
};

comptime {
    for (modules, 0..) |module, index| {
        env.assertStaticModuleName(module.name);
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
