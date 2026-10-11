//! The remote protocol's Z and z requests against a stop machine: breaks
//! in the break table, watches in the watch table.
const std = @import("std");
const ra8 = @import("ra8");
const points = ra8.gdb.rsp.dispatch.points;
const Machine = ra8.session.stop_machine.Machine;

// Z0 and Z1 both set a break, a second set is already true, and z0 clears it.
test "Z0 and Z1 set breaks and z0 clears them" {
    var machine = Machine{};
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "Z0,22000008,2", &out));
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "Z0,22000008,2", &out));
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "Z1,22000010,2", &out));
    try std.testing.expectEqual(@as(usize, 2), machine.breaks.entries().len);
    try std.testing.expect(machine.breaks.find(0x2200_0008) != null);
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "z0,22000008,2", &out));
    try std.testing.expect(machine.breaks.find(0x2200_0008) == null);
    try std.testing.expectEqualStrings("E00", try points.answer(&machine, "z0,22000008,2", &out));
}

// Z2, Z3 and Z4 are write, read and access watches over the length given.
test "Z2, Z3 and Z4 set watches of the right kind and span" {
    var machine = Machine{};
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "Z2,22000054,4", &out));
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "Z3,22000060,1", &out));
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "Z4,22000070,2", &out));
    const set = machine.watches.entries();
    try std.testing.expectEqual(@as(usize, 3), set.len);
    try std.testing.expectEqual(ra8.session.watch.table.Kind.write, set[0].watch.kind);
    try std.testing.expectEqual(@as(u32, 0x2200_0057), set[0].watch.last);
    try std.testing.expectEqual(ra8.session.watch.table.Kind.read, set[1].watch.kind);
    try std.testing.expectEqual(ra8.session.watch.table.Kind.access, set[2].watch.kind);
}

// z2 only clears the watch with the same address, length and kind.
test "z2 clears the matching watch and nothing else" {
    var machine = Machine{};
    var out: [8]u8 = undefined;
    _ = try points.answer(&machine, "Z2,22000054,4", &out);
    _ = try points.answer(&machine, "Z3,22000054,4", &out);
    try std.testing.expectEqualStrings("E00", try points.answer(&machine, "z2,22000054,2", &out));
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "z2,22000054,4", &out));
    const left = machine.watches.entries();
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqual(ra8.session.watch.table.Kind.read, left[0].watch.kind);
}

// An unknown type is unsupported; a malformed request or empty span is an error.
test "unknown types, bad requests and empty watches" {
    var machine = Machine{};
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try points.answer(&machine, "Z9,22000000,2", &out));
    try std.testing.expectEqualStrings("E00", try points.answer(&machine, "Z0,2200zz00,2", &out));
    try std.testing.expectEqualStrings("E00", try points.answer(&machine, "Z0,22000000", &out));
    try std.testing.expectEqualStrings("E00", try points.answer(&machine, "Z2,22000000,0", &out));
    try std.testing.expectEqualStrings("OK", try points.answer(&machine, "Z0,22000000,2;X1,0", &out));
}
