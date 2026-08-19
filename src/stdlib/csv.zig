// zlint-disable homeless-try -- zlint 0.9.1 does not resolve the SDK's aliased error union; Zig validates every callback signature.
//! The first-party `csv` module, authored against the public `ecl-native` SDK.
//!
//! Parsing is RFC 4180 with the frozen text-preserving policy: CRLF or LF
//! record endings, quoted commas and newlines, doubled-quote escapes, and
//! every field returned as a string. No header interpretation, no delimiter
//! sniffing, no scalar inference.
//!
//! The shape of this file is dictated by two SDK contracts. Continuation
//! state is fixed-size POD, so nothing about a field can be buffered across a
//! yield; and aggregate builders are exact-size, so a field's length must be
//! known before its first character is appended. Both are satisfied by
//! keeping only *positions* between turns and re-deriving every count by
//! rescanning from a position. Each rescan is bounded by the record or field
//! it measures, so the whole parse stays linear in the input.
const std = @import("std");
const ecl = @import("ecl-native");

pub const Extension = ecl.module(.{
    .name = "csv",
    // Linked into this image rather than loaded from one, so the ABI entry
    // symbol stays free for a real extension.
    .linkage = .static,
    .doc = "RFC 4180 comma-separated values, preserved as text.",
    .words = .{
        ecl.word(
            "parse",
            "Parse RFC 4180 text into a list of records whose fields are all strings.",
            parse,
        ),
        ecl.word(
            "emit",
            "Render records of string fields as canonical CRLF-terminated RFC 4180 text.",
            emit,
        ),
    },
});

/// Where a field stopped. The distinction survives into the record loop: a
/// comma means another field follows, and a record terminator means another
/// record does.
const Stop = enum(u8) { comma, record, input_end };

/// The quoting state machine's position within one field.
const Mode = enum(u8) {
    /// No character of the field has been read yet.
    start,
    /// Reading an unquoted field.
    bare,
    /// Reading the body of a quoted field.
    quoted,
    /// A quote was seen inside a quoted field; the next character decides
    /// whether it escaped a quote or closed the field.
    quote_seen,
    /// A carriage return was consumed outside a quoted field. RFC 4180 ends
    /// records with CRLF, so only a newline or end of input may follow.
    /// Keeping this in the state means a yield can land mid-terminator.
    cr_seen,
};

/// Builder slots. Nesting is three deep and each level is finished before its
/// parent advances, so three fixed slots suffice: finishing a child hands its
/// candidate to the parent, which releases the child's slot for reuse.
const rows_slot: u32 = 0;
const row_slot: u32 = 1;
const field_slot: u32 = 2;

const Phase = enum(u8) {
    /// Scan the whole input, counting records.
    count_records,
    /// Scan one record, counting its fields.
    count_fields,
    /// Scan one field, counting its decoded characters.
    measure_field,
    /// Rescan the same field, appending its decoded characters.
    fill_field,
    /// Finish the field builder and append it to the record.
    close_field,
    /// Finish the record builder and append it to the row list.
    close_record,
    /// Finish the row list and complete the call.
    finish,
};

const ParseWork = struct {
    pub const State = struct {
        phase: Phase,
        mode: Mode,
        /// Codepoint index the active scan reads next.
        scan: u64,
        /// First codepoint of the record being measured or built.
        record_start: u64,
        /// First codepoint of the field being measured or built.
        field_start: u64,
        records: u64,
        record_index: u64,
        fields: u64,
        field_index: u64,
        characters: u64,
        character_index: u64,
        /// A character taken from the input whose append has not yet been
        /// accepted. Scanning cannot be rewound — a doubled quote consumes two
        /// input characters for one output character — so the character waits
        /// here across a builder yield instead.
        pending: u32,
        has_pending: bool,
    };
    pub fn init() State {
        return .{
            .phase = .count_records,
            .mode = .start,
            .scan = 0,
            .record_start = 0,
            .field_start = 0,
            .records = 0,
            .record_index = 0,
            .fields = 0,
            .field_index = 0,
            .characters = 0,
            .character_index = 0,
            .pending = 0,
            .has_pending = false,
        };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const ParseSchedule = ecl.Reschedule(ParseWork);

/// One step of the field scanner.
const Step = union(enum) {
    /// A decoded content character of the current field.
    character: u32,
    /// The field ended; `mode` is left at `.start` for the next field.
    stop: Stop,
    /// The budget ran out mid-field; the caller must yield.
    exhausted,
    /// The input is not the list the cursor needs.
    invalid,
    /// The quoting is malformed at `state.scan`.
    malformed,
};

/// Advances the scanner by one input character, which is where the budget is
/// charged. `state.scan` and `state.mode` together are the whole resumable
/// position, so a yield here loses nothing — including a yield that lands
/// between the two halves of a CRLF.
fn step(cursor: *ecl.ListCursor, state: *ParseWork.State, length: u64) Step {
    while (true) {
        if (state.scan == length) return switch (state.mode) {
            // An unterminated quoted field is the one malformed input RFC
            // 4180 leaves no room to interpret.
            .quoted => .malformed,
            .start, .bare, .quote_seen, .cr_seen => stop: {
                state.mode = .start;
                break :stop .{ .stop = .input_end };
            },
        };
        const view = switch (cursor.next()) {
            .item => |item| item,
            .end => return .{ .stop = .input_end },
            .yield_required => return .exhausted,
            .invalid => return .invalid,
        };
        const codepoint = view.char() orelse return .invalid;
        state.scan += 1;
        switch (state.mode) {
            .start => switch (codepoint) {
                '"' => state.mode = .quoted,
                ',' => return .{ .stop = .comma },
                '\n' => return .{ .stop = .record },
                '\r' => state.mode = .cr_seen,
                else => {
                    state.mode = .bare;
                    return .{ .character = codepoint };
                },
            },
            .bare => switch (codepoint) {
                // A quote may only open a field, never appear inside a bare
                // one; RFC 4180 requires such a field to be quoted.
                '"' => return .malformed,
                ',' => {
                    state.mode = .start;
                    return .{ .stop = .comma };
                },
                '\n' => {
                    state.mode = .start;
                    return .{ .stop = .record };
                },
                '\r' => state.mode = .cr_seen,
                else => return .{ .character = codepoint },
            },
            .quoted => switch (codepoint) {
                '"' => state.mode = .quote_seen,
                // A quoted field may hold commas, quotes, and newlines alike.
                else => return .{ .character = codepoint },
            },
            .quote_seen => switch (codepoint) {
                // A doubled quote is one literal quote.
                '"' => {
                    state.mode = .quoted;
                    return .{ .character = '"' };
                },
                ',' => {
                    state.mode = .start;
                    return .{ .stop = .comma };
                },
                '\n' => {
                    state.mode = .start;
                    return .{ .stop = .record };
                },
                '\r' => state.mode = .cr_seen,
                else => return .malformed,
            },
            .cr_seen => switch (codepoint) {
                '\n' => {
                    state.mode = .start;
                    return .{ .stop = .record };
                },
                // A carriage return that terminates nothing is malformed
                // rather than silently becoming data.
                else => return .malformed,
            },
        }
    }
}

fn parse(
    call: *ecl.Call("text -- rows"),
    build: *ecl.BuildValues,
    schedule: *ParseSchedule,
) ecl.CallbackResult {
    const view = call.input(0);
    const length = view.aggregateLength() orelse
        return call.fail(.type, "csv.parse expects a string");
    const state = schedule.state();
    while (true) {
        switch (state.phase) {
            // Slot 0's item count must be exact before the first record is
            // appended, so the record total is measured by its own pass.
            .count_records => {
                if (length == 0) {
                    state.records = 0;
                    state.phase = .finish;
                    continue;
                }
                const cursor = call.listCursor(0, state.scan) orelse
                    return call.fail(.type, "csv.parse expects a string");
                switch (step(cursor, state, length)) {
                    .malformed => return malformed(call, state),
                    .invalid => return call.fail(.shape, "csv.parse cursor became invalid"),
                    .exhausted => return schedule.yield(),
                    .character => {},
                    .stop => |stop| switch (stop) {
                        .comma => {},
                        .record => {
                            state.records += 1;
                            state.record_start = state.scan;
                        },
                        // A trailing terminator opens no record, which is
                        // exactly the case where the scan sits at the record
                        // start it just set.
                        .input_end => {
                            if (state.scan != state.record_start) state.records += 1;
                            state.scan = 0;
                            state.record_start = 0;
                            state.mode = .start;
                            state.phase = .count_fields;
                        },
                    },
                }
            },
            .count_fields => {
                const cursor = call.listCursor(0, state.scan) orelse
                    return call.fail(.type, "csv.parse expects a string");
                switch (step(cursor, state, length)) {
                    .malformed => return malformed(call, state),
                    .invalid => return call.fail(.shape, "csv.parse cursor became invalid"),
                    .exhausted => return schedule.yield(),
                    .character => {},
                    .stop => |stop| {
                        state.fields += 1;
                        switch (stop) {
                            .comma => {},
                            .record, .input_end => {
                                state.scan = state.record_start;
                                state.field_start = state.record_start;
                                state.field_index = 0;
                                state.characters = 0;
                                state.mode = .start;
                                state.phase = .measure_field;
                            },
                        }
                    },
                }
            },
            .measure_field => {
                const cursor = call.listCursor(0, state.scan) orelse
                    return call.fail(.type, "csv.parse expects a string");
                switch (step(cursor, state, length)) {
                    .malformed => return malformed(call, state),
                    .invalid => return call.fail(.shape, "csv.parse cursor became invalid"),
                    .exhausted => return schedule.yield(),
                    .character => state.characters += 1,
                    .stop => {
                        state.scan = state.field_start;
                        state.character_index = 0;
                        state.mode = .start;
                        state.phase = .fill_field;
                    },
                }
            },
            // The fill runs to the field's terminator rather than to its
            // character count, so `scan` lands past the separator and the
            // next field starts where it should.
            .fill_field => {
                if (state.has_pending) {
                    const item = try build.scalar(ecl.Scalar.char(state.pending));
                    switch (try build.appendList(field_slot, state.characters, item)) {
                        .appended => {
                            state.has_pending = false;
                            state.character_index += 1;
                        },
                        .yield_required => return schedule.yield(),
                        .invalid => return call.fail(.domain, "csv.parse field builder was rejected"),
                    }
                    continue;
                }
                const cursor = call.listCursor(0, state.scan) orelse
                    return call.fail(.type, "csv.parse expects a string");
                switch (step(cursor, state, length)) {
                    .malformed => return malformed(call, state),
                    .invalid => return call.fail(.shape, "csv.parse cursor became invalid"),
                    .exhausted => return schedule.yield(),
                    .stop => state.phase = .close_field,
                    .character => |codepoint| {
                        if (state.character_index == state.characters)
                            return call.fail(.shape, "csv.parse field length changed");
                        state.pending = codepoint;
                        state.has_pending = true;
                    },
                }
            },
            .close_field => {
                if (state.character_index != state.characters)
                    return call.fail(.shape, "csv.parse field length changed");
                const field = switch (try build.finishList(field_slot, state.characters)) {
                    .candidate => |candidate| candidate,
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv.parse field builder was rejected"),
                };
                switch (try build.appendList(row_slot, state.fields, field)) {
                    .appended => {},
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv.parse record builder was rejected"),
                }
                state.field_index += 1;
                // The scan already sits just past this field's terminator.
                state.field_start = state.scan;
                state.characters = 0;
                state.character_index = 0;
                state.mode = .start;
                state.phase = if (state.field_index == state.fields) .close_record else .measure_field;
            },
            .close_record => {
                const record = switch (try build.finishList(row_slot, state.fields)) {
                    .candidate => |candidate| candidate,
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv.parse record builder was rejected"),
                };
                switch (try build.appendList(rows_slot, state.records, record)) {
                    .appended => {},
                    .yield_required => return schedule.yield(),
                    .invalid => return call.fail(.domain, "csv.parse row builder was rejected"),
                }
                state.record_index += 1;
                if (state.record_index == state.records) {
                    state.phase = .finish;
                    continue;
                }
                state.record_start = state.scan;
                state.field_start = state.scan;
                state.fields = 0;
                state.field_index = 0;
                state.mode = .start;
                state.phase = .count_fields;
            },
            .finish => return switch (try build.finishList(rows_slot, state.records)) {
                .candidate => |candidate| call.complete(.{candidate}),
                .yield_required => schedule.yield(),
                .invalid => call.fail(.domain, "csv.parse row builder was rejected"),
            },
        }
    }
}

fn malformed(call: anytype, state: *ParseWork.State) ecl.CallbackResult {
    var buffer: [96]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "csv.parse found malformed quoting at character {d}",
        .{state.scan},
    ) catch "csv.parse found malformed quoting";
    return call.fail(.parse, message);
}

/// Emission is the mirror of parsing and inherits the same two constraints:
/// the output character count must be exact before the first append, and
/// nothing about a field can be buffered across a yield. So the record set is
/// measured once — counting output characters, including the quotes and
/// doubling a quoted field needs — and then rendered from positions alone.
const EmitPhase = enum(u8) {
    /// Walk every field, validating shape and counting output characters.
    measure,
    /// Re-walk the same fields, appending each output character.
    render,
    /// Finish the output builder and complete the call.
    finish,
};

/// Where the renderer is inside one field. A quoted field emits an opening
/// quote, its body with quotes doubled, and a closing quote.
const FieldPart = enum(u8) {
    open_quote,
    body,
    doubled_quote,
    close_quote,
    comma,
    terminator_cr,
    terminator_lf,
};

const EmitWork = struct {
    pub const State = struct {
        phase: EmitPhase,
        part: FieldPart,
        /// Record and field being measured or rendered.
        record: u64,
        field: u64,
        /// Character position inside the current field's text.
        character: u64,
        /// Total output characters, and how many have been appended.
        characters: u64,
        emitted: u64,
        /// Whether the field being rendered requires quoting. Recomputed per
        /// field during the measure pass and again during the render pass.
        quoted: bool,
        /// Cached widths so the render pass does not re-derive them.
        record_count: u64,
        field_count: u64,
        text_length: u64,
    };
    pub fn init() State {
        return .{
            .phase = .measure,
            .part = .open_quote,
            .record = 0,
            .field = 0,
            .character = 0,
            .characters = 0,
            .emitted = 0,
            .quoted = false,
            .record_count = 0,
            .field_count = 0,
            .text_length = 0,
        };
    }
    pub fn deinit(state: *State) void {
        state.* = undefined;
    }
};
const EmitSchedule = ecl.Reschedule(EmitWork);

const output_slot: u32 = 0;

/// A field must be quoted exactly when it contains a comma, a quote, a
/// carriage return, or a newline. Anything else is emitted bare, which is what
/// keeps the canonical output byte-stable.
fn requiresQuoting(codepoint: u32) bool {
    return codepoint == ',' or codepoint == '"' or codepoint == '\r' or codepoint == '\n';
}

fn emit(
    call: *ecl.Call("rows -- text"),
    build: *ecl.BuildValues,
    schedule: *EmitSchedule,
) ecl.CallbackResult {
    const rows = call.input(0);
    if (rows.kind() != .list) return call.fail(.type, "csv.emit expects a list of records");
    const state = schedule.state();
    state.record_count = rows.aggregateLength().?;
    while (true) switch (state.phase) {
        .measure => {
            if (state.record == state.record_count) {
                state.characters = state.emitted;
                state.emitted = 0;
                state.record = 0;
                state.field = 0;
                state.character = 0;
                state.part = .open_quote;
                state.phase = .render;
                continue;
            }
            switch (try measureStep(call, state)) {
                .keep_going => {},
                .failed => |outcome| return outcome,
            }
        },
        .render => {
            if (state.emitted == state.characters) {
                state.phase = .finish;
                continue;
            }
            switch (try renderStep(call, build, state)) {
                .keep_going => {},
                .failed => |outcome| return outcome,
            }
        },
        .finish => return switch (try build.finishList(output_slot, state.characters)) {
            .candidate => |candidate| call.complete(.{candidate}),
            .yield_required => schedule.yield(),
            .invalid => call.fail(.domain, "csv.emit output builder was rejected"),
        },
    };
}

const StepOutcome = union(enum) {
    keep_going,
    failed: ecl.Outcome,
};

/// Reads one field's view, validating the record and field shape on the way.
/// Every rejection here happens before a single output character is built.
fn fieldView(
    call: *ecl.Call("rows -- text"),
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!union(enum) { view: *const ecl.ValueView, failed: ecl.Outcome } {
    const record = switch (call.nested(0, &.{ecl.Path.item(state.record)})) {
        .item => |item| item,
        .yield_required => return .{ .failed = .yield },
        .invalid => return .{ .failed = try call.fail(.shape, "csv.emit record is unreadable") },
    };
    if (record.kind() != .list)
        return .{ .failed = try call.fail(.type, "csv.emit expects every record to be a list") };
    const fields = record.aggregateLength().?;
    if (fields == 0)
        return .{ .failed = try call.fail(.shape, "csv.emit rejects a record with no fields") };
    state.field_count = fields;
    const field = switch (call.nested(0, &.{
        ecl.Path.item(state.record),
        ecl.Path.item(state.field),
    })) {
        .item => |item| item,
        .yield_required => return .{ .failed = .yield },
        .invalid => return .{ .failed = try call.fail(.shape, "csv.emit field is unreadable") },
    };
    if (field.kind() != .list)
        return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
    state.text_length = field.aggregateLength().?;
    return .{ .view = field };
}

fn measureStep(
    call: *ecl.Call("rows -- text"),
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!StepOutcome {
    switch (try fieldView(call, state)) {
        .failed => |outcome| return .{ .failed = outcome },
        .view => {},
    }
    // One whole field per step: its length is already known, so the scan is
    // bounded by the field and charged by the nested reads it makes.
    var quoted = false;
    var body: u64 = 0;
    var index: u64 = 0;
    while (index != state.text_length) : (index += 1) {
        const cell = switch (call.nested(0, &.{
            ecl.Path.item(state.record),
            ecl.Path.item(state.field),
            ecl.Path.item(index),
        })) {
            .item => |item| item,
            .yield_required => return .{ .failed = .yield },
            .invalid => return .{ .failed = try call.fail(.shape, "csv.emit cell is unreadable") },
        };
        const codepoint = cell.char() orelse
            return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
        if (requiresQuoting(codepoint)) quoted = true;
        body += if (codepoint == '"') 2 else 1;
    }
    state.emitted += if (quoted) body + 2 else body;
    // A comma between fields, CRLF after the last one.
    state.emitted += if (state.field + 1 == state.field_count) 2 else 1;
    state.field += 1;
    if (state.field == state.field_count) {
        state.field = 0;
        state.record += 1;
    }
    return .keep_going;
}

fn renderStep(
    call: *ecl.Call("rows -- text"),
    build: *ecl.BuildValues,
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!StepOutcome {
    // Field widths and the quoting decision are cached in state, so only the
    // first step of a field pays for reading them back.
    if (state.part == .open_quote) {
        switch (try fieldView(call, state)) {
            .failed => |outcome| return .{ .failed = outcome },
            .view => {},
        }
        switch (try quotingRequired(call, state)) {
            .failed => |outcome| return .{ .failed = outcome },
            .required => |required| state.quoted = required,
        }
        state.part = .body;
        if (state.quoted) return append(build, state, '"');
    }
    switch (state.part) {
        .open_quote => unreachable,
        .body, .doubled_quote => {
            if (state.character == state.text_length) {
                state.part = .close_quote;
                return .keep_going;
            }
            const cell = switch (call.nested(0, &.{
                ecl.Path.item(state.record),
                ecl.Path.item(state.field),
                ecl.Path.item(state.character),
            })) {
                .item => |item| item,
                .yield_required => return .{ .failed = .yield },
                .invalid => return .{ .failed = try call.fail(.shape, "csv.emit cell is unreadable") },
            };
            const codepoint = cell.char() orelse
                return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
            const doubling = codepoint == '"' and state.part == .body;
            const outcome = try append(build, state, codepoint);
            if (outcome == .failed) return outcome;
            // A quote inside a quoted field is written twice, which is two
            // separate appends so a yield between them repeats neither.
            if (doubling) {
                state.part = .doubled_quote;
                return .keep_going;
            }
            state.part = .body;
            state.character += 1;
        },
        .close_quote => {
            state.part = if (state.field + 1 == state.field_count) .terminator_cr else .comma;
            if (state.quoted) return append(build, state, '"');
        },
        .comma => {
            const outcome = try append(build, state, ',');
            if (outcome == .failed) return outcome;
            advanceField(state);
        },
        .terminator_cr => {
            const outcome = try append(build, state, '\r');
            if (outcome == .failed) return outcome;
            state.part = .terminator_lf;
        },
        .terminator_lf => {
            const outcome = try append(build, state, '\n');
            if (outcome == .failed) return outcome;
            advanceField(state);
        },
    }
    return .keep_going;
}

fn advanceField(state: *EmitWork.State) void {
    state.character = 0;
    state.part = .open_quote;
    state.field += 1;
    if (state.field == state.field_count) {
        state.field = 0;
        state.record += 1;
    }
}

/// A field must be quoted exactly when it contains a comma, a quote, a
/// carriage return, or a newline. Both passes derive this the same way, which
/// is what keeps the measured length and the rendered length equal.
fn quotingRequired(
    call: *ecl.Call("rows -- text"),
    state: *EmitWork.State,
) error{ OutOfMemory, InvalidValue }!union(enum) { required: bool, failed: ecl.Outcome } {
    var index: u64 = 0;
    while (index != state.text_length) : (index += 1) {
        const cell = switch (call.nested(0, &.{
            ecl.Path.item(state.record),
            ecl.Path.item(state.field),
            ecl.Path.item(index),
        })) {
            .item => |item| item,
            .yield_required => return .{ .failed = .yield },
            .invalid => return .{ .failed = try call.fail(.shape, "csv.emit cell is unreadable") },
        };
        const codepoint = cell.char() orelse
            return .{ .failed = try call.fail(.type, "csv.emit expects every field to be a string") };
        if (requiresQuoting(codepoint)) return .{ .required = true };
    }
    return .{ .required = false };
}

fn append(
    build: *ecl.BuildValues,
    state: *EmitWork.State,
    codepoint: u32,
) error{ OutOfMemory, InvalidValue }!StepOutcome {
    const item = try build.scalar(ecl.Scalar.char(codepoint));
    return switch (try build.appendList(output_slot, state.characters, item)) {
        .appended => appended: {
            state.emitted += 1;
            break :appended .keep_going;
        },
        .yield_required => .{ .failed = .yield },
        .invalid => .{ .failed = .fail },
    };
}
