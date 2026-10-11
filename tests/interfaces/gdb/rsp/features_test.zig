//! The target description and the windows qXfer reads it in.
const std = @import("std");
const ra8 = @import("ra8");
const features = ra8.gdb.rsp.features;

test "a window short of the end is marked m, and the rest reads after it" {
    var out: [0x1000]u8 = undefined;
    const first = try features.read("target.xml:0,10", &out);
    try std.testing.expectEqual(@as(u8, 'm'), first[0]);
    try std.testing.expectEqualStrings(features.target_xml[0..0x10], first[1..]);
    var rest: [0x1000]u8 = undefined;
    const last = try features.read("target.xml:10,fff", &rest);
    try std.testing.expectEqual(@as(u8, 'l'), last[0]);
    try std.testing.expectEqualStrings(features.target_xml[0x10..], last[1..]);
}

test "a window past the end is an empty last window" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("l", try features.read("target.xml:ffff,10", &out));
}

test "an annex that is not target.xml, or numbers that do not parse, is E00" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("E00", try features.read("arm-core.xml:0,10", &out));
    try std.testing.expectEqualStrings("E00", try features.read("target.xml:zz,10", &out));
    try std.testing.expectEqualStrings("E00", try features.read("target.xml", &out));
}

// gdb checks these names to accept the M-profile feature.
test "the description names the M-profile feature and its seventeen registers" {
    const xml = features.target_xml;
    try std.testing.expect(std.mem.indexOf(u8, xml, "org.gnu.gdb.arm.m-profile") != null);
    try std.testing.expectEqual(@as(usize, 17), std.mem.count(u8, xml, "<reg "));
    try std.testing.expect(std.mem.indexOf(u8, xml, "name=\"xpsr\"") != null);
}
