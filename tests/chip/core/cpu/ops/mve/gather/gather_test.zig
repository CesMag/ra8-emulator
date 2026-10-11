//! Covers src/chip/core/cpu/ops/mve_gather.zig. The encodings come from LLVM's
//! assembler for -mcpu=cortex-m85 with MVE.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const vldr = ra8.chip.core.cpu.ops.mve.gather;
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

test "vldrb.u8 q0, [r1, q1] gathers bytes by offset" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 1, 0x00010203_04050607_08090A0B_0C0D0E3F);
    try step(&cpu, 0xFC91, 0x0E02);
    try std.testing.expectEqual(@as(u128, 0x00010203_04050607_08090A0B_0C0D0E3F), qreg.read(&cpu.fp.bank, 0));
}

test "vldrb.s16 q0, [r1, q1] sign-extends each gathered byte" {
    var ram = counting();
    ram.bytes[0x20] = 0x90;
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 1, 0x0001_0002_0003_0004_0005_0006_0007_0020);
    try step(&cpu, 0xEC91, 0x0E82);
    const q = qreg.read(&cpu.fp.bank, 0);
    try std.testing.expectEqual(@as(u32, 0xFF90), qreg.elem(q, .half, 0));
    try std.testing.expectEqual(@as(u32, 0x0001), qreg.elem(q, .half, 7));
}

test "vldrh.u16 q2, [r1, q3, uxtw #1] scales offsets by two" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 3, 0x0000_0001_0002_0003_0004_0005_0006_0007);
    try step(&cpu, 0xFC91, 0x4E97);
    const q = qreg.read(&cpu.fp.bank, 2);
    try std.testing.expectEqual(@as(u32, 0x0F0E), qreg.elem(q, .half, 0));
    try std.testing.expectEqual(@as(u32, 0x0100), qreg.elem(q, .half, 7));
}

test "vldrw.u32 q0, [r1, q1, uxtw #2] under a predicate zeroes inactive words" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 1, 0x00000000_0000FFFF_00000001_00000002);
    cpu.fp.vpr = vpt.open(.{ .p0 = 0x00FF }, 0b1000);
    try step(&cpu, 0xFC91, 0x0F43);
    try std.testing.expectEqual(@as(u128, 0x00000000_00000000_07060504_0B0A0908), qreg.read(&cpu.fp.bank, 0));
}

test "vstrb.32 q0, [r1, q1] scatters each word's low byte" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 0, 0x111111DD_222222CC_333333BB_444444AA);
    qreg.write(&cpu.fp.bank, 1, 0x00000000_00000003_00000009_0000000F);
    try step(&cpu, 0xEC81, 0x0F02);
    try std.testing.expectEqual(@as(u8, 0xAA), ram.bytes[0x0F]);
    try std.testing.expectEqual(@as(u8, 0xBB), ram.bytes[0x09]);
    try std.testing.expectEqual(@as(u8, 0xCC), ram.bytes[0x03]);
    try std.testing.expectEqual(@as(u8, 0xDD), ram.bytes[0x00]);
}

test "vstrw.32 q6, [sp, q7] scatters words off SP" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(13, ram_base + 0x10);
    qreg.write(&cpu.fp.bank, 6, 0x44444444_33333333_22222222_11111111);
    qreg.write(&cpu.fp.bank, 7, 0x00000000_00000004_00000008_0000000C);
    try step(&cpu, 0xEC8D, 0xCF4E);
    try std.testing.expectEqual(@as(u128, 0x11111111_22222222_33333333_44444444), bytesAt(&ram, 0x10));
}

test "word gather faults when an active element address is misaligned" {
    var ram = counting();
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(1, ram_base);
    qreg.write(&cpu.fp.bank, 1, 2);
    try std.testing.expectError(error.Unaligned, step(&cpu, 0xFC91, 0x0F42));
}

test "unclaimed: Qd is Qm on a load, os with bytes, signed same width, Rn PC, Q8+, size 3" {
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x2E02)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x0E83)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xEC91, 0x4E96)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC9F, 0x0E02)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFCD1, 0x0E02)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x0E22)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC91, 0x0FD2)) == null);
    try std.testing.expect(vldr.group.decode(wide(0xFC81, 0x0E02)) == null);
}
