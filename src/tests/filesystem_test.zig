//! Public behavior of the pure `path` module and the capability-gated `fs`
//! module.
//!
//! Every filesystem case runs against a fresh temporary directory named as a
//! Session root through `Host.filesystem_policy`; effects are observed through
//! the public runtime and the real directory, never through implementation
//! state. Sessions run only source text, so the traceless session heap is the
//! right allocator (see `test_heap.zig`).
const std = @import("std");
const filesystem_port = @import("../filesystem_port.zig");
const session = @import("../session.zig");
const support = @import("kernel_test_support.zig");
const test_heap = @import("test_heap.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

const Policy = filesystem_port.FilesystemPolicy;
const Permissions = filesystem_port.Permissions;

/// A temporary directory plus the absolute path that names it as a root.
const Scratch = struct {
    directory: std.testing.TmpDir,
    path: [:0]u8,
    /// Backing storage for `allPolicy`, so the returned policy borrows this
    /// value rather than a temporary.
    root_storage: [1]filesystem_port.Root,

    fn init() !Scratch {
        var directory = std.testing.tmpDir(.{});
        const path = directory.dir.realPathFileAlloc(io, ".", allocator) catch |err| {
            directory.cleanup();
            return err;
        };
        return .{
            .directory = directory,
            .path = path,
            .root_storage = .{.{ .name = "root", .absolute_path = path, .permissions = .all }},
        };
    }

    fn deinit(self: *Scratch) void {
        allocator.free(self.path);
        self.directory.cleanup();
    }

    fn write(self: *Scratch, name: []const u8, data: []const u8) !void {
        try self.directory.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }

    fn read(self: *Scratch, name: []const u8) ![]u8 {
        return self.directory.dir.readFileAlloc(io, name, allocator, .unlimited);
    }

    fn expectAbsent(self: *Scratch, name: []const u8) !void {
        _ = self.directory.dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return error.ExpectedAbsentPath;
    }

    fn entryCount(self: *Scratch, name: []const u8) !usize {
        var directory = try self.directory.dir.openDir(io, name, .{ .iterate = true });
        defer directory.close(io);
        var iterator = directory.iterate();
        var count: usize = 0;
        while (try iterator.next(io)) |_| count += 1;
        return count;
    }

    /// Every private staging entry is prefixed `.ecl-fs-`; none may survive
    /// an operation, whichever way it ended.
    fn expectNoStaging(self: *Scratch, name: []const u8) !void {
        var directory = try self.directory.dir.openDir(io, name, .{ .iterate = true });
        defer directory.close(io);
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".ecl-fs-")) return error.StagingResidue;
        }
    }

    fn allPolicy(self: *const Scratch) Policy {
        return .{ .roots = &self.root_storage };
    }
};

const Outcome = union(enum) {
    stack: []const u8,
    failure: support.ErrorCase,
};

fn runCase(policy: ?Policy, config: session.Config, program: []const u8, outcome: Outcome) !void {
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var diagnostics_buffer: [256]u8 = undefined;
    var diagnostics = std.Io.Writer.Discarding.init(&diagnostics_buffer);
    var runtime = try session.Session.initWithHostConfig(heap.allocator(), &.{}, .{
        .io = io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .filesystem_policy = policy,
    }, config);
    defer runtime.deinit();
    switch (try runtime.runUnit("<fs-test>", program)) {
        .ok => switch (outcome) {
            .stack => |expected| {
                var display = try runtime.stackDisplay();
                defer display.deinit();
                try std.testing.expectEqualStrings(expected, display.bytes());
            },
            .failure => |expected| {
                std.log.err("expected `{s}` to fail: {s}", .{ expected.name, program });
                return error.ExpectedLanguageError;
            },
        },
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            switch (outcome) {
                .stack => {
                    var rendered = try runtime.renderValue(failure);
                    defer rendered.deinit();
                    std.log.err("unexpected language error: {s}\nsource: {s}", .{ rendered.bytes(), program });
                    return error.UnexpectedLanguageError;
                },
                .failure => |expected| try support.expectLanguageError(failure, expected),
            }
        },
    }
}

fn expectStack(policy: ?Policy, program: []const u8, expected: []const u8) !void {
    return runCase(policy, .cooperative, program, .{ .stack = expected });
}

fn expectFailure(policy: ?Policy, program: []const u8, expected: support.ErrorCase) !void {
    return runCase(policy, .cooperative, program, .{ .failure = expected });
}

/// Runs `program` and requires the structured failure every `fs` word raises:
/// kind, operation, root, and reason.
fn expectFsFailure(
    policy: ?Policy,
    program: []const u8,
    kind: []const u8,
    word: []const u8,
    reason: []const u8,
) !void {
    // A copy names both ends of the transfer instead of one root.
    const root_field = if (std.mem.eql(u8, word, "fs.copy")) "source-root" else "root";
    const fields = [_]support.DataField{
        .{ .name = "operation", .expected = .{ .symbol = word[3..] } },
        .{ .name = root_field, .expected = .{ .symbol = "root" } },
        .{ .name = "reason", .expected = .{ .symbol = reason } },
    };
    return runCase(policy, .cooperative, program, .{ .failure = .{
        .name = program,
        .source = program,
        .kind = kind,
        .word = word,
        .data = &fields,
    } });
}

// -- path ---------------------------------------------------------------------

test "path: normalize follows lexical slash-path cleanup" {
    try support.expectStacks(&.{
        .{ .name = "collapse", .source = "\"a//b/./c/../d\" path.normalize", .expected = "\"a/b/d\"" },
        .{ .name = "empty", .source = "\"\" path.normalize", .expected = "\".\"" },
        .{ .name = "dot", .source = "\".\" path.normalize", .expected = "\".\"" },
        .{ .name = "root", .source = "\"/\" path.normalize", .expected = "\"/\"" },
        .{ .name = "root clamp", .source = "\"/..\" path.normalize", .expected = "\"/\"" },
        .{ .name = "deep root clamp", .source = "\"/a/b/../../..\" path.normalize", .expected = "\"/\"" },
        .{ .name = "leading parent kept", .source = "\"../a/..\" path.normalize", .expected = "\"..\"" },
        .{ .name = "parents accumulate", .source = "\"a/../..\" path.normalize", .expected = "\"..\"" },
        .{ .name = "trailing slash", .source = "\"a/b/\" path.normalize", .expected = "\"a/b\"" },
        .{ .name = "leading slash kept", .source = "\"/a/./b\" path.normalize", .expected = "\"/a/b\"" },
        .{ .name = "unicode preserved", .source = "\"héllo/wörld\" path.normalize", .expected = "\"héllo/wörld\"" },
        .{ .name = "backslash ordinary", .source = "\"a\\\\b\" path.normalize", .expected = "\"a\\\\b\"" },
    });
}

test "path: join dirname basename extension and components" {
    try support.expectStacks(&.{
        .{ .name = "join", .source = "(\"a\" \"b/\" \"c\") path.join", .expected = "\"a/b/c\"" },
        .{ .name = "join skips empty", .source = "(\"a\" \"\" \"b\") path.join", .expected = "\"a/b\"" },
        .{ .name = "join empty list", .source = "[] path.join", .expected = "\".\"" },
        .{ .name = "join all empty", .source = "(\"\" \"\") path.join", .expected = "\".\"" },
        .{ .name = "join absolute", .source = "(\"/\" \"a\") path.join", .expected = "\"/a\"" },
        .{ .name = "dirname nested", .source = "\"/a/b\" path.dirname", .expected = "\"/a\"" },
        .{ .name = "dirname single", .source = "\"a\" path.dirname", .expected = "\".\"" },
        .{ .name = "dirname trailing", .source = "\"a/b/\" path.dirname", .expected = "\"a/b\"" },
        .{ .name = "dirname root", .source = "\"/\" path.dirname", .expected = "\"/\"" },
        .{ .name = "dirname empty", .source = "\"\" path.dirname", .expected = "\".\"" },
        .{ .name = "basename trailing", .source = "\"a/b/\" path.basename", .expected = "\"b\"" },
        .{ .name = "basename root", .source = "\"///\" path.basename", .expected = "\"/\"" },
        .{ .name = "basename empty", .source = "\"\" path.basename", .expected = "\".\"" },
        .{ .name = "basename dotted", .source = "\"x/.hidden\" path.basename", .expected = "\".hidden\"" },
        .{ .name = "extension", .source = "\"x/y.tar.gz\" path.extension", .expected = "\".gz\"" },
        .{ .name = "extension dotfile", .source = "\".bashrc\" path.extension", .expected = "\".bashrc\"" },
        .{ .name = "extension trailing dot", .source = "\"a.\" path.extension", .expected = "\".\"" },
        .{ .name = "extension directory dot", .source = "\"a.b/c\" path.extension", .expected = "\"\"" },
        .{ .name = "components absolute", .source = "\"/a/b\" path.components", .expected = "(\"a\" \"b\")" },
        .{ .name = "components current", .source = "\".\" path.components", .expected = "()" },
        .{ .name = "components root", .source = "\"/\" path.components", .expected = "()" },
        .{ .name = "components parent", .source = "\"../x\" path.components", .expected = "(\"..\" \"x\")" },
        .{ .name = "components normalizes", .source = "\"a//b/../c\" path.components", .expected = "(\"a\" \"c\")" },
        .{ .name = "absolute", .source = "\"/a\" path.absolute? \"a/\" path.absolute?", .expected = "1 0" },
        .{ .name = "relative", .source = "\"/a\" path.relative? \"a\" path.relative?", .expected = "0 1" },
    });
}

test "path: valid-relative? is the canonical fs grammar" {
    try support.expectStacks(&.{
        .{ .name = "dot", .source = "\".\" path.valid-relative?", .expected = "1" },
        .{ .name = "nested", .source = "\"a/b.txt\" path.valid-relative?", .expected = "1" },
        .{ .name = "backslash", .source = "\"a\\\\b\" path.valid-relative?", .expected = "1" },
        .{ .name = "empty", .source = "\"\" path.valid-relative?", .expected = "0" },
        .{ .name = "leading slash", .source = "\"/a\" path.valid-relative?", .expected = "0" },
        .{ .name = "trailing slash", .source = "\"a/\" path.valid-relative?", .expected = "0" },
        .{ .name = "repeated slash", .source = "\"a//b\" path.valid-relative?", .expected = "0" },
        .{ .name = "dot component", .source = "\"./a\" path.valid-relative?", .expected = "0" },
        .{ .name = "parent component", .source = "\"a/../b\" path.valid-relative?", .expected = "0" },
        .{ .name = "nul", .source = "\"a\\u{0}b\" path.valid-relative?", .expected = "0" },
    });
}

test "path: words reject non-string arguments" {
    try support.expectErrors(&.{
        .{ .name = "normalize", .source = "1 path.normalize", .kind = "type" },
        .{ .name = "join non-list", .source = "\"a\" path.join", .kind = "type" },
        .{ .name = "join mixed", .source = "(\"a\" 1) path.join", .kind = "type" },
        .{ .name = "dirname", .source = "'a path.dirname", .kind = "type" },
        .{ .name = "basename", .source = "[] 1 path.basename", .kind = "type" },
        .{ .name = "extension", .source = "1.5 path.extension", .kind = "type" },
        .{ .name = "components", .source = "{} path.components", .kind = "type" },
        .{ .name = "valid-relative?", .source = "1 path.valid-relative?", .kind = "type" },
        .{ .name = "absolute?", .source = "1 path.absolute?", .kind = "type" },
    });
}

test "path: valid-relative? agrees with fs path acceptance" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const policy = scratch.allPolicy();
    // A parent must exist for `exists?` to report a definite absence; a
    // missing intermediate is a traversal failure, not `0`.
    try scratch.directory.dir.createDir(io, "a", .default_dir);
    const accepted = [_][]const u8{ ".", "a", "a/b", "a\\\\b", "héllo" };
    const rejected = [_][]const u8{ "", "/a", "a/", "a//b", "./a", "a/../b", "..", "a/." };
    for (accepted) |path| {
        const program = try std.fmt.allocPrint(allocator, "\"{s}\" path.valid-relative? 'root \"{s}\" fs.exists?", .{ path, path });
        defer allocator.free(program);
        const expected = if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "a")) "1 1" else "1 0";
        try expectStack(policy, program, expected);
    }
    for (rejected) |path| {
        const predicate = try std.fmt.allocPrint(allocator, "\"{s}\" path.valid-relative?", .{path});
        defer allocator.free(predicate);
        try expectStack(policy, predicate, "0");
        const program = try std.fmt.allocPrint(allocator, "'root \"{s}\" fs.exists?", .{path});
        defer allocator.free(program);
        try expectFsFailure(policy, program, "domain", "fs.exists?", "invalid-path");
    }
}

// -- fs authority -------------------------------------------------------------

test "fs: a Session without a filesystem policy denies every word" {
    const programs = [_]struct { source: []const u8, word: []const u8 }{
        .{ .source = "'root \"a\" fs.read-text", .word = "fs.read-text" },
        .{ .source = "'root \"a\" fs.read-bytes", .word = "fs.read-bytes" },
        .{ .source = "\"x\" 'root \"a\" fs.create-text", .word = "fs.create-text" },
        .{ .source = "[1] 'root \"a\" fs.create-bytes", .word = "fs.create-bytes" },
        .{ .source = "\"x\" 'root \"a\" fs.replace-text", .word = "fs.replace-text" },
        .{ .source = "[1] 'root \"a\" fs.replace-bytes", .word = "fs.replace-bytes" },
        .{ .source = "'root \"a\" fs.stat", .word = "fs.stat" },
        .{ .source = "'root \"a\" fs.lstat", .word = "fs.lstat" },
        .{ .source = "'root \"a\" fs.exists?", .word = "fs.exists?" },
        .{ .source = "'root \".\" fs.list", .word = "fs.list" },
        .{ .source = "'root \"a\" fs.mkdir", .word = "fs.mkdir" },
        .{ .source = "'root \"a\" 'root \"b\" fs.copy", .word = "fs.copy" },
        .{ .source = "'root \"a\" \"b\" fs.rename", .word = "fs.rename" },
        .{ .source = "'root \"a\" fs.remove-file", .word = "fs.remove-file" },
        .{ .source = "'root \"a\" fs.remove-dir", .word = "fs.remove-dir" },
    };
    for (programs) |case| {
        try expectFailure(null, case.source, .{
            .name = case.word,
            .source = case.source,
            .kind = "domain",
            .word = case.word,
            .data = &.{.{ .name = "reason", .expected = .{ .symbol = "unavailable" } }},
        });
    }
    // The same denial through the bare library constructor.
    try support.expectError(.{ .name = "bare session", .source = "'root \"a\" fs.exists?", .kind = "domain", .word = "fs.exists?" });
}

test "fs: unknown roots and each permission are enforced before the host is reached" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.write("f.txt", "data");
    try scratch.write("g.txt", "data");
    try scratch.directory.dir.createDir(io, "d", .default_dir);
    const all = scratch.allPolicy();
    try expectFailure(all, "'other \"f.txt\" fs.read-text", .{
        .name = "unknown root",
        .source = "'other \"f.txt\" fs.read-text",
        .kind = "domain",
        .word = "fs.read-text",
        .data = &.{
            .{ .name = "root", .expected = .{ .symbol = "other" } },
            .{ .name = "reason", .expected = .{ .symbol = "unknown-root" } },
        },
    });
    try expectFailure(all, "\"f.txt\" 'root fs.read-text", .{ .name = "non-symbol root", .source = "\"f.txt\" 'root fs.read-text", .kind = "type", .word = "fs.read-text" });
    try expectFailure(all, "'root 1 fs.read-text", .{ .name = "non-string path", .source = "'root 1 fs.read-text", .kind = "type", .word = "fs.read-text" });
    try expectFailure(all, "1 'root \"n\" fs.create-text", .{ .name = "non-string payload", .source = "1 'root \"n\" fs.create-text", .kind = "type", .word = "fs.create-text" });
    try expectFailure(all, "\"s\" 'root \"n\" fs.create-bytes", .{ .name = "non-list payload", .source = "\"s\" 'root \"n\" fs.create-bytes", .kind = "type", .word = "fs.create-bytes" });
    try expectFailure(all, "[300] 'root \"n\" fs.create-bytes", .{ .name = "invalid byte member", .source = "[300] 'root \"n\" fs.create-bytes", .kind = "type", .word = "fs.create-bytes" });
    try scratch.expectAbsent("n");

    // Every grant independently: the allowed word succeeds and every other
    // family is denied without touching the directory.
    const grants = [_]struct {
        permissions: Permissions,
        allowed: []const u8,
        allowed_stack: []const u8,
        denied: []const u8,
        denied_word: []const u8,
    }{
        .{ .permissions = .{ .read_data = true }, .allowed = "'root \"f.txt\" fs.read-text", .allowed_stack = "\"data\"", .denied = "'root \"f.txt\" fs.stat", .denied_word = "fs.stat" },
        .{ .permissions = .{ .inspect = true }, .allowed = "'root \"f.txt\" fs.exists?", .allowed_stack = "1", .denied = "'root \".\" fs.list", .denied_word = "fs.list" },
        .{ .permissions = .{ .list = true }, .allowed = "'root \"d\" fs.list", .allowed_stack = "()", .denied = "'root \"f.txt\" fs.read-bytes", .denied_word = "fs.read-bytes" },
        .{ .permissions = .{ .create = true }, .allowed = "'root \"made\" fs.mkdir", .allowed_stack = "", .denied = "\"x\" 'root \"f.txt\" fs.replace-text", .denied_word = "fs.replace-text" },
        .{ .permissions = .{ .replace = true }, .allowed = "\"new\" 'root \"f.txt\" fs.replace-text", .allowed_stack = "", .denied = "'root \"f.txt\" \"moved\" fs.rename", .denied_word = "fs.rename" },
        .{ .permissions = .{ .rename = true }, .allowed = "'root \"g.txt\" \"h.txt\" fs.rename", .allowed_stack = "", .denied = "'root \"h.txt\" fs.remove-file", .denied_word = "fs.remove-file" },
        .{ .permissions = .{ .remove = true }, .allowed = "'root \"h.txt\" fs.remove-file", .allowed_stack = "", .denied = "\"x\" 'root \"again\" fs.create-text", .denied_word = "fs.create-text" },
    };
    for (grants) |grant| {
        const policy: Policy = .{ .roots = &.{.{ .name = "root", .absolute_path = scratch.path, .permissions = grant.permissions }} };
        try expectStack(policy, grant.allowed, grant.allowed_stack);
        try expectFsFailure(policy, grant.denied, "domain", grant.denied_word, "denied");
    }
    try scratch.expectAbsent("moved");
    try scratch.expectAbsent("again");
    const replaced = try scratch.read("f.txt");
    defer allocator.free(replaced);
    try std.testing.expectEqualStrings("new", replaced);

    // Copy composes read-data on the source with create on the destination.
    const two_roots: Policy = .{ .roots = &.{
        .{ .name = "root", .absolute_path = scratch.path, .permissions = .{ .read_data = true } },
        .{ .name = "sink", .absolute_path = scratch.path, .permissions = .{ .create = true } },
    } };
    try expectStack(two_roots, "'root \"f.txt\" 'sink \"copied.txt\" fs.copy", "");
    const copied = try scratch.read("copied.txt");
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("new", copied);
    try expectFailure(two_roots, "'sink \"copied.txt\" 'sink \"again.txt\" fs.copy", .{
        .name = "copy source denied",
        .source = "'sink \"copied.txt\" 'sink \"again.txt\" fs.copy",
        .kind = "domain",
        .word = "fs.copy",
        .data = &.{
            .{ .name = "source-root", .expected = .{ .symbol = "sink" } },
            .{ .name = "destination-root", .expected = .{ .symbol = "sink" } },
            .{ .name = "reason", .expected = .{ .symbol = "denied" } },
        },
    });
    try expectFailure(two_roots, "'root \"f.txt\" 'root \"again.txt\" fs.copy", .{
        .name = "copy destination denied",
        .source = "'root \"f.txt\" 'root \"again.txt\" fs.copy",
        .kind = "domain",
        .word = "fs.copy",
        .data = &.{.{ .name = "reason", .expected = .{ .symbol = "denied" } }},
    });
    try scratch.expectAbsent("again.txt");
}

test "fs: policy validation is a distinct Session construction failure" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.write("file", "x");
    const file_path = try std.fmt.allocPrint(allocator, "{s}/file", .{scratch.path});
    defer allocator.free(file_path);
    const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing", .{scratch.path});
    defer allocator.free(missing_path);
    const invalid = [_]Policy{
        .{ .roots = &.{.{ .name = "root", .absolute_path = "relative", .permissions = .all }} },
        .{ .roots = &.{.{ .name = "root", .absolute_path = file_path, .permissions = .all }} },
        .{ .roots = &.{.{ .name = "root", .absolute_path = missing_path, .permissions = .all }} },
        .{ .roots = &.{.{ .name = "bad name", .absolute_path = scratch.path, .permissions = .all }} },
        .{ .roots = &.{
            .{ .name = "root", .absolute_path = scratch.path, .permissions = .all },
            .{ .name = "root", .absolute_path = scratch.path, .permissions = .all },
        } },
        .{ .roots = &.{.{ .name = "root", .absolute_path = scratch.path, .permissions = .all }}, .limits = .{ .max_transfer_bytes = 0 } },
    };
    for (invalid) |policy| {
        var heap: test_heap.SessionHeap = .init;
        defer test_heap.retire(&heap);
        var output_buffer: [64]u8 = undefined;
        var output = std.Io.Writer.Discarding.init(&output_buffer);
        try std.testing.expectError(error.InvalidHostPolicy, session.Session.initWithHost(heap.allocator(), &.{}, .{
            .io = io,
            .output = &output.writer,
            .diagnostics = &output.writer,
            .filesystem_policy = policy,
        }));
    }
    // The copied policy outlives the borrowed inputs it was built from.
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    const name = try allocator.dupe(u8, "root");
    const root_path = try allocator.dupe(u8, scratch.path);
    var runtime = try session.Session.initWithHost(heap.allocator(), &.{}, .{
        .io = io,
        .output = &output.writer,
        .diagnostics = &output.writer,
        .filesystem_policy = .{ .roots = &.{.{ .name = name, .absolute_path = root_path, .permissions = .all }} },
    });
    defer runtime.deinit();
    allocator.free(name);
    allocator.free(root_path);
    try std.testing.expect((try runtime.runUnit("<fs-test>", "'root \"file\" fs.read-text")) == .ok);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("\"x\"", display.bytes());
}

test "fs: root handle authority survives renaming the configured directory" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(io, "original", .default_dir);
    try scratch.directory.dir.writeFile(io, .{ .sub_path = "original/file", .data = "kept" });
    const original = try std.fmt.allocPrint(allocator, "{s}/original", .{scratch.path});
    defer allocator.free(original);
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var runtime = try session.Session.initWithHost(heap.allocator(), &.{}, .{
        .io = io,
        .output = &output.writer,
        .diagnostics = &output.writer,
        .filesystem_policy = .{ .roots = &.{.{ .name = "root", .absolute_path = original, .permissions = .all }} },
    });
    defer runtime.deinit();
    try scratch.directory.dir.rename("original", scratch.directory.dir, "renamed", io);
    try scratch.directory.dir.createDir(io, "original", .default_dir);
    try scratch.directory.dir.writeFile(io, .{ .sub_path = "original/file", .data = "impostor" });
    try std.testing.expect((try runtime.runUnit("<fs-test>", "'root \"file\" fs.read-text")) == .ok);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("\"kept\"", display.bytes());
}

// -- reads, metadata, listing ------------------------------------------------

test "fs: text and byte reads round trip exactly across chunk boundaries" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const policy = scratch.allPolicy();
    try scratch.write("empty", "");
    try scratch.write("text", "héllo\nworld\n");
    try scratch.write("raw.bin", "\xff\x00\x7f");
    const big = try allocator.alloc(u8, 64 * 1024 * 3 + 17);
    defer allocator.free(big);
    for (big, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try scratch.write("big", big);

    try expectStack(policy, "'root \"empty\" fs.read-text 'root \"empty\" fs.read-bytes", "\"\" []");
    try expectStack(policy, "'root \"text\" fs.read-text dup len swap", "12 \"héllo\\nworld\\n\"");
    try expectStack(policy, "'root \"raw.bin\" fs.read-bytes", "[255 0 127]");
    try expectStack(policy, "'root \"big\" fs.read-bytes dup len swap 65536 at", "196625 25");
    try expectStack(policy, "'root \"big\" fs.read-bytes 'root \"big2\" fs.create-bytes 'root \"big2\" fs.read-bytes 'root \"big\" fs.read-bytes match?", "1");
    try expectFsFailure(policy, "'root \"raw.bin\" fs.read-text", "io", "fs.read-text", "invalid-utf8");
    try expectFsFailure(policy, "'root \"absent\" fs.read-text", "io", "fs.read-text", "not-found");
    try expectFsFailure(policy, "'root \".\" fs.read-text", "io", "fs.read-text", "is-directory");
    try scratch.directory.dir.createDir(io, "dir", .default_dir);
    try expectFsFailure(policy, "'root \"dir\" fs.read-bytes", "io", "fs.read-bytes", "is-directory");
    try expectFsFailure(policy, "'root \"text/child\" fs.read-text", "io", "fs.read-text", "not-directory");

    // The transfer limit is enforced from the observed size.
    const limited: Policy = .{
        .roots = &.{.{ .name = "root", .absolute_path = scratch.path, .permissions = .all }},
        .limits = .{ .max_transfer_bytes = 8 },
    };
    try expectFsFailure(limited, "'root \"big\" fs.read-bytes", "overflow", "fs.read-bytes", "limit");
    try expectStack(limited, "'root \"raw.bin\" fs.read-bytes", "[255 0 127]");
    try expectFsFailure(limited, "[1 2 3 4 5 6 7 8 9] 'root \"nine\" fs.create-bytes", "overflow", "fs.create-bytes", "limit");
    try scratch.expectAbsent("nine");
}

test "fs: stat lstat exists and list describe entries exactly" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const policy = scratch.allPolicy();
    try scratch.write("file", "12345");
    try scratch.directory.dir.createDir(io, "dir", .default_dir);
    try scratch.directory.dir.symLink(io, "file", "link", .{});
    try scratch.directory.dir.symLink(io, "nowhere", "dangling", .{});
    try scratch.directory.dir.writeFile(io, .{ .sub_path = "dir/z", .data = "" });
    try scratch.directory.dir.writeFile(io, .{ .sub_path = "dir/ä", .data = "" });
    try scratch.directory.dir.writeFile(io, .{ .sub_path = "dir/a", .data = "" });
    try scratch.directory.dir.createDir(io, "dir/sub", .default_dir);
    try scratch.directory.dir.symLink(io, "a", "dir/l", .{});

    try expectStack(policy, "'root \"file\" fs.stat", "{'kind 'file 'size 5}");
    try expectStack(policy, "'root \"dir\" fs.stat", "{'kind 'directory}");
    try expectStack(policy, "'root \".\" fs.stat", "{'kind 'directory}");
    try expectStack(policy, "'root \"link\" fs.stat", "{'kind 'file 'size 5}");
    try expectStack(policy, "'root \"link\" fs.lstat", "{'kind 'symlink}");
    try expectStack(policy, "'root \"dangling\" fs.lstat", "{'kind 'symlink}");
    try expectFsFailure(policy, "'root \"dangling\" fs.stat", "io", "fs.stat", "not-found");
    try expectFsFailure(policy, "'root \"absent\" fs.stat", "io", "fs.stat", "not-found");
    try expectFsFailure(policy, "'root \"absent\" fs.lstat", "io", "fs.lstat", "not-found");
    try expectStack(policy, "'root \"file\" fs.exists? 'root \"dangling\" fs.exists? 'root \"absent\" fs.exists? 'root \".\" fs.exists?", "1 1 0 1");
    try expectFsFailure(policy, "'root \"file/x\" fs.exists?", "io", "fs.exists?", "not-directory");
    // Listing is sorted by Unicode scalar order, classifies without
    // following, and excludes dot entries.
    try expectStack(
        policy,
        "'root \"dir\" fs.list",
        "({'name \"a\" 'kind 'file} {'name \"l\" 'kind 'symlink} {'name \"sub\" 'kind 'directory} {'name \"z\" 'kind 'file} {'name \"ä\" 'kind 'file})",
    );
    try expectStack(policy, "'root \"dir/sub\" fs.list", "()");
    try expectStack(policy, "'root \".\" fs.list len", "4");
    try expectFsFailure(policy, "'root \"file\" fs.list", "io", "fs.list", "not-directory");
    try expectFsFailure(policy, "'root \"absent\" fs.list", "io", "fs.list", "not-found");
    const limited: Policy = .{
        .roots = &.{.{ .name = "root", .absolute_path = scratch.path, .permissions = .all }},
        .limits = .{ .max_directory_entries = 3 },
    };
    try expectFsFailure(limited, "'root \"dir\" fs.list", "overflow", "fs.list", "limit");
    const byte_limited: Policy = .{
        .roots = &.{.{ .name = "root", .absolute_path = scratch.path, .permissions = .all }},
        .limits = .{ .max_directory_name_bytes = 4 },
    };
    try expectFsFailure(byte_limited, "'root \"dir\" fs.list", "overflow", "fs.list", "limit");
}

// -- mutation -------------------------------------------------------------------

test "fs: create is exclusive and replace is strict" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const policy = scratch.allPolicy();
    try scratch.directory.dir.createDir(io, "dir", .default_dir);
    try scratch.directory.dir.symLink(io, "nowhere", "dangling", .{});
    try scratch.write("existing", "old");

    try expectStack(policy, "\"héllo\" 'root \"new.txt\" fs.create-text 'root \"new.txt\" fs.read-text", "\"héllo\"");
    try expectStack(policy, "[0 255] 'root \"new.bin\" fs.create-bytes 'root \"new.bin\" fs.read-bytes", "[0 255]");
    try expectStack(policy, "\"\" 'root \"empty\" fs.create-text 'root \"empty\" fs.stat", "{'kind 'file 'size 0}");
    for ([_][]const u8{ "existing", "dir", "dangling", "new.txt" }) |collision| {
        const program = try std.fmt.allocPrint(allocator, "\"x\" 'root \"{s}\" fs.create-text", .{collision});
        defer allocator.free(program);
        try expectFsFailure(policy, program, "io", "fs.create-text", "already-exists");
    }
    const kept = try scratch.read("existing");
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("old", kept);
    try expectFsFailure(policy, "\"x\" 'root \"missing-dir/f\" fs.create-text", "io", "fs.create-text", "not-found");
    try expectFsFailure(policy, "\"x\" 'root \".\" fs.create-text", "domain", "fs.create-text", "invalid-path");

    try expectStack(policy, "\"newer\" 'root \"existing\" fs.replace-text 'root \"existing\" fs.read-text", "\"newer\"");
    try expectStack(policy, "[7] 'root \"existing\" fs.replace-bytes 'root \"existing\" fs.read-bytes", "[7]");
    try expectFsFailure(policy, "\"x\" 'root \"absent\" fs.replace-text", "io", "fs.replace-text", "not-found");
    try expectFsFailure(policy, "\"x\" 'root \"dir\" fs.replace-text", "io", "fs.replace-text", "not-regular");
    try scratch.directory.dir.symLink(io, "existing", "link", .{});
    try expectFsFailure(policy, "\"x\" 'root \"link\" fs.replace-text", "io", "fs.replace-text", "not-regular");
    try scratch.expectAbsent("absent");
    const through_link = try scratch.read("existing");
    defer allocator.free(through_link);
    try std.testing.expectEqualStrings("\x07", through_link);
    try scratch.expectNoStaging(".");
}

test "fs: mkdir copy rename and removal act on final entries without following" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const policy = scratch.allPolicy();
    try scratch.write("file", "payload");
    try scratch.directory.dir.symLink(io, "file", "link", .{});
    try scratch.directory.dir.symLink(io, "nowhere", "dangling", .{});

    try expectStack(policy, "'root \"made\" fs.mkdir 'root \"made\" fs.stat", "{'kind 'directory}");
    try expectFsFailure(policy, "'root \"made\" fs.mkdir", "io", "fs.mkdir", "already-exists");
    try expectFsFailure(policy, "'root \"file\" fs.mkdir", "io", "fs.mkdir", "already-exists");
    try expectFsFailure(policy, "'root \"nope/made\" fs.mkdir", "io", "fs.mkdir", "not-found");
    try expectFsFailure(policy, "'root \"file/made\" fs.mkdir", "io", "fs.mkdir", "not-directory");

    try expectStack(policy, "'root \"file\" 'root \"made/copy\" fs.copy 'root \"made/copy\" fs.read-text", "\"payload\"");
    try expectStack(policy, "'root \"link\" 'root \"made/via-link\" fs.copy 'root \"made/via-link\" fs.read-text", "\"payload\"");
    try expectFsFailure(policy, "'root \"file\" 'root \"made/copy\" fs.copy", "io", "fs.copy", "already-exists");
    try expectFsFailure(policy, "'root \"made\" 'root \"made/again\" fs.copy", "io", "fs.copy", "is-directory");
    try expectFsFailure(policy, "'root \"absent\" 'root \"made/again\" fs.copy", "io", "fs.copy", "not-found");
    try expectFsFailure(policy, "'root \"file\" 'root \".\" fs.copy", "domain", "fs.copy", "invalid-path");
    try scratch.expectAbsent("made/again");

    try expectStack(policy, "'root \"made/copy\" \"renamed\" fs.rename 'root \"renamed\" fs.exists? 'root \"made/copy\" fs.exists?", "1 0");
    try expectStack(policy, "'root \"made\" \"moved-dir\" fs.rename 'root \"moved-dir/via-link\" fs.exists?", "1");
    try expectStack(policy, "'root \"link\" \"moved-link\" fs.rename 'root \"moved-link\" fs.lstat", "{'kind 'symlink}");
    try expectFsFailure(policy, "'root \"renamed\" \"file\" fs.rename", "io", "fs.rename", "already-exists");
    try expectFsFailure(policy, "'root \"absent\" \"x\" fs.rename", "io", "fs.rename", "not-found");
    try expectFsFailure(policy, "'root \".\" \"x\" fs.rename", "domain", "fs.rename", "invalid-path");
    const untouched = try scratch.read("file");
    defer allocator.free(untouched);
    try std.testing.expectEqualStrings("payload", untouched);

    try expectStack(policy, "'root \"moved-link\" fs.remove-file 'root \"moved-link\" fs.exists? 'root \"file\" fs.exists?", "0 1");
    try expectStack(policy, "'root \"dangling\" fs.remove-file 'root \"dangling\" fs.exists?", "0");
    try expectFsFailure(policy, "'root \"moved-dir\" fs.remove-file", "io", "fs.remove-file", "is-directory");
    try expectFsFailure(policy, "'root \"absent\" fs.remove-file", "io", "fs.remove-file", "not-found");
    try expectFsFailure(policy, "'root \"moved-dir\" fs.remove-dir", "io", "fs.remove-dir", "not-empty");
    try expectFsFailure(policy, "'root \"file\" fs.remove-dir", "io", "fs.remove-dir", "not-directory");
    try scratch.directory.dir.symLink(io, "moved-dir", "dir-link", .{});
    try expectFsFailure(policy, "'root \"dir-link\" fs.remove-dir", "io", "fs.remove-dir", "not-directory");
    try expectStack(policy, "'root \"moved-dir/via-link\" fs.remove-file 'root \"moved-dir\" fs.remove-dir 'root \"moved-dir\" fs.exists?", "0");
    try scratch.expectNoStaging(".");
}

// -- symlink containment ------------------------------------------------------

test "fs: symlink resolution is confined to the root" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.directory.dir.createDir(io, "root", .default_dir);
    try scratch.directory.dir.createDir(io, "root-escape", .default_dir);
    try scratch.directory.dir.writeFile(io, .{ .sub_path = "root-escape/secret", .data = "outside" });
    try scratch.write("outside", "outside");
    try scratch.directory.dir.createDir(io, "root/a", .default_dir);
    try scratch.directory.dir.createDir(io, "root/a/b", .default_dir);
    try scratch.directory.dir.writeFile(io, .{ .sub_path = "root/a/b/file", .data = "inside" });
    try scratch.directory.dir.symLink(io, "a/b", "root/inside", .{});
    try scratch.directory.dir.symLink(io, "../outside", "root/escape", .{});
    try scratch.directory.dir.symLink(io, "../../outside", "root/a/deep-escape", .{});
    try scratch.directory.dir.symLink(io, "../root-escape/secret", "root/sibling", .{});
    const absolute_outside = try std.fmt.allocPrint(allocator, "{s}/outside", .{scratch.path});
    defer allocator.free(absolute_outside);
    try scratch.directory.dir.symLink(io, absolute_outside, "root/absolute", .{});
    try scratch.directory.dir.symLink(io, "../a/b", "root/a/safe-parent", .{});
    try scratch.directory.dir.symLink(io, "loop", "root/loop", .{});
    try scratch.directory.dir.symLink(io, "ping", "root/pong", .{});
    try scratch.directory.dir.symLink(io, "pong", "root/ping", .{});
    try scratch.directory.dir.symLink(io, "a/b/file", "root/to-file", .{});
    const root_path = try std.fmt.allocPrint(allocator, "{s}/root", .{scratch.path});
    defer allocator.free(root_path);
    const policy: Policy = .{ .roots = &.{.{ .name = "root", .absolute_path = root_path, .permissions = .all }} };

    try expectStack(policy, "'root \"inside/file\" fs.read-text", "\"inside\"");
    try expectStack(policy, "'root \"a/safe-parent/file\" fs.read-text", "\"inside\"");
    try expectStack(policy, "'root \"to-file\" fs.read-text", "\"inside\"");
    try expectStack(policy, "'root \"inside\" fs.stat 'root \"inside\" fs.lstat", "{'kind 'directory} {'kind 'symlink}");
    try expectStack(policy, "'root \"escape\" fs.exists? 'root \"escape\" fs.lstat", "1 {'kind 'symlink}");
    for ([_][]const u8{ "escape", "a/deep-escape", "sibling", "absolute" }) |name| {
        const read = try std.fmt.allocPrint(allocator, "'root \"{s}\" fs.read-text", .{name});
        defer allocator.free(read);
        try expectFsFailure(policy, read, "io", "fs.read-text", "symlink-escape");
        const stat = try std.fmt.allocPrint(allocator, "'root \"{s}\" fs.stat", .{name});
        defer allocator.free(stat);
        try expectFsFailure(policy, stat, "io", "fs.stat", "symlink-escape");
        const through = try std.fmt.allocPrint(allocator, "'root \"{s}/child\" fs.exists?", .{name});
        defer allocator.free(through);
        try expectFsFailure(policy, through, "io", "fs.exists?", "symlink-escape");
    }
    try expectFsFailure(policy, "'root \"loop\" fs.read-text", "io", "fs.read-text", "symlink-loop");
    try expectFsFailure(policy, "'root \"ping\" fs.stat", "io", "fs.stat", "symlink-loop");
    try expectFsFailure(policy, "'root \"to-file/x\" fs.exists?", "io", "fs.exists?", "not-directory");
    // A link is a collision for create and mkdir, rejected by replace, and
    // removed as itself.
    try expectFsFailure(policy, "\"x\" 'root \"escape\" fs.create-text", "io", "fs.create-text", "already-exists");
    try expectFsFailure(policy, "'root \"escape\" fs.mkdir", "io", "fs.mkdir", "already-exists");
    try expectFsFailure(policy, "\"x\" 'root \"to-file\" fs.replace-text", "io", "fs.replace-text", "not-regular");
    try expectStack(policy, "'root \"escape\" fs.remove-file 'root \"escape\" fs.exists?", "0");
    const outside = try scratch.read("outside");
    defer allocator.free(outside);
    try std.testing.expectEqualStrings("outside", outside);
    const secret = try scratch.read("root-escape/secret");
    defer allocator.free(secret);
    try std.testing.expectEqualStrings("outside", secret);
    const expansion_limited: Policy = .{
        .roots = &.{.{ .name = "root", .absolute_path = root_path, .permissions = .all }},
        .limits = .{ .max_resolved_path_bytes = 12 },
    };
    try expectFsFailure(expansion_limited, "'root \"inside/file\" fs.read-text", "overflow", "fs.read-text", "limit");
    // The initial path pays into the same budget as spliced link targets, so
    // a long link-free path is refused before any handle is opened.
    try expectFsFailure(expansion_limited, "'root \"a/b/file-with-a-long-name\" fs.exists?", "overflow", "fs.exists?", "limit");
    try expectStack(expansion_limited, "'root \"a/b/file\" fs.exists?", "1");
}

// -- limits, cancellation, concurrency ---------------------------------------

test "fs: cancellation before commit leaves the destination unchanged" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.write("existing", "prior");
    var heap: test_heap.SessionHeap = .init;
    defer test_heap.retire(&heap);
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&output_buffer);
    var runtime = try session.Session.initWithHostConfig(heap.allocator(), &.{}, .{
        .io = io,
        .output = &output.writer,
        .diagnostics = &output.writer,
        .filesystem_policy = scratch.allPolicy(),
    }, .cooperative);
    defer runtime.deinit();
    try std.testing.expect((try runtime.runUnit("<fs-warm>", "'root \"existing\" fs.exists? pop")) == .ok);
    runtime.requestCancellation();
    for ([_][]const u8{
        "\"new\" 'root \"existing\" fs.replace-text",
        "\"new\" 'root \"created\" fs.create-text",
        "'root \"existing\" 'root \"copied\" fs.copy",
        "'root \".\" fs.list",
        "'root \"existing\" fs.read-text",
    }) |program| {
        const failure = switch (try runtime.runUnit("<fs-cancel>", program)) {
            .err => |item| item,
            .ok, .incomplete => return error.ExpectedCancellation,
        };
        defer runtime.release(failure);
        try support.expectLanguageError(failure, .{ .name = program, .source = program, .kind = "cancelled" });
    }
    runtime.clearCancellation();
    const preserved = try scratch.read("existing");
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("prior", preserved);
    try scratch.expectAbsent("created");
    try scratch.expectAbsent("copied");
    try scratch.expectNoStaging(".");
    try std.testing.expectEqual(@as(usize, 1), try scratch.entryCount("."));
    // The quota slot was released by cancellation cleanup: the next
    // operation still runs.
    try std.testing.expect((try runtime.runUnit("<fs-after>", "'root \"existing\" fs.read-text pop")) == .ok);
}

test "fs: the live-operation quota is released after each operation" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.write("file", "x");
    const policy: Policy = .{
        .roots = &.{.{ .name = "root", .absolute_path = scratch.path, .permissions = .all }},
        .limits = .{ .max_live_operations = 1 },
    };
    // Sequential operations each take and release the single slot.
    try expectStack(policy, "'root \"file\" fs.read-text 'root \"file\" fs.read-text 'root \"file\" fs.exists?", "\"x\" \"x\" 1");
    // Concurrent tasks contend for one slot. Whether they overlap is a
    // scheduling fact, so the assertion is the invariant: every outcome is
    // success or the limit reason, at least one succeeds, and the slot is
    // free again afterwards. Exhaustion itself is proven deterministically
    // by the filesystem port's own reservation test.
    const big = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(big);
    @memset(big, 'y');
    try scratch.write("big", big);
    try runCase(policy, .{ .worker_pool = 2 },
        \\[] ('root "big" fs.read-bytes len) @spawn [] ('root "big" fs.read-bytes len) @spawn
        \\pair await-all (dup 'ok dict.has? (pop 'ok) ('err at 'data at 'reason at) if) each
        \\dup ('ok match?) filter len 1 >= swap (dup 'ok match? swap 'limit match? or) all? and
        \\'root "file" fs.read-text
    , .{ .stack = "1 \"x\"" });
}

test "fs: concurrent creates have exactly one winner and no staging residue" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const Shared = struct {
        path: []const u8,
        successes: std.atomic.Value(u32) = .init(0),
        collisions: std.atomic.Value(u32) = .init(0),
        unexpected: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var heap: test_heap.SessionHeap = .init;
            defer test_heap.retire(&heap);
            var output_buffer: [64]u8 = undefined;
            var output = std.Io.Writer.Discarding.init(&output_buffer);
            var runtime = session.Session.initWithHostConfig(heap.allocator(), &.{}, .{
                .io = io,
                .output = &output.writer,
                .diagnostics = &output.writer,
                .filesystem_policy = .{ .roots = &.{.{ .name = "root", .absolute_path = self.path, .permissions = .all }} },
            }, .{ .worker_pool = 2 }) catch {
                self.unexpected.store(true, .release);
                return;
            };
            defer runtime.deinit();
            const program = "\"winner\" 'root \"target\" fs.create-text";
            const outcome = runtime.runUnit("<fs-race>", program) catch {
                self.unexpected.store(true, .release);
                return;
            };
            switch (outcome) {
                .ok => _ = self.successes.fetchAdd(1, .monotonic),
                .incomplete => self.unexpected.store(true, .release),
                .err => |failure| {
                    const fields = [_]support.DataField{
                        .{ .name = "operation", .expected = .{ .symbol = "create-text" } },
                        .{ .name = "root", .expected = .{ .symbol = "root" } },
                        .{ .name = "reason", .expected = .{ .symbol = "already-exists" } },
                    };
                    support.expectLanguageError(failure, .{
                        .name = "loser",
                        .source = program,
                        .kind = "io",
                        .word = "fs.create-text",
                        .data = &fields,
                    }) catch self.unexpected.store(true, .release);
                    runtime.release(failure);
                    _ = self.collisions.fetchAdd(1, .monotonic);
                },
            }
        }
    };
    var shared: Shared = .{ .path = scratch.path };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    for (threads) |thread| thread.join();
    try std.testing.expect(!shared.unexpected.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), shared.successes.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), shared.collisions.load(.acquire));
    const winner = try scratch.read("target");
    defer allocator.free(winner);
    try std.testing.expectEqualStrings("winner", winner);
    try scratch.expectNoStaging(".");
    try std.testing.expectEqual(@as(usize, 1), try scratch.entryCount("."));
}

test "fs: words cold-load through the builtin manifest and are documented" {
    try support.expectStack("'fs.read-text doc len 0 > 'path.normalize doc len 0 >", "1 1");
    try support.expectStack("'fs ('exists?) import 'path ('join) import (\"a\" \"b\") join", "\"a/b\"");
}
