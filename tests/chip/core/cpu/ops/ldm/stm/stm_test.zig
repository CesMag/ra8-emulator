//! Covers src/chip/core/cpu/ops/ldm/stm/stm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const ldm_stm = ra8.chip.core.cpu.ops.ldm.stm;

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

fn run(cpu: *Cpu, hw1: u16) !void {
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = hw1, .size = 2 };
    const exec = ldm_stm.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "stm r1!, {r2, r4} stores lowest first and writes back" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base + 8;
    cpu.regs.low[2] = 0x2222_2222;
    cpu.regs.low[4] = 0x4444_4444;
    try run(&cpu, 0xC114);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), std.mem.readInt(u32, ram.bytes[8..12], .little));
    try std.testing.expectEqual(@as(u32, 0x4444_4444), std.mem.readInt(u32, ram.bytes[12..16], .little));
    try std.testing.expectEqual(Ram.base + 16, cpu.regs.low[1]);
}

test "ldm r0!, {r1, r2} loads and writes back when the base is not listed" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    std.mem.writeInt(u32, ram.bytes[0..4], 0xAAAA_0001, .little);
    std.mem.writeInt(u32, ram.bytes[4..8], 0xBBBB_0002, .little);
    cpu.regs.low[0] = Ram.base;
    try run(&cpu, 0xC806);
    try std.testing.expectEqual(@as(u32, 0xAAAA_0001), cpu.regs.low[1]);
    try std.testing.expectEqual(@as(u32, 0xBBBB_0002), cpu.regs.low[2]);
    try std.testing.expectEqual(Ram.base + 8, cpu.regs.low[0]);
}

test "ldm r0, {r0, r3} keeps the loaded base and skips writeback" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    std.mem.writeInt(u32, ram.bytes[0..4], 0x1234_0000, .little);
    std.mem.writeInt(u32, ram.bytes[4..8], 0x0000_5678, .little);
    cpu.regs.low[0] = Ram.base;
    try run(&cpu, 0xC809);
    try std.testing.expectEqual(@as(u32, 0x1234_0000), cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 0x0000_5678), cpu.regs.low[3]);
}

test "an empty list and the 32-bit space stay unclaimed" {
    const empty: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = 0xC800, .size = 2 };
    try std.testing.expect(ldm_stm.group.decode(empty) == null);
    const wide: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = 0xC0FF, .hw2 = 0, .size = 4 };
    try std.testing.expect(ldm_stm.group.decode(wide) == null);
}
