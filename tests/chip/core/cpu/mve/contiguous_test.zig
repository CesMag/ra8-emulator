//! Covers src/chip/core/cpu/mve/contiguous.zig.
const std = @import("std");
const ra8 = @import("ra8");
const contiguous = ra8.chip.core.cpu.mve.contiguous;

test "the offset scales by the element size" {
    const p = contiguous.plan(.{ .base = 0x100, .imm7 = 3, .size = .word, .add = true, .pre = true, .wback = false });
    try std.testing.expectEqual(@as(u32, 0x10C), p.start);
    try std.testing.expectEqual(@as(?u32, null), p.wback);
}

test "post-indexing starts at the base and writes the offset address back" {
    const p = contiguous.plan(.{ .base = 0x100, .imm7 = 2, .size = .half, .add = false, .pre = false, .wback = true });
    try std.testing.expectEqual(@as(u32, 0x100), p.start);
    try std.testing.expectEqual(@as(?u32, 0xFC), p.wback);
}

test "element addresses step by the element size" {
    try std.testing.expectEqual(@as(u32, 0x10E), contiguous.address(0x100, .half, 7));
    try std.testing.expectEqual(@as(u32, 0x10C), contiguous.address(0x100, .word, 3));
}

test "inactive elements read as zero" {
    try std.testing.expectEqual(@as(u128, 0x0000_2222), contiguous.zeroInactive(0x1111_2222, 0x0003, .half));
    try std.testing.expectEqual(@as(u128, 0x33_00), contiguous.zeroInactive(0x33_44, 0x0002, .byte));
}

test "a signed load extends the sign bit of the memory width" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF80), contiguous.element(.{ .value = 0x80, .msize = .byte, .signed = true, .store = false }));
    try std.testing.expectEqual(@as(u32, 0x0000_8000), contiguous.element(.{ .value = 0x8000, .msize = .half, .signed = false, .store = false }));
}

test "a word in memory passes through whole" {
    try std.testing.expectEqual(@as(u32, 0x8000_0001), contiguous.element(.{ .value = 0x8000_0001, .msize = .word, .signed = true, .store = false }));
}

test "a narrowing store drops the bits above the memory width" {
    try std.testing.expectEqual(@as(u32, 0xEF), contiguous.element(.{ .value = 0xDEAD_BEEF, .msize = .byte, .signed = true, .store = true }));
}
