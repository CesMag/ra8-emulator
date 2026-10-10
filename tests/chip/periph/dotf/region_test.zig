const std = @import("std");
const ra8 = @import("ra8");

const region = ra8.chip.periph.dotf_region;

test "the address registers are 4 KB granular" {
    try std.testing.expectEqual(@as(u32, 0x9000_0000), region.address(0x9000_0FFF));
    try std.testing.expectEqual(@as(u32, 0x9000_1000), region.address(0x9000_1ABC));
}

test "the start register reads its reserved field back as zero" {
    try std.testing.expectEqual(@as(u32, 0x9000_0000), region.startReadback(0x9000_0FFF));
}

test "the end register reads its reserved field back as one" {
    try std.testing.expectEqual(@as(u32, 0x9000_0FFF), region.endReadback(0x9000_0000));
}

test "a readback is not what was written, which is the point" {
    const written: u32 = 0x8010_0000;
    try std.testing.expect(region.endReadback(written) != written);
}

test "each channel is bound to its own XSPI window" {
    try std.testing.expect(region.window(0).holds(0x8000_0000));
    try std.testing.expect(region.window(0).holds(0x9FFF_FFFF));
    try std.testing.expect(!region.window(0).holds(0x7000_0000));
    try std.testing.expect(region.window(1).holds(0x7000_0000));
    try std.testing.expect(!region.window(1).holds(0x8000_0000));
}

test "a channel this part does not have covers nothing" {
    try std.testing.expect(!region.window(2).holds(0x8000_0000));
}

test "an unprogrammed pair names no region" {
    try std.testing.expect(!region.programmed(0, 0));
    try std.testing.expectEqual(@as(u32, 0), region.pages(0, 0));
}

test "an end below its start names no region" {
    try std.testing.expect(!region.programmed(0x9000_0000, 0x8000_0000));
}

test "a region runs to the top of the page its end names" {
    const start: u32 = 0x9000_0000;
    const end: u32 = 0x9000_1000;
    try std.testing.expect(region.covers(start, end, 0x9000_0000));
    try std.testing.expect(region.covers(start, end, 0x9000_1FFF));
    try std.testing.expect(!region.covers(start, end, 0x9000_2000));
    try std.testing.expect(!region.covers(start, end, 0x8FFF_FFFF));
}

test "the page count is inclusive of both ends" {
    try std.testing.expectEqual(@as(u32, 1), region.pages(0x9000_0000, 0x9000_0000));
    try std.testing.expectEqual(@as(u32, 2), region.pages(0x9000_0000, 0x9000_1000));
}

test "outsideWindow answers on the pair, not on one register" {
    const bound = region.window(0);
    try std.testing.expect(!region.outsideWindow(bound, 0x0000_1000, 0x0000_0000));
    try std.testing.expect(region.outsideWindow(bound, 0x0000_1000, 0x0000_2000));
    try std.testing.expect(!region.outsideWindow(bound, 0x9000_1000, 0x9000_2000));
}

test "outsideWindow runs the region to the top of its last page" {
    const bound = region.window(1);
    try std.testing.expect(!region.outsideWindow(bound, 0x7000_0000, 0x7FFF_F000));
    try std.testing.expect(region.outsideWindow(bound, 0x7000_0000, 0x8000_0000));
}

test "a pair with a register still at reset names no region to refuse" {
    const bound = region.window(0);
    try std.testing.expect(!region.outsideWindow(bound, 0x0000_0000, 0x9000_1000));
    try std.testing.expect(!region.outsideWindow(bound, 0x9000_0000, 0x0000_0000));
}

test "a reversed pair is the prohibited one" {
    try std.testing.expect(region.reversed(0x9000_2000, 0x9000_1000));
    try std.testing.expect(!region.reversed(0x9000_1000, 0x9000_2000));
    try std.testing.expect(!region.reversed(0x9000_1000, 0x9000_1000));
}

test "a pair whose end is still at reset is not reversed" {
    try std.testing.expect(!region.reversed(0x9000_1000, 0x0000_0000));
    try std.testing.expect(!region.reversed(0x0000_0000, 0x0000_0000));
}

test "reversed judges the address field, not the reserved bits" {
    try std.testing.expect(!region.reversed(0x9000_1FFF, 0x9000_1000));
    try std.testing.expect(region.reversed(0x9000_2000, 0x9000_1FFF));
}
