const std = @import("std");
const ra8 = @import("ra8");
const sau = ra8.chip.periph.sau;

test "TYPE reports the region count this core implements" {
    try std.testing.expectEqual(@as(u32, 8), sau.geometry.type_value);
    try std.testing.expectEqual(
        @as(u32, 8),
        sau.geometry.type_value & sau.field.sregion,
    );
}

test "a select value wraps into the implemented set" {
    try std.testing.expectEqual(@as(u8, 0), sau.geometry.selects(0));
    try std.testing.expectEqual(@as(u8, 4), sau.geometry.selects(4));
    try std.testing.expectEqual(@as(u8, 0), sau.geometry.selects(8));
    try std.testing.expectEqual(@as(u8, 1), sau.geometry.selects(9));
}

test "a region reads its span out of the RBAR/RLAR pair" {
    const region = sau.Region.fromPair(0x0208_0000, 0x020F_FFE0 | sau.field.rlar_enable);
    try std.testing.expectEqual(@as(u32, 0x0208_0000), region.base);
    try std.testing.expectEqual(@as(u32, 0x020F_FFFF), region.limit);
    try std.testing.expect(region.enabled);
    try std.testing.expect(!region.callable);
    try std.testing.expectEqual(@as(u32, 0x0008_0000), region.bytes());
}

test "a limit is inclusive, so the bits the field cannot hold read as ones" {
    const region = sau.Region.fromPair(0, 0x2000_0000 | sau.field.rlar_enable);
    try std.testing.expectEqual(@as(u32, 0x2000_001F), region.limit);
}

test "a region that is not enabled covers nothing" {
    const region = sau.Region.fromPair(0x2200_0000, 0x221F_FFE0);
    try std.testing.expect(!region.enabled);
    try std.testing.expect(!region.covers(0x2200_0004));
    try std.testing.expectEqual(@as(u32, 0), region.bytes());
}

test "RLAR.NSC marks a region Non-Secure Callable" {
    const region = sau.Region.fromPair(
        0x0208_0000,
        0x0208_01E0 | sau.field.rlar_enable | sau.field.rlar_nsc,
    );
    try std.testing.expect(region.enabled);
    try std.testing.expect(region.callable);
}

test "a fresh window is quiet and holds no regions" {
    var unit = sau.Sau.init();
    try std.testing.expect(unit.quiet());
    try std.testing.expect(!unit.on());
    try std.testing.expectEqual(@as(u8, 0), unit.programmed());
}

test "RBAR and RLAR are filed under the region RNR names" {
    var unit = sau.Sau.init();
    try std.testing.expectEqual(sau.Sau.Cue.rebank, unit.observe(0xE000_EDD8, 2));
    _ = unit.observe(0xE000_EDDC, 0x1200_0000);
    _ = unit.observe(0xE000_EDE0, 0x1200_FFE0 | sau.field.rlar_enable);
    try std.testing.expectEqual(@as(u8, 2), unit.selected);
    try std.testing.expectEqual(@as(u32, 0x1200_0000), unit.table[2].base);
    try std.testing.expect(unit.table[2].enabled);
    // The regions either side of it are untouched, which is the whole point
    // of banking: five triples in a row must not collapse onto one entry.
    try std.testing.expect(!unit.table[1].enabled);
    try std.testing.expect(!unit.table[3].enabled);
    try std.testing.expectEqual(@as(u32, 2), unit.banked);
}

test "five regions programmed in a row each keep their own entry" {
    var unit = sau.Sau.init();
    const bases = [_]u32{ 0x1000_0000, 0x0208_0000, 0x1200_0000, 0x2210_0000, 0x5000_0000 };
    for (bases, 0..) |base, index| {
        _ = unit.observe(0xE000_EDD8, @intCast(index));
        _ = unit.observe(0xE000_EDDC, base);
        _ = unit.observe(0xE000_EDE0, (base + 0x000F_FFE0) | sau.field.rlar_enable);
    }
    try std.testing.expectEqual(@as(u8, 5), unit.programmed());
    for (bases, 0..) |base, index| {
        try std.testing.expectEqual(base, unit.table[index].base);
        try std.testing.expect(unit.table[index].enabled);
    }
}

test "the banked pair is the region RNR selects" {
    var unit = sau.Sau.init();
    _ = unit.observe(0xE000_EDD8, 1);
    _ = unit.observe(0xE000_EDDC, 0x0208_0000);
    _ = unit.observe(0xE000_EDE0, 0x020F_FFE0 | sau.field.rlar_enable);
    _ = unit.observe(0xE000_EDD8, 3);
    try std.testing.expectEqual(@as(u32, 0), unit.bankedPair().rbar);
    _ = unit.observe(0xE000_EDD8, 1);
    try std.testing.expectEqual(@as(u32, 0x0208_0000), unit.bankedPair().rbar);
}

test "CTRL is taken at the store, not left for the next poll" {
    var unit = sau.Sau.init();
    try std.testing.expectEqual(sau.Sau.Cue.none, unit.observe(0xE000_EDD0, sau.field.ctrl_enable));
    try std.testing.expect(unit.on());
    try std.testing.expect(!unit.outsideIsNonSecure());
    try std.testing.expect(!unit.quiet());
    _ = unit.observe(0xE000_EDD0, sau.field.ctrl_enable | sau.field.ctrl_allns);
    try std.testing.expect(unit.outsideIsNonSecure());
}

test "the Non-Secure Callable regions are counted apart from the rest" {
    var unit = sau.Sau.init();
    _ = unit.observe(0xE000_EDD8, 0);
    _ = unit.observe(0xE000_EDDC, 0x1000_0000);
    _ = unit.observe(0xE000_EDE0, 0x100F_FFE0 | sau.field.rlar_enable);
    _ = unit.observe(0xE000_EDD8, 1);
    _ = unit.observe(0xE000_EDDC, 0x0208_0000);
    _ = unit.observe(0xE000_EDE0, 0x0208_01E0 | sau.field.rlar_enable | sau.field.rlar_nsc);
    try std.testing.expectEqual(@as(u8, 2), unit.programmed());
    try std.testing.expectEqual(@as(u8, 1), unit.callable());
}

test "a store anywhere else in the window changes nothing" {
    var unit = sau.Sau.init();
    try std.testing.expectEqual(sau.Sau.Cue.none, unit.observe(0xE000_EDD4, 0x40));
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.banked);
}
