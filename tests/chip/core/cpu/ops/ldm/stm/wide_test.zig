//! Covers src/chip/core/cpu/ops/ldm_stm_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const ldm_stm_wide = ra8.chip.core.cpu.ops.ldm.stm.wide;

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

fn instr(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = ldm_stm_wide.group.decode(instr(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, instr(hw1, hw2));
}

fn claimed(hw1: u16, hw2: u16) bool {
    return ldm_stm_wide.group.decode(instr(hw1, hw2)) != null;
}

fn word(ram: *Ram, offset: usize) u32 {
    return std.mem.readInt(u32, ram.bytes[offset..][0..4], .little);
}

test "push.w {r4-r9, lr} is the blink_hal encoding and stacks lowest first" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.setSp(Ram.base + 64);
    for (4..10) |i| cpu.regs.set(@intCast(i), @intCast(0x40 + i));
    cpu.regs.set(14, 0x0800_1235);
    try run(&cpu, 0xE92D, 0x43F0);
    try std.testing.expectEqual(Ram.base + 64 - 28, cpu.regs.sp());
    try std.testing.expectEqual(@as(u32, 0x44), word(&ram, 36));
    try std.testing.expectEqual(@as(u32, 0x49), word(&ram, 56));
    try std.testing.expectEqual(@as(u32, 0x0800_1235), word(&ram, 60));
}

test "pop.w {r4, r5, pc} restores the registers and branches with BXWritePC" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    std.mem.writeInt(u32, ram.bytes[0..4], 0x1111, .little);
    std.mem.writeInt(u32, ram.bytes[4..8], 0x2222, .little);
    std.mem.writeInt(u32, ram.bytes[8..12], 0x0800_0101, .little);
    cpu.regs.setSp(Ram.base);
    try run(&cpu, 0xE8BD, 0x8030);
    try std.testing.expectEqual(@as(u32, 0x1111), cpu.regs.get(4));
    try std.testing.expectEqual(@as(u32, 0x2222), cpu.regs.get(5));
    try std.testing.expectEqual(@as(u32, 0x0800_0100), cpu.regs.pc);
    try std.testing.expectEqual(Ram.base + 12, cpu.regs.sp());
}

test "stmia.w without writeback and ldmdb.w with writeback" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(0, Ram.base + 8);
    cpu.regs.set(1, 0xA);
    cpu.regs.set(2, 0xB);
    try run(&cpu, 0xE880, 0x0006); // stm.w r0, {r1, r2}
    try std.testing.expectEqual(@as(u32, 0xA), word(&ram, 8));
    try std.testing.expectEqual(@as(u32, 0xB), word(&ram, 12));
    try std.testing.expectEqual(Ram.base + 8, cpu.regs.get(0));
    cpu.regs.set(3, Ram.base + 16);
    try run(&cpu, 0xE933, 0x0060); // ldmdb r3!, {r5, r6}
    try std.testing.expectEqual(@as(u32, 0xA), cpu.regs.get(5));
    try std.testing.expectEqual(@as(u32, 0xB), cpu.regs.get(6));
    try std.testing.expectEqual(Ram.base + 8, cpu.regs.get(3));
}

test "unpredictable lists stay unclaimed" {
    try std.testing.expect(!claimed(0xE92D, 0x0010)); // one register
    try std.testing.expect(!claimed(0xE92D, 0x2010)); // SP in the list
    try std.testing.expect(!claimed(0xE92D, 0x8010)); // PC in a store list
    try std.testing.expect(!claimed(0xE8BD, 0xC010)); // P and M both set
    try std.testing.expect(!claimed(0xE8B1, 0x0006)); // writeback with Rn listed
    try std.testing.expect(!claimed(0xE89F, 0x0006)); // Rn = PC
}
