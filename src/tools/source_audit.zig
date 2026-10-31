//! Build-time source architecture audit.
const std = @import("std");
const source_audit_options = @import("source_audit_options");
const ValueTag = @import("../value.zig").Tag;

const SourceGroup = struct {
    production: bool,
    files: []const []const u8,
    sources: []const [:0]const u8,
};

// Derive each embedded source from its classified path. Parallel filename and
// source arrays cannot silently apply an exception to another file's code.
fn embeddedGroup(comptime production: bool, comptime files: []const []const u8) SourceGroup {
    const sources = comptime blk: {
        var result: [files.len][:0]const u8 = undefined;
        for (files, 0..) |file, index| result[index] = @embedFile("../" ++ file);
        break :blk result;
    };
    return .{ .production = production, .files = files, .sources = &sources };
}

const source_groups = [_]SourceGroup{
    // Distribution extensions compile against only the public SDK and native
    // dependencies; they remain production inputs to every applicable audit.
    .{ .production = true, .files = &.{"../extensions/git/git.zig"}, .sources = &.{source_audit_options.git_extension_source} },
    .{ .production = true, .files = &.{"../extensions/net/net.zig"}, .sources = &.{source_audit_options.net_extension_source} },
    .{ .production = true, .files = &.{"../extensions/proc/proc.zig"}, .sources = &.{source_audit_options.proc_extension_source} },
    // Exact, non-rehashing map construction and resumable interning keep
    // user-sized storage work outside scheduler-native stacks.
    embeddedGroup(true, &.{
        "value.zig",       "heap.zig",                "intern.zig", "list.zig",
        "equal.zig",       "dict.zig",                "print.zig",  "poll.zig",
        "text_buffer.zig", "startup_environment.zig",
    }),
    // Tokenization, parsing, locals lowering, exact materialization, and
    // provenance publication all carry nominal resumable state. The larger
    // boundary replaces native-stack control flow.
    embeddedGroup(true, &.{
        "lexer.zig", "locals.zig", "reader_types.zig", "reader.zig", "reader_cursor.zig",
    }),
    // Resumable primitive shells own inputs and exact-size partial outputs;
    // their nominal driver states replace cancellation-only native stacks.
    // Source/file continuations and the typed, resumable failure unwinder make
    // ownership transfers explicit; this replaces hidden native traversal
    // frames and the duplicate synchronous error-value implementation.
    // The native-continuation union carries park, join, cleanup, and work
    // combinations as exhaustive variants rather than five side-band fields.
    embeddedGroup(true, &.{
        "machine.zig", "resolution_core.zig", "spans.zig", "prims.zig", "test_prims.zig", "internal.zig",
    }),
    // Snapshot-safe lookup, publication, and reflection now expose explicit
    // cursor state so scheduler suspension is represented instead of hidden
    // in cancellation-only loops.
    // Completion adds Directory/Shape/generation-owning cursors plus an
    // opaque rendered result rather than folding those lifetime boundaries
    // into Session internals.
    embeddedGroup(true, &.{
        "env.zig", "modules.zig", "snapshot.zig", "module_prims.zig", "reflection.zig", "session.zig", "inert_data.zig", "module_map.zig", "module_snapshot.zig",
    }),
    // The embedded prelude loader and the embedded stdlib manifest are one
    // bootstrap surface: both hand constant source to the ordinary reader.
    embeddedGroup(true, &.{
        "prelude.zig", "stdlib.zig",
    }),
    // First-party native stdlib modules are authored against the public SDK
    // and hold no host authority; they are user-sized traversal files whose
    // resumable state is the SDK's own continuation record.
    embeddedGroup(true, &.{
        "stdlib/csv.zig",
    }),
    // Builtin-backed stdlib modules hold host authority the SDK withholds, so
    // they are ordinary production sources under the bounded-traversal rules.
    embeddedGroup(true, &.{
        "stdlib/dict.zig",  "stdlib/rand.zig",   "stdlib/json.zig", "stdlib/http.zig", "stdlib/archive.zig", "stdlib/fs.zig",
        "stdlib/clock.zig", "stdlib/source.zig", "stdlib/host.zig", "stdlib/str.zig",
    }),
    embeddedGroup(true, &.{
        "combinators.zig",
    }),
    embeddedGroup(true, &.{
        "definition_prims.zig", "doc.zig",
    }),
    // The editor owns raw-terminal restoration, scalar-safe mutation, and
    // atomic locked history as separate nominal states.
    embeddedGroup(true, &.{
        "main.zig", "formatter.zig", "line_editor.zig",
    }),
    // Explicit continuation state is part of the kernel correctness boundary;
    // native-stack traversals could not yield.
    embeddedGroup(true, &.{
        "kernel_support.zig",  "kernels.zig",      "kernel_storage.zig",    "kernel_numeric.zig",
        "kernel_sequence.zig", "kernel_order.zig", "kernel_dict_text.zig",  "idioms.zig",
        "kernel_random.zig",   "kernel_flat.zig",  "driver_completion.zig",
    }),
    embeddedGroup(false, &.{
        "source_audit.zig",           "tools/source_audit.zig",
        "tools/bench_kernels.zig",    "tools/bench_workdrivers.zig",
        "tools/ecl_source_check.zig",
    }),
    // Scheduler-owned external resources: process ports, filesystem roots,
    // and network listeners share the nominal capability
    // vocabulary in external.zig and are opened only by their Session-owned
    // owner.
    embeddedGroup(true, &.{
        "scheduler.zig",        "scheduler_core.zig",     "turn_core.zig",       "external.zig",          "console.zig",           "task_prims.zig",      "archive_document.zig",
        "standard_streams.zig", "mailbox.zig",            "byte_ring.zig",       "port_transfer.zig",     "port_controller.zig",   "port_message.zig",    "port_failure.zig",
        "port_builder.zig",     "port_bytes.zig",         "port_messages.zig",   "port_declarations.zig", "port_resource.zig",     "resource_issuer.zig", "port_endpoint.zig",
        "port_result.zig",      "port_error_data.zig",    "port_exchange.zig",   "port_operation.zig",    "port_service.zig",      "port_factory.zig",    "http_service.zig",
        "filesystem_port.zig",  "directory_resource.zig", "directory_stage.zig", "directory_order.zig",   "filesystem_stream.zig",
    }),
    // The installed author SDK, its sized ABI records, validation, loader,
    // and transactional-call boundary form one separately rooted component.
    embeddedGroup(true, &.{
        "native/ports.zig",        "native/abi.zig",        "native/capability.zig", "native/sdk.zig",
        "native/build_helper.zig", "native_descriptor.zig", "native_module.zig",     "native_port.zig",
        "native_call.zig",         "stdlib/io.zig",         "stdlib/port.zig",       "stdlib/fd.zig",
    }),
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
    "tests/runtime_fixture.zig",
    "oom_root.zig",
    "tests/module_lifecycle_test.zig",
    "tests/stdlib_test.zig",
    "tests/hostio_test.zig",

    "tests/archive_test.zig",
    "tests/http_test.zig",
    "tests/random_test.zig",
    "tests/kernel_typed_test.zig",
    "tests/module_registration_test.zig",
    "tests/unit_input_test.zig",
    "tests/module_source_test.zig",
    "tests/test_language_test.zig",
    "tests/process_test.zig",
    "tests/filesystem_test.zig",
    "tests/net_test.zig",
    "tests/clock_test.zig",
    "tests/conversion_test.zig",
    "tests/cursor_budget_test.zig",
    "tests/interleaving_test.zig",
    "tests/mailbox_test.zig",
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
    "test/test_runner.zig",
    "test/native/sample.zig",
    "test/native/ports.zig",
    "test/native/tutorial.zig",
    "test/native/instance.zig",
    "test/native/instance_dynamic.zig",
    "test/native/malformed.zig",
    "test/native/negative/rejected_open_resource_authority.zig",
    "test/native/negative/rejected_open_child_authority.zig",
    "test/native/negative/rejected_open_clock_authority.zig",
    "test/native/negative/finalizer_resource_lease.zig",
    "test/native/negative/cooperative_prepared_failure.zig",
    "test/native/negative/resource_kind_state.zig",
    "test/native/negative/activity_stop_input.zig",
    "test/native/negative/activity_finish_output.zig",
    "test/native/negative/no_call_parameter.zig",
    "test/native/negative/invalid_instance_callbacks.zig",
    "test/native/negative/wrong_return_type.zig",
    "test/native/negative/generic_callback.zig",
    "test/native/negative/malformed_effect.zig",
    "test/native/negative/partial_effect.zig",
    "test/native/negative/output_arity_mismatch.zig",
    "test/native/negative/unknown_capability.zig",
    "test/native/negative/duplicate_word.zig",
    "test/native/negative/empty_doc.zig",
    "test/native/negative/invalid_port_callbacks.zig",
    "test/native/negative/cooperative_blocking_endpoint.zig",
    "test/native/negative/cooperative_commit_authority.zig",
    "test/native/negative/invalid_qualified_module.zig",
    "test/native/negative/overload_duplicate_resource.zig",
    "test/native/negative/overload_undeclared_resource.zig",
    "test/native/negative/diagnostic_child_creation.zig",
    "test/native/negative/cooperative_diagnostic_child_creation.zig",
    "test/native/negative/finalizer_child_creation.zig",
    "test/native/negative/activity_construction_authority.zig",
    "test/native/negative/shutdown_stream_authority.zig",
    "test/native/negative/activity_duplicate_endpoints.zig",
    "test/native/negative/invalid_cooperative_handler.zig",
    "test/native/negative/missing_port_recovery.zig",
    "test/native/negative/invalid_port_lanes.zig",
    "test/native/negative/resource_operation_endpoint.zig",
    "test/native/negative/wrong_controller_direction.zig",
    "test/native/negative/undeclared_port.zig",
    "test/native/negative/retained_port_candidate.zig",
    "test/http_fixture_server.zig",
    "test/process_fixture.zig",
};
pub fn main(init: std.process.Init) !void {
    var failed = false;
    for (source_groups) |component| {
        if (component.files.len != component.sources.len) return error.SourceAuditFailed;
    }
    failed = auditSourceCoverage(init) or failed;
    failed = auditExtensionImports() or failed;
    failed = auditSourceBodies() or failed;
    failed = auditFilesystemAuthority() or failed;
    failed = auditUnsafeCasts() or failed;
    failed = auditPreludeLayout() or failed;
    failed = auditHttpServerWriteSink() or failed;
    failed = auditFormalValueKinds() or failed;
    failed = auditWorkBudgetIssuers() or failed;
    failed = auditResultAdoption() or failed;
    failed = auditKernelDriverStarts() or failed;
    failed = auditUnreferencedDeclarations(init) or failed;
    if (failed) return error.SourceAuditFailed;
}

fn auditFormalValueKinds() bool {
    const source = source_audit_options.formal_values;
    const head_end = std.mem.indexOf(u8, source, "\n---") orelse {
        std.log.err("formal value kinds: first chapter has no body separator", .{});
        return true;
    };
    const fields = @typeInfo(ValueTag).@"enum".field_names;
    var seen: [fields.len]bool = @splat(false);
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
        inline for (fields, 0..) |field_name, index| {
            const expected = field_name ++ "-type";
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
    inline for (fields, 0..) |field_name, index| if (!seen[index]) {
        std.log.err("formal value kinds: value.Tag.{s} has no `{s}-type` declaration", .{
            field_name,
            field_name,
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
    var failed = false;
    var production_count: usize = 0;
    var verification_count: usize = 0;
    for ([_][]const u8{ "src", "extensions", "apps" }) |root| {
        var directory = std.Io.Dir.cwd().openDir(init.io, root, .{ .iterate = true }) catch |err| {
            std.log.err("source coverage: cannot open {s}: {s}", .{ root, @errorName(err) });
            return true;
        };
        defer directory.close(init.io);
        var walker = directory.walk(std.heap.page_allocator) catch return true;
        defer walker.deinit();
        while (walker.next(init.io) catch |err| {
            std.log.err("source coverage: cannot enumerate src: {s}", .{@errorName(err)});
            return true;
        }) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            var path_buffer: [4096]u8 = undefined;
            const path = if (std.mem.eql(u8, root, "src")) entry.path else std.fmt.bufPrint(&path_buffer, "../{s}/{s}", .{ root, entry.path }) catch return true;
            var matches: usize = 0;
            var is_production = false;
            for (source_groups) |component| for (component.files) |file| {
                if (!sameSourcePath(path, file)) continue;
                matches += 1;
                is_production = component.production;
            };
            for (test_files) |file| matches += @intFromBool(sameSourcePath(path, file));
            if (matches != 1) {
                std.log.err("source coverage: {s} belongs to {d} source groups; expected exactly one", .{
                    path, matches,
                });
                failed = true;
                continue;
            }
            if (is_production) production_count += 1 else verification_count += 1;
        }
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
        std.log.err("source coverage: manifest contains missing production or src verification inputs", .{});
        failed = true;
    }
    failed = auditRepositoryVerification(init) or failed;
    return failed;
}

// Local implementation units remain inside the same isolated extension root,
// and must themselves have an exhaustive production classification.
fn localExtensionImport(file: []const u8, literal: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const name = std.zig.string_literal.parseAlloc(allocator, literal) catch return false;
    defer allocator.free(name);
    if (!std.mem.endsWith(u8, name, ".zig") or std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    const directory = std.fs.path.dirname(file) orelse return false;
    for (source_groups) |group| {
        if (!group.production) continue;
        for (group.files) |candidate| {
            if (std.mem.eql(u8, std.fs.path.dirname(candidate) orelse continue, directory) and std.mem.eql(u8, std.fs.path.basename(candidate), name)) return true;
        }
    }
    return false;
}

fn auditExtensionImports() bool {
    var failed = false;
    for (source_groups) |group| for (group.files, group.sources) |file, source| {
        if (!std.mem.startsWith(u8, file, "../extensions/")) continue;
        var tokenizer = std.zig.Tokenizer.init(source);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .builtin or !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import")) continue;
            const open = tokenizer.next();
            const argument = tokenizer.next();
            const close = tokenizer.next();
            const spelling = source[argument.loc.start..argument.loc.end];
            if (open.tag != .l_paren or argument.tag != .string_literal or close.tag != .r_paren or
                (!std.mem.eql(u8, spelling, "\"std\"") and !std.mem.eql(u8, spelling, "\"builtin\"") and !std.mem.eql(u8, spelling, "\"ecl-native\"") and !std.mem.eql(u8, spelling, "\"c\"") and !localExtensionImport(file, spelling)))
            {
                std.log.err("extension boundary: {s} may import only std, compiler target metadata, ecl-native, its own translated C header as c, and classified local units", .{file});
                failed = true;
            }
        }
    };
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
        // Formatting belongs to check-ecl; this audit recognizes the ordered
        // definition forms and their navigation metadata.
        while (index < source.len and
            (std.ascii.isWhitespace(source[index]) or source[index] == ',')) : (index += 1)
        {}
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
                if (source[index] != '`') {
                    std.log.err("prelude layout: `{s}` lacks its terminal quoted name", .{expected_name});
                    return true;
                }
                const end = preludeTokenEnd(source, index + 1);
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
        std.mem.indexOfScalar(u8, "(),[]{}#`", source[end]) == null)
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
/// handle, never through the process working directory. Types cannot state
/// that: `std.Io.Dir.cwd()` is an ordinary function. Among the modules that implement
/// evaluated filesystem words, none may name the working directory; the
/// owners that open trusted host paths once at Session construction
/// (filesystem_port.zig, directory_resource.zig) and the CLI, map
/// discovery, and module-loading host boundaries do so by design.
fn auditFilesystemAuthority() bool {
    var failed = false;
    const ambient_cwd = [_][]const []const u8{
        &.{ "Dir", ".", "cwd", "(", ")" },
    };
    // Derive stdlib confinement from exhaustive production classification;
    // adding another builtin cannot silently evade this boundary.
    const unbounded_sorting = [_][]const []const u8{
        &.{ "std", ".", "mem", ".", "sort" },
        &.{ "std", ".", "sort", "." },
    };
    for (source_groups) |group| {
        if (!group.production) continue;
        for (group.files, group.sources) |name, text| {
            if (!std.mem.startsWith(u8, name, "stdlib/")) continue;
            failed = auditTokens(name, text, &ambient_cwd) or failed;
            failed = auditTokens(name, text, &unbounded_sorting) or failed;
        }
    }
    failed = auditProductionFunctionTokenPair(
        "filesystem_port.zig",
        @embedFile("../filesystem_port.zig"),
        "step",
        "cwd",
    ) or failed;
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
            "TaskDestroyAdapter",     "PortReleaseAdapter",     "AddressReleaseAdapter",
            "PortTransferAdapter",    "ModuleReleaseAdapter",   "RetirementAdapters",
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

/// A work budget is an owner's allowance, so only an owner may create one:
/// the machine for a unit's turn, the scheduler and the port builder for their
/// own steps, and `poll` itself. Everything else draws on a budget it was lent.
/// A cursor cannot be handed a count, since every cursor takes `*WorkBudget`,
/// but nothing in the type system stops a module from constructing a fresh
/// budget and lending that instead; construction is the boundary this audit owns.
const work_budget_issuers = [_][]const u8{ "poll.zig", "machine.zig", "scheduler.zig", "port_builder.zig" };

/// `poll.unbounded()` is the allowance for work no unit owns, and the audit
/// cannot tell a caller-bounded input from a user-sized one. The files below
/// hold the blocking constructors and setup paths that use it today, each
/// reviewed for a bounded input; a new use elsewhere needs the same review.
const unbounded_allowance_users = [_][]const u8{
    "dict.zig",       "doc.zig",     "inert_data.zig", "kernel_random.zig",
    "list.zig",       "machine.zig", "modules.zig",    "native_module.zig",
    "poll.zig",       "prelude.zig", "print.zig",      "session.zig",
    "task_prims.zig",
};

/// The kernel quantum is the length of a unit's turn. Code that meters its
/// own loop with it is minting a private allowance under another name, so the
/// constant may appear only where a turn or an owner's step is defined, where
/// typed kernels plan a range against the unit's remainder, and at the two
/// sites that use it as a size rather than a budget.
const kernel_quantum_users = [_][]const u8{
    "machine.zig", "scheduler.zig", "kernel_support.zig", "prelude.zig", "native_call.zig",
};

/// Kernel files start drivers only through `support.Kernel`, which decides
/// once whether a typed kernel runs inline or as a driver and owns the
/// charging, operand holding, and fault cleanup around it. The functions
/// below are the exceptions, each structural: it drives work the executor
/// does not model, such as boxed spines, dicts, quotations, or a cursor over
/// nested structure. A typed path in such a function still goes through the
/// executor; only its structural path starts a driver itself. The rule holds
/// both ways: a new driver start elsewhere fails, and so does an exception
/// that no longer starts one.
/// Kernel files are chosen from the production classification, so a newly
/// classified kernel file is audited without a second list. `kernel_support.zig`
/// is excluded because it owns `support.Kernel`, the one sanctioned start.
fn isKernelDriverFile(file: []const u8) bool {
    if (std.mem.eql(u8, file, "kernel_support.zig")) return false;
    if (std.mem.eql(u8, file, "idioms.zig")) return true;
    return std.mem.startsWith(u8, file, "kernel_") and std.mem.indexOfAny(u8, file, "/\\") == null;
}

const KernelDriverException = struct {
    file: []const u8,
    function: []const u8,
};

const kernel_driver_exceptions = [_]KernelDriverException{
    .{ .file = "kernel_numeric.zig", .function = "binaryPrimitive" },
    .{ .file = "kernel_numeric.zig", .function = "unaryPrimitive" },
    .{ .file = "kernel_numeric.zig", .function = "reduceGroups" },
    .{ .file = "kernel_sequence.zig", .function = "atPrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "inPrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "razePrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "takePrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "rotatePrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "installOne" },
    .{ .file = "kernel_sequence.zig", .function = "installCat" },
    .{ .file = "kernel_sequence.zig", .function = "installCons" },
    .{ .file = "kernel_sequence.zig", .function = "shapePrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "flipPrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "reshapePrimitive" },
    .{ .file = "kernel_sequence.zig", .function = "cutPrimitive" },
    .{ .file = "kernel_order.zig", .function = "cmpPrimitive" },
    .{ .file = "kernel_order.zig", .function = "startGrade" },
    .{ .file = "kernel_order.zig", .function = "distinctPrimitive" },
    .{ .file = "kernel_order.zig", .function = "groupPrimitive" },
    .{ .file = "kernel_order.zig", .function = "groupColumnsPrimitive" },
    .{ .file = "kernel_dict_text.zig", .function = "strPrimitive" },
    .{ .file = "kernel_dict_text.zig", .function = "hasPrimitive" },
    .{ .file = "kernel_dict_text.zig", .function = "putImpl" },
    .{ .file = "kernel_dict_text.zig", .function = "fromListsForModule" },
    .{ .file = "kernel_dict_text.zig", .function = "delPrimitive" },
    .{ .file = "kernel_dict_text.zig", .function = "mergePrimitive" },
    .{ .file = "kernel_dict_text.zig", .function = "joinPrimitive" },
    .{ .file = "kernel_dict_text.zig", .function = "formatPrimitive" },
    .{ .file = "idioms.zig", .function = "install" },
    .{ .file = "idioms.zig", .function = "applyLengthEach" },
    .{ .file = "idioms.zig", .function = "applyMatchEach" },
    .{ .file = "idioms.zig", .function = "applyMatchFind" },
    .{ .file = "idioms.zig", .function = "startReduction" },
};

fn auditKernelDriverStarts() bool {
    var seen: [kernel_driver_exceptions.len]bool = @splat(false);
    var failed = false;
    for (source_groups) |group| {
        if (!group.production) continue;
        for (group.files, group.sources) |file, source| {
            if (!isKernelDriverFile(file)) continue;
            var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch return true;
            defer tree.deinit(std.heap.page_allocator);
            if (tree.errors.len != 0) return true;
            for (0..tree.nodes.len) |raw_node| {
                const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
                if (tree.nodeTag(node) != .fn_decl) continue;
                var buffer: [1]std.zig.Ast.Node.Index = undefined;
                const prototype = tree.fullFnProto(&buffer, node) orelse continue;
                const name_token = prototype.name_token orelse continue;
                const name = tree.tokenSlice(name_token);
                const body = tree.nodeData(node).node_and_node[1];
                const starts = for (tree.firstToken(body)..tree.lastToken(body)) |token| {
                    const spelling = tree.tokenSlice(@intCast(token));
                    const is_start = std.mem.eql(u8, spelling, "runDriver") or
                        std.mem.eql(u8, spelling, "runDriverAt") or
                        std.mem.eql(u8, spelling, "startDriver");
                    if (is_start and std.mem.eql(u8, tree.tokenSlice(@intCast(token + 1)), "(")) break true;
                } else false;
                if (!starts) continue;
                const listed = for (kernel_driver_exceptions, 0..) |exception, index| {
                    if (std.mem.eql(u8, exception.file, file) and std.mem.eql(u8, exception.function, name)) {
                        seen[index] = true;
                        break true;
                    }
                } else false;
                if (!listed) {
                    std.log.err("{s}: `{s}` starts a driver directly; run typed kernels through `support.Kernel`, or list the function in kernel_driver_exceptions if its path is structural", .{ file, name });
                    failed = true;
                }
            }
        }
    }
    for (kernel_driver_exceptions, seen) |exception, found| {
        if (found) continue;
        std.log.err("{s}: kernel_driver_exceptions lists `{s}`, which no longer starts a driver; remove it", .{ exception.file, exception.function });
        failed = true;
    }
    return failed;
}

/// A result takes over an operand's buffer through one decision,
/// `support.adopt`, which every producer that can write over its input asks
/// (a `support.Kernel` declares its result shape and the executor asks for
/// it). The capability that decision issues is the heap's; naming it anywhere
/// else is a producer claiming a buffer for itself.
const result_adoption_owners = [_][]const u8{ "heap.zig", "kernel_support.zig" };

fn auditResultAdoption() bool {
    const claims = [_][]const []const u8{
        &.{"UniqueLeafAdoption"},
        &.{"claimHeld"},
        &.{"claimUniqueList"},
    };
    var failed = false;
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file| {
            if (!namedIn(&result_adoption_owners, file))
                failed = auditProductionTokens(file, source, &claims) or failed;
        }
    }
    return failed;
}

fn auditWorkBudgetIssuers() bool {
    const minted = [_][]const []const u8{
        &.{ "WorkBudget", ".", "init" },
        &.{ "WorkBudget", "=", ".", "init" },
        &.{ "WorkBudget", "=", ".", "{" },
    };
    const unbounded = [_][]const []const u8{&.{ "unbounded", "(" }};
    const kernel_quantum = [_][]const []const u8{&.{"kernel_poll_quantum"}};
    var failed = false;
    for (source_groups) |component| {
        if (!component.production) continue;
        for (component.sources, component.files) |source, file| {
            if (!namedIn(&work_budget_issuers, file)) {
                failed = auditProductionTokens(file, source, &minted) or failed;
                failed = auditTypedBudgetLiterals(file, source) or failed;
            }
            if (!namedIn(&unbounded_allowance_users, file))
                failed = auditProductionTokens(file, source, &unbounded) or failed;
            if (!namedIn(&kernel_quantum_users, file))
                failed = auditProductionTokens(file, source, &kernel_quantum) or failed;
        }
    }
    return failed;
}

fn auditTypedBudgetLiterals(file: []const u8, source: [:0]const u8) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const literal = tree.fullStructInit(&buffer, node) orelse continue;
        const type_expr = literal.ast.type_expr.unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.lastToken(type_expr)), "WorkBudget")) continue;
        const token = tree.firstToken(node);
        const in_test = for (tree.rootDecls()) |declaration| {
            if (tree.nodeTag(declaration) == .test_decl and
                token >= tree.firstToken(declaration) and token <= tree.lastToken(declaration)) break true;
        } else false;
        if (in_test) continue;
        std.log.err("{s}: production code constructs a typed WorkBudget literal", .{file});
        failed = true;
    }
    return failed;
}

fn namedIn(names: []const []const u8, file: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, file)) return true;
    return false;
}

/// `auditTokens` over everything but `test` declarations.
fn auditProductionTokens(
    label: []const u8,
    source: [:0]const u8,
    forbidden: []const []const []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch {
        std.log.err("{s}: could not parse source for architecture audit", .{label});
        return true;
    };
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) {
        std.log.err("{s}: source has parser errors during architecture audit", .{label});
        return true;
    }
    var failed = false;
    var start: usize = 0;
    for (tree.rootDecls()) |declaration| {
        if (tree.nodeTag(declaration) != .test_decl) continue;
        const first = tree.firstToken(declaration);
        failed = hasForbiddenTokens(label, tree, start, first, forbidden) or failed;
        start = tree.lastToken(declaration) + 1;
    }
    return hasForbiddenTokens(label, tree, start, tree.tokens.len, forbidden) or failed;
}

fn auditProductionFunctionTokenPair(
    file: []const u8,
    source: [:0]const u8,
    first_spelling: []const u8,
    second_spelling: []const u8,
) bool {
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch return true;
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
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw_node));
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
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch return true;
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
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    if (tree.errors.len != 0) return true;
    var failed = false;
    var node_index: usize = 0;
    while (node_index < tree.nodes.len) : (node_index += 1) {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(node_index));
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
                &.{ &.{"pushOwned"}, &.{ "std", ".", "Io", ".", "concurrent" }, &.{ "std", ".", "Io", ".", "Future" } },
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
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch {
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
    var tree = std.zig.Ast.parse(std.heap.page_allocator, source, .{}) catch return true;
    defer tree.deinit(std.heap.page_allocator);
    var node_index: usize = 0;
    while (node_index < tree.nodes.len) : (node_index += 1) {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(node_index));
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

/// Every byte the HTTP server writes has passed `render-response`: the module
/// calls `net.write` from exactly one private word, `write-response`, whose
/// body validates and encodes before writing. Nothing at runtime can hold a
/// source module to one call site, so the audit does.
fn auditHttpServerWriteSink() bool {
    const source = @embedFile("../stdlib/http/server.ecl");
    var failed = false;
    var count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, source, scan, "net.write")) |found| {
        scan = found + "net.write".len;
        // A comment line is prose, not a call site.
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..found], '\n')) |newline| newline + 1 else 0;
        const line_text = std.mem.trimStart(u8, source[line_start..found], " ");
        if (line_text.len > 0 and line_text[0] == '#') continue;
        count += 1;
        // The immediately enclosing declaration is whichever exact-word
        // navigation header is nearest above the occurrence.
        const header = lastDeclarationHeader(source[0..found]) orelse {
            std.log.err("http server write sink: `net.write` appears outside `write-response`", .{});
            failed = true;
            continue;
        };
        const name_end = preludeTokenEnd(source, header.name_start);
        if (!std.mem.eql(u8, source[header.name_start..name_end], "write-response")) {
            std.log.err("http server write sink: `net.write` appears in `{s}`; only `write-response` may write", .{source[header.name_start..name_end]});
            failed = true;
        }
    }
    if (count != 1) {
        std.log.err("http server write sink: expected exactly one `net.write` call site, found {d}", .{count});
        failed = true;
    }
    return failed;
}

const DeclarationHeader = struct { position: usize, name_start: usize };

fn lastDeclarationHeader(source: []const u8) ?DeclarationHeader {
    const prefixes = [_][]const u8{ "### def ", "### defp ", "### set ", "### setp " };
    var latest: ?DeclarationHeader = null;
    for (prefixes) |prefix| {
        const position = std.mem.lastIndexOf(u8, source, prefix) orelse continue;
        if (latest == null or position > latest.?.position) {
            latest = .{ .position = position, .name_start = position + prefix.len };
        }
    }
    return latest;
}

/// Every container-level declaration must be reachable from code that runs: a
/// test, an exported symbol, an entry point, or another reachable declaration.
/// Zig analyzes only what something references, so an unreachable declaration
/// compiles without ever being checked or exercised. Data or types that only
/// `comptime` blocks reach fail too: a check whose subject nothing else uses
/// proves only itself. Functions and types reached that way are the checks
/// and their vocabulary, and pass.
///
/// References resolve by name, so a name shared with a reachable declaration
/// counts as reachable: the rule can miss dead code but never invents it.
/// Comments are not references; an identifier-shaped string literal is, for
/// `@hasDecl` and `@field`, and is owned and reached like an identifier. Compile-failure fixtures are skipped.
fn auditUnreferencedDeclarations(init: std.process.Init) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scan = DeclarationScan{ .arena = arena };
    for ([_][]const u8{ "src", "test", "apps", "extensions" }) |root| {
        var directory = std.Io.Dir.cwd().openDir(init.io, root, .{ .iterate = true }) catch |err| {
            std.log.err("declarations: cannot open {s}: {s}", .{ root, @errorName(err) });
            return true;
        };
        defer directory.close(init.io);
        var walker = directory.walk(arena) catch |err| {
            std.log.err("declarations: cannot walk {s}: {s}", .{ root, @errorName(err) });
            return true;
        };
        defer walker.deinit();
        while (walker.next(init.io) catch |err| {
            std.log.err("declarations: cannot enumerate {s}: {s}", .{ root, @errorName(err) });
            return true;
        }) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.path }) catch |err| {
                std.log.err("declarations: cannot record {s}/{s}: {s}", .{ root, entry.path, @errorName(err) });
                return true;
            };
            std.mem.replaceScalar(u8, path, '\\', '/');
            if (std.mem.indexOf(u8, path, "zig-cache") != null or
                std.mem.indexOf(u8, path, "zig-pkg") != null or
                std.mem.startsWith(u8, path, "test/native/negative/")) continue;
            scan.add(init, path) catch |err| {
                std.log.err("declarations: cannot scan {s}: {s}", .{ path, @errorName(err) });
                return true;
            };
        }
    }
    var repository = std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true }) catch |err| {
        std.log.err("declarations: cannot open repository root: {s}", .{@errorName(err)});
        return true;
    };
    defer repository.close(init.io);
    var iterator = repository.iterate();
    while (iterator.next(init.io) catch |err| {
        std.log.err("declarations: cannot enumerate repository root: {s}", .{@errorName(err)});
        return true;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const path = arena.dupe(u8, entry.name) catch |err| {
            std.log.err("declarations: cannot record {s}: {s}", .{ entry.name, @errorName(err) });
            return true;
        };
        scan.add(init, path) catch |err| {
            std.log.err("declarations: cannot scan {s}: {s}", .{ path, @errorName(err) });
            return true;
        };
    }
    return scan.report() catch true;
}

const DeclarationScan = struct {
    arena: std.mem.Allocator,
    files: std.ArrayList(File) = .empty,
    declarations: std.ArrayList(Declaration) = .empty,

    const File = struct {
        path: []const u8,
        tree: std.zig.Ast,
        /// For each token, the innermost declaration or block containing it.
        owners: []u32,
    };
    const top: u32 = std.math.maxInt(u32);
    const in_test: u32 = top - 1;
    const in_comptime: u32 = top - 2;

    const Declaration = struct {
        file: u32,
        name: []const u8,
        name_token: u32,
        first: u32,
        last: u32,
        function: bool,
        /// Declares a type, or may: a container, or an alias or computed type
        /// whose initializer is not plainly a value.
        type_like: bool,
        root: bool,
        comptime_used: bool = false,
        users: std.ArrayList(u32) = .empty,
    };

    fn add(self: *DeclarationScan, init: std.process.Init, path: []const u8) !void {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(init.io, path, self.arena, .unlimited, .of(u8), 0);
        const tree = try std.zig.Ast.parse(self.arena, source, .{});
        if (tree.errors.len != 0) return error.ParseFailed;
        const owners = try self.arena.alloc(u32, tree.tokens.len);
        @memset(owners, top);
        const file: u32 = @intCast(self.files.items.len);
        try self.files.append(self.arena, .{ .path = path, .tree = tree, .owners = owners });
        try self.collect(file, tree.rootDecls());
    }

    /// Records a container's members in source order, outer before inner, so
    /// each token's owner ends as the innermost one.
    fn collect(self: *DeclarationScan, file: u32, members: []const std.zig.Ast.Node.Index) error{OutOfMemory}!void {
        const tree = &self.files.items[file].tree;
        const owners = self.files.items[file].owners;
        for (members) |member| {
            const first = tree.firstToken(member);
            const last = tree.lastToken(member);
            switch (tree.nodeTag(member)) {
                .test_decl => @memset(owners[first .. last + 1], in_test),
                .@"comptime" => @memset(owners[first .. last + 1], in_comptime),
                .fn_decl => {
                    var buffer: [1]std.zig.Ast.Node.Index = undefined;
                    const function = tree.fullFnProto(&buffer, member).?;
                    const name_token = function.name_token orelse continue;
                    const exported = if (function.extern_export_inline_token) |token|
                        tree.tokenTag(token) == .keyword_export
                    else
                        false;
                    try self.declare(file, name_token, first, last, true, false, exported);
                    try self.collectNested(file, first, last);
                },
                .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                    const variable = tree.fullVarDecl(member).?;
                    const exported = if (variable.extern_export_token) |token|
                        tree.tokenTag(token) == .keyword_export
                    else
                        false;
                    var buffer: [2]std.zig.Ast.Node.Index = undefined;
                    const container = if (variable.ast.init_node.unwrap()) |initializer|
                        tree.fullContainerDecl(&buffer, initializer)
                    else
                        null;
                    const type_like = container != null or if (variable.ast.init_node.unwrap()) |initializer|
                        typeExpression(tree.nodeTag(initializer))
                    else
                        false;
                    try self.declare(file, variable.ast.mut_token + 1, first, last, false, type_like, exported);
                    if (container) |declared| try self.collect(file, declared.ast.members);
                },
                else => {},
            }
        }
    }

    /// Initializers that can denote a type. Aliases, `@TypeOf`, and calls to
    /// type-returning functions look alike to a syntax scan, so only plain
    /// values are excluded.
    fn typeExpression(tag: std.zig.Ast.Node.Tag) bool {
        return switch (tag) {
            .identifier,
            .field_access,
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            .optional_type,
            .error_union,
            .merge_error_sets,
            .error_set_decl,
            .array_type,
            .array_type_sentinel,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            => true,
            else => false,
        };
    }

    /// A function's body can declare the container it returns, and its
    /// members are declarations too. Takes the outermost containers inside
    /// `first..last`; `collect` descends into the rest.
    fn collectNested(self: *DeclarationScan, file: u32, first: u32, last: u32) error{OutOfMemory}!void {
        const tree = &self.files.items[file].tree;
        var found: std.ArrayList(std.zig.Ast.Node.Index) = .empty;
        for (0..tree.nodes.len) |raw| {
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw));
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buffer, node) == null) continue;
            const start = tree.firstToken(node);
            if (start < first or tree.lastToken(node) > last) continue;
            try found.append(self.arena, node);
        }
        std.mem.sort(std.zig.Ast.Node.Index, found.items, tree, struct {
            fn less(ast: *const std.zig.Ast, a: std.zig.Ast.Node.Index, b: std.zig.Ast.Node.Index) bool {
                return ast.firstToken(a) < ast.firstToken(b);
            }
        }.less);
        var covered: u32 = 0;
        for (found.items) |node| {
            if (tree.firstToken(node) < covered) continue;
            covered = tree.lastToken(node) + 1;
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            try self.collect(file, tree.fullContainerDecl(&buffer, node).?.ast.members);
        }
    }

    fn declare(self: *DeclarationScan, file: u32, name_token: u32, first: u32, last: u32, function: bool, type_like: bool, exported: bool) !void {
        const tree = &self.files.items[file].tree;
        const name = identifierName(tree.tokenSlice(name_token));
        const entry_point = for ([_][]const u8{ "main", "build", "panic", "std_options" }) |root| {
            if (std.mem.eql(u8, name, root)) break true;
        } else false;
        const index: u32 = @intCast(self.declarations.items.len);
        try self.declarations.append(self.arena, .{
            .file = file,
            .name = name,
            .name_token = name_token,
            .first = first,
            .last = last,
            .function = function,
            .type_like = type_like,
            .root = exported or entry_point,
        });
        @memset(self.files.items[file].owners[first .. last + 1], index);
    }

    fn identifierName(spelling: []const u8) []const u8 {
        if (std.mem.startsWith(u8, spelling, "@\"")) return spelling[2 .. spelling.len - 1];
        return spelling;
    }

    fn identifierShaped(text: []const u8) bool {
        if (text.len == 0 or std.ascii.isDigit(text[0])) return false;
        for (text) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
        return true;
    }

    fn report(self: *DeclarationScan) !bool {
        var by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
        for (self.declarations.items, 0..) |declaration, index| {
            const slot = try by_name.getOrPut(self.arena, declaration.name);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(self.arena, @intCast(index));
        }
        for (self.files.items, 0..) |file, file_index| {
            for (0..file.tree.tokens.len) |raw_token| {
                const token: u32 = @intCast(raw_token);
                const named = named: switch (file.tree.tokenTag(token)) {
                    .identifier => identifierName(file.tree.tokenSlice(token)),
                    .string_literal => {
                        const spelling = file.tree.tokenSlice(token);
                        const text = spelling[1 .. spelling.len - 1];
                        // A name spelled as a string is used by reflection, from wherever it appears.
                        if (!identifierShaped(text)) continue;
                        break :named text;
                    },
                    else => continue,
                };
                const candidates = by_name.get(named) orelse continue;
                const owner = file.owners[token];
                for (candidates.items) |candidate| {
                    const declaration = &self.declarations.items[candidate];
                    // A declaration's own name and body do not keep it alive.
                    if (declaration.file == file_index and declaration.first <= token and token <= declaration.last) continue;
                    switch (owner) {
                        top, in_test => declaration.root = true,
                        in_comptime => declaration.comptime_used = true,
                        else => try self.declarations.items[owner].users.append(self.arena, candidate),
                    }
                }
            }
        }
        // `users` was filled user-to-used; walk it forward from every root.
        const live = try self.reach(struct {
            fn seed(declaration: Declaration) bool {
                return declaration.root;
            }
        }.seed, null);
        const checked = try self.reach(struct {
            fn seed(declaration: Declaration) bool {
                return declaration.comptime_used;
            }
        }.seed, live);
        var failed = false;
        for (self.declarations.items, 0..) |declaration, index| {
            if (live[index]) continue;
            const file = self.files.items[declaration.file];
            const line = file.tree.tokenLocation(0, declaration.name_token).line + 1;
            if (!checked[index]) {
                std.log.err("{s}:{d}: `{s}` is never used: nothing outside its own body reaches it", .{ file.path, line, declaration.name });
                failed = true;
            } else if (!declaration.function and !declaration.type_like) {
                std.log.err("{s}:{d}: `{s}` is reached only by comptime checks; data nothing else uses proves nothing", .{ file.path, line, declaration.name });
                failed = true;
            }
        }
        return failed;
    }

    /// Every declaration reachable from those `seed` selects, not passing
    /// through any already in `excluded`.
    fn reach(self: *DeclarationScan, seed: fn (Declaration) bool, excluded: ?[]const bool) ![]bool {
        const reached = try self.arena.alloc(bool, self.declarations.items.len);
        @memset(reached, false);
        var pending: std.ArrayList(u32) = .empty;
        for (self.declarations.items, 0..) |declaration, index| {
            if (!seed(declaration)) continue;
            if (excluded) |skip| if (skip[index]) continue;
            reached[index] = true;
            try pending.append(self.arena, @intCast(index));
        }
        while (pending.pop()) |index| {
            for (self.declarations.items[index].users.items) |used| {
                if (reached[used]) continue;
                if (excluded) |skip| if (skip[used]) continue;
                reached[used] = true;
                try pending.append(self.arena, used);
            }
        }
        return reached;
    }
};
