//! Covers two FPU-using threads switching through a ThreadX-style PendSV
//! handler (RA8EMU-164): entry.zig's lazy extended frame, the handler's
//! VSTMDB/VLDMIA of S16-S31 keyed on EXC_RETURN.FType, the deferred push
//! it triggers, and ret.zig restoring each thread's S0-S31 and FPSCR.
const std = @import("std");
const ra8 = @import("ra8");
const exception = ra8.chip.core.cpu.exception;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;
const fixture = @import("ram.zig");

/// tx_thread_schedule's PendSV for an FPU core, assembled for cortex_m85:
///   mrs r0, psp; tst lr, #0x10; it eq; vstmdbeq r0!, {s16-s31}
///   stmdb r0!, {r4-r11, lr}; ldr r1, =slot; ldr r2, [r1]; str r0, [r1]
///   ldmia r2!, {r4-r11, lr}; tst lr, #0x10; it eq; vldmiaeq r2!, {s16-s31}
///   msr psp, r2; bx lr; .word slot
const pendsv = [_]u16{
    0xF3EF, 0x8009, 0xF01E, 0x0F10, 0xBF08, 0xED20, 0x8A10, 0xE920,
    0x4FF0, 0x4906, 0x680A, 0x6008, 0xE8B2, 0x4FF0, 0xF01E, 0x0F10,
    0xBF08, 0xECB2, 0x8A10, 0xF382, 0x8809, 0x4770, 0x0300, 0x2000,
};
/// The word the handler swaps the outgoing thread's PSP through.
const slot: u32 = fixture.base + 0x300;
const thread_b: u32 = fixture.code + 0x40;
const b_top: u32 = fixture.base + 0x3F0;
const b_saved: u32 = b_top - 0xCC;
const a_saved: u32 = fixture.psp_top - 0xCC;
const exc_return: u32 = 0xFFFF_FFED; // Thread, PSP, FType clear
const fpca: u32 = 1 << 2;
const spsel: u32 = 1 << 1;

fn aValue(i: usize) u32 {
    return 0xA000_0000 + @as(u32, @intCast(i));
}

fn bValue(i: usize) u32 {
    return 0xB000_0000 + @as(u32, @intCast(i));
}

/// Thread B parked the way the scheduler leaves it: r4-r11 and EXC_RETURN,
/// S16-S31, then the extended hardware frame resuming at `thread_b`.
fn parkB(ram: *fixture.Ram) void {
    var at = b_saved;
    for (0..8) |i| ram.putWord(at + @as(u32, @intCast(i)) * 4, 0xB4 + @as(u32, @intCast(i)));
    ram.putWord(at + 0x20, exc_return);
    at += 0x24;
    for (16..32) |i| ram.putWord(at + @as(u32, @intCast(i - 16)) * 4, bValue(i));
    at += 0x40;
    ram.putWord(at + 0x18, thread_b);
    ram.putWord(at + 0x1C, 0x0100_0000);
    for (0..16) |i| ram.putWord(at + 0x20 + @as(u32, @intCast(i)) * 4, bValue(i));
    ram.putWord(at + 0x60, 0x0200_0000);
    ram.putWord(slot, b_saved);
}

/// Thread A running on the PSP with an FP context, lazy stacking on.
fn booted(ram: *fixture.Ram) !Cpu {
    ram.putWord(fixture.base + 14 * 4, fixture.handler | 1);
    for (pendsv, 0..) |hw, i| ram.putHalf(fixture.handler + @as(u32, @intCast(i)) * 2, hw);
    ram.putHalf(fixture.code, 0xE7FE); // b .
    ram.putHalf(thread_b, 0xE7FE);
    parkB(ram);
    var cpu = try fixture.boot(ram);
    cpu.regs.psp = fixture.psp_top;
    cpu.regs.control |= spsel | fpca;
    cpu.fp.context.fpccr.lspen = 1;
    for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), aValue(i));
    cpu.fp.fpscr = @TypeOf(cpu.fp.fpscr).fromBits(0x0300_0000);
    return cpu;
}

/// Pend PendSV over the thread at `from` and run the handler until it
/// lands on `to`.
fn switchTo(cpu: *Cpu, from: u32, to: u32) !void {
    _ = try exception.entry.take(cpu, 14, from);
    var steps: usize = 0;
    while (cpu.regs.pc != to) : (steps += 1) {
        if (steps == 40) return error.NoSwitch;
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    }
}

test "PendSV switches A out and B in with B's S0-S31 and FPSCR" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram);
    try switchTo(&cpu, fixture.code, thread_b);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(b_top, cpu.regs.psp);
    for (0..32) |i| try std.testing.expectEqual(bValue(i), cpu.fp.bank.readS(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 0x0200_0000), cpu.fp.fpscr.bits());
    try std.testing.expectEqual(@as(u32, 0xB4), cpu.regs.low[4]);
}

test "A's S16-S31 go out by VSTMDB and its S0-S15 by the deferred push" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram);
    try switchTo(&cpu, fixture.code, thread_b);
    try std.testing.expectEqual(a_saved, ram.word(slot));
    try std.testing.expectEqual(exc_return, ram.word(a_saved + 0x20));
    try std.testing.expectEqual(aValue(16), ram.word(a_saved + 0x24));
    try std.testing.expectEqual(aValue(31), ram.word(a_saved + 0x60));
    const frame = a_saved + 0x64;
    try std.testing.expectEqual(fixture.code, ram.word(frame + 0x18));
    try std.testing.expectEqual(aValue(0), ram.word(frame + 0x20));
    try std.testing.expectEqual(aValue(15), ram.word(frame + 0x5C));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), ram.word(frame + 0x60));
}

test "switching back restores every A register B's run overwrote" {
    var ram: fixture.Ram = .{};
    var cpu = try booted(&ram);
    try switchTo(&cpu, fixture.code, thread_b);
    try switchTo(&cpu, thread_b, fixture.code);
    try std.testing.expectEqual(fixture.psp_top, cpu.regs.psp);
    for (0..32) |i| try std.testing.expectEqual(aValue(i), cpu.fp.bank.readS(@intCast(i)));
    try std.testing.expectEqual(@as(u32, 0x0300_0000), cpu.fp.fpscr.bits());
    try std.testing.expectEqual(b_saved, ram.word(slot));
    try std.testing.expectEqual(bValue(16), ram.word(b_saved + 0x24));
}
