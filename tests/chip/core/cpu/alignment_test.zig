//! Covers src/chip/core/cpu/alignment.zig and the MemA groups that call it.
const std = @import("std");
const ra8 = @import("ra8");
const alignment = ra8.chip.core.cpu.alignment;
const Instr = ra8.chip.core.cpu.instr.Instr;
const fixture = @import("exception/ram.zig");

test "memA accepts aligned accesses of every size" {
    try alignment.memA(0x2000_0001, 1);
    try alignment.memA(0x2000_0002, 2);
    try alignment.memA(0x2000_0004, 4);
    try alignment.memA(0x2000_0004, 8);
}

test "memA rejects an access off its natural alignment" {
    try std.testing.expectError(error.Unaligned, alignment.memA(0x2000_0001, 2));
    try std.testing.expectError(error.Unaligned, alignment.memA(0x2000_0002, 4));
    try std.testing.expectError(error.Unaligned, alignment.memA(0x2000_0006, 8));
}

fn exec(cpu: *ra8.chip.core.cpu.cpu.Cpu, hw1: u16, hw2: u16, size: u3) !void {
    const instr: Instr = .{ .address = fixture.code, .hw1 = hw1, .hw2 = hw2, .size = size };
    try ra8.chip.core.cpu.decode.decode(instr).?.exec(cpu, instr);
}

test "an unaligned ldrex, ldrd and ldm are all refused" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = fixture.base + 0x202;
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0xE850, 0x1F00, 4)); // ldrex r1, [r0]
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0xE9D0, 0x1200, 4)); // ldrd r1, r2, [r0]
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0xC806, 0, 2)); // ldm r0!, {r1, r2}
}

test "an unaligned MemA access that locks up stops on it with the PC left there" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.code, 0x0000_C806); // ldm r0!, {r1, r2}; movs r0, r0
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = fixture.base + 0x201;
    // FAULTMASK leaves the UsageFault nowhere to go (fault_test.zig covers taking it).
    cpu.regs.faultmask = 1;
    try std.testing.expectEqual(fixture.code, cpu.step().?.unaligned);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
    try std.testing.expectEqual(fixture.base + 0x201, cpu.regs.low[0]);
}

test "memU lets an unaligned access through while CCR.UNALIGN_TRP is clear" {
    var ram: fixture.Ram = .{};
    try alignment.memU(ram.view(), 0x2000_0001, 4);
    try alignment.memU(ram.view(), 0x2000_0001, 2);
}

test "memU refuses an unaligned access once CCR.UNALIGN_TRP is set" {
    var ram: fixture.Ram = .{};
    ram.putWord(alignment.ccr, alignment.unalign_trp);
    try std.testing.expectError(error.Unaligned, alignment.memU(ram.view(), 0x2000_0002, 4));
    try std.testing.expectError(error.Unaligned, alignment.memU(ram.view(), 0x2000_0001, 2));
    try alignment.memU(ram.view(), 0x2000_0004, 4);
    try alignment.memU(ram.view(), 0x2000_0003, 1);
}

test "a narrow and a wide LDR stop on an unaligned word only under UNALIGN_TRP" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = fixture.base + 0x202;
    try exec(&cpu, 0x6801, 0, 2); // ldr r1, [r0]
    try exec(&cpu, 0xF8D0, 0x1000, 4); // ldr.w r1, [r0]
    ram.putWord(alignment.ccr, alignment.unalign_trp);
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0x6801, 0, 2));
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0xF8D0, 0x1000, 4));
}

test "an unaligned vldr, vldm and vldr.16 are refused before touching Rn" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = fixture.base + 0x202;
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0xED90, 0x0A00, 4)); // vldr s0, [r0]
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0xECB0, 0x0A02, 4)); // vldmia r0!, {s0-s1}
    try std.testing.expectEqual(fixture.base + 0x202, cpu.regs.low[0]);
    cpu.regs.low[0] = fixture.base + 0x201;
    try std.testing.expectError(error.Unaligned, exec(&cpu, 0xED90, 0x0900, 4)); // vldr.16 s0, [r0]
}

test "aligned vldr and vldr.16 still go through" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.base + 0x204, 0x3F80_0000);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[0] = fixture.base + 0x204;
    try exec(&cpu, 0xED90, 0x0A00, 4); // vldr s0, [r0]
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(0));
    cpu.regs.low[0] = fixture.base + 0x206;
    try exec(&cpu, 0xED90, 0x0900, 4); // vldr.16 s0, [r0]
    try std.testing.expectEqual(@as(u32, 0x3F80), cpu.fp.bank.readS(0));
}
