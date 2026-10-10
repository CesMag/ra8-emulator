//! Covers src/chip/core/cpu/ops/sp_arith.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const sp_arith = ra8.chip.core.cpu.ops.sp_arith;

fn noBus() bus.Bus {
    return .{ .ctx = undefined, .vtable = &.{ .read = refuseRead, .write = refuseWrite } };
}

fn refuseRead(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
    _ = .{ ctx, address, into };
    return bus.Error.Unmapped;
}

fn refuseWrite(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
    _ = .{ ctx, address, from };
    return bus.Error.Unmapped;
}

fn run(cpu: *Cpu, address: u32, hw1: u16) !void {
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = address, .hw1 = hw1, .size = 2 };
    const exec = sp_arith.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "sub sp, #24 and add sp, #24 move MSP and leave the flags" {
    var cpu: Cpu = .{ .bus = noBus() };
    cpu.regs.msp = 0x2000_1000;
    cpu.regs.xpsr = regs.xpsr_bits.thumb | 0xF000_0000;
    try run(&cpu, 0, 0xB086);
    try std.testing.expectEqual(@as(u32, 0x2000_0FE8), cpu.regs.msp);
    try run(&cpu, 0, 0xB006);
    try std.testing.expectEqual(@as(u32, 0x2000_1000), cpu.regs.msp);
    try std.testing.expectEqual(regs.xpsr_bits.thumb | 0xF000_0000, cpu.regs.xpsr);
}

test "the largest imm7 is 508" {
    var cpu: Cpu = .{ .bus = noBus() };
    cpu.regs.msp = 0x2000_1000;
    try run(&cpu, 0, 0xB0FF);
    try std.testing.expectEqual(@as(u32, 0x2000_1000 - 508), cpu.regs.msp);
}

test "the process stack moves in Thread mode with SPSEL set" {
    var cpu: Cpu = .{ .bus = noBus() };
    cpu.regs.control = regs.control_bits.spsel;
    cpu.regs.psp = 0x2000_0800;
    cpu.regs.msp = 0x2000_1000;
    try run(&cpu, 0, 0xB082);
    try std.testing.expectEqual(@as(u32, 0x2000_07F8), cpu.regs.psp);
    try std.testing.expectEqual(@as(u32, 0x2000_1000), cpu.regs.msp);
}

test "add r0, sp, #16 writes SP plus the scaled immediate" {
    var cpu: Cpu = .{ .bus = noBus() };
    cpu.regs.msp = 0x2000_0F00;
    try run(&cpu, 0, 0xA804);
    try std.testing.expectEqual(@as(u32, 0x2000_0F10), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 0x2000_0F00), cpu.regs.msp);
}

test "adr aligns the PC down to a word before adding" {
    var cpu: Cpu = .{ .bus = noBus() };
    try run(&cpu, 0x0800_0102, 0xA301); // adr r3, #4 at a halfword-aligned address
    try std.testing.expectEqual(@as(u32, 0x0800_0108), cpu.regs.low[3]);
    try run(&cpu, 0x0800_0100, 0xA700); // adr r7, #0
    try std.testing.expectEqual(@as(u32, 0x0800_0104), cpu.regs.low[7]);
}

test "neighbouring encodings are not claimed" {
    // b580 push, b2c0 sxth-shaped, b100 cbz, a000 is adr so take 9800 ldr sp-rel and 4a13 ldr literal
    for ([_]u16{ 0xB580, 0xB240, 0xB100, 0x9800, 0x4A13, 0xB680 }) |hw1| {
        try std.testing.expect(sp_arith.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
