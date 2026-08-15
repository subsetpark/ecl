//! Build-time source architecture and line-budget audit.
const std = @import("std");

// Strong nominal/capability boundaries in shipped product code are deliberately
// budgeted, not treated as overhead to squeeze away. Verification code is
// classified and reported, but never consumes the business-logic allowance.
const business_logic_budget: usize = 30_000;

const Component = struct {
    name: []const u8,
    budget: ?usize,
    files: []const []const u8,
    sources: []const [:0]const u8,
};

const components = [_]Component{
    // Exact, non-rehashing map construction and resumable interning keep
    // user-sized storage work outside scheduler-native stacks.
    .{ .name = "values+RC", .budget = 4200, .files = &.{
        "value.zig", "heap.zig", "intern.zig", "list.zig",
        "equal.zig", "dict.zig", "print.zig",  "poll.zig",
    }, .sources = &.{
        @embedFile("../value.zig"),  @embedFile("../heap.zig"),
        @embedFile("../intern.zig"), @embedFile("../list.zig"),
        @embedFile("../equal.zig"),  @embedFile("../dict.zig"),
        @embedFile("../print.zig"),  @embedFile("../poll.zig"),
    } },
    // Tokenization, parsing, binder lowering, exact materialization, and
    // provenance publication all carry nominal resumable state. The larger
    // boundary replaces native-stack control flow; tests remain uncapped.
    .{ .name = "reader", .budget = 3300, .files = &.{
        "lexer.zig", "binder.zig", "reader_types.zig", "reader.zig", "reader_cursor.zig",
    }, .sources = &.{
        @embedFile("../lexer.zig"),         @embedFile("../binder.zig"),
        @embedFile("../reader_types.zig"),  @embedFile("../reader.zig"),
        @embedFile("../reader_cursor.zig"),
    } },
    // Resumable primitive shells own inputs and exact-size partial outputs;
    // their nominal driver states replace cancellation-only native stacks.
    // Source/file continuations and the typed, resumable failure unwinder make
    // ownership transfers explicit; this replaces hidden native traversal
    // frames and the duplicate synchronous error-value implementation.
    .{ .name = "machine", .budget = 5200, .files = &.{
        "machine.zig", "task_join_core.zig", "resolution_core.zig", "spans.zig", "prims.zig", "root.zig",
    }, .sources = &.{
        @embedFile("../machine.zig"),         @embedFile("../task_join_core.zig"),
        @embedFile("../resolution_core.zig"), @embedFile("../spans.zig"),
        @embedFile("../prims.zig"),           @embedFile("../root.zig"),
    } },
    // Snapshot-safe lookup, publication, and reflection now expose explicit
    // cursor state so scheduler suspension is represented instead of hidden
    // in cancellation-only loops.
    .{ .name = "modules and registry", .budget = 4400, .files = &.{
        "env.zig", "modules.zig", "snapshot_core.zig", "module_prims.zig", "reflection.zig", "session.zig",
    }, .sources = &.{
        @embedFile("../env.zig"),           @embedFile("../modules.zig"),
        @embedFile("../snapshot_core.zig"), @embedFile("../module_prims.zig"),
        @embedFile("../reflection.zig"),    @embedFile("../session.zig"),
    } },
    .{ .name = "bootstrap prelude", .budget = 150, .files = &.{
        "prelude.zig",
    }, .sources = &.{
        @embedFile("../prelude.zig"),
    } },
    .{ .name = "combinators", .budget = 1200, .files = &.{
        "combinators.zig",
    }, .sources = &.{
        @embedFile("../combinators.zig"),
    } },
    .{ .name = "definition annotations", .budget = 1000, .files = &.{
        "definition_prims.zig", "doc.zig",
    }, .sources = &.{
        @embedFile("../definition_prims.zig"), @embedFile("../doc.zig"),
    } },
    // Names, reflective prose, and fixed effects are one compile-time registry;
    // the ceiling covers that deliberate single source of truth.
    .{ .name = "primitive documentation", .budget = 300, .files = &.{
        "primitive_docs.zig",
    }, .sources = &.{
        @embedFile("../primitive_docs.zig"),
    } },
    .{ .name = "CLI and formatter", .budget = 1900, .files = &.{
        "main.zig", "formatter.zig",
    }, .sources = &.{
        @embedFile("../main.zig"), @embedFile("../formatter.zig"),
    } },
    // Explicit continuation state is part of the kernel correctness boundary;
    // the prior ceiling assumed native-stack traversals that could not yield.
    .{ .name = "kernels and idioms", .budget = 8500, .files = &.{
        "kernel_support.zig",  "kernels.zig",      "kernel_storage.zig",   "kernel_numeric.zig",
        "kernel_sequence.zig", "kernel_order.zig", "kernel_dict_text.zig", "idioms.zig",
    }, .sources = &.{
        @embedFile("../kernel_support.zig"),   @embedFile("../kernels.zig"),
        @embedFile("../kernel_storage.zig"),   @embedFile("../kernel_numeric.zig"),
        @embedFile("../kernel_sequence.zig"),  @embedFile("../kernel_order.zig"),
        @embedFile("../kernel_dict_text.zig"), @embedFile("../idioms.zig"),
    } },
    .{ .name = "source tooling", .budget = null, .files = &.{
        "source_audit.zig", "tools/source_audit.zig",
    }, .sources = &.{
        @embedFile("../source_audit.zig"), @embedFile("source_audit.zig"),
    } },
    .{ .name = "scheduler and concurrency", .budget = 3500, .files = &.{
        "scheduler.zig", "scheduler_core.zig", "console.zig", "task_prims.zig",
    }, .sources = &.{
        @embedFile("../scheduler.zig"), @embedFile("../scheduler_core.zig"),
        @embedFile("../console.zig"),   @embedFile("../task_prims.zig"),
    } },
};

const test_files = [_][]const u8{
    "tests/testgen.zig",                  "tests/reader_test.zig",
    "tests/machine_test.zig",             "tests/module_test.zig",
    "tests/value_test.zig",               "tests/kernel_test_support.zig",
    "tests/kernel_numeric_test.zig",      "tests/kernel_sequence_test.zig",
    "tests/kernel_order_test.zig",        "tests/kernel_dict_text_test.zig",
    "tests/combinator_test.zig",          "tests/prelude_test.zig",
    "tests/definition_test.zig",          "tests/formatter_test.zig",
    "tests/concurrency_test.zig",         "tests/scheduler_property_test.zig",
    "tests/snapshot_property_test.zig",   "tests/task_join_property_test.zig",
    "tests/resolution_property_test.zig", "tests/oom_test.zig",
    "oom_root.zig",
};
pub fn main(init: std.process.Init) !void {
    var failed = false;
    var business_logic_lines: usize = 0;
    for (components) |component| {
        if (component.files.len != component.sources.len) return error.SourceAuditFailed;
        var component_lines: usize = 0;
        for (component.sources) |source| {
            component_lines += if (component.budget == null)
                countLines(source)
            else
                countBusinessLogicLines(source);
        }
        if (component.budget) |budget| {
            std.log.info("{s}: {d}/{d} business-logic lines", .{
                component.name, component_lines, budget,
            });
            business_logic_lines += component_lines;
            failed = failed or component_lines > budget;
        } else {
            std.log.info("{s}: {d} verification lines (uncapped)", .{
                component.name, component_lines,
            });
        }
    }
    std.log.info("line budget: {d}/{d} business-logic lines", .{
        business_logic_lines, business_logic_budget,
    });
    failed = failed or business_logic_lines > business_logic_budget;
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
    var walker = directory.walk(std.heap.page_allocator) catch |err| {
        std.log.err("source coverage: cannot walk src: {s}", .{@errorName(err)});
        return true;
    };
    defer walker.deinit();
    var failed = false;
    var business_logic_count: usize = 0;
    var verification_count: usize = 0;
    while (walker.next(init.io) catch |err| {
        std.log.err("source coverage: cannot enumerate src: {s}", .{@errorName(err)});
        return true;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var matches: usize = 0;
        var is_business_logic = false;
        for (components) |component| for (component.files) |file| {
            if (!sameSourcePath(entry.path, file)) continue;
            matches += 1;
            is_business_logic = component.budget != null;
        };
        for (test_files) |file| matches += @intFromBool(sameSourcePath(entry.path, file));
        if (matches != 1) {
            std.log.err("source coverage: {s} belongs to {d} components; expected exactly one", .{
                entry.path, matches,
            });
            failed = true;
            continue;
        }
        if (is_business_logic) business_logic_count += 1 else verification_count += 1;
    }
    std.log.info("source coverage: {d} business-logic and {d} verification inputs classified", .{
        business_logic_count, verification_count,
    });
    return failed;
}

fn sameSourcePath(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |found, wanted| {
        if (found == wanted) continue;
        if (wanted != '/' or (found != '/' and found != '\\')) return false;
    }
    return true;
}

const PreludeStage = enum { header, body, annotation, name, def };

fn auditPreludeLayout() bool {
    const source = @embedFile("../prelude.ecl");
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

fn countBusinessLogicLines(source: [:0]const u8) usize {
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
        .{ .name = "equal", .text = @embedFile("../equal.zig") },
        .{ .name = "print", .text = @embedFile("../print.zig") },
        .{ .name = "numeric kernels", .text = @embedFile("../kernel_numeric.zig") },
        .{ .name = "sequence kernels", .text = @embedFile("../kernel_sequence.zig") },
        .{ .name = "order kernels", .text = @embedFile("../kernel_order.zig") },
        .{ .name = "dict/text kernels", .text = @embedFile("../kernel_dict_text.zig") },
        .{ .name = "kernel storage", .text = @embedFile("../kernel_storage.zig") },
        .{ .name = "module primitives", .text = @embedFile("../module_prims.zig") },
        .{ .name = "reflection", .text = @embedFile("../reflection.zig") },
        .{ .name = "definition primitives", .text = @embedFile("../definition_prims.zig") },
        .{ .name = "documentation", .text = @embedFile("../doc.zig") },
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
    const legacy_work_shapes = [_][]const []const u8{
        &.{"Work" ++ "Context"},
        &.{"Poll" ++ "er"},
        &.{"Poll" ++ "ing"},
        &.{"run" ++ "One"},
        &.{"co" ++ "operate"},
        &.{"advanceKernel" ++ "Critical"},
    };
    for (components) |component| for (component.sources, component.files) |source, file| {
        failed = auditTokens(file, source, &legacy_work_shapes) or failed;
    };
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
    const storage_forbidden = [_][]const []const u8{
        &.{"AutoHashMap"},
        &.{"AutoHashMapUnmanaged"},
    };
    failed = auditTokens("span archive", @embedFile("../spans.zig"), &storage_forbidden) or failed;
    failed = auditTokens("reader provenance", @embedFile("../reader.zig"), &storage_forbidden) or failed;
    const work_forbidden = [_][]const []const u8{
        &.{"pollOptional"},
        &.{ "poller", ".", "charge" },
    };
    const work_sources = [_]Source{
        .{ .name = "poll substrate", .text = @embedFile("../poll.zig") },
        .{ .name = "lexer", .text = @embedFile("../lexer.zig") },
        .{ .name = "binder", .text = @embedFile("../binder.zig") },
        .{ .name = "reader", .text = @embedFile("../reader.zig") },
        .{ .name = "interning", .text = @embedFile("../intern.zig") },
        .{ .name = "output reflection", .text = @embedFile("../reflection.zig") },
        .{ .name = "documentation", .text = @embedFile("../doc.zig") },
    };
    for (work_sources) |source| failed = auditTokens(source.name, source.text, &work_forbidden) or failed;
    const identifier_forbidden = [_][]const []const u8{
        &.{ "std", ".", "mem", ".", "indexOfScalar" },
    };
    failed = auditTokens("definition names", @embedFile("../definition_prims.zig"), &identifier_forbidden) or failed;
    failed = auditTokens("module names", @embedFile("../module_prims.zig"), &identifier_forbidden) or failed;
    failed = auditFunctionTokens(
        "formatter lookahead",
        @embedFile("../formatter.zig"),
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
