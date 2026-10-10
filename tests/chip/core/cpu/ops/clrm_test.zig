//! Covers src/chip/core/cpu/ops/clrm.zig. Encodings checked against
//! arm-none-eabi-as -march=armv8.1-m.main.
const std = @import("std");
const ra8 = @import("ra8");
const clrm = ra8.chip.core.cpu.ops.clrm;
const table = ra8.chip.core.cpu.ops.table;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fixture = @import("../exception/ram.zig");

fn wide(hw2: u16) Instr {
    return .{ .address = fixture.code, .hw1 = clrm.encodings.clrm, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw2: u16) !void {
    try clrm.group.decode(wide(hw2)).?(cpu, wide(hw2));
}

fn fill(cpu: *Cpu) void {
    var n: u4 = 0;
    while (n < 13) : (n += 1) cpu.regs.set(n, 0x1111_0000 + @as(u32, n));
    cpu.regs.set(14, 0xFFFF_FFF9);
}

test "clrm {r0} clears only r0" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    fill(&cpu);
    const sp = cpu.regs.get(13);
    try run(&cpu, 0x0001);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(0));
    try std.testing.expectEqual(@as(u32, 0x1111_0001), cpu.regs.get(1));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF9), cpu.regs.get(14));
    try std.testing.expectEqual(sp, cpu.regs.get(13));
}

test "clrm {r2, ip, lr} clears the high registers and LR, not APSR" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    fill(&cpu);
    cpu.regs.xpsr |= 0xF800_0000;
    try run(&cpu, 0x5004);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(2));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(12));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(14));
    try std.testing.expectEqual(@as(u32, 0x1111_000B), cpu.regs.get(11));
    try std.testing.expectEqual(@as(u32, 0xF800_0000), cpu.regs.xpsr & 0xF800_0000);
}

test "clrm {r0, r1, apsr} clears NZCVQ and GE, keeps T and IPSR" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    fill(&cpu);
    const thumb: u32 = 1 << 24;
    cpu.regs.xpsr = 0xF80F_0000 | thumb | 0x0F;
    try run(&cpu, 0x8003);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(0));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(1));
    try std.testing.expectEqual(@as(u32, 0x1111_0002), cpu.regs.get(2));
    try std.testing.expectEqual(thumb | 0x0F, cpu.regs.xpsr);
}

test "clrm with every register and APSR leaves only SP and PC" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    fill(&cpu);
    const sp = cpu.regs.get(13);
    cpu.regs.xpsr |= 0xF80F_0000;
    try run(&cpu, 0xDFFF);
    var n: u4 = 0;
    while (n < 13) : (n += 1) try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(n));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.get(14));
    try std.testing.expectEqual(sp, cpu.regs.get(13));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & 0xF80F_0000);
}

test "the table routes E89F to clrm and refuses the UNPREDICTABLE lists" {
    var claimed: usize = 0;
    for (table.groups) |g| {
        if (g.decode(wide(0x8003)) == null) continue;
        claimed += 1;
        try std.testing.expectEqualStrings("clrm", g.name);
    }
    try std.testing.expectEqual(@as(usize, 1), claimed);
    try std.testing.expect(clrm.group.decode(wide(0x0000)) == null); // empty
    try std.testing.expect(clrm.group.decode(wide(0x2001)) == null); // SP
    const ldm: Instr = .{ .address = fixture.code, .hw1 = 0xE891, .hw2 = 0x0003, .size = 4 };
    try std.testing.expect(clrm.group.decode(ldm) == null);
}
