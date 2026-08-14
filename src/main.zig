const std = @import("std");
const ecl = @import("ecl");
const AppError = error{ OutOfMemory, Io };
const help =
    \\ecl — a homoiconic concatenative array calculator
    \\
    \\USAGE:
    \\    ecl                         Start a REPL (or read stdin as one unit)
    \\    ecl -e <SOURCE> [ARGS...]  Evaluate source and print the stack
    \\    ecl <FILE> [ARGS...]       Run a UTF-8 script
    \\    ecl <SOURCE> [ARGS...]     Evaluate source and print the stack
    \\    ecl fmt <FILE|->           Format source to standard output
    \\
    \\OPTIONS:
    \\    -e, --eval <SOURCE>        Evaluate source text
    \\    -h, --help                 Show this help
    \\    -V, --version              Show the version
    \\
;
pub fn main(init: std.process.Init) void {
    const status = entry(init) catch |err| switch (err) {
        error.OutOfMemory => failure: {
            writeFile(init.io, .stderr, "ecl: out of memory\n") catch
                std.process.exit(2);
            break :failure 2;
        },
        error.Io => failure: {
            writeFile(init.io, .stderr, "ecl: I/O failure\n") catch
                std.process.exit(1);
            break :failure 1;
        },
    };
    if (status != 0) std.process.exit(status);
}
fn entry(init: std.process.Init) AppError!u8 {
    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch
        return error.OutOfMemory;
    const cli = arguments[1..];
    if (cli.len == 0) {
        const tty = std.Io.File.stdin().isTty(init.io) catch return error.Io;
        return if (tty) repl(init) else runStdin(init, &.{});
    }
    const first = cli[0];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        try writeFile(init.io, .stdout, help);
        return 0;
    }
    if (std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "--version")) {
        var buffer: [64]u8 = undefined;
        const version = std.fmt.bufPrint(&buffer, "ecl {s}\n", .{ecl.version}) catch
            @panic("version string exceeds its fixed output buffer");
        try writeFile(init.io, .stdout, version);
        return 0;
    }
    if (std.mem.eql(u8, first, "fmt")) return formatCommand(init, cli[1..]);
    if (std.mem.eql(u8, first, "-e") or std.mem.eql(u8, first, "--eval")) {
        if (cli.len < 2) return emitSyntheticError(
            init,
            .io,
            "-e/--eval requires source text",
            null,
        );
        return executeSource(init, "<command>", cli[1], cli[2..], true);
    }
    if (std.mem.eql(u8, first, "-")) return runStdin(init, cli[1..]);
    const is_file: bool = file: {
        std.Io.Dir.cwd().access(init.io, first, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound, error.NameTooLong, error.BadPathName => break :file false,
            else => return emitIoError(init, "cannot access script", err),
        };
        break :file true;
    };
    if (is_file) {
        const source = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            first,
            init.gpa,
            .unlimited,
        ) catch |err| return emitIoError(init, "cannot read script", err);
        defer init.gpa.free(source);
        return executeSource(init, first, source, cli[1..], false);
    }
    if (std.mem.endsWith(u8, first, ".ecl")) {
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "script file `{s}` does not exist",
            .{first},
        ) catch "script file does not exist";
        return emitSyntheticError(init, .io, message, null);
    }
    return executeSource(init, "<command>", first, cli[1..], true);
}
fn runStdin(init: std.process.Init, arguments: []const []const u8) AppError!u8 {
    var buffer: [8192]u8 = undefined;
    var file_reader = std.Io.File.stdin().reader(init.io, &buffer);
    const source = file_reader.interface.allocRemaining(init.gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return emitIoError(init, "cannot read stdin", err),
    };
    defer init.gpa.free(source);
    return executeSource(init, "<stdin>", source, arguments, true);
}

fn readFormatStdin(init: std.process.Init) AppError![]u8 {
    var buffer: [8192]u8 = undefined;
    var file_reader = std.Io.File.stdin().reader(init.io, &buffer);
    return file_reader.interface.allocRemaining(init.gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };
}

fn formatCommand(init: std.process.Init, arguments: []const []const u8) AppError!u8 {
    if (arguments.len != 1) {
        try writeFile(init.io, .stderr, "ecl fmt: expected exactly one FILE or -\n");
        return 1;
    }
    const source = if (std.mem.eql(u8, arguments[0], "-"))
        try readFormatStdin(init)
    else
        std.Io.Dir.cwd().readFileAlloc(init.io, arguments[0], init.gpa, .unlimited) catch |err|
            return emitIoError(init, "cannot read format input", err);
    defer init.gpa.free(source);
    const formatted = ecl.formatter.format(init.gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => {
            try writeFile(init.io, .stderr, "ecl fmt: source is not valid UTF-8\n");
            return 1;
        },
        error.InvalidSource => {
            try writeFile(init.io, .stderr, "ecl fmt: source does not parse\n");
            return 1;
        },
    };
    defer init.gpa.free(formatted);
    try writeFile(init.io, .stdout, formatted);
    return 0;
}
fn executeSource(
    init: std.process.Init,
    source_name: []const u8,
    source: []const u8,
    arguments: []const []const u8,
    print_stack: bool,
) AppError!u8 {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var diagnostic_buffer: [4096]u8 = undefined;
    var diagnostic_writer = std.Io.File.stderr().writerStreaming(init.io, &diagnostic_buffer);
    var session = try ecl.session.Session.initWithHost(
        init.gpa,
        arguments,
        init.io,
        &output_writer.interface,
        &diagnostic_writer.interface,
        init.environ_map.get("ECL_PATH"),
    );
    defer session.deinit();
    const outcome = try session.runUnit(source_name, source);
    if (session.requested_exit) |status| return status;
    switch (outcome) {
        .ok => {
            if (print_stack) try printStack(init, &session);
            return 0;
        },
        .incomplete => |incomplete| return emitSyntheticError(
            init,
            .parse,
            incomplete.message,
            .{ .source_name = source_name, .span = incomplete.span },
        ),
        .err => |error_value| {
            defer ecl.heap.releaseValue(init.gpa, error_value);
            try printError(init, error_value);
            return 1;
        },
    }
}
fn repl(init: std.process.Init) AppError!u8 {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var diagnostic_buffer: [4096]u8 = undefined;
    var diagnostic_writer = std.Io.File.stderr().writerStreaming(init.io, &diagnostic_buffer);
    var session = try ecl.session.Session.initWithHost(
        init.gpa,
        &.{},
        init.io,
        &output_writer.interface,
        &diagnostic_writer.interface,
        init.environ_map.get("ECL_PATH"),
    );
    defer session.deinit();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(init.gpa);
    var input_buffer: [8192]u8 = undefined;
    var file_reader = std.Io.File.stdin().reader(init.io, &input_buffer);
    var continuation = false;
    while (true) {
        try writeFile(init.io, .stdout, if (continuation) ".. " else "ecl> ");
        var line = std.Io.Writer.Allocating.init(init.gpa);
        defer line.deinit();
        const has_delimiter = has: {
            _ = file_reader.interface.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
                error.EndOfStream => break :has false,
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => return error.Io,
            };
            file_reader.interface.toss(1);
            break :has true;
        };
        const line_bytes = try line.toOwnedSlice();
        defer init.gpa.free(line_bytes);
        if (line_bytes.len == 0 and !has_delimiter) {
            if (pending.items.len == 0) {
                try writeFile(init.io, .stdout, "\n");
                return 0;
            }
            return emitIncompleteAtEof(init, &session, pending.items);
        }
        try pending.appendSlice(init.gpa, line_bytes);
        if (has_delimiter) try pending.append(init.gpa, '\n');
        const outcome = try session.runUnit("<repl>", pending.items);
        if (session.requested_exit) |status| return status;
        switch (outcome) {
            .incomplete => continuation = true,
            .ok => {
                try printStack(init, &session);
                pending.clearRetainingCapacity();
                continuation = false;
            },
            .err => |error_value| {
                defer ecl.heap.releaseValue(init.gpa, error_value);
                try printError(init, error_value);
                pending.clearRetainingCapacity();
                continuation = false;
            },
        }
    }
}
fn emitIncompleteAtEof(
    init: std.process.Init,
    session: *ecl.session.Session,
    pending: []const u8,
) AppError!u8 {
    const outcome = try session.runUnit("<repl>", pending);
    return switch (outcome) {
        .incomplete => |incomplete| emitSyntheticError(
            init,
            .parse,
            incomplete.message,
            .{ .source_name = "<repl>", .span = incomplete.span },
        ),
        .ok => 0,
        .err => |error_value| status: {
            defer ecl.heap.releaseValue(init.gpa, error_value);
            try printError(init, error_value);
            break :status 1;
        },
    };
}
fn printStack(init: std.process.Init, session: *const ecl.session.Session) AppError!void {
    const display = try session.stackDisplay();
    defer init.gpa.free(display);
    if (display.len == 0) return;
    try writeFile(init.io, .stdout, display);
    try writeFile(init.io, .stdout, "\n");
}
fn emitSyntheticError(
    init: std.process.Init,
    kind: ecl.machine.ErrorKind,
    message: []const u8,
    location: ?ecl.spans.LocatedSpan,
) AppError!u8 {
    var language_error = ecl.machine.EclErr.init(kind, message);
    defer language_error.deinit(init.gpa);
    const error_value = try language_error.toDict(init.gpa, &.{}, location);
    defer ecl.heap.releaseValue(init.gpa, error_value);
    try printError(init, error_value);
    return 1;
}
fn emitIoError(
    init: std.process.Init,
    context: []const u8,
    host_error: anyerror,
) AppError!u8 {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{s}: {s}",
        .{ context, @errorName(host_error) },
    ) catch context;
    return emitSyntheticError(init, .io, message, null);
}
fn printError(init: std.process.Init, error_value: ecl.value.Value) AppError!void {
    const rendered = try ecl.print.toOwnedString(init.gpa, error_value);
    defer init.gpa.free(rendered);
    try writeFile(init.io, .stderr, rendered);
    try writeFile(init.io, .stderr, "\n");
}
const Output = enum { stdout, stderr };
fn writeFile(io: std.Io, output: Output, bytes: []const u8) AppError!void {
    var buffer: [4096]u8 = undefined;
    var file_writer = switch (output) {
        .stdout => std.Io.File.stdout().writerStreaming(io, &buffer),
        .stderr => std.Io.File.stderr().writerStreaming(io, &buffer),
    };
    file_writer.interface.writeAll(bytes) catch return error.Io;
    file_writer.interface.flush() catch return error.Io;
}
