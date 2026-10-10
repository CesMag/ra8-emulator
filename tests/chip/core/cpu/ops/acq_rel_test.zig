//! Covers src/chip/core/cpu/ops/acq_rel.zig.
const std = @import("std");
const ra8 = @import("ra8");
const ar = ra8.chip.core.cpu.ops.acq_rel;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fixture = @import("../exception/ram.zig");

const data: u32 = fixture.base + 0x200;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = fixture.code, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    try ar.group.decode(instr).?(cpu, instr);
}

test "lda, ldab and ldah load from Rn zero-extended" {
    var ram: fixture.Ram = .{};
    ram.putWord(data, 0x8899_AABB);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data;
    try run(&cpu, 0xE8D0, 0x1FAF); // lda r1, [r0]
    try std.testing.expectEqual(@as(u32, 0x8899_AABB), cpu.regs.low[1]);
    try run(&cpu, 0xE8D0, 0x2F9F); // ldah r2, [r0]
    try std.testing.expectEqual(@as(u32, 0xAABB), cpu.regs.low[2]);
    try run(&cpu, 0xE8D0, 0x3F8F); // ldab r3, [r0]
    try std.testing.expectEqual(@as(u32, 0xBB), cpu.regs.low[3]);
}

test "stl, stlb and stlh store their width and leave the monitor alone" {
    var ram: fixture.Ram = .{};
    ram.putWord(data, 0xFFFF_FFFF);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data;
    cpu.regs.low[1] = 0x1234_5678;
    cpu.exclusive = data + 8;
    try run(&cpu, 0xE8C0, 0x1F8F); // stlb r1, [r0]
    try std.testing.expectEqual(@as(u32, 0xFFFF_FF78), try cpu.bus.readWord(data));
    try run(&cpu, 0xE8C0, 0x1F9F); // stlh r1, [r0]
    try std.testing.expectEqual(@as(u32, 0xFFFF_5678), try cpu.bus.readWord(data));
    try run(&cpu, 0xE8C0, 0x1FAF); // stl r1, [r0]
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try cpu.bus.readWord(data));
    try std.testing.expectEqual(@as(?u32, data + 8), cpu.exclusive);
}

test "an unaligned lda, ldah or stl is a MemA fault" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data + 1;
    try std.testing.expectError(error.Unaligned, run(&cpu, 0xE8D0, 0x1FAF));
    try std.testing.expectError(error.Unaligned, run(&cpu, 0xE8D0, 0x1F9F));
    try std.testing.expectError(error.Unaligned, run(&cpu, 0xE8C0, 0x1FAF));
    try run(&cpu, 0xE8D0, 0x1F8F); // ldab at any address
}

test "SP or PC as Rt, PC as Rn, sz 11 and the other op3 values stay unclaimed" {
    const cases = [_][2]u16{
        .{ 0xE8D0, 0xDFAF }, // rt = sp
        .{ 0xE8D0, 0xFFAF }, // rt = pc
        .{ 0xE8DF, 0x1FAF }, // rn = pc
        .{ 0xE8D0, 0x1FBF }, // sz 11
        .{ 0xE8D0, 0x1FEF }, // ldaex, exclusive.zig's
        .{ 0xE8D0, 0x1F4F }, // ldrexb, exclusive.zig's
        .{ 0xE8D0, 0xF001 }, // tbb
        .{ 0xE8D0, 0x1FA0 }, // low nibble not 1111
    };
    for (cases) |c| try std.testing.expect(ar.access(wide(c[0], c[1])) == null);
}
