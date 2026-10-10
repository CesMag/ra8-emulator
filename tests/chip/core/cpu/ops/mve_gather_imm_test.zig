//! Covers src/chip/core/cpu/ops/mve_gather_imm.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vldr = ra8.chip.core.cpu.ops.mve_gather_imm;
const qreg = ra8.chip.core.cpu.mve.qreg;
const vpt = ra8.chip.core.cpu.mve.vpt;

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

const at = ram_base;

test "vldrw.u32 q0, [q1, #8] gathers words from four bases" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 1, (@as(u128, at) << 96) | (@as(u128, at + 4) << 64) | (@as(u128, at + 0x10) << 32) | (at + 0x28));
    try step(&cpu, 0xFD92, 0x1E02);
    try std.testing.expectEqual(@as(u128, 0x0B0A0908_0F0E0D0C_1B1A1918_33323130), qreg.read(&cpu.fp.bank, 0));
}

test "vldrw.u32 q2, [q3, #-4]! writes every address back, inactive lanes too" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 3, (@as(u128, at + 0x10) << 96) | (@as(u128, at + 0x0C) << 64) | (@as(u128, at + 0x08) << 32) | (at + 0x04));
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x00FF }, 0b1000);
    try step(&cpu, 0xFD36, 0x5E01);
    try std.testing.expectEqual(@as(u128, 0x07060504_03020100), qreg.read(&cpu.fp.bank, 2));
    try std.testing.expectEqual((@as(u128, at + 0x0C) << 96) | (@as(u128, at + 0x08) << 64) | (@as(u128, at + 0x04) << 32) | at, qreg.read(&cpu.fp.bank, 3));
}

test "vldrd.u64 q4, [q5, #-8]! moves each doubleword and updates the even words" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 5, (@as(u128, 0xAAAA_AAAA) << 96) | (@as(u128, at + 0x18) << 64) | (@as(u128, 0xBBBB_BBBB) << 32) | (at + 0x08));
    try step(&cpu, 0xFD3A, 0x9F01);
    try std.testing.expectEqual(@as(u128, 0x17161514_13121110_07060504_03020100), qreg.read(&cpu.fp.bank, 4));
    try std.testing.expectEqual((@as(u128, 0xAAAA_AAAA) << 96) | (@as(u128, at + 0x10) << 64) | (@as(u128, 0xBBBB_BBBB) << 32) | at, qreg.read(&cpu.fp.bank, 5));
}

test "vstrw.32 q6, [q7, #12]! scatters words and writes the bases back" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 6, 0x44444444_33333333_22222222_11111111);
    qreg.write(&cpu.fp.bank, 7, (@as(u128, at + 0x08) << 96) | (@as(u128, at + 0x04) << 64) | (@as(u128, at + 0x00) << 32) | (at + 0x0C));
    try step(&cpu, 0xFDAE, 0xDE03);
    try std.testing.expectEqual(@as(u128, 0x11111111_44444444_33333333_22222222), bytesAt(&ram, 0x0C));
    try std.testing.expectEqual(@as(u32, at + 0x18), qreg.elem(qreg.read(&cpu.fp.bank, 7), .word, 0));
}

test "vstrd.64 q0, [q1, #-16] scatters doublewords without writeback" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 0, 0x44444444_33333333_22222222_11111111);
    const bases = (@as(u128, at + 0x10) << 64) | (at + 0x30);
    qreg.write(&cpu.fp.bank, 1, bases);
    try step(&cpu, 0xFD02, 0x1F02);
    try std.testing.expectEqual(@as(u64, 0x44444444_33333333), std.mem.readInt(u64, ram.bytes[0..8], .little));
    try std.testing.expectEqual(@as(u64, 0x22222222_11111111), std.mem.readInt(u64, ram.bytes[0x20..0x28], .little));
    try std.testing.expectEqual(bases, qreg.read(&cpu.fp.bank, 1));
}

test "unclaimed: a load with Qd equal to Qm, Q8+, bit 16 set" {
    try std.testing.expect(vldr.group.decode(wide(0xFD90, 0x1E02)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFDD2, 0x1E02)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFD92, 0x1E82)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFD93, 0x1E02)) == null);
}
