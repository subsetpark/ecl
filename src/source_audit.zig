//! Build-time source architecture and line-budget audit.
const std = @import("std");

// Strong nominal/capability boundaries are deliberately budgeted as
// production architecture, not treated as overhead to squeeze away.
const core_budget: usize = 22_000;

const Component = struct {
    name: []const u8,
    budget: usize,
    files: []const []const u8,
    sources: []const [:0]const u8,
};

const components = [_]Component{
    .{ .name = "values+RC", .budget = 3500, .files = &.{
        "value.zig", "heap.zig", "intern.zig", "list.zig",
        "equal.zig", "dict.zig", "print.zig",  "poll.zig",
    }, .sources = &.{
        @embedFile("value.zig"),  @embedFile("heap.zig"),
        @embedFile("intern.zig"), @embedFile("list.zig"),
        @embedFile("equal.zig"),  @embedFile("dict.zig"),
        @embedFile("print.zig"),  @embedFile("poll.zig"),
    } },
    .{ .name = "reader", .budget = 1900, .files = &.{
        "lexer.zig", "binder.zig", "reader.zig",
    }, .sources = &.{
        @embedFile("lexer.zig"),  @embedFile("binder.zig"),
        @embedFile("reader.zig"),
    } },
    .{ .name = "machine", .budget = 3000, .files = &.{
        "machine.zig", "spans.zig", "prims.zig", "root.zig",
    }, .sources = &.{
        @embedFile("machine.zig"), @embedFile("spans.zig"),
        @embedFile("prims.zig"),   @embedFile("root.zig"),
    } },
    .{ .name = "modules and registry", .budget = 2600, .files = &.{
        "env.zig", "modules.zig", "module_prims.zig", "reflection.zig", "session.zig",
    }, .sources = &.{
        @embedFile("env.zig"),          @embedFile("modules.zig"),
        @embedFile("module_prims.zig"), @embedFile("reflection.zig"),
        @embedFile("session.zig"),
    } },
    .{ .name = "bootstrap prelude", .budget = 150, .files = &.{
        "prelude.zig",
    }, .sources = &.{
        @embedFile("prelude.zig"),
    } },
    .{ .name = "combinators", .budget = 1200, .files = &.{
        "combinators.zig",
    }, .sources = &.{
        @embedFile("combinators.zig"),
    } },
    .{ .name = "definition annotations", .budget = 1000, .files = &.{
        "definition_prims.zig", "doc.zig",
    }, .sources = &.{
        @embedFile("definition_prims.zig"), @embedFile("doc.zig"),
    } },
    .{ .name = "CLI and formatter", .budget = 1900, .files = &.{
        "main.zig", "formatter.zig",
    }, .sources = &.{
        @embedFile("main.zig"), @embedFile("formatter.zig"),
    } },
    .{ .name = "kernels and idioms", .budget = 5500, .files = &.{
        "kernel_support.zig",  "kernels.zig",      "kernel_storage.zig",   "kernel_numeric.zig",
        "kernel_sequence.zig", "kernel_order.zig", "kernel_dict_text.zig", "idioms.zig",
    }, .sources = &.{
        @embedFile("kernel_support.zig"),   @embedFile("kernels.zig"),
        @embedFile("kernel_storage.zig"),   @embedFile("kernel_numeric.zig"),
        @embedFile("kernel_sequence.zig"),  @embedFile("kernel_order.zig"),
        @embedFile("kernel_dict_text.zig"), @embedFile("idioms.zig"),
    } },
    .{ .name = "source tooling", .budget = 1400, .files = &.{
        "source_audit.zig",
    }, .sources = &.{
        @embedFile("source_audit.zig"),
    } },
};

const test_files = [_][]const u8{
    "testgen.zig",             "reader_test.zig",
    "machine_test.zig",        "module_test.zig",
    "value_test.zig",          "kernel_test_support.zig",
    "kernel_numeric_test.zig", "kernel_sequence_test.zig",
    "kernel_order_test.zig",   "kernel_dict_text_test.zig",
    "combinator_test.zig",     "prelude_test.zig",
    "definition_test.zig",     "formatter_test.zig",
    "oom_test.zig",            "oom_root.zig",
};
const test_sources = [_][:0]const u8{
    @embedFile("testgen.zig"),             @embedFile("reader_test.zig"),
    @embedFile("machine_test.zig"),        @embedFile("module_test.zig"),
    @embedFile("value_test.zig"),          @embedFile("kernel_test_support.zig"),
    @embedFile("kernel_numeric_test.zig"), @embedFile("kernel_sequence_test.zig"),
    @embedFile("kernel_order_test.zig"),   @embedFile("kernel_dict_text_test.zig"),
    @embedFile("combinator_test.zig"),     @embedFile("prelude_test.zig"),
    @embedFile("definition_test.zig"),     @embedFile("formatter_test.zig"),
    @embedFile("oom_test.zig"),            @embedFile("oom_root.zig"),
};

pub fn main(init: std.process.Init) !void {
    var failed = false;
    var core_lines: usize = 0;
    for (components) |component| {
        if (component.files.len != component.sources.len) return error.SourceAuditFailed;
        var component_lines: usize = 0;
        for (component.sources) |source| component_lines += countCoreLines(source);
        std.log.info("{s}: {d}/{d} core lines", .{ component.name, component_lines, component.budget });
        core_lines += component_lines;
        failed = failed or component_lines > component.budget;
    }
    var test_lines: usize = 0;
    for (components) |component| for (component.sources) |source| {
        test_lines += countLines(source) - countCoreLines(source);
    };
    for (test_sources) |source| test_lines += countLines(source);
    std.log.info("line budget: {d}/{d} Zig core, {d} test lines, {d} total", .{
        core_lines,
        core_budget,
        test_lines,
        core_lines + test_lines,
    });
    failed = failed or core_lines > core_budget;
    failed = auditSourceCoverage(init) or failed;
    failed = auditTraversalSources() or failed;
    failed = auditPreludeLayout() or failed;
    if (failed) return error.SourceAuditFailed;
}

fn auditSourceCoverage(init: std.process.Init) bool {
    var directory = std.Io.Dir.cwd().openDir(init.io, "src", .{ .iterate = true }) catch |err| {
        std.log.err("source coverage: cannot open src: {s}", .{@errorName(err)});
        return true;
    };
    defer directory.close(init.io);
    var iterator = directory.iterateAssumeFirstIteration();
    var failed = false;
    var production_count: usize = 0;
    var test_count: usize = 0;
    while (iterator.next(init.io) catch |err| {
        std.log.err("source coverage: cannot enumerate src: {s}", .{@errorName(err)});
        return true;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        var matches: usize = 0;
        for (components) |component| for (component.files) |file| {
            matches += @intFromBool(std.mem.eql(u8, entry.name, file));
        };
        for (test_files) |file| matches += @intFromBool(std.mem.eql(u8, entry.name, file));
        if (matches != 1) {
            std.log.err("source coverage: {s} belongs to {d} components; expected exactly one", .{
                entry.name, matches,
            });
            failed = true;
            continue;
        }
        var is_test = false;
        for (test_files) |file| is_test = is_test or std.mem.eql(u8, entry.name, file);
        if (is_test) test_count += 1 else production_count += 1;
    }
    std.log.info("source coverage: {d} production and {d} test/tool inputs classified", .{
        production_count, test_count,
    });
    return failed;
}

const PreludeStage = enum { header, body, annotation, name, def };

fn auditPreludeLayout() bool {
    const source = @embedFile("prelude.ecl");
    var stage: PreludeStage = .header;
    var expected_name: []const u8 = &.{};
    var definitions: usize = 0;
    var index: usize = 0;
    while (true) {
        switch (stage) {
            .header => {
                if (definitions > 0) {
                    if (std.mem.eql(u8, source[index..], "\n")) {
                        index = source.len;
                        break;
                    }
                    if (!std.mem.startsWith(u8, source[index..], "\n\n")) {
                        std.log.err("prelude layout: definitions require exactly one empty line", .{});
                        return true;
                    }
                    index += 2;
                }
            },
            .body => {
                if (index == source.len or source[index] != '\n') {
                    std.log.err("prelude layout: header must be followed by its definition body", .{});
                    return true;
                }
                index += 1;
            },
            .annotation, .name => {
                if (index == source.len or source[index] != '\n') {
                    std.log.err("prelude layout: definition block stages must occupy separate lines", .{});
                    return true;
                }
                index += 1;
            },
            .def => {
                if (index == source.len or source[index] != ' ') {
                    std.log.err("prelude layout: terminal name and def require one separating space", .{});
                    return true;
                }
                index += 1;
            },
        }
        if (index == source.len) break;
        if (source[index] == '#') {
            const end = std.mem.indexOfScalarPos(u8, source, index, '\n') orelse source.len;
            var line = source[index..end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const navigation = std.mem.startsWith(u8, line, "### def ");
            const legacy_navigation = std.mem.startsWith(u8, line, "# def ");
            if (stage == .body and !navigation and !legacy_navigation) {
                index = end;
                continue;
            }
            if (!navigation) {
                std.log.err("prelude layout: unexpected top-level comment `{s}`", .{line});
                return true;
            }
            const name = line[8..];
            if (stage != .header or !validHeaderName(name)) {
                std.log.err("prelude layout: misplaced or malformed navigation header `{s}`", .{line});
                return true;
            }
            expected_name = name;
            stage = .body;
            index = end;
            continue;
        }
        switch (stage) {
            .header => {
                std.log.err("prelude layout: definition lacks a ### def <name> header", .{});
                return true;
            },
            .body, .annotation => {
                if (source[index] != '(' or !skipPreludeQuotation(source, &index)) {
                    std.log.err("prelude layout: {s} for `{s}` is not one complete quotation", .{
                        @tagName(stage), expected_name,
                    });
                    return true;
                }
                stage = if (stage == .body) .annotation else .name;
            },
            .name => {
                if (source[index] != '\'') {
                    std.log.err("prelude layout: `{s}` lacks its terminal quoted name", .{expected_name});
                    return true;
                }
                const end = preludeTokenEnd(source, index);
                if (!std.mem.eql(u8, source[index + 1 .. end], expected_name)) {
                    std.log.err("prelude layout: header `{s}` does not match terminal `{s}`", .{
                        expected_name, source[index + 1 .. end],
                    });
                    return true;
                }
                index = end;
                stage = .def;
            },
            .def => {
                const end = preludeTokenEnd(source, index);
                if (!std.mem.eql(u8, source[index..end], "def")) {
                    std.log.err("prelude layout: `{s}` does not terminate in def", .{expected_name});
                    return true;
                }
                index = end;
                definitions += 1;
                stage = .header;
            },
        }
    }
    if (stage != .header or definitions == 0) {
        std.log.err("prelude layout: incomplete definition block", .{});
        return true;
    }
    std.log.info("prelude layout: {d} documented definition blocks", .{definitions});
    return false;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (std.ascii.isWhitespace(byte) or byte == ',') return false;
    return true;
}

fn skipPreludeQuotation(source: []const u8, index: *usize) bool {
    var depth: usize = 0;
    while (index.* < source.len) {
        switch (source[index.*]) {
            '"' => if (!skipPreludeString(source, index)) return false,
            '#' => {
                index.* = std.mem.indexOfScalarPos(u8, source, index.*, '\n') orelse source.len;
            },
            '(' => {
                depth += 1;
                index.* += 1;
            },
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
                index.* += 1;
                if (depth == 0) return true;
            },
            else => index.* += 1,
        }
    }
    return false;
}

fn skipPreludeString(source: []const u8, index: *usize) bool {
    index.* += 1;
    while (index.* < source.len) {
        if (source[index.*] == '\\') {
            index.* += 1;
            if (index.* == source.len) return false;
            index.* += 1;
        } else if (source[index.*] == '"') {
            index.* += 1;
            return true;
        } else index.* += 1;
    }
    return false;
}

fn preludeTokenEnd(source: []const u8, start: usize) usize {
    var end = start;
    while (end < source.len and !std.ascii.isWhitespace(source[end]) and
        std.mem.indexOfScalar(u8, "(),[]{}#", source[end]) == null)
    {
        end += 1;
    }
    return end;
}

fn countLines(source: []const u8) usize {
    var lines: usize = 0;
    for (source) |byte| lines += @intFromBool(byte == '\n');
    return lines + @intFromBool(source.len > 0 and source[source.len - 1] != '\n');
}

fn countCoreLines(source: [:0]const u8) usize {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return countLines(source);
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return countLines(source);
    const line_count = countLines(source);
    const excluded = std.heap.page_allocator.alloc(bool, line_count) catch return countLines(source);
    defer std.heap.page_allocator.free(excluded);
    @memset(excluded, false);
    for (tree.rootDecls()) |declaration| {
        if (tree.nodeTag(declaration) != .test_decl) continue;
        const first = tree.firstToken(declaration);
        const last = tree.lastToken(declaration);
        const start = tree.tokenStart(first);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        var line: usize = 0;
        var offset: usize = 0;
        while (offset < source.len and offset < end) : (line += 1) {
            const next = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
            if (next >= start and offset < end) excluded[line] = true;
            offset = @min(next + 1, source.len);
        }
    }
    var result: usize = 0;
    for (excluded) |is_excluded| result += @intFromBool(!is_excluded);
    return result;
}

fn auditTraversalSources() bool {
    const Source = struct { name: []const u8, text: [:0]const u8 };
    const traversal_sources = [_]Source{
        .{ .name = "equal", .text = @embedFile("equal.zig") },
        .{ .name = "print", .text = @embedFile("print.zig") },
        .{ .name = "numeric kernels", .text = @embedFile("kernel_numeric.zig") },
        .{ .name = "sequence kernels", .text = @embedFile("kernel_sequence.zig") },
        .{ .name = "order kernels", .text = @embedFile("kernel_order.zig") },
        .{ .name = "dict/text kernels", .text = @embedFile("kernel_dict_text.zig") },
        .{ .name = "kernel storage", .text = @embedFile("kernel_storage.zig") },
        .{ .name = "module primitives", .text = @embedFile("module_prims.zig") },
        .{ .name = "reflection", .text = @embedFile("reflection.zig") },
        .{ .name = "definition primitives", .text = @embedFile("definition_prims.zig") },
        .{ .name = "documentation", .text = @embedFile("doc.zig") },
    };
    const traversal_forbidden = [_][]const []const u8{
        &.{ "std", ".", "ArrayList" },
        &.{"AutoHashMap"},
        &.{"AutoHashMapUnmanaged"},
        &.{ "std", ".", "mem", ".", "sort" },
        &.{ "Writer", ".", "Allocating" },
        &.{ "publicNamesOwned", "(", "self", ".", "unit", ".", "allocator", ",", "null" },
        &.{ "writeAll", "(", "intern", ".", "get" },
        &.{ "print", "(", "\"{s}\"" },
    };
    var failed = false;
    const rehashing_maps = [_][]const []const u8{
        &.{"AutoHashMap"},
        &.{"AutoHashMapUnmanaged"},
    };
    for (components) |component| for (component.sources, component.files) |source, file| {
        failed = auditTokens(file, source, &rehashing_maps) or failed;
    };
    for (traversal_sources) |source| {
        failed = auditTokens(source.name, source.text, &traversal_forbidden) or failed;
    }
    failed = auditFunctionTokens(
        "machine reflection",
        @embedFile("machine.zig"),
        "shadowTraceIdsOwned",
        &traversal_forbidden,
    ) or failed;
    const storage_forbidden = [_][]const []const u8{
        &.{"AutoHashMap"},
        &.{"AutoHashMapUnmanaged"},
    };
    failed = auditTokens("span archive", @embedFile("spans.zig"), &storage_forbidden) or failed;
    failed = auditTokens("reader provenance", @embedFile("reader.zig"), &storage_forbidden) or failed;
    const work_forbidden = [_][]const []const u8{
        &.{"pollOptional"},
        &.{ "poller", ".", "charge" },
    };
    const work_sources = [_]Source{
        .{ .name = "poll substrate", .text = @embedFile("poll.zig") },
        .{ .name = "lexer", .text = @embedFile("lexer.zig") },
        .{ .name = "binder", .text = @embedFile("binder.zig") },
        .{ .name = "reader", .text = @embedFile("reader.zig") },
        .{ .name = "interning", .text = @embedFile("intern.zig") },
        .{ .name = "output reflection", .text = @embedFile("reflection.zig") },
        .{ .name = "documentation", .text = @embedFile("doc.zig") },
    };
    for (work_sources) |source| failed = auditTokens(source.name, source.text, &work_forbidden) or failed;
    const identifier_forbidden = [_][]const []const u8{
        &.{ "std", ".", "mem", ".", "indexOfScalar" },
    };
    failed = auditTokens("definition names", @embedFile("definition_prims.zig"), &identifier_forbidden) or failed;
    failed = auditTokens("module names", @embedFile("module_prims.zig"), &identifier_forbidden) or failed;
    failed = auditFunctionTokens(
        "formatter lookahead",
        @embedFile("formatter.zig"),
        "fits",
        &.{
            &.{ "std", ".", "ArrayList" },
            &.{ "allocator", ".", "alloc" },
            &.{ "allocator", ".", "dupe" },
        },
    ) or failed;
    return failed;
}

fn auditTokens(
    label: []const u8,
    source: [:0]const u8,
    forbidden: []const []const []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch {
        std.log.err("{s}: could not parse source for architecture audit", .{label});
        return true;
    };
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) {
        std.log.err("{s}: source has parser errors during architecture audit", .{label});
        return true;
    }
    return hasForbiddenTokens(label, tree, 0, tree.tokens.len, forbidden);
}

fn auditFunctionTokens(
    label: []const u8,
    source: [:0]const u8,
    function_name: []const u8,
    forbidden: []const []const []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    var node_index: usize = 0;
    while (node_index < tree.nodes.len) : (node_index += 1) {
        const node: std.zig.Ast.Node.Index = @enumFromInt(node_index);
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        const name_token = function.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), function_name)) continue;
        return hasForbiddenTokens(
            label,
            tree,
            tree.firstToken(node),
            tree.lastToken(node) + 1,
            forbidden,
        );
    }
    std.log.err("{s}: audited function `{s}` was not found", .{ label, function_name });
    return true;
}

fn hasForbiddenTokens(
    label: []const u8,
    tree: std.zig.Ast,
    first: usize,
    end: usize,
    forbidden: []const []const []const u8,
) bool {
    var failed = false;
    for (forbidden) |pattern| {
        var index = first;
        while (index + pattern.len <= end) : (index += 1) {
            for (pattern, 0..) |expected, offset| {
                if (!std.mem.eql(u8, tree.tokenSlice(@intCast(index + offset)), expected)) break;
            } else {
                std.log.err("{s}: forbidden syntax begins at token `{s}`", .{ label, pattern[0] });
                failed = true;
                break;
            }
        }
    }
    return failed;
}
