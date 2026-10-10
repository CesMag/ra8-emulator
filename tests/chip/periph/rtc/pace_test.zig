//! Covers src/chip/periph/rtc/pace.zig: the geared boundary clock the corpus
//! was recorded on, and the virtual-time clock that counts nanoseconds.
const std = @import("std");
const ra8 = @import("ra8");

const rtc = ra8.chip.periph.rtc;
const pace = rtc.pace;

fn read8(unit: *rtc.Rtc, offset: u32) u8 {
    return @truncate(unit.read(rtc.win_base + offset, 1));
}

fn started(mode: pace.Mode) rtc.Rtc {
    var unit = rtc.Rtc.init();
    unit.pace.mode = mode;
    unit.write(rtc.win_base + rtc.off.rcr2, 1, 0x01);
    return unit;
}

test "a geared clock owes one second and one sub-second step whatever the time" {
    var gear = pace.Pace{};
    const owed = gear.step(123_456_789_000, 1);
    try std.testing.expectEqual(@as(u64, 1), owed.seconds);
    try std.testing.expectEqual(@as(u64, 1), owed.r64);
    try std.testing.expectEqual(@as(u64, 0), gear.run_ns);
}

test "a virtual clock carries the sub-second part to the next boundary" {
    var gear = pace.Pace{ .mode = .virtual };
    try std.testing.expectEqual(@as(u64, 0), gear.step(999_999_999, 1).seconds);
    try std.testing.expectEqual(@as(u64, 1), gear.step(1, 1).seconds);
    try std.testing.expectEqual(@as(u64, 2), gear.step(2_000_000_000, 1).seconds);
}

test "R64CNT steps at 64 Hz of virtual time" {
    var gear = pace.Pace{ .mode = .virtual };
    try std.testing.expectEqual(@as(u64, 0), gear.step(15_624_999, 1).r64);
    try std.testing.expectEqual(@as(u64, 1), gear.step(1, 1).r64);
    try std.testing.expectEqual(@as(u64, 64), pace.r64Count(pace.ns_per_second));
}

test "a virtual RTC publishes the seconds the run actually took" {
    var unit = started(.virtual);
    unit.tickFor(500_000_000);
    try std.testing.expectEqual(@as(u8, 0x00), read8(&unit, rtc.off.seccnt));
    try std.testing.expectEqual(@as(u8, 32), read8(&unit, rtc.off.r64cnt));
    unit.tickFor(2_500_000_000);
    try std.testing.expectEqual(@as(u8, 0x03), read8(&unit, rtc.off.seccnt));
    try std.testing.expectEqual(@as(u32, 3), unit.seconds);
}

test "a geared RTC still moves a second a boundary" {
    var unit = started(.boundary);
    unit.tickFor(1);
    unit.tickFor(1);
    try std.testing.expectEqual(@as(u8, 0x02), read8(&unit, rtc.off.seccnt));
}

test "a stopped virtual RTC banks no time" {
    var unit = rtc.Rtc.init();
    unit.pace.mode = .virtual;
    unit.tickFor(5_000_000_000);
    try std.testing.expectEqual(@as(u64, 0), unit.pace.run_ns);
    try std.testing.expectEqual(@as(u32, 0), unit.seconds);
}
