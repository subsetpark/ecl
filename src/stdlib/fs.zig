//! Filesystem words over named roots and scope-owned directory resources.
//!
//! Each confined operation selects a root and a canonical relative path; the
//! Session's filesystem owner turns a symbol into a retained directory
//! handle and `filesystem_port` resolves the path beneath it one component
//! per scheduler step. Reads, writes, copies, and listings advance in fixed
//! quanta; mutation stages into a private sibling entry and publishes with one
//! atomic namespace operation. The driver owns every handle, staging entry,
//! and quota reservation until its bounded cleanup releases them.

const std = @import("std");
const driver_completion = @import("../driver_completion.zig");
const dict = @import("../dict.zig");
const directory_order = @import("../directory_order.zig");
const env = @import("../env.zig");
const external = @import("../external.zig");
const directory = @import("../directory_resource.zig");
const fsport = @import("../filesystem_port.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const kernel_storage = @import("../kernel_storage.zig");
const list = @import("../list.zig");
const machine = @import("../machine.zig");
const poll = @import("../poll.zig");
const value = @import("../value.zig");

const Unit = machine.Unit;
const MachineError = machine.MachineError;
const Value = value.Value;

pub const words = [_]env.BuiltinWord{
    .{ .name = "reserve", .effect = "root -- reservation", .doc = "Retain a selected directory root and one filesystem operation slot until joined closure. A reservation can be passed as a root; its derived operations share that slot and reject overlapping work with `` `overflow `` and reason `` `limit ``. Closure waits for admitted work. This supports compositions that must retain admission across inspection and publication.", .primitive = reserve },
    .{ .name = "open-writer", .effect = "root path -- writer", .doc = "Open private storage for an absent regular file. The parent must exist and `.` is rejected. A writer is distinct from a directory. It retains root lifetime and operation admission until joined cleanup. Staging dependencies survive task transfer. Closing an uncommitted writer removes its private contents and publishes no destination.", .primitive = openWriter },
    .{ .name = "open-reader", .effect = "root path -- fd", .doc = "Open a regular file, following a final link within the root, as a readable byte endpoint for `fd.read`, `fd.read-line`, `fd.read-all` and the `io` readers, with no size limit: the stream is read a chunk at a time. The calling scope owns the file; `fd.close` closes it earlier and joins cleanup, and a read after either is `` `io ``. A directory is `` `is-directory ``; a non-regular object is `` `not-regular ``.", .primitive = openReader },
    .{ .name = "write-chunk", .effect = "writer bytes --", .doc = "Append at most 65536 integer bytes. The streaming transfer limit (1 GiB by default) covers the complete stream, including previous chunks. A failed or cancelled append after writer admission prevents later publication of partial contents; a validation failure before admission does not.", .primitive = writeChunk },
    .{ .name = "commit-file", .effect = "writer --", .doc = "Stop admission, flush the completed stream, and atomically publish its previously absent destination. Publication is serialized against cancellation. Success joins writer cleanup; failure retains unpublished private state for explicit or scope cleanup. No allocation is required after the publication permit is granted.", .primitive = commitFile },
    .{ .name = "open-list", .effect = "root path -- cursor", .doc = "Open a scope-owned incremental enumeration of a confined directory. The cursor is a port resource, distinct from a directory root. It owns its descriptor until `port.close` or scope exit. An enumeration opened through staging or its descendants also closes when staging seals.", .primitive = openList },
    .{ .name = "next-entry", .effect = "cursor -- entry", .doc = "Return the next `{name string kind symbol}` dictionary, or `{}` at stable end. Kinds are `` `file ``, `` `directory ``, `` `symlink ``, and `` `other ``; dot entries are omitted and symlinks are described without following them. Names must be UTF-8. Order and visibility of concurrent namespace changes follow the host filesystem; this is not a directory snapshot. Concurrent calls reserve distinct entries, though their results may complete out of order. Each result owns its name independently of subsequent calls or cursor closure. A closed cursor raises `` `io ``. Reading does not materialize the whole directory or apply the aggregate limits of `list`; callers can stop and close at any entry.", .primitive = nextEntry },
    .{ .name = "stage-dir", .effect = "root destination -- stage", .doc = "Create a private sibling of the destination and return a scope-owned directory resource. The destination parent must exist. Filesystem operations accept the stage as a root. `port.close` or scope exit joins descendant closure and recursive rollback; no destination is published. The staging directory uses mode `0700` under the process umask.", .primitive = stageDirectory },
    .{ .name = "commit-dir", .effect = "stage --", .doc = "Seal the stage, reject further operations, close its descendant resources, and wait for admitted operations before atomically publishing to the absent destination. Any existing entry causes an `` `io `` failure and is preserved; failure retains the sealed staging resource for joined cleanup with `port.close`. Success joins descriptor closure and keeps the published tree even if the task is subsequently cancelled. Namespace publication is atomic; directory-entry durability across a host crash is not promised.", .primitive = commitDirectory },
    .{ .name = "mkdirs", .effect = "root path --", .doc = "Create missing intermediate and final directories. Existing directories are preserved, including contained symlink targets. `.` is a no-op. Every component uses the ordinary confined resolver. Failure or cancellation may leave directories created before that point.", .primitive = makeDirectories },
    .{ .name = "remove-tree", .effect = "root path --", .doc = "Recursively remove a directory and its contents. The final entry must be a directory, and `.` is rejected. Symlinks inside the tree are removed without following their targets. Work is incremental and cancellable; failure may leave partially removed contents with temporary entry names. Removal uses bounded descriptor storage and needs no new allocations once the selected directory has been opened.", .primitive = removeTree },
    .{ .name = "lock", .effect = "root path -- lock", .doc = "Acquire an exclusive advisory lock on a regular file, creating an empty file if the path is absent. Existing contents are preserved; final symlinks and non-regular files are rejected. Contention parks the task between attempts and is cancellable. The returned port owns the lock until `port.close` or its owning scope exits. A lock is not a directory resource. The lock file remains after release. Coordinating applications must keep its directory entry in place: replacing or deleting it establishes a different lock identity. Advisory locking coordinates participating applications and does not prevent other filesystem access.", .primitive = advisoryLock },
    .{ .name = "open-dir", .effect = "host-path -- directory", .doc = "Open an absolute host directory path, subject to OS permissions, and return a scope-owned port resource. Host symlinks may be followed while opening this explicit root. Relative paths are rejected. `port.close` closes the resource and joins cleanup; scope exit does the same. A closing directory rejects new operations with `` `io ``. Closure waits for admitted operations to release their independent descriptor leases, then joins backend cleanup.", .primitive = openDirectory },
    .{ .name = "child-dir", .effect = "root path -- directory", .doc = "Acquire an independent directory resource beneath an existing root. Resolution, including final symlinks, is confined to that root. The acquired directory becomes the new containment boundary; closing its ordinary parent resource does not close it. Children of a staging resource, including further descendants, close when staging is sealed or closed even after task ownership transfer. `.` acquires the root itself.", .primitive = childDirectory },
    .{ .name = "read-bytes", .effect = "root path -- bytes", .doc = "Read one regular file, following a final link within the root, and return its exact bytes as an integer list. The size observed at open is the size read; growth or shrink meanwhile fails with `` `io `` and reason `` `changed ``. A directory fails with `` `io `` and reason `` `is-directory ``; a non-regular object fails with `` `io `` and reason `` `not-regular ``; a file over the transfer limit is `` `overflow ``.", .primitive = readBytes },
    .{ .name = "read-text", .effect = "root path -- string", .doc = "Read one regular file as `read-bytes` does and decode it as UTF-8. Invalid UTF-8 is `` `io `` with reason `` `invalid-utf8 ``.", .primitive = readText },
    .{ .name = "create-bytes", .effect = "bytes root path --", .doc = "Atomically create an absent regular file holding exact bytes. Members are validated before any external state exists. An existing regular file, directory, symlink (including a dangling one), or other entry fails with `` `io `` and reason `` `already-exists ``; a missing parent fails with `` `io `` and reason `` `not-found ``.", .primitive = createBytes },
    .{ .name = "create-text", .effect = "string root path --", .doc = "Atomically create an absent regular file holding the string as UTF-8, with the same collision contract as `create-bytes`.", .primitive = createText },
    .{ .name = "replace-bytes", .effect = "bytes root path --", .doc = "Atomically replace an existing regular file with exact bytes. The final entry must be observed as a regular file without following: absence fails with `` `io `` and reason `` `not-found ``, and a symlink, directory, or other entry fails with `` `io `` and reason `` `not-regular ``. The replacement is a new inode published by an atomic exchange; the word never becomes create-or-replace.", .primitive = replaceBytes },
    .{ .name = "replace-text", .effect = "string root path --", .doc = "Replace an existing regular file with UTF-8 text under the `replace-bytes` contract.", .primitive = replaceText },
    .{ .name = "publish-bytes", .effect = "bytes root path --", .doc = "Atomically publish complete file contents, creating an absent destination or replacing one that exists. An entry observed before staging must be a regular file; a symlink, directory, or other entry is `` `not-regular ``. Use the observed file's permissions, or host defaults on first creation. Publication replaces the final directory entry without following it; concurrent publications each succeed and the last commit wins. An intervening directory causes failure. A failed operation preserves its destination, and cancellation before commit removes staging. Cancellation after commit does not roll back publication. Visibility is atomic; directory-entry durability across a crash is not promised.", .primitive = publishBytes },
    .{ .name = "publish-text", .effect = "string root path --", .doc = "Publish UTF-8 text under the `publish-bytes` contract.", .primitive = publishText },
    .{ .name = "stat", .effect = "root path -- metadata", .doc = "Follow the path, including a final link within the root, and describe the object reached with the same shapes as `lstat`. A dangling link fails with `` `io `` and reason `` `not-found ``.", .primitive = stat },
    .{ .name = "lstat", .effect = "root path -- metadata", .doc = "Describe the final entry without following it: `{kind file size n}` for a regular file, `{kind directory}`, `{kind symlink}`, or `{kind other}`. An absent entry fails with `` `io `` and reason `` `not-found ``.", .primitive = lstat },
    .{ .name = "exists?", .effect = "root path -- bool", .doc = "Return 1 when the final entry exists and 0 when it is definitely absent, without following a final link: a dangling link is 1. Malformed paths, unknown roots, denial, traversal failures such as a missing or escaping intermediate component, and host failures are errors rather than 0.", .primitive = exists },
    .{ .name = "list", .effect = "root path -- entries", .doc = "Follow the path to a directory and return its children as `{name string kind file}`, `{name string kind directory}`, `{name string kind symlink}`, or `{name string kind other}`, classified without following, excluding `.` and `..`, and sorted by Unicode scalar order of `` `name ``. A child name that is not valid UTF-8, an entry that vanishes or cannot be classified, or an exceeded listing limit fails the whole listing; nothing is silently omitted.", .primitive = listDirectory },
    .{ .name = "mkdir", .effect = "root path --", .doc = "Create exactly one absent directory beneath an existing parent. There is no recursive parent creation; an existing entry of any kind fails with `` `io `` and reason `` `already-exists ``.", .primitive = mkdir },
    .{ .name = "copy", .effect = "source-root source-path destination-root destination-path --", .doc = "Copy a regular file, following a final source link within its root, into an absent destination entry; the roots may differ. The copy is staged and published atomically without replacing; an existing destination of any kind fails with `` `io `` and reason `` `already-exists ``, a non-regular source fails with `` `io `` and reason `` `not-regular `` or `` `is-directory ``, and the copy keeps the source file's permissions.", .primitive = copy },
    .{ .name = "rename", .effect = "root source-path destination-path --", .doc = "Rename an entry within one root without replacing. The source may be a regular file, symlink, or directory and is not followed; an existing destination fails with `` `io `` and reason `` `already-exists ``, and a destination on another device fails with `` `io `` and reason `` `cross-device `` rather than an emulated copy.", .primitive = rename },
    .{ .name = "remove-file", .effect = "root path --", .doc = "Remove one non-directory entry, including a symlink itself, without following it. A directory fails with `` `io `` and reason `` `is-directory ``.", .primitive = removeFile },
    .{ .name = "remove-dir", .effect = "root path --", .doc = "Remove one empty directory without following a final link. A nonempty directory fails with `` `io `` and reason `` `not-empty ``; a file or symlink fails with `` `io `` and reason `` `not-directory ``.", .primitive = removeDir },
};

const Operation = enum {
    reserve,
    open_writer,
    open_reader,
    open_list,
    stage_dir,
    mkdirs,
    remove_tree,
    lock,
    open_dir,
    child_dir,
    read_bytes,
    read_text,
    create_bytes,
    create_text,
    replace_bytes,
    replace_text,
    publish_bytes,
    publish_text,
    stat,
    lstat,
    exists,
    list,
    mkdir,
    copy,
    rename,
    remove_file,
    remove_dir,

    fn name(self: Operation) []const u8 {
        return switch (self) {
            .open_list => "open-list",
            .open_writer => "open-writer",
            .open_reader => "open-reader",
            .stage_dir => "stage-dir",
            .open_dir => "open-dir",
            .child_dir => "child-dir",
            .read_bytes => "read-bytes",
            .read_text => "read-text",
            .create_bytes => "create-bytes",
            .create_text => "create-text",
            .replace_bytes => "replace-bytes",
            .replace_text => "replace-text",
            .publish_bytes => "publish-bytes",
            .publish_text => "publish-text",
            .exists => "exists?",
            .remove_tree => "remove-tree",
            .remove_file => "remove-file",
            .remove_dir => "remove-dir",
            .reserve, .mkdirs, .lock, .stat, .lstat, .list, .mkdir, .copy, .rename => @tagName(self),
        };
    }

    const Shape = enum { host, root, unary, payload, copy, rename };

    fn shape(self: Operation) Shape {
        return switch (self) {
            .open_dir => .host,
            .reserve => .root,
            .create_bytes, .create_text, .replace_bytes, .replace_text, .publish_bytes, .publish_text => .payload,
            .copy => .copy,
            .rename => .rename,
            else => .unary,
        };
    }

    fn textPayload(self: Operation) bool {
        return self == .create_text or self == .replace_text or self == .publish_text;
    }

    fn resolveMode(self: Operation) fsport.ResolveMode {
        return switch (self) {
            .open_list, .mkdirs, .child_dir, .open_reader, .read_bytes, .read_text, .stat, .list, .copy => .follow_final,
            else => .no_follow_final,
        };
    }

    /// Words that act on a child entry reject `.`, which names the root.
    fn requiresEntry(self: Operation) bool {
        return switch (self) {
            .open_writer, .stage_dir, .create_bytes, .create_text, .replace_bytes, .replace_text, .publish_bytes, .publish_text, .lock, .mkdir, .rename, .remove_tree, .remove_file, .remove_dir => true,
            .reserve, .open_list, .mkdirs, .open_dir, .child_dir, .open_reader, .read_bytes, .read_text, .stat, .lstat, .exists, .list, .copy => false,
        };
    }
};

fn reserve(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .reserve);
}
fn openWriter(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .open_writer);
}
fn openReader(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .open_reader);
}

fn openList(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .open_list);
}
fn nextEntry(evaluator: *Unit) MachineError!void {
    var cursor = try evaluator.popValue();
    errdefer cursor.deinit();
    if (!directory.isEnumeration(cursor.borrow())) return evaluator.typeError("a directory enumeration resource");
    const driver = try evaluator.allocator.create(NextEntry);
    // SAFETY: reading initializes entry before the name phase uses it.
    driver.* = .{ .cursor = cursor.take(), .entry = undefined };
    evaluator.adoptDriver(driver);
}
const NextEntry = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    cursor: Value,
    entry: directory.Entry,
    state: union(enum) { reading, name: kernel_storage.Utf8Materializer, complete } = .reading,
    pub fn deinit(self: *@This(), releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        if (self.state == .name) self.state.name.retire(releases);
        releases.releaseValue(self.cursor);
    }
    pub fn advance(evaluator: *Unit, self: *@This()) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .reading) switch (directory.next(self.cursor)) {
            .pending => return .stepped,
            .closed => return evaluator.fail(.io, "directory enumeration is closed"),
            .failed => |reason| return evaluator.fail(errorKindFor(reason), reason.message()),
            .end => {
                self.state = .complete;
                return .{ .output = try dict.fromUniquePairs(evaluator.allocator, evaluator.releases, &.{}) };
            },
            .entry => |entry| {
                self.entry = entry;
                self.state = .{ .name = .init(evaluator.allocator, self.entry.name[0..self.entry.length]) };
            },
        };
        return switch (self.state.name.advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return evaluator.fail(.io, "directory entry is not UTF-8"),
        }) {
            .pending => .stepped,
            .complete => |name| result: {
                self.state.name.deinit();
                self.state = .complete;
                defer evaluator.releases.releaseValue(name);
                break :result .{ .output = try dict.fromUniquePairs(evaluator.allocator, evaluator.releases, &.{
                    .{ .{ .symbol = .{ .name = try intern.intern("name") } }, name },
                    .{ .{ .symbol = .{ .name = try intern.intern("kind") } }, .{ .symbol = .{ .name = try intern.intern(self.entry.kind.symbol()) } } },
                }) };
            },
        };
    }
};

fn stageDirectory(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .stage_dir);
}
fn commitDirectory(evaluator: *Unit) MachineError!void {
    var stage = try evaluator.popValue();
    errdefer stage.deinit();
    if (!directory.isStage(stage.borrow())) return evaluator.typeError("a directory staging resource");
    const driver = try evaluator.allocator.create(CommitDirectory);
    driver.* = .{ .stage = stage.take() };
    evaluator.adoptDriver(driver);
}
fn commitFile(evaluator: *Unit) MachineError!void {
    var writer = try evaluator.popValue();
    errdefer writer.deinit();
    if (!directory.isStream(writer.borrow())) return evaluator.typeError("a filesystem writer resource");
    const driver = try evaluator.allocator.create(CommitDirectory);
    driver.* = .{ .stage = writer.take(), .kind = .file };
    evaluator.adoptDriver(driver);
}
const CommitDirectory = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    stage: Value,
    kind: enum { directory, file } = .directory,
    state: enum { sealing, joining } = .sealing,
    pub fn deinit(self: *@This(), releases: *heap.ReleaseDomain, _: std.mem.Allocator) void {
        releases.releaseValue(self.stage);
    }
    pub fn advance(evaluator: *Unit, self: *@This()) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        if (self.state == .sealing) switch (if (self.kind == .directory) directory.commit(self.stage) else directory.commitFile(self.stage)) {
            .closed => return failResource(evaluator, self.stage, if (self.kind == .directory) "commit-dir" else "commit-file", .io),
            .failed => |reason| return failResource(evaluator, self.stage, if (self.kind == .directory) "commit-dir" else "commit-file", reason),
            .pending => |source| {
                try evaluator.park(.{ .external = source });
                return .{ .yielded = .park };
            },
            .committed => self.state = .joining,
        };
        const port = @import("../port_resource.zig").Resource.fromValue(self.stage).?;
        if (!port.joined()) {
            try evaluator.park(.{ .external = port.source() });
            return .{ .yielded = .park };
        }
        return .completed;
    }
};

fn failResource(evaluator: *Unit, item: Value, operation: []const u8, reason: fsport.Reason) MachineError {
    const operation_symbol = try intern.intern(operation);
    const reason_symbol = try reasonSymbol(reason);
    const path = try list.fromCodepoints(evaluator.allocator, &.{'.'});
    defer evaluator.releases.releaseValue(path);
    const failure = evaluator.fail(errorKindFor(reason), reason.message());
    evaluator.addErrorFilesystem(.{
        .operation = .{ .symbol = .{ .name = operation_symbol } },
        .reason = .{ .symbol = .{ .name = reason_symbol } },
        .target = .{ .single = .{ .root = item, .path = path } },
    });
    return failure;
}

fn writeChunk(evaluator: *Unit) MachineError!void {
    try evaluator.require(2);
    var payload = try evaluator.popValue();
    errdefer payload.deinit();
    if (payload.borrow() != .list) return evaluator.typeError("a byte list to write");
    var writer = try evaluator.popValue();
    errdefer writer.deinit();
    if (!directory.isStream(writer.borrow())) return evaluator.typeError("a filesystem writer resource");
    const driver = try evaluator.allocator.create(WriteChunk);
    driver.* = .{ .writer = writer.take(), .payload = payload.take() };
    evaluator.adoptDriver(driver);
}
const WriteChunk = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .self_owned;
    writer: Value,
    payload: Value,
    claim: ?*directory.WriteClaim = null,
    state: union(enum) { validating: usize, waiting, admitted, encoding: kernel_storage.ByteVectorEncoder, writing: kernel_storage.ByteVector } = .{ .validating = 0 },
    pub fn deinit(self: *@This(), releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self.state) {
            .validating, .waiting, .admitted => {},
            .encoding => |*encoder| encoder.deinit(),
            .writing => |*bytes| bytes.retire(releases, allocator),
        }
        if (self.claim) |claim| claim.deinit();
        releases.releaseValue(self.writer);
        releases.releaseValue(self.payload);
    }
    pub fn advance(evaluator: *Unit, self: *@This()) MachineError!machine.WorkProgress {
        try evaluator.pollKernel();
        switch (self.state) {
            .validating => |*index| {
                const count = self.payload.list.length();
                if (self.payload.list.kind() != .leaf_u8) {
                    const end = index.* + evaluator.workBudget().take(count - index.*);
                    while (index.* < end) : (index.* += 1) {
                        const item = list.atUnchecked(self.payload, index.*);
                        if (item != .int or item.int < 0 or item.int > 255)
                            return evaluator.failAtIndex(.type, "byte list members must be integers from 0 through 255", index.*);
                    }
                    if (index.* != count) return .stepped;
                }
                self.state = .waiting;
            },
            .waiting => switch (try directory.acquireWrite(self.writer)) {
                .closed => return failResource(evaluator, self.writer, "write-chunk", .io),
                .failed => |reason| return failResource(evaluator, self.writer, "write-chunk", reason),
                .pending => |source| {
                    try evaluator.park(.{ .external = source });
                    return .{ .yielded = .park };
                },
                .claimed => |claim| {
                    self.claim = claim;
                    self.state = .admitted;
                },
            },
            .admitted => {
                const claim = self.claim.?;
                if (!claim.ready()) {
                    try evaluator.park(.{ .external = claim.source() });
                    return .{ .yielded = .park };
                }
                if (self.payload.list.length() > @min(fsport.transfer_quantum, claim.remaining())) {
                    claim.fail(.limit);
                    return failResource(evaluator, self.writer, "write-chunk", .limit);
                }
                self.state = .{ .encoding = .init(evaluator.allocator, self.payload) };
            },
            .encoding => |*encoder| switch (encoder.advance(evaluator.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidByte => return evaluator.failAtIndex(.type, "byte list members must be integers from 0 through 255", encoder.invalid_index.?),
            }) {
                .pending => {},
                .complete => |bytes| {
                    encoder.deinit();
                    self.state = .{ .writing = bytes };
                },
            },
            .writing => |*bytes| {
                switch (self.claim.?.append(bytes.bytes())) {
                    .written => {
                        evaluator.pollKernel() catch |err| {
                            self.claim.?.fail(.io);
                            @import("../port_resource.zig").Resource.fromValue(self.writer).?.close();
                            return err;
                        };
                        return .completed;
                    },
                    .failed => |reason| return failResource(evaluator, self.writer, "write-chunk", reason),
                    .pending => try evaluator.park(.{ .external = self.claim.?.source() }),
                }
            },
        }
        return evaluator.afterStep();
    }
};

fn makeDirectories(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .mkdirs);
}
fn removeTree(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .remove_tree);
}
fn advisoryLock(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .lock);
}
fn openDirectory(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .open_dir);
}
fn childDirectory(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .child_dir);
}

fn readBytes(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .read_bytes);
}
fn readText(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .read_text);
}
fn createBytes(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .create_bytes);
}
fn createText(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .create_text);
}
fn replaceBytes(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .replace_bytes);
}
fn replaceText(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .replace_text);
}
fn publishBytes(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .publish_bytes);
}
fn publishText(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .publish_text);
}
fn stat(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .stat);
}
fn lstat(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .lstat);
}
fn exists(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .exists);
}
fn listDirectory(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .list);
}
fn mkdir(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .mkdir);
}
fn copy(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .copy);
}
fn rename(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .rename);
}
fn removeFile(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .remove_file);
}
fn removeDir(evaluator: *Unit) MachineError!void {
    return begin(evaluator, .remove_dir);
}

/// The owned argument values, retained for error provenance until retirement.
const Inputs = struct {
    root: Value,
    path: Value,
    second_root: ?Value = null,
    second_path: ?Value = null,
    payload: ?Value = null,

    fn deinit(self: *Inputs, releases: *heap.ReleaseDomain) void {
        releases.releaseValue(self.root);
        releases.releaseValue(self.path);
        if (self.second_root) |item| releases.releaseValue(item);
        if (self.second_path) |item| releases.releaseValue(item);
        if (self.payload) |item| releases.releaseValue(item);
        // SAFETY: every owned value has been released; poisoning prevents an
        // accidental second release through this value.
        self.* = undefined;
    }
};

const Payload = union(enum) {
    bytes: kernel_storage.ByteVector,
    text: []u8,

    fn slice(self: *const Payload) []const u8 {
        return switch (self.*) {
            .bytes => |*bytes| bytes.bytes(),
            .text => |text| text,
        };
    }

    fn retire(self: *Payload, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .bytes => |*bytes| bytes.retire(releases, allocator),
            .text => |text| allocator.free(text),
        }
        // SAFETY: the active payload has been released; poisoning prevents an
        // accidental second disposal through this value.
        self.* = undefined;
    }
};

fn begin(evaluator: *Unit, operation: Operation) MachineError!void {
    const count: usize = switch (operation.shape()) {
        .host, .root => 1,
        .unary => 2,
        .payload, .rename => 3,
        .copy => 4,
    };
    try evaluator.require(count);
    // SAFETY: every arm of the switch below assigns the whole value before
    // it is read, and an arm that fails returns before reaching a read.
    var inputs: Inputs = undefined;
    switch (operation.shape()) {
        .root => {
            var root = try evaluator.popValue();
            errdefer root.deinit();
            if (!validRoot(root.borrow())) return evaluator.typeError("a root symbol or directory resource");
            const path = try list.fromCodepoints(evaluator.allocator, &.{'.'});
            inputs = .{ .root = root.take(), .path = path };
        },
        .host => {
            var path = try evaluator.popValue();
            errdefer path.deinit();
            if (!path.borrow().isString()) return evaluator.typeError("an absolute host directory path");
            inputs = .{ .root = .{ .symbol = .{ .name = try intern.intern("host") } }, .path = path.take() };
        },
        .unary => {
            var path = try evaluator.popValue();
            errdefer path.deinit();
            if (!path.borrow().isString()) return evaluator.typeError("a string path");
            var root = try evaluator.popValue();
            errdefer root.deinit();
            if (!validRoot(root.borrow())) return evaluator.typeError("a root symbol or directory resource");
            inputs = .{ .root = root.take(), .path = path.take() };
        },
        .payload => {
            var path = try evaluator.popValue();
            errdefer path.deinit();
            if (!path.borrow().isString()) return evaluator.typeError("a string path");
            var root = try evaluator.popValue();
            errdefer root.deinit();
            if (!validRoot(root.borrow())) return evaluator.typeError("a root symbol or directory resource");
            var payload = try evaluator.popValue();
            errdefer payload.deinit();
            if (operation.textPayload()) {
                if (!payload.borrow().isString()) return evaluator.typeError("a string to write");
            } else if (payload.borrow() != .list) return evaluator.typeError("a byte list to write");
            inputs = .{ .root = root.take(), .path = path.take(), .payload = payload.take() };
        },
        .copy => {
            var destination_path = try evaluator.popValue();
            errdefer destination_path.deinit();
            if (!destination_path.borrow().isString()) return evaluator.typeError("a string destination path");
            var destination_root = try evaluator.popValue();
            errdefer destination_root.deinit();
            if (!validRoot(destination_root.borrow())) return evaluator.typeError("a destination root symbol or directory resource");
            var source_path = try evaluator.popValue();
            errdefer source_path.deinit();
            if (!source_path.borrow().isString()) return evaluator.typeError("a string source path");
            var source_root = try evaluator.popValue();
            errdefer source_root.deinit();
            if (!validRoot(source_root.borrow())) return evaluator.typeError("a source root symbol or directory resource");
            inputs = .{
                .root = source_root.take(),
                .path = source_path.take(),
                .second_root = destination_root.take(),
                .second_path = destination_path.take(),
            };
        },
        .rename => {
            var destination_path = try evaluator.popValue();
            errdefer destination_path.deinit();
            if (!destination_path.borrow().isString()) return evaluator.typeError("a string destination path");
            var source_path = try evaluator.popValue();
            errdefer source_path.deinit();
            if (!source_path.borrow().isString()) return evaluator.typeError("a string source path");
            var root = try evaluator.popValue();
            errdefer root.deinit();
            if (!validRoot(root.borrow())) return evaluator.typeError("a root symbol or directory resource");
            heap.retainValue(root.borrow());
            inputs = .{
                .root = root.borrow(),
                .path = source_path.take(),
                .second_root = root.take(),
                .second_path = destination_path.take(),
            };
        },
    }
    errdefer inputs.deinit(evaluator.releases);
    const symbols = try Symbols.init(operation);
    const access = evaluator.inherited.runtime().filesystem_access;
    const driver = try evaluator.allocator.create(Driver);
    errdefer evaluator.allocator.destroy(driver);
    const path_cursor = kernel_storage.StringEncoder.init(evaluator.allocator, inputs.path);
    driver.* = .{
        .allocator = evaluator.allocator,
        .io = fsport.hostIo(access),
        .access = access,
        .limits = fsport.limitsOf(access),
        .operation = operation,
        .symbols = symbols,
        .inputs = inputs,
        .state = .{ .encode_path = path_cursor },
    };
    evaluator.adoptDriver(driver);
}

/// Interned spellings a failure or result needs, resolved before the driver
/// exists so later steps never allocate for a name.
const Symbols = struct {
    operation: u32,
    kind: u32,
    size: u32,
    name: u32,
    file: u32,
    directory: u32,
    symlink: u32,
    other: u32,

    fn init(operation: Operation) error{OutOfMemory}!Symbols {
        return .{
            .operation = try intern.intern(operation.name()),
            .kind = try intern.intern("kind"),
            .size = try intern.intern("size"),
            .name = try intern.intern("name"),
            .file = try intern.intern("file"),
            .directory = try intern.intern("directory"),
            .symlink = try intern.intern("symlink"),
            .other = try intern.intern("other"),
        };
    }

    fn entryKind(self: Symbols, kind: fsport.EntryKind) u32 {
        return switch (kind) {
            .file => self.file,
            .directory => self.directory,
            .symlink => self.symlink,
            .other => self.other,
        };
    }
};

fn reasonSymbol(reason: fsport.Reason) error{OutOfMemory}!u32 {
    return intern.intern(reason.symbol());
}

fn errorKindFor(reason: fsport.Reason) machine.ErrorKind {
    return switch (reason) {
        .invalid_path, .unknown_root => .domain,
        .limit => .overflow,
        else => .io,
    };
}

fn failInputs(
    evaluator: *Unit,
    kind: machine.ErrorKind,
    reason: fsport.Reason,
    operation: Operation,
    symbols: Symbols,
    inputs: *const Inputs,
) MachineError {
    const reason_symbol = try reasonSymbol(reason);
    const failure = evaluator.fail(kind, reason.message());
    evaluator.addErrorFilesystem(.{
        .operation = .{ .symbol = .{ .name = symbols.operation } },
        .reason = .{ .symbol = .{ .name = reason_symbol } },
        .target = if (operation == .copy) .{ .transfer = .{
            .source_root = inputs.root,
            .source_path = inputs.path,
            .destination_root = inputs.second_root.?,
            .destination_path = inputs.second_path.?,
        } } else .{ .single = .{ .root = inputs.root, .path = inputs.path } },
    });
    return failure;
}

const Listed = struct {
    name: []u8,
    kind: fsport.EntryKind,

    /// Names are valid UTF-8, so byte order is Unicode scalar order.
    fn lessThan(left: *const Listed, right: *const Listed) bool {
        return std.mem.order(u8, left.name, right.name) == .lt;
    }
};
const EntryList = poll.ChunkList(Listed);
const Orderer = directory_order.Orderer(Listed, Listed.lessThan);

fn validRoot(item: Value) bool {
    return fsport.isRoot(item);
}
const RootSelection = fsport.RootSelection;

const Driver = struct {
    pub const address_stable_driver = {};
    pub const ownership: heap.DriverOwnership = .bounded_retirement;

    retirement: heap.ReleaseDomain.Retirement = .{},
    completion: driver_completion.Completion = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    access: *external.FilesystemAccess,
    limits: fsport.Limits,
    operation: Operation,
    symbols: Symbols,
    inputs: Inputs,
    path: ?[]u8 = null,
    second_path: ?[]u8 = null,
    payload: ?Payload = null,
    root: ?RootSelection = null,
    second_root: ?RootSelection = null,
    slot: ?fsport.OperationSlot = null,
    resolved: ?fsport.Resolved = null,
    second: ?fsport.Resolved = null,
    /// Listing storage handed from a build state to the value-release
    /// retirement steps, freed after every built value is released.
    pending_entries: ?EntryList = null,
    state: State,

    const Read = struct {
        file: std.Io.File,
        buffer: []u8,
        offset: usize = 0,
    };
    const Collect = struct {
        dir: std.Io.Dir,
        iterator: std.Io.Dir.Iterator,
        entries: EntryList,
        name_bytes: usize = 0,
    };
    const Ordering = struct {
        entries: EntryList,
        orderer: Orderer,
    };
    const Build = struct {
        entries: EntryList,
        sorted: []*const Listed,
        values: []Value,
        built: usize = 0,
        name: ?kernel_storage.Utf8Materializer = null,
    };
    const Result = struct {
        entries: EntryList,
        sorted: []*const Listed,
        values: []Value,
        built: usize,
        materializer: list.ValueMaterializer,
    };
    const Release = struct {
        entries: EntryList,
        sorted: []*const Listed,
        values: []Value,
        built: usize,
        index: usize = 0,
        result: Value,
    };
    const Write = struct {
        staged: fsport.StagedFile,
        offset: usize = 0,
    };
    const Copy = struct {
        file: std.Io.File,
        size: usize,
        offset: usize = 0,
        staged: fsport.StagedFile,
        buffer: []u8,
    };
    const State = union(enum) {
        encode_path: kernel_storage.StringEncoder,
        encode_second_path: kernel_storage.StringEncoder,
        encode_text: kernel_storage.StringEncoder,
        encode_bytes: kernel_storage.ByteVectorEncoder,
        authorize,
        resolve: fsport.Resolver,
        resolve_second: fsport.Resolver,
        act,
        removing_tree: fsport.TreeRemoval,
        waiting_lock: std.Io.File,
        read: Read,
        bytes_value: struct { buffer: []u8, materializer: list.ByteListMaterializer },
        text_value: struct { buffer: []u8, materializer: kernel_storage.Utf8Materializer },
        list_collect: Collect,
        list_order: Ordering,
        list_build: Build,
        list_result: Result,
        list_release: Release,
        write: Write,
        commit: fsport.StagedFile,
        copy: Copy,
        complete,
        /// Retirement-only: free listing entries one per step.
        cleanup_entries: struct { entries: EntryList, iterator: EntryList.Iterator },
        /// Retirement-only: release built values one per step.
        cleanup_values: struct { values: []Value, built: usize, index: usize },
        cleanup_done,
    };

    pub fn advance(evaluator: *Unit, self: *Driver) MachineError!machine.WorkProgress {
        return self.completion.advance(evaluator, self);
    }

    pub fn advanceOperation(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        try evaluator.pollKernel();
        return switch (self.state) {
            .encode_path => |*cursor| self.encodePath(evaluator, cursor, .primary),
            .encode_second_path => |*cursor| self.encodePath(evaluator, cursor, .second),
            .encode_text => |*encoder| self.encodeText(evaluator, encoder),
            .encode_bytes => |*encoder| self.encodeBytes(evaluator, encoder),
            .authorize => self.authorize(evaluator),
            .resolve => |*resolver| self.resolve(evaluator, resolver, .primary),
            .resolve_second => |*resolver| self.resolve(evaluator, resolver, .second),
            .act => self.act(evaluator),
            .waiting_lock => |file| self.waitForLock(evaluator, file),
            .removing_tree => |*tree| self.removeTreeStep(evaluator, tree),
            .read => |*read| self.readStep(evaluator, read),
            .bytes_value => |*building| self.materializeBytes(evaluator, building),
            .text_value => |*building| self.materializeText(evaluator, building),
            .list_collect => |*collect| self.collectEntries(evaluator, collect),
            .list_order => |*ordering| self.orderEntries(evaluator, ordering),
            .list_build => |*build| self.buildEntries(evaluator, build),
            .list_result => |*result| self.materializeEntries(evaluator, result),
            .list_release => |*release| self.releaseEntries(evaluator, release),
            .write => |*write| self.writeStep(evaluator, write),
            .commit => |*staged| self.commitStep(evaluator, staged),
            .copy => |*copying| self.copyStep(evaluator, copying),
            .complete, .cleanup_entries, .cleanup_values, .cleanup_done => unreachable,
        };
    }

    const Which = enum { primary, second };

    fn fail(self: *Driver, evaluator: *Unit, reason: fsport.Reason) MachineError {
        return failInputs(evaluator, errorKindFor(reason), reason, self.operation, self.symbols, &self.inputs);
    }

    fn failMessage(self: *Driver, evaluator: *Unit, kind: machine.ErrorKind, reason: fsport.Reason, message: []const u8) MachineError {
        const reason_symbol = try reasonSymbol(reason);
        const failure = evaluator.fail(kind, message);
        evaluator.addErrorFilesystem(.{
            .operation = .{ .symbol = .{ .name = self.symbols.operation } },
            .reason = .{ .symbol = .{ .name = reason_symbol } },
            .target = if (self.operation == .copy) .{ .transfer = .{
                .source_root = self.inputs.root,
                .source_path = self.inputs.path,
                .destination_root = self.inputs.second_root.?,
                .destination_path = self.inputs.second_path.?,
            } } else .{ .single = .{ .root = self.inputs.root, .path = self.inputs.path } },
        });
        return failure;
    }

    fn encodePath(
        self: *Driver,
        evaluator: *Unit,
        cursor: *kernel_storage.StringEncoder,
        which: Which,
    ) MachineError!driver_completion.Progress {
        switch (cursor.advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failMessage(evaluator, .domain, .invalid_path, "path contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
            .complete => |bytes| {
                cursor.deinit();
                switch (which) {
                    .primary => {
                        self.path = bytes;
                        if (self.inputs.second_path) |second| {
                            self.state = .{ .encode_second_path = .init(self.allocator, second) };
                        } else if (self.inputs.payload) |payload| {
                            self.state = if (self.operation.textPayload())
                                .{ .encode_text = .init(self.allocator, payload) }
                            else
                                .{ .encode_bytes = .init(self.allocator, payload) };
                        } else self.state = .authorize;
                    },
                    .second => {
                        self.second_path = bytes;
                        self.state = .authorize;
                    },
                }
                return .stepped;
            },
        }
    }

    fn encodeText(
        self: *Driver,
        evaluator: *Unit,
        encoder: *kernel_storage.StringEncoder,
    ) MachineError!driver_completion.Progress {
        switch (encoder.advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCodepoint => return self.failMessage(evaluator, .domain, .invalid_utf8, "string contains an invalid Unicode scalar"),
        }) {
            .pending => return .stepped,
            .complete => |text| {
                encoder.deinit();
                self.payload = .{ .text = text };
                self.state = .authorize;
                return .stepped;
            },
        }
    }

    fn encodeBytes(
        self: *Driver,
        evaluator: *Unit,
        encoder: *kernel_storage.ByteVectorEncoder,
    ) MachineError!driver_completion.Progress {
        switch (encoder.advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidByte => return evaluator.failAtIndex(
                .type,
                "byte list members must be integers from 0 through 255",
                encoder.invalid_index.?,
            ),
        }) {
            .pending => return .stepped,
            .complete => |bytes| {
                encoder.deinit();
                self.payload = .{ .bytes = bytes };
                self.state = .authorize;
                return .stepped;
            },
        }
    }

    /// Grammar, root lookup, and quota checks happen before any
    /// host object is opened.
    fn authorize(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        if (self.operation == .open_dir) {
            const dir = switch (fsport.openHostDirectory(self.access, self.path.?)) {
                .directory => |dir| dir,
                .failed => |reason| return self.fail(evaluator, reason),
            };
            return self.publishDirectory(evaluator, dir);
        }
        const class = fsport.classifyPath(self.path.?) catch return self.fail(evaluator, .invalid_path);
        if (class == .root and self.operation.requiresEntry() and self.operation != .rename)
            return self.fail(evaluator, .invalid_path);
        if (self.second_path) |second| {
            const second_class = fsport.classifyPath(second) catch return self.fail(evaluator, .invalid_path);
            if (second_class == .root) return self.fail(evaluator, .invalid_path);
            if (self.operation == .rename and class == .root) return self.fail(evaluator, .invalid_path);
        }
        const root = try self.acquireRoot(evaluator, self.inputs.root);
        self.root = root;
        if (self.operation == .reserve) return self.publishReservation(evaluator);
        if (self.inputs.second_root) |second_root_value| {
            const second_root = try self.acquireRoot(evaluator, second_root_value);
            self.second_root = second_root;
        }
        if (self.payload) |*payload| {
            if (payload.slice().len > self.limits.max_transfer_bytes) return self.fail(evaluator, .limit);
        }
        self.slot = fsport.reservePair(self.access, root, self.second_root) orelse return self.fail(evaluator, .limit);
        if (class == .root) {
            self.resolved = .{ .directory = .{ .dir = root.dir(), .owned = false } };
            self.state = .act;
            return .yielded;
        }
        // Built into a local first: writing `try` straight into the union
        // could tag the state before the payload exists, and retirement would
        // then retire a resolver that was never constructed.
        var resolver = fsport.Resolver.init(
            self.allocator,
            self.io,
            root.dir(),
            self.path.?,
            self.limits,
            self.operation.resolveMode(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PathTooLong => return self.fail(evaluator, .limit),
        };
        if (self.operation == .mkdirs) resolver.createParents();
        self.state = .{ .resolve = resolver };
        return .yielded;
    }

    fn resolve(
        self: *Driver,
        evaluator: *Unit,
        resolver: *fsport.Resolver,
        which: Which,
    ) MachineError!driver_completion.Progress {
        switch (try resolver.step()) {
            .pending => return .yielded,
            .failed => |reason| return self.fail(evaluator, reason),
            .complete => |completed| {
                // Every allocation happens before the finished resolver is
                // retired, so an allocation failure leaves the state owning
                // exactly what retirement expects to release.
                var resolved = completed;
                switch (which) {
                    .primary => {
                        if (self.second_path) |second| {
                            const next = fsport.Resolver.init(
                                self.allocator,
                                self.io,
                                self.second_root.?.dir(),
                                second,
                                self.limits,
                                .no_follow_final,
                            ) catch |err| {
                                resolved.deinit(self.allocator, self.io);
                                return switch (err) {
                                    error.OutOfMemory => error.OutOfMemory,
                                    error.PathTooLong => self.fail(evaluator, .limit),
                                };
                            };
                            resolver.retire(evaluator.releases);
                            self.resolved = resolved;
                            self.state = .{ .resolve_second = next };
                            return .yielded;
                        }
                        resolver.retire(evaluator.releases);
                        self.resolved = resolved;
                    },
                    .second => {
                        resolver.retire(evaluator.releases);
                        self.second = resolved;
                    },
                }
                self.state = .act;
                return .yielded;
            },
        }
    }

    fn acquireRoot(self: *Driver, evaluator: *Unit, item: Value) MachineError!RootSelection {
        return fsport.selectRoot(self.access, item) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownRoot => return self.fail(evaluator, .unknown_root),
            error.Closed => return self.failMessage(evaluator, .io, .io, "directory resource is closed"),
            error.Io => return self.fail(evaluator, .changed),
        };
    }

    fn publishDirectory(self: *Driver, evaluator: *Unit, dir: std.Io.Dir) MachineError!driver_completion.Progress {
        const scope = evaluator.task_scope orelse {
            dir.close(self.io);
            return evaluator.fail(.cancelled, "directory scope is closing");
        };
        const adoption = if (self.operation == .open_list)
            directory.adoptEnumeration(self.access, scope, dir, self.inputs.root, if (self.root) |root| root.reservation() else null)
        else
            directory.adoptChild(self.access, scope, dir, self.inputs.root, if (self.root) |root| root.reservation() else null);
        const result = adoption catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return evaluator.fail(.cancelled, "directory scope is closing"),
        };
        self.state = .complete;
        return .{ .output = result };
    }

    fn acquireDirectory(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const dir = switch (self.resolved.?) {
            .directory => |d| d.dir.openDir(self.io, ".", .{ .iterate = true }),
            .entry => |entry| entry.parent.dir.openDir(self.io, entry.name, .{ .iterate = true, .follow_symlinks = false }),
        } catch |err| return self.fail(evaluator, fsport.reasonForError(err));
        return self.publishDirectory(evaluator, dir);
    }

    fn act(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        return switch (self.operation) {
            .reserve => unreachable,
            .open_writer => self.beginStage(evaluator, .create),
            .stage_dir => self.stageDirectory(evaluator),
            .mkdirs => self.makeDirectories(evaluator),
            .remove_tree => self.beginRemoveTree(evaluator),
            .lock => self.beginLock(evaluator),
            .open_dir => unreachable,
            .child_dir, .open_list => self.acquireDirectory(evaluator),
            .read_bytes, .read_text => self.beginRead(evaluator),
            .open_reader => self.openReaderEndpoint(evaluator),
            .stat => self.inspect(evaluator, true),
            .lstat => self.inspect(evaluator, false),
            .exists => self.testExistence(evaluator),
            .list => self.beginList(evaluator),
            .mkdir => self.makeDirectory(evaluator),
            .remove_file => self.removeEntry(evaluator, .file),
            .remove_dir => self.removeEntry(evaluator, .directory),
            .rename => self.renameEntry(evaluator),
            .create_bytes, .create_text => self.beginStage(evaluator, .create),
            .replace_bytes, .replace_text => self.beginStage(evaluator, .replace),
            .publish_bytes, .publish_text => self.beginStage(evaluator, .publish),
            .copy => self.beginCopy(evaluator),
        };
    }

    fn publishReservation(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const root = self.root.?;
        const ticket = if (root.reservation()) |existing| existing: {
            existing.retain();
            break :existing existing;
        } else fsport.Reservation.create(self.access) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Limit => return self.fail(evaluator, .limit),
        };
        defer ticket.release();
        const scope = evaluator.task_scope orelse return evaluator.fail(.cancelled, "directory scope is closing");
        const dir = root.dir().openDir(self.io, ".", .{ .iterate = true }) catch |err| return self.fail(evaluator, fsport.reasonForError(err));
        const result = directory.adoptChild(self.access, scope, dir, self.inputs.root, ticket) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return evaluator.fail(.cancelled, "directory scope is closing"),
        };
        self.state = .complete;
        return .{ .output = result };
    }

    fn stageDirectory(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        const scope = evaluator.task_scope orelse return evaluator.fail(.cancelled, "directory scope is closing");
        const stage = @import("../directory_stage.zig").Stage.create(self.access, entry.parent.dir, entry.name) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.fail(evaluator, fsport.reasonForError(err));
        };
        const result = directory.adoptStage(self.access, scope, stage, self.inputs.root, self.root.?.reservation()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return evaluator.fail(.cancelled, "directory scope is closing"),
        };
        self.state = .complete;
        return .{ .output = result };
    }

    fn beginLock(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        const file = switch (fsport.openLockFile(self.io, entry.parent.dir, entry.name)) {
            .file => |file| file,
            .failed => |reason| return self.fail(evaluator, reason),
        };
        self.state = .{ .waiting_lock = file };
        return .yielded;
    }

    fn waitForLock(self: *Driver, evaluator: *Unit, file: std.Io.File) MachineError!driver_completion.Progress {
        if (!(file.tryLock(self.io, .exclusive) catch |err| return self.fail(evaluator, fsport.reasonForError(err)))) {
            try evaluator.park(.{ .sleep = 10 });
            return .yielded;
        }
        const scope = evaluator.task_scope orelse return evaluator.fail(.cancelled, "lock scope is closing");
        // Adoption consumes the descriptor even on failure. Retirement cannot
        // close it again once the resource factory owns it.
        self.state = .complete;
        const result = fsport.adoptLock(self.access, scope, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return evaluator.fail(.cancelled, "lock scope is closing"),
        };
        return .{ .output = result };
    }

    // -- reads --------------------------------------------------------------

    /// `open-reader`: the file is opened as `read-bytes` opens it, but is
    /// adopted by the calling scope as a resource whose endpoint is the
    /// result. There is no size limit: the stream is read a chunk at a time.
    fn openReaderEndpoint(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const entry = switch (self.resolved.?) {
            .directory => return self.fail(evaluator, .is_directory),
            .entry => |entry| entry,
        };
        const file = switch (fsport.openRegularForRead(self.io, entry.parent.dir, entry.name)) {
            .failed => |reason| return self.fail(evaluator, reason),
            .file => |file| file,
        };
        switch (fsport.regularFileInfo(self.io, file, std.math.maxInt(u64))) {
            .failed => |reason| {
                file.close(self.io);
                return self.fail(evaluator, reason);
            },
            .regular => {},
        }
        const scope = evaluator.task_scope orelse {
            file.close(self.io);
            return evaluator.fail(.cancelled, "reader scope is closing");
        };
        // Adoption consumes the descriptor on either outcome.
        self.state = .complete;
        const result = directory.adoptReader(self.access, scope, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScopeClosing => return evaluator.fail(.cancelled, "reader scope is closing"),
        };
        return .{ .output = result };
    }

    fn beginRead(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const entry = switch (self.resolved.?) {
            .directory => return self.fail(evaluator, .is_directory),
            .entry => |entry| entry,
        };
        const file = switch (fsport.openRegularForRead(self.io, entry.parent.dir, entry.name)) {
            .failed => |reason| return self.fail(evaluator, reason),
            .file => |file| file,
        };
        const size = switch (fsport.regularFileInfo(self.io, file, self.limits.max_transfer_bytes)) {
            .failed => |reason| {
                file.close(self.io);
                return self.fail(evaluator, reason);
            },
            .regular => |info| info.size,
        };
        const buffer = self.allocator.alloc(u8, @intCast(size)) catch |err| {
            file.close(self.io);
            return err;
        };
        self.state = .{ .read = .{ .file = file, .buffer = buffer } };
        return .yielded;
    }

    fn readStep(self: *Driver, evaluator: *Unit, read: *Read) MachineError!driver_completion.Progress {
        switch (fsport.readQuantum(self.io, read.file, read.buffer, &read.offset)) {
            .pending => return .yielded,
            .failed => |reason| return self.fail(evaluator, reason),
            .complete => {},
        }
        read.file.close(self.io);
        const buffer = read.buffer;
        self.state = if (self.operation == .read_bytes)
            .{ .bytes_value = .{ .buffer = buffer, .materializer = .init(self.allocator, buffer) } }
        else
            .{ .text_value = .{ .buffer = buffer, .materializer = .init(self.allocator, buffer) } };
        return .yielded;
    }

    fn materializeBytes(
        self: *Driver,
        evaluator: *Unit,
        building: *@FieldType(State, "bytes_value"),
    ) MachineError!driver_completion.Progress {
        return switch (try building.materializer.advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |result| complete: {
                building.materializer.deinit();
                self.allocator.free(building.buffer);
                self.state = .complete;
                break :complete .{ .output = result };
            },
        };
    }

    fn materializeText(
        self: *Driver,
        evaluator: *Unit,
        building: *@FieldType(State, "text_value"),
    ) MachineError!driver_completion.Progress {
        return switch (building.materializer.advance(evaluator.workBudget()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return self.failMessage(evaluator, .io, .invalid_utf8, "file is not valid UTF-8"),
        }) {
            .pending => .stepped,
            .complete => |result| complete: {
                building.materializer.deinit();
                self.allocator.free(building.buffer);
                self.state = .complete;
                break :complete .{ .output = result };
            },
        };
    }

    // -- metadata -----------------------------------------------------------

    fn inspect(self: *Driver, evaluator: *Unit, followed: bool) MachineError!driver_completion.Progress {
        const info: std.Io.File.Stat = switch (self.resolved.?) {
            .directory => |handle| handle.dir.stat(self.io) catch |err| return self.fail(evaluator, fsport.reasonForError(err)),
            .entry => |entry| entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err)),
        };
        const kind = fsport.EntryKind.fromHost(info.kind);
        if (followed and kind == .symlink) return self.fail(evaluator, .changed);
        const result = if (kind == .file)
            try dict.fromUniquePairs(self.allocator, evaluator.releases, &.{
                .{ .{ .symbol = .{ .name = self.symbols.kind } }, .{ .symbol = .{ .name = self.symbols.file } } },
                .{ .{ .symbol = .{ .name = self.symbols.size } }, .{ .int = std.math.cast(i64, info.size) orelse std.math.maxInt(i64) } },
            })
        else
            try dict.fromUniquePairs(self.allocator, evaluator.releases, &.{
                .{ .{ .symbol = .{ .name = self.symbols.kind } }, .{ .symbol = .{ .name = self.symbols.entryKind(kind) } } },
            });
        self.state = .complete;
        return .{ .output = result };
    }

    fn testExistence(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const present: i64 = switch (self.resolved.?) {
            .directory => 1,
            .entry => |entry| present: {
                _ = entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => break :present 0,
                    else => return self.fail(evaluator, fsport.reasonForError(err)),
                };
                break :present 1;
            },
        };
        self.state = .complete;
        return .{ .output = .{ .int = present } };
    }

    // -- listing ------------------------------------------------------------

    fn beginList(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const dir = switch (self.resolved.?) {
            .directory => |handle| handle.dir.openDir(self.io, ".", .{ .iterate = true }) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err)),
            .entry => |entry| entry.parent.dir.openDir(self.io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.SymLinkLoop => return self.fail(evaluator, .changed),
                else => return self.fail(evaluator, fsport.reasonForError(err)),
            },
        };
        self.state = .{ .list_collect = .{
            .dir = dir,
            .iterator = dir.iterate(),
            .entries = .init(self.allocator),
        } };
        return .yielded;
    }

    fn collectEntries(self: *Driver, evaluator: *Unit, collect: *Collect) MachineError!driver_completion.Progress {
        var observed: usize = 0;
        var observed_bytes: usize = 0;
        while (observed < fsport.listing_batch_entries and observed_bytes < fsport.listing_batch_bytes) {
            const entry = collect.iterator.next(self.io) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err));
            const item = entry orelse {
                const orderer = try Orderer.init(self.allocator, &collect.entries);
                collect.dir.close(self.io);
                const entries = collect.entries;
                self.state = .{ .list_order = .{ .entries = entries, .orderer = orderer } };
                return .yielded;
            };
            if (std.mem.eql(u8, item.name, ".") or std.mem.eql(u8, item.name, "..")) continue;
            if (!std.unicode.utf8ValidateSlice(item.name)) return self.fail(evaluator, .invalid_utf8);
            if (collect.entries.count == self.limits.max_directory_entries) return self.fail(evaluator, .limit);
            collect.name_bytes = std.math.add(usize, collect.name_bytes, item.name.len) catch
                return self.fail(evaluator, .limit);
            if (collect.name_bytes > self.limits.max_directory_name_bytes) return self.fail(evaluator, .limit);
            const kind = if (item.kind == .unknown) classify: {
                const info = collect.dir.statFile(self.io, item.name, .{ .follow_symlinks = false }) catch |err|
                    return self.fail(evaluator, fsport.reasonForError(err));
                break :classify fsport.EntryKind.fromHost(info.kind);
            } else fsport.EntryKind.fromHost(item.kind);
            const name = try self.allocator.dupe(u8, item.name);
            collect.entries.append(.{ .name = name, .kind = kind }) catch |err| {
                self.allocator.free(name);
                return err;
            };
            observed += 1;
            observed_bytes += item.name.len;
        }
        return .yielded;
    }

    /// Ordering draws on the unit's budget; only the completed cursor yields
    /// the sorted pointers.
    fn orderEntries(self: *Driver, evaluator: *Unit, ordering: *Ordering) MachineError!driver_completion.Progress {
        if (ordering.orderer.advance(evaluator.workBudget()) == .pending) return .stepped;
        const values = try self.allocator.alloc(Value, ordering.entries.count);
        const entries = ordering.entries;
        const sorted = ordering.orderer.take();
        self.state = .{ .list_build = .{ .entries = entries, .sorted = sorted, .values = values } };
        return .stepped;
    }

    fn buildEntries(self: *Driver, evaluator: *Unit, build: *Build) MachineError!driver_completion.Progress {
        const work = evaluator.workBudget();
        while (!work.exhausted()) {
            if (build.built == build.sorted.len) {
                const entries = build.entries;
                const sorted = build.sorted;
                const values = build.values;
                self.state = .{ .list_result = .{
                    .entries = entries,
                    .sorted = sorted,
                    .values = values,
                    .built = build.built,
                    .materializer = .init(self.allocator, values),
                } };
                return .stepped;
            }
            const entry = build.sorted[build.built];
            if (build.name == null) {
                _ = work.spend();
                build.name = .init(self.allocator, entry.name);
            }
            const name_value = switch (build.name.?.advance(evaluator.workBudget()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidUtf8 => return self.fail(evaluator, .invalid_utf8),
            }) {
                .pending => return .stepped,
                .complete => |name_value| name_value,
            };
            build.name.?.deinit();
            build.name = null;
            defer evaluator.releases.releaseValue(name_value);
            build.values[build.built] = try dict.fromUniquePairs(self.allocator, evaluator.releases, &.{
                .{ .{ .symbol = .{ .name = self.symbols.name } }, name_value },
                .{ .{ .symbol = .{ .name = self.symbols.kind } }, .{ .symbol = .{ .name = self.symbols.entryKind(entry.kind) } } },
            });
            build.built += 1;
        }
        return .yielded;
    }

    fn materializeEntries(self: *Driver, evaluator: *Unit, result: *Result) MachineError!driver_completion.Progress {
        return switch (try result.materializer.advance(evaluator.workBudget())) {
            .pending => .stepped,
            .complete => |listing| complete: {
                result.materializer.deinit();
                const entries = result.entries;
                const sorted = result.sorted;
                const values = result.values;
                self.state = .{ .list_release = .{
                    .entries = entries,
                    .sorted = sorted,
                    .values = values,
                    .built = result.built,
                    .result = listing,
                } };
                break :complete .stepped;
            },
        };
    }

    /// The listing retains its element dictionaries, so the construction
    /// inputs release one per step before the result is published.
    fn releaseEntries(self: *Driver, evaluator: *Unit, release: *Release) MachineError!driver_completion.Progress {
        const work = evaluator.workBudget();
        while (release.index != release.built and work.spend()) {
            evaluator.releases.releaseValue(release.values[release.index]);
            release.index += 1;
        }
        if (release.index != release.built) return .yielded;
        self.allocator.free(release.values);
        self.allocator.free(release.sorted);
        const result = release.result;
        const entries = release.entries;
        // Entry names use the same bounded cleanup cursor before completion
        // and after abandoned execution; nothing else remains to build.
        self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
        return .{ .output = result };
    }

    // -- single-entry mutation ----------------------------------------------

    fn requireEntry(self: *Driver, evaluator: *Unit, resolved: fsport.Resolved) MachineError!@FieldType(fsport.Resolved, "entry") {
        return switch (resolved) {
            .directory => self.fail(evaluator, .invalid_path),
            .entry => |entry| entry,
        };
    }

    fn makeDirectory(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        entry.parent.dir.createDir(self.io, entry.name, .default_dir) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        self.state = .complete;
        return .completed;
    }

    fn makeDirectories(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        switch (self.resolved.?) {
            .directory => {},
            .entry => |entry| entry.parent.dir.createDir(self.io, entry.name, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    const dir = entry.parent.dir.openDir(self.io, entry.name, .{ .follow_symlinks = false }) catch |open_err| return self.fail(evaluator, fsport.reasonForError(open_err));
                    dir.close(self.io);
                },
                else => return self.fail(evaluator, fsport.reasonForError(err)),
            },
        }
        self.state = .complete;
        return .completed;
    }

    fn beginRemoveTree(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        const dir = entry.parent.dir.openDir(self.io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return self.fail(evaluator, fsport.reasonForError(err));
        self.state = .{ .removing_tree = .init(self.io, dir) };
        return .yielded;
    }

    fn removeTreeStep(self: *Driver, evaluator: *Unit, tree: *fsport.TreeRemoval) MachineError!driver_completion.Progress {
        switch (tree.step()) {
            .pending => return .yielded,
            .failed => |reason| return self.fail(evaluator, reason),
            .complete => {
                const entry = try self.requireEntry(evaluator, self.resolved.?);
                entry.parent.dir.deleteDir(self.io, entry.name) catch |err| switch (err) {
                    error.DirNotEmpty => {
                        tree.restart();
                        return .yielded;
                    },
                    else => return self.fail(evaluator, fsport.reasonForError(err)),
                };
                tree.deinit();
                self.state = .complete;
                return .completed;
            },
        }
    }

    const RemoveKind = enum { file, directory };

    fn removeEntry(self: *Driver, evaluator: *Unit, kind: RemoveKind) MachineError!driver_completion.Progress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        const info = entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        switch (kind) {
            .file => {
                if (info.kind == .directory) return self.fail(evaluator, .is_directory);
                entry.parent.dir.deleteFile(self.io, entry.name) catch |err|
                    return self.fail(evaluator, fsport.reasonForError(err));
            },
            .directory => {
                if (info.kind != .directory) return self.fail(evaluator, .not_directory);
                entry.parent.dir.deleteDir(self.io, entry.name) catch |err|
                    return self.fail(evaluator, fsport.reasonForError(err));
            },
        }
        self.state = .complete;
        return .completed;
    }

    fn renameEntry(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const source = try self.requireEntry(evaluator, self.resolved.?);
        const destination = try self.requireEntry(evaluator, self.second.?);
        fsport.renameNoReplace(self.io, source.parent.dir, source.name, destination.parent.dir, destination.name) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        self.state = .complete;
        return .completed;
    }

    // -- staged publication -------------------------------------------------

    const StageMode = enum { create, replace, publish };

    fn beginStage(self: *Driver, evaluator: *Unit, mode: StageMode) MachineError!driver_completion.Progress {
        const entry = try self.requireEntry(evaluator, self.resolved.?);
        const existing = entry.parent.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return self.fail(evaluator, fsport.reasonForError(err)),
        };
        // A replaced file keeps its permissions through the exchange; a
        // created one gets the host default.
        const permissions: std.Io.File.Permissions = switch (mode) {
            .create => if (existing != null) return self.fail(evaluator, .already_exists) else .default_file,
            .replace, .publish => permissions: {
                const info = existing orelse {
                    if (mode == .replace) return self.fail(evaluator, .not_found);
                    break :permissions .default_file;
                };
                if (info.kind != .file) return self.fail(evaluator, .not_regular);
                break :permissions info.permissions;
            },
        };
        const staged = switch (fsport.StagedFile.create(self.io, entry.parent.dir, permissions)) {
            .failed => |reason| return self.fail(evaluator, reason),
            .staged => |staged| staged,
        };
        if (self.operation == .open_writer) {
            const root = self.root.?;
            self.root = null;
            const slot = self.slot.?;
            self.slot = null;
            const target = self.resolved.?;
            self.resolved = null;
            const stream = try @import("../filesystem_stream.zig").Stream.create(self.access, root, slot, target, staged);
            const scope = evaluator.task_scope orelse {
                stream.retire();
                return evaluator.fail(.cancelled, "directory scope is closing");
            };
            const result = directory.adoptStream(self.access, scope, stream, self.inputs.root) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ScopeClosing => return evaluator.fail(.cancelled, "directory scope is closing"),
            };
            self.state = .complete;
            return .{ .output = result };
        }
        self.state = .{ .write = .{ .staged = staged } };
        return .yielded;
    }

    fn writeStep(self: *Driver, evaluator: *Unit, write: *Write) MachineError!driver_completion.Progress {
        switch (fsport.writeQuantum(self.io, write.staged.file.?, self.payload.?.slice(), &write.offset)) {
            .pending => return .yielded,
            .failed => |reason| return self.fail(evaluator, reason),
            .complete => {},
        }
        const staged = write.staged;
        self.state = .{ .commit = staged };
        return .yielded;
    }

    /// Publication is its own step so cancellation is observed after the
    /// last write and before the one commit syscall.
    fn commitStep(self: *Driver, evaluator: *Unit, staged: *fsport.StagedFile) MachineError!driver_completion.Progress {
        // A copy publishes into its destination entry; every other staged
        // word publishes into the primary one.
        const entry = if (self.operation == .copy) self.second.?.entry else self.resolved.?.entry;
        const failed: ?fsport.Reason = switch (self.operation) {
            .replace_bytes, .replace_text => staged.commitExchange(entry.name),
            .publish_bytes, .publish_text => staged.commitReplace(entry.name),
            else => staged.commitNoReplace(entry.name),
        };
        if (failed) |reason| return self.fail(evaluator, reason);
        // After an exchange the displaced original sits under the staging
        // name; the mutation has committed either way, so disposal failure is
        // not reported as operation failure.
        if (staged.displaced) staged.dispose();
        self.state = .complete;
        return .completed;
    }

    // -- copy ---------------------------------------------------------------

    fn beginCopy(self: *Driver, evaluator: *Unit) MachineError!driver_completion.Progress {
        const source = switch (self.resolved.?) {
            .directory => return self.fail(evaluator, .not_regular),
            .entry => |entry| entry,
        };
        const destination = try self.requireEntry(evaluator, self.second.?);
        const existing = destination.parent.dir.statFile(self.io, destination.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return self.fail(evaluator, fsport.reasonForError(err)),
        };
        if (existing != null) return self.fail(evaluator, .already_exists);
        const file = switch (fsport.openRegularForRead(self.io, source.parent.dir, source.name)) {
            .failed => |reason| return self.fail(evaluator, reason),
            .file => |file| file,
        };
        const source_info = switch (fsport.regularFileInfo(self.io, file, self.limits.max_transfer_bytes)) {
            .failed => |reason| {
                file.close(self.io);
                return self.fail(evaluator, reason);
            },
            .regular => |info| info,
        };
        const buffer = self.allocator.alloc(u8, fsport.transfer_quantum) catch |err| {
            file.close(self.io);
            return err;
        };
        // The copy carries the source file's permissions, as `cp` does.
        const staged = switch (fsport.StagedFile.create(self.io, destination.parent.dir, source_info.permissions)) {
            .failed => |reason| {
                file.close(self.io);
                self.allocator.free(buffer);
                return self.fail(evaluator, reason);
            },
            .staged => |staged| staged,
        };
        self.state = .{ .copy = .{
            .file = file,
            .size = @intCast(source_info.size),
            .staged = staged,
            .buffer = buffer,
        } };
        return .yielded;
    }

    fn copyStep(self: *Driver, evaluator: *Unit, copying: *Copy) MachineError!driver_completion.Progress {
        if (copying.offset == copying.size) {
            var probe: [1]u8 = undefined;
            const extra = copying.file.readPositionalAll(self.io, &probe, copying.size) catch |err|
                return self.fail(evaluator, fsport.reasonForError(err));
            if (extra != 0) return self.fail(evaluator, .changed);
            copying.file.close(self.io);
            self.allocator.free(copying.buffer);
            const staged = copying.staged;
            self.state = .{ .commit = staged };
            return .yielded;
        }
        // One transfer chunk per step, charged a unit per byte.
        const end = copying.offset + evaluator.workBudget().take(@min(fsport.transfer_quantum, copying.size - copying.offset));
        if (end == copying.offset) return .yielded;
        const chunk = copying.buffer[0 .. end - copying.offset];
        const amount = copying.file.readPositionalAll(self.io, chunk, copying.offset) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        if (amount != chunk.len) return self.fail(evaluator, .changed);
        copying.staged.file.?.writePositionalAll(self.io, chunk, copying.offset) catch |err|
            return self.fail(evaluator, fsport.reasonForError(err));
        copying.offset = end;
        return .yielded;
    }

    // -- retirement ---------------------------------------------------------

    /// Terminal cleanup, one bounded step per call. Handles close, an
    /// unpublished staging entry is unlinked, listing storage is freed one
    /// entry per step, and the quota slot is released last.
    pub fn advanceRetirement(
        releases: *heap.ReleaseDomain,
        allocator: std.mem.Allocator,
        self: *Driver,
    ) bool {
        if (!self.completion.retire(self, releases, allocator)) return false;
        allocator.destroy(self);
        return true;
    }

    pub fn advanceCleanup(self: *Driver, releases: *heap.ReleaseDomain, allocator: std.mem.Allocator) bool {
        switch (self.state) {
            .encode_path, .encode_second_path => |*cursor| cursor.deinit(),
            .encode_text => |*encoder| encoder.deinit(),
            .encode_bytes => |*encoder| encoder.deinit(),
            .authorize, .act, .complete => {},
            .waiting_lock => |file| file.close(self.io),
            .removing_tree => |*tree| tree.deinit(),
            .resolve, .resolve_second => |*resolver| resolver.retire(releases),
            .read => |*read| {
                read.file.close(self.io);
                allocator.free(read.buffer);
            },
            .bytes_value => |*building| {
                building.materializer.retire(releases);
                allocator.free(building.buffer);
            },
            .text_value => |*building| {
                building.materializer.retire(releases);
                allocator.free(building.buffer);
            },
            .list_collect => |*collect| {
                collect.dir.close(self.io);
                const entries = collect.entries;
                self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
                return false;
            },
            .list_order => |*ordering| {
                ordering.orderer.deinit();
                const entries = ordering.entries;
                self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
                return false;
            },
            .list_build => |*build| {
                if (build.name) |*name| name.retire(releases);
                allocator.free(build.sorted);
                const entries = build.entries;
                const values = build.values;
                const built = build.built;
                self.state = .{ .cleanup_values = .{ .values = values, .built = built, .index = 0 } };
                self.pending_entries = entries;
                return false;
            },
            .list_result => |*result| {
                result.materializer.retire(releases);
                allocator.free(result.sorted);
                const entries = result.entries;
                self.state = .{ .cleanup_values = .{ .values = result.values, .built = result.built, .index = 0 } };
                self.pending_entries = entries;
                return false;
            },
            .list_release => |*release| {
                releases.releaseValue(release.result);
                allocator.free(release.sorted);
                const entries = release.entries;
                self.state = .{ .cleanup_values = .{ .values = release.values, .built = release.built, .index = release.index } };
                self.pending_entries = entries;
                return false;
            },
            .write => |*write| write.staged.dispose(),
            .commit => |*staged| staged.dispose(),
            .copy => |*copying| {
                copying.file.close(self.io);
                allocator.free(copying.buffer);
                copying.staged.dispose();
            },
            .cleanup_values => |*cleanup| {
                if (cleanup.index != cleanup.built) {
                    releases.releaseValue(cleanup.values[cleanup.index]);
                    cleanup.index += 1;
                    return false;
                }
                allocator.free(cleanup.values);
                const entries = self.pending_entries.?;
                self.pending_entries = null;
                self.state = .{ .cleanup_entries = .{ .entries = entries, .iterator = entries.iterator() } };
                return false;
            },
            .cleanup_entries => |*cleanup| {
                if (cleanup.iterator.next()) |entry| {
                    allocator.free(entry.name);
                    return false;
                }
                cleanup.entries.retire(releases);
                self.state = .cleanup_done;
                return false;
            },
            .cleanup_done => {},
        }
        if (self.resolved) |*resolved| resolved.deinit(allocator, self.io);
        if (self.second) |*resolved| resolved.deinit(allocator, self.io);
        if (self.root) |root| root.deinit();
        if (self.second_root) |root| root.deinit();
        if (self.payload) |*payload| payload.retire(releases, allocator);
        if (self.path) |path| allocator.free(path);
        if (self.second_path) |path| allocator.free(path);
        self.inputs.deinit(releases);
        if (self.slot) |*slot| slot.release();
        return true;
    }
};
