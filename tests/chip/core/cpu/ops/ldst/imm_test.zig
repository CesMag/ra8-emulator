//! Covers src/chip/core/cpu/ops/ldst/imm.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const ldst_imm = ra8.chip.core.cpu.ops.ldst.imm;

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
    const exec = ldst_imm.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "str r3, [r7, #12] and ldr back scale imm5 by four" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[7] = Ram.base + 8;
    cpu.regs.low[3] = 0xCAFE_F00D;
    try run(&cpu, 0x60FB);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), std.mem.readInt(u32, ram.bytes[20..24], .little));
    try run(&cpu, 0x68F8); // ldr r0, [r7, #12]
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.low[0]);
}

test "byte and halfword stores write only their width and loads zero-extend" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 0xFFFF_FF81;
    try run(&cpu, 0x704A); // strb r2, [r1, #1]
    try run(&cpu, 0x804A); // strh r2, [r1, #2]
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x81, 0x81, 0xFF, 0x00 }, ram.bytes[0..5]);
    try run(&cpu, 0x784B); // ldrb r3, [r1, #1]
    try std.testing.expectEqual(@as(u32, 0x81), cpu.regs.low[3]);
    try run(&cpu, 0x884C); // ldrh r4, [r1, #2]
    try std.testing.expectEqual(@as(u32, 0xFF81), cpu.regs.low[4]);
}

test "sp-relative str and ldr use the selected stack and scale imm8" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.control = regs.control_bits.spsel;
    cpu.regs.psp = Ram.base + 16;
    cpu.regs.low[5] = 0x1234_5678;
    try run(&cpu, 0x9502); // str r5, [sp, #8]
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, ram.bytes[24..28], .little));
    try run(&cpu, 0x9E02); // ldr r6, [sp, #8]
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.regs.low[6]);
}

test "a fault on load leaves Rt alone" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[0] = 0x1000_0000;
    cpu.regs.low[1] = 9;
    try std.testing.expectError(bus.Error.Unmapped, run(&cpu, 0x6801)); // ldr r1, [r0]
    try std.testing.expectEqual(@as(u32, 9), cpu.regs.low[1]);
}

test "neighbouring encodings are not claimed" {
    // 5800 ldr reg, 4800 ldr literal, a800 add rd sp, b580 push, 5000 str reg
    for ([_]u16{ 0x5800, 0x4800, 0xA800, 0xB580, 0x5000 }) |hw1| {
        try std.testing.expect(ldst_imm.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
