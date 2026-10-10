const std = @import("std");
const ra8 = @import("ra8");

const output = ra8.chip.periph.acmphs.output;

test "a comparator that is not operating monitors nothing" {
    try std.testing.expect(!output.operating(0));
    try std.testing.expectEqual(@as(u8, 0), output.monitor(0));
}

test "HCMPON alone reports the reset verdict, plus below reference" {
    const ctl = output.mask.hcmpon;
    try std.testing.expect(output.operating(ctl));
    try std.testing.expectEqual(@as(u8, 0), output.monitor(ctl));
}

test "CINV inverts the verdict on the way to CMPMON" {
    const ctl = output.mask.hcmpon | output.mask.cinv;
    try std.testing.expect(output.inverted(ctl));
    try std.testing.expectEqual(output.cmpmon, output.monitor(ctl));
}

test "CINV without HCMPON still monitors nothing" {
    try std.testing.expectEqual(@as(u8, 0), output.monitor(output.mask.cinv));
}

test "COE says the result also reaches a pin" {
    try std.testing.expect(!output.driving(output.mask.hcmpon));
    try std.testing.expect(output.driving(output.mask.hcmpon | output.mask.coe));
}

test "CEG names the edge a channel asked to be told about" {
    try std.testing.expectEqual(output.Edge.none, output.Edge.of(0));
    try std.testing.expectEqual(output.Edge.rising, output.Edge.of(1 << 3));
    try std.testing.expectEqual(output.Edge.falling, output.Edge.of(2 << 3));
    try std.testing.expectEqual(output.Edge.both, output.Edge.of(output.mask.ceg));
}

test "the edge selector reads only bits 4 and 3" {
    try std.testing.expectEqual(output.Edge.rising, output.Edge.of(0xFF & ~output.mask.ceg | (1 << 3)));
}

test "the filter select does not disturb the monitor" {
    const ctl = output.mask.hcmpon | output.mask.cdfs;
    try std.testing.expectEqual(@as(u8, 0), output.monitor(ctl));
}
