//! Covers src/chip/core/cpu/ops/ldst_wide.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const regs = ra8.chip.core.cpu.regs;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const ldst_wide = ra8.chip.core.cpu.ops.ldst_wide;

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

fn instr(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const exec = ldst_wide.group.decode(instr(hw1, hw2)) orelse return error.NotClaimed;
    try exec(cpu, instr(hw1, hw2));
}

fn word(ram: *Ram, offset: usize) u32 {
    return std.mem.readInt(u32, ram.bytes[offset..][0..4], .little);
}

test "str.w and ldr.w with imm12 add the offset and leave Rn alone" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[7] = Ram.base;
    cpu.regs.low[3] = 0xCAFE_F00D;
    try run(&cpu, 0xF8C7, 0x300C); // str.w r3, [r7, #12]
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), word(&ram, 12));
    try run(&cpu, 0xF8D7, 0x000C); // ldr.w r0, [r7, #12]
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.low[0]);
    try std.testing.expectEqual(Ram.base, cpu.regs.low[7]);
}

test "ldr r7, [sp], #4 loads from SP then moves it up, a wide pop" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.msp = Ram.base + 16;
    std.mem.writeInt(u32, ram.bytes[16..20], 0x1234_5678, .little);
    try run(&cpu, 0xF85D, 0x7B04);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.regs.low[7]);
    try std.testing.expectEqual(Ram.base + 20, cpu.regs.msp);
}

test "str r0, [sp, #-4]! moves SP down first, a wide push" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.msp = Ram.base + 32;
    cpu.regs.low[0] = 0xA5A5_0001;
    try run(&cpu, 0xF84D, 0x0D04);
    try std.testing.expectEqual(Ram.base + 28, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0xA5A5_0001), word(&ram, 28));
}

test "a negative imm8 offset without writeback leaves Rn alone" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base + 24;
    std.mem.writeInt(u32, ram.bytes[16..20], 0x0BAD_CAFE, .little);
    try run(&cpu, 0xF851, 0x0C08); // ldr r0, [r1, #-8]
    try std.testing.expectEqual(@as(u32, 0x0BAD_CAFE), cpu.regs.low[0]);
    try std.testing.expectEqual(Ram.base + 24, cpu.regs.low[1]);
}

test "byte and halfword stores write their width, signed loads extend" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 0xFFFF_8081;
    try run(&cpu, 0xF881, 0x2003); // strb.w r2, [r1, #3]
    try run(&cpu, 0xF8A1, 0x2004); // strh.w r2, [r1, #4]
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x81, 0x81, 0x80, 0x00 }, ram.bytes[2..7]);
    try run(&cpu, 0xF891, 0x3003); // ldrb.w r3, [r1, #3]
    try std.testing.expectEqual(@as(u32, 0x81), cpu.regs.low[3]);
    try run(&cpu, 0xF8B1, 0x3004); // ldrh.w r3, [r1, #4]
    try std.testing.expectEqual(@as(u32, 0x8081), cpu.regs.low[3]);
    try run(&cpu, 0xF991, 0x3003); // ldrsb.w r3, [r1, #3]
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF81), cpu.regs.low[3]);
    try run(&cpu, 0xF9B1, 0x3004); // ldrsh.w r3, [r1, #4]
    try std.testing.expectEqual(@as(u32, 0xFFFF_8081), cpu.regs.low[3]);
}

test "ldr.w pc writes the PC the BX way" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base;
    std.mem.writeInt(u32, ram.bytes[0..4], 0x0200_1235, .little);
    try run(&cpu, 0xF8D1, 0xF000);
    try std.testing.expectEqual(@as(u32, 0x0200_1234), cpu.regs.pc);
    try std.testing.expect(cpu.regs.xpsr & regs.xpsr_bits.thumb != 0);
}

test "an unmapped address is a bus error and writes nothing back" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = 0x1000_0000;
    try std.testing.expectError(bus.Error.Unmapped, run(&cpu, 0xF851, 0x0B04));
    try std.testing.expectEqual(@as(u32, 0x1000_0000), cpu.regs.low[1]);
}

test "the LDRT/STRT family: positive imm8, no writeback, marked unprivileged" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.low[1] = Ram.base;
    cpu.regs.low[2] = 0x8899_F0E1;
    try run(&cpu, 0xF841, 0x2E08); // strt r2, [r1, #8]
    try std.testing.expectEqual(@as(u32, 0x8899_F0E1), word(&ram, 8));
    try run(&cpu, 0xF801, 0x2E10); // strbt r2, [r1, #16]
    try run(&cpu, 0xF821, 0x2E14); // strht r2, [r1, #20]
    try std.testing.expectEqual(@as(u32, 0xE1), word(&ram, 16));
    try std.testing.expectEqual(@as(u32, 0xF0E1), word(&ram, 20));
    const loads = [_][3]u32{
        .{ 0xF851, 0x0E08, 0x8899_F0E1 }, // ldrt r0, [r1, #8]
        .{ 0xF811, 0x0E08, 0xE1 }, // ldrbt
        .{ 0xF911, 0x0E08, 0xFFFF_FFE1 }, // ldrsbt
        .{ 0xF831, 0x0E08, 0xF0E1 }, // ldrht
        .{ 0xF931, 0x0E08, 0xFFFF_F0E1 }, // ldrsht
    };
    for (loads) |l| {
        try run(&cpu, @intCast(l[0]), @intCast(l[1]));
        try std.testing.expectEqual(l[2], cpu.regs.low[0]);
        const f = ldst_wide.form(instr(@intCast(l[0]), @intCast(l[1]))).?;
        try std.testing.expect(f.unprivileged and !f.writeback and f.index and f.add);
    }
    try std.testing.expectEqual(Ram.base, cpu.regs.low[1]);
    try std.testing.expect(!ldst_wide.form(instr(0xF851, 0x0C04)).?.unprivileged); // ldr r0, [r1, #-4]
}

test "leaves literal, register and UNPREDICTABLE forms alone" {
    const unclaimed = [_][2]u16{
        .{ 0xF8DF, 0x0004 }, // ldr.w r0, [pc, #4]
        .{ 0xF851, 0xDE04 }, // ldrt sp, [r1, #4]
        .{ 0xF851, 0xFE04 }, // ldrt pc, [r1, #4]
        .{ 0xF851, 0x0804 }, // P=0 W=0
        .{ 0xF851, 0x0002 }, // ldr.w r0, [r1, r2]
        .{ 0xF851, 0x1B04 }, // ldr r1, [r1], #4
        .{ 0xF891, 0xF001 }, // pld [r1, #1]
        .{ 0xF8C1, 0xF000 }, // str.w pc, [r1]
        .{ 0xF881, 0xD000 }, // strb.w sp, [r1]
        .{ 0xF8E1, 0x0000 }, // size 0b11
        .{ 0xF9D1, 0x0000 }, // signed word
        .{ 0xF981, 0x0000 }, // signed store
    };
    for (unclaimed) |e| try std.testing.expect(ldst_wide.group.decode(instr(e[0], e[1])) == null);
    const narrow: Instr = .{ .address = 0, .hw1 = 0x6808, .size = 2 };
    try std.testing.expect(ldst_wide.group.decode(narrow) == null);
}
