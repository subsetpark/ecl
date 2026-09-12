const std = @import("std");
const ecl = @import("ecl-internal");
const AppError = error{ OutOfMemory, Io, InvalidHostConfig };
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
    \\    ecl check-map <FILE>       Validate an inert module map
    \\    ecl pkg <SUBCOMMAND>       Manage the current project's packages
    \\    ecl test [OPTIONS] [-- ARGS...]  Run the root project's tests
    \\
    \\OPTIONS:
    \\    -e, --eval <SOURCE>        Evaluate source text
    \\    --module-map <FILE>       Load an explicit module map (before command)
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
        error.InvalidHostConfig => failure: {
            writeFile(init.io, .stderr, "ecl: runtime directories, module map, package store, or limits are invalid\n") catch
                std.process.exit(1);
            break :failure 1;
        },
    };
    if (status != 0) std.process.exit(status);
}
const Startup = struct {
    process: std.process.Init,
    cwd: []const u8,
    environ: []const ecl.machine.Environ.Entry,
    module_map: ?[]const u8 = null,
};

extern "c" fn ecl_git_helper(url: [*:0]const u8, selector: [*:0]const u8, revision: [*:0]const u8, ca_file: [*:0]const u8) c_int;

fn entry(process: std.process.Init) AppError!u8 {
    const args = process.minimal.args.toSlice(process.arena.allocator()) catch return error.OutOfMemory;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--ecl-private-git-helper")) {
        if (args.len != 6) return 2;
        return @intCast(ecl_git_helper(args[2], args[3], args[4], args[5]));
    }
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(process.io, ".", process.gpa) catch return error.Io;
    defer process.gpa.free(cwd);
    const init: Startup = .{ .process = process, .cwd = cwd, .environ = try environSnapshot(process) };
    return dispatch(init);
}

fn dispatch(startup: Startup) AppError!u8 {
    var init = startup;
    const arguments = init.process.minimal.args.toSlice(init.process.arena.allocator()) catch
        return error.OutOfMemory;
    var cli = arguments[1..];
    if (cli.len != 0 and std.mem.eql(u8, cli[0], "--module-map")) {
        if (cli.len < 2) return emitSyntheticError(init, .io, "--module-map requires a file", null);
        init.module_map = cli[1];
        cli = cli[2..];
    }
    if (cli.len == 0) {
        const worker_count = try configuredWorkers(init) orelse return 2;
        const tty = std.Io.File.stdin().isTty(init.process.io) catch return error.Io;
        return if (tty) repl(init, worker_count) else runStdin(init, &.{}, worker_count);
    }
    const first = cli[0];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        try writeFile(init.process.io, .stdout, help);
        return 0;
    }
    if (std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "--version")) {
        var buffer: [64]u8 = undefined;
        const version = std.fmt.bufPrint(&buffer, "ecl {s}\n", .{ecl.version}) catch
            @panic("version string exceeds its fixed output buffer");
        try writeFile(init.process.io, .stdout, version);
        return 0;
    }
    if (std.mem.eql(u8, first, "fmt")) return formatCommand(init, cli[1..]);
    if (std.mem.eql(u8, first, "check-map")) return checkMapCommand(init, cli[1..]);
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
    if (try installedApplication(init, first, cli[1..], worker_count)) |status| return status;
    const is_file: bool = file: {
        std.Io.Dir.cwd().access(init.process.io, first, .{ .read = true }) catch |err| switch (err) {
            error.FileNotFound, error.NameTooLong, error.BadPathName => break :file false,
            else => return emitIoError(init, "cannot access script", err),
        };
        break :file true;
    };
    if (is_file) {
        const source = std.Io.Dir.cwd().readFileAlloc(
            init.process.io,
            first,
            init.process.gpa,
            .unlimited,
        ) catch |err| return emitIoError(init, "cannot read script", err);
        defer init.process.gpa.free(source);
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

/// Installation-owned descriptors are inert JSON, parsed before constructing
/// a Session. Application startup therefore does not inspect the caller's map.
const ApplicationDescriptor = struct {
    format: u32,
    entry: []const u8,
    module_map: []const u8,
};

fn checkMapCommand(init: Startup, arguments: []const []const u8) AppError!u8 {
    if (arguments.len != 1) {
        try writeFile(init.process.io, .stderr, "ecl check-map: usage: ecl check-map <FILE>\n");
        return 1;
    }
    const path = try std.fs.path.resolve(init.process.gpa, &.{ init.cwd, arguments[0] });
    defer init.process.gpa.free(path);
    var host = ecl.heap.HostOwner.init(init.process.gpa);
    defer host.cleanup().drain();
    const map = ecl.module_map.load(host.cleanup(), init.process.io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return emitSyntheticError(init, .io, "invalid module map", null),
    };
    defer map.deinit();
    return 0;
}

fn applicationName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    return true;
}

fn applicationRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 32 or byte == 127 or byte == '\\' or byte == ':') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn installedApplication(init: Startup, name: []const u8, arguments: []const []const u8, worker_count: usize) AppError!?u8 {
    if (!applicationName(name)) return null;
    const allocator = init.process.gpa;
    const executable = std.process.executablePathAlloc(init.process.io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };
    defer allocator.free(executable);
    const bin = std.fs.path.dirname(executable) orelse return null;
    const prefix = std.fs.path.dirname(bin) orelse return null;
    const app_dir = try std.fs.path.join(allocator, &.{ prefix, "share", "ecl", "apps", name });
    defer allocator.free(app_dir);
    const descriptor_path = try std.fs.path.join(allocator, &.{ app_dir, "application.json" });
    defer allocator.free(descriptor_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.process.io, descriptor_path, allocator, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return try emitIoError(init, "cannot read installed application descriptor", err),
    };
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(ApplicationDescriptor, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try emitSyntheticError(init, .io, "invalid installed application descriptor", null),
    };
    defer parsed.deinit();
    const descriptor = parsed.value;
    if (descriptor.format != 1 or !applicationRelativePath(descriptor.entry) or !applicationRelativePath(descriptor.module_map))
        return try emitSyntheticError(init, .io, "invalid installed application descriptor", null);
    const entry_path = try std.fs.path.join(allocator, &.{ app_dir, descriptor.entry });
    defer allocator.free(entry_path);
    const map = try std.fs.path.join(allocator, &.{ app_dir, descriptor.module_map });
    defer allocator.free(map);
    const source = std.Io.Dir.cwd().readFileAlloc(init.process.io, entry_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try emitIoError(init, "cannot read installed application entry", err),
    };
    defer allocator.free(source);
    var application = init;
    application.module_map = map;
    return try executeSource(application, entry_path, source, arguments, false, .data, worker_count);
}

const test_help =
    \\USAGE:
    \\    ecl test [--runner <qualified-word>] [-- <arguments...>]
    \\
    \\OPTIONS:
    \\    --runner <qualified-word>  Select a public userland runner
    \\
;

fn testUsage(init: Startup) AppError!u8 {
    try writeFile(init.process.io, .stderr, test_help);
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

/// Initialized at its final address: writers borrow these buffers, and the
/// Session borrows the writers and roots until teardown. Do not move after init.
const CliRuntime = struct {
    output_buffer: [4096]u8,
    diagnostic_buffer: [4096]u8,
    output_writer: std.Io.File.Writer,
    diagnostic_writer: std.Io.File.Writer,
    roots: [2]ecl.filesystem_port.Root,
    session: ecl.session.Session,

    fn init(
        self: *CliRuntime,
        startup: Startup,
        arguments: []const []const u8,
        worker_count: usize,
        standard_input: ecl.machine.StandardInput.Availability,
        mode: ecl.session.CommandMode,
        project_root: ?[]const u8,
    ) AppError!void {
        self.output_writer = std.Io.File.stdout().writerStreaming(startup.process.io, &self.output_buffer);
        self.diagnostic_writer = std.Io.File.stderr().writerStreaming(startup.process.io, &self.diagnostic_buffer);
        self.roots[0] = cwdRoot(startup.cwd);
        const root_count: usize = if (project_root) |path| count: {
            self.roots[1] = .{ .name = "project", .absolute_path = path };
            break :count 2;
        } else 1;
        self.session = try ecl.session.Session.init(
            startup.process.gpa,
            arguments,
            .{
                .io = startup.process.io,
                .output = &self.output_writer.interface,
                .diagnostics = &self.diagnostic_writer.interface,
                .ecl_path = startup.process.environ_map.get("ECL_PATH"),
                .module_map = startup.module_map,
                .environ = startup.environ,
                .standard_input = standard_input,
                .initial_cwd = startup.cwd,
                .filesystem = .{ .roots = self.roots[0..root_count] },
                .clock = .{ .wall = .host },
            },
            .{ .worker_pool = worker_count },
            mode,
        );
        self.session.setNativeDiagnostics(startup.process.environ_map.get("ECL_NATIVE_DIAGNOSTICS") != null);
    }

    fn deinit(self: *CliRuntime) void {
        self.session.deinit();
        self.* = undefined;
    }
};

fn testCommand(init: Startup, arguments: []const []const u8) AppError!u8 {
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
    // SAFETY: init fills borrowed storage and the Session before use; only a
    // successful init installs the teardown defer, and cli stays at this address.
    var cli: CliRuntime = undefined;
    try cli.init(init, trailing, worker_count, .data, .language_tests, null);
    defer cli.deinit();
    const runtime = &cli.session;

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
            try printSessionError(init, runtime, failure);
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
            try printSessionError(init, runtime, failure);
            break :status 1;
        },
    };
}

const package_help =
    \\USAGE:
    \\    ecl pkg <init|add|sync|tree|why|verify|vendor|gc>
    \\    ecl pkg init [name]
    \\    ecl pkg add <name> <version> <https-url>
    \\    ecl pkg add <https-git-url> <--tag tag|--commit full-id>
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

fn packageUsage(init: Startup) AppError!u8 {
    try writeFile(init.process.io, .stderr, package_help);
    return 1;
}

/// The host-selected shared package cache as an absolute path, or null when
/// no environment variable names one. A relative selection keeps its
/// established meaning by resolving once against the captured startup
/// directory; evaluated package code never derives or sees this path.
fn cacheRootFromEnviron(init: Startup, startup_directory: []const u8) AppError!?[]u8 {
    const selected = try ecl.pkg_lock.cacheRoot(init.process.gpa, .{
        .ecl_cache = init.process.environ_map.get("ECL_CACHE"),
        .xdg_cache_home = init.process.environ_map.get("XDG_CACHE_HOME"),
        .home = init.process.environ_map.get("HOME"),
    }) orelse return null;
    if (std.fs.path.isAbsolute(selected)) return selected;
    defer init.process.gpa.free(selected);
    return std.fs.path.join(init.process.gpa, &.{ startup_directory, selected }) catch return error.OutOfMemory;
}

/// The sentinel slice `realPathFileAlloc` hands back must be freed as one.
fn startupDirectory(init: Startup) AppError![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(init.process.io, ".", init.process.gpa) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn packageCommand(init: Startup, arguments: []const []const u8) AppError!u8 {
    if (arguments.len == 0) return packageUsage(init);
    const command = arguments[0];
    const worker_count = try configuredWorkers(init) orelse return 2;

    if (std.mem.eql(u8, command, "init")) {
        if (arguments.len != 1 and arguments.len != 2) return packageUsage(init);
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(init.process.io, ".", init.process.gpa) catch |err|
            return emitIoError(init, "cannot resolve package project directory", err);
        defer init.process.gpa.free(cwd);
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
    defer init.process.gpa.free(startup);
    if (std.mem.eql(u8, command, "gc")) {
        if (arguments.len < 2) return packageUsage(init);
        const cache = try cacheRootFromEnviron(init, startup);
        defer if (cache) |root| init.process.gpa.free(root);
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

    const git_add = std.mem.eql(u8, command, "add") and arguments.len >= 2 and
        std.mem.startsWith(u8, arguments[1], "https://");
    const valid_shape = if (std.mem.eql(u8, command, "add"))
        arguments.len == 4 and (!git_add or std.mem.eql(u8, arguments[2], "--tag") or std.mem.eql(u8, arguments[2], "--commit"))
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

    const discovery = try ecl.project.Root.discover(init.process.gpa, init.process.io, ".");
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
    defer if (cache) |root| init.process.gpa.free(root);
    // The discovered project is trusted host input resolved once, here. The
    // package authority reaches the vendor store only as the fixed child of
    // this retained handle, so no path names it.
    var project_handle = std.Io.Dir.cwd().openDir(init.process.io, project_root.path(), .{}) catch |err|
        return emitIoError(init, "cannot open project root", err);
    defer project_handle.close(init.process.io);
    // Each command names exactly the stores it may touch. Mutating commands
    // may create an absent cache; read-only commands leave absence visible.
    const executable = std.process.executablePathAlloc(init.process.io, init.process.gpa) catch return error.Io;
    defer init.process.gpa.free(executable);
    const grant: ecl.package_authority.PackageGrant = if (std.mem.eql(u8, command, "add") or
        std.mem.eql(u8, command, "sync"))
        .{ .synchronize = .{ .cache = cache, .project = project_handle, .git = .{ .executable = executable, .ca_file = init.process.environ_map.get("ECL_GIT_CA_FILE") } } }
    else if (std.mem.eql(u8, command, "vendor"))
        .{ .vendor = .{ .cache = cache, .project = project_handle } }
    else if (std.mem.eql(u8, command, "verify"))
        .{ .verify = .{ .cache = cache, .project = project_handle } }
    else
        .inspect;
    const source = if (std.mem.eql(u8, command, "add"))
        if (git_add) "args pkg.cli.add-git" else "args pkg.cli.add"
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
/// working directory, captured once.
fn cwdRoot(initial_cwd: []const u8) ecl.filesystem_port.Root {
    return .{ .name = "cwd", .absolute_path = initial_cwd };
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
fn configuredWorkers(init: Startup) AppError!?usize {
    const raw = init.process.environ_map.get("ECL_WORKERS") orelse
        return @max(@as(usize, 1), std.Thread.getCpuCount() catch 1);
    if (raw.len == 0) {
        try writeFile(init.process.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    }
    for (raw) |byte| if (!std.ascii.isDigit(byte)) {
        try writeFile(init.process.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    };
    const count = std.fmt.parseInt(usize, raw, 10) catch {
        try writeFile(init.process.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    };
    if (count == 0) {
        try writeFile(init.process.io, .stderr, "ecl: ECL_WORKERS must be a positive base-10 integer\n");
        return null;
    }
    return count;
}
fn runStdin(init: Startup, arguments: []const []const u8, worker_count: usize) AppError!u8 {
    var buffer: [8192]u8 = undefined;
    var file_reader = std.Io.File.stdin().reader(init.process.io, &buffer);
    const source = file_reader.interface.allocRemaining(init.process.gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return emitIoError(init, "cannot read stdin", err),
    };
    defer init.process.gpa.free(source);
    return executeSource(init, "<stdin>", source, arguments, true, .program_source, worker_count);
}

fn readFormatStdin(init: Startup) AppError![]u8 {
    var buffer: [8192]u8 = undefined;
    var file_reader = std.Io.File.stdin().reader(init.process.io, &buffer);
    return file_reader.interface.allocRemaining(init.process.gpa, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };
}

fn formatCommand(init: Startup, arguments: []const []const u8) AppError!u8 {
    const write_in_place = arguments.len > 0 and std.mem.eql(u8, arguments[0], "-w");
    if ((write_in_place and arguments.len != 2) or (!write_in_place and arguments.len != 1)) {
        try writeFile(init.process.io, .stderr, "ecl fmt: usage: ecl fmt [-w] <FILE|->\n");
        return 1;
    }
    const source_path = arguments[@intFromBool(write_in_place)];
    if (write_in_place and std.mem.eql(u8, source_path, "-")) {
        try writeFile(init.process.io, .stderr, "ecl fmt: -w requires a file path\n");
        return 1;
    }
    var permissions: std.Io.File.Permissions = .default_file;
    if (write_in_place) {
        const info = std.Io.Dir.cwd().statFile(
            init.process.io,
            source_path,
            .{ .follow_symlinks = false },
        ) catch |err| return emitIoError(init, "cannot inspect format input", err);
        if (info.kind != .file) return formatTargetNotRegular(init, source_path);
        permissions = info.permissions;
    }
    const source = if (std.mem.eql(u8, source_path, "-"))
        try readFormatStdin(init)
    else
        std.Io.Dir.cwd().readFileAlloc(init.process.io, source_path, init.process.gpa, .unlimited) catch |err|
            return emitIoError(init, "cannot read format input", err);
    defer init.process.gpa.free(source);
    const formatted = ecl.formatter.format(init.process.gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => {
            try writeFile(init.process.io, .stderr, "ecl fmt: source is not valid UTF-8\n");
            return 1;
        },
        error.InvalidSource => {
            try writeFile(init.process.io, .stderr, "ecl fmt: source does not parse\n");
            return 1;
        },
    };
    defer init.process.gpa.free(formatted);
    if (write_in_place) {
        if (std.mem.eql(u8, source, formatted)) return 0;
        return writeFormattedFile(init, source_path, permissions, formatted);
    }
    try writeFile(init.process.io, .stdout, formatted);
    return 0;
}

fn formatTargetNotRegular(init: Startup, path: []const u8) AppError!u8 {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "ecl fmt: -w target `{s}` is not a regular file\n",
        .{path},
    ) catch "ecl fmt: -w target is not a regular file\n";
    try writeFile(init.process.io, .stderr, message);
    return 1;
}

fn writeFormattedFile(
    init: Startup,
    path: []const u8,
    permissions: std.Io.File.Permissions,
    formatted: []const u8,
) AppError!u8 {
    const parent_path = std.fs.path.dirname(path) orelse ".";
    var parent = std.Io.Dir.cwd().openDir(
        init.process.io,
        parent_path,
        .{ .follow_symlinks = false },
    ) catch |err| return emitIoError(init, "cannot open format output directory", err);
    defer parent.close(init.process.io);
    const basename = std.fs.path.basename(path);
    var atomic = parent.createFileAtomic(init.process.io, basename, .{
        .permissions = permissions,
        .replace = true,
    }) catch |err| return emitIoError(init, "cannot create format output", err);
    defer atomic.deinit(init.process.io);

    var output_buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(init.process.io, &output_buffer);
    writer.interface.writeAll(formatted) catch |err|
        return emitIoError(init, "cannot write format output", err);
    writer.interface.flush() catch |err|
        return emitIoError(init, "cannot write format output", err);
    atomic.file.sync(init.process.io) catch |err|
        return emitIoError(init, "cannot synchronize format output", err);

    const current = parent.statFile(
        init.process.io,
        basename,
        .{ .follow_symlinks = false },
    ) catch |err| return emitIoError(init, "cannot recheck format input", err);
    if (current.kind != .file) return formatTargetNotRegular(init, path);
    atomic.replace(init.process.io) catch |err|
        return emitIoError(init, "cannot publish format output", err);
    return 0;
}
fn executeSource(
    init: Startup,
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
    init: Startup,
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
    init: Startup,
    source_name: []const u8,
    source: []const u8,
    arguments: []const []const u8,
    print_stack: bool,
    standard_input: ecl.machine.StandardInput.Availability,
    worker_count: usize,
    project_root: ?[]const u8,
    package_grant: ?ecl.package_authority.PackageGrant,
) AppError!u8 {
    // SAFETY: init fills borrowed storage and the Session before use; only a
    // successful init installs the teardown defer, and cli stays at this address.
    var cli: CliRuntime = undefined;
    try cli.init(init, arguments, worker_count, standard_input, if (package_grant) |grant| .{ .package = grant } else .evaluate, project_root);
    defer cli.deinit();
    const session = &cli.session;
    const outcome = try session.runUnit(source_name, source);
    if (session.requestedExit()) |status| return status;
    switch (outcome) {
        .ok => {
            if (print_stack) try printStack(session);
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
            try printSessionError(init, session, error_value);
            return 1;
        },
    }
}
fn repl(init: Startup, worker_count: usize) AppError!u8 {
    // SAFETY: init fills borrowed storage and the Session before use; only a
    // successful init installs the teardown defer, and cli stays at this address.
    var cli: CliRuntime = undefined;
    try cli.init(init, &.{}, worker_count, .program_source, .evaluate, null);
    defer cli.deinit();
    const session = &cli.session;
    const history_path = if (init.process.environ_map.get("HOME")) |home|
        std.Io.Dir.path.join(init.process.gpa, &.{ home, ".ecl_history" }) catch
            return error.OutOfMemory
    else
        null;
    defer if (history_path) |path| init.process.gpa.free(path);
    var editor = try ecl.line_editor.Editor.init(init.process.gpa, init.process.io, history_path);
    defer editor.deinit();
    var pending = try ecl.reader.PendingUnit.init(init.process.gpa);
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
                return emitIncompleteAtEof(init, session, pending.source());
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
                try printStack(session);
                pending.clear();
            },
            .err => |error_value| {
                defer session.release(error_value);
                try printSessionError(init, session, error_value);
                pending.clear();
            },
        }
    }
}
fn emitIncompleteAtEof(
    init: Startup,
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
    init: Startup,
    kind: ecl.machine.ErrorKind,
    message: []const u8,
    location: ?ecl.spans.LocatedSpan,
) AppError!u8 {
    var host = ecl.heap.HostOwner.init(init.process.gpa);
    const releases = host.domain();
    defer host.cleanup().drain();
    var language_error = ecl.machine.EclErr.init(kind, message);
    defer language_error.retire(releases);
    const error_value = try ecl.machine.errorValue(
        init.process.gpa,
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
    init: Startup,
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
fn printError(init: Startup, error_value: ecl.value.Value) AppError!void {
    const rendered = try ecl.print.toOwnedString(init.process.gpa, error_value);
    defer init.process.gpa.free(rendered);
    try writeFile(init.process.io, .stderr, rendered);
    try writeFile(init.process.io, .stderr, "\n");
}
fn printSessionError(
    init: Startup,
    session: *ecl.session.Session,
    error_value: ecl.value.Value,
) AppError!void {
    const rendered = try ecl.print.toOwnedString(init.process.gpa, error_value);
    defer init.process.gpa.free(rendered);
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
