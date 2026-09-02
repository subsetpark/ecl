//! Exact hashing and hostile-input-safe package archive extraction.
//!
//! Binary payloads remain ordinary ECL integer lists. The encoder borrows an
//! internal byte leaf when available and validates any equivalent list, so the
//! module never assigns language semantics to a storage representation.
const std = @import("std");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const env = @import("../env.zig");
const external = @import("../external.zig");
const fsport = @import("../filesystem_port.zig");
const intern = @import("../intern.zig");
const machine = @import("../machine.zig");
const package_authority = @import("../package_authority.zig");
const storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");
const poll = @import("../poll.zig");
const pkg_catalog = @import("../pkg_catalog.zig");
const pkg_lock = @import("../pkg_lock.zig");

const Value = value.Value;
const Machine = machine.Machine;
const MachineError = machine.MachineError;
const work_quantum = machine.kernel_poll_quantum;
const max_uncompressed_bytes: usize = 1_073_741_824;
const max_members: usize = 100_000;
const max_path_bytes: usize = 4096;
const member_slots = 1 << 18;
const tar_block_bytes = 512;
pub const package_seal_name = ".ecl-package.tgz";

pub const words = [_]env.BuiltinWord{
    .{
        .name = "sha256",
        .doc = "( bytes -- lowercase-hex ) Hash an integer byte list with SHA-256.",
        .primitive = sha256,
    },
    .{
        .name = "unpack-tgz",
        .doc = "( bytes root destination -- regular-file-paths ) Validate and atomically " ++
            "extract a gzip tar into a previously absent destination beneath a named root.",
        .primitive = unpackTgz,
    },
};

fn sha256(evaluator: *Machine) MachineError!void {
    var bytes_value = try evaluator.popValue();
    errdefer bytes_value.deinit();
    if (bytes_value.borrow() != .list) return evaluator.typeError("an integer byte list");
    const encoder = storage.ByteVectorEncoder.init(evaluator.allocator(), bytes_value.borrow());
    try evaluator.startDriver(Sha256Driver{
        .bytes_value = .init(bytes_value.take()),
        .encoder = .init(encoder),
    });
}

const Sha256Driver = struct {
    pub const ownership: heap.DriverOwnership = .fields;

    bytes_value: heap.Owned(Value),
    encoder: heap.Owned(storage.ByteVectorEncoder),
    bytes: ?heap.Owned(storage.ByteVector) = null,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    index: usize = 0,
    digest: [32]u8 = @splat(0),
    rendered: [64]u8 = @splat(0),
    text: ?heap.Owned(storage.ByteStringMaterializer) = null,

    pub fn advance(evaluator: *Machine, self: *Sha256Driver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.bytes == null) switch (self.encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.failAtIndex(
                .domain,
                "archive.sha256 expects integers from 0 through 255",
                self.encoder.borrow().invalid_index.?,
            ),
        }) {
            .pending => return .yielded,
            .complete => |bytes| self.bytes = .init(bytes),
        };
        const input = self.bytes.?.borrow().bytes();
        if (self.index != input.len) {
            const end = @min(self.index + work_quantum, input.len);
            self.hasher.update(input[self.index..end]);
            self.index = end;
            return .yielded;
        }
        if (self.text == null) {
            self.hasher.final(&self.digest);
            self.rendered = std.fmt.bytesToHex(self.digest, .lower);
            self.text = .init(.init(evaluator.allocator(), &self.rendered));
        }
        return switch (try self.text.?.borrowMut().advance(work_quantum)) {
            .pending => .yielded,
            .complete => |result| .{ .output = result },
        };
    }
};

fn unpackTgz(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var destination = try evaluator.popValue();
    errdefer destination.deinit();
    if (!destination.borrow().isString()) return evaluator.typeError("a string destination path");
    var root = try evaluator.popValue();
    errdefer root.deinit();
    if (root.borrow() != .symbol) return evaluator.typeError("a root symbol");
    var bytes_value = try evaluator.popValue();
    errdefer bytes_value.deinit();
    if (bytes_value.borrow() != .list) return evaluator.typeError("an integer byte list");
    const access = evaluator.unit.inherited.filesystem_access orelse {
        const failure = evaluator.fail(.domain, "archive extraction is unavailable");
        evaluator.addErrorPath(destination.borrow());
        return failure;
    };
    const byte_encoder = storage.ByteVectorEncoder.init(evaluator.allocator(), bytes_value.borrow());
    const path_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), destination.borrow());
    const entries = poll.ChunkList(Entry).init(evaluator.allocator());
    try evaluator.startDriver(UnpackDriver{
        .allocator = evaluator.allocator(),
        .io = fsport.hostIo(access),
        .authority = .{ .filesystem = access },
        .bytes_value = .init(bytes_value.take()),
        .source = .init(.{ .unpack = .{
            .root = .init(root.take()),
            .destination = .init(destination.take()),
        } }),
        .entries = .init(entries),
        .state = .{ .parsing = .{ .encode_bytes = .{
            .byte = .init(byte_encoder),
            .target = .{ .unpack = .init(path_encoder) },
        } } },
    });
}

/// Package inspection shares the complete gzip/tar scanner with unpack-tgz,
/// but stops before any filesystem mutation and returns the exact root
/// manifest text. The active word remains pkg.store.inspect for diagnostics.
pub fn inspectPackage(evaluator: *Machine) MachineError!void {
    try evaluator.require(2);
    var package = try evaluator.popValue();
    errdefer package.deinit();
    if (!package.borrow().isString()) return evaluator.typeError("a string package name");
    var bytes_value = try evaluator.popValue();
    errdefer bytes_value.deinit();
    if (bytes_value.borrow() != .list) return evaluator.typeError("an integer byte list");
    const byte_encoder = storage.ByteVectorEncoder.init(evaluator.allocator(), bytes_value.borrow());
    const package_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), package.borrow());
    const entries = poll.ChunkList(Entry).init(evaluator.allocator());
    try evaluator.startDriver(UnpackDriver{
        .allocator = evaluator.allocator(),
        .io = null,
        .authority = .none,
        .bytes_value = .init(bytes_value.take()),
        .source = .init(.{ .inspect = .{ .package = .init(package.take()) } }),
        .entries = .init(entries),
        .state = .{ .parsing = .{ .encode_bytes = .{
            .byte = .init(byte_encoder),
            .target = .{ .inspect = .init(package_encoder) },
        } } },
    });
}

/// Resolves the `'cache`/`'vendor` store symbol a package word names against
/// the Session's package authority. Absence of the authority, an unknown store
/// symbol, and an unavailable store are distinct failures.
pub fn packageStore(evaluator: *Machine, store: Value, path_value: Value) MachineError!std.Io.Dir {
    const access = evaluator.unit.inherited.package_access orelse {
        const failure = evaluator.fail(.domain, "package store authority is unavailable");
        evaluator.addErrorPath(path_value);
        return failure;
    };
    const kind = storeKind(store) orelse return evaluator.fail(.domain, "package store must be 'cache or 'vendor");
    return package_authority.storeDir(access, kind) orelse {
        const failure = evaluator.fail(
            .io,
            "package store is unavailable; set ECL_CACHE, XDG_CACHE_HOME, or HOME",
        );
        evaluator.addErrorPath(path_value);
        return failure;
    };
}

fn storeKind(store: Value) ?package_authority.Store {
    if (store != .symbol) return null;
    const name = intern.get(store.symbol);
    inline for (std.enums.values(package_authority.Store)) |kind| {
        if (std.mem.eql(u8, name, kind.symbol())) return kind;
    }
    return null;
}

/// Package installation repeats the package scan at the mutation sink before
/// staging any member. The active word remains pkg.store.install.
pub fn installPackage(evaluator: *Machine) MachineError!void {
    try evaluator.require(4);
    var key = try evaluator.popValue();
    errdefer key.deinit();
    if (!key.borrow().isString()) return evaluator.typeError("a string store key");
    var store = try evaluator.popValue();
    errdefer store.deinit();
    if (store.borrow() != .symbol) return evaluator.typeError("a store symbol");
    var package = try evaluator.popValue();
    errdefer package.deinit();
    if (!package.borrow().isString()) return evaluator.typeError("a string package name");
    var bytes_value = try evaluator.popValue();
    errdefer bytes_value.deinit();
    if (bytes_value.borrow() != .list) return evaluator.typeError("an integer byte list");
    const store_dir = try packageStore(evaluator, store.borrow(), key.borrow());
    const access = evaluator.unit.inherited.package_access.?;
    const byte_encoder = storage.ByteVectorEncoder.init(evaluator.allocator(), bytes_value.borrow());
    const package_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), package.borrow());
    const path_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), key.borrow());
    const entries = poll.ChunkList(Entry).init(evaluator.allocator());
    try evaluator.startDriver(UnpackDriver{
        .allocator = evaluator.allocator(),
        .io = package_authority.hostIo(access),
        .authority = .{ .package = store_dir },
        .bytes_value = .init(bytes_value.take()),
        .source = .init(.{ .install = .{
            .package = .init(package.take()),
            .destination = .init(key.take()),
        } }),
        .entries = .init(entries),
        .state = .{ .parsing = .{ .encode_bytes = .{
            .byte = .init(byte_encoder),
            .target = .{ .install = .{
                .destination = .init(path_encoder),
                .package = .init(package_encoder),
            } },
        } } },
    });
}

const EntryKind = enum { file, directory };

const Entry = struct {
    path: []u8,
    kind: EntryKind,
    data_offset: usize,
    size: usize,
};

const EntryList = poll.ChunkList(Entry);

const GzipDecoder = struct {
    pub const owned_disposal: heap.OwnedDisposal = .deinit;

    const State = struct {
        input: std.Io.Reader,
        window: [std.compress.flate.max_window_len]u8,
        decompressor: std.compress.flate.Decompress,
    };

    allocator: std.mem.Allocator,
    state: *State,

    fn init(allocator: std.mem.Allocator, input_bytes: []const u8) error{OutOfMemory}!GzipDecoder {
        const state = try allocator.create(State);
        state.input = .fixed(input_bytes);
        state.decompressor = .init(&state.input, .gzip, &state.window);
        return .{ .allocator = allocator, .state = state };
    }

    fn read(self: *GzipDecoder, output: []u8) std.Io.Reader.ShortError!usize {
        return self.state.decompressor.reader.readSliceShort(output);
    }

    fn consumedAllInput(self: *const GzipDecoder) bool {
        return self.state.input.seek == self.state.input.end;
    }

    pub fn deinit(self: *GzipDecoder) void {
        self.allocator.destroy(self.state);
        self.* = undefined;
    }
};

const Mode = enum { unpack, package_inspect, package_install };

fn observeCleanupError(action: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => std.log.err("archive rollback could not {s}: {s}", .{ action, @errorName(err) }),
    }
}

/// Where a publication is allowed to land. Generic extraction is confined to
/// a named Session filesystem root; package installation to a package store
/// handle the Session's package authority retained. Inspection publishes
/// nothing.
const Authority = union(enum) {
    none,
    filesystem: *external.FilesystemAccess,
    package: std.Io.Dir,
};

const UnpackDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: ?std.Io,
    authority: Authority,
    bytes_value: heap.Owned(Value),
    source: heap.Owned(SourceTarget),
    entries: heap.Owned(EntryList),
    state: State,
    /// The resolved parent directory and final name the publication targets.
    /// Set by the resolver phase for extraction and directly from the store
    /// handle for installation; every namespace operation is relative to it.
    destination: ?fsport.Resolved = null,
    /// The live-operation reservation an extraction holds from authorization
    /// through terminal cleanup.
    slot: ?fsport.OperationSlot = null,

    const Staged = struct {
        result: Value,
        /// The private staging directory name inside the destination parent.
        path: heap.Owned([]u8),
    };
    const SourceTarget = union(enum) {
        pub const owned_disposal: heap.OwnedDisposal = .deinit;

        unpack: struct { root: heap.Owned(Value), destination: heap.Owned(Value) },
        inspect: struct { package: heap.Owned(Value) },
        install: struct {
            package: heap.Owned(Value),
            destination: heap.Owned(Value),
        },

        pub fn deinit(
            self: *SourceTarget,
            releases: *heap.ReleaseDomain,
            allocator: std.mem.Allocator,
        ) void {
            switch (self.*) {
                .unpack => |*source| {
                    source.root.deinit(releases, allocator);
                    source.destination.deinit(releases, allocator);
                },
                .inspect => |*source| source.package.deinit(releases, allocator),
                .install => |*source| {
                    source.package.deinit(releases, allocator);
                    source.destination.deinit(releases, allocator);
                },
            }
        }
    };
    const EncodeTarget = union(enum) {
        unpack: heap.Owned(storage.ToUtf8Cursor),
        inspect: heap.Owned(storage.ToUtf8Cursor),
        install: struct {
            destination: heap.Owned(storage.ToUtf8Cursor),
            package: heap.Owned(storage.ToUtf8Cursor),
        },
    };
    const EncodedTarget = union(enum) {
        unpack: heap.Owned([]u8),
        inspect: heap.Owned([]u8),
        install: struct {
            destination: heap.Owned([]u8),
            package: heap.Owned([]u8),
        },
    };
    const EncodedInputs = struct {
        bytes: heap.Owned(storage.ByteVector),
        target: EncodedTarget,
    };
    const Archive = struct {
        bytes: heap.Owned(storage.ByteVector),
        target: EncodedTarget,
        tar: heap.Owned([]u8),
        slots: heap.Owned([]?*Entry),
    };
    const ScanContext = struct {
        tar_offset: usize = 0,
        zero_blocks: u2 = 0,
        member_count: usize = 0,
        file_count: usize = 0,
        pending_path: ?heap.Owned([]u8) = null,
        pending_size: ?u64 = null,
        manifest_data: ?struct { offset: usize, size: usize } = null,
    };
    const Pax = struct {
        offset: usize,
        end: usize,
        next_offset: usize,
    };
    const ResultInputs = struct {
        values: []Value,
        built: usize = 0,
    };
    const ResultRelease = struct {
        values: []Value,
        built: usize,
        index: usize = 0,
    };
    const PathWork = union(enum) {
        next,
        text: storage.Utf8Materializer,
    };
    const ScanWork = union(enum) {
        tar_header,
        insert_member: struct {
            entry: Entry,
            next_offset: usize,
            slot: usize,
            probes: usize = 0,
        },
        parse_pax: Pax,
        scan_pax: struct {
            pax: Pax,
            record_end: usize,
            key_start: usize,
            scan_offset: usize,
        },
        trailing_zeroes,
        materialize_manifest,
        materialize_manifest_text: storage.Utf8Materializer,
        allocate_results,
        materialize_paths: struct {
            inputs: ResultInputs,
            iterator: EntryList.Iterator,
            work: PathWork = .next,
        },
        materialize_result: struct {
            inputs: ResultInputs,
            materializer: list.ValueMaterializer,
        },
        release_result_inputs: struct {
            release: ResultRelease,
            result: Value,
        },
        complete,
    };
    const Scanning = struct {
        context: ScanContext = .{},
        work: ScanWork = .tar_header,
    };
    const Parsing = union(enum) {
        encode_bytes: struct {
            byte: heap.Owned(storage.ByteVectorEncoder),
            target: EncodeTarget,
        },
        encode_destination: struct {
            bytes: heap.Owned(storage.ByteVector),
            destination: heap.Owned(storage.ToUtf8Cursor),
            package: ?heap.Owned(storage.ToUtf8Cursor),
        },
        encode_package: struct {
            bytes: heap.Owned(storage.ByteVector),
            destination: ?heap.Owned([]u8),
            package: heap.Owned(storage.ToUtf8Cursor),
        },
        allocate_tar: EncodedInputs,
        allocate_decoder: struct { inputs: EncodedInputs, tar: heap.Owned([]u8) },
        decompress: struct {
            inputs: EncodedInputs,
            tar: heap.Owned([]u8),
            decoder: heap.Owned(GzipDecoder),
            index: usize = 0,
        },
        verify: struct {
            inputs: EncodedInputs,
            tar: heap.Owned([]u8),
            index: usize = 0,
            crc: std.hash.crc.Crc32 = .init(),
        },
        allocate_slots: struct { inputs: EncodedInputs, tar: heap.Owned([]u8) },
        initialize_slots: struct {
            inputs: EncodedInputs,
            tar: heap.Owned([]u8),
            slots: heap.Owned([]?*Entry),
            index: usize = 0,
        },
    };
    const ExtractWork = union(enum) {
        next,
        file: struct {
            entry: *const Entry,
            file: std.Io.File,
            written: usize = 0,
        },
    };
    const Publication = union(enum) {
        resolve: struct { result: Value, resolver: fsport.Resolver },
        destination_check: Value,
        stage_path: Value,
        create_stage: Staged,
        open_stage: Staged,
        extract: struct {
            staged: Staged,
            dir: std.Io.Dir,
            iterator: EntryList.Iterator,
            created_count: usize = 0,
            work: ExtractWork = .next,
        },
        validate_package: struct {
            staged: Staged,
            dir: std.Io.Dir,
            created_count: usize,
            catalog: ?pkg_catalog.Build,
            diagnostic: ?[]u8 = null,
        },
        seal: struct {
            staged: Staged,
            dir: std.Io.Dir,
            file: std.Io.File,
            written: usize = 0,
            created_count: usize,
        },
        commit: struct { staged: Staged, created_count: usize },
        published: heap.Owned([]u8),
    };
    const ActiveWork = union(enum) {
        scanning: Scanning,
        publication: Publication,
    };
    const Active = struct {
        archive: Archive,
        work: ActiveWork,
    };
    const RollbackContext = struct {
        path: heap.Owned([]u8),
    };
    const RollbackPlan = union(enum) {
        entries: usize,
        seal_then_entries: usize,
    };
    const RollbackWork = union(enum) {
        seal: usize,
        skip: struct { iterator: EntryList.ReverseIterator, remaining: usize },
        entries: EntryList.ReverseIterator,
        parents: struct {
            iterator: EntryList.ReverseIterator,
            entry: *const Entry,
            end: usize,
        },
        root,
    };
    const CleanupWork = union(enum) {
        entries: EntryList.ReverseIterator,
        entries_with_results: struct {
            iterator: EntryList.ReverseIterator,
            release: ResultRelease,
        },
        results: ResultRelease,
        finish,
    };
    const ScanningRetirement = union(enum) {
        plain,
        results: ResultRelease,
    };
    const State = union(enum) {
        parsing: Parsing,
        active: Active,
        rollback_reopen: struct {
            archive: Archive,
            context: RollbackContext,
            plan: RollbackPlan,
        },
        rollback: struct {
            archive: Archive,
            context: RollbackContext,
            dir: std.Io.Dir,
            work: RollbackWork,
        },
        cleanup_archive: Archive,
        cleanup_archive_with_results: struct {
            archive: Archive,
            release: ResultRelease,
        },
        cleanup: CleanupWork,
    };

    pub fn advance(evaluator: *Machine, self: *UnpackDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .parsing => |*parsing| self.advanceParsing(evaluator, parsing),
            .active => |*active| self.advanceActive(evaluator, active),
            .rollback_reopen,
            .rollback,
            .cleanup_archive,
            .cleanup_archive_with_results,
            .cleanup,
            => unreachable,
        };
    }

    fn advanceParsing(
        self: *UnpackDriver,
        evaluator: *Machine,
        parsing: *Parsing,
    ) MachineError!machine.WorkProgress {
        return switch (parsing.*) {
            .encode_bytes => |*encoding| self.encodeBytes(evaluator, encoding),
            .encode_destination => |*encoding| self.encodeDestination(evaluator, encoding),
            .encode_package => |*encoding| self.encodePackage(evaluator, encoding),
            .allocate_tar => |*allocation| self.allocateTar(evaluator, allocation),
            .allocate_decoder => |*allocation| self.allocateDecoder(allocation),
            .decompress => |*decompression| self.decompress(evaluator, decompression),
            .verify => |*verification| self.verifyGzip(evaluator, verification),
            .allocate_slots => |*allocation| self.allocateSlots(allocation),
            .initialize_slots => |*initialization| self.initializeSlots(initialization),
        };
    }

    fn advanceActive(
        self: *UnpackDriver,
        evaluator: *Machine,
        active: *Active,
    ) MachineError!machine.WorkProgress {
        return switch (active.work) {
            .scanning => |*scanning| switch (scanning.work) {
                .tar_header => self.readTarHeader(evaluator, &active.archive, scanning),
                .insert_member => |*insertion| self.insertMember(
                    evaluator,
                    &active.archive,
                    scanning,
                    insertion,
                ),
                .parse_pax => |*pax| self.parsePaxRecord(evaluator, &active.archive, scanning, pax),
                .scan_pax => |*scan| self.scanPaxRecord(evaluator, &active.archive, scanning, scan),
                .trailing_zeroes => self.trailingZeroes(evaluator, &active.archive, scanning),
                .materialize_manifest => self.materializeManifest(evaluator, &active.archive, scanning),
                .materialize_manifest_text => |*materializer| self.materializeManifestText(
                    evaluator,
                    scanning,
                    materializer,
                ),
                .allocate_results => self.allocateResults(scanning),
                .materialize_paths => |*paths| self.materializePaths(evaluator, scanning, paths),
                .materialize_result => |*materialization| materializeResult(
                    active,
                    materialization,
                ),
                .release_result_inputs => |*release| try self.releaseResultInputs(
                    evaluator,
                    active,
                    release,
                ),
                .complete => unreachable,
            },
            .publication => |*publication| self.advancePublication(evaluator, &active.archive, publication),
        };
    }

    fn takeEncodeTarget(target: *EncodeTarget) EncodeTarget {
        return switch (target.*) {
            .unpack => |*cursor| .{ .unpack = .init(cursor.take()) },
            .inspect => |*cursor| .{ .inspect = .init(cursor.take()) },
            .install => |*install| .{ .install = .{
                .destination = .init(install.destination.take()),
                .package = .init(install.package.take()),
            } },
        };
    }

    fn takeEncodedTarget(target: *EncodedTarget) EncodedTarget {
        return switch (target.*) {
            .unpack => |*path| .{ .unpack = .init(path.take()) },
            .inspect => |*name| .{ .inspect = .init(name.take()) },
            .install => |*install| .{ .install = .{
                .destination = .init(install.destination.take()),
                .package = .init(install.package.take()),
            } },
        };
    }

    fn takeEncodedInputs(inputs: *EncodedInputs) EncodedInputs {
        return .{
            .bytes = .init(inputs.bytes.take()),
            .target = takeEncodedTarget(&inputs.target),
        };
    }

    fn takeArchive(archive: *Archive) Archive {
        return .{
            .bytes = .init(archive.bytes.take()),
            .target = takeEncodedTarget(&archive.target),
            .tar = .init(archive.tar.take()),
            .slots = .init(archive.slots.take()),
        };
    }

    /// The canonical path text the caller supplied: a root-relative path for
    /// extraction, a store key for installation.
    fn archiveDestination(archive: *Archive) []u8 {
        return switch (archive.target) {
            .unpack => |*path| path.borrow(),
            .install => |*install| install.destination.borrow(),
            .inspect => unreachable,
        };
    }

    /// The resolved publication parent and final entry name.
    fn destinationEntry(self: *UnpackDriver) @FieldType(fsport.Resolved, "entry") {
        return switch (self.destination.?) {
            .entry => |entry| entry,
            .directory => unreachable,
        };
    }

    /// The package value an install carries, for the failures raised against
    /// its staged tree. Only the install target reaches package validation.
    fn installPackageValue(self: *const UnpackDriver) Value {
        return switch (self.source.borrow()) {
            .install => |*install| install.package.borrow(),
            .inspect, .unpack => unreachable,
        };
    }

    fn archivePackageName(archive: *Archive) []u8 {
        return switch (archive.target) {
            .inspect => |*name| name.borrow(),
            .install => |*install| install.package.borrow(),
            .unpack => unreachable,
        };
    }

    fn operationMode(self: *const UnpackDriver) Mode {
        return switch (self.source.borrow()) {
            .unpack => .unpack,
            .inspect => .package_inspect,
            .install => .package_install,
        };
    }

    fn sourceDestination(self: *const UnpackDriver) Value {
        return switch (self.source.borrow()) {
            .unpack => |*source| source.destination.borrow(),
            .install => |*source| source.destination.borrow(),
            .inspect => unreachable,
        };
    }

    fn encodeBytes(
        self: *UnpackDriver,
        evaluator: *Machine,
        encoding: *@FieldType(Parsing, "encode_bytes"),
    ) MachineError!machine.WorkProgress {
        switch (encoding.byte.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.failAtIndex(
                .domain,
                "archive.unpack-tgz expects integers from 0 through 255",
                encoding.byte.borrow().invalid_index.?,
            ),
        }) {
            .pending => return .yielded,
            .complete => |bytes| {
                const target = takeEncodeTarget(&encoding.target);
                encoding.byte.deinit(evaluator.releaseDomain(), self.allocator);
                self.state = .{ .parsing = switch (target) {
                    .unpack => |path| .{ .encode_destination = .{
                        .bytes = .init(bytes),
                        .destination = path,
                        .package = null,
                    } },
                    .inspect => |package| .{ .encode_package = .{
                        .bytes = .init(bytes),
                        .destination = null,
                        .package = package,
                    } },
                    .install => |install| .{ .encode_destination = .{
                        .bytes = .init(bytes),
                        .destination = install.destination,
                        .package = install.package,
                    } },
                } };
                return .yielded;
            },
        }
    }

    fn encodeDestination(
        self: *UnpackDriver,
        evaluator: *Machine,
        encoding: *@FieldType(Parsing, "encode_destination"),
    ) MachineError!machine.WorkProgress {
        switch (encoding.destination.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "destination contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| {
                if (path.len == 0) {
                    self.allocator.free(path);
                    return self.failDomain(evaluator, "destination is empty");
                }
                switch (self.authority) {
                    .filesystem => |access| self.authorizeExtraction(evaluator, access, path) catch |err| {
                        self.allocator.free(path);
                        return err;
                    },
                    .package => |store_dir| {
                        if (!pkg_lock.validStoreKey(path)) {
                            self.allocator.free(path);
                            return self.failDomain(evaluator, "package destination is not a canonical store key");
                        }
                        const name = self.allocator.dupe(u8, path) catch |err| {
                            self.allocator.free(path);
                            return err;
                        };
                        self.destination = .{ .entry = .{
                            .parent = .{ .dir = store_dir, .owned = false },
                            .name = name,
                        } };
                    },
                    .none => unreachable,
                }
                const bytes = encoding.bytes.take();
                encoding.destination.deinit(evaluator.releaseDomain(), self.allocator);
                if (encoding.package) |*package| {
                    const package_cursor = package.take();
                    self.state = .{ .parsing = .{ .encode_package = .{
                        .bytes = .init(bytes),
                        .destination = .init(path),
                        .package = .init(package_cursor),
                    } } };
                } else {
                    self.state = .{ .parsing = .{ .allocate_tar = .{
                        .bytes = .init(bytes),
                        .target = .{ .unpack = .init(path) },
                    } } };
                }
                return .yielded;
            },
        }
    }

    /// Grammar, root, permission, and quota checks for extraction, before any
    /// archive byte is decompressed.
    fn authorizeExtraction(
        self: *UnpackDriver,
        evaluator: *Machine,
        access: *external.FilesystemAccess,
        path: []const u8,
    ) MachineError!void {
        const class = fsport.classifyPath(path) catch
            return self.failReason(evaluator, .domain, .invalid_path, "destination is not a canonical relative path");
        if (class == .root)
            return self.failReason(evaluator, .domain, .invalid_path, "destination must name a child entry, not the root");
        const root_value = self.source.borrow().unpack.root.borrow();
        const root = fsport.findRoot(access, root_value.symbol) orelse
            return self.failReason(evaluator, .domain, .unknown_root, "unknown filesystem root");
        if (!root.allows(.create))
            return self.failReason(evaluator, .domain, .denied, "filesystem root denies create");
        self.slot = fsport.reserveOperation(access) orelse
            return self.failReason(evaluator, .overflow, .limit, "filesystem operation limit reached");
    }

    fn encodePackage(
        self: *UnpackDriver,
        evaluator: *Machine,
        encoding: *@FieldType(Parsing, "encode_package"),
    ) MachineError!machine.WorkProgress {
        switch (encoding.package.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package name contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |name| {
                if (!validPackageName(name)) {
                    self.allocator.free(name);
                    return self.failDomain(evaluator, "package name is not canonical");
                }
                const bytes = encoding.bytes.take();
                encoding.package.deinit(evaluator.releaseDomain(), self.allocator);
                const target: EncodedTarget = if (encoding.destination) |*destination|
                    .{ .install = .{
                        .destination = .init(destination.take()),
                        .package = .init(name),
                    } }
                else
                    .{ .inspect = .init(name) };
                self.state = .{ .parsing = .{ .allocate_tar = .{
                    .bytes = .init(bytes),
                    .target = target,
                } } };
                return .yielded;
            },
        }
    }

    fn allocateTar(
        self: *UnpackDriver,
        evaluator: *Machine,
        allocation: *EncodedInputs,
    ) MachineError!machine.WorkProgress {
        const compressed = allocation.bytes.borrow().bytes();
        if (compressed.len < 18 or compressed[0] != 0x1f or compressed[1] != 0x8b)
            return self.failDomain(evaluator, "malformed gzip archive");
        const expected: usize = std.mem.readInt(u32, compressed[compressed.len - 4 ..][0..4], .little);
        if (expected > max_uncompressed_bytes)
            return self.failDomain(evaluator, "archive exceeds the 1 GiB uncompressed limit");
        const tar = try self.allocator.alloc(u8, expected);
        const inputs = takeEncodedInputs(allocation);
        self.state = .{ .parsing = .{ .allocate_decoder = .{
            .inputs = inputs,
            .tar = .init(tar),
        } } };
        return .yielded;
    }

    fn allocateDecoder(
        self: *UnpackDriver,
        allocation: *@FieldType(Parsing, "allocate_decoder"),
    ) MachineError!machine.WorkProgress {
        const decoder = try GzipDecoder.init(self.allocator, allocation.inputs.bytes.borrow().bytes());
        const inputs = takeEncodedInputs(&allocation.inputs);
        const tar = allocation.tar.take();
        self.state = .{ .parsing = .{ .decompress = .{
            .inputs = inputs,
            .tar = .init(tar),
            .decoder = .init(decoder),
        } } };
        return .yielded;
    }

    fn decompress(
        self: *UnpackDriver,
        evaluator: *Machine,
        decompression: *@FieldType(Parsing, "decompress"),
    ) MachineError!machine.WorkProgress {
        const output = decompression.tar.borrow();
        if (decompression.index != output.len) {
            const end = @min(decompression.index + work_quantum, output.len);
            const read = decompression.decoder.borrowMut().read(output[decompression.index..end]) catch
                return self.failDomain(evaluator, "malformed gzip archive");
            if (read == 0) return self.failDomain(evaluator, "gzip size does not match its footer");
            decompression.index += read;
            return .yielded;
        }
        var extra: [1]u8 = undefined;
        const read = decompression.decoder.borrowMut().read(&extra) catch
            return self.failDomain(evaluator, "malformed gzip archive");
        if (read != 0 or !decompression.decoder.borrow().consumedAllInput())
            return self.failDomain(evaluator, "gzip size does not match its footer");
        const inputs = takeEncodedInputs(&decompression.inputs);
        const tar = decompression.tar.take();
        decompression.decoder.deinit(evaluator.releaseDomain(), self.allocator);
        self.state = .{ .parsing = .{ .verify = .{
            .inputs = inputs,
            .tar = .init(tar),
        } } };
        return .yielded;
    }

    fn verifyGzip(
        self: *UnpackDriver,
        evaluator: *Machine,
        verification: *@FieldType(Parsing, "verify"),
    ) MachineError!machine.WorkProgress {
        const output = verification.tar.borrow();
        if (verification.index != output.len) {
            const end = @min(verification.index + work_quantum, output.len);
            verification.crc.update(output[verification.index..end]);
            verification.index = end;
            return .yielded;
        }
        const compressed = verification.inputs.bytes.borrow().bytes();
        const expected_crc = std.mem.readInt(u32, compressed[compressed.len - 8 ..][0..4], .little);
        if (verification.crc.final() != expected_crc)
            return self.failDomain(evaluator, "gzip checksum does not match its payload");
        const inputs = takeEncodedInputs(&verification.inputs);
        const tar = verification.tar.take();
        self.state = .{ .parsing = .{ .allocate_slots = .{
            .inputs = inputs,
            .tar = .init(tar),
        } } };
        return .yielded;
    }

    fn allocateSlots(
        self: *UnpackDriver,
        allocation: *@FieldType(Parsing, "allocate_slots"),
    ) MachineError!machine.WorkProgress {
        const slots = try self.allocator.alloc(?*Entry, member_slots);
        const inputs = takeEncodedInputs(&allocation.inputs);
        const tar = allocation.tar.take();
        self.state = .{ .parsing = .{ .initialize_slots = .{
            .inputs = inputs,
            .tar = .init(tar),
            .slots = .init(slots),
        } } };
        return .yielded;
    }

    fn initializeSlots(
        self: *UnpackDriver,
        initialization: *@FieldType(Parsing, "initialize_slots"),
    ) MachineError!machine.WorkProgress {
        const slots = initialization.slots.borrow();
        const end = @min(initialization.index + work_quantum, slots.len);
        @memset(slots[initialization.index..end], null);
        initialization.index = end;
        if (end != slots.len) return .yielded;

        var inputs = takeEncodedInputs(&initialization.inputs);
        const archive: Archive = .{
            .bytes = .init(inputs.bytes.take()),
            .target = takeEncodedTarget(&inputs.target),
            .tar = .init(initialization.tar.take()),
            .slots = .init(initialization.slots.take()),
        };
        self.state = .{ .active = .{
            .archive = archive,
            .work = .{ .scanning = .{} },
        } };
        return .yielded;
    }

    fn readTarHeader(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        scanning: *Scanning,
    ) MachineError!machine.WorkProgress {
        const context = &scanning.context;
        const tar = archive.tar.borrow();
        if (context.tar_offset == tar.len) {
            if (context.zero_blocks < 2) return self.failDomain(evaluator, "tar archive has no end marker");
            scanning.work = if (self.operationMode() == .unpack) .allocate_results else .materialize_manifest;
            return .yielded;
        }
        if (context.tar_offset + tar_block_bytes > tar.len)
            return self.failDomain(evaluator, "truncated tar header");
        const header: *const [tar_block_bytes]u8 = @ptrCast(tar[context.tar_offset..][0..tar_block_bytes]);
        if (allZero(header)) {
            if (context.pending_path != null or context.pending_size != null)
                return self.failDomain(evaluator, "tar extension has no following member");
            context.zero_blocks += 1;
            context.tar_offset += tar_block_bytes;
            if (context.zero_blocks == 2) scanning.work = .trailing_zeroes;
            return .yielded;
        }
        if (context.zero_blocks != 0) return self.failDomain(evaluator, "tar data follows an end marker");
        if (!validChecksum(header)) return self.failDomain(evaluator, "tar header checksum is invalid");
        const header_size = parseTarNumber(header[124..136]) orelse
            return self.failDomain(evaluator, "tar member size is malformed");
        const typeflag = header[156];
        const data_offset = context.tar_offset + tar_block_bytes;
        const header_data_end = std.math.add(usize, data_offset, std.math.cast(usize, header_size) orelse
            return self.failDomain(evaluator, "tar member size exceeds addressable memory")) catch
            return self.failDomain(evaluator, "tar member size overflows");
        const header_next = paddedTarOffset(header_data_end) orelse
            return self.failDomain(evaluator, "tar member padding overflows");
        if (header_next > tar.len) return self.failDomain(evaluator, "truncated tar member");

        if (typeflag == 'x') {
            scanning.work = .{ .parse_pax = .{
                .offset = data_offset,
                .end = header_data_end,
                .next_offset = header_next,
            } };
            return .yielded;
        }
        if (typeflag == 'L') {
            if (header_size == 0 or header_size > max_path_bytes + 1)
                return self.failDomain(evaluator, "GNU long name exceeds the path limit");
            if (context.pending_path) |*old| old.deinit(evaluator.releaseDomain(), self.allocator);
            const raw = tar[data_offset..header_data_end];
            const trimmed = std.mem.trimEnd(u8, raw, "\x00");
            context.pending_path = .init(try self.allocator.dupe(u8, trimmed));
            context.tar_offset = header_next;
            return .yielded;
        }

        const kind: EntryKind = switch (typeflag) {
            0, '0' => .file,
            '5' => .directory,
            '1', '2' => return self.failDomain(evaluator, "tar links are not permitted"),
            '3', '4', '6' => return self.failDomain(evaluator, "tar special nodes are not permitted"),
            else => return self.failDomain(evaluator, "tar member kind is unsupported"),
        };
        const effective_size = context.pending_size orelse header_size;
        context.pending_size = null;
        if (effective_size > max_uncompressed_bytes)
            return self.failDomain(evaluator, "tar member exceeds the 1 GiB uncompressed limit");
        if (kind == .directory and effective_size != 0)
            return self.failDomain(evaluator, "tar directory has file content");
        const effective_end = std.math.add(usize, data_offset, std.math.cast(usize, effective_size) orelse
            return self.failDomain(evaluator, "tar member size exceeds addressable memory")) catch
            return self.failDomain(evaluator, "tar member size overflows");
        const next_offset = paddedTarOffset(effective_end) orelse
            return self.failDomain(evaluator, "tar member padding overflows");
        if (next_offset > tar.len) return self.failDomain(evaluator, "truncated tar member");
        const path = try self.memberPath(context, header);
        errdefer self.allocator.free(path);
        if (!validMemberPath(path)) return self.failDomain(evaluator, "tar member path is unsafe");
        context.member_count += 1;
        if (context.member_count > max_members)
            return self.failDomain(evaluator, "archive exceeds the 100000 member limit");
        const entry = Entry{
            .path = path,
            .kind = kind,
            .data_offset = data_offset,
            .size = @intCast(effective_size),
        };
        if (self.operationMode() != .unpack) try self.validatePackageEntry(evaluator, archive, context, entry);
        if (kind == .file) context.file_count += 1;
        const hash = std.hash.Wyhash.hash(0, path);
        scanning.work = .{ .insert_member = .{
            .entry = entry,
            .next_offset = next_offset,
            .slot = @intCast(hash & (member_slots - 1)),
        } };
        return .yielded;
    }

    fn parsePaxRecord(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        scanning: *Scanning,
        pax: *Pax,
    ) MachineError!machine.WorkProgress {
        if (pax.offset == pax.end) {
            scanning.context.tar_offset = pax.next_offset;
            scanning.work = .tar_header;
            return .yielded;
        }
        const tar = archive.tar.borrow();
        var space = pax.offset;
        while (space != pax.end and tar[space] != ' ') : (space += 1) {
            if (space - pax.offset >= 20 or tar[space] < '0' or tar[space] > '9')
                return self.failDomain(evaluator, "PAX record length is malformed");
        }
        if (space == pax.end) return self.failDomain(evaluator, "PAX record is truncated");
        const record_len = std.fmt.parseInt(usize, tar[pax.offset..space], 10) catch
            return self.failDomain(evaluator, "PAX record length is malformed");
        if (record_len <= space - pax.offset + 2 or record_len > pax.end - pax.offset)
            return self.failDomain(evaluator, "PAX record length is invalid");
        const record_end = pax.offset + record_len;
        if (tar[record_end - 1] != '\n') return self.failDomain(evaluator, "PAX record lacks a newline");
        const moved = pax.*;
        scanning.work = .{ .scan_pax = .{
            .pax = moved,
            .record_end = record_end,
            .key_start = space + 1,
            .scan_offset = space + 1,
        } };
        return .yielded;
    }

    fn scanPaxRecord(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        scanning: *Scanning,
        scan: *@FieldType(ScanWork, "scan_pax"),
    ) MachineError!machine.WorkProgress {
        const tar = archive.tar.borrow();
        const payload_end = scan.record_end - 1;
        const end = @min(scan.scan_offset + work_quantum, payload_end);
        const equals_relative = std.mem.indexOfScalar(u8, tar[scan.scan_offset..end], '=') orelse {
            scan.scan_offset = end;
            if (end == payload_end) return self.failDomain(evaluator, "PAX record lacks a value");
            return .yielded;
        };
        const equals = equals_relative + scan.scan_offset;
        const key = tar[scan.key_start..equals];
        const field = tar[equals + 1 .. payload_end];
        if (std.mem.eql(u8, key, "path")) {
            if (field.len == 0 or field.len > max_path_bytes)
                return self.failDomain(evaluator, "PAX path exceeds the path limit");
            if (scanning.context.pending_path) |*old| old.deinit(evaluator.releaseDomain(), self.allocator);
            scanning.context.pending_path = .init(try self.allocator.dupe(u8, field));
        } else if (std.mem.eql(u8, key, "size")) {
            if (field.len == 0 or field.len > 20)
                return self.failDomain(evaluator, "PAX size is malformed");
            scanning.context.pending_size = std.fmt.parseInt(u64, field, 10) catch
                return self.failDomain(evaluator, "PAX size is malformed");
        }
        const pax = scan.pax;
        scanning.work = .{ .parse_pax = .{
            .offset = scan.record_end,
            .end = pax.end,
            .next_offset = pax.next_offset,
        } };
        return .yielded;
    }

    fn memberPath(
        self: *UnpackDriver,
        context: *ScanContext,
        header: *const [tar_block_bytes]u8,
    ) error{OutOfMemory}![]u8 {
        const raw = if (context.pending_path) |*owned| owned.take() else path: {
            const name = tarString(header[0..100]);
            const prefix = tarString(header[345..500]);
            break :path if (prefix.len == 0)
                try self.allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, name });
        };
        context.pending_path = null;
        defer self.allocator.free(raw);
        const normalized = std.mem.trimEnd(u8, raw, "/");
        return self.allocator.dupe(u8, normalized);
    }

    fn insertMember(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        scanning: *Scanning,
        insertion: *@FieldType(ScanWork, "insert_member"),
    ) MachineError!machine.WorkProgress {
        const entry = &insertion.entry;
        var remaining = work_quantum;
        while (remaining != 0) : (remaining -= 1) {
            const slot = &archive.slots.borrow()[insertion.slot];
            if (slot.*) |prior| {
                if (std.mem.eql(u8, prior.path, entry.path))
                    return self.failDomain(evaluator, "tar archive contains a duplicate member path");
                insertion.probes += 1;
                if (insertion.probes == member_slots)
                    return self.failDomain(evaluator, "tar member table is full");
                insertion.slot = (insertion.slot + 1) & (member_slots - 1);
                continue;
            }
            const stored = try self.entries.borrowMut().appendPtr(entry.*);
            slot.* = stored;
            scanning.context.tar_offset = insertion.next_offset;
            scanning.work = .tar_header;
            return .yielded;
        }
        return .yielded;
    }

    fn trailingZeroes(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        scanning: *Scanning,
    ) MachineError!machine.WorkProgress {
        const tar = archive.tar.borrow();
        const end = @min(scanning.context.tar_offset + work_quantum, tar.len);
        for (tar[scanning.context.tar_offset..end]) |byte| if (byte != 0)
            return self.failDomain(evaluator, "tar data follows its end marker");
        scanning.context.tar_offset = end;
        if (end != tar.len) return .yielded;
        scanning.work = if (self.operationMode() == .unpack) .allocate_results else .materialize_manifest;
        return .yielded;
    }

    fn validatePackageEntry(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        context: *ScanContext,
        entry: Entry,
    ) MachineError!void {
        if (entry.kind == .directory) return;
        if (std.mem.eql(u8, entry.path, package_seal_name))
            return self.failPackageMember(evaluator, archive, "package archive uses a reserved store member", entry.path);
        if (std.mem.eql(u8, entry.path, "ecl.pkg")) {
            if (context.manifest_data != null)
                return self.failPackageMember(
                    evaluator,
                    archive,
                    "package archive contains more than one root manifest",
                    entry.path,
                );
            context.manifest_data = .{ .offset = entry.data_offset, .size = entry.size };
            return;
        }
        if (std.mem.endsWith(u8, entry.path, ".eclmod"))
            return self.failPackageMember(evaluator, archive, "native package members are not permitted", entry.path);
    }

    fn materializeManifest(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        scanning: *Scanning,
    ) MachineError!machine.WorkProgress {
        const manifest = scanning.context.manifest_data orelse
            return self.failDomain(evaluator, "package archive has no root ecl.pkg manifest");
        const tar = archive.tar.borrow();
        scanning.work = .{ .materialize_manifest_text = .init(
            self.allocator,
            tar[manifest.offset .. manifest.offset + manifest.size],
        ) };
        return .yielded;
    }

    fn materializeManifestText(
        self: *UnpackDriver,
        evaluator: *Machine,
        scanning: *Scanning,
        materializer: *storage.Utf8Materializer,
    ) MachineError!machine.WorkProgress {
        return switch (materializer.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return self.failDomain(evaluator, "package root ecl.pkg is not valid UTF-8"),
        }) {
            .pending => .yielded,
            .complete => |text| result: {
                materializer.deinit();
                if (self.operationMode() == .package_inspect) {
                    scanning.work = .complete;
                    break :result .{ .output = text };
                }
                evaluator.releaseDomain().releaseValue(text);
                scanning.work = .allocate_results;
                break :result .yielded;
            },
        };
    }

    fn allocateResults(self: *UnpackDriver, scanning: *Scanning) MachineError!machine.WorkProgress {
        const values = try self.allocator.alloc(Value, scanning.context.file_count);
        scanning.work = .{ .materialize_paths = .{
            .inputs = .{ .values = values },
            .iterator = self.entries.borrow().iterator(),
        } };
        return .yielded;
    }

    fn materializePaths(
        self: *UnpackDriver,
        evaluator: *Machine,
        scanning: *Scanning,
        paths: *@FieldType(ScanWork, "materialize_paths"),
    ) MachineError!machine.WorkProgress {
        switch (paths.work) {
            .text => |*materializer| switch (materializer.advance(work_quantum) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return self.failDomain(evaluator, "tar member path is not valid UTF-8"),
            }) {
                .pending => return .yielded,
                .complete => |path_value| {
                    var completed = materializer.*;
                    paths.inputs.values[paths.inputs.built] = path_value;
                    paths.inputs.built += 1;
                    paths.work = .next;
                    completed.deinit();
                    return .yielded;
                },
            },
            .next => {},
        }
        var remaining = work_quantum;
        while (remaining != 0) : (remaining -= 1) {
            const entry = paths.iterator.next() orelse {
                const inputs = paths.inputs;
                scanning.work = .{ .materialize_result = .{
                    .inputs = inputs,
                    .materializer = .init(self.allocator, inputs.values),
                } };
                return .yielded;
            };
            if (entry.kind == .directory) continue;
            paths.work = .{ .text = .init(self.allocator, entry.path) };
            return .yielded;
        }
        return .yielded;
    }

    fn materializeResult(
        active: *Active,
        materialization: *@FieldType(ScanWork, "materialize_result"),
    ) MachineError!machine.WorkProgress {
        return switch (try materialization.materializer.advance(work_quantum)) {
            .pending => .yielded,
            .complete => |result| result: {
                var completed = materialization.materializer;
                const inputs = materialization.inputs;
                const next: ActiveWork = .{ .scanning = .{
                    .work = .{ .release_result_inputs = .{
                        .release = .{ .values = inputs.values, .built = inputs.built },
                        .result = result,
                    } },
                } };
                active.work = next;
                completed.deinit();
                break :result .yielded;
            },
        };
    }

    fn releaseResultInputs(
        self: *UnpackDriver,
        evaluator: *Machine,
        active: *Active,
        release: *@FieldType(ScanWork, "release_result_inputs"),
    ) MachineError!machine.WorkProgress {
        if (release.release.index != release.release.built) {
            evaluator.releaseDomain().releaseValue(
                release.release.values[release.release.index],
            );
            release.release.index += 1;
            return .yielded;
        }
        // The resolver is constructed before the input storage is released,
        // so an allocation failure leaves this state owning exactly what its
        // retirement releases.
        const publication: Publication = switch (self.authority) {
            .filesystem => |access| publication: {
                const root = fsport.findRoot(access, self.source.borrow().unpack.root.borrow().symbol).?;
                const resolver = fsport.Resolver.init(
                    self.allocator,
                    self.io.?,
                    root.dir(),
                    archiveDestination(&active.archive),
                    fsport.limitsOf(access),
                    .no_follow_final,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.PathTooLong => return self.failReason(evaluator, .overflow, .limit, "destination exceeds the resolver byte limit"),
                };
                break :publication .{ .resolve = .{ .result = release.result, .resolver = resolver } };
            },
            .package => .{ .destination_check = release.result },
            .none => unreachable,
        };
        self.allocator.free(release.release.values);
        active.work = .{ .publication = publication };
        return .yielded;
    }

    fn advancePublication(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        publication: *Publication,
    ) MachineError!machine.WorkProgress {
        const io = self.io.?;
        switch (publication.*) {
            .resolve => |*resolving| switch (try resolving.resolver.step()) {
                .pending => return .yielded,
                .failed => |reason| return self.failReason(
                    evaluator,
                    if (reason == .limit) .overflow else .io,
                    reason,
                    reason.message(),
                ),
                .complete => |resolved| {
                    resolving.resolver.deinit();
                    const result = resolving.result;
                    switch (resolved) {
                        .entry => self.destination = resolved,
                        .directory => |*handle| {
                            var closing = handle.*;
                            closing.close(io);
                            publication.* = .{ .destination_check = result };
                            return self.failReason(evaluator, .domain, .invalid_path, "destination must name a child entry, not the root");
                        },
                    }
                    publication.* = .{ .destination_check = result };
                    return .yielded;
                },
            },
            .destination_check => |result| {
                const target = self.destinationEntry();
                _ = target.parent.dir.statFile(io, target.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => {
                        publication.* = .{ .stage_path = result };
                        return .yielded;
                    },
                    else => return self.failIo(evaluator, "cannot inspect archive destination", err),
                };
                return self.failDestinationExists(evaluator, "archive destination already exists");
            },
            .stage_path => |result| {
                var name_buffer: [24]u8 = undefined;
                const name = fsport.stagingDirectoryName(io, &name_buffer);
                const path = try self.allocator.dupe(u8, name);
                publication.* = .{ .create_stage = .{
                    .result = result,
                    .path = .init(path),
                } };
            },
            .create_stage => |*staged| {
                const target = self.destinationEntry();
                target.parent.dir.createDir(io, staged.path.borrow(), .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        const result = staged.result;
                        staged.path.deinit(evaluator.releaseDomain(), self.allocator);
                        publication.* = .{ .stage_path = result };
                        return .yielded;
                    },
                    else => return self.failIo(evaluator, "cannot create archive staging directory", err),
                };
                const moved = staged.*;
                publication.* = .{ .open_stage = moved };
            },
            .open_stage => |*staged| {
                const target = self.destinationEntry();
                const directory = target.parent.dir.openDir(io, staged.path.borrow(), .{
                    .follow_symlinks = false,
                }) catch |err|
                    return self.failIo(evaluator, "cannot open archive staging directory", err);
                const moved = staged.*;
                publication.* = .{ .extract = .{
                    .staged = moved,
                    .dir = directory,
                    .iterator = self.entries.borrow().iterator(),
                } };
            },
            .extract => |*extraction| switch (extraction.work) {
                .next => {
                    const entry = extraction.iterator.next() orelse {
                        if (self.operationMode() == .package_install) {
                            const staged = extraction.staged;
                            const dir = extraction.dir;
                            const created_count = extraction.created_count;
                            publication.* = .{
                                .validate_package = .{
                                    .staged = staged,
                                    .dir = dir,
                                    .created_count = created_count,
                                    .catalog = null,
                                },
                            };
                            const validation = &publication.validate_package;
                            // The staged tree is validated through its own
                            // open handle; the catalog it produces is
                            // discarded, so relative artifact paths suffice.
                            validation.catalog = try evaluator.beginPackageTreeValidation(
                                io,
                                archivePackageName(archive),
                                ".",
                                validation.dir,
                                &validation.diagnostic,
                            );
                        } else {
                            extraction.dir.close(io);
                            const staged = extraction.staged;
                            const created_count = extraction.created_count;
                            publication.* = .{ .commit = .{
                                .staged = staged,
                                .created_count = created_count,
                            } };
                        }
                        return .yielded;
                    };
                    extraction.created_count += 1;
                    if (entry.kind == .directory) {
                        extraction.dir.createDirPath(io, entry.path) catch |err|
                            return self.failIo(evaluator, "cannot create archive directory", err);
                        return .yielded;
                    }
                    if (lastSlash(entry.path)) |slash|
                        extraction.dir.createDirPath(io, entry.path[0..slash]) catch |err|
                            return self.failIo(evaluator, "cannot create archive parent directory", err);
                    const file = extraction.dir.createFile(io, entry.path, .{ .exclusive = true }) catch |err|
                        return self.failIo(evaluator, "cannot create archive file", err);
                    extraction.work = .{ .file = .{ .entry = entry, .file = file } };
                },
                .file => |*file_state| {
                    if (file_state.written != file_state.entry.size) {
                        const end = @min(file_state.written + work_quantum, file_state.entry.size);
                        const source = archive.tar.borrow()[file_state.entry.data_offset + file_state.written .. file_state.entry.data_offset + end];
                        file_state.file.writePositionalAll(io, source, file_state.written) catch |err|
                            return self.failIo(evaluator, "cannot write archive file", err);
                        file_state.written = end;
                    } else {
                        file_state.file.close(io);
                        extraction.work = .next;
                    }
                },
            },
            .validate_package => |*validation| {
                const catalog_cursor = if (validation.catalog) |*catalog| catalog else unreachable;
                switch (catalog_cursor.advance(work_quantum) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => {
                        const message = validation.diagnostic;
                        defer if (message) |owned| self.allocator.free(owned);
                        validation.diagnostic = null;
                        const failure = evaluator.failFmt(
                            .domain,
                            "invalid package catalog: {s}",
                            .{message orelse "validation failed"},
                        );
                        evaluator.addErrorPackage(self.installPackageValue());
                        return failure;
                    },
                }) {
                    .pending => return .yielded,
                    .done => {},
                }
                var catalog = catalog_cursor.take() catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => return evaluator.failFmt(
                        .domain,
                        "invalid package catalog: {s}",
                        .{validation.diagnostic orelse "validation failed"},
                    ),
                };
                catalog.deinit();
                catalog_cursor.deinit();
                validation.catalog = null;
                const seal = validation.dir.createFile(
                    io,
                    package_seal_name,
                    .{ .exclusive = true },
                ) catch |err| return self.failIo(
                    evaluator,
                    "cannot create package archive seal",
                    err,
                );
                const staged = validation.staged;
                const dir = validation.dir;
                const created_count = validation.created_count;
                publication.* = .{ .seal = .{
                    .staged = staged,
                    .dir = dir,
                    .file = seal,
                    .created_count = created_count,
                } };
            },
            .seal => |*seal| {
                const compressed = archive.bytes.borrow().bytes();
                if (seal.written != compressed.len) {
                    const end = @min(seal.written + work_quantum, compressed.len);
                    seal.file.writePositionalAll(
                        io,
                        compressed[seal.written..end],
                        seal.written,
                    ) catch |err| return self.failIo(evaluator, "cannot write package archive seal", err);
                    seal.written = end;
                } else {
                    seal.file.sync(io) catch |err|
                        return self.failIo(evaluator, "cannot synchronize package archive seal", err);
                    seal.file.close(io);
                    seal.dir.close(io);
                    const staged = seal.staged;
                    const created_count = seal.created_count;
                    publication.* = .{ .commit = .{
                        .staged = staged,
                        .created_count = created_count,
                    } };
                }
            },
            .commit => |*commit_state| {
                const target = self.destinationEntry();
                fsport.renameNoReplace(
                    io,
                    target.parent.dir,
                    commit_state.staged.path.borrow(),
                    target.parent.dir,
                    target.name,
                ) catch |err| switch (err) {
                    error.PathAlreadyExists => return self.failDestinationExists(
                        evaluator,
                        "archive destination already exists",
                    ),
                    else => return self.failIo(evaluator, "cannot publish archive destination", err),
                };
                const result = commit_state.staged.result;
                const path = commit_state.staged.path.take();
                publication.* = .{ .published = .init(path) };
                return .{ .output = result };
            },
            .published => unreachable,
        }
        return .yielded;
    }

    fn failDomain(self: *UnpackDriver, evaluator: *Machine, message: []const u8) MachineError {
        _ = self;
        return evaluator.fail(.domain, message);
    }

    /// Authority and resolution failures carry the same provenance the `fs`
    /// words attach: the operation, root, path, and portable reason.
    fn failReason(
        self: *UnpackDriver,
        evaluator: *Machine,
        kind: machine.ErrorKind,
        reason: fsport.Reason,
        message: []const u8,
    ) MachineError {
        const operation = try intern.intern("unpack-tgz");
        const reason_symbol = try intern.intern(reason.symbol());
        const failure = evaluator.fail(kind, message);
        const unpack = self.source.borrow().unpack;
        evaluator.addErrorFilesystem(.{
            .operation = .{ .symbol = operation },
            .reason = .{ .symbol = reason_symbol },
            .target = .{ .single = .{ .root = unpack.root.borrow(), .path = unpack.destination.borrow() } },
        });
        return failure;
    }

    fn failPackageMember(
        self: *UnpackDriver,
        evaluator: *Machine,
        archive: *Archive,
        message: []const u8,
        member: []const u8,
    ) MachineError {
        _ = self;
        return evaluator.failFmt(
            .domain,
            "{s}: package `{s}`, member `{s}`",
            .{ message, archivePackageName(archive), member },
        );
    }

    fn failIo(self: *UnpackDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(.io, "{s}: {s}", .{ message, @errorName(err) });
        evaluator.addErrorPath(self.sourceDestination());
        return failure;
    }

    fn failIoName(self: *UnpackDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.sourceDestination());
        return failure;
    }

    fn failDestinationExists(
        self: *UnpackDriver,
        evaluator: *Machine,
        message: []const u8,
    ) MachineError {
        const failure = self.failIoName(evaluator, message);
        evaluator.addErrorDestinationExists();
        return failure;
    }

    fn beginPublicationRetirement(
        self: *UnpackDriver,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        active: *Active,
        publication: *Publication,
    ) void {
        const archive = takeArchive(&active.archive);
        switch (publication.*) {
            .resolve => |*resolving| {
                resolving.resolver.deinit();
                releases.releaseValue(resolving.result);
                self.state = .{ .cleanup_archive = archive };
            },
            // These abandon the publication before a staging directory
            // exists. Every other failing arm reaches cleanup through
            // rollback, which removes the stage root first.
            .destination_check, .stage_path => |result| {
                releases.releaseValue(result);
                self.state = .{ .cleanup_archive = archive };
            },
            .create_stage => |*staged| {
                releases.releaseValue(staged.result);
                staged.path.deinit(releases, allocator);
                self.state = .{ .cleanup_archive = archive };
            },
            .open_stage => |*staged| {
                releases.releaseValue(staged.result);
                const path = staged.path.take();
                self.state = .{ .rollback_reopen = .{
                    .archive = archive,
                    .context = .{
                        .path = .init(path),
                    },
                    .plan = .{ .entries = 0 },
                } };
            },
            .extract => |*extraction| {
                switch (extraction.work) {
                    .file => |file_state| file_state.file.close(self.io.?),
                    .next => {},
                }
                releases.releaseValue(extraction.staged.result);
                const path = extraction.staged.path.take();
                const context: RollbackContext = .{
                    .path = .init(path),
                };
                const dir = extraction.dir;
                self.state = .{ .rollback = .{
                    .archive = archive,
                    .context = context,
                    .dir = dir,
                    .work = rollbackEntries(self, extraction.created_count),
                } };
            },
            .validate_package => |*validation| {
                // The cursor holds the staged tree's open directory and walk
                // across steps, so abandoning this state has to release them.
                if (validation.catalog) |*catalog| catalog.deinit();
                if (validation.diagnostic) |message| self.allocator.free(message);
                validation.diagnostic = null;
                releases.releaseValue(validation.staged.result);
                const path = validation.staged.path.take();
                self.state = .{ .rollback = .{
                    .archive = archive,
                    .context = .{ .path = .init(path) },
                    .dir = validation.dir,
                    .work = rollbackEntries(self, validation.created_count),
                } };
            },
            .seal => |*seal| {
                seal.file.close(self.io.?);
                releases.releaseValue(seal.staged.result);
                const path = seal.staged.path.take();
                const context: RollbackContext = .{
                    .path = .init(path),
                };
                const dir = seal.dir;
                self.state = .{ .rollback = .{
                    .archive = archive,
                    .context = context,
                    .dir = dir,
                    .work = .{ .seal = seal.created_count },
                } };
            },
            .commit => |*commit_state| {
                releases.releaseValue(commit_state.staged.result);
                const path = commit_state.staged.path.take();
                self.state = .{ .rollback_reopen = .{
                    .archive = archive,
                    .context = .{
                        .path = .init(path),
                    },
                    .plan = if (self.operationMode() == .package_install)
                        .{ .seal_then_entries = commit_state.created_count }
                    else
                        .{ .entries = commit_state.created_count },
                } };
            },
            .published => |*path| {
                path.deinit(releases, allocator);
                self.state = .{ .cleanup_archive = archive };
            },
        }
    }

    fn rollbackEntries(self: *UnpackDriver, created_count: usize) RollbackWork {
        return .{ .skip = .{
            .iterator = self.entries.borrow().reverseIterator(),
            .remaining = self.entries.borrow().count - created_count,
        } };
    }

    fn advanceRollbackReopen(
        self: *UnpackDriver,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        reopening: *@FieldType(State, "rollback_reopen"),
    ) bool {
        const context = &reopening.context;
        const parent = self.destinationEntry().parent.dir;
        const directory = parent.openDir(self.io.?, context.path.borrow(), .{ .follow_symlinks = false }) catch |open_err| {
            observeCleanupError("reopen the stage", open_err);
            parent.deleteDir(self.io.?, context.path.borrow()) catch |err|
                observeCleanupError("remove an unopened stage", err);
            context.path.deinit(releases, allocator);
            const archive = takeArchive(&reopening.archive);
            self.state = .{ .cleanup_archive = archive };
            return false;
        };
        const moved = context.*;
        const work = switch (reopening.plan) {
            .entries => |created_count| rollbackEntries(self, created_count),
            .seal_then_entries => |created_count| RollbackWork{ .seal = created_count },
        };
        const archive = takeArchive(&reopening.archive);
        self.state = .{ .rollback = .{
            .archive = archive,
            .context = moved,
            .dir = directory,
            .work = work,
        } };
        return false;
    }

    fn advanceRollback(
        self: *UnpackDriver,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        rollback: *@FieldType(State, "rollback"),
    ) bool {
        switch (rollback.work) {
            .seal => |created_count| {
                rollback.dir.deleteFile(self.io.?, package_seal_name) catch |err|
                    observeCleanupError("remove the package archive seal", err);
                rollback.work = rollbackEntries(self, created_count);
            },
            .skip => |*skip| {
                if (skip.remaining != 0) {
                    _ = skip.iterator.next();
                    skip.remaining -= 1;
                } else {
                    const iterator = skip.iterator;
                    rollback.work = .{ .entries = iterator };
                }
            },
            .entries => |*iterator| {
                const entry = iterator.next() orelse {
                    rollback.work = .root;
                    return false;
                };
                switch (entry.kind) {
                    .file => rollback.dir.deleteFile(self.io.?, entry.path) catch |err|
                        observeCleanupError("remove a staged file", err),
                    .directory => rollback.dir.deleteDir(self.io.?, entry.path) catch |err|
                        observeCleanupError("remove a staged directory", err),
                }
                if (lastSlash(entry.path)) |end| {
                    const moved = iterator.*;
                    rollback.work = .{ .parents = .{
                        .iterator = moved,
                        .entry = entry,
                        .end = end,
                    } };
                }
            },
            .parents => |*parents| {
                rollback.dir.deleteDir(self.io.?, parents.entry.path[0..parents.end]) catch |err|
                    observeCleanupError("remove an implicit parent directory", err);
                if (lastSlash(parents.entry.path[0..parents.end])) |end| {
                    parents.end = end;
                } else {
                    const iterator = parents.iterator;
                    rollback.work = .{ .entries = iterator };
                }
            },
            .root => {
                rollback.dir.close(self.io.?);
                self.destinationEntry().parent.dir.deleteDir(self.io.?, rollback.context.path.borrow()) catch |err|
                    observeCleanupError("remove the stage root", err);
                rollback.context.path.deinit(releases, allocator);
                const archive = takeArchive(&rollback.archive);
                self.state = .{ .cleanup_archive = archive };
            },
        }
        return false;
    }

    fn retireEncodeTarget(
        target: *EncodeTarget,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (target.*) {
            .unpack, .inspect => |*cursor| cursor.deinit(releases, allocator),
            .install => |*install| {
                install.destination.deinit(releases, allocator);
                install.package.deinit(releases, allocator);
            },
        }
    }

    fn retireEncodedTarget(
        target: *EncodedTarget,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (target.*) {
            .unpack, .inspect => |*text| text.deinit(releases, allocator),
            .install => |*install| {
                install.destination.deinit(releases, allocator);
                install.package.deinit(releases, allocator);
            },
        }
    }

    fn retireEncodedInputs(
        inputs: *EncodedInputs,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        inputs.bytes.deinit(releases, allocator);
        retireEncodedTarget(&inputs.target, releases, allocator);
    }

    fn retireArchive(
        archive: *Archive,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        archive.slots.deinit(releases, allocator);
        archive.tar.deinit(releases, allocator);
        archive.bytes.deinit(releases, allocator);
        retireEncodedTarget(&archive.target, releases, allocator);
    }

    fn retireScanning(
        scanning: *Scanning,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) ScanningRetirement {
        const retirement: ScanningRetirement = switch (scanning.work) {
            .insert_member => |insertion| result: {
                allocator.free(insertion.entry.path);
                break :result .plain;
            },
            .materialize_manifest_text => |*materializer| result: {
                materializer.retire(releases);
                break :result .plain;
            },
            .materialize_paths => |*paths| result: {
                switch (paths.work) {
                    .text => |*materializer| materializer.retire(releases),
                    .next => {},
                }
                break :result .{ .results = .{
                    .values = paths.inputs.values,
                    .built = paths.inputs.built,
                } };
            },
            .materialize_result => |*materialization| result: {
                materialization.materializer.retire(releases);
                break :result .{ .results = .{
                    .values = materialization.inputs.values,
                    .built = materialization.inputs.built,
                } };
            },
            .release_result_inputs => |release| result: {
                releases.releaseValue(release.result);
                break :result .{ .results = release.release };
            },
            else => .plain,
        };
        if (scanning.context.pending_path) |*path| path.deinit(releases, allocator);
        scanning.context.pending_path = null;
        return retirement;
    }

    fn retireParsing(
        parsing: *Parsing,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (parsing.*) {
            .encode_bytes => |*encoding| {
                encoding.byte.deinit(releases, allocator);
                retireEncodeTarget(&encoding.target, releases, allocator);
            },
            .encode_destination => |*encoding| {
                encoding.bytes.deinit(releases, allocator);
                encoding.destination.deinit(releases, allocator);
                if (encoding.package) |*package| package.deinit(releases, allocator);
            },
            .encode_package => |*encoding| {
                encoding.bytes.deinit(releases, allocator);
                if (encoding.destination) |*destination| destination.deinit(releases, allocator);
                encoding.package.deinit(releases, allocator);
            },
            .allocate_tar => |*allocation| retireEncodedInputs(allocation, releases, allocator),
            .allocate_decoder => |*allocation| {
                retireEncodedInputs(&allocation.inputs, releases, allocator);
                allocation.tar.deinit(releases, allocator);
            },
            .decompress => |*decompression| {
                retireEncodedInputs(&decompression.inputs, releases, allocator);
                decompression.tar.deinit(releases, allocator);
                decompression.decoder.deinit(releases, allocator);
            },
            .verify => |*verification| {
                retireEncodedInputs(&verification.inputs, releases, allocator);
                verification.tar.deinit(releases, allocator);
            },
            .allocate_slots => |*allocation| {
                retireEncodedInputs(&allocation.inputs, releases, allocator);
                allocation.tar.deinit(releases, allocator);
            },
            .initialize_slots => |*initialization| {
                retireEncodedInputs(&initialization.inputs, releases, allocator);
                initialization.tar.deinit(releases, allocator);
                initialization.slots.deinit(releases, allocator);
            },
        }
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *UnpackDriver,
    ) bool {
        switch (self.state) {
            .parsing => |*parsing| {
                retireParsing(parsing, releases, allocator);
                self.state = .{ .cleanup = .{
                    .entries = self.entries.borrow().reverseIterator(),
                } };
                return false;
            },
            .active => |*active| {
                switch (active.work) {
                    .scanning => |*scanning| {
                        const retirement = retireScanning(scanning, releases, allocator);
                        const archive = takeArchive(&active.archive);
                        self.state = switch (retirement) {
                            .plain => .{ .cleanup_archive = archive },
                            .results => |release| .{ .cleanup_archive_with_results = .{
                                .archive = archive,
                                .release = release,
                            } },
                        };
                    },
                    .publication => |*publication| self.beginPublicationRetirement(
                        releases,
                        allocator,
                        active,
                        publication,
                    ),
                }
                return false;
            },
            .rollback_reopen => |*reopening| return self.advanceRollbackReopen(
                releases,
                allocator,
                reopening,
            ),
            .rollback => |*rollback| return self.advanceRollback(releases, allocator, rollback),
            .cleanup_archive => |*archive| {
                retireArchive(archive, releases, allocator);
                self.state = .{ .cleanup = .{
                    .entries = self.entries.borrow().reverseIterator(),
                } };
                return false;
            },
            .cleanup_archive_with_results => |*cleanup| {
                retireArchive(&cleanup.archive, releases, allocator);
                const release = cleanup.release;
                self.state = .{ .cleanup = .{ .entries_with_results = .{
                    .iterator = self.entries.borrow().reverseIterator(),
                    .release = release,
                } } };
                return false;
            },
            .cleanup => |*cleanup| switch (cleanup.*) {
                .entries => |*iterator| {
                    if (iterator.next()) |entry| {
                        allocator.free(entry.path);
                        return false;
                    }
                    self.state = .{ .cleanup = .finish };
                    return false;
                },
                .entries_with_results => |*entries| {
                    if (entries.iterator.next()) |entry| {
                        allocator.free(entry.path);
                        return false;
                    }
                    const release = entries.release;
                    self.state = .{ .cleanup = .{ .results = release } };
                    return false;
                },
                .results => |*results| {
                    if (results.index != results.built) {
                        releases.releaseValue(results.values[results.index]);
                        results.index += 1;
                        return false;
                    }
                    allocator.free(results.values);
                    self.state = .{ .cleanup = .finish };
                    return false;
                },
                .finish => {},
            },
        }
        self.bytes_value.deinit(releases, allocator);
        self.source.deinit(releases, allocator);
        self.entries.deinit(releases, allocator);
        if (self.destination) |*destination| destination.deinit(allocator, self.io.?);
        if (self.slot) |*slot| slot.release();
        allocator.destroy(self);
        return true;
    }
};

fn allZero(block: *const [tar_block_bytes]u8) bool {
    for (block) |byte| if (byte != 0) return false;
    return true;
}

fn validChecksum(block: *const [tar_block_bytes]u8) bool {
    const expected = parseTarNumber(block[148..156]) orelse return false;
    var sum: u64 = 0;
    for (block, 0..) |byte, index| sum += if (index >= 148 and index < 156) ' ' else byte;
    return sum == expected;
}

fn parseTarNumber(field: []const u8) ?u64 {
    if (field.len == 0) return null;
    if (field[0] == 0x80) {
        if (field.len > 8) for (field[1 .. field.len - 8]) |byte| if (byte != 0) return null;
        return std.mem.readInt(u64, field[field.len - 8 ..][0..8], .big);
    }
    if (field[0] == 0xff) return null;
    const trimmed = std.mem.trim(u8, field, " \x00");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch null;
}

fn tarString(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

fn paddedTarOffset(data_end: usize) ?usize {
    const remainder = data_end % tar_block_bytes;
    if (remainder == 0) return data_end;
    return std.math.add(usize, data_end, tar_block_bytes - remainder) catch null;
}

fn validMemberPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes or !std.unicode.utf8ValidateSlice(path)) return false;
    if (path[0] == '/' or path[0] == '\\' or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (components.next()) |component| {
        count += 1;
        if (count > 256 or component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..") or
            std.mem.indexOfScalar(u8, component, '\\') != null)
            return false;
    }
    return true;
}

fn validPackageName(name: []const u8) bool {
    if (name.len == 0) return false;
    var segments = std.mem.splitScalar(u8, name, '.');
    while (segments.next()) |segment| {
        if (segment.len == 0 or segment[0] < 'a' or segment[0] > 'z') return false;
        for (segment[1..]) |byte| if (!((byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '-')) return false;
    }
    return true;
}

fn packageOwns(package: []const u8, module_name: []const u8) bool {
    if (std.mem.eql(u8, package, module_name)) return true;
    return module_name.len > package.len and
        std.mem.startsWith(u8, module_name, package) and
        module_name[package.len] == '.';
}

fn lastSlash(path: []const u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, path, '/');
}
