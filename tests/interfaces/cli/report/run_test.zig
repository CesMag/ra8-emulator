//! Covers src/interfaces/cli/report/run.zig: the reduced report a
//! `--cpu zig` run prints after the core stops.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const report_run = cli_app.report.run;
const Store = ra8.chip.core.cpu.memory.store.Store;

/// Run `zigCore` on a fresh board into a scratch file and return what it wrote.
fn zigReport(buf: []u8) ![]const u8 {
    return zigReportWith(buf, .{});
}

/// The same, with a timebase the caller has already charged.
fn zigReportWith(buf: []u8, timebase: ra8.chip.periph.clocks.Clocks) ![]const u8 {
    // Attaching wires the blocks to their power domains, which the report
    // reads; a zig run attaches them over CPU0's own store.
    var store = try Store.init(null);
    defer store.deinit();
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try ra8.board.wiring.attachBlocks(&board, .{ .store = &store });
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile(std.testing.io, "report.txt", .{ .read = true });
    defer file.close(std.testing.io);
    var held: [512]u8 = undefined;
    var writer = file.writer(std.testing.io, &held);
    try report_run.zigCore(&writer.interface, &board, null, timebase, 42, .{});
    try writer.interface.flush();
    const len = try file.readPositionalAll(std.testing.io, buf, 0);
    return buf[0..len];
}

test "a zig run reports the bus and the blocks and says what it leaves out" {
    var buf: [4096]u8 = undefined;
    const text = try zigReport(&buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "peripheral accesses: 0 read, 0 written"));
    try std.testing.expect(std.mem.indexOf(u8, text, "zig core: pend/idle seam counts and stepped-instruction counts are not reported\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "GPIO LEDs: none driven\n") != null);
}

test "a quiet board prints no console line" {
    var buf: [4096]u8 = undefined;
    const text = try zigReport(&buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "SCI console:") == null);
}

/// Run `busErrors` into a scratch file and return what it wrote.
fn busLine(buf: []u8, tally: ra8.chip.periph.fault.status.bus.Tally) ![]const u8 {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile(std.testing.io, "bus.txt", .{ .read = true });
    defer file.close(std.testing.io);
    var held: [256]u8 = undefined;
    var writer = file.writer(std.testing.io, &held);
    try report_run.busErrors(&writer.interface, tally);
    try writer.interface.flush();
    const len = try file.readPositionalAll(std.testing.io, buf, 0);
    return buf[0..len];
}

test "a run that raised no BusFault prints nothing for them" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", try busLine(&buf, .{}));
}

test "a run that raised BusFaults says how many and how many escalated" {
    var buf: [256]u8 = undefined;
    const text = try busLine(&buf, .{ .raised = 3, .escalated = 1 });
    try std.testing.expectEqualStrings("bus faults: 3 raised, 1 escalated to HardFault\n", text);
}
test "a zig run reports its own timebase (RA8EMU-470)" {
    var buf: [4096]u8 = undefined;
    const text = try zigReportWith(&buf, .{ .elapsed = 1000, .cycles = 1000, .ticks = 3, .pends = 2 });
    try std.testing.expect(std.mem.indexOf(u8, text, "time: 1000 cycles elapsed, 3 SysTick periods, 2 pended\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "NEVER TOLD") == null);
}

test "a zig run names the SysTick periods that raised nothing" {
    var buf: [4096]u8 = undefined;
    const text = try zigReportWith(&buf, .{ .elapsed = 500, .cycles = 500, .ticks = 5, .pends = 1, .collapsed = 4 });
    try std.testing.expect(std.mem.indexOf(u8, text, "time: 500 cycles elapsed, 5 SysTick periods, 1 pended, 4 PERIOD(S) THE FIRMWARE WAS NEVER TOLD ABOUT\n") != null);
}
