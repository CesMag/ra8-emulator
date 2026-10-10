//! Tests for src/chip/periph/afsr.zig.

const std = @import("std");
const ra8 = @import("ra8");
const afsr = ra8.chip.periph.afsr;
const memmap = ra8.chip.core.memmap;

test "a data access in the ITCM window raises PPOISON, bit 19" {
    try std.testing.expectEqual(@as(u32, 0x0008_0000), afsr.ppoison);
    try std.testing.expectEqual(afsr.ppoison, afsr.forData(0));
    try std.testing.expectEqual(afsr.ppoison, afsr.forData(memmap.itcm_end - 4));
}

test "a refusal outside the ITCM window leaves AFSR alone" {
    try std.testing.expectEqual(@as(u32, 0), afsr.forData(memmap.itcm_end));
    try std.testing.expectEqual(@as(u32, 0), afsr.forData(0x6000_0010));
}
