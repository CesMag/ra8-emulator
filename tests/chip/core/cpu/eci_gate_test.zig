//! Covers src/chip/core/cpu/eci_gate.zig and its check in Cpu.step
//! (RA8EMU-453): with EPSR.ECI/ICI nonzero, a load/store multiple restarts
//! with ICI cleared, LE leaves ECI, and anything else takes INVSTATE.
const std = @import("std");
const ra8 = @import("ra8");
const gate = ra8.chip.core.cpu.cpu.eci_gate;
const it_state = ra8.chip.core.cpu.it_state;
const fixture = @import("exception/ram.zig");
const Stop = ra8.chip.core.cpu.cpu.Stop;

const usage_handler: u32 = fixture.base + 0x1C0;
const invstate: u32 = 1 << 17;

test "an open IT block or a clear byte always runs" {
    try std.testing.expectEqual(gate.Action.run, gate.action(0x00, .refuses));
    try std.testing.expectEqual(gate.Action.run, gate.action(0x08, .refuses));
    try std.testing.expectEqual(gate.Action.run, gate.action(0x28, .restarts));
}

test "with ECI set each kind of instruction gets its own action" {
    try std.testing.expectEqual(gate.Action.fault, gate.action(0x10, .refuses));
    try std.testing.expectEqual(gate.Action.restart, gate.action(0x10, .restarts));
    try std.testing.expectEqual(gate.Action.run, gate.action(0x10, .beat_wise));
    try std.testing.expectEqual(gate.Action.run, gate.action(0x50, .keeps));
}

test "a reserved ECI value faults a beat-wise instruction" {
    for ([_]u8{ 0x30, 0x60, 0x70, 0x80, 0xF0 }) |it| {
        try std.testing.expectEqual(gate.Action.fault, gate.action(it, .beat_wise));
    }
    try std.testing.expectEqual(gate.Action.run, gate.action(0x40, .beat_wise));
}

fn boot(ram: *fixture.Ram, hw1: u16, hw2: ?u16) !ra8.chip.core.cpu.cpu.Cpu {
    ram.putHalf(fixture.code, hw1);
    if (hw2) |second| ram.putHalf(fixture.code + 2, second);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(ra8.chip.core.memmap.scb.shcsr, 1 << 18);
    var cpu = try fixture.boot(ram);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x10);
    return cpu;
}

test "a NOP run with ECI set takes UsageFault INVSTATE before it runs" {
    var ram: fixture.Ram = .{};
    var cpu = try boot(&ram, 0xBF00, null);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(invstate, ram.word(ra8.chip.core.memmap.scb.cfsr));
    try std.testing.expectEqual(fixture.code, ram.word(cpu.regs.msp + 6 * 4));
    try std.testing.expectEqual(@as(u64, 0), cpu.retired);
}

test "vadd.i32 with a reserved ECI takes INVSTATE before it writes Q0" {
    var ram: fixture.Ram = .{};
    var cpu = try boot(&ram, 0xEF22, 0x0844); // vadd.i32 q0, q1, q2
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x30);
    const before: u128 = 0xAAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA;
    ra8.chip.core.cpu.mve.qreg.write(&cpu.fp.bank, 0, before);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(invstate, ram.word(ra8.chip.core.memmap.scb.cfsr));
    try std.testing.expectEqual(before, ra8.chip.core.cpu.mve.qreg.read(&cpu.fp.bank, 0));
}

test "VLDM restarts from the first S register with ICI cleared" {
    var ram: fixture.Ram = .{};
    ram.putHalf(fixture.code, 0xEC92); // vldmia r2, {s0-s1}
    ram.putHalf(fixture.code + 2, 0x0A02);
    ram.putWord(fixture.base + 0x200, 0x3F80_0000);
    ram.putWord(fixture.base + 0x204, 0x4000_0000);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[2] = fixture.base + 0x200;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x10);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(0));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), cpu.fp.bank.readS(1));
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

test "VSTM restarts from the first S register with ICI cleared" {
    var ram: fixture.Ram = .{};
    ram.putHalf(fixture.code, 0xEC82); // vstmia r2, {s0-s1}
    ram.putHalf(fixture.code + 2, 0x0A02);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[2] = fixture.base + 0x200;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x10);
    cpu.fp.bank.writeS(0, 0x3F80_0000);
    cpu.fp.bank.writeS(1, 0x4000_0000);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(fixture.base + 0x200));
    try std.testing.expectEqual(@as(u32, 0x4000_0000), ram.word(fixture.base + 0x204));
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

test "VLDR with ECI takes UsageFault INVSTATE" {
    var ram: fixture.Ram = .{};
    ram.putHalf(fixture.code, 0xED90); // vldr s0, [r0]
    ram.putHalf(fixture.code + 2, 0x0A00);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(ra8.chip.core.memmap.scb.shcsr, 1 << 18);
    var cpu = try fixture.boot(&ram);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x10);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(invstate, ram.word(ra8.chip.core.memmap.scb.cfsr));
}

test "VSTR with ECI takes UsageFault INVSTATE" {
    var ram: fixture.Ram = .{};
    ram.putHalf(fixture.code, 0xED80); // vstr s0, [r0]
    ram.putHalf(fixture.code + 2, 0x0A00);
    ram.putWord(fixture.base + 6 * 4, usage_handler | 1);
    ram.putWord(ra8.chip.core.memmap.scb.shcsr, 1 << 18);
    var cpu = try fixture.boot(&ram);
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, 0x10);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    try std.testing.expectEqual(invstate, ram.word(ra8.chip.core.memmap.scb.cfsr));
}

test "LDM restarts from the start with ICI cleared" {
    var ram: fixture.Ram = .{};
    var cpu = try boot(&ram, 0xC802, null); // ldmia r0!, {r1}
    ram.putWord(fixture.base + 0x200, 0x1234_5678);
    cpu.regs.low[0] = fixture.base + 0x200;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.regs.low[1]);
    try std.testing.expectEqual(fixture.base + 0x204, cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
}

test "LE leaves ECI for the instruction it branches back to" {
    var ram: fixture.Ram = .{};
    var cpu = try boot(&ram, 0xF00F, 0xC007); // le lr, back
    cpu.regs.lr = 2;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.lr);
    try std.testing.expectEqual(@as(u8, 0x10), it_state.get(cpu.regs.xpsr));
    try std.testing.expectEqual(@as(u32, 0), ram.word(ra8.chip.core.memmap.scb.cfsr));
}
