//! Covers src/chip/periph/drw/regs.zig: the DRW register map, which is a table
//! rather than behaviour, so what there is to check is that the offsets are
//! the ones the HUM names, that they are whole words inside the window, and
//! that no two of them are the same register.
const std = @import("std");
const ra8 = @import("ra8");

const regs = ra8.chip.periph.drw.regs;

/// Every offset the map names, in HUM order.
const every = [_]u32{
    regs.off.control,
    regs.off.control2,
    regs.off.color1,
    regs.off.color2,
    regs.off.size,
    regs.off.pitch,
    regs.off.origin,
    regs.off.cachectl,
    regs.off.dliststart,
};

test "the window is the one DRW claims on the bus" {
    try std.testing.expectEqual(@as(u32, 0x4044_4000), regs.win_base);
    try std.testing.expectEqual(@as(u32, 0x104), regs.win_span);
}

test "every register is a whole word inside the window" {
    for (every) |offset| {
        try std.testing.expectEqual(@as(u32, 0), offset % 4);
        try std.testing.expect(offset < regs.win_span);
    }
}

test "no two names are the same register" {
    for (every, 0..) |offset, index| {
        for (every[index + 1 ..]) |other| try std.testing.expect(offset != other);
    }
}

test "SIZE carries the width and the height in one word" {
    const word = 480 | @as(u32, 272) << regs.field.height_shift;
    try std.testing.expectEqual(@as(u32, 480), word & regs.field.size_mask);
    try std.testing.expectEqual(@as(u32, 272), word >> regs.field.height_shift & regs.field.size_mask);
}

test "HWREVISION is the value the bench reads back" {
    try std.testing.expectEqual(@as(u32, 0x0FBE_0107), regs.hardware_revision);
}
