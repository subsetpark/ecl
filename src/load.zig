//! Module and source loading: finding a qualified module's source, native
//! library, or builtin table, running it, and verifying what it registered
//! before the suspended operation resumes.
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
const map_state = @import("module_snapshot.zig");
const machine = @import("machine.zig");
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
        trace_parent: ?intern.TraceWord,
    },
    load_only,
};
pub const QualifiedLoadRequest = struct {
    context: modules.RegistrationProvenance,
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
const ArtifactLoad = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    fn init(maybe_artifact: ?map_state.ArtifactId) ArtifactLoad {
        return if (maybe_artifact) |id| @fromBackingInt(@intCast(@backingInt(id))) else .none;
    }
    fn artifact(self: ArtifactLoad) ?map_state.ArtifactId {
        return if (self == .none) null else @fromBackingInt(@intCast(@backingInt(self)));
    }
};
/// What a registering source's return frame owns until the load is verified:
/// the loading lease, the path its failures report, and the operation to
/// resume.
pub const AfterLoad = struct {
    loading: modules.LoadingLease,
    path: Value,
    request: SourceLoadRequest,
    artifact: ArtifactLoad,

    pub fn deinit(self: AfterLoad, releases: *heap.ReleaseDomain) void {
        var loading = self.loading;
        loading.deinit();
        releases.releaseValue(self.path);
    }
};

/// A completed auto-load registers the module before resuming the tagged
/// qualified operation. The requested spelling also identifies a misspelled
/// export in the final undefined-word error.
pub fn autoLoadModule(via: *Loading, name: intern.ModuleName, request: QualifiedLoadRequest) MachineError!void {
    const evaluator = via.fiber();
    try via.startDriver(AutoLoadDriver{
        .request = .{ .module = .{ .name = name, .operation = request } },
        .state = .init(.{ .begin = evaluator.inherited.registry.beginLoadingCursor(name, .of(evaluator)) }),
    });
}

/// Loads one mapped source artifact without resuming any qualified operation.
pub fn loadSource(via: *Loading, source: *const map_state.SourceScope) MachineError!void {
    const evaluator = via.fiber();
    const location = source.location();
    try via.startDriver(AutoLoadDriver{
        .request = .source,
        .state = .init(.{ .artifact_begin = .{
            .target = .{
                .scope_name = location.scope_name,
                .root = location.root,
                .relative_path = location.relative_path,
                .scope_id = location.scope_id,
                .artifact_id = location.artifact_id,
                .kind = location.kind,
            },
            .cursor = evaluator.inherited.registry.beginArtifactLoadingCursor(location.artifact_id, .of(evaluator)),
        } }),
    });
}

/// Interns a qualified miss's unknown module prefix, then loads that module.
pub fn prepareQualified(
    via: *Loading,
    prefix: []const u8,
    request: QualifiedLoadRequest,
    restore: QualifiedLoadPreparationDriver.Restore,
) error{OutOfMemory}!void {
    return via.startDriver(QualifiedLoadPreparationDriver.init(prefix, request, restore));
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
        .completion = .init(.{ .session = null }),
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
    const evaluator = via.fiber();
    var lease = after.loading;
    defer lease.deinit();
    var path = heap.OwnedValue.init(evaluator.releases, after.path);
    defer path.deinit();
    // The registration check bounds the retry and gives every transport the
    // same post-load handoff.
    const artifact = after.artifact.artifact();
    const first_name = if (artifact) |artifact_id| name: {
        const names = evaluator.inherited.module_snapshot.?.artifactModules(artifact_id);
        if (names.len == 0) {
            evaluator.inherited.module_snapshot.?.commitArtifact(lease.artifactCommit());
            lease.finish();
            return false;
        }
        break :name names[0];
    } else after.request.module.name;
    // The lease stays held through verification: imports deferred onto this
    // load are checked before it releases.
    try via.startDriver(QualifiedRegistrationDriver{
        .path = .init(path.take()),
        .acquisition = .init(evaluator.inherited.registry.acquireCursor(first_name)),
        .request = after.request,
        .loading = .init(lease.move()),
        .artifact = artifact,
    });
    return true;
}

const AutoLoadDriver = struct {
    const FileKind = enum { source, native };
    const CandidateOrigin = union(enum) {
        search_path: struct {
            component_start: usize,
            component_end: usize,
            next_search: usize,
        },
        mapped: struct {
            scope_name: []const u8,
            root: []const u8,
            scope_id: map_state.ScopeId,
            artifact_id: map_state.ArtifactId,
        },
    };
    const FilenameTarget = union(enum) {
        component_start: usize,
        candidate: CandidateOrigin,
    };
    const FilenameState = struct {
        loading: heap.Owned(modules.LoadingLease),
        filename: heap.Owned([]u8),
        index: usize = 0,
        kind: FileKind,
        target: FilenameTarget,
    };
    const CandidateState = struct {
        loading: heap.Owned(modules.LoadingLease),
        filename: heap.Owned([]u8),
        kind: FileKind,
        origin: CandidateOrigin,
        candidate: heap.Owned([]u8),
        index: usize = 0,
        separator: bool,
    };
    const Disposition = union(enum) {
        source: struct {
            provenance: modules.RegistrationProvenance,
            artifact: ?map_state.ArtifactId,
        },
        native: ?map_state.ArtifactId,
        embedded: stdlib.Entry,
        fail: []const u8,
    };
    const MappedTarget = struct {
        scope_name: []const u8,
        root: []const u8,
        relative_path: []const u8,
        scope_id: map_state.ScopeId,
        artifact_id: map_state.ArtifactId,
        kind: @import("module_map.zig").Kind,
    };
    const State = union(enum) {
        begin: modules.Registry.BeginLoadingCursor,
        registered: struct {
            loading: heap.Owned(modules.LoadingLease),
            cursor: heap.Owned(modules.Registry.AcquireCursor),
        },
        map_lookup: struct {
            loading: heap.Owned(modules.LoadingLease),
            cursor: heap.Owned(map_state.LookupCursor),
        },
        artifact_begin: struct {
            target: MappedTarget,
            cursor: modules.Registry.BeginLoadingCursor,
        },
        committed: heap.Owned(modules.Registry.AcquireCursor),
        mapped_root: struct {
            loading: heap.Owned(modules.LoadingLease),
            target: MappedTarget,
        },
        filename: FilenameState,
        component_start: struct {
            loading: heap.Owned(modules.LoadingLease),
            filename: heap.Owned([]u8),
            kind: FileKind,
            search_index: usize,
        },
        component_end: struct {
            loading: heap.Owned(modules.LoadingLease),
            filename: heap.Owned([]u8),
            kind: FileKind,
            search_index: usize,
            component_start: usize,
        },
        candidate: CandidateState,
        access: CandidateState,
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
                .map_lookup => |*lookup| {
                    lookup.cursor.deinit(releases, storage_allocator);
                    lookup.loading.deinit(releases, storage_allocator);
                },
                .artifact_begin => |*begin| begin.cursor.deinit(),
                .committed => |*cursor| cursor.deinit(releases, storage_allocator),
                .mapped_root => |*mapped| mapped.loading.deinit(releases, storage_allocator),
                .filename => |*filename| {
                    filename.filename.deinit(releases, storage_allocator);
                    filename.loading.deinit(releases, storage_allocator);
                },
                .component_start => |*component| {
                    component.filename.deinit(releases, storage_allocator);
                    component.loading.deinit(releases, storage_allocator);
                },
                .component_end => |*component| {
                    component.filename.deinit(releases, storage_allocator);
                    component.loading.deinit(releases, storage_allocator);
                },
                .candidate, .access => |*candidate| {
                    candidate.candidate.deinit(releases, storage_allocator);
                    candidate.filename.deinit(releases, storage_allocator);
                    candidate.loading.deinit(releases, storage_allocator);
                },
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

    fn makeFilename(
        self: *AutoLoadDriver,
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
        kind: FileKind,
        target: FilenameTarget,
    ) error{OutOfMemory}!FilenameState {
        const evaluator = via.fiber();
        const module_name = intern.get(intern.moduleId(self.request.module.name));
        const extension = switch (kind) {
            .source => ".ecl",
            .native => ".eclmod",
        };
        const length = std.math.add(usize, module_name.len, extension.len) catch
            return error.OutOfMemory;
        const filename = try evaluator.allocator.alloc(u8, length);
        return .{
            .loading = .init(loading.take()),
            .filename = .init(filename),
            .kind = kind,
            .target = target,
        };
    }
    fn makeCandidate(
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
        filename: *heap.Owned([]u8),
        kind: FileKind,
        origin: CandidateOrigin,
    ) error{OutOfMemory}!CandidateState {
        const evaluator = via.fiber();
        const directory = switch (origin) {
            .mapped => |mapped| mapped.root,
            .search_path => |legacy| legacy_directory: {
                const search = evaluator.inherited.ecl_path.?;
                break :legacy_directory search[legacy.component_start..legacy.component_end];
            },
        };
        const separator = directory.len != 0 and !std.fs.path.isSep(directory[directory.len - 1]);
        var length = std.math.add(usize, directory.len, filename.borrow().len) catch
            return error.OutOfMemory;
        if (separator) length = std.math.add(usize, length, 1) catch
            return error.OutOfMemory;
        const candidate = try evaluator.allocator.alloc(u8, length);
        return .{
            .loading = .init(loading.take()),
            .filename = .init(filename.take()),
            .kind = kind,
            .origin = origin,
            .candidate = .init(candidate),
            .separator = separator,
        };
    }
    /// Embedded modules reuse the candidate slot for their provenance
    /// name, so the existing `.path_value` phase materializes exactly the
    /// value the load continuation reports as `'path`.
    fn beginEmbedded(
        self: *AutoLoadDriver,
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
        entry: stdlib.Entry,
    ) error{OutOfMemory}!void {
        const evaluator = via.fiber();
        const provenance = switch (entry) {
            .source => |source| source.name,
            .native, .builtin => intern.get(intern.moduleId(self.request.module.name)),
        };
        var candidate = heap.Owned([]u8).init(try evaluator.allocator.dupe(u8, provenance));
        const materializer = kernel_storage.Utf8Materializer.init(
            evaluator.allocator,
            candidate.borrow(),
        );
        self.state.borrowMut().* = .{ .path_value = .{
            .loading = .init(loading.take()),
            .candidate = .init(candidate.take()),
            .materializer = .init(materializer),
            .disposition = .{ .embedded = entry },
        } };
    }
    /// The module is already registered, so this driver publishes nothing.
    fn finishWithoutLoading(
        self: *AutoLoadDriver,
        via: *Loading,
        loading: *heap.Owned(modules.LoadingLease),
    ) MachineError!WorkProgress {
        loading.borrowMut().finish();
        return continueSourceRequest(via, self, self.request);
    }
    fn notFound(self: *AutoLoadDriver, via: *Loading) MachineError {
        const evaluator = via.fiber();
        return evaluator.undefinedWordIn(self.request.module.operation.qualified, .qualified);
    }
    fn sourceCompletion(
        self: *AutoLoadDriver,
        transfer: *@FieldType(State, "transfer"),
        provenance: modules.RegistrationProvenance,
        artifact: ?map_state.ArtifactId,
    ) SourceCompletion {
        return .{ .register = .{
            .loading = transfer.loading.borrowMut().move(),
            .path = transfer.path.take(),
            .request = self.request,
            .provenance = provenance,
            .artifact = artifact,
        } };
    }
    pub fn advance(via: *Loading, self: *AutoLoadDriver) MachineError!WorkProgress {
        const evaluator = via.fiber();
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        work: while (work.spend()) switch (self.state.borrowMut().*) {
            .begin => |*cursor| switch (try cursor.advance()) {
                .pending => {},
                .complete => |outcome| switch (outcome) {
                    .cycle => return evaluator.failFmt(
                        .domain,
                        "recursive auto-load of module `{s}`",
                        .{intern.get(intern.moduleId(self.request.module.name))},
                    ),
                    // Another fiber is loading this name. Wait for it
                    // rather than publishing a second copy; the recheck
                    // below is what makes the winner's work count.
                    .contended => {
                        cursor.deinit();
                        self.state.borrowMut().* = .{ .begin = evaluator.inherited.registry.beginLoadingCursor(
                            self.request.module.name,
                            .of(evaluator),
                        ) };
                        return .{ .yielded = .wait };
                    },
                    .granted => |lease| {
                        cursor.deinit();
                        if (evaluator.inherited.module_snapshot != null and
                            via.embeddedLibrary(self.request.module.name) == null)
                        {
                            self.state.borrowMut().* = .{ .map_lookup = .{
                                .loading = .init(lease),
                                .cursor = .init(evaluator.inherited.module_snapshot.?.lookupCursor(
                                    self.request.module.operation.context.scopeId(),
                                    intern.get(intern.moduleId(self.request.module.name)),
                                )),
                            } };
                        } else {
                            self.state.borrowMut().* = .{ .registered = .{
                                .loading = .init(lease),
                                .cursor = .init(evaluator.inherited.registry.acquireCursor(self.request.module.name)),
                            } };
                        }
                    },
                },
            },
            // A load that raced a winner has nothing left to publish: its
            // tagged operation resumes against the winner's module.
            .registered => |*registered| switch (registered.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |maybe_generation| {
                    var loading = heap.Owned(modules.LoadingLease).init(registered.loading.take());
                    defer loading.deinit(evaluator.releases, evaluator.allocator);
                    registered.cursor.deinit(
                        evaluator.releases,
                        evaluator.allocator,
                    );
                    if (maybe_generation) |generation| {
                        var lease = generation;
                        lease.deinit();
                        return self.finishWithoutLoading(via, &loading);
                    }
                    // The embedded manifest is consulted before the
                    // search path: a stdlib name resolves without filesystem lookup
                    // and no ECL_PATH, and no path module can shadow one.
                    if (via.embeddedLibrary(self.request.module.name)) |entry| {
                        try self.beginEmbedded(via, &loading, entry);
                        continue;
                    }
                    if (evaluator.inherited.module_snapshot) |module_snapshot| {
                        self.state.borrowMut().* = .{ .map_lookup = .{
                            .loading = .init(loading.take()),
                            .cursor = .init(module_snapshot.lookupCursor(
                                self.request.module.operation.context.scopeId(),
                                intern.get(intern.moduleId(self.request.module.name)),
                            )),
                        } };
                        continue;
                    }
                    if (evaluator.inherited.ecl_path == null)
                        return self.notFound(via);
                    const filename = try self.makeFilename(
                        via,
                        &loading,
                        .source,
                        .{ .component_start = 0 },
                    );
                    self.state.borrowMut().* = .{ .filename = filename };
                },
            },
            .map_lookup => |*lookup| switch (lookup.cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |outcome| {
                    var loading = heap.Owned(modules.LoadingLease).init(lookup.loading.take());
                    defer loading.deinit(evaluator.releases, evaluator.allocator);
                    lookup.cursor.deinit(
                        evaluator.releases,
                        evaluator.allocator,
                    );
                    switch (outcome) {
                        .unmatched => {
                            return evaluator.failFmt(
                                .undefined_word,
                                "module `{s}` is not exported by the active module map",
                                .{intern.get(intern.moduleId(self.request.module.name))},
                            );
                        },
                        .hidden => |hidden| {
                            return evaluator.failFmt(
                                .undefined_word,
                                "module `{s}` is exported by scope `{s}`, but is not visible to `{s}`",
                                .{
                                    intern.get(intern.moduleId(self.request.module.name)),
                                    hidden.owner,
                                    hidden.consumer,
                                },
                            );
                        },
                        .matched => |match| {
                            loading.borrowMut().finish();
                            const target: MappedTarget = .{
                                .scope_name = match.scope_name,
                                .root = match.root,
                                .relative_path = match.relative_path,
                                .scope_id = match.scope_id,
                                .artifact_id = match.artifact_id,
                                .kind = match.kind,
                            };
                            self.state.borrowMut().* = .{ .artifact_begin = .{
                                .target = target,
                                .cursor = evaluator.inherited.registry.beginArtifactLoadingCursor(match.artifact_id, .of(evaluator)),
                            } };
                        },
                    }
                },
            },
            .artifact_begin => |*begin| switch (try begin.cursor.advance()) {
                .pending => {},
                .complete => |outcome| switch (outcome) {
                    .cycle => return evaluator.failFmt(
                        .domain,
                        "recursive auto-load of mapped artifact `{s}`",
                        .{begin.target.relative_path},
                    ),
                    .contended => {
                        const target = begin.target;
                        begin.cursor.deinit();
                        self.state.borrowMut().* = .{ .artifact_begin = .{
                            .target = target,
                            .cursor = evaluator.inherited.registry.beginArtifactLoadingCursor(
                                target.artifact_id,
                                .of(evaluator),
                            ),
                        } };
                        return .{ .yielded = .wait };
                    },
                    .granted => |lease| {
                        const target = begin.target;
                        begin.cursor.deinit();
                        self.state.borrowMut().* = .{ .mapped_root = .{ .target = target, .loading = .init(lease) } };
                        if (evaluator.inherited.module_snapshot.?.artifactCommitted(target.artifact_id)) {
                            self.state.borrowMut().mapped_root.loading.borrowMut().finish();
                            if (self.request == .source) return .completed;
                            self.state.borrowMut().mapped_root.loading.deinit(evaluator.releases, evaluator.allocator);
                            self.state.borrowMut().* = .{ .committed = .init(evaluator.inherited.registry.acquireCursor(self.request.module.name)) };
                        }
                    },
                },
            },
            .committed => |*cursor| switch (cursor.borrowMut().advance()) {
                .pending => {},
                .complete => |maybe_generation| {
                    cursor.deinit(evaluator.releases, evaluator.allocator);
                    const generation = maybe_generation orelse return evaluator.failFmt(
                        .io,
                        "a committed mapped artifact is missing module `{s}`",
                        .{intern.get(intern.moduleId(self.request.module.name))},
                    );
                    var lease = generation;
                    lease.deinit();
                    return continueSourceRequest(via, self, self.request);
                },
            },
            .mapped_root => |*mapped| {
                var loading = heap.Owned(modules.LoadingLease).init(mapped.loading.take());
                defer loading.deinit(evaluator.releases, evaluator.allocator);
                const origin: CandidateOrigin = .{ .mapped = .{
                    .scope_name = mapped.target.scope_name,
                    .root = mapped.target.root,
                    .scope_id = mapped.target.scope_id,
                    .artifact_id = mapped.target.artifact_id,
                } };
                const filename_bytes = try evaluator.allocator.dupe(u8, mapped.target.relative_path);
                const filename = FilenameState{
                    .loading = .init(loading.take()),
                    .filename = .init(filename_bytes),
                    .index = filename_bytes.len,
                    .kind = if (mapped.target.kind == .ecl) .source else .native,
                    .target = .{ .candidate = origin },
                };
                self.state.borrowMut().* = .{ .filename = filename };
            },
            .filename => |*filename| {
                if (filename.index != filename.filename.borrow().len) {
                    const module_name = intern.get(intern.moduleId(self.request.module.name));
                    const extension = switch (filename.kind) {
                        .source => ".ecl",
                        .native => ".eclmod",
                    };
                    filename.filename.borrow()[filename.index] = if (filename.index < module_name.len)
                        module_name[filename.index]
                    else
                        extension[filename.index - module_name.len];
                    filename.index += 1;
                } else switch (filename.target) {
                    .component_start => |search_index| {
                        const next = @FieldType(State, "component_start"){
                            .loading = .init(filename.loading.take()),
                            .filename = .init(filename.filename.take()),
                            .kind = filename.kind,
                            .search_index = search_index,
                        };
                        self.state.borrowMut().* = .{ .component_start = next };
                    },
                    .candidate => |origin| {
                        const candidate = try makeCandidate(
                            via,
                            &filename.loading,
                            &filename.filename,
                            filename.kind,
                            origin,
                        );
                        self.state.borrowMut().* = .{ .candidate = candidate };
                    },
                }
            },
            .component_start => |*component| {
                const search = evaluator.inherited.ecl_path.?;
                if (component.search_index == search.len) return self.notFound(via);
                if (search[component.search_index] == std.fs.path.delimiter) {
                    component.search_index += 1;
                } else {
                    const next = @FieldType(State, "component_end"){
                        .loading = .init(component.loading.take()),
                        .filename = .init(component.filename.take()),
                        .kind = component.kind,
                        .search_index = component.search_index,
                        .component_start = component.search_index,
                    };
                    self.state.borrowMut().* = .{ .component_end = next };
                }
            },
            .component_end => |*component| {
                const search = evaluator.inherited.ecl_path.?;
                if (component.search_index == search.len or
                    search[component.search_index] == std.fs.path.delimiter)
                {
                    const component_end = component.search_index;
                    var next_search = component.search_index;
                    if (next_search != search.len) next_search += 1;
                    const origin: CandidateOrigin = .{ .search_path = .{
                        .component_start = component.component_start,
                        .component_end = component_end,
                        .next_search = next_search,
                    } };
                    const candidate = try makeCandidate(
                        via,
                        &component.loading,
                        &component.filename,
                        component.kind,
                        origin,
                    );
                    self.state.borrowMut().* = .{ .candidate = candidate };
                } else component.search_index += 1;
            },
            .candidate => |*candidate| {
                const directory = switch (candidate.origin) {
                    .mapped => |mapped| mapped.root,
                    .search_path => |legacy| legacy_directory: {
                        const search = evaluator.inherited.ecl_path.?;
                        break :legacy_directory search[legacy.component_start..legacy.component_end];
                    },
                };
                if (candidate.index != candidate.candidate.borrow().len) {
                    candidate.candidate.borrow()[candidate.index] = if (candidate.index < directory.len)
                        directory[candidate.index]
                    else if (candidate.separator and candidate.index == directory.len)
                        std.fs.path.sep
                    else
                        candidate.filename.borrow()[candidate.index - directory.len - @intFromBool(candidate.separator)];
                    candidate.index += 1;
                } else {
                    const next = CandidateState{
                        .loading = .init(candidate.loading.take()),
                        .filename = .init(candidate.filename.take()),
                        .kind = candidate.kind,
                        .origin = candidate.origin,
                        .candidate = .init(candidate.candidate.take()),
                        .index = candidate.index,
                        .separator = candidate.separator,
                    };
                    self.state.borrowMut().* = .{ .access = next };
                }
            },
            .access => |*access| {
                var disposition: Disposition = switch (access.kind) {
                    .source => .{ .source = switch (access.origin) {
                        .search_path => .{ .provenance = .ordinary, .artifact = null },
                        .mapped => |mapped| .{
                            .provenance = .{ .source = evaluator.inherited.module_snapshot.?.sourceScope(mapped.artifact_id) },
                            .artifact = mapped.artifact_id,
                        },
                    } },
                    .native => .{ .native = switch (access.origin) {
                        .search_path => null,
                        .mapped => |mapped| mapped.artifact_id,
                    } },
                };
                std.Io.Dir.cwd().access(
                    evaluator.inherited.runtime().host_io,
                    access.candidate.borrow(),
                    .{ .read = true },
                ) catch |err| switch (err) {
                    error.FileNotFound => {
                        const origin = access.origin;
                        switch (origin) {
                            .mapped => |mapped| return evaluator.failFmt(
                                .undefined_word,
                                "mapped source `{s}` is absent from scope `{s}`",
                                .{ access.candidate.borrow(), mapped.scope_name },
                            ),
                            .search_path => |legacy| {
                                const kind: FileKind = if (access.kind == .source) .native else .source;
                                const target: FilenameTarget = if (access.kind == .source)
                                    .{ .candidate = origin }
                                else
                                    .{ .component_start = legacy.next_search };
                                const filename = try self.makeFilename(
                                    via,
                                    &access.loading,
                                    kind,
                                    target,
                                );
                                access.candidate.deinit(evaluator.releases, evaluator.allocator);
                                access.filename.deinit(evaluator.releases, evaluator.allocator);
                                self.state.borrowMut().* = .{ .filename = filename };
                                continue :work;
                            },
                        }
                    },
                    else => disposition = .{ .fail = @errorName(err) },
                };
                const materializer = kernel_storage.Utf8Materializer.init(
                    evaluator.allocator,
                    access.candidate.borrow(),
                );
                access.filename.deinit(evaluator.releases, evaluator.allocator);
                const next = @FieldType(State, "path_value"){
                    .loading = .init(access.loading.take()),
                    .candidate = .init(access.candidate.take()),
                    .materializer = .init(materializer),
                    .disposition = disposition,
                };
                self.state.borrowMut().* = .{ .path_value = next };
            },
            .path_value => |*path| switch (path.materializer.borrowMut().advance(work) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return evaluator.fail(.io, "module path is not valid UTF-8"),
            }) {
                .pending => {},
                .complete => |path_value| {
                    path.materializer.deinit(
                        evaluator.releases,
                        evaluator.allocator,
                    );
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
                .fail => |name| {
                    const failure = evaluator.failFmt(
                        .io,
                        "cannot access module file `{s}`: {s}",
                        .{ transfer.candidate.borrow(), name },
                    );
                    evaluator.addErrorPath(transfer.path.borrow());
                    return failure;
                },
                .embedded => |entry| return self.transferEmbedded(via, transfer, entry),
                .native => return self.transferNative(via, transfer),
                .source => |source| {
                    const candidate = transfer.candidate.take();
                    const completion = self.sourceCompletion(
                        transfer,
                        source.provenance,
                        source.artifact,
                    );
                    evaluator.retireDriver(self);
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
        const evaluator = via.fiber();
        const text = switch (entry) {
            .source => |source| try evaluator.allocator.dupe(u8, source.text),
            .native => |descriptor| return self.transferStatic(via, transfer, descriptor),
            .builtin => |module| return self.transferBuiltin(via, transfer, module),
        };
        const source_name = transfer.candidate.take();
        const completion = self.sourceCompletion(transfer, .standard_library, null);
        evaluator.retireDriver(self);
        try sourceOwned(via, source_name, text, completion);
        return .detached;
    }
    fn transferBuiltin(
        self: *AutoLoadDriver,
        via: *Loading,
        transfer: *@FieldType(State, "transfer"),
        module: env.BuiltinModule,
    ) MachineError!WorkProgress {
        const evaluator = via.fiber();
        // The candidate is created before ownership moves: struct-literal
        // fields evaluate in order, so a failure here would otherwise
        // strand the lease and path this driver had already taken.
        const publication = try modules.Registry.BuiltinCandidateCursor.init(evaluator.inherited.registry, self.request.module.name, .standard_library, module);
        // No errdefer: from here nothing fails until `startDriver`, which
        // disposes the whole uninstalled driver's owned fields itself.
        const next = BuiltinLoadDriver{
            .name = self.request.module.name,
            .request = self.request.module.operation,
            .loading = .init(transfer.loading.take()),
            .path = .init(transfer.path.take()),
            .publication = .init(publication),
        };
        evaluator.retireDriver(self);
        try via.startDriver(next);
        return .detached;
    }
    fn transferStatic(
        self: *AutoLoadDriver,
        via: *Loading,
        transfer: *@FieldType(State, "transfer"),
        descriptor: *const native_abi.Descriptor,
    ) MachineError!WorkProgress {
        const evaluator = via.fiber();
        const loader_authority = evaluator.inherited.runtime().native_loader;
        const loader = switch (loader_authority.startStatic(self.request.module.name, descriptor)) {
            .failure => |failure| {
                const failed = evaluator.fail(.io, failure.text());
                evaluator.addErrorPath(transfer.path.borrow());
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
        evaluator.retireDriver(self);
        try via.startDriver(next);
        return .detached;
    }
    fn transferNative(
        self: *AutoLoadDriver,
        via: *Loading,
        transfer: *@FieldType(State, "transfer"),
    ) MachineError!WorkProgress {
        const evaluator = via.fiber();
        const loader_authority = evaluator.inherited.runtime().native_loader;
        const start = try loader_authority.startDynamic(
            self.request.module.name,
            transfer.candidate.borrow(),
        );
        const loader = switch (start) {
            .failure => |failure| {
                const failed = evaluator.fail(.io, failure.text());
                evaluator.addErrorPath(transfer.path.borrow());
                return failed;
            },
            .loading => |loading| loading,
        };
        const next = NativeLoadDriver{
            .name = self.request.module.name,
            .request = self.request.module.operation,
            .provenance = if (transfer.disposition.native) |id| .{ .source = evaluator.inherited.module_snapshot.?.sourceScope(id) } else .ordinary,
            .loading = .init(transfer.loading.take()),
            .path = .init(transfer.path.take()),
            .state = .init(.{ .validate = .init(loader) }),
        };
        evaluator.retireDriver(self);
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
        const evaluator = via.fiber();
        try evaluator.pollKernel();
        if (self.commit == null) {
            switch (self.publication.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidName => return evaluator.fail(
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
                        error.Duplicate, error.UnboundWord => return evaluator.fail(
                            .contract,
                            "builtin module declares an invalid word",
                        ),
                    };
                    self.commit = .init(evaluator.inherited.registry.registrationCursor(sealed));
                    return .stepped;
                },
            }
        }
        switch (self.commit.?.borrowMut().advance() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return evaluator.failFmt(
                .io,
                "cannot publish builtin module `{s}`: {s}",
                .{ intern.get(intern.moduleId(self.name)), @errorName(err) },
            ),
        }) {
            .pending => return .stepped,
            .complete => {},
        }
        self.commit.?.deinit(evaluator.releases, evaluator.allocator);
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
        const evaluator = via.fiber();
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.path.borrow());
        return failure;
    }

    pub fn advance(via: *Loading, self: *NativeLoadDriver) MachineError!WorkProgress {
        const evaluator = via.fiber();
        try evaluator.pollKernel();
        switch (self.state.borrowMut().*) {
            .validate => |*loader| switch (try loader.borrowMut().advance(evaluator.workBudget())) {
                .pending => return .stepped,
                .failure => |failure| return self.failLoad(via, failure.text()),
                .loaded => |instance| {
                    loader.deinit(evaluator.releases, evaluator.allocator);
                    self.state.borrowMut().* = .{ .loaded = .init(instance) };
                    return .stepped;
                },
            },
            .loaded => |*instance| {
                const publication = try modules.Registry.NativeCandidateCursor.init(
                    evaluator.inherited.registry,
                    self.name,
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
                        error.Duplicate, error.UnboundWord => return self.failLoad(via, "native module declares an invalid word"),
                    };
                    // Shadowing in a shipped module is deliberate.
                    if (self.provenance != .standard_library) {
                        var names = sealed.entries();
                        while (true) switch (names.advance()) {
                            .pending => {},
                            .item => |entry| evaluator.warnCoreShadowing(entry.key, sealed.moduleName()),
                            .complete => break,
                        };
                    }
                    const instance = definitions.instance.take();
                    definitions.publication.deinit(
                        evaluator.releases,
                        evaluator.allocator,
                    );
                    const cursor = evaluator.inherited.registry.registrationCursor(sealed);
                    self.state.borrowMut().* = .{ .commit = .{
                        .instance = .init(instance),
                        .cursor = .init(cursor),
                    } };
                    return .stepped;
                },
            },
            .commit => |*commit| switch (commit.cursor.borrowMut().advance() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return evaluator.failFmt(
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
                    cursor.deinit(evaluator.releases, evaluator.allocator);
                    if (self.provenance == .source) evaluator.inherited.module_snapshot.?.commitArtifact(self.loading.borrowMut().artifactCommit());
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
    push,
    call: ?*const map_state.SourceScope,
    session: ?*const map_state.SourceScope,
    /// `@load`: the source runs as a stack-isolated unit on an empty stack.
    load: struct {
        source: ?*const map_state.SourceScope = null,
        word: intern.TraceWord,
    },
    /// Registration only: the source runs, then the loading lease and
    /// tagged qualified operation transfer to the return frame.
    register: struct {
        loading: ?modules.LoadingLease,
        path: ?Value,
        request: SourceLoadRequest,
        provenance: modules.RegistrationProvenance,
        artifact: ?map_state.ArtifactId,
    },

    pub fn deinit(self: *SourceCompletion, releases: *heap.ReleaseDomain) void {
        switch (self.*) {
            .push, .call, .session, .load => {},
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
        locating: map_state.SourcePathCursor,
        ingesting: spans.SpanArchive.SourceIngestCursor,
        activating: *Header,
        storage,
    };

    retirement: heap.ReleaseDomain.Retirement = .{},
    text: heap.Owned(SourceText),
    completion: heap.Owned(SourceCompletion),
    diag: reader.Diag = .{},
    state: State = .start,

    fn beginIngest(self: *SourceDriver, via: *Loading) error{OutOfMemory}!void {
        const evaluator = via.fiber();
        const ingestion = try evaluator.archive.sourceIngestCursor(
            self.text.borrow().sourceName(),
            self.text.borrow().source(),
            &self.diag,
            try evaluator.rootLinker(evaluator.lexicalScope()),
        );
        self.state = .{ .ingesting = ingestion };
    }

    pub fn advance(via: *Loading, self: *SourceDriver) MachineError!WorkProgress {
        const evaluator = via.fiber();
        // Preserve the established pre-cancelled-fiber behavior for a
        // source that fits in its first bounded slice: activate it first,
        // so evaluation can attach cancellation to the responsible word.
        // A source that needs another slice observes cancellation before
        // doing any more ingestion work.
        if (self.state != .start) try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) switch (self.state) {
            .start => {
                if ((self.completion.borrow() == .call or self.completion.borrow() == .session or
                    self.completion.borrow() == .load) and
                    evaluator.inherited.module_snapshot != null)
                {
                    const cursor = try evaluator.inherited.module_snapshot.?.sourcePathCursor(self.text.borrow().sourceName());
                    self.state = .{ .locating = cursor };
                } else try self.beginIngest(via);
            },
            .locating => |*cursor| switch (cursor.advance()) {
                .pending => {},
                .complete => |source| {
                    cursor.deinit();
                    self.state = .start;
                    switch (self.completion.borrowMut().*) {
                        .call => |*context| context.* = source,
                        .session => |*context| context.* = source,
                        .load => |*load| load.source = source,
                        else => unreachable,
                    }
                    try self.beginIngest(via);
                },
            },
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
                    .push => try evaluator.pushBorrowed(.{ .list = root_header }),
                    .load => |load| {
                        const provenance: modules.RegistrationProvenance = if (load.source) |context|
                            .{ .source = context }
                        else
                            .ordinary;
                        heap.incRef(root_header);
                        try via.openLoad(root_header, load.word, provenance);
                    },
                    .call, .session => |source| {
                        heap.incRef(root_header);
                        try evaluator.callProgramOwned(root_header, .owned);
                        if (source) |context| {
                            evaluator.current.?.site.registration_provenance = .{ .source = context };
                        } else if (self.completion.borrow() == .call) {
                            evaluator.current.?.site.registration_provenance = .ordinary;
                        }
                    },
                    .register => |*register| {
                        heap.incRef(root_header);
                        const after = AfterLoad{
                            .loading = register.loading.?.move(),
                            .path = register.path.?,
                            .request = register.request,
                            .artifact = .init(register.artifact),
                        };
                        register.loading = null;
                        register.path = null;
                        try via.enterRegistration(root_header, register.provenance, after);
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
            .locating => |*cursor| {
                cursor.deinit();
                self.state = .storage;
                return false;
            },
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
                .push, .call, .session, .load => null,
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
        const evaluator = via.fiber();
        const failure = evaluator.fail(.io, message);
        if (diagnosticPath(context)) |item| evaluator.addErrorPath(item);
        return failure;
    }
    pub fn advance(via: *Loading, self: *FileSourceDriver) MachineError!WorkProgress {
        const evaluator = via.fiber();
        try evaluator.pollKernel();
        const io = evaluator.inherited.runtime().host_io;
        switch (self.state.borrowMut().*) {
            .open => |*context| {
                const file = std.Io.Dir.cwd().openFile(io, context.path.borrow(), .{}) catch |err| {
                    const failure = evaluator.failFmt(
                        .io,
                        "cannot read `{s}`: {s}",
                        .{ context.path.borrow(), @errorName(err) },
                    );
                    if (diagnosticPath(context)) |item| evaluator.addErrorPath(item);
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
                    const failure = evaluator.failFmt(
                        .io,
                        "cannot read `{s}`: {s}",
                        .{ size.context.path.borrow(), @errorName(err) },
                    );
                    if (diagnosticPath(&size.context)) |item| evaluator.addErrorPath(item);
                    return failure;
                };
                if (stat.size > std.math.maxInt(usize))
                    return failIo(&size.context, evaluator, "source file is too large");
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
                    const end = read.offset + evaluator.workBudget().take(read.source.borrow().len - read.offset);
                    const amount = read.reader.interface.readSliceShort(
                        read.source.borrow()[read.offset..end],
                    ) catch {
                        const name = if (read.reader.err) |err| @errorName(err) else "ReadFailed";
                        const failure = evaluator.failFmt(
                            .io,
                            "cannot read `{s}`: {s}",
                            .{ read.context.path.borrow(), name },
                        );
                        if (diagnosticPath(&read.context)) |item| evaluator.addErrorPath(item);
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
                read.file.deinit(evaluator.releases, evaluator.allocator);
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
                evaluator.retireDriver(self);
                try sourceOwned(via, path, source, completion);
                return .detached;
            },
            .complete => unreachable,
        }
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
/// Resumable boundary between a qualified miss and module loading. A prefix
/// absent from the intern table is external, runtime-sized input; preserving
/// this cursor as its own driver keeps both insertion and module-name
/// validation inside scheduler safe points.
const QualifiedLoadPreparationDriver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    const Restore = union(enum) {
        none,
        operand: value.Symbol,
    };

    cursor: intern.InternModuleNameCursor,
    request: QualifiedLoadRequest,
    restore: Restore,

    fn init(
        prefix: []const u8,
        request: QualifiedLoadRequest,
        restore: Restore,
    ) QualifiedLoadPreparationDriver {
        return .{
            .cursor = intern.internModuleNameCursor(prefix),
            .request = request,
            .restore = restore,
        };
    }

    pub fn advance(
        via: *Loading,
        self: *QualifiedLoadPreparationDriver,
    ) MachineError!WorkProgress {
        const evaluator = via.fiber();
        try evaluator.pollKernel();
        const work = evaluator.workBudget();
        while (work.spend()) switch (try self.cursor.advance()) {
            .pending => {},
            .complete => |maybe_name| {
                const name = maybe_name orelse return switch (self.restore) {
                    .none => evaluator.undefinedWordIn(self.request.qualified, .qualified),
                    .operand => evaluator.undefinedNameIn(self.request.qualified, .qualified),
                };
                const request = self.request;
                const restore = self.restore;
                switch (restore) {
                    .none => {},
                    .operand => |requested| {
                        try via.replayOperand(requested);
                    },
                }
                evaluator.retireDriver(self);
                try autoLoadModule(via, name, request);
                return .detached;
            },
        };
        return .stepped;
    }
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
    const evaluator = via.fiber();
    return switch (request.continuation) {
        .replay, .load_only => .completed,
        .dispatch => |dispatch_request| continuation: {
            evaluator.retireDriver(driver);
            try via.dispatchAfterLoad(
                dispatch_request.word,
                dispatch_request.site,
                dispatch_request.trace_parent,
                request.context,
            );
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
    const evaluator = via.fiber();
    loading.borrowMut().finish();
    const registry = evaluator.inherited.registry;
    const next = QualifiedRegistrationDriver{
        .path = .init(path.take()),
        .acquisition = .init(registry.acquireCursor(name)),
        .request = .{ .module = .{ .name = name, .operation = request } },
    };
    evaluator.retireDriver(driver);
    try via.startDriver(next);
    return .detached;
}

/// Verifies what a completed load registered before releasing its lease:
/// every module the load was expected to register, then every import a
/// module body deferred onto this load. An artifact commits only after both.
const QualifiedRegistrationDriver = struct {
    path: heap.Owned(Value),
    acquisition: heap.Owned(modules.Registry.AcquireCursor),
    request: SourceLoadRequest,
    loading: ?heap.Owned(modules.LoadingLease) = null,
    artifact: ?map_state.ArtifactId = null,
    module_index: usize = 0,
    /// The active name lookup of the `.resolving` phase. It is a direct field,
    /// not a phase payload, so cancelling the driver releases its pin.
    resolving_cursor: ?heap.Owned(modules.ModuleNameLookupCursor) = null,
    phase: union(enum) {
        declared,
        /// The index of the deferred import whose module is being acquired.
        deferred: usize,
        /// The deferred import whose name is being looked up.
        resolving: usize,
    } = .declared,

    pub fn advance(via: *Loading, self: *QualifiedRegistrationDriver) MachineError!WorkProgress {
        const evaluator = via.fiber();
        try evaluator.pollKernel();
        switch (self.phase) {
            .declared => {},
            .deferred => |index| return self.acquireDeferred(via, index),
            .resolving => |index| {
                const cursor = if (self.resolving_cursor) |*owned| owned else unreachable;
                switch (cursor.borrowMut().advance()) {
                    .pending => return .stepped,
                    .complete => |maybe_entry| {
                        const public = if (maybe_entry) |entry| modules.entryIsPublic(entry) else false;
                        cursor.deinit(evaluator.releases, evaluator.allocator);
                        self.resolving_cursor = null;
                        if (!public) return self.failDeferred(via, index);
                        return self.nextDeferred(via, index + 1);
                    },
                }
            },
        }
        switch (self.acquisition.borrowMut().advance()) {
            .pending => return .stepped,
            .complete => |maybe_generation| {
                const checked_name = if (self.artifact) |artifact|
                    evaluator.inherited.module_snapshot.?.artifactModules(artifact)[self.module_index]
                else
                    self.request.module.name;
                const generation = maybe_generation orelse {
                    const failure = if (self.artifact != null)
                        evaluator.failFmt(
                            .io,
                            "loading mapped artifact registered nothing under declared module `{s}`",
                            .{intern.get(intern.moduleId(checked_name))},
                        )
                    else
                        evaluator.failFmt(
                            .io,
                            "loading module `{s}` registered nothing under that name",
                            .{intern.get(intern.moduleId(checked_name))},
                        );
                    evaluator.addErrorPath(self.path.borrow());
                    return failure;
                };
                var lease = generation;
                defer lease.deinit();
                if (self.artifact) |artifact| {
                    const expected_source = evaluator.inherited.module_snapshot.?.sourceScope(artifact);
                    const valid_origin = switch (lease.provenance()) {
                        .source => |source| source == expected_source,
                        .ordinary, .root_scope, .standard_library => false,
                    };
                    if (!valid_origin) {
                        const failure = evaluator.failFmt(
                            .domain,
                            "mapped artifact declared module `{s}` with foreign publication provenance",
                            .{intern.get(intern.moduleId(checked_name))},
                        );
                        evaluator.addErrorPath(self.path.borrow());
                        return failure;
                    }
                    const modules_in_artifact = evaluator.inherited.module_snapshot.?.artifactModules(artifact);
                    self.module_index += 1;
                    if (self.module_index != modules_in_artifact.len) {
                        self.acquisition.deinit(evaluator.releases, evaluator.allocator);
                        self.acquisition = .init(evaluator.inherited.registry.acquireCursor(
                            modules_in_artifact[self.module_index],
                        ));
                        return .stepped;
                    }
                }
                return self.nextDeferred(via, 0);
            },
        }
    }

    fn deferredImports(self: *const QualifiedRegistrationDriver) []const modules.DeferredImport {
        const loading = if (self.loading) |*owned| owned.borrow() else return &.{};
        return loading.deferredImports();
    }

    /// A deferred target is always a module this load registers, so it is
    /// read from the main registry directly: the importer's own lookup would
    /// not see an artifact that has yet to commit.
    fn nextDeferred(self: *QualifiedRegistrationDriver, via: *Loading, index: usize) MachineError!WorkProgress {
        const evaluator = via.fiber();
        const deferred = self.deferredImports();
        if (index == deferred.len) return self.complete(via);
        self.acquisition.deinit(evaluator.releases, evaluator.allocator);
        self.acquisition = .init(evaluator.inherited.registry.acquireCursor(deferred[index].module));
        self.phase = .{ .deferred = index };
        return .stepped;
    }

    fn acquireDeferred(self: *QualifiedRegistrationDriver, via: *Loading, index: usize) MachineError!WorkProgress {
        switch (self.acquisition.borrowMut().advance()) {
            .pending => return .stepped,
            .complete => |maybe_generation| {
                var lease = maybe_generation orelse return self.failDeferred(via, index);
                defer lease.deinit();
                const binding = self.deferredImports()[index].binding;
                self.resolving_cursor = .init(lease.lookupCursor(binding));
                self.phase = .{ .resolving = index };
                return .stepped;
            },
        }
    }

    fn failDeferred(self: *QualifiedRegistrationDriver, via: *Loading, index: usize) MachineError {
        const evaluator = via.fiber();
        const deferred = self.deferredImports()[index];
        const failure = evaluator.undefinedNameIn(deferred.qualified, .qualified);
        via.addErrorImporter(deferred.importer);
        evaluator.addErrorPath(self.path.borrow());
        return failure;
    }

    fn complete(self: *QualifiedRegistrationDriver, via: *Loading) MachineError!WorkProgress {
        const evaluator = via.fiber();
        if (self.loading) |*owned| {
            const lease = owned.borrowMut();
            if (self.artifact != null)
                evaluator.inherited.module_snapshot.?.commitArtifact(lease.artifactCommit());
            lease.finish();
        }
        return continueSourceRequest(via, self, self.request);
    }
    pub const ownership: heap.DriverOwnership = .fields;
};
