const abi = @import("native-abi");
const options = @import("malformed_options");

const empty_slots = [_]abi.EffectSlot{};
const invalid_effect_slots = [_]abi.EffectSlot{.{ .name_ptr = "".ptr, .name_len = 0 }};
const output_slots = [_]abi.EffectSlot{
    .{ .name_ptr = "left".ptr, .name_len = "left".len },
    .{ .name_ptr = "right".ptr, .name_len = "right".len },
};
const word_name = "word";
const word_doc = "Malformed fixture word.";
const duplicate_doc = "Duplicate malformed fixture word.";
const module_doc = "Malformed native fixture.";
const requested_name = "sample";
const wrong_name = "different";

fn invoke(
    host: *const abi.HostTable,
    context: *anyopaque,
    _: u32,
    output: *abi.InvokeResult,
) callconv(.c) void {
    if (is("result-size")) {
        output.* = .{ .size = 0, .tag = .fail };
        return;
    }
    if (is("unknown-result")) {
        output.* = .{ .tag = @enumFromInt(99), .adapter_status = 0 };
        return;
    }
    if (is("unknown-failure-kind")) {
        _ = host.fail(context, @enumFromInt(99), "bad kind".ptr, "bad kind".len);
        output.* = .{ .tag = .fail, .adapter_status = 0 };
        return;
    }
    if (is("unknown-scalar-kind") or is("oversized-scalar") or
        is("invalid-utf8-scalar") or is("scalar-size"))
    {
        const invalid_utf8 = [_]u8{0xff};
        var candidate: abi.Candidate = 0;
        var scalar = abi.Scalar{
            .size = if (is("scalar-size")) 0 else @sizeOf(abi.Scalar),
            .kind = if (is("unknown-scalar-kind")) @enumFromInt(99) else .symbol,
            .bytes_ptr = if (is("invalid-utf8-scalar")) &invalid_utf8 else "x".ptr,
            .bytes_len = if (is("oversized-scalar")) abi.max_guest_scalar_bytes + 1 else 1,
        };
        _ = host.scalar(context, &scalar, &candidate);
        output.* = .{ .tag = .fail, .adapter_status = 0 };
        return;
    }
    if (is("partial-complete")) {
        var candidate: abi.Candidate = 0;
        var scalar = abi.Scalar{ .kind = .int, .bits = 1 };
        _ = host.scalar(context, &scalar, &candidate);
        const invalid = [_]abi.Candidate{ candidate, 0 };
        _ = host.complete(context, &invalid, invalid.len);
        const valid = [_]abi.Candidate{ candidate, candidate };
        _ = host.complete(context, &valid, valid.len);
        output.* = .{ .tag = .complete, .adapter_status = 0 };
        return;
    }
    if (is("undeclared-yield")) {
        if (host.consume != null) {
            _ = host.consume.?(context, 1);
            output.* = .{ .tag = .yield, .adapter_status = 0 };
        } else {
            _ = host.fail(
                context,
                .user,
                "reschedule capability unavailable".ptr,
                "reschedule capability unavailable".len,
            );
            output.* = .{ .tag = .fail, .adapter_status = 0 };
        }
        return;
    }
    if (is("consume-without-state")) {
        const status = host.consume.?(context, 1);
        const message = if (status == .invalid)
            "consume rejected without continuation"
        else
            "consume accepted without continuation";
        _ = host.fail(context, .user, message.ptr, message.len);
        output.* = .{ .tag = .fail, .adapter_status = 0 };
        return;
    }
    output.* = .{ .tag = .fail };
}

const definitions = [_]abi.Definition{
    .{
        .callback_index = 0,
        .name_ptr = word_name.ptr,
        .name_len = word_name.len,
        .doc_ptr = word_doc.ptr,
        .doc_len = if (is("missing-doc")) 0 else word_doc.len,
        .input_count = if (is("invalid-effect")) 1 else 0,
        .inputs_ptr = if (is("invalid-effect")) &invalid_effect_slots else &empty_slots,
        .output_count = if (is("partial-complete")) output_slots.len else 0,
        .outputs_ptr = if (is("partial-complete")) &output_slots else &empty_slots,
        .continuation_size = if (is("invalid-continuation")) 8 else 0,
    },
    .{
        .callback_index = 0,
        .name_ptr = word_name.ptr,
        .name_len = word_name.len,
        .doc_ptr = duplicate_doc.ptr,
        .doc_len = duplicate_doc.len,
        .input_count = 0,
        .inputs_ptr = &empty_slots,
        .output_count = 0,
        .outputs_ptr = &empty_slots,
    },
};

const requirements = [_]abi.CapabilityRequirement{
    .{
        .id = if (is("unsupported-capability"))
            99
        else
            @intFromEnum(abi.CapabilityId.call),
    },
    .{ .id = @intFromEnum(abi.CapabilityId.reschedule) },
};

const descriptor = abi.Descriptor{
    .size = if (is("descriptor-size")) @sizeOf(abi.Descriptor) - 8 else @sizeOf(abi.Descriptor),
    .abi_version = if (is("abi-version")) abi.abi_version + 1 else abi.abi_version,
    .module_name_ptr = if (is("wrong-name")) wrong_name.ptr else requested_name.ptr,
    .module_name_len = if (is("wrong-name")) wrong_name.len else requested_name.len,
    .module_doc_ptr = module_doc.ptr,
    .module_doc_len = module_doc.len,
    .definition_count = if (is("duplicate-word")) 2 else 1,
    .definition_record_size = if (is("stride-overread")) @sizeOf(abi.Definition) - 8 else @sizeOf(abi.Definition),
    .definitions_ptr = &definitions,
    .capability_count = if (is("consume-without-state")) requirements.len else 1,
    .capabilities_ptr = &requirements,
    .callback_count = 1,
    .invoke = invoke,
};

export fn ecl_module_abi_v2(output: *abi.EntryResult) callconv(.c) void {
    if (is("entry-size")) {
        output.* = .{ .size = 0, .status = .descriptor, .descriptor = &descriptor };
        return;
    }
    if (is("entry-failure") or is("unknown-entry-status")) {
        const message = "fixture entry point failure";
        output.* = .{
            .status = if (is("unknown-entry-status")) @enumFromInt(99) else .fail,
            .message_ptr = message.ptr,
            .message_len = message.len,
        };
    } else {
        output.* = .{ .status = .descriptor, .descriptor = &descriptor };
    }
}

fn is(comptime expected: []const u8) bool {
    return @import("std").mem.eql(u8, options.defect, expected);
}
