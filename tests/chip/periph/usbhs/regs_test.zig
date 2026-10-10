//! The register bits the USBHS model decodes, pinned to the hardware manual
//! so a model constant can't drift onto a neighbouring bit.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.usbhs.regs;

test "SUREQ is DCPCTR bit 14, not SQMON's bit 6" {
    // HUM 37.2.24 DCPCTR: SUREQ b14, SUREQCLR b11, SQMON b6, CCPL b2.
    try std.testing.expectEqual(@as(u16, 0x4000), regs.dcpctr.sureq);
    try std.testing.expectEqual(@as(u16, 0x0800), regs.dcpctr.sureqclr);
    try std.testing.expectEqual(@as(u16, 0x0004), regs.dcpctr.ccpl);
}

test "the bits the host driver writes into DCPCTR don't overlap" {
    const d = regs.dcpctr;
    const all = [_]u16{ d.pid_mask, d.ccpl, d.sureqclr, d.sureq, d.bsts };
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| try std.testing.expectEqual(@as(u16, 0), a & b);
}
