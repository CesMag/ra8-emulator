//! Covers src/chip/core/cpu/ops/svc.zig.
const std = @import("std");
const ra8 = @import("ra8");
const svc = ra8.chip.core.cpu.ops.svc;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const fixture = @import("../exception/ram.zig");

fn claims(hw1: u16) bool {
    return svc.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) != null;
}

test "SVC claims every immediate and nothing beside it" {
    try std.testing.expect(claims(0xDF00));
    try std.testing.expect(claims(0xDFAB));
    try std.testing.expect(claims(0xDFFF));
    try std.testing.expect(!claims(0xDE00)); // UDF
    try std.testing.expect(!claims(0xDD00)); // BLE
    try std.testing.expect(svc.group.decode(.{ .address = 0, .hw1 = 0xDF00, .hw2 = 0, .size = 4 }) == null);
}

test "SVC raises exception 11 for the core to take once it retires" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const exec = svc.group.decode(.{ .address = 0, .hw1 = 0xDF05, .size = 2 }).?;
    try exec(&cpu, .{ .address = 0, .hw1 = 0xDF05, .size = 2 });
    try std.testing.expectEqual(@as(?ra8.chip.core.cpu.exception.entry.Number, 11), cpu.raised);
    try std.testing.expectEqual(fixture.code, cpu.regs.pc);
}

test "SVC has no lockstep oracle" {
    try std.testing.expect(!svc.group.oracle);
}
