const std = @import("std");
const line_editor = @import("../line_editor.zig");

test "line editor: edit actions preserve UTF-8 scalar boundaries" {
    var buffer = try line_editor.EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    try buffer.insert("aλb");
    buffer.moveLeft();
    buffer.backspace();
    try std.testing.expectEqualStrings("ab", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 1), buffer.cursorIndex());
    try buffer.insert("λ");
    buffer.moveLeft();
    buffer.delete();
    try std.testing.expectEqualStrings("ab", buffer.bytes());
    try buffer.insert("界");
    buffer.moveRight();
    buffer.transpose();
    try std.testing.expect(std.unicode.utf8ValidateSlice(buffer.bytes()));
    const expected = try std.testing.allocator.dupe(u8, buffer.bytes());
    defer std.testing.allocator.free(expected);
    try buffer.set(buffer.bytes());
    try std.testing.expectEqualSlices(u8, expected, buffer.bytes());
    var line = try buffer.takeOwned();
    defer line.deinit();
    try std.testing.expect(std.unicode.utf8ValidateSlice(line.bytes()));
}

test "line editor: a splice never leaves the cursor inside a scalar" {
    var buffer = try line_editor.EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    // Inserting a lead byte in front of a stranded continuation byte forms a
    // scalar across the insertion seam. The cursor has to end after it, or a
    // later backspace would split well-formed UTF-8 back into rubble.
    try buffer.insert("\x80");
    buffer.moveHome();
    try buffer.insert("\xc2");
    try std.testing.expectEqualStrings("\u{80}", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 2), buffer.cursorIndex());
    buffer.backspace();
    try std.testing.expectEqualStrings("", buffer.bytes());

    // The same seam on the left of a deletion.
    try buffer.set("\xc2A\x80");
    buffer.moveHome();
    buffer.moveRight();
    buffer.delete();
    try std.testing.expectEqualStrings("\u{80}", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 2), buffer.cursorIndex());
}

test "line editor: persisted history merges writers and caps entries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/history",
        .{path_buffer[0..length]},
    );
    defer std.testing.allocator.free(path);

    var first = try line_editor.History.init(std.testing.allocator, std.testing.io, path);
    defer first.deinit();
    var stale = try line_editor.History.init(std.testing.allocator, std.testing.io, path);
    defer stale.deinit();
    try first.record("first λ");
    try stale.record("second");
    try stale.record("second");

    var index: usize = 0;
    while (index != 105) : (index += 1) {
        var label: [32]u8 = undefined;
        try stale.record(try std.fmt.bufPrint(&label, "entry-{d}", .{index}));
    }
    var loaded = try line_editor.History.init(std.testing.allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(line_editor.max_history_entries, loaded.entries().len);
    try std.testing.expectEqualStrings("entry-5", loaded.entries()[0]);
    try std.testing.expectEqualStrings("entry-104", loaded.entries()[99]);
    const disk = try temporary.dir.readFileAlloc(
        std.testing.io,
        "history",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(disk);
    try std.testing.expect(std.unicode.utf8ValidateSlice(disk));
    try std.testing.expectEqual(@as(u8, '\n'), disk[disk.len - 1]);
    const metadata = try temporary.dir.statFile(std.testing.io, "history", .{});
    if (std.Io.File.Permissions.has_executable_bit)
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), metadata.permissions.toMode() & 0o777);

    const corrupt_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/corrupt-history",
        .{path_buffer[0..length]},
    );
    defer std.testing.allocator.free(corrupt_path);
    var corrupt_file = try temporary.dir.createFile(std.testing.io, "corrupt-history", .{});
    try corrupt_file.writeStreamingAll(std.testing.io, "\xff");
    corrupt_file.close(std.testing.io);
    var corrupt = try line_editor.History.init(
        std.testing.allocator,
        std.testing.io,
        corrupt_path,
    );
    defer corrupt.deinit();
    try std.testing.expect(corrupt.takeWarning() != null);
    try std.testing.expect(corrupt.takeWarning() == null);
    try corrupt.record("memory remains usable");
    try std.testing.expectEqualStrings("memory remains usable", corrupt.entries()[0]);
    const preserved = try temporary.dir.readFileAlloc(
        std.testing.io,
        "corrupt-history",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualSlices(u8, "\xff", preserved);
}

test "line editor: invalid physical lines are not recorded or persisted" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/history",
        .{path_buffer[0..length]},
    );
    defer std.testing.allocator.free(path);
    var file = try temporary.dir.createFile(std.testing.io, "history", .{});
    try file.writeStreamingAll(std.testing.io, "existing\n");
    file.close(std.testing.io);

    var history = try line_editor.History.init(std.testing.allocator, std.testing.io, path);
    defer history.deinit();
    try history.record("\xc2\r");
    try history.record("embedded\nline");
    try history.record("carriage\rreturn");
    try std.testing.expectEqual(@as(usize, 1), history.entries().len);
    {
        const preserved = try temporary.dir.readFileAlloc(
            std.testing.io,
            "history",
            std.testing.allocator,
            .unlimited,
        );
        defer std.testing.allocator.free(preserved);
        try std.testing.expectEqualStrings("existing\n", preserved);
    }

    try history.record("valid λ");
    try std.testing.expectEqual(@as(usize, 2), history.entries().len);
    const preserved = try temporary.dir.readFileAlloc(
        std.testing.io,
        "history",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("existing\nvalid λ\n", preserved);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var buffer = try line_editor.EditBuffer.init(allocator);
    defer buffer.deinit();
    try buffer.insert("one λ three");
    buffer.moveLeft();
    buffer.deleteWord();
    var line = try buffer.takeOwned();
    defer line.deinit();
    var history = try line_editor.History.init(allocator, std.testing.io, null);
    defer history.deinit();
    try history.record(line.bytes());
    try history.record("next");
}

test "line editor: allocation failures release edit and history storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
