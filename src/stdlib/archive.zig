//! Exact hashing and validated hostile-input archive inspection.
//!
//! Binary payloads remain ordinary ECL integer lists. The encoder borrows an
//! internal byte leaf when available and validates any equivalent list, so the
//! module never assigns language semantics to a storage representation.
const std = @import("std");
const document = @import("../archive_document.zig");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const env = @import("../env.zig");
const intern = @import("../intern.zig");
const machine = @import("../machine.zig");
const storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");

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
    .{ .name = "open-tgz", .doc = "( bytes -- archive ) Validate a gzip tar for scope-owned member inspection.", .primitive = openTgz },
    .{ .name = "next-member", .doc = "( archive -- metadata ) Advance to the next member, or return an empty dictionary at end.", .primitive = nextMember },
    .{ .name = "read-member", .doc = "( archive maximum -- bytes ) Stream up to 65536 bytes from the selected member; empty bytes denote end.", .primitive = readMember },
    .{
        .name = "sha256",
        .doc = "( bytes -- lowercase-hex ) Hash an integer byte list with SHA-256.",
        .primitive = sha256,
    },
};

fn openTgz(evaluator: *Machine) MachineError!void {
    var bytes = try evaluator.popValue();
    errdefer bytes.deinit();
    if (bytes.borrow() != .list) return evaluator.typeError("an integer byte list");
    const encoder = storage.ByteVectorEncoder.init(evaluator.allocator(), bytes.borrow());
    try evaluator.startDriver(InspectionDriver{
        .allocator = evaluator.allocator(),
        .bytes_value = .init(bytes.take()),
        .entries = .init(.init(evaluator.allocator())),
        .state = .{ .parsing = .{ .encode_bytes = .{ .byte = .init(encoder) } } },
    });
}
fn nextMember(evaluator: *Machine) MachineError!void {
    var archive = try evaluator.popValue();
    errdefer archive.deinit();
    if (!document.isArchive(archive.borrow())) return evaluator.typeError("an archive resource");
    const driver = try evaluator.allocator().create(MemberDriver);
    driver.* = .{ .archive = archive.take() };
    evaluator.adoptDriver(driver);
}
const MemberDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    archive: Value,
    path: [document.path_limit]u8 = undefined,
    metadata: document.Metadata = undefined,
    state: union(enum) { reading, text: storage.Utf8Materializer, complete } = .reading,
    pub fn deinit(self: *@This(), releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        if (self.state == .text) self.state.text.retire(releases);
        releases.releaseValue(self.archive);
    }
    pub fn advance(evaluator: *Machine, self: *@This()) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .reading) {
            self.metadata = (document.next(self.archive, &self.path) catch |err| switch (err) {
                error.Closed => return evaluator.fail(.io, "archive resource is closed"),
                error.Invalid => return evaluator.fail(.domain, "archive member range is invalid"),
            }) orelse {
                self.state = .complete;
                return .{ .output = try @import("../dict.zig").fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{}) };
            };
            self.state = .{ .text = .init(evaluator.allocator(), self.path[0..self.metadata.length]) };
        }
        return switch (self.state.text.advance(work_quantum) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return evaluator.fail(.domain, "archive member path is not UTF-8"),
        }) {
            .pending => .yielded,
            .complete => |path| result: {
                self.state.text.deinit();
                self.state = .complete;
                defer evaluator.releaseDomain().releaseValue(path);
                break :result .{ .output = try @import("../dict.zig").fromUniquePairs(evaluator.allocator(), evaluator.releaseDomain(), &.{
                    .{ .{ .symbol = try intern.intern("path") }, path },
                    .{ .{ .symbol = try intern.intern("kind") }, .{ .symbol = try intern.intern(@tagName(self.metadata.kind)) } },
                    .{ .{ .symbol = try intern.intern("size") }, .{ .int = @intCast(self.metadata.size) } },
                }) };
            },
        };
    }
};
fn readMember(evaluator: *Machine) MachineError!void {
    var maximum_value = try evaluator.popValue();
    defer maximum_value.deinit();
    if (maximum_value.borrow() != .int) return evaluator.typeError("an integer read maximum");
    const maximum = maximum_value.borrow().int;
    if (maximum < 1 or maximum > document.read_limit) return evaluator.fail(.domain, "archive read maximum must be from 1 through 65536");
    var archive = try evaluator.popValue();
    errdefer archive.deinit();
    if (!document.isArchive(archive.borrow())) return evaluator.typeError("an archive resource");
    const driver = try evaluator.allocator().create(MemberReadDriver);
    errdefer evaluator.allocator().destroy(driver);
    const buffer = try evaluator.allocator().alloc(u8, @intCast(maximum));
    driver.* = .{ .archive = archive.take(), .buffer = buffer };
    evaluator.adoptDriver(driver);
}
const MemberReadDriver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    archive: Value,
    buffer: []u8,
    state: union(enum) { reading, bytes: list.ByteListMaterializer, complete } = .reading,
    pub fn deinit(self: *@This(), releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (self.state == .bytes) self.state.bytes.retire(releases);
        allocator.free(self.buffer);
        releases.releaseValue(self.archive);
    }
    pub fn advance(evaluator: *Machine, self: *@This()) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .reading) {
            const count = document.read(self.archive, self.buffer) catch return evaluator.fail(.io, "archive resource is closed");
            self.state = .{ .bytes = .init(evaluator.allocator(), self.buffer[0..count]) };
        }
        return switch (try self.state.bytes.advance(work_quantum)) {
            .pending => .yielded,
            .complete => |bytes| result: {
                self.state.bytes.deinit();
                self.state = .complete;
                break :result .{ .output = bytes };
            },
        };
    }
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

const EntryKind = document.Kind;
const Entry = document.Member;
const EntryList = document.Members;

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

const InspectionDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    allocator: std.mem.Allocator,
    bytes_value: heap.Owned(Value),
    entries: heap.Owned(EntryList),
    state: State,
    const EncodedInputs = struct {
        bytes: heap.Owned(storage.ByteVector),
    };
    const Archive = struct {
        bytes: heap.Owned(storage.ByteVector),
        tar: heap.Owned([]u8),
        slots: heap.Owned([]?*Entry),
    };
    const ScanContext = struct {
        tar_offset: usize = 0,
        zero_blocks: u2 = 0,
        member_count: usize = 0,
        pending_path: ?heap.Owned([]u8) = null,
        pending_size: ?u64 = null,
    };
    const Pax = struct {
        offset: usize,
        end: usize,
        next_offset: usize,
    };
    const ScanWork = union(enum) {
        publish_view,
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
    };
    const Scanning = struct {
        context: ScanContext = .{},
        work: ScanWork = .tar_header,
    };
    const Parsing = union(enum) {
        encode_bytes: struct {
            byte: heap.Owned(storage.ByteVectorEncoder),
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
    const Active = struct { archive: Archive, scanning: Scanning = .{} };
    const CleanupWork = union(enum) { entries: EntryList.ReverseIterator, finish };
    const State = union(enum) {
        parsing: Parsing,
        active: Active,
        cleanup_archive: Archive,
        cleanup: CleanupWork,
    };

    pub fn advance(evaluator: *Machine, self: *InspectionDriver) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .parsing => |*parsing| self.advanceParsing(evaluator, parsing),
            .active => |*active| self.advanceActive(evaluator, active),
            .cleanup_archive,
            .cleanup,
            => unreachable,
        };
    }

    fn advanceParsing(
        self: *InspectionDriver,
        evaluator: *Machine,
        parsing: *Parsing,
    ) MachineError!machine.WorkProgress {
        return switch (parsing.*) {
            .encode_bytes => |*encoding| self.encodeBytes(evaluator, encoding),
            .allocate_tar => |*allocation| self.allocateTar(evaluator, allocation),
            .allocate_decoder => |*allocation| self.allocateDecoder(allocation),
            .decompress => |*decompression| self.decompress(evaluator, decompression),
            .verify => |*verification| self.verifyGzip(evaluator, verification),
            .allocate_slots => |*allocation| self.allocateSlots(allocation),
            .initialize_slots => |*initialization| self.initializeSlots(initialization),
        };
    }

    fn advanceActive(self: *InspectionDriver, evaluator: *Machine, active: *Active) MachineError!machine.WorkProgress {
        const scanning = &active.scanning;
        return switch (scanning.work) {
            .publish_view => self.publishView(evaluator, &active.archive),
            .tar_header => self.readTarHeader(evaluator, &active.archive, scanning),
            .insert_member => |*insertion| self.insertMember(evaluator, &active.archive, scanning, insertion),
            .parse_pax => |*pax| self.parsePaxRecord(evaluator, &active.archive, scanning, pax),
            .scan_pax => |*scan| self.scanPaxRecord(evaluator, &active.archive, scanning, scan),
            .trailing_zeroes => self.trailingZeroes(evaluator, &active.archive, scanning),
        };
    }

    fn takeEncodedInputs(inputs: *EncodedInputs) EncodedInputs {
        return .{ .bytes = .init(inputs.bytes.take()) };
    }
    fn takeArchive(archive: *Archive) Archive {
        return .{ .bytes = .init(archive.bytes.take()), .tar = .init(archive.tar.take()), .slots = .init(archive.slots.take()) };
    }

    fn encodeBytes(
        self: *InspectionDriver,
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
                encoding.byte.deinit(evaluator.releaseDomain(), self.allocator);
                self.state = .{ .parsing = .{ .allocate_tar = .{ .bytes = .init(bytes) } } };
                return .yielded;
            },
        }
    }

    fn allocateTar(
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
            .tar = .init(initialization.tar.take()),
            .slots = .init(initialization.slots.take()),
        };
        self.state = .{ .active = .{
            .archive = archive,
        } };
        return .yielded;
    }

    fn publishView(self: *InspectionDriver, evaluator: *Machine, archive: *Archive) MachineError!machine.WorkProgress {
        const scope: *@import("../scheduler.zig").TaskScope = @ptrCast(@alignCast(evaluator.unit.task_scope orelse return evaluator.fail(.cancelled, "archive scope is closing")));
        const result = document.adopt(scope, archive.tar.borrow(), self.entries.borrow()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return evaluator.fail(.cancelled, "archive scope is closing"),
        };
        // Scope publication consumes both inputs. Replace them without any
        // allocation or cancellation point before driver retirement can run.
        _ = archive.tar.take();
        archive.tar = .init(&.{});
        _ = self.entries.take();
        self.entries = .init(.init(self.allocator));
        return .{ .output = result };
    }

    fn readTarHeader(
        self: *InspectionDriver,
        evaluator: *Machine,
        archive: *Archive,
        scanning: *Scanning,
    ) MachineError!machine.WorkProgress {
        const context = &scanning.context;
        const tar = archive.tar.borrow();
        if (context.tar_offset == tar.len) {
            if (context.zero_blocks < 2) return self.failDomain(evaluator, "tar archive has no end marker");
            scanning.work = .publish_view;
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
        const hash = std.hash.Wyhash.hash(0, path);
        scanning.work = .{ .insert_member = .{
            .entry = entry,
            .next_offset = next_offset,
            .slot = @intCast(hash & (member_slots - 1)),
        } };
        return .yielded;
    }

    fn parsePaxRecord(
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        self: *InspectionDriver,
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
        scanning.work = .publish_view;
        return .yielded;
    }

    fn failDomain(self: *InspectionDriver, evaluator: *Machine, message: []const u8) MachineError {
        _ = self;
        return evaluator.fail(.domain, message);
    }

    fn retireEncodedInputs(
        inputs: *EncodedInputs,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        inputs.bytes.deinit(releases, allocator);
    }

    fn retireArchive(
        archive: *Archive,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        archive.slots.deinit(releases, allocator);
        archive.tar.deinit(releases, allocator);
        archive.bytes.deinit(releases, allocator);
    }

    fn retireScanning(scanning: *Scanning, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        if (scanning.work == .insert_member) allocator.free(scanning.work.insert_member.entry.path);
        if (scanning.context.pending_path) |*path| path.deinit(releases, allocator);
        scanning.context.pending_path = null;
    }

    fn retireParsing(
        parsing: *Parsing,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        switch (parsing.*) {
            .encode_bytes => |*encoding| {
                encoding.byte.deinit(releases, allocator);
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

    pub fn advanceRetirement(releases: *heap.ReleaseDomain, allocator: std.mem.Allocator, self: *InspectionDriver) bool {
        switch (self.state) {
            .parsing => |*parsing| {
                retireParsing(parsing, releases, allocator);
                self.state = .{ .cleanup = .{ .entries = self.entries.borrow().reverseIterator() } };
                return false;
            },
            .active => |*active| {
                retireScanning(&active.scanning, releases, allocator);
                const archive = takeArchive(&active.archive);
                self.state = .{ .cleanup_archive = archive };
                return false;
            },
            .cleanup_archive => |*archive| {
                retireArchive(archive, releases, allocator);
                self.state = .{ .cleanup = .{ .entries = self.entries.borrow().reverseIterator() } };
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
                .finish => {},
            },
        }
        self.bytes_value.deinit(releases, allocator);
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
