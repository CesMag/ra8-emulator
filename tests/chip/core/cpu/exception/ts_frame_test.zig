//! Covers FPCCR.TS through src/chip/core/cpu/exception/entry.zig, fp_frame.zig
//! and ret.zig (RA8EMU-165): a Non-secure interrupt over Secure code with
//! an FP context stacks S16-S31 after the extended frame on the Secure
//! stack, clears S0-S31 and FPSCR, and the return restores them.
const std = @import("std");
const ra8 = @import("ra8");
const exception = ra8.chip.core.cpu.exception;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const fixture = @import("ram.zig");

const bx_lr: u16 = 0x4770;
const itns: u32 = 0xE000_E380;
const fpca: u32 = 1 << 2;
const ns_msp: u32 = fixture.psp_top;

fn sValue(i: usize) u32 {
    return 0x3F00_0000 + @as(u32, @intCast(i));
}

/// Secure Thread code with an eager FP context is preempted by an
/// interrupt ITNS hands to Non-secure.
fn preempted(ram: *fixture.Ram, ts: u1) !Cpu {
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    ram.putHalf(fixture.handler, bx_lr);
    ram.putWord(itns, 1);
    var cpu = try fixture.boot(ram);
    cpu.banked.other.msp = ns_msp;
    cpu.regs.control |= fpca;
    cpu.fp.context.fpccr.lspen = 0;
    cpu.fp.context.fpccr.ts = ts;
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), sValue(i));
    cpu.fp.fpscr = @TypeOf(cpu.fp.fpscr).fromBits(0x0300_0000);
    _ = try exception.entry.take(&cpu, 16, fixture.code);
    return cpu;
}

test "TS set: the Secure frame is 0xA8 bytes with S16-S31 after the VPR word" {
    var ram: fixture.Ram = .{};
    const cpu = try preempted(&ram, 1);
    const at = fixture.msp_top - 0xA8;
    try std.testing.expectEqual(.non_secure, cpu.banked.current);
    try std.testing.expectEqual(at - 0x28, cpu.banked.other.msp);
    try std.testing.expectEqual(sValue(0), ram.word(at + 0x20));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), ram.word(at + 0x60));
    try std.testing.expectEqual(sValue(16), ram.word(at + 0x68));
    try std.testing.expectEqual(sValue(31), ram.word(at + 0xA4));
}

test "TS set: the Non-secure handler sees S0-S31 and FPSCR cleared" {
    var ram: fixture.Ram = .{};
    const cpu = try preempted(&ram, 1);
    for (0..32) |i| try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 0), cpu.fp.fpscr.bits());
}

test "TS set: the return restores S0-S31 and the Secure stack" {
    var ram: fixture.Ram = .{};
    var cpu = try preempted(&ram, 1);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    for (0..32) |i| try std.testing.expectEqual(sValue(i), cpu.fp.bank.readS(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), cpu.fp.fpscr.bits());
}

test "TS clear: the basic 0x68-byte frame, S16-S31 left in place" {
    var ram: fixture.Ram = .{};
    var cpu = try preempted(&ram, 0);
    const at = fixture.msp_top - 0x68;
    try std.testing.expectEqual(at - 0x28, cpu.banked.other.msp);
    try std.testing.expectEqual(sValue(16), cpu.fp.bank.readS(16));
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(sValue(0), cpu.fp.bank.readS(0));
}
