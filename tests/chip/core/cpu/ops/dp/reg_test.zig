//! Covers src/chip/core/cpu/ops/dp_reg.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const regs = ra8.chip.core.cpu.regs;
const flags = ra8.chip.core.cpu.flags;
const dp_reg = ra8.chip.core.cpu.ops.dp.reg;

const thumb = regs.xpsr_bits.thumb;
const N = flags.bits.n;
const Z = flags.bits.z;
const C = flags.bits.c;
const V = flags.bits.v;

/// hw1 0x4000 | opcode << 6 | rm << 3 | rdn, with r0 = x and r1 = y.
const Case = struct { opcode: u4, x: u32, y: u32, carry_in: bool = false, r0: u32, apsr: u32 };

const cases = [_]Case{
    .{ .opcode = 0x0, .x = 0xF0F0, .y = 0x0FF0, .r0 = 0x00F0, .apsr = 0 },
    .{ .opcode = 0x0, .x = 0xF0, .y = 0x0F, .carry_in = true, .r0 = 0, .apsr = Z | C },
    .{ .opcode = 0x1, .x = 0x8000_0000, .y = 1, .r0 = 0x8000_0001, .apsr = N },
    .{ .opcode = 0x2, .x = 0x8000_0001, .y = 1, .r0 = 2, .apsr = C },
    .{ .opcode = 0x2, .x = 1, .y = 0x100, .carry_in = true, .r0 = 1, .apsr = C }, // amount = Rm[7:0] = 0
    .{ .opcode = 0x3, .x = 0x8000_0000, .y = 32, .r0 = 0, .apsr = Z | C },
    .{ .opcode = 0x4, .x = 0x8000_0000, .y = 33, .r0 = 0xFFFF_FFFF, .apsr = N | C },
    .{ .opcode = 0x5, .x = 1, .y = 2, .carry_in = true, .r0 = 4, .apsr = 0 },
    .{ .opcode = 0x6, .x = 5, .y = 5, .carry_in = false, .r0 = 0xFFFF_FFFF, .apsr = N },
    .{ .opcode = 0x6, .x = 5, .y = 5, .carry_in = true, .r0 = 0, .apsr = Z | C },
    .{ .opcode = 0x7, .x = 0x1, .y = 1, .r0 = 0x8000_0000, .apsr = N | C },
    .{ .opcode = 0x7, .x = 0x8000_0000, .y = 32, .r0 = 0x8000_0000, .apsr = N | C },
    .{ .opcode = 0x8, .x = 0xF0, .y = 0x0F, .r0 = 0xF0, .apsr = Z },
    .{ .opcode = 0x9, .x = 0x99, .y = 1, .r0 = 0xFFFF_FFFF, .apsr = N },
    .{ .opcode = 0x9, .x = 0x99, .y = 0, .r0 = 0, .apsr = Z | C },
    .{ .opcode = 0x9, .x = 0x99, .y = 0x8000_0000, .r0 = 0x8000_0000, .apsr = N | V },
    .{ .opcode = 0xA, .x = 3, .y = 3, .r0 = 3, .apsr = Z | C },
    .{ .opcode = 0xA, .x = 0x8000_0000, .y = 1, .r0 = 0x8000_0000, .apsr = C | V },
    .{ .opcode = 0xB, .x = 0xFFFF_FFFF, .y = 1, .r0 = 0xFFFF_FFFF, .apsr = Z | C },
    .{ .opcode = 0xC, .x = 0x0F, .y = 0xF0, .r0 = 0xFF, .apsr = 0 },
    .{ .opcode = 0xD, .x = 0x1_0000, .y = 0x1_0000, .carry_in = true, .r0 = 0, .apsr = Z | C },
    .{ .opcode = 0xE, .x = 0xFF, .y = 0x0F, .r0 = 0xF0, .apsr = 0 },
    .{ .opcode = 0xF, .x = 0x99, .y = 0, .r0 = 0xFFFF_FFFF, .apsr = N },
};

fn run(cpu: *Cpu, hw1: u16) !void {
    const instr: ra8.chip.core.cpu.instr.Instr = .{ .address = 0, .hw1 = hw1, .size = 2 };
    const exec = dp_reg.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "every opcode matches the pseudocode outside an IT block" {
    for (cases) |case| {
        var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = thumb | (if (case.carry_in) C else 0) } };
        cpu.regs.low[0] = case.x;
        cpu.regs.low[1] = case.y;
        try run(&cpu, 0x4000 | (@as(u16, case.opcode) << 6) | (1 << 3));
        try std.testing.expectEqual(case.r0, cpu.regs.low[0]);
        try std.testing.expectEqual(case.y, cpu.regs.low[1]);
        try std.testing.expectEqual(thumb | case.apsr, cpu.regs.xpsr);
    }
}

test "cmp r3, r1 (0x428b) compares the right registers" {
    var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = thumb } };
    cpu.regs.low[3] = 1;
    cpu.regs.low[1] = 2;
    try run(&cpu, 0x428B);
    try std.testing.expectEqual(thumb | N, cpu.regs.xpsr);
}

test "inside an IT block only TST, CMP and CMN set flags" {
    const it: u32 = 1 << 12;
    for (cases) |case| {
        var cpu: Cpu = .{ .bus = undefined, .regs = .{ .xpsr = thumb | it } };
        cpu.regs.low[0] = case.x;
        cpu.regs.low[1] = case.y;
        try run(&cpu, 0x4000 | (@as(u16, case.opcode) << 6) | (1 << 3));
        const always = case.opcode == 0x8 or case.opcode == 0xA or case.opcode == 0xB;
        if (!always) try std.testing.expectEqual(thumb | it, cpu.regs.xpsr);
    }
}

test "outside the block is not claimed" {
    for ([_]u16{ 0x3FFF, 0x4400, 0x4700, 0x4800 }) |hw1| {
        try std.testing.expect(dp_reg.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) == null);
    }
}
