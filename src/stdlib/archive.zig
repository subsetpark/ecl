//! Exact hashing and hostile-input-safe package archive extraction.
//!
//! Binary payloads remain ordinary ECL integer lists. The encoder borrows an
//! internal byte leaf when available and validates any equivalent list, so the
//! module never assigns language semantics to a storage representation.
const std = @import("std");
const builtin = @import("builtin");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const env = @import("../env.zig");
const machine = @import("../machine.zig");
const storage = @import("../kernel_storage.zig");
const poll = @import("../poll.zig");

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
        .doc = "( bytes destination -- regular-file-paths ) Validate and atomically " ++
            "extract a gzip tar into a previously absent destination.",
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
    try evaluator.require(2);
    var destination = try evaluator.popValue();
    errdefer destination.deinit();
    if (!destination.borrow().isString()) return evaluator.typeError("a string destination");
    var bytes_value = try evaluator.popValue();
    errdefer bytes_value.deinit();
    if (bytes_value.borrow() != .list) return evaluator.typeError("an integer byte list");
    const io = evaluator.unit.inherited.host_io orelse {
        const failure = evaluator.fail(.io, "archive extraction is unavailable");
        evaluator.addErrorPath(destination.borrow());
        return failure;
    };
    const byte_encoder = storage.ByteVectorEncoder.init(evaluator.allocator(), bytes_value.borrow());
    const path_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), destination.borrow());
    const entries = poll.ChunkList(Entry).init(evaluator.allocator());
    try evaluator.startDriver(UnpackDriver{
        .allocator = evaluator.allocator(),
        .io = io,
        .mode = .unpack,
        .bytes_value = .init(bytes_value.take()),
        .destination_value = .init(destination.take()),
        .byte_encoder = .init(byte_encoder),
        .path_encoder = .init(path_encoder),
        .entries = .init(entries),
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
        .mode = .package_inspect,
        .bytes_value = .init(bytes_value.take()),
        .package_value = .init(package.take()),
        .byte_encoder = .init(byte_encoder),
        .package_encoder = .init(package_encoder),
        .entries = .init(entries),
    });
}

/// Package installation repeats the package scan at the mutation sink before
/// staging any member. The active word remains pkg.store.install.
pub fn installPackage(evaluator: *Machine) MachineError!void {
    try evaluator.require(3);
    var destination = try evaluator.popValue();
    errdefer destination.deinit();
    if (!destination.borrow().isString()) return evaluator.typeError("a string destination");
    var package = try evaluator.popValue();
    errdefer package.deinit();
    if (!package.borrow().isString()) return evaluator.typeError("a string package name");
    var bytes_value = try evaluator.popValue();
    errdefer bytes_value.deinit();
    if (bytes_value.borrow() != .list) return evaluator.typeError("an integer byte list");
    const io = evaluator.unit.inherited.host_io orelse {
        const failure = evaluator.fail(.io, "package installation is unavailable");
        evaluator.addErrorPath(destination.borrow());
        return failure;
    };
    const byte_encoder = storage.ByteVectorEncoder.init(evaluator.allocator(), bytes_value.borrow());
    const package_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), package.borrow());
    const path_encoder = storage.ToUtf8Cursor.init(evaluator.allocator(), destination.borrow());
    const entries = poll.ChunkList(Entry).init(evaluator.allocator());
    try evaluator.startDriver(UnpackDriver{
        .allocator = evaluator.allocator(),
        .io = io,
        .mode = .package_install,
        .bytes_value = .init(bytes_value.take()),
        .package_value = .init(package.take()),
        .destination_value = .init(destination.take()),
        .byte_encoder = .init(byte_encoder),
        .package_encoder = .init(package_encoder),
        .path_encoder = .init(path_encoder),
        .entries = .init(entries),
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

const ParsePhase = enum {
    encode_bytes,
    encode_destination,
    encode_package,
    allocate_output,
    decompress,
    verify_gzip,
    initialize_slots,
    tar_header,
    insert_member,
    parse_pax,
    scan_pax,
    trailing_zeroes,
    materialize_manifest,
    allocate_results,
    materialize_paths,
    materialize_result,
};

const Mode = enum { unpack, package_inspect, package_install };

var next_stage_identity: std.atomic.Value(u64) = .init(1);

const darwin = struct {
    extern "c" fn renameatx_np(
        old_dir: c_int,
        old_path: [*:0]const u8,
        new_dir: c_int,
        new_path: [*:0]const u8,
        flags: c_uint,
    ) c_int;
};

pub fn renamePreserve(
    parent: std.Io.Dir,
    old_name: []const u8,
    new_name: []const u8,
    io: std.Io,
) std.Io.Dir.RenamePreserveError!void {
    if (comptime builtin.os.tag == .linux or builtin.os.tag == .windows)
        return parent.renamePreserve(old_name, parent, new_name, io);
    if (comptime builtin.os.tag.isDarwin()) {
        const old_path = try std.posix.toPosixPath(old_name);
        const new_path = try std.posix.toPosixPath(new_name);
        while (true) switch (std.c.errno(darwin.renameatx_np(
            parent.handle,
            &old_path,
            parent.handle,
            &new_path,
            0x00000004,
        ))) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .EXIST, .NOTEMPTY => return error.PathAlreadyExists,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .ISDIR => return error.IsDir,
            .BUSY => return error.FileBusy,
            .DQUOT => return error.DiskQuota,
            .LOOP => return error.SymLinkLoop,
            .MLINK => return error.LinkQuotaExceeded,
            .NOSPC => return error.NoSpaceLeft,
            .ROFS => return error.ReadOnlyFileSystem,
            .XDEV => return error.CrossDevice,
            else => return error.Unexpected,
        };
    }
    return error.OperationUnsupported;
}

fn observeCleanupError(action: []const u8, err: anyerror) void {
    switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => std.log.err("archive rollback could not {s}: {s}", .{ action, @errorName(err) }),
    }
}

const UnpackDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    io: ?std.Io,
    mode: Mode,
    bytes_value: heap.Owned(Value),
    package_value: ?heap.Owned(Value) = null,
    destination_value: ?heap.Owned(Value) = null,
    byte_encoder: heap.Owned(storage.ByteVectorEncoder),
    package_encoder: ?heap.Owned(storage.ToUtf8Cursor) = null,
    path_encoder: ?heap.Owned(storage.ToUtf8Cursor) = null,
    entries: heap.Owned(EntryList),
    state: State = .{ .parsing = .encode_bytes },

    bytes: ?heap.Owned(storage.ByteVector) = null,
    destination: ?heap.Owned([]u8) = null,
    package_name: ?heap.Owned([]u8) = null,
    decoder: ?heap.Owned(GzipDecoder) = null,
    tar: ?heap.Owned([]u8) = null,
    output_index: usize = 0,
    gzip_checked_index: usize = 0,
    gzip_crc: std.hash.crc.Crc32 = .init(),

    slots: ?heap.Owned([]?*Entry) = null,
    slots_initialized: usize = 0,
    tar_offset: usize = 0,
    zero_blocks: u2 = 0,
    member_count: usize = 0,
    file_count: usize = 0,
    pending_path: ?heap.Owned([]u8) = null,
    pending_size: ?u64 = null,
    pending_entry: ?Entry = null,
    pending_next_offset: usize = 0,
    pending_hash: u64 = 0,
    pending_slot: usize = 0,
    pending_probes: usize = 0,
    pax_offset: usize = 0,
    pax_end: usize = 0,
    pax_next_offset: usize = 0,
    pax_record_end: usize = 0,
    pax_key_start: usize = 0,
    pax_scan_offset: usize = 0,
    manifest_data: ?struct { offset: usize, size: usize } = null,

    result_values: ?[]Value = null,
    result_values_built: usize = 0,
    result_iterator: ?EntryList.Iterator = null,
    current_result_path: ?[]const u8 = null,
    text_materializer: ?storage.Utf8Materializer = null,
    result_materializer: ?storage.ValueMaterializer = null,
    free_iterator: ?EntryList.ReverseIterator = null,
    result_release_index: usize = 0,

    const Staged = struct {
        result: Value,
        path: heap.Owned([]u8),
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
    const RollbackContext = struct {
        path: heap.Owned([]u8),
        created_count: usize,
        seal_created: bool,
    };
    const RollbackWork = union(enum) {
        seal,
        skip: struct { iterator: EntryList.ReverseIterator, remaining: usize },
        entries: EntryList.ReverseIterator,
        parents: struct {
            iterator: EntryList.ReverseIterator,
            entry: *const Entry,
            end: usize,
        },
        root,
    };
    const State = union(enum) {
        parsing: ParsePhase,
        publication: Publication,
        rollback_reopen: RollbackContext,
        rollback: struct {
            context: RollbackContext,
            dir: std.Io.Dir,
            work: RollbackWork,
        },
        cleanup_archive,
    };

    pub fn advance(evaluator: *Machine, self: *UnpackDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .parsing => |phase| switch (phase) {
                .encode_bytes => self.encodeBytes(evaluator),
                .encode_destination => self.encodeDestination(evaluator),
                .encode_package => self.encodePackage(evaluator),
                .allocate_output => self.allocateOutput(evaluator),
                .decompress => self.decompress(evaluator),
                .verify_gzip => self.verifyGzip(evaluator),
                .initialize_slots => self.initializeSlots(),
                .tar_header => self.readTarHeader(evaluator),
                .insert_member => self.insertMember(evaluator),
                .parse_pax => self.parsePaxRecord(evaluator),
                .scan_pax => self.scanPaxRecord(evaluator),
                .trailing_zeroes => self.trailingZeroes(evaluator),
                .materialize_manifest => self.materializeManifest(evaluator),
                .allocate_results => self.allocateResults(),
                .materialize_paths => self.materializePaths(evaluator),
                .materialize_result => self.materializeResult(),
            },
            .publication => |*publication| self.advancePublication(evaluator, publication),
            .rollback_reopen, .rollback, .cleanup_archive => unreachable,
        };
    }

    fn encodeBytes(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.byte_encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.failAtIndex(
                .domain,
                "archive.unpack-tgz expects integers from 0 through 255",
                self.byte_encoder.borrow().invalid_index.?,
            ),
        }) {
            .pending => return .yielded,
            .complete => |bytes| {
                self.bytes = .init(bytes);
                self.state = .{ .parsing = switch (self.mode) {
                    .unpack, .package_install => .encode_destination,
                    .package_inspect => .encode_package,
                } };
                return .yielded;
            },
        }
    }

    fn encodeDestination(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.path_encoder.?.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "destination contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |path| {
                if (path.len == 0) {
                    self.allocator.free(path);
                    return self.failDomain(evaluator, "destination is empty");
                }
                self.destination = .init(path);
                self.state = .{ .parsing = if (self.mode == .package_install)
                    .encode_package
                else
                    .allocate_output };
                return .yielded;
            },
        }
    }

    fn encodePackage(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.package_encoder.?.borrowMut().advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failDomain(evaluator, "package name contains an invalid Unicode scalar"),
        }) {
            .pending => return .yielded,
            .complete => |name| {
                if (!validPackageName(name)) {
                    self.allocator.free(name);
                    return self.failDomain(evaluator, "package name is not canonical");
                }
                self.package_name = .init(name);
                self.state = .{ .parsing = .allocate_output };
                return .yielded;
            },
        }
    }

    fn allocateOutput(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const compressed = self.bytes.?.borrow().bytes();
        if (compressed.len < 18 or compressed[0] != 0x1f or compressed[1] != 0x8b)
            return self.failDomain(evaluator, "malformed gzip archive");
        const expected: usize = std.mem.readInt(u32, compressed[compressed.len - 4 ..][0..4], .little);
        if (expected > max_uncompressed_bytes)
            return self.failDomain(evaluator, "archive exceeds the 1 GiB uncompressed limit");
        self.tar = .init(try self.allocator.alloc(u8, expected));
        self.decoder = .init(try .init(self.allocator, compressed));
        self.state = .{ .parsing = .decompress };
        return .yielded;
    }

    fn decompress(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const output = self.tar.?.borrow();
        if (self.output_index != output.len) {
            const end = @min(self.output_index + work_quantum, output.len);
            const read = self.decoder.?.borrowMut().read(output[self.output_index..end]) catch
                return self.failDomain(evaluator, "malformed gzip archive");
            if (read == 0) return self.failDomain(evaluator, "gzip size does not match its footer");
            self.output_index += read;
            return .yielded;
        }
        var extra: [1]u8 = undefined;
        const read = self.decoder.?.borrowMut().read(&extra) catch
            return self.failDomain(evaluator, "malformed gzip archive");
        if (read != 0 or !self.decoder.?.borrow().consumedAllInput())
            return self.failDomain(evaluator, "gzip size does not match its footer");
        self.state = .{ .parsing = .verify_gzip };
        return .yielded;
    }

    fn verifyGzip(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const output = self.tar.?.borrow();
        if (self.gzip_checked_index != output.len) {
            const end = @min(self.gzip_checked_index + work_quantum, output.len);
            self.gzip_crc.update(output[self.gzip_checked_index..end]);
            self.gzip_checked_index = end;
            return .yielded;
        }
        const compressed = self.bytes.?.borrow().bytes();
        const expected_crc = std.mem.readInt(u32, compressed[compressed.len - 8 ..][0..4], .little);
        if (self.gzip_crc.final() != expected_crc)
            return self.failDomain(evaluator, "gzip checksum does not match its payload");
        self.slots = .init(try self.allocator.alloc(?*Entry, member_slots));
        self.state = .{ .parsing = .initialize_slots };
        return .yielded;
    }

    fn initializeSlots(self: *UnpackDriver) MachineError!machine.WorkProgress {
        const slots = self.slots.?.borrow();
        const end = @min(self.slots_initialized + work_quantum, slots.len);
        @memset(slots[self.slots_initialized..end], null);
        self.slots_initialized = end;
        if (end != slots.len) return .yielded;
        self.state = .{ .parsing = .tar_header };
        return .yielded;
    }

    fn readTarHeader(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const tar = self.tar.?.borrow();
        if (self.tar_offset == tar.len) {
            if (self.zero_blocks < 2) return self.failDomain(evaluator, "tar archive has no end marker");
            self.state = .{ .parsing = if (self.mode == .unpack)
                .allocate_results
            else
                .materialize_manifest };
            return .yielded;
        }
        if (self.tar_offset + tar_block_bytes > tar.len)
            return self.failDomain(evaluator, "truncated tar header");
        const header: *const [tar_block_bytes]u8 = @ptrCast(tar[self.tar_offset..][0..tar_block_bytes]);
        if (allZero(header)) {
            if (self.pending_path != null or self.pending_size != null)
                return self.failDomain(evaluator, "tar extension has no following member");
            self.zero_blocks += 1;
            self.tar_offset += tar_block_bytes;
            if (self.zero_blocks == 2) self.state = .{ .parsing = .trailing_zeroes };
            return .yielded;
        }
        if (self.zero_blocks != 0) return self.failDomain(evaluator, "tar data follows an end marker");
        if (!validChecksum(header)) return self.failDomain(evaluator, "tar header checksum is invalid");
        const header_size = parseTarNumber(header[124..136]) orelse
            return self.failDomain(evaluator, "tar member size is malformed");
        const typeflag = header[156];
        const data_offset = self.tar_offset + tar_block_bytes;
        const header_data_end = std.math.add(usize, data_offset, std.math.cast(usize, header_size) orelse
            return self.failDomain(evaluator, "tar member size exceeds addressable memory")) catch
            return self.failDomain(evaluator, "tar member size overflows");
        const header_next = paddedTarOffset(header_data_end) orelse
            return self.failDomain(evaluator, "tar member padding overflows");
        if (header_next > tar.len) return self.failDomain(evaluator, "truncated tar member");

        if (typeflag == 'x') {
            self.pax_offset = data_offset;
            self.pax_end = header_data_end;
            self.pax_next_offset = header_next;
            self.state = .{ .parsing = .parse_pax };
            return .yielded;
        }
        if (typeflag == 'L') {
            if (header_size == 0 or header_size > max_path_bytes + 1)
                return self.failDomain(evaluator, "GNU long name exceeds the path limit");
            if (self.pending_path) |*old| old.deinit(evaluator.releaseDomain(), self.allocator);
            const raw = tar[data_offset..header_data_end];
            const trimmed = std.mem.trimEnd(u8, raw, "\x00");
            self.pending_path = .init(try self.allocator.dupe(u8, trimmed));
            self.tar_offset = header_next;
            return .yielded;
        }

        const kind: EntryKind = switch (typeflag) {
            0, '0' => .file,
            '5' => .directory,
            '1', '2' => return self.failDomain(evaluator, "tar links are not permitted"),
            '3', '4', '6' => return self.failDomain(evaluator, "tar special nodes are not permitted"),
            else => return self.failDomain(evaluator, "tar member kind is unsupported"),
        };
        const effective_size = self.pending_size orelse header_size;
        self.pending_size = null;
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
        const path = try self.memberPath(header);
        errdefer self.allocator.free(path);
        if (!validMemberPath(path)) return self.failDomain(evaluator, "tar member path is unsafe");
        self.member_count += 1;
        if (self.member_count > max_members)
            return self.failDomain(evaluator, "archive exceeds the 100000 member limit");
        const entry = Entry{
            .path = path,
            .kind = kind,
            .data_offset = data_offset,
            .size = @intCast(effective_size),
        };
        if (self.mode != .unpack) try self.validatePackageEntry(evaluator, entry);
        if (kind == .file) self.file_count += 1;
        self.pending_entry = entry;
        self.pending_next_offset = next_offset;
        self.pending_hash = std.hash.Wyhash.hash(0, path);
        self.pending_slot = @intCast(self.pending_hash & (member_slots - 1));
        self.pending_probes = 0;
        self.state = .{ .parsing = .insert_member };
        return .yielded;
    }

    fn parsePaxRecord(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.pax_offset == self.pax_end) {
            self.tar_offset = self.pax_next_offset;
            self.state = .{ .parsing = .tar_header };
            return .yielded;
        }
        const tar = self.tar.?.borrow();
        var space = self.pax_offset;
        while (space != self.pax_end and tar[space] != ' ') : (space += 1) {
            if (space - self.pax_offset >= 20 or tar[space] < '0' or tar[space] > '9')
                return self.failDomain(evaluator, "PAX record length is malformed");
        }
        if (space == self.pax_end) return self.failDomain(evaluator, "PAX record is truncated");
        const record_len = std.fmt.parseInt(usize, tar[self.pax_offset..space], 10) catch
            return self.failDomain(evaluator, "PAX record length is malformed");
        if (record_len <= space - self.pax_offset + 2 or record_len > self.pax_end - self.pax_offset)
            return self.failDomain(evaluator, "PAX record length is invalid");
        const record_end = self.pax_offset + record_len;
        if (tar[record_end - 1] != '\n') return self.failDomain(evaluator, "PAX record lacks a newline");
        self.pax_record_end = record_end;
        self.pax_key_start = space + 1;
        self.pax_scan_offset = space + 1;
        self.state = .{ .parsing = .scan_pax };
        return .yielded;
    }

    fn scanPaxRecord(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const tar = self.tar.?.borrow();
        const payload_end = self.pax_record_end - 1;
        const end = @min(self.pax_scan_offset + work_quantum, payload_end);
        const equals_relative = std.mem.indexOfScalar(u8, tar[self.pax_scan_offset..end], '=') orelse {
            self.pax_scan_offset = end;
            if (end == payload_end) return self.failDomain(evaluator, "PAX record lacks a value");
            return .yielded;
        };
        const equals = equals_relative + self.pax_scan_offset;
        const key = tar[self.pax_key_start..equals];
        const field = tar[equals + 1 .. payload_end];
        if (std.mem.eql(u8, key, "path")) {
            if (field.len == 0 or field.len > max_path_bytes)
                return self.failDomain(evaluator, "PAX path exceeds the path limit");
            if (self.pending_path) |*old| old.deinit(evaluator.releaseDomain(), self.allocator);
            self.pending_path = .init(try self.allocator.dupe(u8, field));
        } else if (std.mem.eql(u8, key, "size")) {
            if (field.len == 0 or field.len > 20)
                return self.failDomain(evaluator, "PAX size is malformed");
            self.pending_size = std.fmt.parseInt(u64, field, 10) catch
                return self.failDomain(evaluator, "PAX size is malformed");
        }
        self.pax_offset = self.pax_record_end;
        self.state = .{ .parsing = .parse_pax };
        return .yielded;
    }

    fn memberPath(self: *UnpackDriver, header: *const [tar_block_bytes]u8) error{OutOfMemory}![]u8 {
        const raw = if (self.pending_path) |*owned| owned.take() else path: {
            const name = tarString(header[0..100]);
            const prefix = tarString(header[345..500]);
            break :path if (prefix.len == 0)
                try self.allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, name });
        };
        self.pending_path = null;
        defer self.allocator.free(raw);
        const normalized = std.mem.trimEnd(u8, raw, "/");
        return self.allocator.dupe(u8, normalized);
    }

    fn insertMember(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const entry = &self.pending_entry.?;
        var remaining = work_quantum;
        while (remaining != 0) : (remaining -= 1) {
            const slot = &self.slots.?.borrow()[self.pending_slot];
            if (slot.*) |prior| {
                if (std.mem.eql(u8, prior.path, entry.path))
                    return self.failDomain(evaluator, "tar archive contains a duplicate member path");
                self.pending_probes += 1;
                if (self.pending_probes == member_slots)
                    return self.failDomain(evaluator, "tar member table is full");
                self.pending_slot = (self.pending_slot + 1) & (member_slots - 1);
                continue;
            }
            const stored = try self.entries.borrowMut().appendPtr(entry.*);
            slot.* = stored;
            self.pending_entry = null;
            self.tar_offset = self.pending_next_offset;
            self.state = .{ .parsing = .tar_header };
            return .yielded;
        }
        return .yielded;
    }

    fn trailingZeroes(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const tar = self.tar.?.borrow();
        const end = @min(self.tar_offset + work_quantum, tar.len);
        for (tar[self.tar_offset..end]) |byte| if (byte != 0)
            return self.failDomain(evaluator, "tar data follows its end marker");
        self.tar_offset = end;
        if (end != tar.len) return .yielded;
        self.state = .{ .parsing = if (self.mode == .unpack)
            .allocate_results
        else
            .materialize_manifest };
        return .yielded;
    }

    fn validatePackageEntry(
        self: *UnpackDriver,
        evaluator: *Machine,
        entry: Entry,
    ) MachineError!void {
        if (entry.kind == .directory) return;
        if (std.mem.eql(u8, entry.path, package_seal_name))
            return self.failPackageMember(evaluator, "package archive uses a reserved store member", entry.path);
        if (std.mem.eql(u8, entry.path, "ecl.pkg")) {
            if (self.manifest_data != null)
                return self.failPackageMember(evaluator, "package archive contains more than one root manifest", entry.path);
            self.manifest_data = .{ .offset = entry.data_offset, .size = entry.size };
            return;
        }
        if (std.mem.endsWith(u8, entry.path, ".eclmod"))
            return self.failPackageMember(evaluator, "native package members are not permitted", entry.path);
        if (!std.mem.endsWith(u8, entry.path, ".ecl")) return;
        if (lastSlash(entry.path) != null)
            return self.failPackageMember(evaluator, "package source modules must be at the archive root", entry.path);
        const module_name = entry.path[0 .. entry.path.len - ".ecl".len];
        if (!validPackageName(module_name))
            return self.failPackageMember(evaluator, "package source module name is not canonical", entry.path);
        if (!packageOwns(self.package_name.?.borrow(), module_name))
            return self.failPackageMember(evaluator, "package does not own source module", entry.path);
    }

    fn materializeManifest(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const manifest = self.manifest_data orelse
            return self.failDomain(evaluator, "package archive has no root ecl.pkg manifest");
        if (self.text_materializer == null) {
            const tar = self.tar.?.borrow();
            self.text_materializer = .init(self.allocator, tar[manifest.offset .. manifest.offset + manifest.size]);
        }
        return switch (self.text_materializer.?.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return self.failDomain(evaluator, "package root ecl.pkg is not valid UTF-8"),
        }) {
            .pending => .yielded,
            .complete => |text| result: {
                self.text_materializer.?.deinit();
                self.text_materializer = null;
                if (self.mode == .package_inspect) break :result .{ .output = text };
                evaluator.releaseDomain().releaseValue(text);
                self.state = .{ .parsing = .allocate_results };
                break :result .yielded;
            },
        };
    }

    fn allocateResults(self: *UnpackDriver) MachineError!machine.WorkProgress {
        self.result_values = try self.allocator.alloc(Value, self.file_count);
        self.result_iterator = self.entries.borrow().iterator();
        self.state = .{ .parsing = .materialize_paths };
        return .yielded;
    }

    fn materializePaths(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.text_materializer) |*materializer| switch (materializer.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return self.failDomain(evaluator, "tar member path is not valid UTF-8"),
        }) {
            .pending => return .yielded,
            .complete => |path_value| {
                materializer.deinit();
                self.text_materializer = null;
                self.result_values.?[self.result_values_built] = path_value;
                self.result_values_built += 1;
                self.current_result_path = null;
                return .yielded;
            },
        };
        var remaining = work_quantum;
        while (remaining != 0) : (remaining -= 1) {
            const entry = self.result_iterator.?.next() orelse {
                self.result_materializer = .init(self.allocator, self.result_values.?);
                self.state = .{ .parsing = .materialize_result };
                return .yielded;
            };
            if (entry.kind == .directory) continue;
            self.current_result_path = entry.path;
            self.text_materializer = .init(self.allocator, entry.path);
            return .yielded;
        }
        return .yielded;
    }

    fn materializeResult(self: *UnpackDriver) MachineError!machine.WorkProgress {
        return switch (try self.result_materializer.?.advance(work_quantum)) {
            .pending => .yielded,
            .complete => |result| result: {
                self.result_materializer.?.deinit();
                self.result_materializer = null;
                self.state = .{ .publication = .{ .destination_check = result } };
                break :result .yielded;
            },
        };
    }

    fn advancePublication(
        self: *UnpackDriver,
        evaluator: *Machine,
        publication: *Publication,
    ) MachineError!machine.WorkProgress {
        const io = self.io.?;
        switch (publication.*) {
            .destination_check => |result| {
                if (self.mode == .package_install) {
                    const parent = std.fs.path.dirname(self.destination.?.borrow()) orelse ".";
                    std.Io.Dir.cwd().createDirPath(io, parent) catch |err|
                        return self.failIo(evaluator, "cannot create package store parents", err);
                }
                std.Io.Dir.cwd().access(io, self.destination.?.borrow(), .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        publication.* = .{ .stage_path = result };
                        return .yielded;
                    },
                    else => return self.failIo(evaluator, "cannot inspect archive destination", err),
                };
                return self.failDestinationExists(evaluator, "archive destination already exists");
            },
            .stage_path => |result| {
                const identity = next_stage_identity.fetchAdd(1, .monotonic);
                const destination = self.destination.?.borrow();
                const parent = std.fs.path.dirname(destination) orelse ".";
                const basename = std.fs.path.basename(destination);
                const path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{c}.ecl-unpack-{x}-{s}",
                    .{ parent, std.fs.path.sep, identity, basename },
                );
                publication.* = .{ .create_stage = .{
                    .result = result,
                    .path = .init(path),
                } };
            },
            .create_stage => |*staged| {
                std.Io.Dir.cwd().createDir(io, staged.path.borrow(), .default_dir) catch |err| switch (err) {
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
                const directory = std.Io.Dir.cwd().openDir(io, staged.path.borrow(), .{}) catch |err|
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
                        if (self.mode == .package_install) {
                            const seal = extraction.dir.createFile(
                                io,
                                package_seal_name,
                                .{ .exclusive = true },
                            ) catch |err| return self.failIo(
                                evaluator,
                                "cannot create package archive seal",
                                err,
                            );
                            const staged = extraction.staged;
                            const dir = extraction.dir;
                            const created_count = extraction.created_count;
                            publication.* = .{ .seal = .{
                                .staged = staged,
                                .dir = dir,
                                .file = seal,
                                .created_count = created_count,
                            } };
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
                        const source = self.tar.?.borrow()[file_state.entry.data_offset + file_state.written .. file_state.entry.data_offset + end];
                        file_state.file.writePositionalAll(io, source, file_state.written) catch |err|
                            return self.failIo(evaluator, "cannot write archive file", err);
                        file_state.written = end;
                    } else {
                        file_state.file.close(io);
                        extraction.work = .next;
                    }
                },
            },
            .seal => |*seal| {
                const compressed = self.bytes.?.borrow().bytes();
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
                const destination = self.destination.?.borrow();
                const parent_path = std.fs.path.dirname(destination) orelse ".";
                var parent = std.Io.Dir.cwd().openDir(io, parent_path, .{}) catch |err|
                    return self.failIo(evaluator, "cannot open archive destination parent", err);
                defer parent.close(io);
                renamePreserve(
                    parent,
                    std.fs.path.basename(commit_state.staged.path.borrow()),
                    std.fs.path.basename(destination),
                    io,
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

    fn failPackageMember(
        self: *UnpackDriver,
        evaluator: *Machine,
        message: []const u8,
        member: []const u8,
    ) MachineError {
        return evaluator.failFmt(
            .domain,
            "{s}: package `{s}`, member `{s}`",
            .{ message, self.package_name.?.borrow(), member },
        );
    }

    fn failIo(self: *UnpackDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(.io, "{s}: {s}", .{ message, @errorName(err) });
        evaluator.addErrorPath(self.destination_value.?.borrow());
        return failure;
    }

    fn failIoName(self: *UnpackDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.destination_value.?.borrow());
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
        publication: *Publication,
    ) void {
        switch (publication.*) {
            .destination_check, .stage_path => |result| {
                releases.releaseValue(result);
                self.state = .cleanup_archive;
            },
            .create_stage => |*staged| {
                releases.releaseValue(staged.result);
                staged.path.deinit(releases, allocator);
                self.state = .cleanup_archive;
            },
            .open_stage => |*staged| {
                releases.releaseValue(staged.result);
                const path = staged.path.take();
                self.state = .{ .rollback_reopen = .{
                    .path = .init(path),
                    .created_count = 0,
                    .seal_created = false,
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
                    .created_count = extraction.created_count,
                    .seal_created = false,
                };
                const dir = extraction.dir;
                self.state = .{ .rollback = .{
                    .context = context,
                    .dir = dir,
                    .work = rollbackEntries(self, context.created_count),
                } };
            },
            .seal => |*seal| {
                seal.file.close(self.io.?);
                releases.releaseValue(seal.staged.result);
                const path = seal.staged.path.take();
                const context: RollbackContext = .{
                    .path = .init(path),
                    .created_count = seal.created_count,
                    .seal_created = true,
                };
                const dir = seal.dir;
                self.state = .{ .rollback = .{
                    .context = context,
                    .dir = dir,
                    .work = .seal,
                } };
            },
            .commit => |*commit_state| {
                releases.releaseValue(commit_state.staged.result);
                const path = commit_state.staged.path.take();
                self.state = .{ .rollback_reopen = .{
                    .path = .init(path),
                    .created_count = commit_state.created_count,
                    .seal_created = self.mode == .package_install,
                } };
            },
            .published => |*path| {
                path.deinit(releases, allocator);
                self.state = .cleanup_archive;
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
        context: *RollbackContext,
    ) bool {
        const directory = std.Io.Dir.cwd().openDir(self.io.?, context.path.borrow(), .{}) catch |open_err| {
            observeCleanupError("reopen the stage", open_err);
            std.Io.Dir.cwd().deleteDir(self.io.?, context.path.borrow()) catch |err|
                observeCleanupError("remove an unopened stage", err);
            context.path.deinit(releases, allocator);
            self.state = .cleanup_archive;
            return false;
        };
        const moved = context.*;
        self.state = .{ .rollback = .{
            .context = moved,
            .dir = directory,
            .work = if (moved.seal_created) .seal else rollbackEntries(self, moved.created_count),
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
            .seal => {
                rollback.dir.deleteFile(self.io.?, package_seal_name) catch |err|
                    observeCleanupError("remove the package archive seal", err);
                rollback.work = rollbackEntries(self, rollback.context.created_count);
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
                std.Io.Dir.cwd().deleteDir(self.io.?, rollback.context.path.borrow()) catch |err|
                    observeCleanupError("remove the stage root", err);
                rollback.context.path.deinit(releases, allocator);
                self.state = .cleanup_archive;
            },
        }
        return false;
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *UnpackDriver,
    ) bool {
        switch (self.state) {
            .parsing => {
                self.state = .cleanup_archive;
                return false;
            },
            .publication => |*publication| {
                self.beginPublicationRetirement(releases, allocator, publication);
                return false;
            },
            .rollback_reopen => |*context| return self.advanceRollbackReopen(
                releases,
                allocator,
                context,
            ),
            .rollback => |*rollback| return self.advanceRollback(releases, allocator, rollback),
            .cleanup_archive => {},
        }
        if (self.free_iterator == null) self.free_iterator = self.entries.borrow().reverseIterator();
        if (self.free_iterator.?.next()) |entry| {
            allocator.free(entry.path);
            return false;
        }
        if (self.result_values) |items| {
            if (self.result_release_index != self.result_values_built) {
                releases.releaseValue(items[self.result_release_index]);
                self.result_release_index += 1;
                return false;
            }
            allocator.free(items);
            self.result_values = null;
        }
        if (self.text_materializer) |*materializer| materializer.retire(releases);
        self.text_materializer = null;
        if (self.result_materializer) |*materializer| materializer.retire(releases);
        self.result_materializer = null;
        if (self.pending_entry) |entry| allocator.free(entry.path);
        self.pending_entry = null;
        if (self.pending_path) |*path| path.deinit(releases, allocator);
        self.pending_path = null;
        if (self.slots) |*slots| slots.deinit(releases, allocator);
        self.slots = null;
        if (self.tar) |*tar| tar.deinit(releases, allocator);
        self.tar = null;
        if (self.decoder) |*decoder| decoder.deinit(releases, allocator);
        self.decoder = null;
        if (self.bytes) |*bytes| bytes.deinit(releases, allocator);
        self.bytes = null;
        if (self.destination) |*destination| destination.deinit(releases, allocator);
        self.destination = null;
        if (self.package_name) |*name| name.deinit(releases, allocator);
        self.package_name = null;
        self.byte_encoder.deinit(releases, allocator);
        if (self.path_encoder) |*encoder| encoder.deinit(releases, allocator);
        self.path_encoder = null;
        if (self.package_encoder) |*encoder| encoder.deinit(releases, allocator);
        self.package_encoder = null;
        self.bytes_value.deinit(releases, allocator);
        if (self.destination_value) |*destination| destination.deinit(releases, allocator);
        self.destination_value = null;
        if (self.package_value) |*package| package.deinit(releases, allocator);
        self.package_value = null;
        self.entries.deinit(releases, allocator);
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
