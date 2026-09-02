const std = @import("std");
const ecl = @import("ecl");
const AppError = error{ OutOfMemory, Io, InvalidHostPolicy };
const help =
    \\ecl — a homoiconic concatenative array calculator
    \\
    \\USAGE:
    \\    ecl                         Start a REPL (or read stdin as one unit)
    \\    ecl -e <SOURCE> [ARGS...]  Evaluate source and print the stack
    \\    ecl <FILE> [ARGS...]       Run a UTF-8 script
    \\    ecl <SOURCE> [ARGS...]     Evaluate source and print the stack
    \\    ecl fmt <FILE|->           Format source to standard output
    \\    ecl fmt -w <FILE>          Format and atomically rewrite a file
    \\    ecl pkg <SUBCOMMAND>       Manage the current project's packages
    \\    ecl test [OPTIONS] [-- ARGS...]  Run the root project's tests
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
        error.InvalidHostPolicy => failure: {
            writeFile(init.io, .stderr, "ecl: host filesystem, package store, or process policy is invalid\n") catch
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
    if (std.mem.eql(u8, first, "test")) return testCommand(init, cli[1..]);
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

const test_help =
    \\USAGE:
    \\    ecl test [--runner <qualified-word>] [-- <arguments...>]
    \\
    \\OPTIONS:
    \\    --runner <qualified-word>  Select a public userland runner
    \\
;

fn testUsage(init: std.process.Init) AppError!u8 {
    try writeFile(init.io, .stderr, test_help);
    return 1;
}

fn validateRunner(name: []const u8) AppError!bool {
    const separator = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (separator == 0 or separator + 1 == name.len) return false;
    _ = ecl.intern.internModuleName(name[0..separator]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => return false,
    };
    _ = ecl.intern.internNamespace(name[separator + 1 ..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidName => return false,
    };
    return true;
}

fn testCommand(init: std.process.Init, arguments: []const []const u8) AppError!u8 {
    var runner: []const u8 = "test.default.run";
    var trailing: []const []const u8 = &.{};
    var index: usize = 0;
    while (index < arguments.len) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--")) {
            trailing = arguments[index + 1 ..];
            index = arguments.len;
            break;
        }
        if (std.mem.eql(u8, argument, "--runner")) {
            if (index + 1 >= arguments.len) return testUsage(init);
            runner = arguments[index + 1];
            index += 2;
            continue;
        }
        return testUsage(init);
    }
    if (!try validateRunner(runner)) return emitSyntheticError(
        init,
        .domain,
        "ecl test runner must be a qualified public word",
        null,
    );

    const worker_count = try configuredWorkers(init) orelse return 2;
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var diagnostic_buffer: [4096]u8 = undefined;
    var diagnostic_writer = std.Io.File.stderr().writerStreaming(init.io, &diagnostic_buffer);
    const initial_cwd = std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa) catch |err|
        return emitIoError(init, "cannot resolve process working directory", err);
    defer init.gpa.free(initial_cwd);
    var runtime = try ecl.session.Session.initTestWithHostConfig(
        init.gpa,
        trailing,
        .{
            .io = init.io,
            .output = &output_writer.interface,
            .diagnostics = &diagnostic_writer.interface,
            .ecl_path = init.environ_map.get("ECL_PATH"),
            .project_start = ".",
            .environ = try environSnapshot(init),
            .standard_input = .data,
            .process_policy = .{
                .executables = .unrestricted,
                .initial_cwd = initial_cwd,
                .inherit_environment = true,
            },
            .filesystem_policy = .{ .roots = &.{cwdRoot(initial_cwd)} },
            .net_policy = .{ .binds = .unrestricted },
            .clock = .{ .wall = .host },
        },
        .{ .worker_pool = worker_count },
    );
    defer runtime.deinit();
    runtime.setNativeDiagnostics(init.environ_map.get("ECL_NATIVE_DIAGNOSTICS") != null);

    while (true) switch (try runtime.advanceRootPreload()) {
        .pending => {},
        .complete => break,
        .no_project => return emitSyntheticError(
            init,
            .io,
            "ecl test requires a lock-backed root project; run `ecl pkg sync`",
            null,
        ),
        .invalid => |message| return emitSyntheticError(init, .io, message, null),
        .err => |failure| {
            defer runtime.release(failure);
            try printSessionError(init, &runtime, failure);
            return 1;
        },
    };
    if (runtime.requestedExit()) |status| return status;

    const outcome = try runtime.runUnit("<test-runner>", runner);
    if (runtime.requestedExit()) |status| return status;
    return switch (outcome) {
        .ok => 0,
        .incomplete => |incomplete| emitSyntheticError(
            init,
            .parse,
            incomplete.message,
            .{ .source_name = "<test-runner>", .span = incomplete.span },
        ),
        .err => |failure| status: {
            defer runtime.release(failure);
            try printSessionError(init, &runtime, failure);
            break :status 1;
        },
    };
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
    \\Lock files given to gc are canonical relative paths beneath the working
    \\directory; commands read and write project files only beneath the
    \\discovered project root.
    \\
;

fn packageUsage(init: std.process.Init) AppError!u8 {
    try writeFile(init.io, .stderr, package_help);
    return 1;
}

/// The host-selected shared package cache as an absolute path, or null when
/// no environment variable names one. A relative selection keeps its
/// established meaning by resolving once against the captured startup
/// directory; evaluated package code never derives or sees this path.
fn cacheRootFromEnviron(init: std.process.Init, startup_directory: []const u8) AppError!?[]u8 {
    const selected = try ecl.pkg_lock.cacheRoot(init.gpa, .{
        .ecl_cache = init.environ_map.get("ECL_CACHE"),
        .xdg_cache_home = init.environ_map.get("XDG_CACHE_HOME"),
        .home = init.environ_map.get("HOME"),
    }) orelse return null;
    if (std.fs.path.isAbsolute(selected)) return selected;
    defer init.gpa.free(selected);
    return std.fs.path.join(init.gpa, &.{ startup_directory, selected }) catch return error.OutOfMemory;
}

/// The sentinel slice `realPathFileAlloc` hands back must be freed as one.
fn startupDirectory(init: std.process.Init) AppError![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
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
        return executeSource(
            init,
            "<pkg:init>",
            "args pkg.cli.init",
            &.{name},
            false,
            .program_source,
            worker_count,
        );
    }

    const startup = try startupDirectory(init);
    defer init.gpa.free(startup);
    if (std.mem.eql(u8, command, "gc")) {
        if (arguments.len < 2) return packageUsage(init);
        const cache = try cacheRootFromEnviron(init, startup);
        defer if (cache) |root| init.gpa.free(root);
        return executePackageSource(
            init,
            "<pkg:gc>",
            "args pkg.cli.gc",
            arguments[1..],
            null,
            .{ .collect = .{ .cache = cache } },
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
    const cache = try cacheRootFromEnviron(init, startup);
    defer if (cache) |root| init.gpa.free(root);
    // The discovered project is trusted host input resolved once, here. The
    // package authority reaches the vendor store only as the fixed child of
    // this retained handle, so no path names it.
    var project_handle = std.Io.Dir.cwd().openDir(init.io, project_root.path(), .{}) catch |err|
        return emitIoError(init, "cannot open project root", err);
    defer project_handle.close(init.io);
    // Each command names exactly the stores it may touch. Mutating commands
    // may create an absent cache; read-only commands leave absence visible.
    const grant: ecl.package_authority.PackageGrant = if (std.mem.eql(u8, command, "add") or
        std.mem.eql(u8, command, "sync"))
        .{ .synchronize = .{ .cache = cache, .project = project_handle } }
    else if (std.mem.eql(u8, command, "vendor"))
        .{ .vendor = .{ .cache = cache, .project = project_handle } }
    else if (std.mem.eql(u8, command, "verify"))
        .{ .verify = .{ .cache = cache, .project = project_handle } }
    else
        .inspect;
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
    return executePackageSource(
        init,
        "<pkg>",
        source,
        arguments[1..],
        project_root.path(),
        grant,
        worker_count,
    );
}
/// The one filesystem root every command-line Session receives: the startup
/// working directory, captured once, with every v1 permission. Embedders get
/// nothing by default; the CLI is the program that deliberately grants it.
fn cwdRoot(initial_cwd: []const u8) ecl.filesystem_port.Root {
    return .{ .name = "cwd", .absolute_path = initial_cwd, .permissions = .all };
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
    const write_in_place = arguments.len > 0 and std.mem.eql(u8, arguments[0], "-w");
    if ((write_in_place and arguments.len != 2) or (!write_in_place and arguments.len != 1)) {
        try writeFile(init.io, .stderr, "ecl fmt: usage: ecl fmt [-w] <FILE|->\n");
        return 1;
    }
    const source_path = arguments[@intFromBool(write_in_place)];
    if (write_in_place and std.mem.eql(u8, source_path, "-")) {
        try writeFile(init.io, .stderr, "ecl fmt: -w requires a file path\n");
        return 1;
    }
    var permissions: std.Io.File.Permissions = .default_file;
    if (write_in_place) {
        const info = std.Io.Dir.cwd().statFile(
            init.io,
            source_path,
            .{ .follow_symlinks = false },
        ) catch |err| return emitIoError(init, "cannot inspect format input", err);
        if (info.kind != .file) return formatTargetNotRegular(init, source_path);
        permissions = info.permissions;
    }
    const source = if (std.mem.eql(u8, source_path, "-"))
        try readFormatStdin(init)
    else
        std.Io.Dir.cwd().readFileAlloc(init.io, source_path, init.gpa, .unlimited) catch |err|
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
    if (write_in_place) {
        if (std.mem.eql(u8, source, formatted)) return 0;
        return writeFormattedFile(init, source_path, permissions, formatted);
    }
    try writeFile(init.io, .stdout, formatted);
    return 0;
}

fn formatTargetNotRegular(init: std.process.Init, path: []const u8) AppError!u8 {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "ecl fmt: -w target `{s}` is not a regular file\n",
        .{path},
    ) catch "ecl fmt: -w target is not a regular file\n";
    try writeFile(init.io, .stderr, message);
    return 1;
}

fn writeFormattedFile(
    init: std.process.Init,
    path: []const u8,
    permissions: std.Io.File.Permissions,
    formatted: []const u8,
) AppError!u8 {
    const parent_path = std.fs.path.dirname(path) orelse ".";
    var parent = std.Io.Dir.cwd().openDir(
        init.io,
        parent_path,
        .{ .follow_symlinks = false },
    ) catch |err| return emitIoError(init, "cannot open format output directory", err);
    defer parent.close(init.io);
    const basename = std.fs.path.basename(path);
    var atomic = parent.createFileAtomic(init.io, basename, .{
        .permissions = permissions,
        .replace = true,
    }) catch |err| return emitIoError(init, "cannot create format output", err);
    defer atomic.deinit(init.io);

    var output_buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(init.io, &output_buffer);
    writer.interface.writeAll(formatted) catch |err|
        return emitIoError(init, "cannot write format output", err);
    writer.interface.flush() catch |err|
        return emitIoError(init, "cannot write format output", err);
    atomic.file.sync(init.io) catch |err|
        return emitIoError(init, "cannot synchronize format output", err);

    const current = parent.statFile(
        init.io,
        basename,
        .{ .follow_symlinks = false },
    ) catch |err| return emitIoError(init, "cannot recheck format input", err);
    if (current.kind != .file) return formatTargetNotRegular(init, path);
    atomic.replace(init.io) catch |err|
        return emitIoError(init, "cannot publish format output", err);
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
    return executeWith(init, source_name, source, arguments, print_stack, standard_input, worker_count, null, null);
}

/// A package command: the ordinary command-line Session plus the `'project`
/// filesystem root and the opaque package-store authority.
fn executePackageSource(
    init: std.process.Init,
    source_name: []const u8,
    source: []const u8,
    arguments: []const []const u8,
    project_root: ?[]const u8,
    grant: ecl.package_authority.PackageGrant,
    worker_count: usize,
) AppError!u8 {
    return executeWith(init, source_name, source, arguments, false, .program_source, worker_count, project_root, grant);
}

fn executeWith(
    init: std.process.Init,
    source_name: []const u8,
    source: []const u8,
    arguments: []const []const u8,
    print_stack: bool,
    standard_input: ecl.machine.StandardInput.Availability,
    worker_count: usize,
    project_root: ?[]const u8,
    package_grant: ?ecl.package_authority.PackageGrant,
) AppError!u8 {
    var output_buffer: [4096]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var diagnostic_buffer: [4096]u8 = undefined;
    var diagnostic_writer = std.Io.File.stderr().writerStreaming(init.io, &diagnostic_buffer);
    const initial_cwd = std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa) catch |err|
        return emitIoError(init, "cannot resolve process working directory", err);
    defer init.gpa.free(initial_cwd);
    // SAFETY: the second slot is read only through `filesystem_roots[0..root_count]`,
    // and `root_count` becomes 2 only after that slot is assigned below.
    var filesystem_roots: [2]ecl.filesystem_port.Root = .{ cwdRoot(initial_cwd), undefined };
    var root_count: usize = 1;
    if (project_root) |path| {
        filesystem_roots[1] = .{
            .name = "project",
            .absolute_path = path,
            .permissions = .{ .read_data = true, .inspect = true, .create = true, .replace = true },
        };
        root_count = 2;
    }
    const host: ecl.session.Host = .{
        .io = init.io,
        .output = &output_writer.interface,
        .diagnostics = &diagnostic_writer.interface,
        .ecl_path = init.environ_map.get("ECL_PATH"),
        .project_start = ".",
        .environ = try environSnapshot(init),
        .standard_input = standard_input,
        .process_policy = .{
            .executables = .unrestricted,
            .initial_cwd = initial_cwd,
            .inherit_environment = true,
        },
        .filesystem_policy = .{ .roots = filesystem_roots[0..root_count] },
        .net_policy = .{ .binds = .unrestricted },
        .clock = .{ .wall = .host },
    };
    var session = if (package_grant) |grant|
        try ecl.session.Session.initPackageCommand(init.gpa, arguments, host, .{ .worker_pool = worker_count }, grant)
    else
        try ecl.session.Session.initWithHostConfig(init.gpa, arguments, host, .{ .worker_pool = worker_count });
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
    const initial_cwd = std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa) catch |err|
        return emitIoError(init, "cannot resolve process working directory", err);
    defer init.gpa.free(initial_cwd);
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
            .process_policy = .{
                .executables = .unrestricted,
                .initial_cwd = initial_cwd,
                .inherit_environment = true,
            },
            .filesystem_policy = .{ .roots = &.{cwdRoot(initial_cwd)} },
            .net_policy = .{ .binds = .unrestricted },
            .clock = .{ .wall = .host },
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
