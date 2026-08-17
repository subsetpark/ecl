//! Build-time source architecture and line-budget audit.
const std = @import("std");

// Strong nominal/capability boundaries in shipped product code are deliberately
// budgeted, not treated as overhead to squeeze away. Tests and verification
// tooling are classified for source coverage, but their lines are neither
// measured nor controlled by the product complexity budget.
const business_logic_budget: usize = 36_000;

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
        "value.zig",       "heap.zig", "intern.zig", "list.zig",
        "equal.zig",       "dict.zig", "print.zig",  "poll.zig",
        "text_buffer.zig",
    }, .sources = &.{
        @embedFile("../value.zig"),       @embedFile("../heap.zig"),
        @embedFile("../intern.zig"),      @embedFile("../list.zig"),
        @embedFile("../equal.zig"),       @embedFile("../dict.zig"),
        @embedFile("../print.zig"),       @embedFile("../poll.zig"),
        @embedFile("../text_buffer.zig"),
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
    // The native-continuation union carries park, join, cleanup, and work
    // combinations as exhaustive variants rather than five side-band fields.
    // That stronger lifecycle boundary is intentionally budgeted here.
    .{ .name = "machine", .budget = 5900, .files = &.{
        "machine.zig", "task_join_core.zig", "resolution_core.zig", "spans.zig", "prims.zig", "root.zig",
    }, .sources = &.{
        @embedFile("../machine.zig"),         @embedFile("../task_join_core.zig"),
        @embedFile("../resolution_core.zig"), @embedFile("../spans.zig"),
        @embedFile("../prims.zig"),           @embedFile("../root.zig"),
    } },
    // Snapshot-safe lookup, publication, and reflection now expose explicit
    // cursor state so scheduler suspension is represented instead of hidden
    // in cancellation-only loops.
    // Completion adds Directory/Shape/generation-owning cursors plus an
    // opaque rendered result; the higher ceiling preserves those nominal
    // lifetime boundaries rather than folding them into Session internals.
    .{ .name = "modules and registry", .budget = 5300, .files = &.{
        "env.zig", "modules.zig", "snapshot.zig", "snapshot_core.zig", "module_prims.zig", "reflection.zig", "session.zig",
    }, .sources = &.{
        @embedFile("../env.zig"),          @embedFile("../modules.zig"),
        @embedFile("../snapshot.zig"),     @embedFile("../snapshot_core.zig"),
        @embedFile("../module_prims.zig"), @embedFile("../reflection.zig"),
        @embedFile("../session.zig"),
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
    .{ .name = "definition annotations", .budget = 1100, .files = &.{
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
    // The editor owns raw-terminal restoration, scalar-safe mutation, and
    // atomic locked history as separate nominal states. Its ceiling budgets
    // those boundaries rather than hiding them in the CLI entrypoint.
    .{ .name = "CLI, line editor, and source formatter", .budget = 2800, .files = &.{
        "main.zig", "formatter.zig", "line_editor.zig",
    }, .sources = &.{
        @embedFile("../main.zig"), @embedFile("../formatter.zig"), @embedFile("../line_editor.zig"),
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
    // The installed author SDK, its sized ABI records, validation, loader,
    // and transactional-call boundary form one separately rooted component.
    .{ .name = "native SDK, ABI, and loader", .budget = 3800, .files = &.{
        "native/abi.zig",          "native/capability.zig", "native/sdk.zig",
        "native/build_helper.zig", "native_descriptor.zig", "native_module.zig",
        "native_call.zig",
    }, .sources = &.{
        @embedFile("../native/abi.zig"),        @embedFile("../native/capability.zig"),
        @embedFile("../native/sdk.zig"),        @embedFile("../native/build_helper.zig"),
        @embedFile("../native_descriptor.zig"), @embedFile("../native_module.zig"),
        @embedFile("../native_call.zig"),
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
    "tests/line_editor_test.zig",         "tests/native_test.zig",
    "tests/fuzz_test.zig",                "oom_root.zig",
};
const repository_verification_files = [_][]const u8{
    "build.zig",
    "test/cli_test_support.zig",
    "test/e2e.zig",
    "test/native_runtime.zig",
    "test/idiom_differential.zig",
    "test/oracle_differential.zig",
    "test/scheduler_shell_property.zig",
    "test/native/sample.zig",
    "test/native/malformed.zig",
    "test/native/negative/no_call_parameter.zig",
    "test/native/negative/wrong_return_type.zig",
    "test/native/negative/generic_callback.zig",
    "test/native/negative/malformed_effect.zig",
    "test/native/negative/output_arity_mismatch.zig",
    "test/native/negative/unknown_capability.zig",
    "test/native/negative/duplicate_word.zig",
    "test/native/negative/empty_doc.zig",
};
pub fn main(init: std.process.Init) !void {
    var failed = false;
    var business_logic_lines: usize = 0;
    for (components) |component| {
        if (component.files.len != component.sources.len) return error.SourceAuditFailed;
        var component_lines: usize = 0;
        if (component.budget == null) continue;
        for (component.sources) |source| component_lines += countBusinessLogicLines(source);
        if (component.budget) |budget| {
            std.log.info("{s}: {d}/{d} business-logic lines", .{
                component.name, component_lines, budget,
            });
            business_logic_lines += component_lines;
            failed = failed or component_lines > budget;
        }
    }
    std.log.info("line budget: {d}/{d} business-logic lines", .{
        business_logic_lines, business_logic_budget,
    });
    failed = failed or business_logic_lines > business_logic_budget;
    failed = auditSourceCoverage(init) or failed;
    failed = auditTraversalSources() or failed;
    failed = auditTypingBoundaries() or failed;
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
    var expected_business: usize = 0;
    var expected_verification: usize = test_files.len;
    for (components) |component| {
        if (component.budget == null)
            expected_verification += component.files.len
        else
            expected_business += component.files.len;
    }
    if (business_logic_count != expected_business or verification_count != expected_verification) {
        std.log.err("source coverage: manifest contains missing src inputs", .{});
        failed = true;
    }
    failed = auditRepositoryVerification(init) or failed;
    return failed;
}

fn auditRepositoryVerification(init: std.process.Init) bool {
    var failed = false;
    var count: usize = 0;
    var test_directory = std.Io.Dir.cwd().openDir(init.io, "test", .{ .iterate = true }) catch |err| {
        std.log.err("source coverage: cannot open test: {s}", .{@errorName(err)});
        return true;
    };
    defer test_directory.close(init.io);
    var walker = test_directory.walk(std.heap.page_allocator) catch |err| {
        std.log.err("source coverage: cannot walk test: {s}", .{@errorName(err)});
        return true;
    };
    defer walker.deinit();
    while (walker.next(init.io) catch |err| {
        std.log.err("source coverage: cannot enumerate test: {s}", .{@errorName(err)});
        return true;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var path_buffer: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "test/{s}", .{entry.path}) catch {
            std.log.err("source coverage: test path is too long", .{});
            failed = true;
            continue;
        };
        const matches = repositoryVerificationMatches(path);
        if (matches != 1) {
            std.log.err("source coverage: {s} belongs to {d} repository manifests; expected exactly one", .{
                path, matches,
            });
            failed = true;
        } else count += 1;
    }

    var root = std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true }) catch |err| {
        std.log.err("source coverage: cannot open repository root: {s}", .{@errorName(err)});
        return true;
    };
    defer root.close(init.io);
    var iterator = root.iterate();
    while (iterator.next(init.io) catch |err| {
        std.log.err("source coverage: cannot enumerate repository root: {s}", .{@errorName(err)});
        return true;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const matches = repositoryVerificationMatches(entry.name);
        if (matches != 1) {
            std.log.err("source coverage: {s} belongs to {d} repository manifests; expected exactly one", .{
                entry.name, matches,
            });
            failed = true;
        } else count += 1;
    }
    if (count != repository_verification_files.len) {
        std.log.err("source coverage: repository verification manifest contains missing inputs", .{});
        failed = true;
    }
    std.log.info("source coverage: {d} repository verification inputs classified", .{count});
    return failed;
}

fn repositoryVerificationMatches(path: []const u8) usize {
    var matches: usize = 0;
    for (repository_verification_files) |file|
        matches += @intFromBool(sameSourcePath(path, file));
    return matches;
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
    const Declaration = struct {
        node: std.zig.Ast.Node.Index,
        first: std.zig.Ast.TokenIndex,
        last: std.zig.Ast.TokenIndex,
        name: ?[]const u8,
        reachable: bool,
    };
    var declarations: std.ArrayList(Declaration) = .empty;
    defer declarations.deinit(std.heap.page_allocator);
    for (tree.rootDecls()) |declaration| {
        const first = tree.firstToken(declaration);
        const last = tree.lastToken(declaration);
        var name: ?[]const u8 = null;
        var public_or_root = false;
        var test_conditional = false;
        var token = first;
        while (token <= last) : (token += 1) {
            switch (tree.tokenTag(token)) {
                .keyword_pub, .keyword_export, .keyword_comptime => public_or_root = true,
                .keyword_fn, .keyword_const, .keyword_var => if (name == null and token < last and
                    tree.tokenTag(token + 1) == .identifier)
                {
                    name = tree.tokenSlice(token + 1);
                },
                else => {},
            }
            if (token + 2 <= last and
                std.mem.eql(u8, tree.tokenSlice(token), "builtin") and
                tree.tokenTag(token + 1) == .period and
                std.mem.eql(u8, tree.tokenSlice(token + 2), "is_test"))
            {
                test_conditional = true;
            }
        }
        if (tree.nodeTag(declaration) == .test_decl) name = null;
        declarations.append(std.heap.page_allocator, .{
            .node = declaration,
            .first = first,
            .last = last,
            .name = name,
            .reachable = tree.nodeTag(declaration) != .test_decl and !test_conditional and
                (public_or_root or name == null or std.mem.eql(u8, name.?, "main")),
        }) catch return countLines(source);
    }
    // Production reachability starts at exported/comptime declarations and
    // follows top-level identifier references. Test declarations and
    // builtin.is_test-only declarations are never roots, so helpers reachable
    // only from verification code are excluded regardless of visibility.
    var changed = true;
    while (changed) {
        changed = false;
        for (declarations.items) |owner| {
            if (!owner.reachable) continue;
            var token = owner.first;
            while (token <= owner.last) : (token += 1) {
                if (tree.tokenTag(token) != .identifier) continue;
                const identifier = tree.tokenSlice(token);
                for (declarations.items) |*candidate| {
                    if (candidate.reachable or candidate.name == null) continue;
                    if (std.mem.eql(u8, candidate.name.?, identifier)) {
                        candidate.reachable = true;
                        changed = true;
                    }
                }
            }
        }
    }
    const line_count = countLines(source);
    const excluded = std.heap.page_allocator.alloc(bool, line_count) catch return countLines(source);
    defer std.heap.page_allocator.free(excluded);
    @memset(excluded, false);
    for (declarations.items) |declaration| {
        if (declaration.reachable) continue;
        const start = tree.tokenStart(declaration.first);
        const end = tree.tokenStart(declaration.last) + tree.tokenSlice(declaration.last).len;
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
        &.{"pushResult" ++ "Owned"},
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
    failed = auditFunctionTokens(
        "owned stack handoff",
        @embedFile("../machine.zig"),
        "pushOwned",
        &.{&.{ "heap", ".", "releaseValue" }},
    ) or failed;
    const operand_stack_mutations = [_][]const []const u8{
        &.{ "unit", ".", "stack", ".", "append" },
        &.{ "unit", ".", "stack", ".", "appendAssumeCapacity" },
        &.{ "unit", ".", "stack", ".", "appendSliceAssumeCapacity" },
        &.{ "unit", ".", "stack", ".", "ensureUnusedCapacity" },
        &.{ "unit", ".", "stack", ".", "clearRetainingCapacity" },
        &.{ "unit", ".", "stack", ".", "shrinkRetainingCapacity" },
        &.{ "unit", ".", "stack", ".", "pop" },
    };
    for (components) |component| for (component.sources, component.files) |source, file| {
        if (std.mem.eql(u8, file, "machine.zig")) continue;
        failed = auditTokens(file, source, &operand_stack_mutations) or failed;
    };
    const raw_stack_ownership = [_][]const []const u8{&.{"takeStackOwned"}};
    for (components) |component| for (component.sources, component.files) |source, file| {
        if (std.mem.eql(u8, file, "machine.zig") or std.mem.eql(u8, file, "scheduler.zig")) continue;
        failed = auditTokens(file, source, &raw_stack_ownership) or failed;
    };
    const session_stack_mutations = [_][]const []const u8{
        &.{ "self", ".", "stack", ".", "append" },
        &.{ "self", ".", "stack", ".", "appendAssumeCapacity" },
        &.{ "self", ".", "stack", ".", "appendSliceAssumeCapacity" },
        &.{ "self", ".", "stack", ".", "ensureUnusedCapacity" },
        &.{ "self", ".", "stack", ".", "clearRetainingCapacity" },
        &.{ "self", ".", "stack", ".", "shrinkRetainingCapacity" },
        &.{ "self", ".", "stack", ".", "pop" },
    };
    failed = auditTokens(
        "session operand stack",
        @embedFile("../session.zig"),
        &session_stack_mutations,
    ) or failed;
    for (components) |component| for (component.sources, component.files) |source, file| {
        failed = auditWorkDriverOutputs(file, source) or failed;
        failed = auditOwnershipIdentifiers(file, source) or failed;
        failed = auditOwnershipBooleans(file, source) or failed;
        failed = auditReleaseDestructors(file, source) or failed;
    };
    const retired_release_implementation = [_][]const []const u8{&.{"ReleaseCursor"}};
    for (components) |component| for (component.sources, component.files) |source, file| {
        failed = auditTokens(file, source, &retired_release_implementation) or failed;
    };
    return failed;
}

/// Type seams that cannot be expressed at a call site are enforced over
/// parsed production declarations. Test declarations remain behavioral and
/// may use synchronous compatibility cleanup.
fn auditTypingBoundaries() bool {
    var failed = false;
    // Every classified production file receives the same ownership audit.
    // Adding a file to the manifest can never silently omit it from the
    // release and blocking-destruction boundaries.
    for (components) |component| {
        if (component.budget == null) continue;
        for (component.sources, component.files) |source, file| {
            failed = auditProductionTokens(file, source, &.{
                &.{ "heap", ".", "decRef" },
            }) or failed;
            const host_owner_allowed = std.mem.eql(u8, file, "heap.zig") or
                std.mem.eql(u8, file, "session.zig") or
                std.mem.eql(u8, file, "main.zig") or
                std.mem.eql(u8, file, "formatter.zig");
            if (!host_owner_allowed) failed = auditProductionTokens(file, source, &.{
                &.{"HostOwner"},
            }) or failed;
            if (!std.mem.eql(u8, file, "heap.zig")) for ([_][]const u8{
                "@ptrCast",
                "@ptrFromInt",
            }) |cast| {
                failed = auditProductionFunctionTokenPair(file, source, "HostCleanup", cast) or failed;
            };
            failed = auditExclusiveParameterTypes(
                file,
                source,
                "HostCleanup",
                "Allocator",
            ) or failed;
            const execution_cast_allowed = std.mem.eql(u8, file, "session.zig") or
                std.mem.eql(u8, file, "prelude.zig") or
                std.mem.eql(u8, file, "machine.zig");
            if (!execution_cast_allowed) for ([_][]const u8{
                "@ptrCast",
                "@ptrFromInt",
            }) |cast| {
                failed = auditProductionFunctionTokenPair(file, source, "ExecutionAccess", cast) or failed;
            };
        }
    }

    failed = auditTokens("environment nominal maps", @embedFile("../env.zig"), &.{
        &.{ "poll", ".", "U32Map" },
    }) or failed;
    failed = auditTokens("module nominal maps", @embedFile("../modules.zig"), &.{
        &.{ "poll", ".", "U32Map" },
    }) or failed;
    // Session may privately consume observation leases, but none may cross an
    // exported function boundary into untrusted callers.
    failed = auditPublicFunctionTypes("session lease boundary", @embedFile("../session.zig"), &.{
        &.{"GenerationLease"},
        &.{"BindingLease"},
    }) or failed;
    failed = auditPublicFunctionReturnTypes(
        "session allocation authority",
        @embedFile("../session.zig"),
        &.{&.{"Allocator"}},
    ) or failed;

    failed = auditErasedCasts(
        "machine erased callbacks",
        @embedFile("../machine.zig"),
        &.{ "ApplicationAdapters", "IdiomFallbackAdapters", "WorkDriverAdapters" },
    ) or failed;
    failed = auditErasedCasts(
        "task destructor erasure",
        @embedFile("../heap.zig"),
        &.{ "TaskDestroyAdapter", "RetirementAdapters", "RetirementWakeAdapters" },
    ) or failed;

    const raw_task_publication = [_][]const []const u8{
        &.{"allocTaskHeader"},
        &.{"publishTask"},
    };
    for (components) |component| for (component.sources, component.files) |source, file| {
        if (std.mem.eql(u8, file, "heap.zig")) continue;
        failed = auditTokens(file, source, &raw_task_publication) or failed;
    };
    return failed;
}

/// An owner-bound host capability supplies its allocator. Accepting both as
/// parameters recreates the mismatched-owner state even when every current
/// caller happens to pass the corresponding pair.
fn auditExclusiveParameterTypes(
    file: []const u8,
    source: [:0]const u8,
    first_type: []const u8,
    second_type: []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    const excluded = std.heap.page_allocator.alloc(bool, tree.tokens.len) catch return true;
    defer std.heap.page_allocator.free(excluded);
    @memset(excluded, false);
    for (tree.rootDecls()) |declaration| {
        if (tree.nodeTag(declaration) != .test_decl) continue;
        for (tree.firstToken(declaration)..tree.lastToken(declaration) + 1) |token|
            excluded[token] = true;
    }
    var failed = false;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .fn_decl or excluded[tree.firstToken(node)]) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        var found_first = false;
        var found_second = false;
        var parameters = function.iterate(&tree);
        while (parameters.next()) |parameter| {
            const type_expr = parameter.type_expr orelse continue;
            for (tree.firstToken(type_expr)..tree.lastToken(type_expr) + 1) |token| {
                const spelling = tree.tokenSlice(@intCast(token));
                found_first = found_first or std.mem.eql(u8, spelling, first_type);
                found_second = found_second or std.mem.eql(u8, spelling, second_type);
            }
        }
        if (!found_first or !found_second) continue;
        const name = if (function.name_token) |name_token| tree.tokenSlice(name_token) else "<anonymous>";
        std.log.err(
            "{s}: production function `{s}` accepts mutually exclusive `{s}` and `{s}` capabilities",
            .{ file, name, first_type, second_type },
        );
        failed = true;
    }
    return failed;
}

fn auditProductionFunctionTokenPair(
    file: []const u8,
    source: [:0]const u8,
    first_spelling: []const u8,
    second_spelling: []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    const excluded = std.heap.page_allocator.alloc(bool, tree.tokens.len) catch return true;
    defer std.heap.page_allocator.free(excluded);
    @memset(excluded, false);
    for (tree.rootDecls()) |declaration| {
        if (tree.nodeTag(declaration) != .test_decl) continue;
        for (tree.firstToken(declaration)..tree.lastToken(declaration) + 1) |token|
            excluded[token] = true;
    }
    var failed = false;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .fn_decl or excluded[tree.firstToken(node)]) continue;
        var found_first = false;
        var found_second = false;
        for (tree.firstToken(node)..tree.lastToken(node) + 1) |token| {
            const spelling = tree.tokenSlice(@intCast(token));
            found_first = found_first or std.mem.eql(u8, spelling, first_spelling);
            found_second = found_second or std.mem.eql(u8, spelling, second_spelling);
        }
        if (found_first and found_second) {
            std.log.err("{s}: production function combines forbidden `{s}` and `{s}`", .{
                file, first_spelling, second_spelling,
            });
            failed = true;
        }
    }
    return failed;
}

fn auditProductionTokens(
    label: []const u8,
    source: [:0]const u8,
    forbidden: []const []const []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    const excluded = std.heap.page_allocator.alloc(bool, tree.tokens.len) catch return true;
    defer std.heap.page_allocator.free(excluded);
    @memset(excluded, false);
    for (tree.rootDecls()) |declaration| {
        if (tree.nodeTag(declaration) != .test_decl) continue;
        const end = tree.lastToken(declaration) + 1;
        for (tree.firstToken(declaration)..end) |token| excluded[token] = true;
    }
    var failed = false;
    for (forbidden) |pattern| {
        var index: usize = 0;
        while (index + pattern.len <= tree.tokens.len) : (index += 1) {
            if (excluded[index]) continue;
            for (pattern, 0..) |expected, offset| {
                if (excluded[index + offset] or
                    !std.mem.eql(u8, tree.tokenSlice(@intCast(index + offset)), expected)) break;
            } else {
                std.log.err("{s}: forbidden production cleanup begins at `{s}`", .{ label, pattern[0] });
                failed = true;
                break;
            }
        }
    }
    return failed;
}

fn auditErasedCasts(
    label: []const u8,
    source: [:0]const u8,
    allowed_factories: []const []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    for (0..tree.tokens.len) |index| {
        const raw_cast = [_][]const u8{ "@ptrCast", "(", "@alignCast", "(", "raw" };
        if (index + raw_cast.len > tree.tokens.len) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(@intCast(index)), "@ptrCast") or
            !std.mem.eql(u8, tree.tokenSlice(@intCast(index + 1)), "(") or
            !std.mem.eql(u8, tree.tokenSlice(@intCast(index + 2)), "@alignCast") or
            !std.mem.eql(u8, tree.tokenSlice(@intCast(index + 3)), "(") or
            !std.mem.eql(u8, tree.tokenSlice(@intCast(index + 4)), "raw")) continue;
        for (tree.rootDecls()) |declaration| {
            if (tree.nodeTag(declaration) != .fn_decl) continue;
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const function = tree.fullFnProto(&buffer, declaration) orelse continue;
            const name_token = function.name_token orelse continue;
            var allowed = false;
            for (allowed_factories) |name| allowed = allowed or
                std.mem.eql(u8, tree.tokenSlice(name_token), name);
            if (!allowed) continue;
            if (index >= tree.firstToken(declaration) and index <= tree.lastToken(declaration))
                break;
        } else {
            std.log.err("{s}: raw erased cast exists outside a typed adapter factory", .{label});
            failed = true;
        }
    }
    return failed;
}

/// A mutable boolean initialized as truth state is the characteristic shape of
/// a side-band transfer flag. Ownership transitions must consume a capability
/// or change a tagged state instead.
fn auditOwnershipBooleans(label: []const u8, source: [:0]const u8) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    var token: usize = 0;
    while (token + 3 < tree.tokens.len) : (token += 1) {
        if (tree.tokenTag(@intCast(token)) != .keyword_var or
            tree.tokenTag(@intCast(token + 1)) != .identifier or
            tree.tokenTag(@intCast(token + 2)) != .equal)
        {
            continue;
        }
        if (tree.tokenTag(@intCast(token + 3)) != .identifier) continue;
        const initial = tree.tokenSlice(@intCast(token + 3));
        if (!std.mem.eql(u8, initial, "true") and !std.mem.eql(u8, initial, "false")) continue;
        const identifier = tree.tokenSlice(@intCast(token + 1));
        if (!std.mem.eql(u8, identifier, "owned") and
            !std.mem.eql(u8, identifier, "transferred") and
            !std.mem.eql(u8, identifier, "consumed"))
        {
            continue;
        }
        std.log.err("{s}: mutable ownership flag `{s}` must be a capability or tagged state", .{
            label, identifier,
        });
        failed = true;
    }
    return failed;
}

/// Ownership transfer is represented by capabilities or tagged optionals,
/// never by a second boolean whose truth must track a raw value or buffer.
fn auditOwnershipIdentifiers(label: []const u8, source: [:0]const u8) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    for (0..tree.tokens.len) |token_index| {
        const token: std.zig.Ast.TokenIndex = @intCast(token_index);
        if (tree.tokenTag(token) != .identifier) continue;
        const identifier = tree.tokenSlice(token);
        if (!std.mem.endsWith(u8, identifier, "_owned")) continue;
        std.log.err("{s}: ownership flag `{s}` must be an OwnedValue or tagged state", .{
            label, identifier,
        });
        failed = true;
    }
    return failed;
}

/// A destructor that receives a release capability may retire roots but may
/// not bypass the sole graph walker through a synchronous compatibility API.
fn auditReleaseDestructors(label: []const u8, source: [:0]const u8) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    var node_index: usize = 0;
    while (node_index < tree.nodes.len) : (node_index += 1) {
        const node: std.zig.Ast.Node.Index = @enumFromInt(node_index);
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        const name_token = function.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), "destroy")) continue;
        const first = tree.firstToken(node);
        const end = tree.lastToken(node) + 1;
        if (!tokenRangeContains(tree, first, end, "ReleaseDomain")) continue;
        failed = hasForbiddenTokens(label, tree, first, end, &.{
            &.{ "heap", ".", "releaseValue" },
            &.{ "heap", ".", "decRef" },
            &.{ "materializer", ".", "deinit" },
            &.{ "normalizer", ".", "deinit" },
            &.{ "utf8", ".", "deinit" },
            &.{"blocking"},
            &.{"for"},
            &.{"while"},
        }) or failed;
    }
    return failed;
}

fn tokenRangeContains(tree: std.zig.Ast, first: usize, end: usize, wanted: []const u8) bool {
    var token = first;
    while (token != end) : (token += 1)
        if (std.mem.eql(u8, tree.tokenSlice(@intCast(token)), wanted)) return true;
    return false;
}

/// Work drivers may produce owned values, but only the evaluator loop may
/// commit those values to the operand stack. Checking the declared return
/// type makes this boundary cover new drivers without maintaining a name list.
fn auditWorkDriverOutputs(label: []const u8, source: [:0]const u8) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    var node_index: usize = 0;
    while (node_index < tree.nodes.len) : (node_index += 1) {
        const node: std.zig.Ast.Node.Index = @enumFromInt(node_index);
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        const return_type = function.ast.return_type.unwrap() orelse continue;
        var token: usize = tree.firstToken(return_type);
        const return_end: usize = tree.lastToken(return_type) + 1;
        while (token != return_end) : (token += 1) {
            if (!std.mem.eql(u8, tree.tokenSlice(@intCast(token)), "WorkProgress")) continue;
            failed = hasForbiddenTokens(
                label,
                tree,
                tree.firstToken(node),
                tree.lastToken(node) + 1,
                &.{&.{"pushOwned"}},
            ) or failed;
            break;
        }
    }
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

fn auditPublicFunctionTypes(
    label: []const u8,
    source: [:0]const u8,
    forbidden: []const []const []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .fn_decl) continue;
        const first = tree.firstToken(node);
        if (tree.tokenTag(first) != .keyword_pub) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        var parameters = function.iterate(&tree);
        while (parameters.next()) |parameter| {
            const type_expr = parameter.type_expr orelse continue;
            failed = hasForbiddenTokens(
                label,
                tree,
                tree.firstToken(type_expr),
                tree.lastToken(type_expr) + 1,
                forbidden,
            ) or failed;
        }
        if (function.ast.return_type.unwrap()) |return_type| {
            failed = hasForbiddenTokens(
                label,
                tree,
                tree.firstToken(return_type),
                tree.lastToken(return_type) + 1,
                forbidden,
            ) or failed;
        }
    }
    return failed;
}

fn auditPublicFunctionReturnTypes(
    label: []const u8,
    source: [:0]const u8,
    forbidden: []const []const []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .zig) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .fn_decl) continue;
        const first = tree.firstToken(node);
        if (tree.tokenTag(first) != .keyword_pub) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const function = tree.fullFnProto(&buffer, node) orelse continue;
        const return_type = function.ast.return_type.unwrap() orelse continue;
        failed = hasForbiddenTokens(
            label,
            tree,
            tree.firstToken(return_type),
            tree.lastToken(return_type) + 1,
            forbidden,
        ) or failed;
    }
    return failed;
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
