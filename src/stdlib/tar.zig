//! Hostile-input-safe tar parsing behind the `tar` module.
//!
//! Binary payloads remain ordinary ECL integer lists. The encoder borrows an
//! internal byte leaf when available and validates any equivalent list, so the
//! module never assigns language semantics to a storage representation. This
//! file reads the format only; `tar.unpack` publishes through `fs`.
const std = @import("std");
const driver_completion = @import("../driver_completion.zig");
const value = @import("../value.zig");
const heap = @import("../heap.zig");
const env = @import("../env.zig");
const intern = @import("../intern.zig");
const machine = @import("../machine.zig");
const storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");
const poll = @import("../poll.zig");

const Value = value.Value;
const Fiber = machine.Fiber;
const MachineError = machine.MachineError;
const max_tar_bytes: usize = 1_073_741_824;
const max_members: usize = 100_000;
const max_path_bytes: usize = 4096;
const member_slots = 1 << 18;
const tar_block_bytes = 512;

/// The module's documentation, which `module-doc` reflects.
pub const doc =
    \\Host parser behind the `tar` module. A failure inside it reports its `tar.core` name.
;

pub const words = [_]env.BuiltinWord{
    .{
        .name = "read",
        .effect = "bytes -- members",
        .doc = "Validate a tar byte list with the hostile-input parser and limits that `unpack` relies on, without filesystem writes, and return its members in archive order as `{path string kind symbol bytes list}`. Kinds are `` `file `` and `` `directory ``; a directory's bytes are `[]`. Unsafe, linked, special, duplicate, malformed, or over-limit members and invalid byte items are `` `domain ``; a non-list input is `` `type ``.",
        .primitive = readWord,
    },
};

fn readWord(fiber: *Fiber) MachineError!void {
    var bytes = try fiber.popValue();
    errdefer bytes.deinit();
    if (bytes.borrow() != .list) return fiber.typeError("an integer byte list");
    const encoder = storage.ByteVectorEncoder.init(fiber.allocator, bytes.borrow());
    try fiber.startDriver(ReadDriver{
        .allocator = fiber.allocator,
        .bytes_value = .init(bytes.take()),
        .entries = .init(.init(fiber.allocator)),
        .state = .{ .parsing = .{ .encode_bytes = .init(encoder) } },
    });
}

const EntryKind = enum { file, directory };
const Entry = struct { path: []u8, kind: EntryKind, data_offset: usize, size: usize };
const EntryList = poll.ChunkList(Entry);

const ReadDriver = struct {
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    completion: driver_completion.Completion = .{},
    allocator: std.mem.Allocator,
    bytes_value: heap.Owned(Value),
    entries: heap.Owned(EntryList),
    state: State,

    const Archive = struct {
        bytes: heap.Owned(storage.ByteVector),
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
    const ResultInputs = struct {
        values: []Value,
        built: usize = 0,
    };
    const ResultRelease = struct {
        values: []Value,
        built: usize,
        index: usize = 0,
    };
    /// One member dict under construction: its path text, then its contents.
    const MemberWork = union(enum) {
        next,
        text: struct { materializer: storage.Utf8Materializer, entry: *const Entry },
        contents: struct { path: Value, kind: EntryKind, materializer: list.ByteListMaterializer },
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

        allocate_results,
        materialize_members: struct {
            inputs: ResultInputs,
            iterator: EntryList.Iterator,
            work: MemberWork = .next,
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
        encode_bytes: heap.Owned(storage.ByteVectorEncoder),
        allocate_slots: heap.Owned(storage.ByteVector),
        initialize_slots: struct {
            bytes: heap.Owned(storage.ByteVector),
            slots: heap.Owned([]?*Entry),
            index: usize = 0,
        },
    };
    const Active = struct {
        archive: Archive,
        scanning: Scanning,
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
        cleanup_archive: Archive,
        cleanup_archive_with_results: struct {
            archive: Archive,
            release: ResultRelease,
        },
        cleanup: CleanupWork,
    };

    /// Polls while its operation runs; its cleanup must finish under cancellation.
    pub const cancellation: machine.DriverCancellation = .own;

    pub fn advance(fiber: *Fiber, self: *ReadDriver) MachineError!machine.WorkProgress {
        return self.completion.advance(fiber, self);
    }

    pub fn advanceOperation(self: *ReadDriver, fiber: *Fiber) MachineError!driver_completion.Progress {
        try fiber.pollKernel();
        return switch (self.state) {
            .parsing => |*parsing| self.advanceParsing(fiber, parsing),
            .active => |*active| self.advanceActive(fiber, active),
            .cleanup_archive,
            .cleanup_archive_with_results,
            .cleanup,
            => unreachable,
        };
    }

    fn advanceParsing(
        self: *ReadDriver,
        fiber: *Fiber,
        parsing: *Parsing,
    ) MachineError!driver_completion.Progress {
        return switch (parsing.*) {
            .encode_bytes => |*encoder| self.encodeBytes(fiber, encoder),
            .allocate_slots => |*bytes| self.allocateSlots(fiber, bytes),
            .initialize_slots => |*initialization| self.initializeSlots(fiber, initialization),
        };
    }

    fn advanceActive(
        self: *ReadDriver,
        fiber: *Fiber,
        active: *Active,
    ) MachineError!driver_completion.Progress {
        const scanning = &active.scanning;
        return switch (scanning.work) {
            .tar_header => self.readTarHeader(fiber, &active.archive, scanning),
            .insert_member => |*insertion| self.insertMember(
                fiber,
                &active.archive,
                scanning,
                insertion,
            ),
            .parse_pax => |*pax| self.parsePaxRecord(fiber, &active.archive, scanning, pax),
            .scan_pax => |*scan| self.scanPaxRecord(fiber, &active.archive, scanning, scan),
            .trailing_zeroes => self.trailingZeroes(fiber, &active.archive, scanning),
            .allocate_results => self.allocateResults(scanning),
            .materialize_members => |*members| self.materializeMembers(
                fiber,
                &active.archive,
                scanning,
                members,
            ),
            .materialize_result => |*materialization| materializeResult(
                fiber,
                scanning,
                materialization,
            ),
            .release_result_inputs => |*release| self.releaseResultInputs(
                fiber,
                scanning,
                release,
            ),
            .complete => unreachable,
        };
    }

    fn takeArchive(archive: *Archive) Archive {
        return .{
            .bytes = .init(archive.bytes.take()),
            .slots = .init(archive.slots.take()),
        };
    }

    fn encodeBytes(
        self: *ReadDriver,
        fiber: *Fiber,
        encoder: *heap.Owned(storage.ByteVectorEncoder),
    ) MachineError!driver_completion.Progress {
        switch (encoder.borrowMut().advance(fiber.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return fiber.failAtIndex(
                .domain,
                "tar.read expects integers from 0 through 255",
                encoder.borrow().invalid_index.?,
            ),
        }) {
            .pending => return .stepped,
            .complete => |bytes| {
                encoder.deinit(fiber.releases, self.allocator);
                self.state = .{ .parsing = .{ .allocate_slots = .init(bytes) } };
                return .stepped;
            },
        }
    }

    fn allocateSlots(
        self: *ReadDriver,
        fiber: *Fiber,
        bytes: *heap.Owned(storage.ByteVector),
    ) MachineError!driver_completion.Progress {
        if (bytes.borrow().bytes().len > max_tar_bytes)
            return self.failDomain(fiber, "tar archive exceeds the 1 GiB limit");
        const slots = try self.allocator.alloc(?*Entry, member_slots);
        self.state = .{ .parsing = .{ .initialize_slots = .{
            .bytes = .init(bytes.take()),
            .slots = .init(slots),
        } } };
        return .stepped;
    }

    fn initializeSlots(
        self: *ReadDriver,
        fiber: *Fiber,
        initialization: *@FieldType(Parsing, "initialize_slots"),
    ) MachineError!driver_completion.Progress {
        const slots = initialization.slots.borrow();
        const end = initialization.index + fiber.workBudget().take(slots.len - initialization.index);
        @memset(slots[initialization.index..end], null);
        initialization.index = end;
        if (end != slots.len) return .stepped;

        const archive: Archive = .{
            .bytes = .init(initialization.bytes.take()),
            .slots = .init(initialization.slots.take()),
        };
        self.state = .{ .active = .{ .archive = archive, .scanning = .{} } };
        return .stepped;
    }

    fn readTarHeader(
        self: *ReadDriver,
        fiber: *Fiber,
        archive: *Archive,
        scanning: *Scanning,
    ) MachineError!driver_completion.Progress {
        const context = &scanning.context;
        const tar = archive.bytes.borrow().bytes();
        if (context.tar_offset == tar.len) {
            if (context.zero_blocks < 2) return self.failDomain(fiber, "tar archive has no end marker");
            scanning.work = .allocate_results;
            return .stepped;
        }
        if (context.tar_offset + tar_block_bytes > tar.len)
            return self.failDomain(fiber, "truncated tar header");
        const header: *const [tar_block_bytes]u8 = @ptrCast(tar[context.tar_offset..][0..tar_block_bytes]);
        if (allZero(header)) {
            if (context.pending_path != null or context.pending_size != null)
                return self.failDomain(fiber, "tar extension has no following member");
            context.zero_blocks += 1;
            context.tar_offset += tar_block_bytes;
            if (context.zero_blocks == 2) scanning.work = .trailing_zeroes;
            return .stepped;
        }
        if (context.zero_blocks != 0) return self.failDomain(fiber, "tar data follows an end marker");
        if (!validChecksum(header)) return self.failDomain(fiber, "tar header checksum is invalid");
        const header_size = parseTarNumber(header[124..136]) orelse
            return self.failDomain(fiber, "tar member size is malformed");
        const typeflag = header[156];
        const data_offset = context.tar_offset + tar_block_bytes;
        const header_data_end = std.math.add(usize, data_offset, std.math.cast(usize, header_size) orelse
            return self.failDomain(fiber, "tar member size exceeds addressable memory")) catch
            return self.failDomain(fiber, "tar member size overflows");
        const header_next = paddedTarOffset(header_data_end) orelse
            return self.failDomain(fiber, "tar member padding overflows");
        if (header_next > tar.len) return self.failDomain(fiber, "truncated tar member");

        if (typeflag == 'x') {
            scanning.work = .{ .parse_pax = .{
                .offset = data_offset,
                .end = header_data_end,
                .next_offset = header_next,
            } };
            return .stepped;
        }
        if (typeflag == 'L') {
            if (header_size == 0 or header_size > max_path_bytes + 1)
                return self.failDomain(fiber, "GNU long name exceeds the path limit");
            if (context.pending_path) |*old| old.deinit(fiber.releases, self.allocator);
            const raw = tar[data_offset..header_data_end];
            const trimmed = std.mem.trimEnd(u8, raw, "\x00");
            context.pending_path = .init(try self.allocator.dupe(u8, trimmed));
            context.tar_offset = header_next;
            return .stepped;
        }

        const kind: EntryKind = switch (typeflag) {
            0, '0' => .file,
            '5' => .directory,
            '1', '2' => return self.failDomain(fiber, "tar links are not permitted"),
            '3', '4', '6' => return self.failDomain(fiber, "tar special nodes are not permitted"),
            else => return self.failDomain(fiber, "tar member kind is unsupported"),
        };
        const effective_size = context.pending_size orelse header_size;
        context.pending_size = null;
        if (effective_size > max_tar_bytes)
            return self.failDomain(fiber, "tar member exceeds the 1 GiB uncompressed limit");
        if (kind == .directory and effective_size != 0)
            return self.failDomain(fiber, "tar directory has file content");
        const effective_end = std.math.add(usize, data_offset, std.math.cast(usize, effective_size) orelse
            return self.failDomain(fiber, "tar member size exceeds addressable memory")) catch
            return self.failDomain(fiber, "tar member size overflows");
        const next_offset = paddedTarOffset(effective_end) orelse
            return self.failDomain(fiber, "tar member padding overflows");
        if (next_offset > tar.len) return self.failDomain(fiber, "truncated tar member");
        const path = try self.memberPath(context, header);
        errdefer self.allocator.free(path);
        if (!validMemberPath(path)) return self.failDomain(fiber, "tar member path is unsafe");
        context.member_count += 1;
        if (context.member_count > max_members)
            return self.failDomain(fiber, "archive exceeds the 100000 member limit");
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
        return .stepped;
    }

    fn parsePaxRecord(
        self: *ReadDriver,
        fiber: *Fiber,
        archive: *Archive,
        scanning: *Scanning,
        pax: *Pax,
    ) MachineError!driver_completion.Progress {
        if (pax.offset == pax.end) {
            scanning.context.tar_offset = pax.next_offset;
            scanning.work = .tar_header;
            return .stepped;
        }
        const tar = archive.bytes.borrow().bytes();
        var space = pax.offset;
        while (space != pax.end and tar[space] != ' ') : (space += 1) {
            if (space - pax.offset >= 20 or tar[space] < '0' or tar[space] > '9')
                return self.failDomain(fiber, "PAX record length is malformed");
        }
        if (space == pax.end) return self.failDomain(fiber, "PAX record is truncated");
        const record_len = std.fmt.parseInt(usize, tar[pax.offset..space], 10) catch
            return self.failDomain(fiber, "PAX record length is malformed");
        if (record_len <= space - pax.offset + 2 or record_len > pax.end - pax.offset)
            return self.failDomain(fiber, "PAX record length is invalid");
        const record_end = pax.offset + record_len;
        if (tar[record_end - 1] != '\n') return self.failDomain(fiber, "PAX record lacks a newline");
        const moved = pax.*;
        scanning.work = .{ .scan_pax = .{
            .pax = moved,
            .record_end = record_end,
            .key_start = space + 1,
            .scan_offset = space + 1,
        } };
        return .stepped;
    }

    fn scanPaxRecord(
        self: *ReadDriver,
        fiber: *Fiber,
        archive: *Archive,
        scanning: *Scanning,
        scan: *@FieldType(ScanWork, "scan_pax"),
    ) MachineError!driver_completion.Progress {
        const tar = archive.bytes.borrow().bytes();
        const payload_end = scan.record_end - 1;
        const end = scan.scan_offset + fiber.workBudget().take(payload_end - scan.scan_offset);
        const equals_relative = std.mem.indexOfScalar(u8, tar[scan.scan_offset..end], '=') orelse {
            scan.scan_offset = end;
            if (end == payload_end) return self.failDomain(fiber, "PAX record lacks a value");
            return .stepped;
        };
        const equals = equals_relative + scan.scan_offset;
        const key = tar[scan.key_start..equals];
        const field = tar[equals + 1 .. payload_end];
        if (std.mem.eql(u8, key, "path")) {
            if (field.len == 0 or field.len > max_path_bytes)
                return self.failDomain(fiber, "PAX path exceeds the path limit");
            if (scanning.context.pending_path) |*old| old.deinit(fiber.releases, self.allocator);
            scanning.context.pending_path = .init(try self.allocator.dupe(u8, field));
        } else if (std.mem.eql(u8, key, "size")) {
            if (field.len == 0 or field.len > 20)
                return self.failDomain(fiber, "PAX size is malformed");
            scanning.context.pending_size = std.fmt.parseInt(u64, field, 10) catch
                return self.failDomain(fiber, "PAX size is malformed");
        }
        const pax = scan.pax;
        scanning.work = .{ .parse_pax = .{
            .offset = scan.record_end,
            .end = pax.end,
            .next_offset = pax.next_offset,
        } };
        return .stepped;
    }

    fn memberPath(
        self: *ReadDriver,
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
        self: *ReadDriver,
        fiber: *Fiber,
        archive: *Archive,
        scanning: *Scanning,
        insertion: *@FieldType(ScanWork, "insert_member"),
    ) MachineError!driver_completion.Progress {
        const entry = &insertion.entry;
        const work = fiber.workBudget();
        while (work.spend()) {
            const slot = &archive.slots.borrow()[insertion.slot];
            if (slot.*) |prior| {
                if (std.mem.eql(u8, prior.path, entry.path))
                    return self.failDomain(fiber, "tar archive contains a duplicate member path");
                insertion.probes += 1;
                if (insertion.probes == member_slots)
                    return self.failDomain(fiber, "tar member table is full");
                insertion.slot = (insertion.slot + 1) & (member_slots - 1);
                continue;
            }
            const stored = try self.entries.borrowMut().appendPtr(entry.*);
            slot.* = stored;
            scanning.context.tar_offset = insertion.next_offset;
            scanning.work = .tar_header;
            return .stepped;
        }
        return .stepped;
    }

    fn trailingZeroes(
        self: *ReadDriver,
        fiber: *Fiber,
        archive: *Archive,
        scanning: *Scanning,
    ) MachineError!driver_completion.Progress {
        const tar = archive.bytes.borrow().bytes();
        const end = scanning.context.tar_offset + fiber.workBudget().take(tar.len - scanning.context.tar_offset);
        for (tar[scanning.context.tar_offset..end]) |byte| if (byte != 0)
            return self.failDomain(fiber, "tar data follows its end marker");
        scanning.context.tar_offset = end;
        if (end != tar.len) return .stepped;
        scanning.work = .allocate_results;
        return .stepped;
    }

    fn allocateResults(self: *ReadDriver, scanning: *Scanning) MachineError!driver_completion.Progress {
        const values = try self.allocator.alloc(Value, scanning.context.member_count);
        scanning.work = .{ .materialize_members = .{
            .inputs = .{ .values = values },
            .iterator = self.entries.borrow().iterator(),
        } };
        return .stepped;
    }

    fn materializeMembers(
        self: *ReadDriver,
        fiber: *Fiber,
        archive: *Archive,
        scanning: *Scanning,
        members: *@FieldType(ScanWork, "materialize_members"),
    ) MachineError!driver_completion.Progress {
        switch (members.work) {
            .text => |*text| switch (text.materializer.advance(fiber.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return self.failDomain(fiber, "tar member path is not valid UTF-8"),
            }) {
                .pending => return .stepped,
                .complete => |path_value| {
                    var completed = text.materializer;
                    const entry = text.entry;
                    members.work = .{ .contents = .{
                        .path = path_value,
                        .kind = entry.kind,
                        .materializer = .init(
                            self.allocator,
                            archive.bytes.borrow().bytes()[entry.data_offset..][0..entry.size],
                        ),
                    } };
                    completed.deinit();
                    return .stepped;
                },
            },
            .contents => |*contents| switch (try contents.materializer.advance(fiber.workBudget())) {
                .pending => return .stepped,
                .complete => |bytes| {
                    var completed = contents.materializer;
                    const path = contents.path;
                    const kind = contents.kind;
                    members.work = .next;
                    completed.deinit();
                    defer fiber.releases.releaseValue(path);
                    defer fiber.releases.releaseValue(bytes);
                    members.inputs.values[members.inputs.built] = try @import("../dict.zig").fromUniquePairs(
                        self.allocator,
                        fiber.releases,
                        &.{
                            .{ .{ .symbol = .{ .name = try intern.intern("path") } }, path },
                            .{ .{ .symbol = .{ .name = try intern.intern("kind") } }, .{ .symbol = .{ .name = try intern.intern(@tagName(kind)) } } },
                            .{ .{ .symbol = .{ .name = try intern.intern("bytes") } }, bytes },
                        },
                    );
                    members.inputs.built += 1;
                    return .stepped;
                },
            },
            .next => {},
        }
        const entry = members.iterator.next() orelse {
            const inputs = members.inputs;
            scanning.work = .{ .materialize_result = .{
                .inputs = inputs,
                .materializer = .init(self.allocator, inputs.values),
            } };
            return .stepped;
        };
        members.work = .{ .text = .{ .materializer = .init(self.allocator, entry.path), .entry = entry } };
        return .stepped;
    }

    fn materializeResult(
        fiber: *Fiber,
        scanning: *Scanning,
        materialization: *@FieldType(ScanWork, "materialize_result"),
    ) MachineError!driver_completion.Progress {
        return switch (try materialization.materializer.advance(fiber.workBudget())) {
            .pending => .stepped,
            .complete => |result| result: {
                var completed = materialization.materializer;
                const inputs = materialization.inputs;
                scanning.work = .{ .release_result_inputs = .{
                    .release = .{ .values = inputs.values, .built = inputs.built },
                    .result = result,
                } };
                completed.deinit();
                break :result .stepped;
            },
        };
    }

    fn releaseResultInputs(
        self: *ReadDriver,
        fiber: *Fiber,
        scanning: *Scanning,
        release: *@FieldType(ScanWork, "release_result_inputs"),
    ) driver_completion.Progress {
        if (release.release.index != release.release.built) {
            fiber.releases.releaseValue(release.release.values[release.release.index]);
            release.release.index += 1;
            return .stepped;
        }
        const result = release.result;
        self.allocator.free(release.release.values);
        scanning.work = .complete;
        return .{ .output = result };
    }

    fn failDomain(self: *ReadDriver, fiber: *Fiber, message: []const u8) MachineError {
        _ = self;
        return fiber.fail(.domain, message);
    }

    fn retireArchive(
        archive: *Archive,
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
    ) void {
        archive.slots.deinit(releases, allocator);
        archive.bytes.deinit(releases, allocator);
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
            .materialize_members => |*members| result: {
                switch (members.work) {
                    .text => |*text| text.materializer.retire(releases),
                    .contents => |*contents| {
                        contents.materializer.retire(releases);
                        releases.releaseValue(contents.path);
                    },
                    .next => {},
                }
                break :result .{ .results = .{
                    .values = members.inputs.values,
                    .built = members.inputs.built,
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
            .encode_bytes => |*encoder| encoder.deinit(releases, allocator),
            .allocate_slots => |*bytes| bytes.deinit(releases, allocator),
            .initialize_slots => |*initialization| {
                initialization.bytes.deinit(releases, allocator);
                initialization.slots.deinit(releases, allocator);
            },
        }
    }

    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *ReadDriver,
    ) bool {
        if (!self.completion.retire(self, releases, allocator)) return false;
        allocator.destroy(self);
        return true;
    }

    pub fn advanceCleanup(self: *ReadDriver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) bool {
        switch (self.state) {
            .parsing => |*parsing| {
                retireParsing(parsing, releases, allocator);
                self.state = .{ .cleanup = .{
                    .entries = self.entries.borrow().reverseIterator(),
                } };
                return false;
            },
            .active => |*active| {
                const retirement = retireScanning(&active.scanning, releases, allocator);
                const archive = takeArchive(&active.archive);
                self.state = switch (retirement) {
                    .plain => .{ .cleanup_archive = archive },
                    .results => |release| .{ .cleanup_archive_with_results = .{
                        .archive = archive,
                        .release = release,
                    } },
                };
                return false;
            },
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
        self.entries.deinit(releases, allocator);
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
