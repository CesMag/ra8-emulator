//! Covers src/chip/core/cpu/op.zig.
const std = @import("std");
const ra8 = @import("ra8");
const op = ra8.chip.core.cpu.op;
const Instr = ra8.chip.core.cpu.instr.Instr;

fn none(instr: Instr) ?op.Exec {
    _ = instr;
    return null;
}

test "a group is a class name and a decode function" {
    const group: op.Group = .{ .name = "empty", .decode = none };
    try std.testing.expectEqualStrings("empty", group.name);
    try std.testing.expect(group.decode(.{ .address = 0, .hw1 = 0xBF00, .size = 2 }) == null);
}
