//! Covers src/chip/core/cpu/ops/exclusive.zig.
const std = @import("std");
const ra8 = @import("ra8");
const ex = ra8.chip.core.cpu.ops.exclusive;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fixture = @import("../exception/ram.zig");

const data: u32 = fixture.base + 0x200;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = fixture.code, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const instr = wide(hw1, hw2);
    try ex.group.decode(instr).?(cpu, instr);
}

test "ldrex then strex to the same address stores and reports 0" {
    var ram: fixture.Ram = .{};
    ram.putWord(data + 4, 0x1111_2222);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data;
    try run(&cpu, 0xE850, 0x1F01); // ldrex r1, [r0, #4]
    try std.testing.expectEqual(@as(u32, 0x1111_2222), cpu.regs.low[1]);
    try std.testing.expectEqual(@as(?u32, data + 4), cpu.exclusive);
    cpu.regs.low[3] = 0xAAAA_BBBB;
    try run(&cpu, 0xE840, 0x3201); // strex r2, r3, [r0, #4]
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0xAAAA_BBBB), try cpu.bus.readWord(data + 4));
    try std.testing.expectEqual(@as(?u32, null), cpu.exclusive);
}

test "strex without the monitor, or after clrex, stores nothing and reports 1" {
    var ram: fixture.Ram = .{};
    ram.putWord(data, 0x5555_5555);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data;
    cpu.regs.low[3] = 0x77;
    try run(&cpu, 0xE840, 0x3200); // strex r2, r3, [r0]
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[2]);
    try run(&cpu, 0xE850, 0x1F00); // ldrex r1, [r0]
    try run(&cpu, 0xF3BF, 0x8F2F); // clrex
    try run(&cpu, 0xE840, 0x3200);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0x5555_5555), try cpu.bus.readWord(data));
}

test "strex to another address fails" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data;
    try run(&cpu, 0xE850, 0x1F00); // ldrex r1, [r0]
    try run(&cpu, 0xE840, 0x3201); // strex r2, r3, [r0, #4]
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[2]);
}

test "byte and halfword forms load zero-extended and store their width" {
    var ram: fixture.Ram = .{};
    ram.putWord(data, 0xFFFF_FFFF);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data;
    try run(&cpu, 0xE8D0, 0x1F5F); // ldrexh r1, [r0]
    try std.testing.expectEqual(@as(u32, 0xFFFF), cpu.regs.low[1]);
    cpu.regs.low[3] = 0x1234_5678;
    try run(&cpu, 0xE8C0, 0x3F52); // strexh r2, r3, [r0]
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[2]);
    try run(&cpu, 0xE8D0, 0x1F4F); // ldrexb r1, [r0]
    try std.testing.expectEqual(@as(u32, 0x78), cpu.regs.low[1]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_5678), try cpu.bus.readWord(data));
}

test "ldaex then stlex, in word, halfword and byte, use the monitor with no offset" {
    var ram: fixture.Ram = .{};
    ram.putWord(data, 0xFFFF_FFFF);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = data;
    cpu.regs.low[3] = 0x1234_5678;
    try run(&cpu, 0xE8D0, 0x1FEF); // ldaex r1, [r0]
    try std.testing.expectEqual(@as(?u32, data), cpu.exclusive);
    try run(&cpu, 0xE8C0, 0x3FE2); // stlex r2, r3, [r0]
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try cpu.bus.readWord(data));
    try run(&cpu, 0xE8D0, 0x1FDF); // ldaexh r1, [r0]
    try std.testing.expectEqual(@as(u32, 0x5678), cpu.regs.low[1]);
    cpu.regs.low[3] = 0xAB;
    try run(&cpu, 0xE8C0, 0x3FC2); // stlexb r2, r3, [r0]: monitor tagged by ldaexh
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0x1234_56AB), try cpu.bus.readWord(data));
    try run(&cpu, 0xE8C0, 0x3FD2); // stlexh with the monitor clear
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[2]);
}

test "exception entry clears the monitor" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.exclusive = data;
    _ = try ra8.chip.core.cpu.exception.entry.take(&cpu, 11, fixture.code);
    try std.testing.expectEqual(@as(?u32, null), cpu.exclusive);
}

test "unpredictable registers and TBB stay unclaimed" {
    try std.testing.expect(ex.access(wide(0xE85F, 0x1F00)) == null); // rn = pc
    try std.testing.expect(ex.access(wide(0xE850, 0xDF00)) == null); // rt = sp
    try std.testing.expect(ex.access(wide(0xE840, 0x3300)) == null); // rd = rt
    try std.testing.expect(ex.access(wide(0xE840, 0x3000)) == null); // rd = rn
    try std.testing.expect(ex.access(wide(0xE8D0, 0xF000)) == null); // tbb
    try std.testing.expect(ex.access(wide(0xE8D0, 0x1F6F)) == null); // op3 0110
    try std.testing.expect(ex.access(wide(0xE8D0, 0x1FAF)) == null); // lda, acq_rel.zig's
    try std.testing.expect(ex.access(wide(0xE8C0, 0x3FE3)) == null); // stlex rd = rt
    try std.testing.expect(ex.group.decode(wide(0xF3BF, 0x8F4F)) == null); // dsb, not clrex
}
