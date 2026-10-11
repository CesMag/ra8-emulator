//! Covers src/chip/core/cpu/ops/mve_vldr.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vldr = ra8.chip.core.cpu.ops.mve.vldr;
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

test "vldrb.u8 q0, [r1, #3] loads sixteen bytes from the offset" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    try step(&cpu, 0xED91, 0x1E03);
    try std.testing.expectEqual(bytesAt(&ram, 3), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(ram_base, cpu.regs.get(1));
}

test "vldrh.u16 q2, [r1, #-4]! pre-indexes and writes Rn back" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base + 0x10);
    try step(&cpu, 0xED31, 0x5E82);
    try std.testing.expectEqual(bytesAt(&ram, 0x0C), qreg.read(&cpu.fp.bank, 2));
    try std.testing.expectEqual(ram_base + 0x0C, cpu.regs.get(1));
}

test "vldrw.u32 q7, [r1], #8 post-indexes" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    try step(&cpu, 0xECB1, 0xFF02);
    try std.testing.expectEqual(bytesAt(&ram, 0), qreg.read(&cpu.fp.bank, 7));
    try std.testing.expectEqual(ram_base + 8, cpu.regs.get(1));
}

test "vstrw.32 q0, [r1, #-8]! stores and writes Rn back" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 0, 0x44444444_33333333_22222222_11111111);
    cpu.regs.set(1, ram_base + 0x20);
    try step(&cpu, 0xED21, 0x1F02);
    try std.testing.expectEqual(@as(u128, 0x44444444_33333333_22222222_11111111), bytesAt(&ram, 0x18));
    try std.testing.expectEqual(ram_base + 0x18, cpu.regs.get(1));
}

test "a predicated load zeroes inactive lanes and never reads them" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 0, ~@as(u128, 0));
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x000F }, 0b1000);
    cpu.regs.set(1, ram_base + 0x38);
    try step(&cpu, 0xED91, 0x1F01);
    try std.testing.expectEqual(@as(u128, 0x3F3E3D3C), qreg.read(&cpu.fp.bank, 0));
    try std.testing.expectEqual(@as(u4, 0), cpu.fp.vpr.mask01);
}

test "a predicated store leaves inactive lanes' memory alone" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    qreg.write(&cpu.fp.bank, 1, 0x7777_6666_5555_4444_3333_2222_1111_0000);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x000C }, 0b1000);
    cpu.regs.set(1, ram_base);
    try step(&cpu, 0xED81, 0x3E81);
    try std.testing.expectEqual(@as(u128, 0x1111_0000_0000), bytesAt(&ram, 0));
}

test "a faulting load leaves Rn unwritten" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base + 0x38);
    try std.testing.expectError(bus.Error.Unmapped, step(&cpu, 0xECB1, 0xFF02));
    try std.testing.expectEqual(ram_base + 0x38, cpu.regs.get(1));
}

test "word elements fault when the contiguous base is not word aligned" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base + 2);
    try std.testing.expectError(error.Unaligned, step(&cpu, 0xECB1, 0xFF02));
}

test "an SP ram_base without writeback is claimed" {
    try std.testing.expect(vldr.group.decode(wide(0xED9D, 0x1F01)) != null);
}

test "unclaimed: PC ram_base, SP with writeback, P and W clear, Q8+, size 3" {
    try std.testing.expect(vldr.group.decode(wide(0xED9F, 0x1E03)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xED3D, 0x1E01)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xEC91, 0x1E01)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xEDD1, 0x1E03)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xED91, 0x1F83)) == null);
}
