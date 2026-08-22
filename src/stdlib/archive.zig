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
        .bytes_value = .init(bytes_value.take()),
        .destination_value = .init(destination.take()),
        .byte_encoder = .init(byte_encoder),
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

const Phase = enum {
    encode_bytes,
    encode_destination,
    allocate_output,
    decompress,
    verify_gzip,
    initialize_slots,
    tar_header,
    insert_member,
    parse_pax,
    scan_pax,
    trailing_zeroes,
    allocate_results,
    materialize_paths,
    materialize_result,
    destination_check,
    create_stage,
    extract,
    commit,
};

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

fn renameDirectoryPreserve(
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
    io: std.Io,
    bytes_value: heap.Owned(Value),
    destination_value: heap.Owned(Value),
    byte_encoder: heap.Owned(storage.ByteVectorEncoder),
    path_encoder: heap.Owned(storage.ToUtf8Cursor),
    entries: heap.Owned(EntryList),
    phase: Phase = .encode_bytes,

    bytes: ?heap.Owned(storage.ByteVector) = null,
    destination: ?heap.Owned([]u8) = null,
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

    result_values: ?[]Value = null,
    result_values_built: usize = 0,
    result_iterator: ?EntryList.Iterator = null,
    current_result_path: ?[]const u8 = null,
    text_materializer: ?storage.Utf8Materializer = null,
    result_materializer: ?storage.ValueMaterializer = null,
    result: ?Value = null,

    stage_path: ?heap.Owned([]u8) = null,
    stage_dir: ?std.Io.Dir = null,
    stage_created: bool = false,
    extract_iterator: ?EntryList.Iterator = null,
    current_entry: ?*const Entry = null,
    current_file: ?std.Io.File = null,
    current_written: usize = 0,
    created_count: usize = 0,
    committed: bool = false,

    cleanup_iterator: ?EntryList.ReverseIterator = null,
    cleanup_skip: usize = 0,
    cleanup_current: ?*const Entry = null,
    cleanup_parent_end: ?usize = null,
    free_iterator: ?EntryList.ReverseIterator = null,
    result_release_index: usize = 0,

    pub fn advance(evaluator: *Machine, self: *UnpackDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.phase) {
            .encode_bytes => self.encodeBytes(evaluator),
            .encode_destination => self.encodeDestination(evaluator),
            .allocate_output => self.allocateOutput(evaluator),
            .decompress => self.decompress(evaluator),
            .verify_gzip => self.verifyGzip(evaluator),
            .initialize_slots => self.initializeSlots(),
            .tar_header => self.readTarHeader(evaluator),
            .insert_member => self.insertMember(evaluator),
            .parse_pax => self.parsePaxRecord(evaluator),
            .scan_pax => self.scanPaxRecord(evaluator),
            .trailing_zeroes => self.trailingZeroes(evaluator),
            .allocate_results => self.allocateResults(),
            .materialize_paths => self.materializePaths(evaluator),
            .materialize_result => self.materializeResult(),
            .destination_check => self.destinationCheck(evaluator),
            .create_stage => self.createStage(evaluator),
            .extract => self.extract(evaluator),
            .commit => self.commit(evaluator),
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
                self.phase = .encode_destination;
                return .yielded;
            },
        }
    }

    fn encodeDestination(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        switch (self.path_encoder.borrowMut().advance(work_quantum) catch |err| switch (err) {
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
                self.phase = .allocate_output;
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
        self.phase = .decompress;
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
        self.phase = .verify_gzip;
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
        self.phase = .initialize_slots;
        return .yielded;
    }

    fn initializeSlots(self: *UnpackDriver) MachineError!machine.WorkProgress {
        const slots = self.slots.?.borrow();
        const end = @min(self.slots_initialized + work_quantum, slots.len);
        @memset(slots[self.slots_initialized..end], null);
        self.slots_initialized = end;
        if (end != slots.len) return .yielded;
        self.phase = .tar_header;
        return .yielded;
    }

    fn readTarHeader(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const tar = self.tar.?.borrow();
        if (self.tar_offset == tar.len) {
            if (self.zero_blocks < 2) return self.failDomain(evaluator, "tar archive has no end marker");
            self.phase = .allocate_results;
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
            if (self.zero_blocks == 2) self.phase = .trailing_zeroes;
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
            self.phase = .parse_pax;
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
        if (kind == .file) self.file_count += 1;
        self.pending_entry = .{
            .path = path,
            .kind = kind,
            .data_offset = data_offset,
            .size = @intCast(effective_size),
        };
        self.pending_next_offset = next_offset;
        self.pending_hash = std.hash.Wyhash.hash(0, path);
        self.pending_slot = @intCast(self.pending_hash & (member_slots - 1));
        self.pending_probes = 0;
        self.phase = .insert_member;
        return .yielded;
    }

    fn parsePaxRecord(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.pax_offset == self.pax_end) {
            self.tar_offset = self.pax_next_offset;
            self.phase = .tar_header;
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
        self.phase = .scan_pax;
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
        self.phase = .parse_pax;
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
            self.phase = .tar_header;
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
        self.phase = .allocate_results;
        return .yielded;
    }

    fn allocateResults(self: *UnpackDriver) MachineError!machine.WorkProgress {
        self.result_values = try self.allocator.alloc(Value, self.file_count);
        self.result_iterator = self.entries.borrow().iterator();
        self.phase = .materialize_paths;
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
                self.phase = .materialize_result;
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
                self.result = result;
                self.phase = .destination_check;
                break :result .yielded;
            },
        };
    }

    fn destinationCheck(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        std.Io.Dir.cwd().access(self.io, self.destination.?.borrow(), .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.phase = .create_stage;
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot inspect archive destination", err),
        };
        return self.failIoName(evaluator, "archive destination already exists");
    }

    fn createStage(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.stage_path == null) {
            const identity = next_stage_identity.fetchAdd(1, .monotonic);
            const destination = self.destination.?.borrow();
            const parent = std.fs.path.dirname(destination) orelse ".";
            const basename = std.fs.path.basename(destination);
            self.stage_path = .init(try std.fmt.allocPrint(
                self.allocator,
                "{s}{c}.ecl-unpack-{x}-{s}",
                .{ parent, std.fs.path.sep, identity, basename },
            ));
        }
        std.Io.Dir.cwd().createDir(self.io, self.stage_path.?.borrow(), .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                self.stage_path.?.deinit(evaluator.releaseDomain(), self.allocator);
                self.stage_path = null;
                return .yielded;
            },
            else => return self.failIo(evaluator, "cannot create archive staging directory", err),
        };
        self.stage_created = true;
        self.stage_dir = std.Io.Dir.cwd().openDir(self.io, self.stage_path.?.borrow(), .{}) catch |err|
            return self.failIo(evaluator, "cannot open archive staging directory", err);
        self.extract_iterator = self.entries.borrow().iterator();
        self.phase = .extract;
        return .yielded;
    }

    fn extract(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        if (self.current_entry == null) {
            const entry = self.extract_iterator.?.next() orelse {
                self.stage_dir.?.close(self.io);
                self.stage_dir = null;
                self.phase = .commit;
                return .yielded;
            };
            self.current_entry = entry;
            self.created_count += 1;
            if (entry.kind == .directory) {
                self.stage_dir.?.createDirPath(self.io, entry.path) catch |err|
                    return self.failIo(evaluator, "cannot create archive directory", err);
                self.current_entry = null;
                return .yielded;
            }
            if (lastSlash(entry.path)) |slash|
                self.stage_dir.?.createDirPath(self.io, entry.path[0..slash]) catch |err|
                    return self.failIo(evaluator, "cannot create archive parent directory", err);
            self.current_file = self.stage_dir.?.createFile(self.io, entry.path, .{ .exclusive = true }) catch |err|
                return self.failIo(evaluator, "cannot create archive file", err);
            self.current_written = 0;
            return .yielded;
        }
        const entry = self.current_entry.?;
        if (self.current_written != entry.size) {
            const end = @min(self.current_written + work_quantum, entry.size);
            const source = self.tar.?.borrow()[entry.data_offset + self.current_written .. entry.data_offset + end];
            self.current_file.?.writePositionalAll(self.io, source, self.current_written) catch |err|
                return self.failIo(evaluator, "cannot write archive file", err);
            self.current_written = end;
            return .yielded;
        }
        self.current_file.?.close(self.io);
        self.current_file = null;
        self.current_entry = null;
        return .yielded;
    }

    fn commit(self: *UnpackDriver, evaluator: *Machine) MachineError!machine.WorkProgress {
        const destination = self.destination.?.borrow();
        const parent_path = std.fs.path.dirname(destination) orelse ".";
        var parent = std.Io.Dir.cwd().openDir(self.io, parent_path, .{}) catch |err|
            return self.failIo(evaluator, "cannot open archive destination parent", err);
        defer parent.close(self.io);
        renameDirectoryPreserve(
            parent,
            std.fs.path.basename(self.stage_path.?.borrow()),
            std.fs.path.basename(destination),
            self.io,
        ) catch |err| return self.failIo(evaluator, "cannot publish archive destination", err);
        self.committed = true;
        self.stage_created = false;
        const result = self.result.?;
        self.result = null;
        return .{ .output = result };
    }

    fn failDomain(self: *UnpackDriver, evaluator: *Machine, message: []const u8) MachineError {
        _ = self;
        return evaluator.fail(.domain, message);
    }

    fn failIo(self: *UnpackDriver, evaluator: *Machine, message: []const u8, err: anyerror) MachineError {
        const failure = evaluator.failFmt(.io, "{s}: {s}", .{ message, @errorName(err) });
        evaluator.addErrorPath(self.destination_value.borrow());
        return failure;
    }

    fn failIoName(self: *UnpackDriver, evaluator: *Machine, message: []const u8) MachineError {
        const failure = evaluator.fail(.io, message);
        evaluator.addErrorPath(self.destination_value.borrow());
        return failure;
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *UnpackDriver,
    ) bool {
        if (self.current_file) |file| file.close(self.io);
        self.current_file = null;
        if (!self.committed and self.stage_created) {
            if (self.stage_dir == null) {
                self.stage_dir = std.Io.Dir.cwd().openDir(self.io, self.stage_path.?.borrow(), .{}) catch |open_err| {
                    observeCleanupError("reopen the stage", open_err);
                    std.Io.Dir.cwd().deleteDir(self.io, self.stage_path.?.borrow()) catch |err|
                        observeCleanupError("remove an unopened stage", err);
                    self.stage_created = false;
                    return false;
                };
            }
            if (self.cleanup_iterator == null) {
                self.cleanup_iterator = self.entries.borrow().reverseIterator();
                self.cleanup_skip = self.entries.borrow().count - self.created_count;
            }
            if (self.cleanup_parent_end) |end| {
                const entry = self.cleanup_current.?;
                self.stage_dir.?.deleteDir(self.io, entry.path[0..end]) catch |err|
                    observeCleanupError("remove an implicit parent directory", err);
                self.cleanup_parent_end = lastSlash(entry.path[0..end]);
                return false;
            }
            if (self.cleanup_current != null) self.cleanup_current = null;
            if (self.cleanup_skip != 0) {
                _ = self.cleanup_iterator.?.next();
                self.cleanup_skip -= 1;
                return false;
            }
            if (self.cleanup_iterator.?.next()) |entry| {
                self.cleanup_current = entry;
                switch (entry.kind) {
                    .file => {
                        self.stage_dir.?.deleteFile(self.io, entry.path) catch |err|
                            observeCleanupError("remove a staged file", err);
                        self.cleanup_parent_end = lastSlash(entry.path);
                    },
                    .directory => {
                        self.stage_dir.?.deleteDir(self.io, entry.path) catch |err|
                            observeCleanupError("remove a staged directory", err);
                        self.cleanup_parent_end = lastSlash(entry.path);
                    },
                }
                return false;
            }
            if (self.stage_dir) |directory| directory.close(self.io);
            self.stage_dir = null;
            std.Io.Dir.cwd().deleteDir(self.io, self.stage_path.?.borrow()) catch |err|
                observeCleanupError("remove the stage root", err);
            self.stage_created = false;
            return false;
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
        if (self.result) |result| releases.releaseValue(result);
        self.result = null;
        if (self.pending_entry) |entry| allocator.free(entry.path);
        self.pending_entry = null;
        if (self.pending_path) |*path| path.deinit(releases, allocator);
        self.pending_path = null;
        if (self.stage_dir) |directory| directory.close(self.io);
        self.stage_dir = null;
        if (self.stage_path) |*path| path.deinit(releases, allocator);
        self.stage_path = null;
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
        self.byte_encoder.deinit(releases, allocator);
        self.path_encoder.deinit(releases, allocator);
        self.bytes_value.deinit(releases, allocator);
        self.destination_value.deinit(releases, allocator);
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

fn lastSlash(path: []const u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, path, '/');
}
