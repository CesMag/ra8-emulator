//! Covers src/chip/core/cpu/conformance/base/clrm_vectors.zig: each vector runs
//! through the `clrm` group over the exception tests' RAM with every
//! register filled.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const vectors = ra8.chip.core.cpu.conformance.base.clrm_vectors;
const cpu_ns = ra8.chip.core.cpu;
const Cpu = cpu_ns.cpu.Cpu;
const fixture = @import("../../exception/ram.zig");

fn initial(n: u4) u32 {
    return if (n == 14) vectors.lr_in else vectors.fill + n;
}

fn observe(cpu: *const Cpu) vectors.Out {
    var zeroed: u16 = 0;
    var kept = cpu.regs.sp() == vectors.sp_in;
    for ([_]u4{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14 }) |n| {
        const value = cpu.regs.get(n);
        if (value == 0) {
            zeroed |= @as(u16, 1) << n;
        } else if (value != initial(n)) {
            kept = false;
        }
    }
    return .{ .zeroed = zeroed, .kept = kept, .xpsr = cpu.regs.xpsr };
}

fn run(in: vectors.In) vectors.Out {
    var ram: fixture.Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view(), .regs = .{ .xpsr = in.xpsr } };
    for ([_]u4{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14 }) |n| cpu.regs.set(n, initial(n));
    cpu.regs.setSp(vectors.sp_in);
    const instr: cpu_ns.instr.Instr = .{ .address = 0x1000, .hw1 = in.hw1, .hw2 = in.hw2, .size = @intCast(in.size) };
    const none: vectors.Out = .{ .claimed = false, .kept = false, .xpsr = 0 };
    const exec = cpu_ns.ops.clrm.group.decode(instr) orelse return none;
    exec(&cpu, instr) catch return none;
    return observe(&cpu);
}

test "clrm matches the Arm ARM" {
    try vector.expectAll(vectors.In, vectors.Out, run, &vectors.all);
}

test "every vector is counted in covered and names the group" {
    try std.testing.expectEqual(vectors.all.len, vectors.covered.len);
    for (vectors.covered) |name| try std.testing.expectEqualStrings("clrm", name);
}
