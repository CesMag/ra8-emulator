//! Covers src/chip/periph/mpu/mpu_background.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mpu = ra8.chip.periph.mpu;
const background = ra8.chip.periph.mpu_background;

/// A table with the given spans enabled, written the way the firmware would
/// through RBAR/RLAR so the region fields come out of the real decoder.
fn tableOf(spans: []const [2]u32) mpu.Mpu {
    var unit = mpu.Mpu{};
    for (spans, 0..) |span, i| {
        unit.table[i] = mpu.Region.fromPair(
            span[0] | mpu.field.rbar_ap_unprivileged,
            (span[1] & mpu.field.address) | mpu.field.rlar_enable,
        );
    }
    return unit;
}

fn gapsOf(unit: *const mpu.Mpu, out: *[background.limits.spans]background.Span) []background.Span {
    return background.gaps(unit, out);
}

test "an empty table leaves the whole address space in the background" {
    const unit = mpu.Mpu{};
    var out: [background.limits.spans]background.Span = undefined;
    const found = gapsOf(&unit, &out);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(u32, 0), found[0].base);
    try std.testing.expectEqual(background.limits.top, found[0].limit);
}

test "one region in the middle leaves a gap either side" {
    const unit = tableOf(&.{.{ 0x2000_0000, 0x2000_FFFF }});
    var out: [background.limits.spans]background.Span = undefined;
    const found = gapsOf(&unit, &out);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(u32, 0), found[0].base);
    try std.testing.expectEqual(@as(u32, 0x1FFF_FFFF), found[0].limit);
    try std.testing.expectEqual(@as(u32, 0x2001_0000), found[1].base);
    try std.testing.expectEqual(background.limits.top, found[1].limit);
}

test "regions out of order still give gaps lowest first" {
    const unit = tableOf(&.{
        .{ 0x2000_0000, 0x2000_FFFF },
        .{ 0x0000_0000, 0x0000_FFFF },
    });
    var out: [background.limits.spans]background.Span = undefined;
    const found = gapsOf(&unit, &out);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(u32, 0x0001_0000), found[0].base);
    try std.testing.expectEqual(@as(u32, 0x1FFF_FFFF), found[0].limit);
    try std.testing.expectEqual(@as(u32, 0x2001_0000), found[1].base);
}

test "overlapping regions do not open a gap between them" {
    const unit = tableOf(&.{
        .{ 0x2000_0000, 0x2000_FFFF },
        .{ 0x2000_8000, 0x2001_FFFF },
    });
    var out: [background.limits.spans]background.Span = undefined;
    const found = gapsOf(&unit, &out);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(u32, 0x1FFF_FFFF), found[0].limit);
    try std.testing.expectEqual(@as(u32, 0x2002_0000), found[1].base);
}

test "a region running to the top leaves no gap above it" {
    const unit = tableOf(&.{
        .{ 0x0000_0000, 0xDFFF_FFFF },
        .{ 0xE000_0000, 0xFFFF_FFE0 },
    });
    var out: [background.limits.spans]background.Span = undefined;
    const found = gapsOf(&unit, &out);
    // RLAR's low five bits are always set, so the second region really does
    // reach 0xFFFFFFFF and the complement is empty.
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a disabled entry covers nothing and does not close a gap" {
    var unit = tableOf(&.{.{ 0x2000_0000, 0x2000_FFFF }});
    unit.table[1] = mpu.Region.fromPair(0x3000_0000, 0x3000_FFE0);
    var out: [background.limits.spans]background.Span = undefined;
    const found = gapsOf(&unit, &out);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(u32, 0x2001_0000), found[1].base);
    try std.testing.expectEqual(background.limits.top, found[1].limit);
}

test "a disabled MPU has no background at all" {
    const unit = mpu.Mpu{};
    try std.testing.expect(!background.refuses(&unit, false));
    try std.testing.expect(!background.refuses(&unit, true));
}

test "without PRIVDEFENA the background is refused to everyone" {
    var unit = mpu.Mpu{};
    unit.ctrl = mpu.field.ctrl_enable;
    try std.testing.expect(background.refuses(&unit, false));
    try std.testing.expect(background.refuses(&unit, true));
}

test "PRIVDEFENA hands the default map to privileged code only" {
    var unit = mpu.Mpu{};
    unit.ctrl = mpu.field.ctrl_enable | mpu.field.ctrl_privdefena;
    try std.testing.expect(!background.refuses(&unit, true));
    try std.testing.expect(background.refuses(&unit, false));
}
