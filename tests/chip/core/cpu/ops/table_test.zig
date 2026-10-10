//! Covers src/chip/core/cpu/ops/table.zig.
const std = @import("std");
const ra8 = @import("ra8");
const table = ra8.chip.core.cpu.ops.table;

test "every group has a distinct class name" {
    for (table.groups, 0..) |a, i| {
        try std.testing.expect(a.name.len > 0);
        for (table.groups[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}
