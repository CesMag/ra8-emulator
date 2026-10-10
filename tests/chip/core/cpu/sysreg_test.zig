//! Covers src/chip/core/cpu/sysreg.zig.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.core.cpu.regs;
const sysreg = ra8.chip.core.cpu.sysreg;
const Regs = regs.Regs;

test "known covers the PSR views, stack pointers, limits, masks, CONTROL and PAC keys" {
    try std.testing.expect(sysreg.known(0) and sysreg.known(3) and sysreg.known(7));
    try std.testing.expect(!sysreg.known(4));
    try std.testing.expect(sysreg.known(8) and sysreg.known(9));
    try std.testing.expect(sysreg.known(10) and sysreg.known(11)); // MSPLIM, PSPLIM
    try std.testing.expect(!sysreg.known(12) and !sysreg.known(15));
    try std.testing.expect(sysreg.known(16) and sysreg.known(20));
    try std.testing.expect(sysreg.known(0x20) and sysreg.known(0x27));
    try std.testing.expect(!sysreg.known(0x88)); // MSP_NS
}

test "xPSR views: IPSR with SYSm[0], flags unless SYSm[2], EPSR reads zero" {
    var r: Regs = .{ .xpsr = 0xF90F_0000 | regs.xpsr_bits.thumb | 0x0F };
    try std.testing.expectEqual(@as(u32, 0xF80F_0000), sysreg.read(&r, 0)); // APSR
    try std.testing.expectEqual(@as(u32, 0xF80F_000F), sysreg.read(&r, 3)); // XPSR
    try std.testing.expectEqual(@as(u32, 0x0F), sysreg.read(&r, 5)); // IPSR
    try std.testing.expectEqual(@as(u32, 0), sysreg.read(&r, 6)); // EPSR
}

test "unprivileged thread mode reads zero masks and stack pointers but sees CONTROL" {
    var r: Regs = .{ .control = regs.control_bits.npriv, .primask = 1, .msp = 0x2000_0000 };
    try std.testing.expectEqual(@as(u32, 0), sysreg.read(&r, sysreg.sysm.primask));
    try std.testing.expectEqual(@as(u32, 0), sysreg.read(&r, sysreg.sysm.msp));
    try std.testing.expectEqual(regs.control_bits.npriv, sysreg.read(&r, sysreg.sysm.control));
    sysreg.write(&r, sysreg.sysm.primask, 0b10, 0);
    try std.testing.expectEqual(@as(u32, 1), r.primask);
}

test "APSR writes honour the mask and leave IPSR and EPSR alone" {
    var r: Regs = .{ .xpsr = regs.xpsr_bits.thumb | 0x03 };
    sysreg.write(&r, 0, 0b10, 0xFFFF_FFFF);
    try std.testing.expectEqual(0xF800_0000 | regs.xpsr_bits.thumb | 0x03, r.xpsr);
    sysreg.write(&r, 0, 0b01, 0x000F_0000);
    try std.testing.expectEqual(@as(u32, 0x000F_0000), r.xpsr & 0x000F_0000);
    sysreg.write(&r, 5, 0b10, 0); // IPSR ignores it
    try std.testing.expectEqual(@as(u32, 0x03), r.xpsr & regs.xpsr_bits.ipsr);
}

test "BASEPRI_MAX only raises the masking priority" {
    var r: Regs = .{};
    sysreg.write(&r, sysreg.sysm.basepri_max, 0b10, 0x40);
    try std.testing.expectEqual(@as(u32, 0x40), r.basepri);
    sysreg.write(&r, sysreg.sysm.basepri_max, 0b10, 0x80);
    try std.testing.expectEqual(@as(u32, 0x40), r.basepri);
    sysreg.write(&r, sysreg.sysm.basepri_max, 0b10, 0);
    try std.testing.expectEqual(@as(u32, 0x40), r.basepri);
    sysreg.write(&r, sysreg.sysm.basepri_max, 0b10, 0x20);
    try std.testing.expectEqual(@as(u32, 0x20), r.basepri);
}

test "FAULTMASK cannot be set from HardFault but can be cleared" {
    var r: Regs = .{ .xpsr = 3, .faultmask = 1 };
    sysreg.write(&r, sysreg.sysm.faultmask, 0b10, 0);
    try std.testing.expectEqual(@as(u32, 0), r.faultmask);
    sysreg.write(&r, sysreg.sysm.faultmask, 0b10, 1);
    try std.testing.expectEqual(@as(u32, 0), r.faultmask);
}

test "CONTROL: SPSEL changes from thread mode only, and switches SP" {
    var r: Regs = .{ .msp = 0x2000_1000, .psp = 0x2000_2000 };
    sysreg.write(&r, sysreg.sysm.control, 0b10, 0xFFFF_FFF2);
    try std.testing.expectEqual(@as(u32, 0xF2), r.control);
    try std.testing.expectEqual(@as(u32, 0x2000_2000), r.sp());
    r.xpsr = 0x0F; // SysTick handler
    sysreg.write(&r, sysreg.sysm.control, 0b10, 0x5);
    try std.testing.expectEqual(@as(u32, 0x7), r.control);
}

test "CONTROL PACBTI enables are writable only by privileged code" {
    const pacbti = regs.control_bits.pac_en | regs.control_bits.bti_en |
        regs.control_bits.upac_en | regs.control_bits.ubti_en;
    var r: Regs = .{};
    sysreg.write(&r, sysreg.sysm.control, 0b10, pacbti);
    try std.testing.expectEqual(pacbti, sysreg.read(&r, sysreg.sysm.control));

    r.control |= regs.control_bits.npriv;
    sysreg.write(&r, sysreg.sysm.control, 0b10, 0);
    try std.testing.expectEqual(pacbti | regs.control_bits.npriv, r.control);
}

test "MSPLIM and PSPLIM keep bits 31:3 and are privileged only" {
    var r: Regs = .{};
    sysreg.write(&r, sysreg.sysm.msplim, 0b10, 0x2200_0107);
    sysreg.write(&r, sysreg.sysm.psplim, 0b10, 0x2210_000C);
    try std.testing.expectEqual(@as(u32, 0x2200_0100), sysreg.read(&r, sysreg.sysm.msplim));
    try std.testing.expectEqual(@as(u32, 0x2210_0008), sysreg.read(&r, sysreg.sysm.psplim));
    r.control = regs.control_bits.npriv;
    sysreg.write(&r, sysreg.sysm.psplim, 0b10, 0x2300_0000);
    try std.testing.expectEqual(@as(u32, 0x2210_0008), r.psplim);
    try std.testing.expectEqual(@as(u32, 0), sysreg.read(&r, sysreg.sysm.psplim));
}

test "the eight PAC key system registers are privileged read-write words" {
    var r: Regs = .{};
    sysreg.write(&r, 0x20, 0b10, 0x1122_3344);
    sysreg.write(&r, 0x23, 0b10, 0x5566_7788);
    sysreg.write(&r, 0x24, 0b10, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), sysreg.read(&r, 0x20));
    try std.testing.expectEqual(@as(u32, 0x5566_7788), r.pac_key_p[3]);
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), r.pac_key_u[0]);
    r.control = regs.control_bits.npriv;
    sysreg.write(&r, 0x20, 0b10, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), r.pac_key_p[0]);
    try std.testing.expectEqual(@as(u32, 0), sysreg.read(&r, 0x20));
}
