//! Covers src/chip/core/cpu/ops/ldrd_strd.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const ldrd_strd = ra8.chip.core.cpu.ops.ldrd_strd;

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

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
    const exec = ldrd_strd.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn claimed(hw1: u16, hw2: u16) bool {
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
    return ldrd_strd.group.decode(instr) != null;
}

fn word(ram: *Ram, offset: usize) u32 {
    return std.mem.readInt(u32, ram.bytes[offset..][0..4], .little);
}

test "strd r0, r1, [r4, #4] is the blink_hal encoding and keeps Rn" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[4] = Ram.base + 8;
    cpu.regs.low[0] = 0x1111_1111;
    cpu.regs.low[1] = 0x2222_2222;
    try run(&cpu, 0xE9C4, 0x0101);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), word(&ram, 12));
    try std.testing.expectEqual(@as(u32, 0x2222_2222), word(&ram, 16));
    try std.testing.expectEqual(Ram.base + 8, cpu.regs.low[4]);
}

test "ldrd r2, r3, [r5], #8 loads then writes the base back" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    std.mem.writeInt(u32, ram.bytes[0..4], 0xAAAA_0001, .little);
    std.mem.writeInt(u32, ram.bytes[4..8], 0xBBBB_0002, .little);
    cpu.regs.low[5] = Ram.base;
    try run(&cpu, 0xE8F5, 0x2302);
    try std.testing.expectEqual(@as(u32, 0xAAAA_0001), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0xBBBB_0002), cpu.regs.low[3]);
    try std.testing.expectEqual(Ram.base + 8, cpu.regs.low[5]);
}

test "strd r0, r1, [r6, #-8]! pre-indexes downward" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[6] = Ram.base + 16;
    cpu.regs.low[0] = 7;
    cpu.regs.low[1] = 9;
    try run(&cpu, 0xE966, 0x0102);
    try std.testing.expectEqual(@as(u32, 7), word(&ram, 8));
    try std.testing.expectEqual(@as(u32, 9), word(&ram, 12));
    try std.testing.expectEqual(Ram.base + 8, cpu.regs.low[6]);
}

test "unpredictable and neighbouring encodings stay unclaimed" {
    try std.testing.expect(!claimed(0xE845, 0x0100)); // P=0 W=0: exclusive space
    try std.testing.expect(!claimed(0xE9DF, 0x0101)); // literal LDRD
    try std.testing.expect(!claimed(0xE9D4, 0x0001)); // LDRD Rt = Rt2
    try std.testing.expect(!claimed(0xE9C4, 0xD101)); // SP as Rt
    try std.testing.expect(!claimed(0xE9E4, 0x4101)); // writeback with Rn = Rt
}
