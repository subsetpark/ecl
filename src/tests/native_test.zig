const std = @import("std");
const abi = @import("native-abi");
const descriptor_api = @import("../native_descriptor.zig");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const modules = @import("../modules.zig");
const native_module = @import("../native_module.zig");
const session = @import("../session.zig");
const native_sample = @import("native-sample");
const native_fixture = @import("native_fixture_options");
const ecl = @import("ecl-native");

const PortSpec = struct {
    pub const name = "counter";
    pub const State = struct { value: u64 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(_: *State, _: u32, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
};

test "native: SDK port declarations validate state layouts and controller adapters" {
    const P = ecl.Port(PortSpec);
    const Extension = ecl.module(.{ .name = "sample", .doc = "Port definition probe.", .linkage = .static, .words = .{}, .ports = .{P} });
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    const validated = try validate(host.cleanup(), requested, Extension.descriptor());
    defer validated.deinit();
    const port = validated.port(0).?;
    try std.testing.expectEqualStrings("counter", port.name_ptr[0..port.name_len]);
    try std.testing.expectEqual(@as(u32, @sizeOf(PortSpec.State)), port.state_size);
    try std.testing.expect(validated.port(1) == null);
    var invalid = Extension.descriptor().*;
    var definition = P.definition();
    invalid.ports_ptr = @ptrCast(&definition);
    definition.cancel = null;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition = P.definition();
    definition.state_alignment = 3;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
}

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("native-test.ecl", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.debug.print("unexpected native ECL error: {s}\n", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
    }
}

fn expectErrorContains(
    runtime: *session.Session,
    source: []const u8,
    needles: []const []const u8,
) !void {
    const failure = switch (try runtime.runUnit("native-test.ecl", source)) {
        .err => |item| item,
        .ok => return error.ExpectedLanguageError,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    for (needles) |needle|
        try std.testing.expect(std.mem.indexOf(u8, rendered.bytes(), needle) != null);
}

fn initRuntime(
    output: *std.Io.Writer,
    diagnostics: *std.Io.Writer,
    search: []const u8,
) !session.Session {
    return session.Session.initWithHost(std.testing.allocator, &.{}, .{
        .io = std.testing.io,
        .output = output,
        .diagnostics = diagnostics,
        .ecl_path = search,
    });
}

const Fixture = struct {
    module_name: []const u8 = "sample",
    module_doc: []const u8 = "Sample native fixture.",
    word_name: []const u8 = "increment",
    word_doc: []const u8 = "Increment a number.",
    input_name: []const u8 = "n",
    output_name: []const u8 = "result",
    inputs: ?[1]abi.EffectSlot = null,
    outputs: ?[1]abi.EffectSlot = null,
    definitions: ?[1]abi.Definition = null,
    capabilities: ?[1]abi.CapabilityRequirement = null,

    fn descriptor(self: *Fixture) abi.Descriptor {
        self.inputs = .{.{
            .name_ptr = self.input_name.ptr,
            .name_len = self.input_name.len,
        }};
        self.outputs = .{.{
            .name_ptr = self.output_name.ptr,
            .name_len = self.output_name.len,
        }};
        self.definitions = .{.{
            .callback_index = 0,
            .name_ptr = self.word_name.ptr,
            .name_len = self.word_name.len,
            .doc_ptr = self.word_doc.ptr,
            .doc_len = self.word_doc.len,
            .input_count = self.inputs.?.len,
            .inputs_ptr = &self.inputs.?,
            .output_count = self.outputs.?.len,
            .outputs_ptr = &self.outputs.?,
        }};
        self.capabilities = .{.{ .id = @intFromEnum(abi.CapabilityId.call) }};
        return .{
            .module_name_ptr = self.module_name.ptr,
            .module_name_len = self.module_name.len,
            .module_doc_ptr = self.module_doc.ptr,
            .module_doc_len = self.module_doc.len,
            .definition_count = self.definitions.?.len,
            .definitions_ptr = &self.definitions.?,
            .capability_count = self.capabilities.?.len,
            .capabilities_ptr = &self.capabilities.?,
            .callback_count = 1,
            .invoke = dummyInvoke,
        };
    }
};

fn dummyInvoke(_: *const abi.HostTable, _: *anyopaque, _: u32, output: *abi.InvokeResult) callconv(.c) void {
    output.* = .{ .tag = .fail };
}

test "native: opaque ports survive forwarding and nested aggregate builders" {
    const Port = struct {
        releases: usize = 0,

        pub fn releasePort(self: *@This()) void {
            self.releases += 1;
        }
        pub fn prepareScopeTransfer(_: *@This(), _: *anyopaque, _: *anyopaque) heap.PortTransferError!void {
            return error.Closed;
        }
        pub fn commitScopeTransfer(_: *@This()) void {}
        pub fn abortScopeTransfer(_: *@This()) void {}
    };
    var port: Port = .{};
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    {
        var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
        defer runtime.deinit();
        try runtime.pushOwned(try heap.createPort(Port, std.testing.allocator, 917, &port));
        try expectErrorContains(&runtime, "sample.draft-fail", &.{ "'kind 'user", "draft candidates retired" });
        try std.testing.expectEqual(@as(usize, 0), port.releases);
        try expectOk(
            &runtime,
            "sample.forward sample.split " ++
                "sample.singleton sample.nested-port " ++
                "'key swap sample.pair-dict sample.nested-port match?",
        );
        try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
        try std.testing.expectEqual(@as(usize, 1), port.releases);
    }
    try std.testing.expectEqual(@as(usize, 1), port.releases);
}

fn validate(
    host: *const heap.HostCleanup,
    requested: intern.ModuleName,
    raw: *const abi.Descriptor,
) descriptor_api.ValidateError!*descriptor_api.ValidatedDescriptor {
    var cursor = descriptor_api.ValidateCursor.init(host, requested, raw);
    defer cursor.deinit();
    while (true) switch (try cursor.advance(7)) {
        .pending => {},
        .complete => |validated| return validated,
    };
}

fn expectReject(
    expected: descriptor_api.ValidateError,
    host: *const heap.HostCleanup,
    requested: intern.ModuleName,
    raw: *const abi.Descriptor,
) !void {
    var cursor = descriptor_api.ValidateCursor.init(host, requested, raw);
    defer cursor.deinit();
    while (true) {
        const progress = cursor.advance(5) catch |err| {
            try std.testing.expectEqual(expected, err);
            return;
        };
        switch (progress) {
            .pending => {},
            .complete => |validated| {
                validated.deinit();
                return error.TestExpectedError;
            },
        }
    }
}

test "native: descriptor validation rejects malformed metadata before publication" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    var fixture = Fixture{};

    var raw = fixture.descriptor();
    raw.abi_version += 1;
    try expectReject(error.AbiVersionMismatch, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.capabilities.?[0].id = 99;
    try expectReject(error.UnsupportedCapabilityId, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.definitions.?[0].callback_index = 1;
    try expectReject(error.CallbackIndexOutOfRange, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.definitions.?[0].size = 4;
    try expectReject(error.RecordSizeMismatch, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.definitions.?[0].continuation_size = 8;
    try expectReject(error.InvalidContinuation, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    raw.module_name_ptr = "different".ptr;
    raw.module_name_len = "different".len;
    try expectReject(error.ModuleNameMismatch, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.word_doc = " \n\t";
    raw = fixture.descriptor();
    try expectReject(error.EmptyDocumentation, host.cleanup(), requested, &raw);

    fixture.word_doc = "Increment a number.";
    fixture.word_name = "bad.name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);

    fixture.word_name = "bad name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);

    fixture.word_name = "bad\u{00a0}name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);

    fixture.word_name = "increment";
    fixture.module_name = "bad\u{2000}name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);
}

test "native: validation copies names effects and documentation into runtime storage" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    var module_name = [_]u8{ 's', 'a', 'm', 'p', 'l', 'e' };
    var word_name = [_]u8{ 'i', 'n', 'c', 'r', 'e', 'm', 'e', 'n', 't' };
    var word_doc = "Increment a number.".*;
    var fixture = Fixture{
        .module_name = &module_name,
        .word_name = &word_name,
        .word_doc = &word_doc,
    };
    var raw = fixture.descriptor();
    const validated = try validate(host.cleanup(), requested, &raw);
    defer validated.deinit();

    @memset(&module_name, 'x');
    @memset(&word_name, 'x');
    @memset(&word_doc, 'x');

    try std.testing.expectEqualStrings("sample", intern.get(intern.moduleId(validated.name())));
    try std.testing.expectEqual(@as(usize, 1), validated.definitions().len);
    const definition = validated.definitions()[0];
    try std.testing.expectEqualStrings("increment", intern.get(intern.namespaceId(definition.name)));
    try std.testing.expectEqual(@as(u32, 1), definition.effect.inputs);
    try std.testing.expectEqual(@as(u32, 1), definition.effect.outputs);
    const document = env.documentationHeader(definition.doc);
    try std.testing.expectEqual(@as(u64, "Increment a number.".len), document.length());
    for ("Increment a number.", 0..) |byte, index|
        try std.testing.expectEqual(@as(u32, byte), list.atUnchecked(.{ .list = document }, index).char);
    try std.testing.expectEqual(@as(usize, 1), validated.requirements().len);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.call), validated.requirements()[0].id);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, validationAllocationProbe, .{});
}

fn validationAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("allocation-native");
    var fixture = Fixture{ .module_name = "allocation-native" };
    var raw = fixture.descriptor();
    const validated = try validate(host.cleanup(), requested, &raw);
    validated.deinit();
}

test "native: the SDK generates a descriptor the production validator accepts" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    const validated = try validate(host.cleanup(), requested, native_sample.Extension.descriptor());
    defer validated.deinit();

    try std.testing.expectEqualStrings("sample", intern.get(intern.moduleId(validated.name())));
    try std.testing.expectEqual(@as(usize, 20), validated.definitions().len);
    const expected_names = [_][]const u8{
        "increment",     "discard",        "split",      "forward",    "nested-port",    "fail-user",      "fail-kind",
        "make-char",     "singleton",      "pair-dict",  "sum-list",   "sum-dict",       "cooperative",    "draft-fail",
        "yield-forever", "builder-budget", "large-list", "large-dict", "duplicate-dict", "noncooperative",
    };
    for (validated.definitions(), expected_names) |definition, expected| {
        try std.testing.expectEqualStrings(expected, intern.get(intern.namespaceId(definition.name)));
        try std.testing.expect(env.documentationHeader(definition.doc).length() != 0);
    }
    try std.testing.expectEqual(@as(usize, 3), validated.requirements().len);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.call), validated.requirements()[0].id);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.build_values), validated.requirements()[1].id);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.reschedule), validated.requirements()[2].id);
}

test "native: a discovered artifact publishes its complete table atomically" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "'sample ('increment) import 40 sample.increment 41 increment 's 'sample alias 42 s.increment",
    );
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 41), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 43), runtime.stackItems()[2].int);

    const exports = [_][]const u8{
        "sample.increment",     "sample.discard",        "sample.split",
        "sample.forward",       "sample.fail-user",      "sample.fail-kind",
        "sample.singleton",     "sample.pair-dict",      "sample.sum-list",
        "sample.sum-dict",      "sample.cooperative",    "sample.draft-fail",
        "sample.yield-forever", "sample.builder-budget", "sample.large-list",
        "sample.large-dict",    "sample.duplicate-dict", "sample.noncooperative",
    };
    for (exports) |prefix| {
        var completion = try runtime.completionCandidates(prefix);
        defer completion.deinit();
        try std.testing.expectEqual(@as(usize, 1), completion.items().len);
        try std.testing.expectEqualStrings(prefix, completion.items()[0]);
    }
}

test "native: source candidates win inside a root and path-root order wins across roots" {
    const fixture_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ native_fixture.directory, "sample.eclmod" },
    );
    defer std.testing.allocator.free(fixture_path);

    var same_root = std.testing.tmpDir(.{});
    defer same_root.cleanup();
    try same_root.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.ecl",
        .data = "[] (100 'increment set) 'sample @defm",
    });
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        fixture_path,
        same_root.dir,
        "sample.eclmod",
        std.testing.io,
        .{},
    );
    const same_root_path = try same_root.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(same_root_path);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var source_first = try initRuntime(&output.writer, &diagnostics.writer, same_root_path);
    defer source_first.deinit();
    try expectOk(&source_first, "sample.increment");
    try std.testing.expectEqual(@as(i64, 100), source_first.stackItems()[0].int);

    var native_root = std.testing.tmpDir(.{});
    defer native_root.cleanup();
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        fixture_path,
        native_root.dir,
        "sample.eclmod",
        std.testing.io,
        .{},
    );
    var later_source = std.testing.tmpDir(.{});
    defer later_source.cleanup();
    try later_source.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.ecl",
        .data = "[] (100 'increment set) 'sample @defm",
    });
    const native_root_path = try native_root.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(native_root_path);
    const later_source_path = try later_source.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(later_source_path);
    const search = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}{c}{s}",
        .{ native_root_path, std.fs.path.delimiter, later_source_path },
    );
    defer std.testing.allocator.free(search);
    var path_first = try initRuntime(&output.writer, &diagnostics.writer, search);
    defer path_first.deinit();
    try expectOk(&path_first, "41 sample.increment");
    try std.testing.expectEqual(@as(i64, 42), path_first.stackItems()[0].int);
}

test "native: a rejected artifact publishes nothing and never selects a later candidate" {
    const cases = [_]struct { defect: []const u8, message: []const u8 }{
        .{ .defect = "wrong-name", .message = "ModuleNameMismatch" },
        .{ .defect = "abi-version", .message = "AbiVersionMismatch" },
        .{ .defect = "duplicate-word", .message = "DuplicateDefinition at definition 1" },
        .{ .defect = "missing-doc", .message = "EmptyDocumentation at definition 0" },
        .{ .defect = "entry-failure", .message = "native module entry failed" },
        .{ .defect = "invalid-effect", .message = "InvalidEffect at definition 0" },
        .{ .defect = "unsupported-capability", .message = "UnsupportedCapabilityId" },
        .{ .defect = "invalid-continuation", .message = "InvalidContinuation" },
    };
    for (cases) |case| {
        const broken = try std.fs.path.join(
            std.testing.allocator,
            &.{ native_fixture.directory, case.defect },
        );
        defer std.testing.allocator.free(broken);
        const search = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{c}{s}",
            .{ broken, std.fs.path.delimiter, native_fixture.directory },
        );
        defer std.testing.allocator.free(search);
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        var runtime = try initRuntime(&output.writer, &diagnostics.writer, search);
        defer runtime.deinit();
        try expectErrorContains(&runtime, "'sample ('increment) import", &.{ "'kind 'io", case.message, broken });
        var completion = try runtime.completionCandidates("sample.");
        defer completion.deinit();
        try std.testing.expectEqual(@as(usize, 0), completion.items().len);
        // Under the qualified-miss auto-load ruling a bare qualified
        // reference loads its module exactly as `import` does, so it reports the
        // same rejection rather than an undefined word.
        try expectErrorContains(&runtime, "sample.increment", &.{ "'kind 'io", case.message });
    }
}

test "native: reflection exposes native origin effects documentation and capabilities" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(
        &runtime,
        "'sample.increment which 'sample.increment see 'sample.increment doc",
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "sample.increment -> sample.increment native public generation 1 (n -- result) requires call, build-values, reschedule",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "<native:sample.increment> requires call build-values\nreschedule",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "requires call, build-values, reschedule") != null);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("\"Increment an integer.\"", display.bytes());
}

test "native: only exact completion mutates the operand stack" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "7");
    try expectErrorContains(
        &runtime,
        "sample.fail-user",
        &.{ "'kind 'user", "sample native failure", "'word 'sample.fail-user" },
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    const author_kinds = [_][]const u8{
        "type", "shape", "conform", "overflow", "domain", "parse", "io", "user",
    };
    for (author_kinds, 0..) |kind, index| {
        var source_buffer: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buffer, "{d}", .{index});
        try expectOk(&runtime, source);
        var expected_buffer: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "'kind '{s}", .{kind});
        try expectErrorContains(&runtime, "sample.fail-kind", &.{ expected, "selected native failure" });
        try std.testing.expectEqual(@as(i64, @intCast(index)), runtime.stackItems()[1].int);
        try expectOk(&runtime, "pop");
    }
    try expectOk(&runtime, "sample.split");
    try std.testing.expectEqual(@as(usize, 2), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try expectOk(&runtime, "sample.singleton");
    try std.testing.expectEqual(@as(usize, 2), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(u64, 1), runtime.stackItems()[1].list.length());
}

test "native: the static transport publishes a linked descriptor through the same path" {
    var host = heap.HostOwner.init(std.testing.allocator);
    var environment = try env.Env.init(&host);
    var registry = try modules.Registry.init(host.cleanup());
    const owner = try native_module.Owner.init(host.cleanup());
    defer {
        const closing = owner.closeCalls();
        registry.deinit();
        // Images clear their Env-owned scope-label cell as they retire, so this
        // drain must finish before the Env releases the cells.
        host.cleanup().drain();
        environment.deinit();
        const settled = closing.settle();
        host.cleanup().drain();
        settled.deinit();
    }
    const requested = try intern.internModuleName("sample");
    var loader = switch (owner.loader().startStatic(requested, native_sample.Extension.descriptor())) {
        .loading => |cursor| cursor,
        .failure => |failure| {
            std.debug.print("unexpected static native load failure: {s}\n", .{failure.text()});
            return error.UnexpectedNativeLoadFailure;
        },
    };
    defer loader.deinit();
    const loaded = while (true) switch (try loader.advance(7)) {
        .pending => {},
        .loaded => |instance| break instance,
        .failure => |failure| {
            std.debug.print("unexpected static native validation failure: {s}\n", .{failure.text()});
            return error.UnexpectedNativeLoadFailure;
        },
    };
    defer loaded.releasePin();
    var publication = try modules.Registry.NativeCandidateCursor.init(&registry, loaded);
    defer publication.deinit();
    var candidate = while (true) switch (try publication.advance()) {
        .pending => {},
        .complete => |candidate| break candidate,
    };
    defer candidate.deinit();
    var candidate_sealed = candidate.seal();
    defer candidate_sealed.deinit();
    _ = try modules.testing.register(&registry, candidate_sealed.ref(), requested);
    var generation = modules.testing.acquire(&registry, requested).?;
    defer generation.deinit();
    const increment = try intern.internNamespace("increment");
    var resolver = generation.resolveCursor(intern.namespaceId(increment));
    defer resolver.deinit();
    var binding = while (true) switch (resolver.advance()) {
        .pending => {},
        .complete => |resolved| break resolved.?,
    };
    defer binding.deinit();
    try std.testing.expect(binding.binding == .native);
    try std.testing.expectEqual(@as(u32, 1), binding.effect.?.inputs);
    try std.testing.expectEqual(@as(u32, 1), binding.effect.?.outputs);
    try std.testing.expectEqual(@as(usize, 3), binding.binding.native.instance.requirements().len);
    const document = env.documentationHeader(binding.doc.?);
    try std.testing.expectEqual(@as(u64, "Increment an integer.".len), document.length());
    for ("Increment an integer.", 0..) |byte, index|
        try std.testing.expectEqual(
            @as(u32, byte),
            list.atUnchecked(.{ .list = document }, index).char,
        );
}

test "native: cooperative slices let another unit progress at one worker" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHostConfig(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = native_fixture.directory,
        },
        .{ .worker_pool = 1 },
    );
    defer runtime.deinit();
    try expectOk(
        &runtime,
        "[] ([] (sample.cooperative) @spawn 'native-task set " ++
            "[] (7) @spawn 'observer set native-task observer pair await-any) @spawn await",
    );
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("{'ok (1 {'ok [7]})}", display.bytes());
}

test "native: aggregate cursors and builders charge the scheduler budget" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "200000 range");
    try expectOk(&runtime, "sample.sum-list");
    try std.testing.expectEqual(@as(i64, 19_999_900_000), runtime.stackItems()[0].int);
    try std.testing.expect(runtime.lastPolls() >= 4);
    try expectOk(
        &runtime,
        "sample.builder-budget 7 sample.singleton {'a 1 'b 2} sample.sum-dict " ++
            "'answer 42 sample.pair-dict",
    );
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(u64, 1), runtime.stackItems()[2].list.length());
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[3].int);
    try std.testing.expectEqual(@as(u64, 1), runtime.stackItems()[4].dict.length());
    try std.testing.expect(runtime.lastPolls() >= 2);
}

test "native: cancellation after a yield preserves the pre-call operand stack" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHostConfig(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = native_fixture.directory,
        },
        .{ .worker_pool = 1 },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "5");
    try expectOk(
        &runtime,
        "[] (9 sample.yield-forever) @spawn dup 1 await-for pop dup cancel await pop",
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 5), runtime.stackItems()[0].int);
}
