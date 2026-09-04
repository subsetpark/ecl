//! Build-time conventions for checked-in ECL sources.
//!
//! Two rules, both about text the repository treats as a contract rather than
//! as implementation detail. Neither is expressible in the type system, and
//! neither belongs in a runtime test: the first is about a documented artifact
//! format, the second about a source spelling that has no observable behavior
//! of its own.
//!
//! Both walk directories rather than lists, so a new module or fixture cannot
//! evade them.
const std = @import("std");
const ecl = @import("ecl-internal");

/// Every checked-in ECL source, wherever it lives, is canonically formatted.
const format_roots = [_][]const u8{ "src", "test" };

/// The parser fixture is deliberately invalid input, so it has no canonical
/// form and the formatter is expected to reject it.
const format_exempt = [_][]const u8{"acceptance/load-parse-error.ecl"};

/// Every source under here is an embedded standard-library module, and a
/// module definition's terminal form is `@defm`.
const module_root = "src/stdlib";

const registration_word = "@defm";

pub fn main(init: std.process.Init) !void {
    var failed = false;
    failed = try checkFormatting(init) or failed;
    failed = try checkModuleRegistration(init) or failed;
    if (failed) return error.EclSourceCheckFailed;
}

/// `ecl fmt` output is a documented artifact contract, so a checked-in source
/// that is not already its own formatter output is a defect: the next person to
/// run the formatter gets an unrelated diff.
fn checkFormatting(init: std.process.Init) !bool {
    var failed = false;
    var checked: usize = 0;
    for (format_roots) |root| {
        var directory = std.Io.Dir.cwd().openDir(init.io, root, .{ .iterate = true }) catch |err| {
            std.log.err("ecl sources: cannot open {s}: {s}", .{ root, @errorName(err) });
            return error.EclSourceCheckFailed;
        };
        defer directory.close(init.io);
        var walker = try directory.walk(init.gpa);
        defer walker.deinit();
        while (try walker.next(init.io)) |entry| {
            if (!isEclSource(entry)) continue;
            if (isExempt(&format_exempt, entry.path)) continue;
            const source = readSource(init, directory, root, entry.path) catch {
                failed = true;
                continue;
            };
            defer init.gpa.free(source);
            const formatted = ecl.formatter.format(init.gpa, source) catch |err| {
                std.log.err("ecl sources: cannot format {s}/{s}: {s}", .{
                    root, entry.path, @errorName(err),
                });
                failed = true;
                continue;
            };
            defer init.gpa.free(formatted);
            checked += 1;
            if (std.mem.eql(u8, source, formatted)) continue;
            std.log.err("ecl sources: {s}/{s} is not canonically formatted; run `ecl fmt`", .{
                root, entry.path,
            });
            failed = true;
        }
    }
    if (checked == 0) {
        std.log.err("ecl sources: no ECL sources were found", .{});
        return error.EclSourceCheckFailed;
    }
    std.log.info("ecl sources: {d} sources are canonically formatted", .{checked});
    return failed;
}

/// A standard module's terminal form must use the single `@defm` form.
/// The two are observably equivalent, so nothing at runtime can hold this rule;
/// what it buys is one spelling for one thing across the checked-in corpus, and
/// a navigable `### module` header, which the formatter synthesizes only for the
/// combined form.
///
/// The check reads the real parser's top-level forms rather than matching
/// bytes. A suffix match would accept `@module` followed by a `# @defm`
/// comment, or a multiline string whose last line happens to end that way.
fn checkModuleRegistration(init: std.process.Init) !bool {
    var failed = false;
    var checked: usize = 0;
    var directory = std.Io.Dir.cwd().openDir(init.io, module_root, .{ .iterate = true }) catch |err| {
        std.log.err("standard modules: cannot open {s}: {s}", .{ module_root, @errorName(err) });
        return error.EclSourceCheckFailed;
    };
    defer directory.close(init.io);
    var walker = try directory.walk(init.gpa);
    defer walker.deinit();
    while (try walker.next(init.io)) |entry| {
        if (!isEclSource(entry)) continue;
        const source = readSource(init, directory, module_root, entry.path) catch {
            failed = true;
            continue;
        };
        defer init.gpa.free(source);
        checked += 1;
        if (try terminalWord(init, module_root, entry.path, source)) |word| {
            if (std.mem.eql(u8, word, registration_word)) continue;
            std.log.err(
                "standard modules: {s}/{s} ends in `{s}`; a module definition ends in `{s}`",
                .{ module_root, entry.path, word, registration_word },
            );
        } else {
            std.log.err(
                "standard modules: {s}/{s} does not end in an executable word; expected `{s}`",
                .{ module_root, entry.path, registration_word },
            );
        }
        failed = true;
    }
    if (checked == 0) {
        std.log.err("standard modules: no module sources were found", .{});
        return error.EclSourceCheckFailed;
    }
    std.log.info("standard modules: {d} registrations verified", .{checked});
    return failed;
}

/// The spelling of the source's last top-level form when that form is a word,
/// and null for anything else — including a source the reader rejects, which is
/// itself a failure for a module.
fn terminalWord(
    init: std.process.Init,
    root: []const u8,
    path: []const u8,
    source: []const u8,
) !?[]const u8 {
    var host = ecl.heap.HostOwner.init(init.gpa);
    defer host.cleanup().drain();
    var diag: ecl.reader.Diag = .{};
    var parsed = switch (ecl.reader.read(host.cleanup(), path, source, &diag) catch |err| {
        std.log.err("standard modules: cannot read {s}/{s}: {s}", .{ root, path, @errorName(err) });
        return null;
    }) {
        .complete => |complete| complete,
        .incomplete => {
            std.log.err("standard modules: {s}/{s} is an incomplete unit", .{ root, path });
            return null;
        },
    };
    defer parsed.deinit();
    const forms = parsed.values();
    if (forms.len == 0) return null;
    const last = forms[forms.len - 1];
    if (last != .word) return null;
    return ecl.intern.get(last.word.name);
}

fn isEclSource(entry: std.Io.Dir.Walker.Entry) bool {
    return entry.kind == .file and std.mem.endsWith(u8, entry.path, ".ecl");
}

fn isExempt(exempt: []const []const u8, path: []const u8) bool {
    for (exempt) |name| {
        if (std.mem.eql(u8, path, name)) return true;
    }
    return false;
}

fn readSource(
    init: std.process.Init,
    directory: std.Io.Dir,
    root: []const u8,
    path: []const u8,
) ![]u8 {
    return directory.readFileAlloc(init.io, path, init.gpa, .limited(1 << 24)) catch |err| {
        std.log.err("ecl sources: cannot read {s}/{s}: {s}", .{ root, path, @errorName(err) });
        return error.EclSourceCheckFailed;
    };
}
