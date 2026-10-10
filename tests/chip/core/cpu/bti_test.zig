//! Covers src/chip/core/cpu/bti.zig and the BTI path through Cpu.step.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const regs = ra8.chip.core.cpu.regs;
const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;

const enabled_faults: u32 = 1 << 18;
const invstate: u32 = 1 << 17;

fn branchToTarget(ram: *fixture.Ram, target: u32) !Cpu {
    ram.putWord(memmap.scb.shcsr, enabled_faults);
    ram.putWord(fixture.base + 3 * 4, fixture.handler | 1);
    ram.putWord(fixture.base + 6 * 4, fixture.handler | 1);
    ram.putHalf(fixture.code, 0x4700); // bx r0
    ram.putHalf(fixture.code + 2, 0xBF00);
    var cpu = try fixture.boot(ram);
    cpu.regs.low[0] = target | 1;
    cpu.regs.control |= regs.control_bits.bti_en;
    return cpu;
}

fn putBti(ram: *fixture.Ram, target: u32) void {
    ram.putHalf(target, 0xF3AF);
    ram.putHalf(target + 2, 0x800F);
}

test "BTI enabled accepts an indirect branch to a BTI landing pad" {
    var ram: fixture.Ram = .{};
    const target = fixture.code + 8;
    putBti(&ram, target);
    var cpu = try branchToTarget(&ram, target);

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expect(cpu.regs.xpsr & regs.xpsr_bits.bti != 0);
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & regs.xpsr_bits.bti);
    try std.testing.expectEqual(target + 4, cpu.regs.pc);
}

test "BTI enabled raises INVSTATE after an indirect branch to a non-BTI target" {
    var ram: fixture.Ram = .{};
    const target = fixture.code + 8;
    ram.putHalf(target, 0xBF00);
    var cpu = try branchToTarget(&ram, target);

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(invstate, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & regs.xpsr_bits.bti);
}

test "BTI disabled does not require a landing pad on an indirect branch" {
    var ram: fixture.Ram = .{};
    const target = fixture.code + 8;
    ram.putHalf(target, 0xBF00);
    var cpu = try branchToTarget(&ram, target);
    cpu.regs.control &= ~regs.control_bits.bti_en;

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(target + 2, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & regs.xpsr_bits.bti);
}

test "PACBTI is a landing pad and clears EPSR.B" {
    var ram: fixture.Ram = .{};
    const target = fixture.code + 8;
    ram.putHalf(target, 0xF3AF);
    ram.putHalf(target + 2, 0x800D); // pacbti r12, lr, sp
    var cpu = try branchToTarget(&ram, target);

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(target + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & regs.xpsr_bits.bti);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "BTI runs as a NOP on the M33 profile" {
    var ram: fixture.Ram = .{};
    putBti(&ram, fixture.code);
    var cpu = try fixture.boot(&ram);
    cpu.profile = ra8.chip.core.cpu.decode.profile.Profile.m33;

    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "BTI enable is selected from the active security and privilege CONTROL bank" {
    const State = ra8.chip.core.banked.State;
    const states = [_]State{ .secure, .non_secure };
    for (states) |state| {
        for ([_]bool{ true, false }) |privileged| {
            var ram: fixture.Ram = .{};
            const target = fixture.code + 8;
            ram.putHalf(target, 0xBF00);
            var cpu = try branchToTarget(&ram, target);
            cpu.regs.control = 0;
            if (state == .non_secure) cpu.banked.switchTo(&cpu.regs, state);
            const bit = if (privileged) regs.control_bits.bti_en else regs.control_bits.ubti_en;
            cpu.regs.control = bit | (if (privileged) 0 else regs.control_bits.npriv);

            try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
            try std.testing.expect(cpu.regs.xpsr & regs.xpsr_bits.bti != 0);
        }
    }
}

test "M33 profile ignores BTI CONTROL enables and never checks EPSR.B" {
    var ram: fixture.Ram = .{};
    const target = fixture.code + 8;
    ram.putHalf(target, 0xBF00);
    var cpu = try branchToTarget(&ram, target);
    cpu.profile = ra8.chip.core.cpu.decode.profile.Profile.m33;
    cpu.regs.control = regs.control_bits.bti_en;
    cpu.regs.xpsr |= regs.xpsr_bits.bti;
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr) & invstate);
    try std.testing.expectEqual(regs.xpsr_bits.bti, cpu.regs.xpsr & regs.xpsr_bits.bti);
}
