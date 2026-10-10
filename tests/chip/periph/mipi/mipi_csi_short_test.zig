//! Tests for the MIPI CSI-2 generic short-packet rule.
const std = @import("std");
const ra8 = @import("ra8");

const short = ra8.chip.periph.mipi_csi_short;

test "storing follows GSCT.GFIF" {
    try std.testing.expect(!short.storing(0));
    try std.testing.expect(short.storing(short.control.store));
    try std.testing.expect(short.storing(short.control.store | 0x7F));
}

test "threshold is the low seven bits" {
    try std.testing.expectEqual(@as(u32, 0), short.thresholdOf(short.control.store));
    try std.testing.expectEqual(@as(u32, 4), short.thresholdOf(0x0001_0004));
    try std.testing.expectEqual(@as(u32, 0x7F), short.thresholdOf(0xFFFF_FFFF));
}

test "the three GSIU request lines are separate" {
    try std.testing.expect(short.advanceRequested(short.update.advance));
    try std.testing.expect(!short.clearRequested(short.update.advance));
    try std.testing.expect(short.clearRequested(short.update.clear));
    try std.testing.expect(!short.advanceRequested(short.update.clear));
    try std.testing.expect(short.reenableRequested(short.update.reenable));
    try std.testing.expect(!short.reenableRequested(0));
}

test "an empty FIFO with storing on reads as plain zero" {
    try std.testing.expectEqual(@as(u32, 0), short.value(0, 0, false, true));
}

test "storing off raises STRDS even when empty" {
    const word = short.value(0, 0, false, false);
    try std.testing.expect(word & short.status.store_disabled != 0);
    try std.testing.expect(word & short.status.not_empty == 0);
}

test "a queued packet raises GNE and lands in PNUM" {
    const word = short.value(3, 0, false, true);
    try std.testing.expect(word & short.status.not_empty != 0);
    try std.testing.expectEqual(@as(u32, 3), short.queuedIn(word));
}

test "GTH is the threshold, and a zero threshold never meets it" {
    try std.testing.expect(short.value(4, 4, false, true) & short.status.threshold_met != 0);
    try std.testing.expect(short.value(3, 4, false, true) & short.status.threshold_met == 0);
    try std.testing.expect(short.value(9, 0, false, true) & short.status.threshold_met == 0);
}

test "GCD is the clear handshake and nothing else" {
    try std.testing.expect(short.value(0, 0, true, true) & short.status.cleared != 0);
    try std.testing.expect(short.value(0, 0, false, true) & short.status.cleared == 0);
}

test "PNUM survives the full FIFO depth" {
    const word = short.value(short.depth, 0, false, true);
    try std.testing.expectEqual(short.depth, short.queuedIn(word));
}

test "a header word packs data type, channel and payload" {
    const word = short.headerWord(0x21, 2, 0xBEEF);
    try std.testing.expectEqual(@as(u32, 0xBEEF), word & short.header.payload);
    try std.testing.expectEqual(@as(u32, 0x21), (word & short.header.data_type) >> short.header.data_type_shift);
    try std.testing.expectEqual(@as(u32, 2), (word & short.header.channel) >> short.header.channel_shift);
}

test "a header field wider than its slot is masked, not smeared" {
    const word = short.headerWord(0xFF, 0xFF, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0x3F), (word & short.header.data_type) >> short.header.data_type_shift);
    try std.testing.expectEqual(@as(u32, 0x0F), (word & short.header.channel) >> short.header.channel_shift);
}
