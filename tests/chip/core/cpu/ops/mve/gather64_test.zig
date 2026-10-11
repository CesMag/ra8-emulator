//! Covers src/chip/core/cpu/ops/mve_gather64.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vldr = ra8.chip.core.cpu.ops.mve.gather64;
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

test "vldrd.u64 q0, [r1, q1] gathers two doublewords" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 1, 0xFFFFFFFF_00000008_FFFFFFFF_00000020);
    try step(&cpu, 0xFC91, 0x0FD2);
    try std.testing.expectEqual(@as(u128, 0x0F0E0D0C_0B0A0908_27262524_23222120), qreg.read(&cpu.fp.bank, 0));
}

test "doubleword gather faults when a word beat is misaligned" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base + 2);
    try std.testing.expectError(error.Unaligned, step(&cpu, 0xFC91, 0x0FD2));
}

test "vldrd.u64 q2, [r1, q3, uxtw #3] under a predicate zeroes the inactive beat" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 3, 0x00000000_00000001_00000000_00000002);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x0FFF }, 0b1000);
    try step(&cpu, 0xFC91, 0x4FD7);
    try std.testing.expectEqual(@as(u128, 0x00000000_0B0A0908_17161514_13121110), qreg.read(&cpu.fp.bank, 2));
}

test "vstrd.64 q4, [sp, q5, uxtw #3] scatters doublewords off SP" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(13, ram_base);
    qreg.write(&cpu.fp.bank, 4, 0x44444444_33333333_22222222_11111111);
    qreg.write(&cpu.fp.bank, 5, 0x00000000_00000000_00000000_00000001);
    try step(&cpu, 0xEC8D, 0x8FDB);
    try std.testing.expectEqual(@as(u128, 0x44444444_33333333), bytesAt(&ram, 0) & 0xFFFFFFFF_FFFFFFFF);
    try std.testing.expectEqual(@as(u64, 0x22222222_11111111), std.mem.readInt(u64, ram.bytes[8..16], .little));
}

test "unclaimed: signed load, store with U, Qd is Qm, Rn PC, Q8+" {
    try std.testing.expect(vldr.group.decode(wide(0xEC91, 0x0FD2)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC81, 0x0FD2)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x2FD2)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC9F, 0x0FD2)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFCD1, 0x0FD2)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x0FF2)) == null);
}
