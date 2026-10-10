//! Tests for the GLCDC gamma correction blocks.
const std = @import("std");
const ra8 = @import("ra8");
const gam = ra8.chip.periph.glcdc.gamma;

fn packGains(high: u32, low: u32) u32 {
    return high << gam.field.gain_shift | low;
}

fn packThresholds(high: u32, low: u32) u32 {
    return high << gam.field.threshold_shift | low;
}

/// Fill a channel with a single slope across the whole range.
fn flat(channel: *gam.Channel, gain: u32) void {
    var index: u8 = 0;
    while (index < gam.geometry.registers) : (index += 1) {
        channel.latch(.{ .channel = 0, .table = .lut, .index = index }, packGains(gain, gain));
    }
}

test "a gamma block is found by its offset" {
    const slot = gam.slotOf(0x1300).?;
    try std.testing.expectEqual(@as(u8, 0), slot.channel);
    try std.testing.expectEqual(gam.Table.lut, slot.table);
    try std.testing.expectEqual(@as(u8, 0), slot.index);
}

test "the area table starts halfway through a block" {
    const slot = gam.slotOf(0x1340 + gam.geometry.area_base + 4).?;
    try std.testing.expectEqual(@as(u8, 1), slot.channel);
    try std.testing.expectEqual(gam.Table.area, slot.table);
    try std.testing.expectEqual(@as(u8, 1), slot.index);
}

test "the blue block is the third one" {
    const slot = gam.slotOf(0x1380 + 12).?;
    try std.testing.expectEqual(@as(u8, 2), slot.channel);
    try std.testing.expectEqual(@as(u8, 3), slot.index);
}

test "an offset outside the three blocks names no slot" {
    try std.testing.expect(gam.slotOf(0x12FC) == null);
    try std.testing.expect(gam.slotOf(0x13C4) == null);
}

test "an unprogrammed channel passes its sample through" {
    const channel = gam.Channel{};
    try std.testing.expectEqual(@as(u32, 512), channel.apply(512));
    try std.testing.expect(channel.identity());
}

test "a unity ramp leaves the sample where it was" {
    var channel = gam.Channel{};
    flat(&channel, gam.field.unity);
    try std.testing.expect(channel.identity());
    try std.testing.expectEqual(@as(u32, 300), channel.apply(300));
    try std.testing.expectEqual(@as(u32, 0), channel.apply(0));
}

test "half gain darkens by half" {
    var channel = gam.Channel{};
    flat(&channel, gam.field.unity / 2);
    try std.testing.expect(!channel.identity());
    try std.testing.expectEqual(@as(u32, 256), channel.apply(512));
}

test "a gain above unity saturates at the top of the pipeline" {
    var channel = gam.Channel{};
    flat(&channel, gam.field.gain_mask);
    try std.testing.expectEqual(gam.field.full, channel.apply(900));
}

test "both halves of a lut register land" {
    var channel = gam.Channel{};
    channel.latch(.{ .channel = 0, .table = .lut, .index = 0 }, packGains(2047, 512));
    try std.testing.expectEqual(@as(u16, 2047), channel.gain[0]);
    try std.testing.expectEqual(@as(u16, 512), channel.gain[1]);
}

test "both halves of an area register land" {
    var channel = gam.Channel{};
    channel.latch(.{ .channel = 0, .table = .area, .index = 3 }, packThresholds(400, 500));
    try std.testing.expectEqual(@as(u16, 400), channel.threshold[6]);
    try std.testing.expectEqual(@as(u16, 500), channel.threshold[7]);
}

test "a gain field wider than eleven bits is masked" {
    var channel = gam.Channel{};
    channel.latch(.{ .channel = 0, .table = .lut, .index = 0 }, packGains(0xFFFF, 0xFFFF));
    try std.testing.expectEqual(@as(u16, gam.field.gain_mask), channel.gain[0]);
    try std.testing.expectEqual(@as(u16, gam.field.gain_mask), channel.gain[1]);
}

test "a threshold field wider than ten bits is masked" {
    var channel = gam.Channel{};
    channel.latch(.{ .channel = 0, .table = .area, .index = 0 }, packThresholds(0xFFFF, 0xFFFF));
    try std.testing.expectEqual(@as(u16, gam.field.threshold_mask), channel.threshold[0]);
}

test "a two-segment curve bends where the threshold says" {
    var channel = gam.Channel{};
    // Flat unity everywhere, then flatten the first segment to nothing.
    flat(&channel, gam.field.unity);
    channel.latch(.{ .channel = 0, .table = .lut, .index = 0 }, packGains(0, gam.field.unity));
    var index: u8 = 0;
    while (index < gam.geometry.registers) : (index += 1) {
        const high: u32 = (@as(u32, index) * 2 + 1) * 64;
        const low: u32 = (@as(u32, index) * 2 + 2) * 64;
        channel.latch(.{ .channel = 0, .table = .area, .index = index }, packThresholds(high, low));
    }
    // Below the first threshold the gain is zero, so the sample is crushed.
    try std.testing.expectEqual(@as(u32, 0), channel.apply(32));
    // Past it, the unity segments carry the rest of the rise.
    try std.testing.expect(channel.apply(200) > 0);
}

test "a programmed block counts its writes" {
    var channel = gam.Channel{};
    channel.latch(.{ .channel = 0, .table = .lut, .index = 0 }, packGains(1, 1));
    channel.latch(.{ .channel = 0, .table = .area, .index = 0 }, packThresholds(1, 1));
    try std.testing.expectEqual(@as(u32, 2), channel.writes);
    try std.testing.expect(channel.programmed);
}

test "a descending threshold pair does not stall the walk" {
    var channel = gam.Channel{};
    flat(&channel, gam.field.unity);
    var index: u8 = 0;
    while (index < gam.geometry.registers) : (index += 1) {
        channel.latch(.{ .channel = 0, .table = .area, .index = index }, packThresholds(0, 0));
    }
    try std.testing.expectEqual(@as(u32, 700), channel.apply(700));
}
