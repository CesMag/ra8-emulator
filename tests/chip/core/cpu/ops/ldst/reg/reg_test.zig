//! Covers src/chip/core/cpu/ops/ldst_reg.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const ldst_reg = ra8.chip.core.cpu.ops.ldst.reg;

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
    const exec = ldst_reg.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "str and ldr [Rn, Rm] add the two registers" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base + 4;
    cpu.regs.low[2] = 8;
    cpu.regs.low[3] = 0x1234_5678;
    try run(&cpu, 0x508B); // str r3, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, ram.bytes[12..16], .little));
    try run(&cpu, 0x588C); // ldr r4, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.regs.low[4]);
}

test "byte and halfword stores write only their width" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 1;
    cpu.regs.low[3] = 0xAABB_CCDD;
    try run(&cpu, 0x548B); // strb r3, [r1, r2]
    cpu.regs.low[2] = 2;
    try run(&cpu, 0x528B); // strh r3, [r1, r2]
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xDD, 0xDD, 0xCC, 0x00 }, ram.bytes[0..5]);
}

test "ldrb and ldrh zero-extend, ldrsb and ldrsh sign-extend" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.bytes[0] = 0x81;
    ram.bytes[2] = 0x34;
    ram.bytes[3] = 0x92;
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 0;
    try run(&cpu, 0x5C8B); // ldrb r3, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0x81), cpu.regs.low[3]);
    try run(&cpu, 0x568B); // ldrsb r3, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF81), cpu.regs.low[3]);
    cpu.regs.low[2] = 2;
    try run(&cpu, 0x5A8B); // ldrh r3, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0x9234), cpu.regs.low[3]);
    try run(&cpu, 0x5E8B); // ldrsh r3, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0xFFFF_9234), cpu.regs.low[3]);
}

test "a positive halfword stays positive under ldrsh" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.bytes[0] = 0xFF;
    ram.bytes[1] = 0x7F;
    cpu.regs.low[1] = Ram.base;
    try run(&cpu, 0x5E8B); // ldrsh r3, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0x7FFF), cpu.regs.low[3]);
}

test "the group leaves the immediate-offset and wide space alone" {
    const imm: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = 0x6000, .size = 2 };
    try std.testing.expect(ldst_reg.group.decode(imm) == null);
    const wide: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = 0x5000, .hw2 = 0, .size = 4 };
    try std.testing.expect(ldst_reg.group.decode(wide) == null);
}
