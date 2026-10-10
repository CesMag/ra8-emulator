//! Covers FPCCR.CLRONRET in src/chip/core/cpu/exception/ret.zig (RA8EMU-165):
//! a return that restores no FP context clears S0-S15, FPSCR and VPR; one
//! that restores them from the frame does not.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;
const fixture = @import("ram.zig");

const svc: u16 = 0xDF00;
const bx_lr: u16 = 0x4770;
const fpca: u32 = 1 << 2;

/// SVC into a handler that is only BX LR, with S0-S31 and FPSCR loaded.
fn booted(ram: *fixture.Ram, clronret: u1, fp: bool) !Cpu {
    ram.putHalf(fixture.code, svc);
    ram.putHalf(fixture.code + 2, 0xBF00);
    ram.putHalf(fixture.handler, bx_lr);
    var cpu = try fixture.boot(ram);
    if (fp) cpu.regs.control |= fpca;
    cpu.fp.context.fpccr.lspen = 0;
    cpu.fp.context.fpccr.clronret = clronret;
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), 0x3F00_0000 + @as(u32, @intCast(i)));
    cpu.fp.fpscr = @TypeOf(cpu.fp.fpscr).fromBits(0x0300_0000);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    return cpu;
}

test "CLRONRET set: a return with no FP frame clears S0-S15 and FPSCR, keeps S16-S31" {
    var ram: fixture.Ram = .{};
    const cpu = try booted(&ram, 1, false);
    for (0..16) |i| try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cpu.fp.vpr)));
    try std.testing.expectEqual(@as(u32, 0x3F00_0010), cpu.fp.bank.readS(16));
}

test "CLRONRET clear: the return leaves the FP registers alone" {
    var ram: fixture.Ram = .{};
    const cpu = try booted(&ram, 0, false);
    try std.testing.expectEqual(@as(u32, 0x3F00_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), cpu.fp.fpscr.bits());
}

test "CLRONRET set: a return with an FP frame restores it rather than clearing" {
    var ram: fixture.Ram = .{};
    const cpu = try booted(&ram, 1, true);
    try std.testing.expectEqual(@as(u32, 0x3F00_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0x3F00_000F), cpu.fp.bank.readS(15));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), cpu.fp.fpscr.bits());
}
