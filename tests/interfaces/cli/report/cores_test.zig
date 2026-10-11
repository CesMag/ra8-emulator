//! Covers the CPU1 lines of src/interfaces/cli/report/cores.zig: what a
//! `--cpu zig` run prints about the second core once it stops.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const report_run = cli_app.report.run;
const Second = ra8.chip.core.second.core.Second;

/// Through a real file, because the SAU half of the report writes to a
/// file writer rather than any writer.
fn reported(second: *const Second, buffer: []u8) ![]const u8 {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile(std.testing.io, "report.txt", .{ .read = true });
    defer file.close(std.testing.io);
    var held: [512]u8 = undefined;
    var writer = file.writer(std.testing.io, &held);
    try report_run.cpu1(&writer.interface, second);
    try writer.interface.flush();
    return buffer[0..try file.readPositionalAll(std.testing.io, buffer, 0)];
}

test "the report says how often CPU1 parked in WFE and what woke it" {
    var second: Second = .{};
    second.state.wait.parks = 3;
    second.state.wait.wakes = .{ .interrupt = 1, .event = 1, .spurious = 1 };
    var buffer: [1024]u8 = undefined;
    const text = try reported(&second, &buffer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "CPU1: parked in WFE 3 time(s), woken 1 by an exception, 1 by SEV, 1 spuriously\n",
    ) != null);
}

test "a CPU1 that never waited reports no parking line" {
    const second: Second = .{};
    var buffer: [1024]u8 = undefined;
    const text = try reported(&second, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "parked in WFE") == null);
}
