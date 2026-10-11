//! Covers src/chip/core/cpu/ops/ldst_reg_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const ldst_reg_wide = ra8.chip.core.cpu.ops.ldst.reg.wide;

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

fn wide(hw1: u16, hw2: u16) ra8.chip.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = ldst_reg_wide.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, wide(hw1, hw2));
}

test "ldrh.w r0, [r1, r0, lsl #1] is the blink_hal and threadx_blink encoding" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.bytes[6] = 0xCD;
    ram.bytes[7] = 0xAB;
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[0] = 3;
    try run(&cpu, 0xF831, 0x0010);
    try std.testing.expectEqual(@as(u32, 0xABCD), cpu.regs.low[0]);
}

test "str.w and ldr.w round-trip with lsl #2" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 4;
    cpu.regs.low[3] = 0x1234_5678;
    try run(&cpu, 0xF841, 0x3022); // str.w r3, [r1, r2, lsl #2]
    try std.testing.expectEqual(@as(u8, 0x78), ram.bytes[16]);
    try run(&cpu, 0xF851, 0x4022); // ldr.w r4, [r1, r2, lsl #2]
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.regs.low[4]);
}

test "strb.w, strh.w and the sign-extending loads" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 1;
    cpu.regs.low[3] = 0xFFFF_FF80;
    try run(&cpu, 0xF801, 0x3002); // strb.w r3, [r1, r2]
    try run(&cpu, 0xF911, 0x4002); // ldrsb.w r4, [r1, r2]
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF80), cpu.regs.low[4]);
    cpu.regs.low[3] = 0x8001;
    try run(&cpu, 0xF821, 0x3012); // strh.w r3, [r1, r2, lsl #1]
    try run(&cpu, 0xF931, 0x5012); // ldrsh.w r5, [r1, r2, lsl #1]
    try std.testing.expectEqual(@as(u32, 0xFFFF_8001), cpu.regs.low[5]);
    try run(&cpu, 0xF811, 0x6012); // ldrb.w r6, [r1, r2, lsl #1]
    try std.testing.expectEqual(@as(u32, 0x01), cpu.regs.low[6]);
}

test "ldr.w pc branches through BXWritePC" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = regs.xpsr_bits.thumb } };
    std.mem.writeInt(u32, ram.bytes[8..12], 0x0200_1235, .little);
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 2;
    try run(&cpu, 0xF851, 0xF022); // ldr.w pc, [r1, r2, lsl #2]
    try std.testing.expectEqual(@as(u32, 0x0200_1234), cpu.regs.pc);
}

test "literal, sp/pc offsets, a pc store, hints and the immediate forms stay unclaimed" {
    try std.testing.expect(ldst_reg_wide.group.decode(wide(0xF85F, 0x0002)) == null); // Rn = PC
    try std.testing.expect(ldst_reg_wide.group.decode(wide(0xF851, 0x000D)) == null); // Rm = SP
    try std.testing.expect(ldst_reg_wide.group.decode(wide(0xF841, 0xF002)) == null); // str pc
    try std.testing.expect(ldst_reg_wide.group.decode(wide(0xF811, 0xF002)) == null); // PLD
    try std.testing.expect(ldst_reg_wide.group.decode(wide(0xF831, 0xD002)) == null); // ldrh sp
    try std.testing.expect(ldst_reg_wide.group.decode(wide(0xF851, 0x0C04)) == null); // LDR imm8
}
