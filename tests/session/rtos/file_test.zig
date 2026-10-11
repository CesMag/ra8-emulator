//! Tests for src/session/rtos/file.zig: a trace written to text reads back
//! event for event, malformed files are refused, and each core gets its
//! own file.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_hook = ra8.session.step_hook.rtos.hook;
const rtos_file = rtos_hook.file;
const rtos_trace = ra8.session.step_hook.rtos.trace;

const Event = rtos_trace.Event;

/// Two switches, an exception in and out, idle, and one on CPU1.
fn sample() rtos_trace.Trace {
    var trace = rtos_trace.Trace{};
    trace.store(0, 1200, 0x2200_10F0);
    trace.exception(0, 1350, .enter, 14);
    trace.exception(0, 1360, .leave, 14);
    trace.store(0, 1400, 0x2200_11A0);
    trace.store(0, 1500, 0);
    trace.store(1, 1600, 0x2219_0008);
    trace.dropped = 3;
    return trace;
}

fn render(trace: *const rtos_trace.Trace, into: []u8) ![]const u8 {
    var stream: std.Io.Writer = .fixed(into);
    try rtos_file.write(&stream, trace);
    return stream.buffered();
}

test "a written trace reads back event for event, dropped count included" {
    const trace = sample();
    var text: [1024]u8 = undefined;
    const written = try render(&trace, &text);
    var into: [8]Event = undefined;
    const loaded = try rtos_file.read(written, &into);
    try std.testing.expectEqual(@as(usize, 3), loaded.dropped);
    try std.testing.expectEqualSlices(Event, trace.list(), loaded.events);
}

test "the text is the documented line format" {
    const trace = sample();
    var text: [1024]u8 = undefined;
    const written = try render(&trace, &text);
    const expected =
        \\# ra8 rtos trace v1
        \\1200 cpu0 switch 0x220010F0
        \\1350 cpu0 enter 14
        \\1360 cpu0 leave 14
        \\1400 cpu0 switch 0x220011A0
        \\1500 cpu0 idle
        \\1600 cpu1 switch 0x22190008
        \\# dropped 3
        \\
    ;
    try std.testing.expectEqualStrings(expected, written);
}

test "an empty trace round-trips to no events" {
    const trace = rtos_trace.Trace{};
    var text: [128]u8 = undefined;
    var into: [1]Event = undefined;
    const loaded = try rtos_file.read(try render(&trace, &text), &into);
    try std.testing.expectEqual(@as(usize, 0), loaded.events.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.dropped);
}

test "malformed files are refused" {
    var into: [4]Event = undefined;
    const read = rtos_file.read;
    try std.testing.expectError(error.BadHeader, read("", &into));
    try std.testing.expectError(error.BadHeader, read("# ra8 rtos trace v2\n# dropped 0\n", &into));
    try std.testing.expectError(error.Truncated, read("# ra8 rtos trace v1\n1 cpu0 idle\n", &into));
    const bad = [_][]const u8{
        "x cpu0 idle",       "1 cpu2 idle",        "1 cpu0 nap",
        "1 cpu0 switch 10",  "1 cpu0 switch 0xZZ", "1 cpu0 enter",
        "1 cpu0 idle extra", "1 cpu0 leave 70000",
    };
    for (bad) |one| {
        var text: [96]u8 = undefined;
        const file = try std.fmt.bufPrint(&text, "# ra8 rtos trace v1\n{s}\n# dropped 0\n", .{one});
        try std.testing.expectError(error.BadLine, read(file, &into));
    }
    try std.testing.expectError(error.BadLine, read("# ra8 rtos trace v1\n# dropped 0\n1 cpu0 idle\n", &into));
    try std.testing.expectError(error.BadLine, read("# ra8 rtos trace v1\n# dropped many\n", &into));
}

test "more events than the buffer holds is TooMany" {
    const trace = sample();
    var text: [1024]u8 = undefined;
    var into: [2]Event = undefined;
    try std.testing.expectError(error.TooMany, rtos_file.read(try render(&trace, &text), &into));
}

test "CPU0 saves to the path and CPU1 to path.cpu1" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("run.trace", try rtos_file.nameFor("run.trace", 0, &buffer));
    try std.testing.expectEqualStrings("run.trace.cpu1", try rtos_file.nameFor("run.trace", 1, &buffer));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var where: [std.fs.max_path_bytes]u8 = undefined;
    const dir = where[0..try tmp.dir.realPathFile(std.testing.io, ".", &where)];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/run.trace", .{dir});
    const trace = sample();
    try rtos_file.save(std.testing.io, path, 0, &trace);
    try rtos_file.save(std.testing.io, path, 1, &trace);
    var text: [1024]u8 = undefined;
    var into: [8]Event = undefined;
    for ([_][]const u8{ "run.trace", "run.trace.cpu1" }) |name| {
        const got = try tmp.dir.readFile(std.testing.io, name, &text);
        const loaded = try rtos_file.read(got, &into);
        try std.testing.expectEqual(trace.len, loaded.events.len);
    }
}
