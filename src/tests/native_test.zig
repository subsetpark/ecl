const std = @import("std");
const abi = @import("native-abi");
const descriptor_api = @import("../native_descriptor.zig");
const env = @import("../env.zig");
const heap = @import("../heap.zig");
const intern = @import("../intern.zig");
const list = @import("../list.zig");
const modules = @import("../modules.zig");
const native_module = @import("../native_module.zig");
const session = @import("../session.zig");
const native_sample = @import("native-sample");
const native_fixture = @import("native_fixture_options");
const ecl = @import("ecl-native");

fn expectPortProgram(workers: u32, max_operations: u32, source: []const u8, expected: []const u8) !void {
    try expectPortProgramAtCapacity(workers, max_operations, 8, source, expected);
}

fn expectPortProgramAtCapacity(workers: u32, max_operations: u32, capacity: u32, source: []const u8, expected: []const u8) !void {
    return expectPortProgramWithLimits(workers, .{ .ring_capacity = capacity, .max_operations = max_operations }, source, expected);
}

fn expectPortProgramWithLimits(workers: u32, limits: @import("../native_port.zig").Limits, source: []const u8, expected: []const u8) !void {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHostConfig(std.testing.allocator, &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = native_fixture.directory,
        .native_port_limits = limits,
    }, .{ .worker_pool = workers });
    defer runtime.deinit();
    try expectOk(&runtime, "'task ('await 'cancel) import portprobe.reset");
    try expectOk(&runtime, source);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings(expected, display.bytes());
}

test "native: message endpoints preserve empty values boundaries and stable eof" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.factory [] port.open 'p set p portprobe.messages [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint 's set x portprobe.receiver port.endpoint 'r set " ++
        "s [] port.send r port.receive dup 'kind at swap 'value at len " ++
        "s {'address [127 0 0 1] 'port 42 'payload [0 255]} port.send " ++
        "r port.receive 'value at {'address [127 0 0 1] 'port 42 'payload [0 255]} match? " ++
        "s port.finish s port.finish r port.receive 'kind at r port.receive 'kind at " ++
        "x port.await x port.close p port.close portprobe.cleaned", "'message 0 1 'eof 'eof 1");
}

test "native: messages retain budget credit while the controller forwards them" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.messages [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint wrap ('s set s 1 port.send s 2 port.send s 3 port.send s port.finish) @spawn 'producer set " ++
        "x portprobe.receiver port.endpoint 'r set r port.receive 'value at r port.receive 'value at r port.receive 'value at " ++
        "r port.receive 'kind at producer task.await 'ok at pop x port.await x port.close p port.close portprobe.cleaned", "1 2 3 'eof 1");
}

test "native: structured terminal results preserve capabilities and are claimed once" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.message-result [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint p 42 pair port.send x port.await " ++
        "x port.result dup first p match? swap 1 at " ++
        "x wrap (port.result) @attempt 'err at 'kind at x port.await x port.close p port.close portprobe.cleaned", "1 42 'contract 1");
}

test "native: buffered messages precede terminal failure" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.message-failure [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint [] port.send x wrap (port.await) @attempt 'err at 'kind at " ++
        "x portprobe.receiver port.endpoint 'r set r port.receive 'value at len " ++
        "r wrap (port.receive) @attempt 'err at 'kind at x port.close p port.close portprobe.cleaned", "'domain 0 'domain 1");
}

test "native: message validation and endpoint attenuation fail without partial delivery" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.messages [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint 's set x portprobe.receiver port.endpoint 'r set " ++
        "s wrap ([1 2] port.send) @attempt 'err at 'kind at " ++
        "s wrap ((dup) port.send) @attempt 'err at 'kind at " ++
        "s wrap (port.receive) @attempt 'err at 'kind at " ++
        "r wrap ([] port.send) @attempt 'err at 'kind at " ++
        "s 7 port.send r port.receive 'value at s port.finish x port.await x port.close p port.close portprobe.cleaned", "'overflow 'type 'type 'type 7 1");
}

test "native: competing message receivers reject overlap and cancellation restores the lane" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.messages [] port.begin 'x set " ++
        "x portprobe.receiver port.endpoint 'r set r wrap (port.receive) @spawn 'a set r wrap (port.receive) @spawn 'b set " ++
        "a b pair task.await-any 'err at 'kind at swap pop x port.cancel " ++
        "a task.await pop b task.await pop x port.close p portprobe.noop [] port.call pop p port.close portprobe.cleaned", "'contract 1");
}

test "native: cancellation interrupts message producers under shared budget pressure" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.messages [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint wrap ('s set [7] 64 take (s swap port.send) for) @spawn 'producer set " ++
        "x portprobe.receiver port.endpoint port.receive 'value at x port.cancel " ++
        "producer task.await 'err at 'kind at x port.close p port.close portprobe.cleaned", "7 'cancelled 1");
}

test "native: abortive cleanup breaks queued and terminal exchange capability cycles" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.messages [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint dup x port.send port.finish x port.await x port.close " ++
        "p portprobe.message-result [] port.begin 'y set y portprobe.sender port.endpoint y port.send y port.await y port.close " ++
        "x type y type p port.close portprobe.cleaned", "'port 'port 1");
}

test "native: message exchanges transfer scope ownership and clean up exactly once" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.messages [] port.begin 'x set " ++
        "p x pair [] (pop pop) @give task.await 'ok at len x type p type portprobe.cleaned", "0 'port 'port 1");
}

test "native: exchange transfer joins cancellation on scope exit" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.block 1 port.begin 'x set 1 portprobe.await-blocked " ++
        "x wrap [] (pop) @give task.await 'ok at pop " ++
        "x type p portprobe.step 7 port.call p port.close portprobe.cleaned", "'port 7 1");
}

test "native: registered capabilities retain identity across ordinary module bindings" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory type portprobe.factory portprobe.factory match? " ++
        "portprobe.echo portprobe.echo match? portprobe.input portprobe.output match? " ++
        "portprobe.factory sample.forward portprobe.factory match? " ++
        "portprobe.factory wrap [] (pop) 3 pack (@give) @attempt 'err at 'kind at", "'port 1 1 0 1 'domain");
}

test "native: common open and begin preserve structured configuration and parameters" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory 7 port.open 'p set p portprobe.inspect " ++
        "42 0.5 \"a\" first 'tag [7] {'key 9} portprobe.factory 7 pack port.begin " ++
        "dup port.result swap port.await p port.close portprobe.cleaned", "() 1");
}

test "native: common requests reject executable values oversize data and foreign selectors" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "[] (portprobe.factory (pop) port.open) @attempt 'err at 'kind at " ++
        "[] (portprobe.factory [0] 4096 take port.open) @attempt 'err at 'kind at " ++
        "portprobe.other [] port.open 'p set [] (p portprobe.failure [] port.begin) @attempt 'err at 'kind at " ++
        "p port.close portprobe.cleaned", "'type 'overflow 'type 1");
}

test "native: common call composes result claiming and exchange cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory [] port.open 'p set p portprobe.noop [] port.call " ++
        "p portprobe.noop [] port.call p port.close portprobe.cleaned", "() () 1");
}

test "native: common call closes failed exchanges and leaves its resource usable" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory [] port.open 'p set p wrap (portprobe.failure [] port.call) @attempt " ++
        "'err at 'kind at p portprobe.noop [] port.call pop p port.close portprobe.cleaned", "'domain 1");
}

test "native: byte endpoints preserve exact bytes finish and stable eof" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.echo [] port.begin 'x set " ++
        "x portprobe.input port.endpoint 'w set x portprobe.output port.endpoint 'r set " ++
        "w [0 10 255 1] port.write w port.finish w port.finish x port.await " ++
        "r 8 port.read r 8 port.read r 8 port.read " ++
        "x port.result x port.close p port.close r type portprobe.cleaned", "[0 10 255 1] [] [] () 'port 1");
}

test "native: endpoint attenuation rejects other directions and ownership transfer" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.echo [] port.begin 'x set " ++
        "x portprobe.input port.endpoint 'w set x portprobe.output port.endpoint 'r set " ++
        "w wrap (8 port.read) @attempt 'err at 'kind at " ++
        "r wrap ([1] port.write) @attempt 'err at 'kind at " ++
        "r wrap (port.finish) @attempt 'err at 'kind at " ++
        "w wrap [] (pop) 3 pack (@give) @attempt 'err at 'kind at " ++
        "w port.finish x port.await x port.close p port.close portprobe.cleaned", "'type 'type 'type 'domain 1");
}

test "native: media pipeline drains output and diagnostics concurrently under pressure" {
    for ([_]u32{ 1, 8 }) |workers| for ([_]u32{ 1, 8 }) |capacity| try expectPortProgramAtCapacity(workers, 4, capacity, "portprobe.factory [] port.open 'p set p portprobe.pipeline [] port.begin 'x set " ++
        "x portprobe.input port.endpoint 'w set " ++
        "x portprobe.output port.endpoint wrap ('r set [] (dup len 32 <) (r 8 port.read cat) while r 8 port.read) @spawn 'a set " ++
        "x portprobe.diagnostics port.endpoint wrap ('r set [] (dup len 32 <) (r 8 port.read cat) while r 8 port.read) @spawn 'b set " ++
        "w [3] 32 take port.write w port.finish " ++
        "a task.await 'ok at dup first [3] 32 take match? swap 1 at len " ++
        "b task.await 'ok at dup first [252] 32 take match? swap 1 at len " ++
        "x port.await x port.close p port.close portprobe.cleaned", "1 0 1 0 1");
}

test "native: input finish preserves an accepted writer through its final byte" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.echo [] port.begin 'x set " ++
        "x portprobe.input port.endpoint 'w set x portprobe.output port.endpoint 'r set " ++
        "w wrap ([1] 32 take port.write) @spawn 'a set r 8 port.read 'prefix set w port.finish " ++
        "prefix (dup len 32 <) (r 8 port.read cat) while [1] 32 take match? " ++
        "r 8 port.read len a task.await 'ok at pop " ++
        "w wrap ([] port.write) @attempt 'err at 'kind at " ++
        "x port.await x port.close p port.close portprobe.cleaned", "1 0 'io 1");
}

test "native: concurrent writes remain contiguous through repeated byte pressure" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.echo [] port.begin 'x set " ++
        "x portprobe.input port.endpoint 'w set " ++
        "x portprobe.output port.endpoint wrap ('r set [] (dup len 32 <) (r 8 port.read cat) while) @spawn 'reader set " ++
        "w wrap ([1] 16 take port.write) @spawn 'a set w wrap ([2] 16 take port.write) @spawn 'b set " ++
        "a task.await 'ok at pop b task.await 'ok at pop w port.finish " ++
        "reader task.await 'ok at first dup [1] 16 take [2] 16 take cat match? " ++
        "swap [2] 16 take [1] 16 take cat match? or " ++
        "x port.await x port.close p port.close portprobe.cleaned", "1 1");
}

test "native: overlapping endpoint reads fail without consuming the pending read" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.blocked [] port.begin 'x set 1 portprobe.await-blocked " ++
        "x portprobe.output port.endpoint 'r set r wrap (8 port.read) @spawn 'a set r wrap (8 port.read) @spawn 'b set " ++
        "a b 2 pack task.await-any 'err at 'kind at swap pop " ++
        "x port.cancel a task.await pop b task.await pop x port.close p port.close portprobe.cleaned", "'contract 1");
}

test "native: accepted output precedes failure and explicit eof remains stable" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.buffered-failure [] port.begin 'x set " ++
        "x wrap (port.await) @attempt 'err at 'kind at x portprobe.output port.endpoint 'r set " ++
        "r 8 port.read r wrap (8 port.read) @attempt 'err at 'kind at x port.close " ++
        "p portprobe.finished-failure [] port.begin 'y set y wrap (port.await) @attempt pop " ++
        "y portprobe.output port.endpoint 's set s 8 port.read s 8 port.read s 8 port.read " ++
        "y port.close p port.close portprobe.cleaned", "'domain [4 5 6] 'domain [4 5 6] [] [] 1");
}

test "native: early consumer completion interrupts a blocked byte producer" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.early-exit [] port.begin 'x set " ++
        "x portprobe.input port.endpoint 'w set w wrap ([7] 32 take port.write) @attempt 'err at 'kind at " ++
        "w port.finish x port.await x portprobe.output port.endpoint 8 port.read " ++
        "x port.close p port.close portprobe.cleaned", "'io [7] 1");
}

test "native: an exchange remains owned when only a borrowed use is sent" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.block 1 port.begin 'x set 1 portprobe.await-blocked " ++
        "x wrap (pop) @spawn task.await 'ok at pop " ++
        "portprobe.cleaned x wrap [] (pop) @give task.await 'ok at pop " ++
        "p portprobe.step 5 port.call p port.close portprobe.cleaned", "0 5 1");
}

test "native: common exchange await repeats and cancel waits for acknowledged return" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set " ++
        "p portprobe.noop [] port.begin 'done set done port.await done port.await done port.close done port.close " ++
        "p portprobe.block 1 port.begin 'x set 1 portprobe.await-blocked x port.cancel x port.cancel " ++
        "x wrap (port.await) @attempt 'err at 'kind at " ++
        "x wrap (port.await) @attempt 'err at 'kind at " ++
        "x port.close x port.close p portprobe.step 9 port.call p port.close portprobe.cleaned", "'cancelled 'cancelled 9 1");
}

test "native: common exchange failure is repeatable and separate from cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.failure [] port.begin 'x set " ++
        "x wrap (port.await) @attempt 'err at 'kind at " ++
        "x wrap (port.await) @attempt 'err at 'kind at " ++
        "x port.close p port.close portprobe.cleaned", "'domain 'domain 1");
}

test "native: exactly one concurrent caller claims an exchange result" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p portprobe.noop [] port.begin 'x set " ++
        "x wrap (port.result) @spawn 'a set x wrap (port.result) @spawn 'b set " ++
        "a task.await 'ra set b task.await 'rb set " ++
        "ra 'ok dict.has? rb 'ok dict.has? + " ++
        "ra 'err dict.has? (ra 'err at 'kind at) (rb 'err at 'kind at) if " ++
        "x port.await x port.close p port.close portprobe.cleaned", "1 'contract 1");
}

test "native: independent lanes retain admission capacity while a controller is blocked" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory [] port.open 'p set p wrap (portprobe.block 1 port.call) @spawn 't set " ++
        "1 portprobe.await-blocked p wrap (portprobe.signal-waiting portprobe.receive-step 9 port.call) @spawn 'q set " ++
        "1 portprobe.await-waiting p portprobe.step 65 port.call " ++
        "q cancel q await pop portprobe.unblock t await 'ok at first p port.close", "65 1");
}

test "native: acknowledged active cancellation preserves subsequent lane operations" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p wrap (portprobe.block 1 port.call) @spawn 't set " ++
        "1 portprobe.await-blocked p portprobe.step 17 port.begin 'q set " ++
        "t cancel t await 'err at 'kind at " ++
        "q port.result q port.close p portprobe.step 65 port.call p port.close portprobe.cleaned", "'cancelled 17 82 1");
}

test "native: unacknowledged cancellation closes every lane and joins cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.unrecoverable [] port.open 'p set p wrap (portprobe.unrecoverable-block 1 port.call) @spawn 'a set " ++
        "p wrap (portprobe.unrecoverable-send 1 port.call) @spawn 'b set " ++
        "2 portprobe.await-blocked a cancel a await 'err at 'kind at b await 'err at 'kind at " ++
        "p port.close portprobe.cleaned", "'cancelled 'cancelled 1");
}

test "native: closing and transferring independent lanes preserves resource ownership" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set p wrap (portprobe.block 1 port.call) @spawn 'a set " ++
        "p wrap (portprobe.block-send 1 port.call) @spawn 'b set 2 portprobe.await-blocked " ++
        "p wrap [] (port.close) @give await 'ok at pop " ++
        "a await 'err at 'kind at b await 'err at 'kind at portprobe.cleaned", "'cancelled 'cancelled 1");
}

test "native: creation refuses an operation budget smaller than its lane count" {
    try expectPortProgram(1, 1, "[] (portprobe.factory [] port.open) @attempt 'err at 'kind at portprobe.cleaned", "'domain 0");
}

test "native: blocked controllers leave another port and task runnable" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
        "1 portprobe.await-blocked [] (7) @spawn await 'ok at first " ++
        "portprobe.counter [] port.open portprobe.counter-step 4 port.call portprobe.unblock t await 'ok at first p port.close", "7 4 1");
}

test "native: cancellation before admission and while queued preserves the port" {
    for ([_]u32{ 1, 8 }) |workers| {
        try expectPortProgram(workers, 1, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
            "1 portprobe.await-blocked p wrap (portprobe.signal-waiting portprobe.counter-step 2 port.call) @spawn 'q set " ++
            "1 portprobe.await-waiting q cancel q await pop portprobe.unblock t await 'ok at first " ++
            "p portprobe.counter-step 2 port.call p port.close", "1 3");
        try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
            "1 portprobe.await-blocked p portprobe.counter-step 2 port.begin 'q set " ++
            "q port.cancel q port.close portprobe.unblock t await 'ok at first " ++
            "p portprobe.counter-step 2 port.call p port.close", "1 3");
    }
}

test "native: active cancellation interrupts backend waits and cancels its queue" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
        "1 portprobe.await-blocked p portprobe.counter-step 2 port.begin 'q set " ++
        "t cancel t await 'err at 'kind at q wrap (port.await) @attempt 'err at 'kind at q port.close " ++
        "p port.close p port.close portprobe.cleaned", "'cancelled 'cancelled 1");
}

test "native: admitted operations execute in order under queue pressure" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
        "1 portprobe.await-blocked p portprobe.counter-step 2 port.begin 'q set " ++
        "p wrap (portprobe.signal-waiting portprobe.counter-step 4 port.call) @spawn 'r set " ++
        "1 portprobe.await-waiting portprobe.unblock t await 'ok at first q port.result q port.close " ++
        "r await 'ok at first p port.close", "1 3 7");
}

test "native: initialization cancellation and concurrent close join cleanup" {
    for ([_]u32{ 1, 8 }) |workers| {
        try expectPortProgram(workers, 2, "portprobe.block-next [] (portprobe.counter [] port.open) @spawn 't set " ++
            "1 portprobe.await-blocked t cancel t await pop 1 portprobe.await-cleaned portprobe.cleaned", "1");
        try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
            "1 portprobe.await-blocked p wrap (port.close) @spawn 'a set " ++
            "p wrap (port.close) @spawn 'b set a await pop b await pop t await 'err at 'kind at " ++
            "portprobe.cleaned", "'cancelled 1");
    }
}

test "native: transfer preserves active operations and rolls back multiple ports" {
    for ([_]u32{ 1, 8 }) |workers| {
        try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
            "1 portprobe.await-blocked p wrap [] (portprobe.unblock portprobe.counter-step 2 port.call) @give await 'ok at first " ++
            "t await 'ok at first p port.close portprobe.cleaned", "3 1 1");
        try expectPortProgram(workers, 2, "portprobe.counter [] port.open portprobe.counter [] port.open 'q set 'p set q port.close " ++
            "p q pair [] (pop pop) 3 pack (@give) @attempt 'err at 'kind at " ++
            "p portprobe.counter-step 2 port.call p port.close portprobe.cleaned", "'domain 2 2");
    }
}

test "native: close races transfer and controller completion without duplicate cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p wrap (portprobe.counter-block 1 port.call) @spawn 't set " ++
        "1 portprobe.await-blocked p wrap (port.close) @spawn 'c set " ++
        "p wrap [] (pop) 3 pack (@give) @attempt pop portprobe.unblock " ++
        "c await 'ok at pop t await pop p port.close portprobe.cleaned", "1");
}

test "native: initialization and failed task publication join resource cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.fail-next [] (portprobe.counter [] port.open) @attempt 'err at 'kind at " ++
        "1 portprobe.await-cleaned [] (portprobe.counter [] port.open pop sample.fail-user) @spawn task.await 'err at 'kind at " ++
        "2 portprobe.await-cleaned portprobe.cleaned", "'domain 'user 2");
}

test "native: live capacity is reserved before initialization and released by close" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHostConfig(std.testing.allocator, &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = native_fixture.directory,
        .native_port_limits = .{ .max_live_ports = 1 },
    }, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try expectOk(&runtime, "portprobe.reset portprobe.counter [] port.open 'p set");
    try expectErrorContains(&runtime, "portprobe.counter [] port.open", &.{ "'kind 'domain", "capacity" });
    try expectOk(&runtime, "p port.close portprobe.counter [] port.open port.close");
    try expectOk(&runtime, "[] (portprobe.counter [] port.open portprobe.counter [] port.open) @spawn task.await 'err at 'kind at");
    var capacity_error = try runtime.stackDisplay();
    defer capacity_error.deinit();
    try std.testing.expectEqualStrings("'domain", capacity_error.bytes());
    try expectOk(&runtime, "pop");
    try expectOk(&runtime, "3 portprobe.await-cleaned portprobe.cleaned");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
}

test "native: completion remains observable after another task has awaited it" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set p portprobe.counter-step 2 port.begin 'x set " ++
        "x port.await x wrap (port.await) @spawn task.await 'ok at pop x port.result x port.close p port.close", "2");
}

test "native: Session shutdown joins active controllers before releasing images" {
    for ([_]u32{ 1, 8 }) |workers| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        var observer = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
        defer observer.deinit();
        try expectOk(&observer, "portprobe.reset");
        {
            var runtime = try session.Session.initWithHostConfig(std.testing.allocator, &.{}, .{
                .io = std.testing.io,
                .output = &output.writer,
                .diagnostics = &diagnostics.writer,
                .ecl_path = native_fixture.directory,
            }, .{ .worker_pool = workers });
            defer runtime.deinit();
            try expectOk(&runtime, "portprobe.counter [] port.open wrap (portprobe.counter-block 1 port.call) @spawn pop 1 portprobe.await-blocked");
        }
        // A second Session pins the same fixture image solely to observe the
        // first Session's completed cleanup through an ordinary native word.
        try expectOk(&observer, "portprobe.cleaned");
        try std.testing.expectEqual(@as(i64, 1), observer.stackItems()[0].int);
    }
}

const streamCounter = "'count set 'resource set resource portprobe.counter-echo [] port.begin 'exchange set " ++
    "exchange portprobe.counter-input port.endpoint wrap ('w set w [1] count take port.write w port.finish) @spawn 'writer set " ++
    "exchange portprobe.counter-output port.endpoint 'r set 0 (dup count <) (r 4096 port.read len +) while " ++
    "writer task.await 'ok at pop exchange port.await exchange port.close ";

test "native: package ports stream beyond capacity and retain ordered state" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHostConfig(std.testing.allocator, &.{}, .{
        .io = std.testing.io,
        .output = &output.writer,
        .diagnostics = &diagnostics.writer,
        .ecl_path = native_fixture.directory,
        .native_port_limits = .{ .ring_capacity = 8 },
    }, .{ .worker_pool = 1 });
    defer runtime.deinit();
    try expectOk(&runtime, "portprobe.counter [] port.open 'p set p 10000 " ++ streamCounter ++
        "p portprobe.counter-step 2 port.call p portprobe.counter-step 3 port.call p port.close p port.close");
    try std.testing.expectEqual(@as(i64, 10000), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 18), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 21), runtime.stackItems()[2].int);
}

test "native: package port kinds, operation failure, forwarding and terminal identity" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "portprobe.counter [] port.open 'p set");
    try expectOk(&runtime, "portprobe.other [] port.open 'q set q portprobe.other-step 0 port.call pop");
    try expectErrorContains(&runtime, "q portprobe.counter-step 0 port.call", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "p portprobe.other-step 0 port.call pop", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "p foreignport.counter-step 0 port.call", &.{"'kind 'type"});
    try expectErrorContains(&runtime, "p portprobe.counter-failure [] port.call", &.{ "'kind 'domain", "deliberate operation failure" });
    try expectOk(&runtime, "p portprobe.counter-step 3 port.call p wrap sample.nested-port p match? p port.close p port.close");
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "p portprobe.counter-step 0 port.call", &.{"'kind 'io"});
}

test "native: package port scope transfer and rollback" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "portprobe.counter [] port.open 'p set p wrap dup cat [] (pop pop) 3 pack (@give) @attempt pop p portprobe.counter-step 2 port.call");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[0].int);
    try expectOk(&runtime, "p wrap [] (portprobe.counter-step 3 port.call) @give task.await 'ok at first");
    try std.testing.expectEqual(@as(i64, 5), runtime.stackItems()[1].int);
    try expectErrorContains(&runtime, "p portprobe.counter-step 0 port.call", &.{"'kind 'io"});
}

test "native: streaming crosses the default ring capacity" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "portprobe.counter [] port.open 'p set p 131073 " ++ streamCounter ++ "p port.close");
    try std.testing.expectEqual(@as(i64, 131073), runtime.stackItems()[0].int);
}

test "native: bounded controller errors preserve UTF-8 and the backend error kind" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "portprobe.counter [] port.open 'p set");
    try expectErrorContains(&runtime, "p portprobe.counter-long-failure [] port.call", &.{"'kind 'io"});
    try expectErrorContains(&runtime, "portprobe.fail-long", &.{"'kind 'io"});
    try expectOk(&runtime, "p portprobe.counter-step 2 port.call p port.close");
    try std.testing.expectEqual(@as(i64, 2), runtime.stackItems()[0].int);
}

const PortSpec = struct {
    pub const name = "counter";
    pub const State = struct { value: u64 = 0 };
    pub fn init() State {
        return .{};
    }
    pub fn open(_: *State, _: *ecl.Controller) void {}
    pub fn run(_: *State, _: u32, _: *ecl.Controller) void {}
    pub fn cancel(_: *State) void {}
    pub fn deinit(_: *State) void {}
};

test "native: SDK port declarations validate state layouts and controller adapters" {
    const P = ecl.Port(PortSpec);
    const Extension = ecl.module(.{ .name = "sample", .doc = "Port definition probe.", .linkage = .static, .words = .{}, .ports = .{P} });
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    const validated = try validate(host.cleanup(), requested, Extension.descriptor());
    defer validated.deinit();
    const port = validated.port(0).?;
    try std.testing.expectEqualStrings("counter", port.name_ptr[0..port.name_len]);
    try std.testing.expectEqual(@as(u32, @sizeOf(PortSpec.State)), port.state_size);
    try std.testing.expect(validated.port(1) == null);
    var invalid = Extension.descriptor().*;
    var definition = P.definition();
    invalid.ports_ptr = @ptrCast(&definition);
    definition.cancel = null;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition = P.definition();
    definition.state_alignment = 3;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition = P.definition();
    definition.lane_count = 0;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition.lane_count = abi.max_port_lanes + 1;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition = P.definition();
    definition.cancellation = .acknowledge;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition = P.definition();
    definition.cancellation = @enumFromInt(999);
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition = P.definition();
    definition.select_lane = null;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    definition = P.definition();
    definition.identity = null;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
    var duplicates = [_]abi.PortDefinition{ P.definition(), P.definition() };
    duplicates[1].name_ptr = "other";
    duplicates[1].name_len = 5;
    invalid.ports_ptr = &duplicates;
    invalid.port_count = 2;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &invalid);
}

test "native: registered descriptors reject undeclared kinds lanes and endpoints" {
    const P = ecl.Port(PortSpec);
    const Extension = ecl.module(.{ .name = "sample", .doc = "Registered port validation.", .linkage = .static, .ports = .{P}, .words = .{
        ecl.factory("factory", "Create a counter.", P),
        ecl.operation("operation", "Read counter bytes.", P, 0, .operation, 1),
        ecl.endpoint("output", "Counter bytes.", P, .{ .id = 0, .transport = .bytes, .direction = .output }),
    } });
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    const validated = try validate(host.cleanup(), requested, Extension.descriptor());
    defer validated.deinit();
    try std.testing.expectEqual(@as(usize, 3), validated.definitions().len);
    var raw = Extension.descriptor().*;
    const original: [3]abi.Definition = raw.definitions_ptr[0..3].*;
    var definitions = original;
    raw.definitions_ptr = &definitions;
    definitions[0].binding.resource = 1;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &raw);
    definitions = original;
    definitions[1].binding.lane = 1;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &raw);
    definitions = original;
    definitions[1].binding.endpoints = 2;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &raw);
    definitions = original;
    definitions[2].binding.endpoint = 64;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &raw);
    definitions = original;
    definitions[2].binding.transport = @enumFromInt(999);
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &raw);
    definitions = original;
    definitions[2].binding.owner = .resource;
    try expectReject(error.InvalidPortDefinition, host.cleanup(), requested, &raw);
    definitions = original;
    definitions[0].doc_len = 0;
    try expectReject(error.EmptyDocumentation, host.cleanup(), requested, &raw);
}

fn expectOk(runtime: *session.Session, source: []const u8) !void {
    switch (try runtime.runUnit("native-test.ecl", source)) {
        .ok => {},
        .incomplete => return error.UnexpectedIncomplete,
        .err => |failure| {
            defer runtime.release(failure);
            var rendered = try runtime.renderValue(failure);
            defer rendered.deinit();
            std.debug.print("unexpected native ECL error: {s}\n", .{rendered.bytes()});
            return error.UnexpectedLanguageError;
        },
    }
}

fn expectErrorContains(
    runtime: *session.Session,
    source: []const u8,
    needles: []const []const u8,
) !void {
    const failure = switch (try runtime.runUnit("native-test.ecl", source)) {
        .err => |item| item,
        .ok => return error.ExpectedLanguageError,
        .incomplete => return error.UnexpectedIncomplete,
    };
    defer runtime.release(failure);
    var rendered = try runtime.renderValue(failure);
    defer rendered.deinit();
    for (needles) |needle| {
        if (std.mem.indexOf(u8, rendered.bytes(), needle) == null) {
            std.debug.print("expected native error to contain {s}; received {s}\n", .{ needle, rendered.bytes() });
            return error.MissingErrorDetail;
        }
    }
}

fn initRuntime(
    output: *std.Io.Writer,
    diagnostics: *std.Io.Writer,
    search: []const u8,
) !session.Session {
    return session.Session.initWithHost(std.testing.allocator, &.{}, .{
        .io = std.testing.io,
        .output = output,
        .diagnostics = diagnostics,
        .ecl_path = search,
    });
}

const Fixture = struct {
    module_name: []const u8 = "sample",
    module_doc: []const u8 = "Sample native fixture.",
    word_name: []const u8 = "increment",
    word_doc: []const u8 = "Increment a number.",
    input_name: []const u8 = "n",
    output_name: []const u8 = "result",
    inputs: ?[1]abi.EffectSlot = null,
    outputs: ?[1]abi.EffectSlot = null,
    definitions: ?[1]abi.Definition = null,
    capabilities: ?[1]abi.CapabilityRequirement = null,

    fn descriptor(self: *Fixture) abi.Descriptor {
        self.inputs = .{.{
            .name_ptr = self.input_name.ptr,
            .name_len = self.input_name.len,
        }};
        self.outputs = .{.{
            .name_ptr = self.output_name.ptr,
            .name_len = self.output_name.len,
        }};
        self.definitions = .{.{
            .callback_index = 0,
            .name_ptr = self.word_name.ptr,
            .name_len = self.word_name.len,
            .doc_ptr = self.word_doc.ptr,
            .doc_len = self.word_doc.len,
            .input_count = self.inputs.?.len,
            .inputs_ptr = &self.inputs.?,
            .output_count = self.outputs.?.len,
            .outputs_ptr = &self.outputs.?,
        }};
        self.capabilities = .{.{ .id = @intFromEnum(abi.CapabilityId.call) }};
        return .{
            .module_name_ptr = self.module_name.ptr,
            .module_name_len = self.module_name.len,
            .module_doc_ptr = self.module_doc.ptr,
            .module_doc_len = self.module_doc.len,
            .definition_count = self.definitions.?.len,
            .definitions_ptr = &self.definitions.?,
            .capability_count = self.capabilities.?.len,
            .capabilities_ptr = &self.capabilities.?,
            .callback_count = 1,
            .invoke = dummyInvoke,
        };
    }
};

fn dummyInvoke(_: *const abi.HostTable, _: *anyopaque, _: u32, output: *abi.InvokeResult) callconv(.c) void {
    output.* = .{ .tag = .fail };
}

test "native: opaque ports survive forwarding and nested aggregate builders" {
    const Port = struct {
        releases: usize = 0,

        pub fn releasePort(self: *@This()) void {
            self.releases += 1;
        }
        pub fn prepareScopeTransfer(_: *@This(), _: *anyopaque, _: *anyopaque) heap.PortTransferError!void {
            return error.Closed;
        }
        pub fn commitScopeTransfer(_: *@This()) void {}
        pub fn abortScopeTransfer(_: *@This()) void {}
    };
    var port: Port = .{};
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    {
        var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
        defer runtime.deinit();
        try runtime.pushOwned(try heap.createOwnedPort(Port, .resource, std.testing.allocator, 917, &port));
        try expectErrorContains(&runtime, "sample.draft-fail", &.{ "'kind 'user", "draft candidates retired" });
        try std.testing.expectEqual(@as(usize, 0), port.releases);
        try expectOk(
            &runtime,
            "sample.forward sample.split " ++
                "sample.singleton sample.nested-port " ++
                "'key swap sample.pair-dict sample.nested-port match?",
        );
        try std.testing.expectEqual(@as(i64, 1), runtime.stackItems()[0].int);
        try std.testing.expectEqual(@as(usize, 1), port.releases);
    }
    try std.testing.expectEqual(@as(usize, 1), port.releases);
}

test "native: borrowed port roles forward identities but cannot be given" {
    const Capability = struct {
        releases: usize = 0,
        pub fn releasePort(self: *@This()) void {
            self.releases += 1;
        }
    };
    inline for (comptime std.meta.tags(heap.BorrowedPortVariant)) |variant| {
        var capability: Capability = .{};
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        {
            var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
            defer runtime.deinit();
            try runtime.pushOwned(try heap.createBorrowedPort(Capability, variant, std.testing.allocator, 918, &capability));
            try expectOk(&runtime, "'cap set cap type 'port match? cap sample.forward cap match? " ++
                "cap wrap [] (pop) 3 pack (@give) @attempt 'err at 'kind at");
            var display = try runtime.stackDisplay();
            defer display.deinit();
            try std.testing.expectEqualStrings("1 1 'domain", display.bytes());
            try std.testing.expectEqual(@as(usize, 0), capability.releases);
        }
        try std.testing.expectEqual(@as(usize, 1), capability.releases);
    }
}

fn validate(
    host: *const heap.HostCleanup,
    requested: intern.ModuleName,
    raw: *const abi.Descriptor,
) descriptor_api.ValidateError!*descriptor_api.ValidatedDescriptor {
    var cursor = descriptor_api.ValidateCursor.init(host, requested, raw);
    defer cursor.deinit();
    while (true) switch (try cursor.advance(7)) {
        .pending => {},
        .complete => |validated| return validated,
    };
}

fn expectReject(
    expected: descriptor_api.ValidateError,
    host: *const heap.HostCleanup,
    requested: intern.ModuleName,
    raw: *const abi.Descriptor,
) !void {
    var cursor = descriptor_api.ValidateCursor.init(host, requested, raw);
    defer cursor.deinit();
    while (true) {
        const progress = cursor.advance(5) catch |err| {
            try std.testing.expectEqual(expected, err);
            return;
        };
        switch (progress) {
            .pending => {},
            .complete => |validated| {
                validated.deinit();
                return error.TestExpectedError;
            },
        }
    }
}

test "native: descriptor validation rejects malformed metadata before publication" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    var fixture = Fixture{};

    var raw = fixture.descriptor();
    raw.abi_version += 1;
    try expectReject(error.AbiVersionMismatch, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    raw.invoke = null;
    raw.callback_count = 0;
    try expectReject(error.MissingInvoke, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.capabilities.?[0].id = 99;
    try expectReject(error.UnsupportedCapabilityId, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.definitions.?[0].callback_index = 1;
    try expectReject(error.CallbackIndexOutOfRange, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.definitions.?[0].size = 4;
    try expectReject(error.RecordSizeMismatch, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.definitions.?[0].continuation_size = 8;
    try expectReject(error.InvalidContinuation, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    raw.module_name_ptr = "different".ptr;
    raw.module_name_len = "different".len;
    try expectReject(error.ModuleNameMismatch, host.cleanup(), requested, &raw);

    raw = fixture.descriptor();
    fixture.word_doc = " \n\t";
    raw = fixture.descriptor();
    try expectReject(error.EmptyDocumentation, host.cleanup(), requested, &raw);

    fixture.word_doc = "Increment a number.";
    fixture.word_name = "bad.name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);

    fixture.word_name = "bad name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);

    fixture.word_name = "bad\u{00a0}name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);

    fixture.word_name = "increment";
    fixture.module_name = "bad\u{2000}name";
    raw = fixture.descriptor();
    try expectReject(error.InvalidName, host.cleanup(), requested, &raw);
}

test "native: validation copies names effects and documentation into runtime storage" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    var module_name = [_]u8{ 's', 'a', 'm', 'p', 'l', 'e' };
    var word_name = [_]u8{ 'i', 'n', 'c', 'r', 'e', 'm', 'e', 'n', 't' };
    var word_doc = "Increment a number.".*;
    var fixture = Fixture{
        .module_name = &module_name,
        .word_name = &word_name,
        .word_doc = &word_doc,
    };
    var raw = fixture.descriptor();
    const validated = try validate(host.cleanup(), requested, &raw);
    defer validated.deinit();

    @memset(&module_name, 'x');
    @memset(&word_name, 'x');
    @memset(&word_doc, 'x');

    try std.testing.expectEqualStrings("sample", intern.get(intern.moduleId(validated.name())));
    try std.testing.expectEqual(@as(usize, 1), validated.definitions().len);
    const definition = validated.definitions()[0];
    try std.testing.expectEqualStrings("increment", intern.get(intern.namespaceId(definition.name)));
    try std.testing.expectEqual(@as(u32, 1), definition.effect.inputs);
    try std.testing.expectEqual(@as(u32, 1), definition.effect.outputs);
    const document = env.documentationHeader(definition.doc);
    try std.testing.expectEqual(@as(u64, "Increment a number.".len), document.length());
    for ("Increment a number.", 0..) |byte, index|
        try std.testing.expectEqual(@as(u32, byte), list.atUnchecked(.{ .list = document }, index).char);
    try std.testing.expectEqual(@as(usize, 1), validated.requirements().len);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.call), validated.requirements()[0].id);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, validationAllocationProbe, .{});
}

fn validationAllocationProbe(allocator: std.mem.Allocator) !void {
    var host = heap.HostOwner.init(allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("allocation-native");
    var fixture = Fixture{ .module_name = "allocation-native" };
    var raw = fixture.descriptor();
    const validated = try validate(host.cleanup(), requested, &raw);
    validated.deinit();
}

test "native: the SDK generates a descriptor the production validator accepts" {
    var host = heap.HostOwner.init(std.testing.allocator);
    defer host.cleanup().drain();
    const requested = try intern.internModuleName("sample");
    const validated = try validate(host.cleanup(), requested, native_sample.Extension.descriptor());
    defer validated.deinit();

    try std.testing.expectEqualStrings("sample", intern.get(intern.moduleId(validated.name())));
    try std.testing.expectEqual(@as(usize, 20), validated.definitions().len);
    const expected_names = [_][]const u8{
        "increment",     "discard",        "split",      "forward",    "nested-port",    "fail-user",      "fail-kind",
        "make-char",     "singleton",      "pair-dict",  "sum-list",   "sum-dict",       "cooperative",    "draft-fail",
        "yield-forever", "builder-budget", "large-list", "large-dict", "duplicate-dict", "noncooperative",
    };
    for (validated.definitions(), expected_names) |definition, expected| {
        try std.testing.expectEqualStrings(expected, intern.get(intern.namespaceId(definition.name)));
        try std.testing.expect(env.documentationHeader(definition.doc).length() != 0);
    }
    try std.testing.expectEqual(@as(usize, 3), validated.requirements().len);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.call), validated.requirements()[0].id);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.build_values), validated.requirements()[1].id);
    try std.testing.expectEqual(@intFromEnum(abi.CapabilityId.reschedule), validated.requirements()[2].id);
}

test "native: a discovered artifact publishes its complete table atomically" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();

    try expectOk(
        &runtime,
        "'sample ('increment) import 40 sample.increment 41 increment 's 'sample alias 42 s.increment",
    );
    try std.testing.expectEqual(@as(usize, 3), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 41), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(i64, 43), runtime.stackItems()[2].int);

    const exports = [_][]const u8{
        "sample.increment",     "sample.discard",        "sample.split",
        "sample.forward",       "sample.fail-user",      "sample.fail-kind",
        "sample.singleton",     "sample.pair-dict",      "sample.sum-list",
        "sample.sum-dict",      "sample.cooperative",    "sample.draft-fail",
        "sample.yield-forever", "sample.builder-budget", "sample.large-list",
        "sample.large-dict",    "sample.duplicate-dict", "sample.noncooperative",
    };
    for (exports) |prefix| {
        var completion = try runtime.completionCandidates(prefix);
        defer completion.deinit();
        try std.testing.expectEqual(@as(usize, 1), completion.items().len);
        try std.testing.expectEqualStrings(prefix, completion.items()[0]);
    }
}

test "native: source candidates win inside a root and path-root order wins across roots" {
    const fixture_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ native_fixture.directory, "sample.eclmod" },
    );
    defer std.testing.allocator.free(fixture_path);

    var same_root = std.testing.tmpDir(.{});
    defer same_root.cleanup();
    try same_root.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.ecl",
        .data = "[] (100 'increment set) 'sample @defm",
    });
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        fixture_path,
        same_root.dir,
        "sample.eclmod",
        std.testing.io,
        .{},
    );
    const same_root_path = try same_root.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(same_root_path);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var source_first = try initRuntime(&output.writer, &diagnostics.writer, same_root_path);
    defer source_first.deinit();
    try expectOk(&source_first, "sample.increment");
    try std.testing.expectEqual(@as(i64, 100), source_first.stackItems()[0].int);

    var native_root = std.testing.tmpDir(.{});
    defer native_root.cleanup();
    try std.Io.Dir.copyFile(
        std.Io.Dir.cwd(),
        fixture_path,
        native_root.dir,
        "sample.eclmod",
        std.testing.io,
        .{},
    );
    var later_source = std.testing.tmpDir(.{});
    defer later_source.cleanup();
    try later_source.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.ecl",
        .data = "[] (100 'increment set) 'sample @defm",
    });
    const native_root_path = try native_root.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(native_root_path);
    const later_source_path = try later_source.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(later_source_path);
    const search = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}{c}{s}",
        .{ native_root_path, std.fs.path.delimiter, later_source_path },
    );
    defer std.testing.allocator.free(search);
    var path_first = try initRuntime(&output.writer, &diagnostics.writer, search);
    defer path_first.deinit();
    try expectOk(&path_first, "41 sample.increment");
    try std.testing.expectEqual(@as(i64, 42), path_first.stackItems()[0].int);
}

test "native: a rejected artifact publishes nothing and never selects a later candidate" {
    const cases = [_]struct { defect: []const u8, message: []const u8 }{
        .{ .defect = "wrong-name", .message = "ModuleNameMismatch" },
        .{ .defect = "abi-version", .message = "AbiVersionMismatch" },
        .{ .defect = "duplicate-word", .message = "DuplicateDefinition at definition 1" },
        .{ .defect = "missing-doc", .message = "EmptyDocumentation at definition 0" },
        .{ .defect = "entry-failure", .message = "native module entry failed" },
        .{ .defect = "invalid-effect", .message = "InvalidEffect at definition 0" },
        .{ .defect = "unsupported-capability", .message = "UnsupportedCapabilityId" },
        .{ .defect = "invalid-continuation", .message = "InvalidContinuation" },
    };
    for (cases) |case| {
        const broken = try std.fs.path.join(
            std.testing.allocator,
            &.{ native_fixture.directory, case.defect },
        );
        defer std.testing.allocator.free(broken);
        const search = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{c}{s}",
            .{ broken, std.fs.path.delimiter, native_fixture.directory },
        );
        defer std.testing.allocator.free(search);
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        var runtime = try initRuntime(&output.writer, &diagnostics.writer, search);
        defer runtime.deinit();
        try expectErrorContains(&runtime, "'sample ('increment) import", &.{ "'kind 'io", case.message, broken });
        var completion = try runtime.completionCandidates("sample.");
        defer completion.deinit();
        try std.testing.expectEqual(@as(usize, 0), completion.items().len);
        // Under the qualified-miss auto-load ruling a bare qualified
        // reference loads its module exactly as `import` does, so it reports the
        // same rejection rather than an undefined word.
        try expectErrorContains(&runtime, "sample.increment", &.{ "'kind 'io", case.message });
    }
}

test "native: reflection exposes native origin effects documentation and capabilities" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(
        &runtime,
        "'sample.increment which 'sample.increment see 'sample.increment doc",
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "sample.increment -> sample.increment native public generation 1 (n -- result) requires call, build-values, reschedule",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "<native:sample.increment> requires call build-values\nreschedule",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "requires call, build-values, reschedule") != null);
    try expectOk(&runtime, "'portprobe.signal-waiting which 'portprobe.signal-waiting see");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "requires call, reschedule, ports") != null);
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("\"Increment an integer.\"", display.bytes());
}

test "native: only exact completion mutates the operand stack" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "7");
    try expectErrorContains(
        &runtime,
        "sample.fail-user",
        &.{ "'kind 'user", "sample native failure", "'word 'sample.fail-user" },
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    const author_kinds = [_][]const u8{
        "type", "shape", "conform", "overflow", "domain", "parse", "io", "user",
    };
    for (author_kinds, 0..) |kind, index| {
        var source_buffer: [32]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buffer, "{d}", .{index});
        try expectOk(&runtime, source);
        var expected_buffer: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "'kind '{s}", .{kind});
        try expectErrorContains(&runtime, "sample.fail-kind", &.{ expected, "selected native failure" });
        try std.testing.expectEqual(@as(i64, @intCast(index)), runtime.stackItems()[1].int);
        try expectOk(&runtime, "pop");
    }
    try expectOk(&runtime, "sample.split");
    try std.testing.expectEqual(@as(usize, 2), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[1].int);
    try expectOk(&runtime, "sample.singleton");
    try std.testing.expectEqual(@as(usize, 2), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 7), runtime.stackItems()[0].int);
    try std.testing.expectEqual(@as(u64, 1), runtime.stackItems()[1].list.length());
}

test "native: the static transport publishes a linked descriptor through the same path" {
    var host = heap.HostOwner.init(std.testing.allocator);
    var environment = try env.Env.init(&host);
    var registry = try modules.Registry.init(host.cleanup());
    const owner = try native_module.Owner.init(host.cleanup());
    defer {
        const closing = owner.closeCalls();
        registry.deinit();
        // Images clear their Env-owned scope-label cell as they retire, so this
        // drain must finish before the Env releases the cells.
        host.cleanup().drain();
        environment.deinit();
        const settled = closing.settle();
        host.cleanup().drain();
        settled.deinit();
    }
    const requested = try intern.internModuleName("sample");
    var loader = switch (owner.loader().startStatic(requested, native_sample.Extension.descriptor())) {
        .loading => |cursor| cursor,
        .failure => |failure| {
            std.debug.print("unexpected static native load failure: {s}\n", .{failure.text()});
            return error.UnexpectedNativeLoadFailure;
        },
    };
    defer loader.deinit();
    const loaded = while (true) switch (try loader.advance(7)) {
        .pending => {},
        .loaded => |instance| break instance,
        .failure => |failure| {
            std.debug.print("unexpected static native validation failure: {s}\n", .{failure.text()});
            return error.UnexpectedNativeLoadFailure;
        },
    };
    defer loaded.releasePin();
    var publication = try modules.Registry.NativeCandidateCursor.init(&registry, loaded);
    defer publication.deinit();
    var candidate = while (true) switch (try publication.advance()) {
        .pending => {},
        .complete => |candidate| break candidate,
    };
    defer candidate.deinit();
    var candidate_sealed = candidate.seal();
    defer candidate_sealed.deinit();
    _ = try modules.testing.register(&registry, candidate_sealed.ref(), requested);
    var generation = modules.testing.acquire(&registry, requested).?;
    defer generation.deinit();
    const increment = try intern.internNamespace("increment");
    var resolver = generation.resolveCursor(intern.namespaceId(increment));
    defer resolver.deinit();
    var binding = while (true) switch (resolver.advance()) {
        .pending => {},
        .complete => |resolved| break resolved.?,
    };
    defer binding.deinit();
    try std.testing.expect(binding.binding == .native);
    try std.testing.expectEqual(@as(u32, 1), binding.effect.?.inputs);
    try std.testing.expectEqual(@as(u32, 1), binding.effect.?.outputs);
    try std.testing.expectEqual(@as(usize, 3), binding.binding.native.instance.requirements().len);
    const document = env.documentationHeader(binding.doc.?);
    try std.testing.expectEqual(@as(u64, "Increment an integer.".len), document.length());
    for ("Increment an integer.", 0..) |byte, index|
        try std.testing.expectEqual(
            @as(u32, byte),
            list.atUnchecked(.{ .list = document }, index).char,
        );
}

test "native: cooperative slices let another unit progress at one worker" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHostConfig(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = native_fixture.directory,
        },
        .{ .worker_pool = 1 },
    );
    defer runtime.deinit();
    // Measure interleaved execution after module loading; a cold await-any
    // lookup can otherwise let the native task finish before observing it.
    try expectOk(&runtime, "'task ('await 'await-any) import 0 sample.increment pop");
    try expectOk(
        &runtime,
        "[] ([] (sample.cooperative) @spawn 'native-task set " ++
            "[] (7) @spawn 'observer set native-task observer pair task.await-any) @spawn task.await",
    );
    var display = try runtime.stackDisplay();
    defer display.deinit();
    try std.testing.expectEqualStrings("{'ok (1 {'ok [7]})}", display.bytes());
}

test "native: aggregate cursors and builders charge the scheduler budget" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try initRuntime(&output.writer, &diagnostics.writer, native_fixture.directory);
    defer runtime.deinit();
    try expectOk(&runtime, "200000 range");
    try expectOk(&runtime, "sample.sum-list");
    try std.testing.expectEqual(@as(i64, 19_999_900_000), runtime.stackItems()[0].int);
    try std.testing.expect(runtime.lastPolls() >= 4);
    try expectOk(
        &runtime,
        "sample.builder-budget 7 sample.singleton {'a 1 'b 2} sample.sum-dict " ++
            "'answer 42 sample.pair-dict",
    );
    try std.testing.expectEqual(@as(i64, 42), runtime.stackItems()[1].int);
    try std.testing.expectEqual(@as(u64, 1), runtime.stackItems()[2].list.length());
    try std.testing.expectEqual(@as(i64, 3), runtime.stackItems()[3].int);
    try std.testing.expectEqual(@as(u64, 1), runtime.stackItems()[4].dict.length());
    try std.testing.expect(runtime.lastPolls() >= 2);
}

test "native: cancellation after a yield preserves the pre-call operand stack" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer diagnostics.deinit();
    var runtime = try session.Session.initWithHostConfig(
        std.testing.allocator,
        &.{},
        .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = native_fixture.directory,
        },
        .{ .worker_pool = 1 },
    );
    defer runtime.deinit();
    try expectOk(&runtime, "5");
    try expectOk(
        &runtime,
        "[] (9 sample.yield-forever) @spawn dup 1 task.await-for pop dup task.cancel task.await pop",
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.stackItems().len);
    try std.testing.expectEqual(@as(i64, 5), runtime.stackItems()[0].int);
}

test "native: graceful shutdown has independent progress and joins cleanup once" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory [] port.open 'p set " ++
        "p portprobe.blocked [] port.begin 'x set 1 portprobe.await-blocked " ++
        "p port.shutdown p port.shutdown p port.close " ++
        "x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "portprobe.shutdowns portprobe.cleaned", "'cancelled 1 1");
}

test "native: unsupported graceful shutdown preserves abortive cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.counter [] port.open 'p set " ++
        "p wrap (port.shutdown) @attempt 'err at 'kind at portprobe.cleaned " ++
        "p port.close p wrap (port.shutdown) @attempt 'err at 'kind at " ++
        "portprobe.shutdowns portprobe.cleaned", "'domain 0 'domain 0 1");
}

test "native: graceful failure is repeatable after joined cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory 254 port.open 'p set " ++
        "p wrap (port.shutdown) @attempt 'err at 'kind at portprobe.cleaned " ++
        "p wrap (port.shutdown) @attempt 'err at 'kind at p port.close " ++
        "portprobe.shutdowns portprobe.cleaned", "'domain 1 'domain 1 1");
}

test "native: abort interrupts blocked graceful shutdown and joins its callback" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory 253 port.open 'p set " ++
        "p wrap (port.shutdown) @spawn 's set 1 portprobe.await-blocked " ++
        "p wrap (portprobe.noop [] port.begin) @attempt 'err at 'kind at " ++
        "p port.close s task.await 'err at 'kind at " ++
        "p wrap (port.shutdown) @attempt 'err at 'kind at " ++
        "portprobe.shutdowns portprobe.cleaned", "'io 'io 'io 1 1");
}

test "native: concurrent graceful callers invoke one callback" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory 253 port.open 'p set " ++
        "p wrap (port.shutdown) @spawn 'a set 1 portprobe.await-blocked " ++
        "p wrap (port.shutdown) @spawn 'b set portprobe.unblock " ++
        "a task.await 'ok at pop b task.await 'ok at pop p port.close " ++
        "portprobe.shutdowns portprobe.cleaned", "1 1");
}

test "native: cancelled receiving tasks leave message and result claims available" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory [] port.open 'p set " ++
        "p portprobe.message-result [] port.begin 'x set x wrap (port.result) @spawn 'a set " ++
        "a cancel a task.await 'err at 'kind at " ++
        "x portprobe.sender port.endpoint [42] port.send x port.result x port.close " ++
        "p portprobe.messages [] port.begin 'y set y portprobe.receiver port.endpoint 'r set " ++
        "r wrap (port.receive) @spawn 'b set b cancel b task.await 'err at 'kind at " ++
        "y portprobe.sender port.endpoint dup [7] port.send port.finish " ++
        "r port.receive 'value at r port.receive 'kind at y port.close p port.close " ++
        "portprobe.cleaned", "'cancelled [42] 'cancelled [7] 'eof 1");
}

test "native: allocation failure survives controller and endpoint boundaries" {
    for ([_]u32{ 1, 8 }) |workers| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        var runtime = try session.Session.initWithHostConfig(std.testing.allocator, &.{}, .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = native_fixture.directory,
        }, .{ .worker_pool = workers });
        defer runtime.deinit();
        for ([_][]const u8{
            "port.await",                                    "port.result", "portprobe.output port.endpoint 1 port.read",
            "portprobe.receiver port.endpoint port.receive",
        }) |observe| {
            try expectOk(&runtime, "portprobe.reset portprobe.factory [] port.open 'p set");
            const source = try std.fmt.allocPrint(std.testing.allocator, "p portprobe.allocation-failure [] port.begin {s}", .{observe});
            defer std.testing.allocator.free(source);
            try std.testing.expectError(error.OutOfMemory, runtime.runUnit("native-oom.ecl", source));
            try expectOk(&runtime, "p port.close portprobe.cleaned");
            var display = try runtime.stackDisplay();
            defer display.deinit();
            try std.testing.expectEqualStrings("1", display.bytes());
            try expectOk(&runtime, "pop");
        }
        try expectOk(&runtime, "portprobe.reset portprobe.factory 252 port.open 'p set");
        try std.testing.expectError(error.OutOfMemory, runtime.runUnit("native-shutdown-oom.ecl", "p port.shutdown"));
        try expectOk(&runtime, "p port.close portprobe.cleaned");
        var display = try runtime.stackDisplay();
        defer display.deinit();
        try std.testing.expectEqualStrings("1", display.bytes());
        try expectOk(&runtime, "pop portprobe.reset");
        try std.testing.expectError(error.OutOfMemory, runtime.runUnit("native-open-oom.ecl", "portprobe.factory 255 port.open"));
        try expectOk(&runtime, "1 portprobe.await-cleaned portprobe.cleaned");
        var opened = try runtime.stackDisplay();
        defer opened.deinit();
        try std.testing.expectEqualStrings("1", opened.bytes());
    }
}

test "native: message builders produce unsolicited events with bounded queue pressure" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.events [] port.begin 'x set " ++
        "x portprobe.receiver port.endpoint 'r set " ++
        "8 range (r port.receive 'value at =) each sum " ++
        "r port.receive 'kind at x port.await x port.close p port.close portprobe.cleaned", "8 'eof 1");
}

test "native: message builders preserve nested scalars and capability identity" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory [] port.open 'p set p portprobe.build-result p wrap port.call 'payload at " ++
        "dup 0 at swap dup 1 at int swap dup 2 at swap dup 3 at swap 4 at p match? " ++
        "p port.close portprobe.cleaned", "0.5 955 42 'tag 1 1");
}

test "native: message builder failures reject partial output and duplicate dictionaries" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 2, "portprobe.factory [] port.open 'p set p wrap (portprobe.duplicate-result [] port.call) @attempt 'err at 'kind at " ++
        "p portprobe.oversize-event [] port.begin 'x set x portprobe.receiver port.endpoint wrap (port.receive) @attempt 'err at 'kind at " ++
        "x wrap (port.await) @attempt 'err at 'kind at x port.close p port.close portprobe.cleaned", "'domain 'overflow 'overflow 1");
}

test "native: message builders copy received values and reset consumed messages" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.factory [] port.open 'p set p portprobe.build-received [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint [42] port.send x portprobe.receiver port.endpoint 'r set " ++
        "r port.receive 'value at 'copy at r port.receive 'value at len x port.result dict.keys len " ++
        "r port.receive 'kind at x port.close p port.close portprobe.cleaned", "42 0 0 'eof 1");
}

test "native: resource message endpoints outlive exchanges and preserve attenuation" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.resource-notify [] port.call pop " ++
        "p portprobe.resource-receiver port.endpoint 'r set r port.receive 'value at " ++
        "p portprobe.noop [] port.begin 'x set x wrap (portprobe.resource-receiver port.endpoint) @attempt 'err at 'kind at " ++
        "p wrap (portprobe.receiver port.endpoint) @attempt 'err at 'kind at " ++
        "x port.close p port.close r wrap (port.receive) @attempt 'err at 'kind at portprobe.cleaned", "42 'type 'type 'io 1");
}

test "native: resource message finish and shutdown join their controllers" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.resource-messages [] port.begin 'x set " ++
        "p portprobe.resource-sender port.endpoint 's set p portprobe.resource-receiver port.endpoint 'r set " ++
        "s 7 port.send r port.receive 'value at s port.finish r port.receive 'kind at " ++
        "x port.await x port.close r port.receive 'kind at p port.shutdown portprobe.cleaned", "7 'eof 'eof 1");
}

test "native: resource byte endpoints make independent progress under tiny rings" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.resource-bytes [] port.begin 'x set " ++
        "p portprobe.resource-input port.endpoint wrap (dup [1 2 3] port.write port.finish) @spawn 't set " ++
        "p portprobe.resource-output port.endpoint 'r set r 8 port.read r 8 port.read r 8 port.read " ++
        "r 8 port.read t task.await 'ok at pop x port.await x port.close p port.close portprobe.cleaned", "[1] [2] [3] [] 1");
}

test "native: resource closure discards self-retaining channel messages exactly once" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.factory [] port.open 'p set p portprobe.resource-messages [] port.begin 'x set " ++
        "p portprobe.resource-sender port.endpoint dup p port.send port.finish " ++
        "x port.await x port.close p port.close p port.close portprobe.cleaned", "1");
}

test "native: cancellation interrupts resource message readers without finishing the resource" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.factory [] port.open 'p set p portprobe.resource-messages [] port.begin 'x set " ++
        "1 portprobe.await-blocked x port.cancel x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "p portprobe.resource-messages [] port.begin 'y set p portprobe.resource-sender port.endpoint 's set " ++
        "s 42 port.send p portprobe.resource-receiver port.endpoint port.receive 'value at " ++
        "s port.finish y port.await y port.close p port.close portprobe.cleaned", "'cancelled 42 1");
}

test "native: cancellation interrupts resource byte readers and leaves the lane reusable" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.resource-bytes [] port.begin 'x set " ++
        "1 portprobe.await-blocked x port.cancel x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "p portprobe.resource-bytes [] port.begin 'y set p portprobe.resource-input port.endpoint dup [42] port.write port.finish " ++
        "p portprobe.resource-output port.endpoint dup 1 port.read swap 1 port.read " ++
        "y port.await y port.close p port.close portprobe.cleaned", "'cancelled [42] [] 1");
}

test "native: bidirectional RPC interleaves notifications and correlates out of order replies" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 64 }, "portprobe.factory [] port.open 'p set p portprobe.rpc [] port.begin 'x set " ++
        "x portprobe.receiver port.endpoint 'r set r port.receive 'value at 'reply at 'a set " ++
        "r port.receive 'value at 'notification at r port.receive 'value at 'reply at 'b set " ++
        "b [2 20] port.send r port.receive 'value at a [1 10] port.send r port.receive 'value at " ++
        "r port.receive 'kind at x port.result x port.close " ++
        "b wrap ([] port.send) @attempt 'err at 'kind at p port.close portprobe.cleaned", "7 [2 20] [1 10] 'eof 42 'io 1");
}

test "native: multiplexed channels preserve boundaries and independent progress under pressure" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.multiplex [] port.open 'p set " ++
        "p portprobe.channel 1 port.call 'a set p portprobe.channel 2 port.call 'b set " ++
        "a portprobe.channel-stream [] port.begin 'x set x portprobe.channel-input port.endpoint 'xi set " ++
        "xi [] port.send xi [1] port.send 2 portprobe.await-blocked " ++
        "b portprobe.channel-stream [] port.begin 'y set y portprobe.channel-input port.endpoint [] port.send " ++
        "y portprobe.channel-output port.endpoint port.receive 'value at dup 'channel at swap 'payload at len " ++
        "y portprobe.channel-input port.endpoint port.finish y port.await y port.close " ++
        "x port.cancel x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "a portprobe.channel-stream [] port.begin 'z set z portprobe.channel-input port.endpoint [3] port.send " ++
        "z portprobe.channel-output port.endpoint port.receive 'value at 'payload at " ++
        "z portprobe.channel-input port.endpoint port.finish z port.await z port.close p port.close portprobe.cleaned", "2 0 'cancelled [3] 3");
}

test "native: connection failure interrupts child channels and preserves its accepted diagnostic" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.multiplex [] port.open 'p set " ++
        "p portprobe.channel 1 port.call 'a set p portprobe.channel 2 port.call 'b set " ++
        "a portprobe.channel-stream [] port.begin 'x set x portprobe.channel-input port.endpoint 'xi set " ++
        "xi [] port.send xi [1] port.send 2 portprobe.await-blocked b portprobe.channel-stream [] port.begin 'y set " ++
        "p portprobe.disconnect [] port.begin 'f set f wrap (port.await) @attempt 'err at 'kind at " ++
        "p wrap (portprobe.channel-count [] port.call) @attempt 'err at 'kind at " ++
        "x wrap (port.await) @attempt 'err at 'kind at y wrap (port.await) @attempt 'err at 'kind at p port.close " ++
        "f portprobe.disconnect-event port.endpoint 'events set events port.receive 'value at " ++
        "events wrap (port.receive) @attempt 'err at 'kind at f wrap (port.await) @attempt 'err at 'kind at " ++
        "a wrap (portprobe.channel-stream [] port.begin) @attempt 'err at 'kind at " ++
        "f port.close x port.close y port.close portprobe.cleaned", "'io 'io 'cancelled 'cancelled 9 'io 'io 'io 3");
}

test "native: resource failure preserves allocation exhaustion and retirement in either report order" {
    for ([_]u32{ 1, 8 }) |workers| {
        var output = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer output.deinit();
        var diagnostics = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer diagnostics.deinit();
        var runtime = try session.Session.initWithHostConfig(std.testing.allocator, &.{}, .{
            .io = std.testing.io,
            .output = &output.writer,
            .diagnostics = &diagnostics.writer,
            .ecl_path = native_fixture.directory,
        }, .{ .worker_pool = workers });
        defer runtime.deinit();
        for ([_][]const u8{ "0", "1" }) |order| for ([_][]const u8{ "port.await", "port.result" }) |observe| {
            try expectOk(&runtime, "portprobe.reset portprobe.multiplex [] port.open 'p set");
            const source = try std.fmt.allocPrint(std.testing.allocator, "p portprobe.fatal-allocation-failure {s} port.begin {s}", .{ order, observe });
            defer std.testing.allocator.free(source);
            try std.testing.expectError(error.OutOfMemory, runtime.runUnit("native-resource-oom.ecl", source));
            try expectErrorContains(&runtime, "p portprobe.channel-count [] port.begin", &.{"'kind 'io"});
            try expectOk(&runtime, "p port.close portprobe.cleaned");
            var display = try runtime.stackDisplay();
            defer display.deinit();
            try std.testing.expectEqualStrings("1", display.bytes());
            try expectOk(&runtime, "pop");
        };
    }
}

test "native: connection failure reaches transferred channel owners" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.multiplex [] port.open 'p set " ++
        "p portprobe.channel 1 port.call 'a set a wrap [] (portprobe.channel-stream [] port.begin 'x set " ++
        "x portprobe.channel-input port.endpoint 'input set input [] port.send input [1] port.send x port.await) @give 'task set " ++
        "2 portprobe.await-blocked p portprobe.disconnect [] port.begin 'f set f wrap (port.await) @attempt 'err at 'kind at " ++
        "task task.await 'err at 'kind at p port.close f port.close a type portprobe.cleaned", "'io 'cancelled 'port 2");
}

test "native: discarded channel results and scope exit join their dependent controllers" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "[] (portprobe.multiplex [] port.open 'p set " ++
        "p portprobe.channel 1 port.begin 'discarded set discarded port.await discarded port.close " ++
        "p portprobe.channel-count [] port.call p portprobe.channel 2 port.call 'a set " ++
        "a portprobe.channel-stream [] port.begin 'x set x portprobe.channel-input port.endpoint 'input set " ++
        "input [] port.send input [1] port.send 2 portprobe.await-blocked) @spawn task.await 'ok at first portprobe.cleaned", "0 3");
}

test "native: opaque buffers defer native work until their independent control lane completes it" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.device [] port.open 'd set d portprobe.buffer 3 port.call 'b set " ++
        "b portprobe.compute [] port.begin 'x set 1 portprobe.await-blocked d portprobe.device-status [] port.call " ++
        "b portprobe.buffer-update [2 9] port.call pop b portprobe.complete-work [] port.call pop " ++
        "x port.result x port.await x port.close d portprobe.device-status [] port.call " ++
        "d port.close b type portprobe.cleaned", "[1 1 0] 30 [1 0 1] 'port 2");
}

test "native: buffer cancellation joins backend work before acknowledging lane reuse" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.device [] port.open 'd set d portprobe.buffer 4 port.call 'b set " ++
        "b portprobe.compute [] port.begin 'x set 1 portprobe.await-blocked x port.cancel " ++
        "x wrap (port.await) @attempt 'err at 'kind at x port.close d portprobe.device-status [] port.call " ++
        "b portprobe.compute [] port.begin 'y set 2 portprobe.await-blocked b portprobe.complete-work [] port.call pop " ++
        "y port.result y port.close d portprobe.device-status [] port.call d port.close portprobe.cleaned", "'cancelled [1 0 0] 32 [1 0 1] 2");
}

test "native: queued buffer cancellation never starts backend work" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 4, 1, "portprobe.device [] port.open 'd set d portprobe.buffer 2 port.call 'b set " ++
        "b portprobe.compute [] port.begin 'x set 1 portprobe.await-blocked b portprobe.compute [] port.begin 'y set " ++
        "y port.cancel y wrap (port.await) @attempt 'err at 'kind at y port.close " ++
        "b portprobe.complete-work [] port.call pop x port.result x port.close " ++
        "d portprobe.device-status [] port.call d port.close portprobe.cleaned", "'cancelled 16 [1 0 1] 2");
}

test "native: buffer children progress while a sibling is cancelled" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.device [] port.open 'd set " ++
        "d portprobe.buffer 1 port.call 'a set d portprobe.buffer 5 port.call 'b set " ++
        "a portprobe.compute [] port.begin 'x set b portprobe.compute [] port.begin 'y set 2 portprobe.await-blocked " ++
        "x port.cancel x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "d portprobe.device-status [] port.call b portprobe.complete-work [] port.call pop y port.result y port.close " ++
        "d port.close portprobe.cleaned", "'cancelled [2 1 0] 40 3");
}

test "native: device closure joins backend work on transferred buffer children" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.device [] port.open 'd set d portprobe.buffer 1 port.call 'b set " ++
        "b wrap [] (portprobe.compute [] port.call) @give 'task set 1 portprobe.await-blocked " ++
        "d port.close task task.await 'err at 'kind at b type portprobe.cleaned", "'cancelled 'port 2");
}

test "native: task scope exit joins outstanding native buffer work" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "[] (portprobe.device [] port.open 'd set " ++
        "d portprobe.buffer 1 port.call 'b set b portprobe.compute [] port.begin 'x set 1 portprobe.await-blocked) " ++
        "@spawn task.await 'ok at len portprobe.cleaned", "0 2");
}

test "native: discarded buffer results and failed initialization release device ownership" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.device [] port.open 'd set " ++
        "d portprobe.buffer 1 port.begin 'x set x port.await x port.close d portprobe.device-status [] port.call " ++
        "d wrap (portprobe.buffer 256 port.call) @attempt 'err at 'kind at d portprobe.device-status [] port.call " ++
        "d port.close portprobe.cleaned", "[0 0 0] 'io [0 0 0] 3");
}

test "native: broker delivery messages carry one-time acknowledgement capabilities" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.broker [] port.open 'p set p portprobe.deliver [] port.begin 'x set " ++
        "x portprobe.deliveries port.endpoint 'r set r port.receive 'value at " ++
        "dup 'payload at len swap 'delivery at 'd set r port.receive 'kind at x port.result pop x port.close " ++
        "d portprobe.delivery-info [] port.call d portprobe.acknowledge [] port.call " ++
        "d wrap (portprobe.acknowledge [] port.call) @attempt 'err at 'kind at " ++
        "p wrap (portprobe.redeliver [] port.call) @attempt 'err at 'kind at " ++
        "p portprobe.broker-status [] port.call p port.close d type portprobe.cleaned", "0 'eof {'id 1 'attempt 1} 1 'contract 'contract ('acknowledged 1 1) 'port 2");
}

test "native: explicit broker redelivery invalidates the previous acknowledgement" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.broker [] port.open 'p set p portprobe.deliver [] port.begin 'x set " ++
        "x portprobe.deliveries port.endpoint port.receive 'value at 'delivery at 'old set x port.result pop x port.close " ++
        "p portprobe.redeliver [] port.call 'next set " ++
        "old wrap (portprobe.acknowledge [] port.call) @attempt 'err at 'kind at " ++
        "next portprobe.delivery-info [] port.call next portprobe.acknowledge [] port.call old port.close " ++
        "p portprobe.broker-status [] port.call p port.close portprobe.cleaned", "'contract {'id 1 'attempt 2} 2 ('acknowledged 2 1) 3");
}

test "native: competing broker acknowledgements have one winner under admission pressure" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .max_operations = 1, .message_capacity = 1 }, "portprobe.broker [] port.open 'p set p portprobe.deliver [] port.begin 'x set " ++
        "x portprobe.deliveries port.endpoint port.receive 'value at 'delivery at 'd set x port.result pop x port.close " ++
        "d wrap (portprobe.acknowledge [] port.call) @spawn 'left set " ++
        "d wrap (portprobe.acknowledge [] port.call) @spawn 'right set " ++
        "left task.await 'a set right task.await 'b set a 'ok dict.has? b 'ok dict.has? + " ++
        "a 'err dict.has? (a 'err at 'kind at) (b 'err at 'kind at) if " ++
        "p portprobe.broker-status [] port.call p port.close portprobe.cleaned", "1 'contract ('acknowledged 1 1) 2");
}

test "native: discarded broker messages clean delivery owners without automatic redelivery" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.broker [] port.open 'p set p portprobe.deliver [] port.begin 'x set x port.await x port.close " ++
        "p portprobe.broker-status [] port.call p portprobe.redeliver [] port.call 'd set " ++
        "d portprobe.delivery-info [] port.call p port.close portprobe.cleaned", "('pending 1 0) {'id 1 'attempt 2} 3");
}

test "native: given broker deliveries acknowledge and close in the receiving task scope" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.broker [] port.open 'p set p portprobe.deliver [] port.begin 'x set " ++
        "x portprobe.deliveries port.endpoint port.receive 'value at 'delivery at 'd set x port.result pop x port.close " ++
        "d wrap [] (portprobe.acknowledge [] port.call) @give task.await 'ok at " ++
        "p portprobe.broker-status [] port.call d wrap (portprobe.delivery-info [] port.call) @attempt 'err at 'kind at " ++
        "p port.close portprobe.cleaned", "[1] ('acknowledged 1 0) 'io 2");
}

test "native: broker acknowledgement races explicit redelivery atomically" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.broker [] port.open 'p set p portprobe.deliver [] port.begin 'x set " ++
        "x portprobe.deliveries port.endpoint port.receive 'value at 'delivery at 'd set x port.result pop x port.close " ++
        "d wrap (portprobe.acknowledge [] port.call) @spawn 'left set p wrap (portprobe.redeliver [] port.call) @spawn 'right set " ++
        "left task.await 'a set right task.await 'b set a 'ok dict.has? b 'ok dict.has? + " ++
        "p portprobe.broker-status [] port.call a 'ok dict.has? (['acknowledged 1 1]) (['pending 2 1]) if match? " ++
        "p port.close portprobe.cleaned a 'ok dict.has? (2) (3) if =", "1 1 1");
}

test "native: storage cursors stream rows and position through registered operations" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .max_operations = 2, .ring_capacity = 1, .message_capacity = 1 }, "portprobe.storage [] port.open 's set s portprobe.query [1 2] port.call 'c set " ++
        "c portprobe.rows [] port.begin 'x set x portprobe.row port.endpoint 'r set " ++
        "r port.receive 'value at 'id at r port.receive 'value at 'value at r port.receive 'kind at " ++
        "x port.result pop x port.close c portprobe.position 2 port.call " ++
        "c portprobe.rows [] port.begin 'y set y portprobe.row port.endpoint 'r set " ++
        "r port.receive 'value at 'value at r port.receive 'kind at y port.result pop y port.close " ++
        "c port.close s port.close portprobe.cleaned", "1 2 'eof 2 2 'eof 2");
}

test "native: cancelling a full cursor queue leaves its storage session usable" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .max_operations = 2, .message_capacity = 1 }, "portprobe.storage [] port.open 's set s portprobe.query [0 4] port.call 'c set " ++
        "c portprobe.rows [] port.begin 'x set 1 portprobe.await-blocked x port.cancel " ++
        "x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "s portprobe.storage-status [] port.call s port.close portprobe.cleaned", "'cancelled [0 0 0] 2");
}

test "native: storage transactions are exclusive and commit does not imply durability" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.storage [] port.open 's set s portprobe.transaction [] port.call 't set " ++
        "s wrap (portprobe.transaction [] port.call) @attempt 'err at 'kind at " ++
        "t portprobe.transaction-write 41 port.call s portprobe.storage-status [] port.call " ++
        "t portprobe.commit [] port.call t wrap (portprobe.commit [] port.call) @attempt 'err at 'kind at " ++
        "s portprobe.storage-status [] port.call s portprobe.durable [] port.call t port.close " ++
        "s portprobe.storage-status [] port.call s port.close portprobe.cleaned", "'contract 41 [0 0 1] 41 'contract [41 0 1] 41 [41 41 0] 2");
}

test "native: discarded transaction results release exclusivity before exchange close returns" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.storage [] port.open 's set s portprobe.transaction [] port.begin 'x set " ++
        "x port.await x port.close s portprobe.storage-status [] port.call " ++
        "s portprobe.transaction [] port.call 't set s port.close " ++
        "t wrap (portprobe.transaction-write 1 port.call) @attempt 'err at 'kind at portprobe.cleaned", "[0 0 0] 'io 3");
}

test "native: transferred transactions release parent state during cancellation cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.storage [] port.open 's set s portprobe.transaction [] port.call 't set " ++
        "t wrap [] (portprobe.transaction-wait [] port.call) @give 'task set 1 portprobe.await-blocked " ++
        "s port.close task task.await 'err at 'kind at portprobe.cleaned", "'cancelled 2");
}

test "native: child creation rejects an undeclared same-name native kind" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.storage [] port.open 's set " ++
        "s wrap (portprobe.lookalike-child [] port.call) @attempt 'err at 'kind at " ++
        "s portprobe.storage-status [] port.call s port.close portprobe.cleaned", "'domain [0 0 0] 1");
}

test "native: parent state is unavailable to root and independent resources" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "[] (portprobe.orphan-cursor [0 1] port.open) @attempt 'err at 'kind at 1 portprobe.await-cleaned " ++
        "portprobe.storage [] port.open 's set " ++
        "s wrap (portprobe.detached-query [0 1] port.call) @attempt 'err at 'kind at s port.close portprobe.cleaned", "'domain 'io 3");
}

test "native: result publication gives an independent child to the claiming scope" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.child 7 port.call 'c set " ++
        "p port.close c portprobe.noop [] port.call len c port.close portprobe.cleaned", "0 2");
}

test "native: message publication gives an independent child to the receiving scope" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.child-event [] port.begin 'x set x port.await " ++
        "x portprobe.receiver port.endpoint port.receive 'value at 'c set x port.close p port.close " ++
        "c portprobe.noop [] port.call len c port.close portprobe.cleaned", "0 2");
}

test "native: discarded results and builder values join provisional child cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.child [] port.begin dup port.await port.close " ++
        "portprobe.cleaned p portprobe.discard-child [] port.call p port.close portprobe.cleaned", "1 42 3");
}

test "native: dependent children join before parent closure and remain closed identities" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.dependent-child [] port.call 'c set " ++
        "p port.close c wrap (portprobe.noop [] port.call) @attempt 'err at 'kind at " ++
        "c port.close c type portprobe.cleaned", "'io 'port 2");
}

test "native: transferring a dependent child retains its parent dependency" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.dependent-child [] port.call 'c set " ++
        "c wrap [] (portprobe.blocked [] port.call) @give 't set 1 portprobe.await-blocked " ++
        "p port.close t task.await 'err at 'kind at portprobe.cleaned", "'cancelled 2");
}

test "native: queued child messages are cleaned when their exchange closes" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.child-event [] port.begin dup port.await port.close " ++
        "portprobe.cleaned p port.close portprobe.cleaned", "1 2");
}

test "native: a result publishes multiple child owners atomically" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.child-pair [] port.call 'cs set p port.close " ++
        "cs (portprobe.noop [] port.call len) each cs (dup port.close) each pop portprobe.cleaned", "[0 0] 3");
}

test "native: cancellation interrupts provisional child initialization and restores the lane" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.child 250 port.begin 'x set " ++
        "1 portprobe.await-blocked x port.cancel x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "p portprobe.noop [] port.call len p port.close portprobe.cleaned", "'cancelled 0 2");
}

test "native: competing child result claims publish into exactly one task scope" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set p portprobe.child [] port.begin 'x set " ++
        "x wrap (port.result) @spawn 'a set x wrap (port.result) @spawn 'b set " ++
        "a task.await 'ra set b task.await 'rb set ra 'ok dict.has? rb 'ok dict.has? + " ++
        "ra 'err dict.has? (ra 'err at 'kind at) (rb 'err at 'kind at) if " ++
        "x port.close p port.close portprobe.cleaned", "1 'contract 2");
}

test "native: task scope exit joins unclaimed independent children" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "[] (portprobe.factory [] port.open dup portprobe.child [] port.begin dup port.await pop pop) @spawn " ++
        "task.await 'ok at len portprobe.cleaned", "0 2");
}

test "native: reply endpoint construction cannot widen direction or completion lifetime" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgram(workers, 4, "portprobe.factory [] port.open 'p set " ++
        "p wrap (portprobe.invalid-reply [] port.call) @attempt 'err at 'kind at " ++
        "p portprobe.reply-result [] port.call dup wrap (port.receive) @attempt 'err at 'kind at " ++
        "swap wrap ([] port.send) @attempt 'err at 'kind at p port.close portprobe.cleaned", "'domain 'type 'io 1");
}

test "native: RPC cancellation discards queued reply capabilities and restores admission" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 64 }, "portprobe.factory [] port.open 'p set p portprobe.rpc [] port.begin 'x set " ++
        "x portprobe.receiver port.endpoint port.receive pop x port.cancel " ++
        "x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "p portprobe.noop [] port.call pop p port.close portprobe.cleaned", "'cancelled 1");
}

test "native: independent controller lanes cannot overlap a resource message receive" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.factory [] port.open 'p set " ++
        "p portprobe.resource-messages [] port.begin 'x set p portprobe.resource-compete-messages [] port.begin 'y set " ++
        "x wrap (port.await) @spawn 'a set y wrap (port.await) @spawn 'b set " ++
        "a b pair task.await-any nip 'err at 'kind at x port.cancel y port.cancel " ++
        "a task.await pop b task.await pop x port.close y port.close p port.close portprobe.cleaned", "'contract 1");
}

test "native: independent controller lanes cannot overlap a resource byte read" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramAtCapacity(workers, 2, 1, "portprobe.factory [] port.open 'p set " ++
        "p portprobe.resource-bytes [] port.begin 'x set p portprobe.resource-compete-bytes [] port.begin 'y set " ++
        "x wrap (port.await) @spawn 'a set y wrap (port.await) @spawn 'b set " ++
        "a b pair task.await-any nip 'err at 'kind at x port.cancel y port.cancel " ++
        "a task.await pop b task.await pop x port.close y port.close p port.close portprobe.cleaned", "'contract 1");
}

test "native: datagrams preserve empty payload metadata and explicit loss events" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 64 }, "portprobe.factory [] port.open 'p set p portprobe.datagram [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint 's set s wrap ([0] 4097 take port.send) @attempt 'err at 'kind at " ++
        "s [] port.send x portprobe.receiver port.endpoint 'r set r port.receive 'value at " ++
        "dup 'payload at len swap dup 'address at swap 'port at " ++
        "r port.receive 'value at dup 'kind at swap 'count at r port.receive 'kind at " ++
        "x port.result len x port.close p port.close portprobe.cleaned", "'overflow 0 '127.0.0.1 42 'loss 1 'eof 0 1");
}

test "native: watcher configuration progresses independently of a subscription and disconnect" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 64 }, "portprobe.factory [] port.open 'p set p portprobe.watch [] port.begin 'x set " ++
        "x portprobe.receiver port.endpoint 'r set r port.receive 'value at 'mode at " ++
        "p portprobe.watch-config 7 port.call x portprobe.sender port.endpoint [] port.send " ++
        "r port.receive 'value at dup 'sequence at swap 'mode at " ++
        "r wrap (port.receive) @attempt 'err at 'kind at x wrap (port.await) @attempt 'err at 'kind at " ++
        "x port.close p port.close portprobe.cleaned", "0 7 1 7 'io 'io 1");
}

test "native: cancelled watcher subscriptions leave configuration and admission reusable" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.factory [] port.open 'p set p portprobe.watch [] port.begin 'x set " ++
        "x portprobe.receiver port.endpoint port.receive pop x port.cancel " ++
        "x wrap (port.await) @attempt 'err at 'kind at x port.close " ++
        "p portprobe.watch-config 9 port.call p portprobe.noop [] port.call pop p port.close portprobe.cleaned", "'cancelled 9 1");
}

test "native: watcher resource and exchange transfer atomically and join scope cleanup" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1 }, "portprobe.factory [] port.open 'p set p portprobe.watch [] port.begin 'x set " ++
        "x portprobe.receiver port.endpoint 'r set r port.receive pop " ++
        "p x pair [] (pop pop) @give task.await 'ok at len " ++
        "r wrap (port.receive) @attempt 'err at 'kind at x port.close p port.close portprobe.cleaned", "0 'cancelled 1");
}

test "native: datagram exchange scope exit interrupts full output and preserves its resource" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 64 }, "portprobe.factory [] port.open 'p set p portprobe.datagram [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint [] port.send " ++
        "x wrap [] (pop) @give task.await 'ok at len " ++
        "p portprobe.noop [] port.call pop x port.close p port.close portprobe.cleaned", "0 1");
}

test "native: explicit message consumption releases pressure without invalidating builder copies" {
    for ([_]u32{ 1, 8 }) |workers| try expectPortProgramWithLimits(workers, .{ .message_capacity = 1, .message_queue_bytes = 8 }, "portprobe.factory [] port.open 'p set p portprobe.transform-message [] port.begin 'x set " ++
        "x portprobe.sender port.endpoint 42 port.send x portprobe.receiver port.endpoint 'r set " ++
        "r port.receive 'value at r port.receive 'kind at x port.result len " ++
        "x port.close p port.close portprobe.cleaned", "42 'eof 0 1");
}
