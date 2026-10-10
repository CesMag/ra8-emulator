const std = @import("std");
const profile = @import("ra8").session.functions.profile;

test "profile ranks functions by cycles and keeps instruction counts" {
    var table = profile.Table{ .image = .{ .bytes = &.{} } };
    table.add(0x1000, 3, 3);
    table.add(0x2000, 8, 8);
    table.add(0x1000, 2, 2);
    var into: [profile.limits.functions]profile.Site = undefined;
    const ranked = table.ranked(&into);
    try std.testing.expectEqual(@as(u32, 0x2000), ranked[0].address);
    try std.testing.expectEqual(@as(u64, 8), ranked[0].instructions);
    try std.testing.expectEqual(@as(u64, 5), ranked[1].cycles);
    try std.testing.expectEqual(@as(u64, 5), ranked[1].instructions);
}
