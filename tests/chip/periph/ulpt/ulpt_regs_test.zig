//! Covers src/chip/periph/ulpt_regs.zig: which register owns a byte of a ULPT
//! channel, which matters because ULPTCR, ULPTMR1, ULPTMR2 and ULPTMR3 share
//! one word and the three counters above them are 32-bit.
const std = @import("std");
const ra8 = @import("ra8");

const regs = ra8.chip.periph.ulpt_regs;

test "the counter owns four bytes, low byte first" {
    for (0..4) |byte| {
        const place = regs.owner(regs.at.cnt + @as(u32, @intCast(byte))).?;
        try std.testing.expectEqual(regs.Reg.cnt, place.reg);
        try std.testing.expectEqual(@as(u32, @intCast(byte)), place.index);
    }
}

test "the compare values sit above the counter, four bytes each" {
    try std.testing.expectEqual(regs.Reg.cma, regs.owner(regs.at.cma).?.reg);
    try std.testing.expectEqual(regs.Reg.cma, regs.owner(regs.at.cma + 3).?.reg);
    try std.testing.expectEqual(regs.Reg.cmb, regs.owner(regs.at.cmb).?.reg);
    try std.testing.expectEqual(@as(u32, 3), regs.owner(regs.at.cmb + 3).?.index);
}

test "the four control and mode bytes are four registers, not one word" {
    try std.testing.expectEqual(regs.Reg.cr, regs.owner(regs.at.cr).?.reg);
    try std.testing.expectEqual(regs.Reg.mr1, regs.owner(regs.at.mr1).?.reg);
    try std.testing.expectEqual(regs.Reg.mr2, regs.owner(regs.at.mr2).?.reg);
    try std.testing.expectEqual(regs.Reg.mr3, regs.owner(regs.at.mr3).?.reg);
    for ([_]u32{ regs.at.cr, regs.at.mr1, regs.at.mr2, regs.at.mr3, regs.at.ioc }) |offset| {
        try std.testing.expectEqual(@as(u32, 0), regs.owner(offset).?.index);
    }
}

test "nothing owns the bytes past the I/O control register" {
    try std.testing.expectEqual(regs.Reg.ioc, regs.owner(regs.at.ioc).?.reg);
    try std.testing.expect(regs.owner(regs.at.ioc + 1) == null);
    try std.testing.expect(regs.owner(0xFF) == null);
}

test "only the two compare registers are counted as compare touches" {
    try std.testing.expect(regs.isCompare(.cma));
    try std.testing.expect(regs.isCompare(.cmb));
    try std.testing.expect(!regs.isCompare(.cnt));
    try std.testing.expect(!regs.isCompare(.cr));
}
