//! Covers src/chip/core/cpu/ops/barrier.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const barrier = ra8.chip.core.cpu.ops.barrier;

fn none(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
    _ = ctx;
    _ = address;
    _ = into;
    return bus.Error.Unmapped;
}

fn noneWrite(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
    _ = ctx;
    _ = address;
    _ = from;
    return bus.Error.Unmapped;
}

fn wide(hw2: u16) Instr {
    return .{ .address = 0, .hw1 = 0xF3BF, .hw2 = hw2, .size = 4 };
}

test "dsb, dmb and isb with every option run and change nothing" {
    var dummy: u8 = 0;
    var cpu: Cpu = .{ .bus = .{ .ctx = &dummy, .vtable = &.{ .read = none, .write = noneWrite } } };
    cpu.regs.low[0] = 7;
    cpu.regs.xpsr = 0x2100_0000;
    const before = cpu.regs;
    for ([_]u16{ 0x8F40, 0x8F50, 0x8F60 }) |kind| {
        for (0..16) |option| {
            const instr = wide(kind | @as(u16, @intCast(option)));
            const exec = barrier.group.decode(instr) orelse return error.NotClaimed;
            try exec(&cpu, instr);
        }
    }
    try std.testing.expectEqual(before, cpu.regs);
}

test "leaves the hint space, CLREX and other wide encodings alone" {
    const unclaimed = [_]Instr{
        .{ .address = 0, .hw1 = 0xF3AF, .hw2 = 0x8000, .size = 4 }, // nop.w
        wide(0x8F2F), // clrex
        wide(0x8F70),
        wide(0x8E4F),
        .{ .address = 0, .hw1 = 0xF3BF, .size = 2 },
    };
    for (unclaimed) |instr| try std.testing.expect(barrier.group.decode(instr) == null);
}
