//! Covers src/chip/core/long_shift.zig: one encoding of each form, decoded and
//! run over a plain register file. Encodings are arm-none-eabi-as 13.3's.
const std = @import("std");
const ra8 = @import("ra8");
const long_shift = ra8.chip.core.long_shift;

fn runOn(first: u16, second: u16, regs: *long_shift.Regs) !bool {
    const form = long_shift.decode(first, second) orelse return error.NotALongShift;
    return long_shift.run(form, regs);
}

test "lsll by an immediate shifts the pair" {
    var regs = std.mem.zeroes(long_shift.Regs);
    regs[2] = 0xC000_0001;
    regs[3] = 0x0000_0001;
    try std.testing.expect(!try runOn(0xEA52, 0x038F, &regs)); // lsll r2, r3, #2
    try std.testing.expectEqual(@as(u32, 0x0000_0004), regs[2]);
    try std.testing.expectEqual(@as(u32, 0x0000_0007), regs[3]);
}

test "asrl by a register reads the signed amount and leaves Rm alone" {
    var regs = std.mem.zeroes(long_shift.Regs);
    regs[2] = 0;
    regs[3] = 0x8000_0000;
    regs[12] = 4;
    try std.testing.expect(!try runOn(0xEA52, 0xC32D, &regs)); // asrl r2, r3, r12
    try std.testing.expectEqual(@as(u32, 0), regs[2]);
    try std.testing.expectEqual(@as(u32, 0xF800_0000), regs[3]);
    try std.testing.expectEqual(@as(u32, 4), regs[12]);
}

test "a single-register saturating shift reports the clamp" {
    var regs = std.mem.zeroes(long_shift.Regs);
    regs[2] = 0x0800_0000;
    try std.testing.expect(try runOn(0xEA52, 0x1F4F, &regs)); // uqshl r2, #5
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), regs[2]);
}

test "a pair saturating shift reports the clamp" {
    var regs = std.mem.zeroes(long_shift.Regs);
    regs[3] = 0x0800_0000;
    try std.testing.expect(try runOn(0xEA53, 0x134F, &regs)); // uqshll r2, r3, #5
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), regs[2]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), regs[3]);
}

test "ordinary shifted-register encodings are not long shifts" {
    try std.testing.expect(long_shift.decode(0xEA43, 0x7392) == null); // orr.w r3, r3, r2, lsr #30
    try std.testing.expect(long_shift.decode(0xEA02, 0x038F) == null); // and.w r3, r2, pc, lsl #2
}
