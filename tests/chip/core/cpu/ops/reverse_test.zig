//! Covers src/chip/core/cpu/ops/reverse.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const reverse = ra8.chip.core.cpu.ops.reverse;

fn at(hw1: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .size = 2 };
}

fn run(cpu: *Cpu, hw1: u16) !void {
    const exec = reverse.group.decode(at(hw1)) orelse return error.NotClaimed;
    try exec(cpu, at(hw1));
}

test "apply reverses bytes per kind" {
    const cases = [_]struct { kind: reverse.Kind, in: u32, out: u32 }{
        .{ .kind = .rev, .in = 0x1122_3344, .out = 0x4433_2211 },
        .{ .kind = .rev16, .in = 0x1122_3344, .out = 0x2211_4433 },
        .{ .kind = .revsh, .in = 0x1122_3380, .out = 0xFFFF_8033 },
        .{ .kind = .revsh, .in = 0xFFFF_007F, .out = 0x0000_7F00 },
    };
    for (cases) |c| try std.testing.expectEqual(c.out, reverse.apply(c.kind, c.in));
}

test "each encoding writes Rd from Rm and leaves the flags alone" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[1] = 0xAABB_CCDD;
    cpu.regs.xpsr = 0x2100_0000;
    try run(&cpu, 0xBA08); // rev r0, r1
    try std.testing.expectEqual(@as(u32, 0xDDCC_BBAA), cpu.regs.low[0]);
    try run(&cpu, 0xBA4A); // rev16 r2, r1
    try std.testing.expectEqual(@as(u32, 0xBBAA_DDCC), cpu.regs.low[2]);
    try run(&cpu, 0xBACB); // revsh r3, r1
    try std.testing.expectEqual(@as(u32, 0xFFFF_DDCC), cpu.regs.low[3]);
    try std.testing.expectEqual(@as(u32, 0x2100_0000), cpu.regs.xpsr);
}

test "leaves the unallocated op and its neighbours alone" {
    for ([_]u16{ 0xBA80, 0xBABF, 0xB200, 0xBB00, 0xBE00 }) |hw1| {
        try std.testing.expect(reverse.group.decode(at(hw1)) == null);
    }
}
