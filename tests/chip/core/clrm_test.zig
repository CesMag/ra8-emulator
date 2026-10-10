//! Covers src/chip/core/clrm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const clrm = ra8.chip.core.csel.clrm;

const base: u32 = 0x2200_0000;

/// movs r1, #5 / cmp r1, r1 / clrm {r1, r2, r3, ip, APSR} / bkpt.
/// The clrm is the one tz_nsc_cgc_usb's CMSE entry stub runs, assembled by
/// arm-none-eabi-as 13.3.rel1 for armv8.1-m.main.
const clear_stub = [_]u8{
    0x05, 0x21, //             2105       movs r1, #5
    0x89, 0x42, //             4289       cmp r1, r1
    0x9F, 0xE8, 0x0E, 0x90, // e89f 900e  clrm {r1, r2, r3, ip, APSR}
    0x00, 0xBE, //             be00       bkpt
};

test "decode reads the stub's list and refuses what is not CLRM" {
    const found = clrm.decode(0xE89F, 0x900E).?;
    try std.testing.expect(found.apsr);
    try std.testing.expect(found.clears(1) and found.clears(2) and found.clears(3) and found.clears(12));
    try std.testing.expect(!found.clears(0) and !found.clears(14));
    try std.testing.expect(clrm.decode(0xE89F, 0x4000).?.clears(14));
    try std.testing.expectEqual(@as(?clrm.Instruction, null), clrm.decode(0xE89E, 0x900E));
    try std.testing.expectEqual(@as(?clrm.Instruction, null), clrm.decode(0xE89F, 0x2001));
    try std.testing.expectEqual(@as(?clrm.Instruction, null), clrm.decode(0xE89F, 0x0000));
}

test "clearedApsr drops the flags and keeps the rest of xPSR" {
    try std.testing.expectEqual(@as(u32, 0x0100_0010), clrm.clearedApsr(0xF90F_0010));
}
