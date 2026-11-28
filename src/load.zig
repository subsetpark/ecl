//! Module and source loading: finding the file that declares a qualified
//! module, or its native library or builtin table, running it, and verifying
//! what it registered before the suspended operation resumes.
const std = @import("std");
const value = @import("value.zig");
const heap = @import("heap.zig");
const intern = @import("intern.zig");
const spans = @import("spans.zig");
const env = @import("env.zig");
const modules = @import("modules.zig");
const native_module = @import("native_module.zig");
const native_abi = @import("native-abi");
const reader = @import("reader.zig");
const stdlib = @import("stdlib.zig");
const kernel_storage = @import("kernel_storage.zig");
const module_search = @import("module_search.zig");
const machine = @import("machine.zig");
const module_lookup = @import("module_lookup.zig");
const Value = value.Value;
const Header = value.ListHandle;
const Loading = machine.Loading;
const MachineError = machine.MachineError;
const WorkProgress = machine.WorkProgress;
const ErrorSite = machine.ErrorSite;

/// The semantic operation suspended while an unavailable qualified module is
/// materialized. Direct and dynamically constructed words resume from the
/// word they requested; operand-consuming primitives that still replay their
/// source call restore those operands before selecting `.replay`.
pub const QualifiedLoadContinuation = union(enum) {
    replay,
    /// Dispatch the exact word again by explicit lookup.
    dispatch: struct {
        word: value.Symbol,
        site: ?ErrorSite,
    },
    load_only,
};
pub const QualifiedLoadRequest = struct {
    qualified: u32,
    continuation: QualifiedLoadContinuation,
};
const SourceLoadRequest = union(enum) {
    module: struct { name: intern.ModuleName, operation: QualifiedLoadRequest },
    source,

    pub fn preservesCaller(self: SourceLoadRequest) bool {
        return switch (self) {
            .module => |module| switch (module.operation.continuation) {
                .replay, .dispatch => true,
                .load_only => false,
            },
            .source => false,
        };
    }
};
/// What a registering source's return frame owns until the load is verified:
/// the loading lease, the path its failures report, the operation to resume,
/// what the source may register, and what the unit it interrupted may.
pub const AfterLoad = struct {
    loading: modules.LoadingLease,
    path: Value,
    request: SourceLoadRequest,
    registrant: modules.RegistrationProvenance,
    outer: modules.RegistrationProvenance = .ordinary,

    pub fn deinit(self: AfterLoad, releases: *heap.ReleaseDomain) void {
        var loading = self.loading;
        loading.deinit();
        releases.releaseValue(self.path);
    }
};

/// The Session's published catalog. Only a load that found its file asks,
/// so the catalog is there.
fn catalogOf(fiber: *machine.Fiber) *const module_search.Catalog {
    return fiber.inherited.module_search.?.current().?;
}

/// A completed auto-load registers the module before resuming the tagged
/// qualified operation. The requested spelling also identifies a misspelled
/// export in the final undefined-word error.
pub fn autoLoadModule(via: *Loading, name: intern.ModuleName, request: QualifiedLoadRequest) MachineError!void {
    const fiber = via.fiber();
    try via.startDriver(AutoLoadDriver{
        .request = .{ .module = .{ .name = name, .operation = request } },
        .state = .init(.{ .begin = fiber.inherited.registry.beginLoadingCursor(name, .of(fiber)) }),
    });
}

/// Loads one found source file without resuming any qualified operation.
pub fn loadSource(via: *Loading, source: *const module_search.Source) MachineError!void {
    const fiber = via.fiber();
    try via.startDriver(AutoLoadDriver{
        .request = .source,
        .state = .init(.{ .file_begin = .{
            .file = source,
            .cursor = fiber.inherited.registry.beginArtifactLoadingCursor(source.id(), .of(fiber)),
        } }),
    });
}

/// Parses `source` and pushes its forms as one list. Consumes `source` on
/// success and failure.
pub fn parseSource(via: *Loading, source: []u8) MachineError!void {
    const allocator = via.fiber().allocator;
    const source_name = allocator.dupe(u8, "<parse>") catch |err| {
        allocator.free(source);
        return err;
    };
    try via.startDriver(SourceDriver{
        .text = .init(.{ .owned = .{ .source_name = source_name, .source = source } }),
        .completion = .init(.push),
    });
}

/// Runs borrowed source text as a session's root program.
pub fn sessionSource(via: *Loading, source_name: []const u8, source: []const u8) error{OutOfMemory}!void {
    try via.startDriver(SourceDriver{
        .text = .init(.{ .borrowed = .{ .source_name = source_name, .source = source } }),
        .completion = .init(.session),
    });
}

/// `path @load`: the file runs as a stack-isolated unit on an empty stack.
pub fn loadFile(via: *Loading, path: []u8, path_value: Value, word: intern.TraceWord) MachineError!void {
    return fileTransferOwned(via, path, path_value, .{ .source = .{ .load = .{ .word = word } } });
}

/// Starts verifying what a returned registering source registered. Reports
/// false when there was nothing to verify, which leaves no work installed.
/// Consumes `after`.
pub fn verifyAfterLoad(via: *Loading, after: AfterLoad) MachineError!bool {
    const fiber = via.fiber();
    var lease = after.loading;
    defer lease.deinit();
    var path = heap.OwnedValue.init(fiber.releases, after.path);
    defer path.deinit();
    // The registration check bounds the retry and gives every transport the
    // same post-load handoff.
    const file = after.registrant.foundSource();
    const first_name = if (file) |found| name: {
        const names = found.declared();
        if (names.len == 0) {
            catalogOf(fiber).markLoaded(lease.artifactCommit());
            lease.deinit();
            return false;
        }
        break :name names[0];
    } else after.request.module.name;
    // The lease stays held through verification: a file is recorded loaded
    // only once every module it declares is found registered.
    try via.startDriver(QualifiedRegistrationDriver{
        .path = .init(path.take()),
        .acquisition = .init(fiber.inherited.registry.acquireCursor(first_name)),
        .request = after.request,
        .loading = .init(lease.move()),
        .file = file,
    });
    return true;
}

/// Finds and loads what supplies one module: the registry first, then the
/// embedded library, then the one source file on the search path that
/// declares it, and then the first entry holding `<name>.eclmod`.
const AutoLoadDriver = struct {
    const Disposition = union(enum) {
        source: *const module_search.Source,
        native,
        embedded: stdlib.Entry,
    };
    const State = union(enum) {
        begin: modules.Registry.BeginLoadingCursor,
        registered: struct {
            loading: heap.Owned(modules.LoadingLease),
            cursor: heap.Owned(modules.Registry.AcquireCursor),
        },
        scanning: struct {
            loading: heap.Owned(modules.LoadingLease),
            cursor: heap.Owned(module_search.ScanCursor),
        },
        file_begin: struct {
            file: *const module_search.Source,
            cursor: modules.Registry.BeginLoadingCursor,
        },
        /// The next search-path entry to look in for the native library.
        native_probe: struct {
            loading: heap.Owned(modules.LoadingLease),
            entry: usize,
        },
        committed: heap.Owned(modules.Registry.AcquireCursor),
        /// Between states, holding nothing; also where a source request
        /// whose file was already loaded ends.
        done,
        path_value: struct {
            loading: heap.Owned(modules.LoadingLease),
            candidate: heap.Owned([]u8),
            materializer: heap.Owned(kernel_storage.Utf8Materializer),
            disposition: Disposition,
        },
        transfer: struct {
            loading: heap.Owned(modules.LoadingLease),
            candidate: heap.Owned([]u8),
            path: heap.Owned(Value),
            disposition: Disposition,
        },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .begin => |*cursor| cursor.deinit(),
                .registered => |*registered| {
                    registered.cursor.deinit(releases, storage_allocator);
                    registered.loading.deinit(releases, storage_allocator);
                },
                .scanning => |*scanning| {
                    scanning.cursor.deinit(releases, storage_allocator);
                    scanning.loading.deinit(releases, storage_allocator);
                },
                .file_begin => |*begin| begin.cursor.deinit(),
                .native_probe => |*probe| probe.loading.deinit(releases, storage_allocator),
                .committed => |*cursor| cursor.deinit(releases, storage_allocator),
                .done => {},
                .path_value => |*path| {
                    path.materializer.deinit(releases, storage_allocator);
                    path.candidate.deinit(releases, storage_allocator);
                    path.loading.deinit(releases, storage_allocator);
                },
                .transfer => |*transfer| {
                    transfer.path.deinit(releases, storage_allocator);
                    transfer.candidate.deinit(releases, storage_allocator);
                    transfer.loading.deinit(releases, storage_allocator);
                },
            }
            self.* = undefined;
        }
    };

    request: SourceLoadRequest,
    state: heap.Owned(State),

    /// Materializes `candidate` as the path value the load reports, then
    /// transfers it as `disposition`. Takes `loading` and `candidate`.
    fn beginPath(
        self: *AutoLoadDriver,
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
        candidate: []u8,
        disposition: Disposition,
    ) void {
        const materializer = kernel_storage.Utf8Materializer.init(via.fiber().allocator, candidate);
        // Built apart from the state: `loading` may live in the state this
        // replaces.
        const next: State = .{ .path_value = .{
            .loading = .init(loading.take()),
            .candidate = .init(candidate),
            .materializer = .init(materializer),
            .disposition = disposition,
        } };
        self.state.borrowMut().* = next;
    }
    /// Embedded modules report their provenance name as their path.
    fn beginEmbedded(
        self: *AutoLoadDriver,
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
        entry: stdlib.Entry,
    ) error{OutOfMemory}!void {
        const fiber = via.fiber();
        const provenance = switch (entry) {
            .source => |source| source.name,
            .native, .builtin => intern.get(intern.moduleId(self.request.module.name)),
        };
        self.beginPath(via, loading, try fiber.allocator.dupe(u8, provenance), .{ .embedded = entry });
    }
    /// The module is already registered, so this driver publishes nothing.
    fn finishWithoutLoading(
        self: *AutoLoadDriver,
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
    ) MachineError!WorkProgress {
        loading.borrowMut().deinit();
        return continueSourceRequest(via, self, self.request);
    }
    fn notFound(self: *AutoLoadDriver, via: *Loading) MachineError {
        const fiber = via.fiber();
        return fiber.undefinedWordIn(self.request.module.operation.qualified, .qualified);
    }
    /// Answers the request from a completed catalog: the one file declaring
    /// the module is loaded under its own lease, and a module no source
    /// declares is looked for as a native library.
    fn found(
        self: *AutoLoadDriver,
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
        catalog: *const module_search.Catalog,
    ) MachineError!void {
        const fiber = via.fiber();
        if (catalog.failure) |reason| return fiber.fail(.io, reason);
        const name = self.request.module.name;
        switch (catalog.find(name)) {
            .none => self.state.borrowMut().* = .{ .native_probe = .{ .loading = .init(loading.take()), .entry = 0 } },
            .duplicate => |files| return fiber.failFmt(
                .domain,
                "module `{s}` is declared by both `{s}` and `{s}`",
                .{ intern.get(intern.moduleId(name)), files[0].path(), files[1].path() },
            ),
            .file => |file| {
                loading.borrowMut().deinit();
                self.state.borrowMut().* = .{ .file_begin = .{
                    .file = file,
                    .cursor = fiber.inherited.registry.beginArtifactLoadingCursor(file.id(), .of(fiber)),
                } };
            },
        }
    }
    fn sourceCompletion(
        self: *AutoLoadDriver,
        transfer: *@FieldType(State, "transfer"),
        registrant: modules.RegistrationProvenance,
    ) SourceCompletion {
        return .{ .register = .{
            .loading = transfer.loading.borrowMut().move(),
            .path = transfer.path.take(),
            .request = self.request,
            .registrant = registrant,
        } };
    }
    pub fn advance(via: *Loading, self: *AutoLoadDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        const work = fiber.workBudget();
        while (work.spend()) switch (self.state.borrowMut().*) {
            .begin => |*cursor| switch (try cursor.advance()) {
                .pending => {},
                .complete => |outcome| switch (outcome) {
                    .cycle => return fiber.failFmt(
                        .domain,
                        "recursive auto-load of module `{s}`",
                        .{intern.get(intern.moduleId(self.request.module.name))},
                    ),
                    // Another fiber is loading this name. Wait for it
                    // rather than publishing a second copy; the recheck
                    // below is what makes the winner's work count.
                    .contended => {
                        cursor.deinit();
                        self.state.borrowMut().* = .{ .begin = fiber.inherited.registry.beginLoadingCursor(
                            self.request.module.name,
                            .of(fiber),
                        ) };
                        return .{ .yielded = .wait };
                    },
                    .granted => |lease| {
                        cursor.deinit();
                        self.state.borrowMut().* = .{ .registered = .{
                            .loading = .init(lease),
                            .cursor = .init(fiber.inherited.registry.acquireCursor(self.request.module.name)),
                        } };
                    },
                },
            },
            // A load that raced a winner has nothing left to publish: its
            // tagged operation resumes against the winner's module.
            .registered => |*registered| switch (registered.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |maybe_generation| {
                    var loading = heap.Owned(modules.LoadingLease).init(registered.loading.take());
                    defer loading.deinit(fiber.releases, fiber.allocator);
                    registered.cursor.deinit(fiber.releases, fiber.allocator);
                    if (maybe_generation != null)
                        return self.finishWithoutLoading(via, &loading);
                    // The embedded manifest is consulted before the search
                    // path: a stdlib name resolves without the filesystem,
                    // and no file can shadow one.
                    if (module_lookup.embeddedLibrary(self.request.module.name)) |entry| {
                        try self.beginEmbedded(via, &loading, entry);
                        continue;
                    }
                    const search = fiber.inherited.module_search orelse return self.notFound(via);
                    if (search.current()) |catalog| {
                        try self.found(via, &loading, catalog);
                        continue;
                    }
                    self.state.borrowMut().* = .{ .scanning = .{
                        .loading = .init(loading.take()),
                        .cursor = .init(search.scan()),
                    } };
                },
            },
            .scanning => |*scanning| switch (try scanning.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |built| {
                    var loading = heap.Owned(modules.LoadingLease).init(scanning.loading.take());
                    defer loading.deinit(fiber.releases, fiber.allocator);
                    scanning.cursor.deinit(fiber.releases, fiber.allocator);
                    const catalog = fiber.inherited.module_search.?.publish(built);
                    try self.found(via, &loading, catalog);
                },
            },
            .file_begin => |*begin| switch (try begin.cursor.advance()) {
                .pending => {},
                .complete => |outcome| switch (outcome) {
                    .cycle => return fiber.failFmt(
                        .domain,
                        "recursive auto-load of `{s}`",
                        .{begin.file.path()},
                    ),
                    .contended => {
                        const file = begin.file;
                        begin.cursor.deinit();
                        self.state.borrowMut().* = .{ .file_begin = .{
                            .file = file,
                            .cursor = fiber.inherited.registry.beginArtifactLoadingCursor(file.id(), .of(fiber)),
                        } };
                        return .{ .yielded = .wait };
                    },
                    .granted => |lease| {
                        const file = begin.file;
                        begin.cursor.deinit();
                        self.state.borrowMut().* = .done;
                        var loading = heap.Owned(modules.LoadingLease).init(lease);
                        defer loading.deinit(fiber.releases, fiber.allocator);
                        if (file.loaded()) {
                            loading.borrowMut().deinit();
                            if (self.request == .source) return .completed;
                            self.state.borrowMut().* = .{ .committed = .init(fiber.inherited.registry.acquireCursor(self.request.module.name)) };
                            continue;
                        }
                        const candidate = try fiber.allocator.dupe(u8, file.path());
                        self.beginPath(via, &loading, candidate, .{ .source = file });
                    },
                },
            },
            .native_probe => |*probe| {
                const entries = fiber.inherited.module_search.?.entries;
                if (probe.entry == entries.len) return self.notFound(via);
                const filename = try std.mem.concat(fiber.allocator, u8, &.{ intern.get(intern.moduleId(self.request.module.name)), ".eclmod" });
                defer fiber.allocator.free(filename);
                const candidate = try std.fs.path.join(fiber.allocator, &.{ entries[probe.entry], filename });
                std.Io.Dir.cwd().access(fiber.inherited.runtime().host_io, candidate, .{ .read = true }) catch |err| {
                    defer fiber.allocator.free(candidate);
                    switch (err) {
                        // An entry that cannot be searched supplies nothing,
                        // as in the scan.
                        error.FileNotFound, error.AccessDenied, error.PermissionDenied => {
                            probe.entry += 1;
                            continue;
                        },
                        else => return fiber.failFmt(.io, "cannot access module file `{s}`: {s}", .{ candidate, @errorName(err) }),
                    }
                };
                self.beginPath(via, &probe.loading, candidate, .native);
            },
            .done => unreachable,
            .committed => |*cursor| switch (cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |maybe_generation| {
                    cursor.deinit(fiber.releases, fiber.allocator);
                    if (maybe_generation == null) return fiber.failFmt(
                        .io,
                        "a loaded file is missing module `{s}`",
                        .{intern.get(intern.moduleId(self.request.module.name))},
                    );
                    return continueSourceRequest(via, self, self.request);
                },
            },
            .path_value => |*path| switch (path.materializer.borrowMut().advance(work) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return fiber.fail(.io, "module path is not valid UTF-8"),
            }) {
                .pending => {},
                .complete => |path_value| {
                    path.materializer.deinit(fiber.releases, fiber.allocator);
                    const next = @FieldType(State, "transfer"){
                        .loading = .init(path.loading.take()),
                        .candidate = .init(path.candidate.take()),
                        .path = .init(path_value),
                        .disposition = path.disposition,
                    };
                    self.state.borrowMut().* = .{ .transfer = next };
                },
            },
            .transfer => |*transfer| switch (transfer.disposition) {
                .embedded => |entry| return self.transferEmbedded(via, transfer, entry),
                .native => return self.transferNative(via, transfer),
                .source => |file| {
                    const candidate = transfer.candidate.take();
                    const completion = self.sourceCompletion(transfer, .source(file));
                    fiber.retireDriver(self);
                    try fileSourceOwned(via, candidate, null, completion);
                    return .detached;
                },
            },
        };
        return .stepped;
    }
    /// The manifest owns constant bytes, and `sourceOwned` frees what it
    /// is given, so the text is duped for the reader to consume. A linked
    /// descriptor needs no transport at all: `startStatic` publishes it
    /// through the same validate/publish/commit phases as a dynamic
    /// image, with a no-op image pin.
    fn transferEmbedded(
        self: *AutoLoadDriver,
        via: *Loading,
        transfer: *@FieldType(State, "transfer"),
        entry: stdlib.Entry,
    ) MachineError!WorkProgress {
        const fiber = via.fiber();
        const text = switch (entry) {
            .source => |source| try fiber.allocator.dupe(u8, source.text),
            .native => |descriptor| return self.transferStatic(via, transfer, descriptor),
            .builtin => |module| return self.transferBuiltin(via, transfer, module),
        };
        const source_name = transfer.candidate.take();
        const completion = self.sourceCompletion(transfer, .standard_library);
        fiber.retireDriver(self);
        try sourceOwned(via, source_name, text, completion);
        return .detached;
    }
    fn transferBuiltin(
        self: *AutoLoadDriver,
        via: *Loading,
        transfer: *@FieldType(State, "transfer"),
        module: env.BuiltinModule,
    ) MachineError!WorkProgress {
        const fiber = via.fiber();
        // The candidate is created before ownership moves: struct-literal
        // fields evaluate in order, so a failure here would otherwise
        // strand the lease and path this driver had already taken.
        const publication = try modules.Registry.BuiltinCandidateCursor.init(
            fiber.inherited.registry,
            try fiber.environment.moduleScope(self.request.module.name),
            .standard_library,
            module,
        );
        // No errdefer: from here nothing fails until `startDriver`, which
        // disposes the whole uninstalled driver's owned fields itself.
        const next = BuiltinLoadDriver{
            .name = self.request.module.name,
            .request = self.request.module.operation,
            .loading = .init(transfer.loading.take()),
            .path = .init(transfer.path.take()),
            .publication = .init(publication),
        };
        fiber.retireDriver(self);
        try via.startDriver(next);
        return .detached;
    }
    fn transferStatic(
        self: *AutoLoadDriver,
        via: *Loading,
        transfer: *@FieldType(State, "transfer"),
        descriptor: *const native_abi.Descriptor,
    ) MachineError!WorkProgress {
        const fiber = via.fiber();
        const loader_authority = fiber.inherited.runtime().native_loader;
        const loader = switch (loader_authority.startStatic(self.request.module.name, descriptor)) {
            .failure => |failure| {
                const failed = fiber.fail(.io, failure.text());
                fiber.addErrorPath(transfer.path.borrow());
                return failed;
            },
            .loading => |loading| loading,
        };
        const next = NativeLoadDriver{
            .name = self.request.module.name,
            .request = self.request.module.operation,
            .provenance = .standard_library,
            .loading = .init(transfer.loading.take()),
            .path = .init(transfer.path.take()),
            .state = .init(.{ .validate = .init(loader) }),
        };
        fiber.retireDriver(self);
        try via.startDriver(next);
        return .detached;
    }
    fn transferNative(
        self: *AutoLoadDriver,
        via: *Loading,
        transfer: *@FieldType(State, "transfer"),
    ) MachineError!WorkProgress {
        const fiber = via.fiber();
        const loader_authority = fiber.inherited.runtime().native_loader;
        const start = try loader_authority.startDynamic(
            self.request.module.name,
            transfer.candidate.borrow(),
        );
        const loader = switch (start) {
            .failure => |failure| {
                const failed = fiber.fail(.io, failure.text());
                fiber.addErrorPath(transfer.path.borrow());
                return failed;
            },
            .loading => |loading| loading,
        };
        const next = NativeLoadDriver{
            .name = self.request.module.name,
            .request = self.request.module.operation,
            .provenance = .ordinary,
            .loading = .init(transfer.loading.take()),
            .path = .init(transfer.path.take()),
            .state = .init(.{ .validate = .init(loader) }),
        };
        fiber.retireDriver(self);
        try via.startDriver(next);
        return .detached;
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
/// Publishes a builtin-backed module through the same candidate/commit
/// protocol as a native one; only the definition source differs.
const BuiltinLoadDriver = struct {
    name: intern.ModuleName,
    request: QualifiedLoadRequest,
    loading: heap.Owned(modules.LoadingLease),
    path: heap.Owned(Value),
    publication: heap.Owned(modules.Registry.BuiltinCandidateCursor),
    commit: ?heap.Owned(modules.Registry.RegistrationCursor) = null,

    pub fn advance(via: *Loading, self: *BuiltinLoadDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        if (self.commit == null) {
            switch (self.publication.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidName => return fiber.fail(
                    .contract,
                    "builtin module declares an invalid word name",
                ),
            }) {
                .pending => return .stepped,
                .complete => |candidate| {
                    var built = candidate;
                    defer built.deinit();
                    const sealed = built.sealLiteralGroup() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Duplicate => return fiber.fail(
                            .contract,
                            "builtin module declares an invalid word",
                        ),
                    };
                    self.commit = .init(fiber.inherited.registry.registrationCursor(sealed));
                    return .stepped;
                },
            }
        }
        switch (self.commit.?.borrowMut().advance() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fiber.failFmt(
                .io,
                "cannot publish builtin module `{s}`: {s}",
                .{ intern.get(intern.moduleId(self.name)), @errorName(err) },
            ),
        }) {
            .pending => return .stepped,
            .complete => {},
        }
        self.commit.?.deinit(fiber.releases, fiber.allocator);
        self.commit = null;
        return verifyPublishedModule(
            via,
            self,
            self.name,
            &self.loading,
            &self.path,
            self.request,
        );
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
const NativeLoadDriver = struct {
    name: intern.ModuleName,
    request: QualifiedLoadRequest,
    provenance: modules.RegistrationProvenance,
    loading: heap.Owned(modules.LoadingLease),
    path: heap.Owned(Value),
    state: heap.Owned(State),

    const State = union(enum) {
        validate: heap.Owned(native_module.LoadCursor),
        loaded: heap.Owned(*native_module.ModuleInstance),
        definitions: struct {
            instance: heap.Owned(*native_module.ModuleInstance),
            publication: heap.Owned(modules.Registry.NativeCandidateCursor),
        },
        commit: struct {
            instance: heap.Owned(*native_module.ModuleInstance),
            cursor: heap.Owned(modules.Registry.RegistrationCursor),
        },
        published: struct {
            instance: heap.Owned(*native_module.ModuleInstance),
        },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .validate => |*loader| loader.deinit(releases, storage_allocator),
                .loaded => |*instance| instance.deinit(releases, storage_allocator),
                .definitions => |*definitions| {
                    definitions.publication.deinit(releases, storage_allocator);
                    definitions.instance.deinit(releases, storage_allocator);
                },
                .commit => |*commit| {
                    commit.cursor.deinit(releases, storage_allocator);
                    commit.instance.deinit(releases, storage_allocator);
                },
                .published => |*published| published.instance.deinit(releases, storage_allocator),
            }
            self.* = undefined;
        }
    };

    fn failLoad(self: *NativeLoadDriver, via: *Loading, message: []const u8) MachineError {
        const fiber = via.fiber();
        const failure = fiber.fail(.io, message);
        fiber.addErrorPath(self.path.borrow());
        return failure;
    }

    pub fn advance(via: *Loading, self: *NativeLoadDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        switch (self.state.borrowMut().*) {
            .validate => |*loader| switch (try loader.borrowMut().advance(fiber.workBudget())) {
                .pending => return .stepped,
                .failure => |failure| return self.failLoad(via, failure.text()),
                .loaded => |instance| {
                    loader.deinit(fiber.releases, fiber.allocator);
                    self.state.borrowMut().* = .{ .loaded = .init(instance) };
                    return .stepped;
                },
            },
            .loaded => |*instance| {
                const publication = try modules.Registry.NativeCandidateCursor.init(
                    fiber.inherited.registry,
                    try fiber.environment.moduleScope(self.name),
                    self.provenance,
                    instance.borrow(),
                );
                self.state.borrowMut().* = .{ .definitions = .{
                    .instance = .init(instance.take()),
                    .publication = .init(publication),
                } };
                return .stepped;
            },
            .definitions => |*definitions| switch (try definitions.publication.borrowMut().advance()) {
                .pending => return .stepped,
                .complete => |candidate| {
                    // Sealing can fail; until it succeeds the instance and
                    // the publication stay with this driver's state.
                    var built = candidate;
                    defer built.deinit();
                    const sealed = built.sealLiteralGroup() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Duplicate => return self.failLoad(via, "native module declares an invalid word"),
                    };
                    // Shadowing in a shipped module is deliberate.
                    if (self.provenance != .standard_library) {
                        var names = sealed.entries();
                        while (true) switch (names.advance()) {
                            .pending => {},
                            .item => |entry| fiber.warnCoreShadowing(entry.key, sealed.moduleName()),
                            .complete => break,
                        };
                    }
                    const instance = definitions.instance.take();
                    definitions.publication.deinit(
                        fiber.releases,
                        fiber.allocator,
                    );
                    const cursor = fiber.inherited.registry.registrationCursor(sealed);
                    self.state.borrowMut().* = .{ .commit = .{
                        .instance = .init(instance),
                        .cursor = .init(cursor),
                    } };
                    return .stepped;
                },
            },
            .commit => |*commit| switch (commit.cursor.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fiber.failFmt(
                    .io,
                    "cannot publish native module `{s}`: {s}",
                    .{ intern.get(intern.moduleId(self.name)), @errorName(err) },
                ),
            }) {
                .pending => return .stepped,
                .complete => {
                    const next: State = .{ .published = .{
                        .instance = commit.instance,
                    } };
                    var cursor = commit.cursor;
                    self.state.borrowMut().* = next;
                    cursor.deinit(fiber.releases, fiber.allocator);
                    return verifyPublishedModule(
                        via,
                        self,
                        self.name,
                        &self.loading,
                        &self.path,
                        self.request,
                    );
                },
            },
            .published => unreachable,
        }
    }

    pub const ownership: heap.DriverOwnership = .fields;
};
const SourceCompletion = union(enum) {
    /// `parse`: the forms are pushed as data.
    push,
    session,
    /// `@load`: the source runs as a stack-isolated unit on an empty stack.
    load: struct { word: intern.TraceWord },
    /// Registration only: the source runs, then the loading lease and
    /// tagged qualified operation transfer to the return frame.
    register: struct {
        loading: ?modules.LoadingLease,
        path: ?Value,
        request: SourceLoadRequest,
        registrant: modules.RegistrationProvenance,
    },

    pub fn deinit(self: *SourceCompletion, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .push, .session, .load => {},
            .register => |*register| {
                if (register.loading) |*loading| loading.deinit();
                if (register.path) |path| releases.releaseValue(path);
            },
        }
        self.* = undefined;
    }
};
const SourceText = union(enum) {
    borrowed: struct { source_name: []const u8, source: []const u8 },
    owned: struct { source_name: []u8, source: []u8 },

    fn sourceName(self: SourceText) []const u8 {
        return switch (self) {
            .borrowed => |text| text.source_name,
            .owned => |text| text.source_name,
        };
    }
    fn source(self: SourceText) []const u8 {
        return switch (self) {
            .borrowed => |text| text.source,
            .owned => |text| text.source,
        };
    }
    pub fn deinit(self: *SourceText, storage_allocator: std.mem.Allocator) void {
        switch (self.*) {
            .borrowed => {},
            .owned => |text| {
                storage_allocator.free(text.source);
                storage_allocator.free(text.source_name);
            },
        }
        self.* = undefined;
    }
};
fn sourceOwned(
    via: *Loading,
    source_name: []u8,
    source: []u8,
    completion: SourceCompletion,
) error{OutOfMemory}!void {
    try via.startDriver(SourceDriver{
        .text = .init(.{ .owned = .{ .source_name = source_name, .source = source } }),
        .completion = .init(completion),
    });
}
const SourceDriver = struct {
    const State = union(enum) {
        start,
        ingesting: spans.SpanArchive.SourceIngestCursor,
        activating: *Header,
        storage,
    };

    retirement: heap.ReleaseDomain.Retirement = .{},
    text: heap.Owned(SourceText),
    completion: heap.Owned(SourceCompletion),
    diag: reader.Diag = .{},
    state: State = .start,

    /// An embedded module's top-level words mean core's, as the prelude's do,
    /// so no session definition can change what it registers. Any other
    /// source links in the root of the fiber that loads it.
    fn linkScope(self: *SourceDriver, fiber: *machine.Fiber) env.ScopeId {
        switch (self.completion.borrow()) {
            .register => |register| if (register.registrant == .standard_library)
                return fiber.environment.coreScopeId(),
            .push, .session, .load => {},
        }
        return fiber.lexicalScope();
    }

    fn beginIngest(self: *SourceDriver, via: *Loading) error{OutOfMemory}!void {
        const fiber = via.fiber();
        const ingestion = try fiber.archive.sourceIngestCursor(
            self.text.borrow().sourceName(),
            self.text.borrow().source(),
            &self.diag,
            fiber.rootLinker(self.linkScope(fiber)),
        );
        self.state = .{ .ingesting = ingestion };
    }

    /// Activates a source that fits its first slice before observing cancellation.
    pub const cancellation: machine.DriverCancellation = .own;

    pub fn advance(via: *Loading, self: *SourceDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        // Preserve the established pre-cancelled-fiber behavior for a
        // source that fits in its first bounded slice: activate it first,
        // so evaluation can attach cancellation to the responsible word.
        // A source that needs another slice observes cancellation before
        // doing any more ingestion work.
        if (self.state != .start) try fiber.pollKernel();
        const work = fiber.workBudget();
        while (work.spend()) switch (self.state) {
            .start => try self.beginIngest(via),
            .ingesting => |*ingestion| {
                switch (ingestion.advance(work) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Parse => return via.failAtSource(
                        self.diag.text(),
                        self.text.borrow().sourceName(),
                        self.diag.span,
                    ),
                    error.InvalidProvenance => @panic("archive-bound source reader produced foreign provenance"),
                }) {
                    .pending => {},
                    .complete => |result| switch (result) {
                        .complete => |root_header| self.state = .{ .activating = root_header },
                        .incomplete => |value_incomplete| switch (self.completion.borrowMut().*) {
                            .session => {
                                via.finishIncomplete(value_incomplete);
                                return .completed;
                            },
                            else => return via.failAtSource(
                                value_incomplete.message,
                                self.text.borrow().sourceName(),
                                value_incomplete.span,
                            ),
                        },
                    },
                }
            },
            .activating => |root_header| {
                switch (self.completion.borrowMut().*) {
                    .push => try fiber.pushBorrowed(.{ .list = root_header }),
                    .load => |load| {
                        heap.incRef(root_header);
                        try via.openLoad(root_header, load.word);
                    },
                    .session => {
                        heap.incRef(root_header);
                        try fiber.callProgramOwned(root_header, .owned);
                    },
                    .register => |*register| {
                        heap.incRef(root_header);
                        const after = AfterLoad{
                            .loading = register.loading.?.move(),
                            .path = register.path.?,
                            .request = register.request,
                            .registrant = register.registrant,
                        };
                        register.loading = null;
                        register.path = null;
                        try via.enterRegistration(root_header, after);
                    },
                }
                return .completed;
            },
            .storage => unreachable,
        };
        return .stepped;
    }
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        storage_allocator: std.mem.Allocator,
        self: *SourceDriver,
    ) bool {
        return switch (self.state) {
            .start, .activating => result: {
                self.state = .storage;
                break :result false;
            },
            .ingesting => |*ingestion| result: {
                if (!ingestion.advanceRetirement()) break :result false;
                self.state = .storage;
                break :result false;
            },
            .storage => {
                self.completion.deinit(releases, storage_allocator);
                self.text.deinit(releases, storage_allocator);
                storage_allocator.destroy(self);
                return true;
            },
        };
    }
    pub const ownership: heap.DriverOwnership = .bounded_retirement;
};
fn fileSourceOwned(
    via: *Loading,
    path: []u8,
    path_value: ?Value,
    completion: SourceCompletion,
) MachineError!void {
    return fileTransferOwned(via, path, path_value, .{ .source = completion });
}
fn fileTransferOwned(
    via: *Loading,
    path: []u8,
    path_value: ?Value,
    transfer: FileTransfer,
) MachineError!void {
    try via.startDriver(FileSourceDriver{
        .allocator = via.fiber().allocator,
        .state = .init(.{ .open = .{
            .path = .init(path),
            .path_value = if (path_value) |item| .init(item) else null,
            .transfer = .init(transfer),
        } }),
    });
}
/// What one read file's bytes become. Module loading is the only client
/// of this trusted host read; caller-selected file access goes through the
/// capability-gated `fs` module instead.
const FileTransfer = union(enum) {
    /// Hand the bytes to the reader as source text.
    source: SourceCompletion,

    pub fn deinit(self: *FileTransfer, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .source => |*completion| completion.deinit(releases),
        }
        self.* = undefined;
    }
    fn diagnosticPath(self: FileTransfer) ?Value {
        return switch (self) {
            .source => |completion| switch (completion) {
                .register => |register| register.path,
                .push, .session, .load => null,
            },
        };
    }
};
const OpenFile = struct {
    io: std.Io,
    file: std.Io.File,

    pub fn deinit(self: *OpenFile) void {
        self.file.close(self.io);
    }
};
const FileSourceDriver = struct {
    const Context = struct {
        path: heap.Owned([]u8),
        path_value: ?heap.Owned(Value),
        transfer: heap.Owned(FileTransfer),

        fn move(self: *Context) Context {
            return .{
                .path = .init(self.path.take()),
                .path_value = if (self.path_value) |*item| .init(item.take()) else null,
                .transfer = .init(self.transfer.take()),
            };
        }
        fn deinit(
            self: *Context,
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
        ) void {
            self.transfer.deinit(releases, storage_allocator);
            if (self.path_value) |*item| item.deinit(releases, storage_allocator);
            self.path.deinit(releases, storage_allocator);
        }
    };
    const State = union(enum) {
        open: Context,
        size: struct { context: Context, file: heap.Owned(OpenFile) },
        read: struct {
            context: Context,
            file: heap.Owned(OpenFile),
            reader: std.Io.File.Reader,
            source: heap.Owned([]u8),
            offset: usize,
        },
        transfer: struct { context: Context, source: heap.Owned([]u8) },
        complete: struct { context: Context, source: heap.Owned([]u8) },

        pub fn deinit(
            self: *State,
            releases: *heap.ReleaseDomain,
            storage_allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .open => |*context| context.deinit(releases, storage_allocator),
                .size => |*size| {
                    size.file.deinit(releases, storage_allocator);
                    size.context.deinit(releases, storage_allocator);
                },
                .read => |*read| {
                    read.source.deinit(releases, storage_allocator);
                    read.file.deinit(releases, storage_allocator);
                    read.context.deinit(releases, storage_allocator);
                },
                .transfer => |*transfer| {
                    transfer.source.deinit(releases, storage_allocator);
                    transfer.context.deinit(releases, storage_allocator);
                },
                .complete => |*transfer| {
                    transfer.source.deinit(releases, storage_allocator);
                    transfer.context.deinit(releases, storage_allocator);
                },
            }
        }
    };

    allocator: std.mem.Allocator,
    state: heap.Owned(State),

    fn diagnosticPath(context: *Context) ?Value {
        if (context.path_value) |*item| return item.borrow();
        return context.transfer.borrow().diagnosticPath();
    }
    fn failIo(context: *Context, via: *Loading, message: []const u8) MachineError {
        const fiber = via.fiber();
        const failure = fiber.fail(.io, message);
        if (diagnosticPath(context)) |item| fiber.addErrorPath(item);
        return failure;
    }
    pub fn advance(via: *Loading, self: *FileSourceDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        const io = fiber.inherited.runtime().host_io;
        switch (self.state.borrowMut().*) {
            .open => |*context| {
                const file = std.Io.Dir.cwd().openFile(io, context.path.borrow(), .{}) catch |err| {
                    const failure = fiber.failFmt(
                        .io,
                        "cannot read `{s}`: {s}",
                        .{ context.path.borrow(), @errorName(err) },
                    );
                    if (diagnosticPath(context)) |item| fiber.addErrorPath(item);
                    return failure;
                };
                self.state.borrowMut().* = .{ .size = .{
                    .context = context.move(),
                    .file = .init(.{ .io = io, .file = file }),
                } };
                return .stepped;
            },
            .size => |*size| {
                const opened = size.file.borrow();
                const stat = opened.file.stat(opened.io) catch |err| {
                    const failure = fiber.failFmt(
                        .io,
                        "cannot read `{s}`: {s}",
                        .{ size.context.path.borrow(), @errorName(err) },
                    );
                    if (diagnosticPath(&size.context)) |item| fiber.addErrorPath(item);
                    return failure;
                };
                if (stat.size > std.math.maxInt(usize))
                    return failIo(&size.context, fiber, "source file is too large");
                const source = try self.allocator.alloc(u8, @intCast(stat.size));
                const file_reader = opened.file.reader(opened.io, &.{});
                self.state.borrowMut().* = .{ .read = .{
                    .context = size.context.move(),
                    .file = .init(size.file.take()),
                    .reader = file_reader,
                    .source = .init(source),
                    .offset = 0,
                } };
                return .stepped;
            },
            .read => |*read| {
                if (read.offset != read.source.borrow().len) {
                    const end = read.offset + fiber.workBudget().take(read.source.borrow().len - read.offset);
                    const amount = read.reader.interface.readSliceShort(
                        read.source.borrow()[read.offset..end],
                    ) catch {
                        const name = if (read.reader.err) |err| @errorName(err) else "ReadFailed";
                        const failure = fiber.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ read.context.path.borrow(), name },
                        );
                        if (diagnosticPath(&read.context)) |item| fiber.addErrorPath(item);
                        return failure;
                    };
                    if (amount == 0) return failIo(
                        &read.context,
                        via,
                        "source file changed while being read",
                    );
                    read.offset += amount;
                    return .stepped;
                }
                const context = read.context.move();
                const source = read.source.take();
                read.file.deinit(fiber.releases, fiber.allocator);
                self.state.borrowMut().* = .{ .transfer = .{
                    .context = context,
                    .source = .init(source),
                } };
                return .stepped;
            },
            .transfer => |*transfer| {
                const path = transfer.context.path.take();
                const source = transfer.source.take();
                const completion = transfer.context.transfer.take().source;
                fiber.retireDriver(self);
                try sourceOwned(via, path, source, completion);
                return .detached;
            },
            .complete => unreachable,
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
/// After an auto-load, the requested module must actually be registered.
/// Checking that is what bounds the operation: a source that registered
/// nothing, or a different name, fails once here instead of starting another
/// load when its tagged continuation resumes.
fn continueSourceRequest(via: *Loading, driver: anytype, request: SourceLoadRequest) MachineError!WorkProgress {
    return switch (request) {
        .source => .completed,
        .module => |module| continueQualifiedRequest(via, driver, module.operation),
    };
}

fn continueQualifiedRequest(
    via: *Loading,
    driver: anytype,
    request: QualifiedLoadRequest,
) MachineError!WorkProgress {
    const fiber = via.fiber();
    return switch (request.continuation) {
        .replay, .load_only => .completed,
        .dispatch => |dispatch_request| continuation: {
            fiber.retireDriver(driver);
            try via.dispatchAfterLoad(dispatch_request.word, dispatch_request.site);
            break :continuation .detached;
        },
    };
}

fn verifyPublishedModule(
    via: *Loading,
    driver: anytype,
    name: intern.ModuleName,
    loading: *heap.Owned(modules.LoadingLease),
    path: *heap.Owned(Value),
    request: QualifiedLoadRequest,
) MachineError!WorkProgress {
    const fiber = via.fiber();
    loading.borrowMut().deinit();
    const registry = fiber.inherited.registry;
    const next = QualifiedRegistrationDriver{
        .path = .init(path.take()),
        .acquisition = .init(registry.acquireCursor(name)),
        .request = .{ .module = .{ .name = name, .operation = request } },
    };
    fiber.retireDriver(driver);
    try via.startDriver(next);
    return .detached;
}

/// Verifies that a completed load registered every module it was expected
/// to before releasing its lease. A found file is recorded loaded only after
/// that.
const QualifiedRegistrationDriver = struct {
    path: heap.Owned(Value),
    acquisition: heap.Owned(modules.Registry.AcquireCursor),
    request: SourceLoadRequest,
    loading: ?heap.Owned(modules.LoadingLease) = null,
    file: ?*const module_search.Source = null,
    module_index: usize = 0,

    pub fn advance(via: *Loading, self: *QualifiedRegistrationDriver) MachineError!WorkProgress {
        const fiber = via.fiber();
        switch (self.acquisition.borrowMut().advance()) {
            .pending => return .stepped,
            .complete => |maybe_generation| {
                const checked_name = if (self.file) |file|
                    file.declared()[self.module_index]
                else
                    self.request.module.name;
                if (maybe_generation == null) {
                    const failure = if (self.file) |file|
                        fiber.failFmt(
                            .io,
                            "loading `{s}` registered nothing under its declared module `{s}`",
                            .{ file.path(), intern.get(intern.moduleId(checked_name)) },
                        )
                    else
                        fiber.failFmt(
                            .io,
                            "loading module `{s}` registered nothing under that name",
                            .{intern.get(intern.moduleId(checked_name))},
                        );
                    fiber.addErrorPath(self.path.borrow());
                    return failure;
                }
                if (self.file) |file| {
                    self.module_index += 1;
                    if (self.module_index != file.declared().len) {
                        self.acquisition.deinit(fiber.releases, fiber.allocator);
                        self.acquisition = .init(fiber.inherited.registry.acquireCursor(
                            file.declared()[self.module_index],
                        ));
                        return .stepped;
                    }
                }
                return self.complete(via);
            },
        }
    }

    fn complete(self: *QualifiedRegistrationDriver, via: *Loading) MachineError!WorkProgress {
        const fiber = via.fiber();
        if (self.loading) |*owned| {
            const lease = owned.borrowMut();
            if (self.file != null)
                catalogOf(fiber).markLoaded(lease.artifactCommit());
            lease.deinit();
        }
        return continueSourceRequest(via, self, self.request);
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
