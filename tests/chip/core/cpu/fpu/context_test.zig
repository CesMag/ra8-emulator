//! Covers src/chip/core/cpu/fpu/context.zig against the Arm ARM (DDI0553)
//! register descriptions for FPCCR, FPCAR and FPDSCR and ExecuteFPCheck().
const std = @import("std");
const ra8 = @import("ra8");
const context = ra8.chip.core.cpu.fpu.context;
const Context = context.Context;
const Fpscr = ra8.chip.core.cpu.fpu.fpscr.Fpscr;
const State = ra8.chip.core.cpu.fpu.state.State;
const Vpr = ra8.chip.core.cpu.mve.predicate.Vpr;
const fpca: u32 = 1 << 2;

test "reset values: FPCCR has ASPEN and LSPEN, FPDSCR reads LTPSIZE 4" {
    const c: Context = .{};
    try std.testing.expectEqual(@as(u32, 0xC000_0000), c.readFpccr());
    try std.testing.expectEqual(@as(u32, 0), c.fpcar);
    try std.testing.expectEqual(@as(u32, 0x0004_0000), c.fpdscr);
    const s: State = .{};
    try std.testing.expectEqual(@as(u32, 0xC000_0000), s.context.readFpccr());
}

test "FPCCR keeps every defined bit and drops the reserved ones" {
    var c: Context = .{};
    c.writeFpccr(0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xFC00_07FF), c.readFpccr());
    c.writeFpccr(0x8000_0001);
    try std.testing.expectEqual(@as(u1, 1), c.fpccr.aspen);
    try std.testing.expectEqual(@as(u1, 0), c.fpccr.lspen);
    try std.testing.expectEqual(@as(u1, 1), c.fpccr.lspact);
}

test "FPCAR keeps bits 31:3" {
    var c: Context = .{};
    c.writeFpcar(0x2000_1237);
    try std.testing.expectEqual(@as(u32, 0x2000_1230), c.fpcar);
}

test "FPDSCR keeps AHP, DN, FZ, RMode and FZ16; LTPSIZE stays 4" {
    var c: Context = .{};
    c.writeFpdscr(0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x07CC_0000), c.fpdscr);
    c.writeFpdscr(0);
    try std.testing.expectEqual(@as(u32, 0x0004_0000), c.fpdscr);
}

test "the first FP instruction sets FPCA and loads FPSCR from FPDSCR" {
    var c: Context = .{};
    c.writeFpdscr(0x03C0_0000); // DN, FZ, RMode = towards zero
    var fpscr: Fpscr = @bitCast(@as(u32, 0xF800_009F)); // NZCV, QC, flags
    var vpr: Vpr = @bitCast(@as(u32, 0x00FF_FFFF));
    const control = c.touch(0b10, .non_secure, &fpscr, &vpr);
    try std.testing.expectEqual(@as(u32, 0b10 | fpca), control);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(vpr)));
    try std.testing.expectEqual(@as(u1, 0), c.fpccr.s);
    try std.testing.expectEqual(@as(u32, 0x03C4_0000), fpscr.bits());
}

test "an open context or ASPEN clear leaves FPSCR and CONTROL alone" {
    var c: Context = .{};
    c.writeFpdscr(0x0200_0000);
    var fpscr: Fpscr = @bitCast(@as(u32, 0x8000_0001));
    var vpr: Vpr = .{};
    try std.testing.expectEqual(fpca, c.touch(fpca, .non_secure, &fpscr, &vpr));
    try std.testing.expectEqual(@as(u32, 0x8000_0001), fpscr.bits());
    c.writeFpccr(0);
    try std.testing.expectEqual(@as(u32, 0), c.touch(0, .non_secure, &fpscr, &vpr));
    try std.testing.expectEqual(@as(u32, 0x8000_0001), fpscr.bits());
}

test "Secure FP use opens a Secure context when SFPA is clear despite FPCA" {
    var c: Context = .{};
    c.writeFpdscr(0x0200_0000);
    var fpscr: Fpscr = @bitCast(@as(u32, 0x8000_0011));
    var vpr: Vpr = @bitCast(@as(u32, 0x0000_00FF));
    const control = c.touch(fpca, .secure, &fpscr, &vpr);
    try std.testing.expectEqual(fpca | ra8.chip.core.cpu.regs.control_bits.sfpa, control);
    try std.testing.expectEqual(@as(u32, 0x0204_0000), fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(vpr)));
    try std.testing.expectEqual(@as(u1, 1), c.fpccr.s);
}

test "Secure FP ownership is recorded when ASPEN is clear without creating context" {
    var c: Context = .{};
    c.writeFpccr(0);
    var fpscr: Fpscr = @bitCast(@as(u32, 0x8000_0001));
    var vpr: Vpr = @bitCast(@as(u32, 0xFF));
    try std.testing.expectEqual(@as(u32, 0), c.touch(0, .secure, &fpscr, &vpr));
    try std.testing.expectEqual(@as(u32, 0x8000_0001), fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0xFF), @as(u32, @bitCast(vpr)));
    try std.testing.expectEqual(@as(u1, 1), c.fpccr.s);
}
