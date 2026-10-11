//! Tests for src/interfaces/rpc/session/rtc.zig and
//! src/session/board/rtc.zig (RA8EMU-809) on a real harness: the rtc
//! request returns the board's calendar in one snapshot.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const rtc = ra8.rpc.session.rtc;
const board_rtc = ra8.session.board.rtc;

const image = "tests/fixtures/fpu/fp_basic.elf";

fn ask(context: *server.Context) !ra8.rpc.session.rpc.RtcReport {
    return switch (rtc.rtc(context, .{ .core = .cpu0 })) {
        .ok => |report| report,
        .err => error.Refused,
    };
}

test "a seeded clock reports its date and that it runs" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    context.clock = board_rtc.clock(opened.board());
    opened.board().clock.seed(.{ .year = 26, .month = 10, .day = 8, .hour = 9, .minute = 47, .second = 5 });
    const report = try ask(&context);
    try std.testing.expectEqual(@as(u8, 1), report.valid);
    try std.testing.expectEqual(@as(u8, 1), report.running);
    try std.testing.expectEqual(@as(u16, 2026), report.year);
    try std.testing.expectEqual(@as(u8, 10), report.month);
    try std.testing.expectEqual(@as(u8, 8), report.day);
    try std.testing.expectEqual(@as(u8, 9), report.hour);
    try std.testing.expectEqual(@as(u8, 47), report.minute);
    try std.testing.expectEqual(@as(u8, 5), report.second);
}

test "a clock nobody started reports the reset date, stopped" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    context.clock = board_rtc.clock(opened.board());
    const report = try ask(&context);
    try std.testing.expectEqual(@as(u8, 0), report.running);
    try std.testing.expectEqual(@as(u8, 1), report.valid);
    try std.testing.expectEqual(@as(u16, 2000), report.year);
    try std.testing.expectEqual(@as(u8, 1), report.month);
    try std.testing.expectEqual(@as(u8, 1), report.day);
}

test "counters firmware left invalid report no date" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    context.clock = board_rtc.clock(opened.board());
    opened.board().clock.reg[ra8.chip.periph.rtc.off.moncnt] = 0x13;
    const report = try ask(&context);
    try std.testing.expectEqual(@as(u8, 0), report.valid);
    try std.testing.expectEqual(@as(u16, 0), report.year);
}

test "a server without a clock refuses rtc" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try std.testing.expectError(error.Refused, ask(&context));
}
