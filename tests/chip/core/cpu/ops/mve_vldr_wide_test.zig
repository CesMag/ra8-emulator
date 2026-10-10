//! Covers src/chip/core/cpu/ops/mve_vldr_wide.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vldr = ra8.chip.core.cpu.ops.mve_vldr_wide;
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

test "vldrb.s16 q0, [r1, #3] sign-extends eight bytes" {
    var ram = counting();
    ram.bytes[4] = 0x80;
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    try step(&cpu, 0xED91, 0x0E83);
    const q = qreg.read(&cpu.fp.bank, 0);
    try std.testing.expectEqual(@as(u32, 0x0003), qreg.elem(q, .half, 0));
    try std.testing.expectEqual(@as(u32, 0xFF80), qreg.elem(q, .half, 1));
    try std.testing.expectEqual(@as(u32, 0x000A), qreg.elem(q, .half, 7));
}

test "vldrb.u16 q1, [r2, #-2]! zero-extends and writes Rn back" {
    var ram = counting();
    ram.bytes[0x0E] = 0xF0;
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(2, ram_base + 0x10);
    try step(&cpu, 0xFD32, 0x2E82);
    try std.testing.expectEqual(@as(u32, 0x00F0), qreg.elem(qreg.read(&cpu.fp.bank, 1), .half, 0));
    try std.testing.expectEqual(ram_base + 0x0E, cpu.regs.get(2));
}

test "vldrb.s32 q2, [r3], #4 post-indexes by bytes" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(3, ram_base);
    try step(&cpu, 0xECB3, 0x4F04);
    try std.testing.expectEqual(@as(u128, 0x00000003_00000002_00000001_00000000), qreg.read(&cpu.fp.bank, 2));
    try std.testing.expectEqual(ram_base + 4, cpu.regs.get(3));
}

test "vldrh.s32 q4, [r1, #4] sign-extends halfwords" {
    var ram = counting();
    ram.bytes[7] = 0x80;
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    try step(&cpu, 0xED99, 0x8F02);
    const q = qreg.read(&cpu.fp.bank, 4);
    try std.testing.expectEqual(@as(u32, 0x0504), qreg.elem(q, .word, 0));
    try std.testing.expectEqual(@as(u32, 0xFFFF_8006), qreg.elem(q, .word, 1));
}

test "halfword memory elements fault when the base is misaligned" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base + 1);
    try std.testing.expectError(error.Unaligned, step(&cpu, 0xED99, 0x8F02));
}

test "vstrb.32 q1, [r1, #-1]! keeps each word's low byte" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 1, 0xAAAAAA44_BBBBBB33_CCCCCC22_DDDDDD11);
    cpu.regs.set(1, ram_base + 9);
    try step(&cpu, 0xED21, 0x2F01);
    try std.testing.expectEqual(@as(u128, 0x44332211), bytesAt(&ram, 8));
    try std.testing.expectEqual(ram_base + 8, cpu.regs.get(1));
}

test "vstrh.32 q2, [r1], #2 under a predicate skips inactive words" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 2, 0x00004444_00003333_00002222_00001111);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x0F0F }, 0b1000);
    cpu.regs.set(1, ram_base);
    try step(&cpu, 0xECA9, 0x4F01);
    try std.testing.expectEqual(@as(u128, 0x0000_3333_0000_1111), bytesAt(&ram, 0));
    try std.testing.expectEqual(ram_base + 2, cpu.regs.get(1));
}

test "unclaimed: H with half elements, size 0 and 3, P and W clear, VSTR with U" {
    try std.testing.expect(vldr.group.decode(wide(0xED99, 0x0E82)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xED91, 0x0E03)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xED91, 0x0F83)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xEC91, 0x0E83)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFD81, 0x0E81)) == null);
}
