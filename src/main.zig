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
    \\    ecl pkg <SUBCOMMAND>       Manage the current project's packages
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
        const worker_count = try configuredWorkers(init) orelse return 2;
        const tty = std.Io.File.stdin().isTty(init.io) catch return error.Io;
        return if (tty) repl(init, worker_count) else runStdin(init, &.{}, worker_count);
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
    if (std.mem.eql(u8, first, "pkg")) return packageCommand(init, cli[1..]);
    const worker_count = try configuredWorkers(init) orelse return 2;
    if (std.mem.eql(u8, first, "-e") or std.mem.eql(u8, first, "--eval")) {
        if (cli.len < 2) return emitSyntheticError(
            init,
            .io,
            "-e/--eval requires source text",
            null,
        );
        return executeSource(init, "<command>", cli[1], cli[2..], true, .data, worker_count);
    }
    if (std.mem.eql(u8, first, "-")) return runStdin(init, cli[1..], worker_count);
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
        return executeSource(init, first, source, cli[1..], false, .data, worker_count);
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
    return executeSource(init, "<command>", first, cli[1..], true, .data, worker_count);
}

const package_help =
    \\USAGE:
    \\    ecl pkg <init|add|sync|tree|why|verify|vendor|gc>
    \\    ecl pkg init [name]
    \\    ecl pkg add <name> <version> <https-url>
    \\    ecl pkg sync [--offline]
    \\    ecl pkg tree
    \\    ecl pkg why <module>
    \\    ecl pkg verify
    \\    ecl pkg vendor
    \\    ecl pkg gc <lock-file> [lock-file ...]
    \\
;

fn packageUsage(init: std.process.Init) AppError!u8 {
    try writeFile(init.io, .stderr, package_help);
    return 1;
}

fn packageArguments(
    init: std.process.Init,
    project_root: []const u8,
    trailing: []const []const u8,
) AppError![]const []const u8 {
    const result = init.arena.allocator().alloc([]const u8, trailing.len + 1) catch
        return error.OutOfMemory;
    result[0] = project_root;
    @memcpy(result[1..], trailing);
    return result;
}

fn packageCommand(init: std.process.Init, arguments: []const []const u8) AppError!u8 {
    if (arguments.len == 0) return packageUsage(init);
    const command = arguments[0];
    const worker_count = try configuredWorkers(init) orelse return 2;

    if (std.mem.eql(u8, command, "init")) {
        if (arguments.len != 1 and arguments.len != 2) return packageUsage(init);
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa) catch |err|
            return emitIoError(init, "cannot resolve package project directory", err);
        defer init.gpa.free(cwd);
        const name = if (arguments.len == 2) arguments[1] else std.fs.path.basename(cwd);
        const cli_args = try packageArguments(init, cwd, &.{name});
        return executeSource(
            init,
            "<pkg:init>",
            "args pkg.cli.init",
            cli_args,
            false,
            .program_source,
            worker_count,
        );
    }

    if (std.mem.eql(u8, command, "gc")) {
        if (arguments.len < 2) return packageUsage(init);
        return executeSource(
            init,
            "<pkg:gc>",
            "args pkg.cli.gc",
            arguments[1..],
            false,
            .program_source,
            worker_count,
        );
    }

    const valid_shape = if (std.mem.eql(u8, command, "add"))
        arguments.len == 4
    else if (std.mem.eql(u8, command, "sync"))
        arguments.len == 1 or
            (arguments.len == 2 and std.mem.eql(u8, arguments[1], "--offline"))
    else if (std.mem.eql(u8, command, "tree") or
        std.mem.eql(u8, command, "verify") or
        std.mem.eql(u8, command, "vendor"))
        arguments.len == 1
    else if (std.mem.eql(u8, command, "why"))
        arguments.len == 2
    else
        false;
    if (!valid_shape) return packageUsage(init);

    const discovery = try ecl.project.Root.discover(init.gpa, init.io, ".");
    const project_root = switch (discovery) {
        .absent => return emitSyntheticError(
            init,
            .io,
            "no ecl.pkg found from the working directory to the filesystem root",
            null,
        ),
        .invalid => |failure| {
            defer failure.deinit();
            return emitSyntheticError(init, .io, failure.message(), null);
        },
        .found => |root| root,
    };
    defer project_root.deinit();
    const cli_args = try packageArguments(init, project_root.path(), arguments[1..]);
    const source = if (std.mem.eql(u8, command, "add"))
        "args pkg.cli.add"
    else if (std.mem.eql(u8, command, "sync"))
        if (arguments.len == 2) "args pkg.cli.sync-offline" else "args pkg.cli.sync"
    else if (std.mem.eql(u8, command, "tree"))
        "args pkg.cli.tree"
    else if (std.mem.eql(u8, command, "why"))
        "args pkg.cli.why"
    else if (std.mem.eql(u8, command, "vendor"))
        "args pkg.cli.vendor"
    else
        "args pkg.cli.verify";
    return executeSource(
        init,
        "<pkg>",
        source,
        cli_args,
        false,
        .program_source,
        worker_count,
    );
}
/// One immutable view of the process environment, borrowed from the arena so
/// the Session can copy it once at init.
fn environSnapshot(init: std.process.Init) AppError![]const ecl.machine.Environ.Entry {
    const names = init.environ_map.keys();
    const values = init.environ_map.values();
    const entries = init.arena.allocator().alloc(ecl.machine.Environ.Entry, names.len) catch
        return error.OutOfMemory;
    for (names, values, entries) |name, value, *variable|
        variable.* = .{ .name = name, .value = value };
    return entries;
}
fn configuredWorkers(init: std.process.Init) AppError!?usize {
    const raw = init.environ_map.get("ECL_WORKERS") orelse
        return @max(@as(usize, 1), std.Thread.getCpuCount() catch 1);
    if (raw.len == 0) {
        try writeFile(init.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    }
    for (raw) |byte| if (!std.ascii.isDigit(byte)) {
        try writeFile(init.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    };
    const count = std.fmt.parseInt(usize, raw, 10) catch {
        try writeFile(init.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    };
    if (count == 0) {
        try writeFile(init.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    }
    return count;
}
fn runStdin(init: std.process.Init, arguments: []const []const u8, worker_count: usize) AppError!u8 {
    var buffer: [8192]u8 = undefined;
    var file_reader = std.Io.File.stdin().reader(init.io, &buffer);
    const source = file_reader.interface.allocRemaining(init.gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return emitIoError(init, "cannot read stdin", err),
    };
    defer init.gpa.free(source);
    return executeSource(init, "<stdin>", source, arguments, true, .program_source, worker_count);
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
    standard_input: ecl.machine.StandardInput.Availability,
    worker_count: usize,
) AppError!u8 {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var diagnostic_buffer: [4096]u8 = undefined;
    var diagnostic_writer = std.Io.File.stderr().writerStreaming(init.io, &diagnostic_buffer);
    var session = try ecl.session.Session.initWithHostConfig(
        init.gpa,
        arguments,
        .{
            .io = init.io,
            .output = &output_writer.interface,
            .diagnostics = &diagnostic_writer.interface,
            .ecl_path = init.environ_map.get("ECL_PATH"),
            .project_start = ".",
            .environ = try environSnapshot(init),
            .standard_input = standard_input,
        },
        .{ .worker_pool = worker_count },
    );
    defer session.deinit();
    session.setNativeDiagnostics(init.environ_map.get("ECL_NATIVE_DIAGNOSTICS") != null);
    const outcome = try session.runUnit(source_name, source);
    if (session.requestedExit()) |status| return status;
    switch (outcome) {
        .ok => {
            if (print_stack) try printStack(&session);
            return 0;
        },
        .incomplete => |incomplete| return emitSyntheticError(
            init,
            .parse,
            incomplete.message,
            .{ .source_name = source_name, .span = incomplete.span },
        ),
        .err => |error_value| {
            defer session.release(error_value);
            try printSessionError(init, &session, error_value);
            return 1;
        },
    }
}
fn repl(init: std.process.Init, worker_count: usize) AppError!u8 {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var diagnostic_buffer: [4096]u8 = undefined;
    var diagnostic_writer = std.Io.File.stderr().writerStreaming(init.io, &diagnostic_buffer);
    var session = try ecl.session.Session.initWithHostConfig(
        init.gpa,
        &.{},
        .{
            .io = init.io,
            .output = &output_writer.interface,
            .diagnostics = &diagnostic_writer.interface,
            .ecl_path = init.environ_map.get("ECL_PATH"),
            .project_start = ".",
            .environ = try environSnapshot(init),
            .standard_input = .program_source,
        },
        .{ .worker_pool = worker_count },
    );
    defer session.deinit();
    session.setNativeDiagnostics(init.environ_map.get("ECL_NATIVE_DIAGNOSTICS") != null);
    const history_path = if (init.environ_map.get("HOME")) |home|
        std.Io.Dir.path.join(init.gpa, &.{ home, ".ecl_history" }) catch
            return error.OutOfMemory
    else
        null;
    defer if (history_path) |path| init.gpa.free(path);
    var editor = try ecl.line_editor.Editor.init(init.gpa, init.io, history_path);
    defer editor.deinit();
    var pending = try ecl.reader.PendingUnit.init(init.gpa);
    defer pending.deinit();
    while (true) {
        const result = editor.readLine(
            session.editorTerminal(),
            session.completionObserve(),
            if (pending.isEmpty()) .primary else .continuation,
            pending,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed, error.WriteFailed, error.TerminalFailure => return error.Io,
        };
        if (editor.takeHistoryWarning()) |warning|
            session.writeDiagnosticsLine(warning) catch return error.Io;
        const line_bytes = switch (result) {
            .cancelled => {
                pending.clear();
                continue;
            },
            .eof => {
                if (pending.isEmpty()) return 0;
                return emitIncompleteAtEof(init, &session, pending.source());
            },
            .line => |owned| bytes: {
                var line = owned;
                defer line.deinit();
                try pending.appendLine(line.bytes());
                break :bytes pending.source();
            },
        };
        const outcome = try session.runUnit("<repl>", line_bytes);
        if (session.requestedExit()) |status| return status;
        switch (outcome) {
            .incomplete => {},
            .ok => {
                try printStack(&session);
                pending.clear();
            },
            .err => |error_value| {
                defer session.release(error_value);
                try printSessionError(init, &session, error_value);
                pending.clear();
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
            defer session.release(error_value);
            try printSessionError(init, session, error_value);
            break :status 1;
        },
    };
}
fn printStack(session: *ecl.session.Session) AppError!void {
    var display = try session.stackDisplay();
    defer display.deinit();
    if (display.bytes().len == 0) return;
    session.writeOutputLine(display.bytes()) catch return error.Io;
}
fn emitSyntheticError(
    init: std.process.Init,
    kind: ecl.machine.ErrorKind,
    message: []const u8,
    location: ?ecl.spans.LocatedSpan,
) AppError!u8 {
    var host = ecl.heap.HostOwner.init(init.gpa);
    const releases = host.domain();
    defer host.cleanup().drain();
    var language_error = ecl.machine.EclErr.init(kind, message);
    defer language_error.retire(releases);
    const error_value = try ecl.machine.errorValue(
        init.gpa,
        releases,
        &language_error,
        .{},
        location,
    );
    defer releases.releaseValue(error_value);
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
fn printSessionError(
    init: std.process.Init,
    session: *ecl.session.Session,
    error_value: ecl.value.Value,
) AppError!void {
    const rendered = try ecl.print.toOwnedString(init.gpa, error_value);
    defer init.gpa.free(rendered);
    session.writeDiagnosticsLine(rendered) catch return error.Io;
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
