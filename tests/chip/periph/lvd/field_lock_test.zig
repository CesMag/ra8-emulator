//! Covers src/chip/periph/lvd/field_lock.zig.
const std = @import("std");
const ra8 = @import("ra8");

const field_lock = ra8.chip.periph.lvd.field_lock;
const regs = ra8.chip.periph.lvd.regs;

const div_one: u8 = 0x10;
const div_two: u8 = 0x20;

test "a fresh gate is quiet" {
    const gate = field_lock.Locked{};
    try std.testing.expect(gate.quiet());
    try std.testing.expectEqual(@as(u32, 0), gate.filters);
}

test "FSAMP lands while DFDIS is set" {
    var gate = field_lock.Locked{};
    const landed = gate.filter(regs.control.dfdis, regs.control.dfdis | div_two);
    try std.testing.expectEqual(regs.control.dfdis | div_two, landed);
    try std.testing.expectEqual(@as(u32, 0), gate.filters);
}

test "FSAMP is held while the filter runs, and the other bits still land" {
    var gate = field_lock.Locked{};
    const landed = gate.filter(div_one, div_two | regs.control.rie);
    try std.testing.expectEqual(div_one | regs.control.rie, landed);
    try std.testing.expectEqual(@as(u32, 1), gate.filters);
    try std.testing.expect(!gate.quiet());
}

test "a read-modify-write that carries FSAMP along is not a violation" {
    var gate = field_lock.Locked{};
    const landed = gate.filter(div_one, div_one | regs.control.dfdis);
    try std.testing.expectEqual(div_one | regs.control.dfdis, landed);
    try std.testing.expectEqual(@as(u32, 0), gate.filters);
}

test "the gate reads the DFDIS standing before the store, not the one it carries" {
    var gate = field_lock.Locked{};
    const landed = gate.filter(div_one, div_two | regs.control.dfdis);
    try std.testing.expectEqual(div_one | regs.control.dfdis, landed);
    try std.testing.expectEqual(@as(u32, 1), gate.filters);
}
