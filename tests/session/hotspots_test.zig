const std = @import("std");
const hotspots = @import("ra8").session.hotspots;

test "a fresh table has nothing to say" {
    const table = hotspots.Table{};
    try std.testing.expect(table.quiet());
    try std.testing.expectEqual(@as(u64, 0), table.total);
}

test "the same address twice is one site with two samples" {
    var table = hotspots.Table{};
    table.sample(0x0200029E);
    table.sample(0x0200029E);
    try std.testing.expectEqual(@as(usize, 1), table.used);
    try std.testing.expectEqual(@as(u64, 2), table.sites[0].samples);
    try std.testing.expectEqual(@as(u64, 2), table.total);
}

test "a share is a share of the run, not of the table" {
    var table = hotspots.Table{};
    for (0..75) |_| table.sample(0x0200029E);
    for (0..25) |_| table.sample(0x02000A20);
    try std.testing.expectEqual(@as(u64, 75), table.shareOf(table.sites[0]));
    try std.testing.expectEqual(@as(u64, 25), table.shareOf(table.sites[1]));
}

test "ranked puts the most sampled site first and leaves the table alone" {
    var table = hotspots.Table{};
    table.sample(0x1000);
    for (0..9) |_| table.sample(0x2000);
    var into: [hotspots.limits.kept]hotspots.Site = undefined;
    const out = table.ranked(&into);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(u32, 0x2000), out[0].address);
    try std.testing.expectEqual(@as(u32, 0x1000), out[1].address);
    // The table itself still holds them in arrival order.
    try std.testing.expectEqual(@as(u32, 0x1000), table.sites[0].address);
}

test "a full table reuses its weakest slot and counts the displacement" {
    var table = hotspots.Table{};
    // Fill every slot, the first one heavily.
    for (0..50) |_| table.sample(0x0200029E);
    for (1..hotspots.limits.kept) |index| table.sample(@intCast(0x1000 + index));
    try std.testing.expectEqual(@as(usize, hotspots.limits.kept), table.used);
    try std.testing.expectEqual(@as(u64, 0), table.displaced);

    table.sample(0xDEAD0000);
    try std.testing.expectEqual(@as(usize, hotspots.limits.kept), table.used);
    try std.testing.expectEqual(@as(u64, 1), table.displaced);
    // The heavy site cannot be evicted by a newcomer.
    try std.testing.expectEqual(@as(u32, 0x0200029E), table.sites[0].address);
    try std.testing.expectEqual(@as(u64, 50), table.sites[0].samples);
}

test "a run spread evenly over many addresses reports nothing" {
    var table = hotspots.Table{};
    for (0..1000) |index| table.sample(@intCast(0x2000 + index));
    try std.testing.expect(table.quiet());
}

test "a run that fell into one spin is not quiet" {
    var table = hotspots.Table{};
    for (0..1000) |index| table.sample(@intCast(0x2000 + index));
    for (0..1000) |_| table.sample(0x0200029E);
    try std.testing.expect(!table.quiet());
    var into: [hotspots.limits.kept]hotspots.Site = undefined;
    const out = table.ranked(&into);
    try std.testing.expectEqual(@as(u32, 0x0200029E), out[0].address);
    try std.testing.expectEqual(@as(u64, 50), table.shareOf(out[0]));
}

test "ranked on an empty or one-site table returns it as it is" {
    var into: [hotspots.limits.kept]hotspots.Site = undefined;
    var table = hotspots.Table{};
    try std.testing.expectEqual(@as(usize, 0), table.ranked(&into).len);
    table.sample(0x3000);
    const out = table.ranked(&into);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 0x3000), out[0].address);
}
