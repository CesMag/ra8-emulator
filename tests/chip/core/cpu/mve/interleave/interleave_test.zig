//! Covers src/chip/core/cpu/mve/interleave/interleave.zig.
const std = @import("std");
const ra8 = @import("ra8");
const interleave = ra8.chip.core.cpu.mve.interleave;

test "the patterns of a set cover every word exactly once" {
    for ([_]u3{ 2, 4 }) |regs| {
        var seen: u16 = 0;
        for (0..regs) |p| for (0..4) |b| {
            const off = interleave.beatOffset(.{ .regs = regs, .pat = @intCast(p), .beat = @intCast(b) });
            seen |= @as(u16, 1) << @intCast(off / 4);
        };
        try std.testing.expectEqual(if (regs == 2) @as(u16, 0x00FF) else 0xFFFF, seen);
    }
}

test "memory element j goes to register j mod n, element j / n" {
    try std.testing.expectEqual(interleave.Slot{ .reg = 1, .elem = 2 }, interleave.slot(2, .byte, 5));
    try std.testing.expectEqual(interleave.Slot{ .reg = 2, .elem = 5 }, interleave.slot(4, .half, 44));
    try std.testing.expectEqual(interleave.Slot{ .reg = 3, .elem = 2 }, interleave.slot(4, .word, 44));
}
