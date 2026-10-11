const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;
const half = fpu.half;

test "lane and place are inverses on either half" {
    const word: u32 = 0x1234_5678;
    try std.testing.expectEqual(@as(u16, 0x5678), half.lane(word, false));
    try std.testing.expectEqual(@as(u16, 0x1234), half.lane(word, true));
    try std.testing.expectEqual(word, half.place(word, half.lane(word, true), true));
    try std.testing.expectEqual(word, half.place(word, half.lane(word, false), false));
}

test "every finite half survives a round trip through single" {
    var op: u32 = 0;
    while (op <= 0xFFFF) : (op += 1) {
        if (op & 0x7C00 == 0x7C00) continue;
        var fpscr: fpu.fpscr.Fpscr = .{};
        const wide = half.fromHalf(fpu.format.single, @intCast(op), &fpscr);
        try std.testing.expectEqual(@as(u16, @intCast(op)), half.toHalf(fpu.format.single, wide, &fpscr));
        try std.testing.expectEqual(@as(u32, 0), fpu.case.flagsOf(fpscr));
    }
}

test "under AHP every half survives a round trip through double" {
    var op: u32 = 0;
    while (op <= 0xFFFF) : (op += 1) {
        var fpscr: fpu.fpscr.Fpscr = .{ .ahp = 1 };
        const wide = half.fromHalf(fpu.format.double, @intCast(op), &fpscr);
        try std.testing.expectEqual(@as(u16, @intCast(op)), half.toHalf(fpu.format.double, wide, &fpscr));
        try std.testing.expectEqual(@as(u32, 0), fpu.case.flagsOf(fpscr));
    }
}
