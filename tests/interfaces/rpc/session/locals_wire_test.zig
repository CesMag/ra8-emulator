//! Tests for src/interfaces/rpc/session/locals_wire.zig.
const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const locals_wire = ra8.rpc.session.locals_wire;

test "locals_wire constants and codec round-trip" {
    try std.testing.expectEqual(@as(usize, 32), locals_wire.locals_rows);
    const row: proto.LocalRow = .{
        .name = "counter",
        .type_name = "uint32_t",
        .size = 4,
        .where_kind = locals_wire.where_kinds.frame,
        .where_a = 8,
        .where_b = 0,
    };
    var buf: [256]u8 = undefined;
    const encoded = try proto.encode(proto.LocalRow, row, &buf);
    const decoded = try proto.decode(proto.LocalRow, encoded);
    try std.testing.expectEqualDeep(row, decoded);
}
