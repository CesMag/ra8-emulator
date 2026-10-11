//! Covers src/chip/core/cpu/text/table.zig.
const std = @import("std");
const ra8 = @import("ra8");
const table = ra8.chip.core.cpu.decode.text.table;
const groups = ra8.chip.core.cpu.ops.table.groups;

test "every printer names a group the decode table has" {
    for (table.entries) |entry| {
        var found = false;
        for (groups) |group| found = found or std.mem.eql(u8, group.name, entry.group);
        try std.testing.expect(found);
    }
}

test "find returns null for a group with no printer yet" {
    try std.testing.expect(table.find("no_such_group") == null);
    try std.testing.expect(table.find("dp_reg") != null);
}
