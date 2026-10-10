//! Covers the Non-secure-over-Secure path through
//! src/chip/core/cpu/exception/entry.zig, ret.zig and target.zig: an interrupt
//! NVIC_ITNS hands to Non-secure preempts Secure Thread code, the callee
//! registers are stacked under the integrity signature and cleared, and the
//! return gives them back, or chains SecureFault INVIS over the frame it
//! left when the signature was corrupted (RA8EMU-411).
const std = @import("std");
const ra8 = @import("ra8");
const exception = ra8.chip.core.cpu.exception;
const fixture = @import("ram.zig");

const bx_lr: u16 = 0x4770;
const itns: u32 = 0xE000_E380;
const sfsr: u32 = 0xE000_EDE4;
/// The Non-secure Main stack; the fixture's own `msp_top` serves Secure.
const ns_msp: u32 = fixture.psp_top;
/// Where the signature lands: below the caller frame and the callee frame.
const signature_at: u32 = fixture.msp_top - 0x20 - 0x28;

fn preempted(ram: *fixture.Ram) !ra8.chip.core.cpu.cpu.Cpu {
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    ram.putWord(fixture.base + 3 * 4, fixture.handler | 1);
    ram.putWord(fixture.base + 7 * 4, fixture.handler | 1);
    ram.putHalf(fixture.handler, bx_lr);
    ram.putWord(itns, 1);
    var cpu = try fixture.boot(ram);
    cpu.banked.other.msp = ns_msp;
    cpu.regs.low[0] = 0x10;
    for (4..12) |i| cpu.regs.low[i] = @intCast(0x40 + i);
    _ = try exception.entry.take(&cpu, 16, fixture.code);
    return cpu;
}

test "an ITNS interrupt over Secure code is taken Non-secure with the callee registers hidden" {
    var ram: fixture.Ram = .{};
    const cpu = try preempted(&ram);
    try std.testing.expectEqual(.non_secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF8), cpu.regs.lr);
    try std.testing.expectEqual(ns_msp, cpu.regs.msp);
    try std.testing.expectEqual(signature_at, cpu.banked.other.msp);
    try std.testing.expectEqual(@as(u32, 0xFEFA_125B), ram.word(signature_at));
    try std.testing.expectEqual(@as(u32, 0x44), ram.word(signature_at + 8));
    for (0..13) |i| try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[i]);
}

test "the return puts Secure Thread code back intact" {
    var ram: fixture.Ram = .{};
    var cpu = try preempted(&ram);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(ns_msp, cpu.banked.other.msp);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.regs.low[0]);
    for (4..12) |i| try std.testing.expectEqual(@as(u32, @intCast(0x40 + i)), cpu.regs.low[i]);
}

test "a corrupted signature raises SecureFault INVIS" {
    var ram: fixture.Ram = .{};
    var cpu = try preempted(&ram);
    ram.putWord(signature_at, 0);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 1), cpu.secure_faults);
    try std.testing.expect(ram.word(sfsr) & 2 != 0);
    try std.testing.expectEqual(.secure, cpu.banked.current);
}

test "INVIS chains over the callee frame instead of stacking a new one" {
    var ram: fixture.Ram = .{};
    var cpu = try preempted(&ram);
    ram.putWord(ra8.chip.core.memmap.scb.shcsr, 1 << 19);
    ram.putWord(signature_at, 0);
    const below = ram.word(signature_at - 4);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(signature_at, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xF000_0000) +% 0xFFFF_FFF8, cpu.regs.lr);
    try std.testing.expectEqual(below, ram.word(signature_at - 4));
    try std.testing.expectEqual(ns_msp, cpu.banked.other.msp);
}

test "without ITNS the interrupt stays Secure and nothing is hidden" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.base + 16 * 4, fixture.handler | 1);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[4] = 0x44;
    _ = try exception.entry.take(&cpu, 16, fixture.code);
    try std.testing.expectEqual(.secure, cpu.banked.current);
    try std.testing.expectEqual(@as(u32, 0x44), cpu.regs.low[4]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.lr | 0x10);
}
