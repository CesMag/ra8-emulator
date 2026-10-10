const std = @import("std");
const pc_hits = @import("ra8").session.pc_hits;

test "a run that asked for nothing stays quiet" {
    const hits = pc_hits.Hits{};
    try std.testing.expect(hits.quiet());
    try std.testing.expectEqual(@as(usize, 0), hits.asked().len);
}

test "an asked address starts at zero and counts every execution" {
    var hits = pc_hits.Hits{};
    hits.want(0x02002458);
    try std.testing.expect(!hits.quiet());
    try std.testing.expectEqual(@as(u64, 0), hits.asked()[0].hits);
    hits.hit(0x02002458);
    hits.hit(0x02002458);
    try std.testing.expectEqual(@as(u64, 2), hits.asked()[0].hits);
}

test "asking twice for one address keeps one slot and one count" {
    var hits = pc_hits.Hits{};
    hits.want(0x020023DC);
    hits.want(0x020023DC);
    hits.hit(0x020023DC);
    try std.testing.expectEqual(@as(usize, 1), hits.asked().len);
    try std.testing.expectEqual(@as(u64, 1), hits.asked()[0].hits);
    try std.testing.expectEqual(@as(usize, 0), hits.refused);
}

test "addresses are reported in the order they were asked for" {
    var hits = pc_hits.Hits{};
    hits.want(0x020023DC);
    hits.want(0x02002458);
    hits.hit(0x02002458);
    hits.hit(0x02002458);
    hits.hit(0x020023DC);
    const asked = hits.asked();
    try std.testing.expectEqual(@as(usize, 2), asked.len);
    try std.testing.expectEqual(@as(u32, 0x020023DC), asked[0].at);
    try std.testing.expectEqual(@as(u64, 1), asked[0].hits);
    try std.testing.expectEqual(@as(u32, 0x02002458), asked[1].at);
    try std.testing.expectEqual(@as(u64, 2), asked[1].hits);
}

test "a hit on an address nobody asked for takes no slot" {
    var hits = pc_hits.Hits{};
    hits.want(0x02002458);
    hits.hit(0x0200CAFE);
    try std.testing.expectEqual(@as(usize, 1), hits.asked().len);
    try std.testing.expectEqual(@as(u64, 0), hits.asked()[0].hits);
}

test "an address past the table is refused rather than displacing one" {
    var hits = pc_hits.Hits{};
    var at: u32 = 0x02000000;
    var index: usize = 0;
    while (index < pc_hits.limits.places) : (index += 1) {
        hits.want(at);
        at += 4;
    }
    try std.testing.expectEqual(@as(usize, pc_hits.limits.places), hits.asked().len);
    hits.want(0x02009999);
    try std.testing.expectEqual(@as(usize, pc_hits.limits.places), hits.asked().len);
    try std.testing.expectEqual(@as(usize, 1), hits.refused);
    try std.testing.expect(!hits.quiet());
}
