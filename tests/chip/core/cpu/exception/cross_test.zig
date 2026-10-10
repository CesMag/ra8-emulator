//! Covers the state-crossing path through src/chip/core/cpu/exception/entry.zig
//! and ret.zig: a Secure HardFault taken over Non-secure Thread code, and
//! the return that puts Non-secure back.
const std = @import("std");
const ra8 = @import("ra8");
const exception = ra8.chip.core.cpu.exception;
const fixture = @import("ram.zig");

const bx_lr: u16 = 0x4770;
/// The Secure Main stack; the fixture's own `msp_top` serves Non-secure.
const secure_msp: u32 = fixture.psp_top;

fn nonSecureCpu(ram: *fixture.Ram) !ra8.chip.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 3 * 4, fixture.handler | 1);
    ram.putHalf(fixture.handler, bx_lr);
    var cpu = try fixture.boot(ram);
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    cpu.regs.msp = fixture.msp_top;
    cpu.banked.other.msp = secure_msp;
    return cpu;
}

test "a HardFault over Non-secure code is taken Secure with the frame on the Non-secure stack" {
    var ram: fixture.Ram = .{};
    var cpu = try nonSecureCpu(&ram);
    cpu.regs.low[1] = 0x11;
    _ = try exception.entry.take(&cpu, 3, fixture.code);
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFB9), cpu.regs.lr);
    try std.testing.expectEqual(secure_msp, cpu.regs.msp);
    try std.testing.expectEqual(fixture.msp_top - 32, cpu.banked.other.msp);
    try std.testing.expectEqual(@as(u32, 0x11), ram.word(fixture.msp_top - 32 + 4));
    try std.testing.expectEqual(fixture.code, ram.word(fixture.msp_top - 32 + 24));
}

test "BX LR from the Secure handler returns to Non-secure Thread code intact" {
    var ram: fixture.Ram = .{};
    var cpu = try nonSecureCpu(&ram);
    cpu.regs.low[1] = 0x11;
    _ = try exception.entry.take(&cpu, 3, fixture.code);
    cpu.regs.low[1] = 0xDEAD;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(.non_secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(secure_msp, cpu.banked.other.msp);
    try std.testing.expectEqual(@as(u32, 0x11), cpu.regs.low[1]);
}

test "a Non-secure exception over Non-secure code stays Non-secure" {
    var ram: fixture.Ram = .{};
    var cpu = try nonSecureCpu(&ram);
    ram.putWord(fixture.base + 14 * 4, fixture.handler | 1);
    // PendSV pended in the Non-secure copy, as the pick tags it (RA8EMU-439).
    cpu.entering_non_secure = true;
    _ = try exception.entry.take(&cpu, 14, fixture.code);
    try std.testing.expectEqual(.non_secure, cpu.banked.current);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFB8), cpu.regs.lr & ~@as(u32, 0x10) | 0x10 & cpu.regs.lr);
}
