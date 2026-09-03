//! Build-time source architecture audit.
const std = @import("std");
const source_audit_options = @import("source_audit_options");
const ValueTag = @import("../value.zig").Tag;

const SourceGroup = struct {
    production: bool,
    files: []const []const u8,
    sources: []const [:0]const u8,
};

const source_groups = [_]SourceGroup{
    // Exact, non-rehashing map construction and resumable interning keep
    // user-sized storage work outside scheduler-native stacks.
    .{ .production = true, .files = &.{
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
    // boundary replaces native-stack control flow.
    .{ .production = true, .files = &.{
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
    .{ .production = true, .files = &.{
        "machine.zig", "task_join_core.zig", "resolution_core.zig", "spans.zig", "prims.zig", "test_prims.zig", "root.zig",
    }, .sources = &.{
        @embedFile("../machine.zig"),         @embedFile("../task_join_core.zig"),
        @embedFile("../resolution_core.zig"), @embedFile("../spans.zig"),
        @embedFile("../prims.zig"),           @embedFile("../test_prims.zig"),
        @embedFile("../root.zig"),
    } },
    // Snapshot-safe lookup, publication, and reflection now expose explicit
    // cursor state so scheduler suspension is represented instead of hidden
    // in cancellation-only loops.
    // Completion adds Directory/Shape/generation-owning cursors plus an
    // opaque rendered result rather than folding those lifetime boundaries
    // into Session internals.
    .{ .production = true, .files = &.{
        "env.zig", "modules.zig", "snapshot.zig", "module_prims.zig", "reflection.zig", "session.zig", "project.zig", "pkg_catalog.zig", "pkg_lock.zig",
    }, .sources = &.{
        @embedFile("../env.zig"),        @embedFile("../modules.zig"),
        @embedFile("../snapshot.zig"),   @embedFile("../module_prims.zig"),
        @embedFile("../reflection.zig"), @embedFile("../session.zig"),
        @embedFile("../project.zig"),    @embedFile("../pkg_catalog.zig"),
        @embedFile("../pkg_lock.zig"),
    } },
    // The embedded prelude loader and the embedded stdlib manifest are one
    // bootstrap surface: both hand constant source to the ordinary reader.
    .{ .production = true, .files = &.{
        "prelude.zig", "stdlib.zig",
    }, .sources = &.{
        @embedFile("../prelude.zig"), @embedFile("../stdlib.zig"),
    } },
    // First-party native stdlib modules are authored against the public SDK
    // and hold no host authority; they are user-sized traversal files whose
    // resumable state is the SDK's own continuation record.
    .{ .production = true, .files = &.{
        "stdlib/csv.zig",
    }, .sources = &.{
        @embedFile("../stdlib/csv.zig"),
    } },
    // Builtin-backed stdlib modules hold host authority the SDK withholds, so
    // they are ordinary production sources under the bounded-traversal rules.
    .{ .production = true, .files = &.{
        "stdlib/dict.zig",  "stdlib/rand.zig", "stdlib/json.zig", "stdlib/http.zig", "stdlib/proc.zig", "stdlib/archive.zig", "stdlib/pkg_store.zig", "stdlib/fs.zig",
        "stdlib/clock.zig", "stdlib/time.zig", "stdlib/net.zig",
    }, .sources = &.{
        @embedFile("../stdlib/dict.zig"),      @embedFile("../stdlib/rand.zig"),
        @embedFile("../stdlib/json.zig"),      @embedFile("../stdlib/http.zig"),
        @embedFile("../stdlib/proc.zig"),      @embedFile("../stdlib/archive.zig"),
        @embedFile("../stdlib/pkg_store.zig"), @embedFile("../stdlib/fs.zig"),
        @embedFile("../stdlib/clock.zig"),     @embedFile("../stdlib/time.zig"),
        @embedFile("../stdlib/net.zig"),
    } },
    .{ .production = true, .files = &.{
        "combinators.zig",
    }, .sources = &.{
        @embedFile("../combinators.zig"),
    } },
    .{ .production = true, .files = &.{
        "definition_prims.zig", "doc.zig",
    }, .sources = &.{
        @embedFile("../definition_prims.zig"), @embedFile("../doc.zig"),
    } },
    // Names, reflective prose, and fixed effects are one compile-time registry.
    .{ .production = true, .files = &.{
        "primitive_docs.zig",
    }, .sources = &.{
        @embedFile("../primitive_docs.zig"),
    } },
    // The editor owns raw-terminal restoration, scalar-safe mutation, and
    // atomic locked history as separate nominal states.
    .{ .production = true, .files = &.{
        "main.zig", "formatter.zig", "line_editor.zig",
    }, .sources = &.{
        @embedFile("../main.zig"), @embedFile("../formatter.zig"), @embedFile("../line_editor.zig"),
    } },
    // Explicit continuation state is part of the kernel correctness boundary;
    // native-stack traversals could not yield.
    .{ .production = true, .files = &.{
        "kernel_support.zig",  "kernels.zig",      "kernel_storage.zig",   "kernel_numeric.zig",
        "kernel_sequence.zig", "kernel_order.zig", "kernel_dict_text.zig", "idioms.zig",
        "kernel_random.zig",   "kernel_flat.zig",
    }, .sources = &.{
        @embedFile("../kernel_support.zig"),   @embedFile("../kernels.zig"),
        @embedFile("../kernel_storage.zig"),   @embedFile("../kernel_numeric.zig"),
        @embedFile("../kernel_sequence.zig"),  @embedFile("../kernel_order.zig"),
        @embedFile("../kernel_dict_text.zig"), @embedFile("../idioms.zig"),
        @embedFile("../kernel_random.zig"),    @embedFile("../kernel_flat.zig"),
    } },
    .{ .production = false, .files = &.{
        "source_audit.zig",               "tools/source_audit.zig",
        "tools/captured_test_runner.zig", "tools/bench_kernels.zig",
        "tools/bench_workdrivers.zig",    "tools/ecl_source_check.zig",
    }, .sources = &.{
        @embedFile("../source_audit.zig"),      @embedFile("source_audit.zig"),
        @embedFile("captured_test_runner.zig"), @embedFile("bench_kernels.zig"),
        @embedFile("bench_workdrivers.zig"),    @embedFile("ecl_source_check.zig"),
    } },
    // Scheduler-owned external resources: process ports, filesystem roots,
    // network listeners, and package stores share the nominal capability
    // vocabulary in external.zig and are opened only by their Session-owned
    // owner.
    .{ .production = true, .files = &.{
        "scheduler.zig", "scheduler_core.zig", "external.zig", "process_port.zig", "console.zig", "task_prims.zig", "filesystem_port.zig", "package_authority.zig", "directory_order.zig",
        "net_port.zig",
    }, .sources = &.{
        @embedFile("../scheduler.zig"),       @embedFile("../scheduler_core.zig"),
        @embedFile("../external.zig"),        @embedFile("../process_port.zig"),
        @embedFile("../console.zig"),         @embedFile("../task_prims.zig"),
        @embedFile("../filesystem_port.zig"), @embedFile("../package_authority.zig"),
        @embedFile("../directory_order.zig"), @embedFile("../net_port.zig"),
    } },
    // The installed author SDK, its sized ABI records, validation, loader,
    // and transactional-call boundary form one separately rooted component.
    .{ .production = true, .files = &.{
        "native/abi.zig",          "native/capability.zig", "native/sdk.zig",
        "native/build_helper.zig", "native_descriptor.zig", "native_module.zig",
        "native_call.zig",         "stdlib/io.zig",
    }, .sources = &.{
        @embedFile("../native/abi.zig"),        @embedFile("../native/capability.zig"),
        @embedFile("../native/sdk.zig"),        @embedFile("../native/build_helper.zig"),
        @embedFile("../native_descriptor.zig"), @embedFile("../native_module.zig"),
        @embedFile("../native_call.zig"),       @embedFile("../stdlib/io.zig"),
    } },
};

const test_files = [_][]const u8{
    "tests/allocation_budget_test.zig",
    "tests/testgen.zig",
    "tests/reader_test.zig",
    "tests/machine_test.zig",
    "tests/module_test.zig",
    "tests/value_test.zig",
    "tests/kernel_test_support.zig",
    "tests/kernel_numeric_test.zig",
    "tests/kernel_sequence_test.zig",
    "tests/kernel_order_test.zig",
    "tests/kernel_dict_text_test.zig",
    "tests/combinator_test.zig",
    "tests/prelude_test.zig",
    "tests/definition_test.zig",
    "tests/formatter_test.zig",
    "tests/concurrency_test.zig",
    "tests/oom_test.zig",
    "tests/line_editor_test.zig",
    "tests/native_test.zig",
    "tests/fuzz_test.zig",
    "fuzz_root.zig",
    "tests/test_heap.zig",
    "oom_root.zig",
    "tests/stateful_module_test.zig",
    "tests/stdlib_test.zig",
    "tests/hostio_test.zig",
    "tests/pkg_sync_test.zig",
    "tests/archive_test.zig",
    "tests/http_test.zig",
    "tests/random_test.zig",
    "tests/kernel_typed_test.zig",
    "tests/module_value_test.zig",
    "tests/unit_input_test.zig",
    "tests/module_source_test.zig",
    "tests/test_language_test.zig",
    "tests/process_test.zig",
    "tests/filesystem_test.zig",
    "tests/net_test.zig",
    "tests/clock_test.zig",
    "tests/conversion_test.zig",
    "tests/http_server_test.zig",
};
const repository_verification_files = [_][]const u8{
    "build.zig",
    "test/cli_test_support.zig",
    "test/e2e.zig",
    "test/native_runtime.zig",
    "test/idiom_differential.zig",
    "test/reference_snapshots.zig",
    "test/scheduler_shell_property.zig",
    "test/native/sample.zig",
    "test/native/malformed.zig",
    "test/native/negative/no_call_parameter.zig",
    "test/native/negative/wrong_return_type.zig",
    "test/native/negative/generic_callback.zig",
    "test/native/negative/malformed_effect.zig",
    "test/native/negative/partial_effect.zig",
    "test/native/negative/output_arity_mismatch.zig",
    "test/native/negative/unknown_capability.zig",
    "test/native/negative/duplicate_word.zig",
    "test/native/negative/empty_doc.zig",
    "test/http_fixture_server.zig",
    "test/pkg_lock_fixture.zig",
    "test/process_fixture.zig",
};
pub fn main(init: std.process.Init) !void {
    var failed = false;
    for (source_groups) |component| {
        if (component.files.len != component.sources.len) return error.SourceAuditFailed;
    }
    failed = auditSourceCoverage(init) or failed;
    failed = auditSourceBodies() or failed;
    failed = auditFilesystemAuthority() or failed;
    failed = auditUnsafeCasts() or failed;
    failed = auditPreludeLayout() or failed;
    failed = auditUnitConstructorSpelling() or failed;
    failed = auditDynamicContextSpelling() or failed;
    failed = auditFormalValueKinds() or failed;
    if (failed) return error.SourceAuditFailed;
}

fn auditFormalValueKinds() bool {
    const source = source_audit_options.formal_values;
    const head_end = std.mem.indexOf(u8, source, "\n---") orelse {
        std.log.err("formal value kinds: first chapter has no body separator", .{});
        return true;
    };
    const fields = @typeInfo(ValueTag).@"enum".fields;
    var seen = [_]bool{false} ** fields.len;
    var declaration_count: usize = 0;
    var lines = std.mem.splitScalar(u8, source[0..head_end], '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const suffix = " => ValueType.";
        if (!std.mem.endsWith(u8, line, suffix)) continue;
        const declaration = line[0 .. line.len - suffix.len];
        if (std.mem.indexOfAny(u8, declaration, " \t") != null or
            !std.mem.endsWith(u8, declaration, "-type"))
            continue;
        declaration_count += 1;
        var matched = false;
        inline for (fields, 0..) |field, index| {
            const expected = field.name ++ "-type";
            if (std.mem.eql(u8, declaration, expected)) {
                if (seen[index]) {
                    std.log.err("formal value kinds: duplicate declaration `{s}`", .{declaration});
                    return true;
                }
                seen[index] = true;
                matched = true;
            }
        }
        if (!matched) {
            std.log.err("formal value kinds: `{s}` has no value.Tag member", .{declaration});
            return true;
        }
    }
    var failed = declaration_count != fields.len;
    inline for (fields, 0..) |field, index| if (!seen[index]) {
        std.log.err("formal value kinds: value.Tag.{s} has no `{s}-type` declaration", .{
            field.name,
            field.name,
        });
        failed = true;
    };
    if (declaration_count != fields.len) std.log.err(
        "formal value kinds: found {d} declarations for {d} value.Tag members",
        .{ declaration_count, fields.len },
    );
    return failed;
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
    var production_count: usize = 0;
    var verification_count: usize = 0;
    while (walker.next(init.io) catch |err| {
        std.log.err("source coverage: cannot enumerate src: {s}", .{@errorName(err)});
        return true;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var matches: usize = 0;
        var is_production = false;
        for (source_groups) |component| for (component.files) |file| {
            if (!sameSourcePath(entry.path, file)) continue;
            matches += 1;
            is_production = component.production;
        };
        for (test_files) |file| matches += @intFromBool(sameSourcePath(entry.path, file));
        if (matches != 1) {
            std.log.err("source coverage: {s} belongs to {d} source groups; expected exactly one", .{
                entry.path, matches,
            });
            failed = true;
            continue;
        }
        if (is_production) production_count += 1 else verification_count += 1;
    }
    std.log.info("source coverage: {d} production and {d} verification inputs classified", .{
        production_count, verification_count,
    });
    var expected_production: usize = 0;
    var expected_verification: usize = test_files.len;
    for (source_groups) |component| {
        if (component.production)
            expected_production += component.files.len
        else
            expected_verification += component.files.len;
    }
    if (production_count != expected_production or verification_count != expected_verification) {
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

const PreludeStage = enum { header, annotation, body, name, def };

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
            .annotation => {
                if (index == source.len or source[index] != '\n') {
                    std.log.err("prelude layout: header must be followed by its definition annotation", .{});
                    return true;
                }
                index += 1;
            },
            .body, .name => {
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
            if (stage == .annotation and !navigation) {
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
            stage = .annotation;
            index = end;
            continue;
        }
        switch (stage) {
            .header => {
                std.log.err("prelude layout: definition lacks a ### def <name> header", .{});
                return true;
            },
            .annotation, .body => {
                if (source[index] != '(' or !skipPreludeQuotation(source, &index)) {
                    std.log.err("prelude layout: {s} for `{s}` is not one complete quotation", .{
                        @tagName(stage), expected_name,
                    });
                    return true;
                }
                stage = if (stage == .annotation) .body else .name;
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

fn auditSourceBodies() bool {
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
        .{ .name = "csv module", .text = @embedFile("../stdlib/csv.zig") },
        .{ .name = "random kernels", .text = @embedFile("../kernel_random.zig") },
    };
    const traversal_forbidden = [_][]const []const u8{
        &.{ "std", ".", "ArrayList" },
        &.{ "std", ".", "mem", ".", "sort" },
        &.{ "Writer", ".", "Allocating" },
        &.{ "writeAll", "(", "intern", ".", "get" },
        &.{ "print", "(", "\"{s}\"" },
    };
    var failed = false;
    const rehashing_maps = [_][]const []const u8{
        &.{"AutoHashMap"},
        &.{"AutoHashMapUnmanaged"},
    };
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file|
            failed = auditTokens(file, source, &rehashing_maps) or failed;
    }
    for (traversal_sources) |source| {
        failed = auditTokens(source.name, source.text, &traversal_forbidden) or failed;
    }
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
    const operand_stack_mutations = [_][]const []const u8{
        &.{ "unit", ".", "stack", ".", "append" },
        &.{ "unit", ".", "stack", ".", "appendAssumeCapacity" },
        &.{ "unit", ".", "stack", ".", "appendSliceAssumeCapacity" },
        &.{ "unit", ".", "stack", ".", "ensureUnusedCapacity" },
        &.{ "unit", ".", "stack", ".", "clearRetainingCapacity" },
        &.{ "unit", ".", "stack", ".", "shrinkRetainingCapacity" },
        &.{ "unit", ".", "stack", ".", "pop" },
    };
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file| {
            if (std.mem.eql(u8, file, "machine.zig")) continue;
            failed = auditTokens(file, source, &operand_stack_mutations) or failed;
        }
    }
    // A registry outcome that a driver dismisses as `unreachable` is an
    // interleaving nobody imagined rather than one that cannot happen:
    // removal can invalidate any name between the snapshot a cursor read and
    // the turn it is granted. Every registry error must reach an ECL error
    // kind instead.
    const dismissed_registry_outcomes = [_][]const []const u8{
        &.{ "MissingModule", "=>", "unreachable" },
        &.{ "NameConflict", "=>", "unreachable" },
        &.{ "InvalidDefinition", "=>", "unreachable" },
        &.{ "StateApplicationActive", "=>", "unreachable" },
    };
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file| {
            failed = auditTokens(file, source, &dismissed_registry_outcomes) or failed;
        }
    }
    const raw_stack_ownership = [_][]const []const u8{&.{"takeStackOwned"}};
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file| {
            if (std.mem.eql(u8, file, "machine.zig") or std.mem.eql(u8, file, "scheduler.zig")) continue;
            failed = auditTokens(file, source, &raw_stack_ownership) or failed;
        }
    }
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file| {
            failed = auditWorkDriverOutputs(file, source) or failed;
        }
    }
    // The typed loop boundary. A flat kernel loop reads unboxed slices through
    // heap-issued capabilities and writes typed storage; the two names below are
    // the boxed route — one cell at a time, then a profiling pass to recover a
    // representation the dispatch already knew. A typed loop that could reach
    // them would not be a typed loop, and the boundary is not something the
    // compiler can state, so it is stated here.
    const boxed_flat_route = [_][]const []const u8{
        &.{ "list", ".", "atUnchecked" },
        &.{"OwnedValueBuffer"},
        &.{ "list", ".", "ValueMaterializer" },
    };
    failed = auditTokens(
        "typed flat loops",
        @embedFile("../kernel_flat.zig"),
        &boxed_flat_route,
    ) or failed;
    // Migrated kernel files still contain deliberately generic spine/dict
    // drivers, so a whole-file denylist would outlaw the second half of the
    // design. The boundary is instead semantic at function granularity: a
    // production function that acquires a typed leaf capability may not also
    // rebox cells or invoke a profiling materializer.
    const migrated_kernel_files = [_]struct { name: []const u8, source: [:0]const u8 }{
        .{ .name = "kernel_numeric.zig", .source = @embedFile("../kernel_numeric.zig") },
        .{ .name = "kernel_sequence.zig", .source = @embedFile("../kernel_sequence.zig") },
        .{ .name = "kernel_order.zig", .source = @embedFile("../kernel_order.zig") },
        .{ .name = "kernel_random.zig", .source = @embedFile("../kernel_random.zig") },
    };
    for (migrated_kernel_files) |kernel| {
        failed = auditProductionFunctionTokenPair(
            kernel.name,
            kernel.source,
            "LeafReader",
            "atUnchecked",
        ) or failed;
        failed = auditProductionFunctionTokenPair(
            kernel.name,
            kernel.source,
            "LeafReader",
            "ValueMaterializer",
        ) or failed;
    }
    return failed;
}

/// Caller-selected filesystem work must flow through a retained root or store
/// handle, never through the process working directory, and the ambient file
/// words removed from `io` must stay removed everywhere first-party code is
/// written. Types cannot state either rule: `std.Io.Dir.cwd()` is an ordinary
/// function and a word spelling is text. Among the modules that implement
/// evaluated filesystem words, none may name the working directory; the
/// owners that open trusted host paths once at Session construction
/// (`filesystem_port.zig`, `package_authority.zig`) and the CLI, project
/// discovery, and module-loading host boundaries do so by design.
fn auditFilesystemAuthority() bool {
    var failed = false;
    const ambient_cwd = [_][]const []const u8{
        &.{ "Dir", ".", "cwd", "(", ")" },
    };
    const confined_sources = [_]struct { name: []const u8, text: [:0]const u8 }{
        .{ .name = "fs module", .text = @embedFile("../stdlib/fs.zig") },
        .{ .name = "archive module", .text = @embedFile("../stdlib/archive.zig") },
        .{ .name = "package store module", .text = @embedFile("../stdlib/pkg_store.zig") },
    };
    for (confined_sources) |source| {
        failed = auditTokens(source.name, source.text, &ambient_cwd) or failed;
    }
    // User-sized ordering inside a scheduler driver goes through the
    // resumable directory orderer; a general sort call would run a whole
    // listing in one step.
    const unbounded_sorting = [_][]const []const u8{
        &.{ "std", ".", "mem", ".", "sort" },
        &.{ "std", ".", "sort", "." },
    };
    for (confined_sources) |source| {
        failed = auditTokens(source.name, source.text, &unbounded_sorting) or failed;
    }
    // The filesystem port opens configured roots by their trusted host path
    // exactly once, inside the owner's constructor, and nowhere else.
    failed = auditProductionFunctionTokenPair(
        "filesystem_port.zig",
        @embedFile("../filesystem_port.zig"),
        "step",
        "cwd",
    ) or failed;
    const removed_words = [_][]const u8{ "slurp", "spit", "lines" };
    const console_module = @embedFile("../stdlib/io.zig");
    for (removed_words) |name| {
        if (installedPrimitiveName(console_module, name)) {
            std.log.err("filesystem authority: `io.{s}` is an ambient file word and must not exist", .{name});
            failed = true;
        }
    }
    const removed_spellings = [_][]const u8{ "io.slurp", "io.spit", "io.lines" };
    for (first_party_definition_sources) |source| {
        for (removed_spellings) |spelling| if (std.mem.indexOf(u8, source, spelling) != null) {
            std.log.err("filesystem authority: first-party source still uses `{s}`", .{spelling});
            failed = true;
        };
    }
    return failed;
}

/// Unsafe casts can bypass an opaque capability or callback adapter. Keep
/// those casts confined to the factories that own the corresponding erasure.
fn auditUnsafeCasts() bool {
    var failed = false;
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file| {
            if (!std.mem.eql(u8, file, "heap.zig")) for ([_][]const u8{
                "@ptrCast",
                "@ptrFromInt",
            }) |cast| {
                failed = auditProductionFunctionTokenPair(file, source, "HostCleanup", cast) or failed;
            };
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

    failed = auditErasedCasts(
        "machine erased callbacks",
        @embedFile("../machine.zig"),
        &.{ "ApplicationAdapters", "IdiomFallbackAdapters", "WorkDriverAdapters" },
    ) or failed;
    failed = auditErasedCasts(
        "capability payload erasure",
        @embedFile("../heap.zig"),
        &.{
            "TaskDestroyAdapter",     "PortReleaseAdapter",
            "ModuleReleaseAdapter",   "RetirementAdapters",
            "RetirementWakeAdapters", "CodeRetirementAdapters",
        },
    ) or failed;
    failed = auditErasedCasts(
        "external capability erasure",
        @embedFile("../external.zig"),
        &.{
            "WakeTargetAdapters",
            "ReadinessRegistrationAdapters",
            "ReadinessSourceAdapters",
            "ScopeMemberAdapters",
            "ScopeMembershipAdapters",
        },
    ) or failed;
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

/// The `@` mark means one thing: the word applies its quotation in a fresh
/// unit. Nothing in the compiler can express that, so the manifest is written
/// down here and the audit enforces both directions — every listed word is
/// marked, and nothing else in first-party vocabulary is.
const unit_constructors = [_][]const u8{ "@attempt", "@spawn", "@each", "@module", "@defm", "@test" };

/// Wrapped stars mean one thing in shipped vocabulary: the word returns a
/// value supplied by dynamic execution context rather than consuming it from
/// the operand stack. The compiler cannot express that semantic class, so the
/// audit owns its closed manifest just as it owns the `@` constructor class.
const dynamic_context_words = [_][]const u8{ "*file*", "*module*" };
const first_party_definition_sources = [_][:0]const u8{
    @embedFile("../prelude.ecl"),
    @embedFile("../stdlib/result.ecl"),
    @embedFile("../stdlib/str.ecl"),
    @embedFile("../stdlib/table.ecl"),
    @embedFile("../stdlib/rng.ecl"),
    @embedFile("../stdlib/pkg/version.ecl"),
    @embedFile("../stdlib/pkg/name.ecl"),
    @embedFile("../stdlib/pkg/data.ecl"),
    @embedFile("../stdlib/pkg/manifest.ecl"),
    @embedFile("../stdlib/pkg/lock.ecl"),
    @embedFile("../stdlib/pkg/mvs.ecl"),
    @embedFile("../stdlib/pkg/sync.ecl"),
    @embedFile("../stdlib/pkg/cli.ecl"),
    @embedFile("../stdlib/path.ecl"),
    @embedFile("../stdlib/test/default.ecl"),
};

fn auditUnitConstructorSpelling() bool {
    var failed = false;
    const installers = [_][:0]const u8{
        @embedFile("../prims.zig"),
        @embedFile("../task_prims.zig"),
        @embedFile("../module_prims.zig"),
        @embedFile("../test_prims.zig"),
    };
    const documentation = @embedFile("../primitive_docs.zig");
    for (unit_constructors) |name| {
        var installed = false;
        for (installers) |source| {
            if (installedPrimitiveName(source, name)) installed = true;
        }
        if (!installed) {
            std.log.err("unit constructors: `{s}` is not installed under that spelling", .{name});
            failed = true;
        }
        if (!installedPrimitiveName(documentation, name)) {
            std.log.err("unit constructors: `{s}` has no documentation entry", .{name});
            failed = true;
        }
    }
    // The other direction: a marked word that constructs no unit teaches the
    // reader a rule the vocabulary then breaks.
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, documentation, index, ".name = \"@")) |found| {
        const start = found + ".name = \"".len;
        const end = std.mem.indexOfScalarPos(u8, documentation, start, '"') orelse documentation.len;
        const name = documentation[start..end];
        if (!isUnitConstructor(name)) {
            std.log.err("unit constructors: primitive `{s}` is marked but constructs no unit", .{name});
            failed = true;
        }
        index = end;
    }
    for (first_party_definition_sources) |source| {
        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, source, scan, "'@")) |found| {
            const start = found + 1;
            const end = preludeTokenEnd(source, start);
            const name = source[start..end];
            if (!isUnitConstructor(name)) {
                std.log.err("unit constructors: `{s}` is marked but constructs no unit", .{name});
                failed = true;
            }
            scan = end;
        }
    }
    return failed;
}

fn auditDynamicContextSpelling() bool {
    var failed = false;
    const installers = [_][:0]const u8{
        @embedFile("../prims.zig"),
        @embedFile("../task_prims.zig"),
        @embedFile("../module_prims.zig"),
    };
    const documentation = @embedFile("../primitive_docs.zig");
    for (dynamic_context_words) |name| {
        var installed = false;
        for (installers) |source| {
            if (installedPrimitiveName(source, name)) installed = true;
        }
        if (!installed) {
            std.log.err("dynamic context: `{s}` is not installed under that spelling", .{name});
            failed = true;
        }
        if (!installedPrimitiveName(documentation, name)) {
            std.log.err("dynamic context: `{s}` has no documentation entry", .{name});
            failed = true;
        }
    }
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, documentation, index, ".name = \"*")) |found| {
        const start = found + ".name = \"".len;
        const end = std.mem.indexOfScalarPos(u8, documentation, start, '"') orelse
            documentation.len;
        const name = documentation[start..end];
        if (wrappedStars(name) and !isDynamicContextWord(name)) {
            std.log.err("dynamic context: primitive `{s}` uses wrapped stars", .{name});
            failed = true;
        }
        index = end;
    }
    for (first_party_definition_sources) |source| {
        var scan: usize = 0;
        while (std.mem.indexOfPos(u8, source, scan, "'*")) |found| {
            const start = found + 1;
            const end = preludeTokenEnd(source, start);
            const name = source[start..end];
            if (wrappedStars(name) and !isDynamicContextWord(name)) {
                std.log.err("dynamic context: definition `{s}` uses wrapped stars", .{name});
                failed = true;
            }
            scan = end;
        }
    }
    return failed;
}

fn occurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

fn isUnitConstructor(name: []const u8) bool {
    for (unit_constructors) |listed| {
        if (std.mem.eql(u8, listed, name)) return true;
    }
    return false;
}

fn wrappedStars(name: []const u8) bool {
    return name.len > 2 and name[0] == '*' and name[name.len - 1] == '*';
}

fn isDynamicContextWord(name: []const u8) bool {
    for (dynamic_context_words) |listed| {
        if (std.mem.eql(u8, listed, name)) return true;
    }
    return false;
}

fn installedPrimitiveName(source: []const u8, name: []const u8) bool {
    var buffer: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, ".name = \"{s}\"", .{name}) catch return false;
    return std.mem.indexOf(u8, source, needle) != null;
}
