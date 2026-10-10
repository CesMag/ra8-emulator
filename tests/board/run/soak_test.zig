//! Tests for src/board/run/soak.zig.
const std = @import("std");
const ra8 = @import("ra8");
const soak = ra8.board.run.soak;

test "an unarmed soak ignores events and prints nothing" {
    var state = soak.Soak{};
    state.note(.watchdog_reset, 5);
    try std.testing.expect(!state.ended());
    var buffer: [96]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try state.line(&stream);
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "an armed soak keeps its first event and ends the run on it" {
    var state = soak.Soak{ .armed = true };
    try std.testing.expect(!state.ended());
    state.note(.iwdt_reset, 3_600_000_000_123);
    state.note(.watchdog_reset, 3_700_000_000_000);
    try std.testing.expect(state.ended());
    try std.testing.expectEqual(soak.Kind.iwdt_reset, state.event.?.kind);
    var buffer: [96]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try state.line(&stream);
    try std.testing.expectEqualStrings("soak: stopped on watchdog reset (IWDT) at 3600.000000123 s virtual, core 0\n", stream.buffered());
}

test "an armed soak with nothing to report says so" {
    const state = soak.Soak{ .armed = true };
    var buffer: [96]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try state.line(&stream);
    try std.testing.expectEqualStrings("soak: no events\n", stream.buffered());
}

test "a placed event names the PC it stopped on and the RTC date" {
    var state = soak.Soak{ .armed = true };
    state.place(0x1234, null);
    try std.testing.expect(state.event == null);
    state.note(.watchdog_reset, 2 * 3600 * 1_000_000_000);
    state.place(0x0200_0F3A, .{ .second = 5, .minute = 4, .hour = 3, .day = 29, .month = 2, .year = 28 });
    var buffer: [160]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try state.line(&stream);
    try std.testing.expectEqualStrings("soak: stopped on watchdog reset (WDT) at 7200.000000000 s virtual, core 0, pc 0x02000F3A, rtc 2028-02-29 03:04:05\n", stream.buffered());
    stream.end = 0;
    state.place(0x10, null);
    try state.line(&stream);
    try std.testing.expectEqualStrings("soak: stopped on watchdog reset (WDT) at 7200.000000000 s virtual, core 0, pc 0x00000010\n", stream.buffered());
}
