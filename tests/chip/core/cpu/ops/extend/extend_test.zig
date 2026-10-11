//! Covers src/chip/core/cpu/ops/extend/extend.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const extend = ra8.chip.core.cpu.ops.extend;

fn run(cpu: *Cpu, hw1: u16) !void {
    const instr: Instr = .{ .address = 0, .hw1 = hw1, .size = 2 };
    const exec = extend.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

test "apply extends the low byte or halfword" {
    const cases = [_]struct { kind: extend.Kind, in: u32, out: u32 }{
        .{ .kind = .sxth, .in = 0x1234_8001, .out = 0xFFFF_8001 },
        .{ .kind = .sxth, .in = 0xFFFF_7FFF, .out = 0x0000_7FFF },
        .{ .kind = .sxtb, .in = 0x1234_5680, .out = 0xFFFF_FF80 },
        .{ .kind = .sxtb, .in = 0xFFFF_FF7F, .out = 0x0000_007F },
        .{ .kind = .uxth, .in = 0xFFFF_8001, .out = 0x0000_8001 },
        .{ .kind = .uxtb, .in = 0xFFFF_FF80, .out = 0x0000_0080 },
    };
    for (cases) |c| try std.testing.expectEqual(c.out, extend.apply(c.kind, c.in));
}

test "each encoding writes Rd from Rm and leaves the flags alone" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[3] = 0xABCD_EF81;
    cpu.regs.xpsr = 0x8100_0000;
    try run(&cpu, 0xB2DB); // uxtb r3, r3
    try std.testing.expectEqual(@as(u32, 0x81), cpu.regs.low[3]);
    cpu.regs.low[1] = 0x0000_80FF;
    try run(&cpu, 0xB208); // sxth r0, r1
    try std.testing.expectEqual(@as(u32, 0xFFFF_80FF), cpu.regs.low[0]);
    try run(&cpu, 0xB24A); // sxtb r2, r1
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.regs.low[2]);
    try run(&cpu, 0xB28C); // uxth r4, r1
    try std.testing.expectEqual(@as(u32, 0x80FF), cpu.regs.low[4]);
    try std.testing.expectEqual(@as(u32, 0x8100_0000), cpu.regs.xpsr);
}

test "leaves its neighbours alone" {
    for ([_]u16{ 0xB100, 0xB300, 0xB000, 0xBA00 }) |hw1| {
        const instr: Instr = .{ .address = 0, .hw1 = hw1, .size = 2 };
        try std.testing.expect(extend.group.decode(instr) == null);
    }
}
