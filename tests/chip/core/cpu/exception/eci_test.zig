//! Covers EPSR.ECI across src/chip/core/cpu/exception/entry.zig and ret.zig
//! (RA8EMU-454): an exception taken with ECI live stacks it, clears it,
//! and the return brings it back so the next beat-wise instruction runs
//! only the beats still to do.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const qreg = ra8.chip.core.cpu.mve.qreg;
const it_state = ra8.chip.core.cpu.it_state;
const Stop = ra8.chip.core.cpu.cpu.Stop;

const vadd_i32 = [2]u16{ 0xEF22, 0x0844 }; // vadd.i32 q0, q1, q2
const bx_lr: u16 = 0x4770;
const cpacr: u32 = 0xE000_ED88;
const svc_number: ra8.chip.core.cpu.exception.entry.Number = 11;
const old: u128 = 0xAAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA;

fn program(ram: *fixture.Ram) void {
    ram.putHalf(fixture.code, vadd_i32[0]);
    ram.putHalf(fixture.code + 2, vadd_i32[1]);
    ram.putHalf(fixture.code + 4, vadd_i32[0]);
    ram.putHalf(fixture.code + 6, vadd_i32[1]);
    ram.putHalf(fixture.handler, bx_lr);
    ram.putWord(cpacr, 0x00F0_0000);
}

fn loadQ(cpu: *ra8.chip.core.cpu.cpu.Cpu) void {
    qreg.write(&cpu.fp.bank, 0, old);
    qreg.write(&cpu.fp.bank, 1, 0x0000_0004_0000_0003_0000_0002_0000_0001);
    qreg.write(&cpu.fp.bank, 2, 0x0000_0010_0000_0010_0000_0010_0000_0010);
}

test "ECI A0 is stacked on entry, cleared live, and restored on return" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var cpu = try fixture.boot(&ram);
    loadQ(&cpu);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x50); // A0 A1 A2 B0 done
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u8, 0x10), it_state.get(cpu.regs.xpsr));
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);

    _ = try ra8.chip.core.cpu.exception.entry.take(&cpu, svc_number, cpu.regs.pc);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
    const stacked = ram.word(cpu.regs.msp + 7 * 4);
    try std.testing.expectEqual(@as(u8, 0x10), it_state.get(stacked));

    try std.testing.expectEqual(@as(?Stop, null), cpu.step()); // bx lr
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u8, 0x10), it_state.get(cpu.regs.xpsr));
}

test "the resumed vadd.i32 writes only beats 1 to 3 after the return" {
    var ram: fixture.Ram = .{};
    program(&ram);
    var cpu = try fixture.boot(&ram);
    loadQ(&cpu);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x50);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    qreg.write(&cpu.fp.bank, 0, old);
    _ = try ra8.chip.core.cpu.exception.entry.take(&cpu, svc_number, cpu.regs.pc);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step()); // bx lr
    try std.testing.expectEqual(@as(?Stop, null), cpu.step()); // vadd.i32
    const expected: u128 = 0x0000_0014_0000_0013_0000_0012_AAAA_AAAA;
    try std.testing.expectEqual(expected, qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}
