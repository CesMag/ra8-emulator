//! Covers src/chip/core/cpu/ops/mve/vld_il.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vldr = ra8.chip.core.cpu.ops.mve.vld_il;
const qreg = ra8.chip.core.cpu.mve.qreg;

/// 64 bytes of RAM at 0x2000_0000.
const Ram = struct {
    const base: u32 = 0x2000_0000;
    bytes: [64]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slot(self: *Ram, address: u32, len: usize) bus.Error![]u8 {
        if (address < base or address - base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slot(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slot(address, from.len), from);
    }
};

const ram_base = Ram.base;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn counting() Ram {
    var ram: Ram = .{};
    for (&ram.bytes, 0..) |*b, i| b.* = @intCast(i);
    return ram;
}

fn step(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    const exec = vldr.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn bytesAt(ram: *Ram, offset: usize) u128 {
    return std.mem.readInt(u128, ram.bytes[offset..][0..16], .little);
}

test "vld20.8 then vld21.8 de-interleave 32 bytes into q0 and q1" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    try step(&cpu, 0xFC91, 0x1E00);
    try step(&cpu, 0xFC91, 0x1E20);
    try std.testing.expectEqual(@as(u128, 0x1E1C1A18_16141210_0E0C0A08_06040200), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u128, 0x1F1D1B19_17151311_0F0D0B09_07050301), qreg.read(&cpu.fp.bank, 1));
    try std.testing.expectEqual(ram_base, cpu.regs.get(1));
}

test "vld21.16 {q2, q3}, [r2]! fills its half of the elements and adds 32 to Rn" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(2, ram_base);
    try step(&cpu, 0xFCB2, 0x5EA0);
    const q2 = qreg.read(&cpu.fp.bank, 2);
    try std.testing.expectEqual(@as(u32, 0x0908), qreg.elem(q2, .half, 2));
    try std.testing.expectEqual(@as(u32, 0x1514), qreg.elem(q2, .half, 5));
    try std.testing.expectEqual(@as(u32, 0), qreg.elem(q2, .half, 0));
    try std.testing.expectEqual(@as(u32, 0x0B0A), qreg.elem(qreg.read(&cpu.fp.bank, 3), .half, 2));
    try std.testing.expectEqual(ram_base + 32, cpu.regs.get(2));
}

test "all four vld4x.32 patterns de-interleave 64 bytes" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    for ([_]u16{ 0x1F01, 0x1F21, 0x1F41, 0x1F61 }) |hw2| try step(&cpu, 0xFC91, hw2);
    try std.testing.expectEqual(@as(u128, 0x33323130_23222120_13121110_03020100), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u128, 0x3F3E3D3C_2F2E2D2C_1F1E1D1C_0F0E0D0C), qreg.read(&cpu.fp.bank, 3));
}

test "vst40.8 to vst43.8 interleave q0..q3 back into memory" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    for (0..4) |r| qreg.write(&cpu.fp.bank, @intCast(r), @as(u128, 0x0101_0101_0101_0101_0101_0101_0101_0101) * @as(u128, r + 1));
    for ([_]u16{ 0x1E01, 0x1E21, 0x1E41, 0x1E61 }) |hw2| try step(&cpu, 0xFC81, hw2);
    try std.testing.expectEqual(@as(u128, 0x04030201_04030201_04030201_04030201), bytesAt(&ram, 0));
    try std.testing.expectEqual(@as(u128, 0x04030201_04030201_04030201_04030201), bytesAt(&ram, 48));
}

test "vst20.32 then vst21.32 interleave q6 and q7 words" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 6, 0xA3A3A3A3_A2A2A2A2_A1A1A1A1_A0A0A0A0);
    qreg.write(&cpu.fp.bank, 7, 0xB3B3B3B3_B2B2B2B2_B1B1B1B1_B0B0B0B0);
    try step(&cpu, 0xFC81, 0xDF00);
    try step(&cpu, 0xFC81, 0xDF20);
    try std.testing.expectEqual(@as(u128, 0xB1B1B1B1_A1A1A1A1_B0B0B0B0_A0A0A0A0), bytesAt(&ram, 0));
    try std.testing.expectEqual(@as(u128, 0xB3B3B3B3_A3A3A3A3_B2B2B2B2_A2A2A2A2), bytesAt(&ram, 16));
}

test "word interleaving store faults when the base is not word aligned" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base + 2);
    try std.testing.expectError(error.Unaligned, step(&cpu, 0xFC81, 0x1F01));
}

test "unclaimed: past Q7, size 3, pattern 2 of VLD2, PC, SP with writeback, Q8+" {
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0xFE00)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0xBE01)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x1F80)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x1E40)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC9F, 0x1E00)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFCBD, 0x1E00)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFCD1, 0x1E00)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC9D, 0x3EA1)) != null);
}
