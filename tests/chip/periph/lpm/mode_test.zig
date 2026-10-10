const std = @import("std");
const ra8 = @import("ra8");
const mode = ra8.chip.periph.lpm.mode;

test "the five LPMD codes the HUM defines resolve" {
    try std.testing.expectEqual(mode.Mode.active, mode.modeOf(0x0).?);
    try std.testing.expectEqual(mode.Mode.software_standby, mode.modeOf(0x5).?);
    try std.testing.expectEqual(mode.Mode.deep_standby_1, mode.modeOf(0x8).?);
    try std.testing.expectEqual(mode.Mode.deep_standby_2, mode.modeOf(0x9).?);
    try std.testing.expectEqual(mode.Mode.deep_standby_3, mode.modeOf(0xA).?);
}

test "every other LPMD code is undocumented rather than guessed at" {
    for ([_]u4{ 0x1, 0x2, 0x3, 0x4, 0x6, 0x7, 0xB, 0xC, 0xD, 0xE, 0xF }) |code| {
        try std.testing.expect(mode.modeOf(code) == null);
    }
}

test "only System Active leaves the peripherals running" {
    try std.testing.expect(!mode.Mode.active.stopsPeripherals());
    try std.testing.expect(mode.Mode.software_standby.stopsPeripherals());
    try std.testing.expect(mode.Mode.deep_standby_3.stopsPeripherals());
}

test "a mode names itself" {
    try std.testing.expectEqualStrings("sleep", mode.Mode.active.name());
    try std.testing.expectEqualStrings("software standby", mode.Mode.software_standby.name());
}

test "DCSSMODE 0 is the prohibited encoding" {
    try std.testing.expectEqual(mode.SoftStart.prohibited, mode.softStartOf(0));
    try std.testing.expectEqual(mode.SoftStart.us_128, mode.softStartOf(1));
    try std.testing.expectEqual(mode.SoftStart.us_512, mode.softStartOf(3));
    try std.testing.expectEqualStrings("128 us", mode.SoftStart.us_128.name());
}
