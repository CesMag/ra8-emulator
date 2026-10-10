//! Covers src/chip/periph/rtc/frequency.zig.
const std = @import("std");
const freq = @import("ra8").chip.periph.rtc.frequency;

test "the pair is named from RFRH through the top of RFRL" {
    try std.testing.expect(!freq.names(0x29));
    try std.testing.expect(freq.names(freq.off.rfrh));
    try std.testing.expect(freq.names(freq.off.rfrh + 1));
    try std.testing.expect(freq.names(freq.off.rfrl));
    try std.testing.expect(freq.names(freq.off.rfrl + 1));
    try std.testing.expect(!freq.names(0x2E));
}

test "only RFRH is the high half" {
    try std.testing.expect(freq.namesHigh(freq.off.rfrh));
    try std.testing.expect(freq.namesHigh(freq.off.rfrh + 1));
    try std.testing.expect(!freq.namesHigh(freq.off.rfrl));
}

test "a fresh pair has nothing to report" {
    const unit = freq.Frequency{};
    try std.testing.expect(unit.quiet());
}

test "a store with the prescaler stopped is not counted hot" {
    var unit = freq.Frequency{};
    unit.note(freq.off.rfrh, false);
    unit.note(freq.off.rfrl, false);
    try std.testing.expectEqual(@as(u32, 0), unit.hot_stores);
}

test "a store with the prescaler running is counted" {
    var unit = freq.Frequency{};
    unit.note(freq.off.rfrh, true);
    unit.note(freq.off.rfrl, true);
    try std.testing.expectEqual(@as(u32, 2), unit.hot_stores);
    try std.testing.expect(!unit.quiet());
}

test "RFRH before RFRL is the order the driver follows" {
    var unit = freq.Frequency{};
    unit.note(freq.off.rfrh, false);
    unit.note(freq.off.rfrl, false);
    try std.testing.expectEqual(@as(u32, 0), unit.out_of_order);
    try std.testing.expect(unit.quiet());
}

test "RFRL with RFRH untouched is counted out of order" {
    var unit = freq.Frequency{};
    unit.note(freq.off.rfrl, false);
    try std.testing.expectEqual(@as(u32, 1), unit.out_of_order);
    try std.testing.expect(!unit.quiet());
}

test "every byte of an out-of-order RFRL store is counted" {
    var unit = freq.Frequency{};
    unit.note(freq.off.rfrl, false);
    unit.note(freq.off.rfrl + 1, false);
    try std.testing.expectEqual(@as(u32, 2), unit.out_of_order);
}

test "a reset puts the order rule back on its cold-start footing" {
    var unit = freq.Frequency{};
    unit.note(freq.off.rfrh, false);
    unit.clear();
    unit.note(freq.off.rfrl, false);
    try std.testing.expectEqual(@as(u32, 1), unit.out_of_order);
}

test "the two rules count independently" {
    var unit = freq.Frequency{};
    unit.note(freq.off.rfrl, true);
    try std.testing.expectEqual(@as(u32, 1), unit.hot_stores);
    try std.testing.expectEqual(@as(u32, 1), unit.out_of_order);
}
