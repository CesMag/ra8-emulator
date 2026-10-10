//! Tests for src/chip/periph/mrms.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mrms = ra8.chip.periph.mrms;

fn unit() mrms.Mrms {
    return .{};
}

test "an image that touched nothing here stays out of the report" {
    var m = unit();
    try std.testing.expect(m.quiet());
}

test "a frequency store carrying the right key latches the megahertz" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, mrms.key.mrcfreq | 250);
    try std.testing.expectEqual(@as(u32, 250), m.code.mhz);
    try std.testing.expectEqual(@as(u32, 1), m.code.latched);
}

test "the key is not part of what reads back" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, mrms.key.mrcfreq | 250);
    try std.testing.expectEqual(@as(u32, 250), m.read(mrms.win_base + mrms.regs.mrcfreq, 4));
}

test "the driver's own wait loop terminates on the second read" {
    var m = unit();
    const at = mrms.win_base + mrms.regs.mrcfreq;
    try std.testing.expect(m.read(at, 4) != 250);
    m.write(at, 4, mrms.key.mrcfreq | 250);
    try std.testing.expectEqual(@as(u32, 250), m.read(at, 4));
}

test "a store with the wrong key is dropped and counted" {
    var m = unit();
    const at = mrms.win_base + mrms.regs.mrcfreq;
    m.write(at, 4, mrms.key.mrefreq | 250);
    try std.testing.expectEqual(@as(u32, 0), m.code.mhz);
    try std.testing.expectEqual(@as(u32, 1), m.code.refused);
    try std.testing.expectEqual(@as(u32, 0), m.code.latched);
}

test "a store with no key at all is dropped too" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, 250);
    try std.testing.expectEqual(@as(u32, 0), m.code.mhz);
    try std.testing.expectEqual(@as(u32, 1), m.code.refused);
}

test "a dropped store leaves the previous frequency standing" {
    var m = unit();
    const at = mrms.win_base + mrms.regs.mrcfreq;
    m.write(at, 4, mrms.key.mrcfreq | 250);
    m.write(at, 4, 125);
    try std.testing.expectEqual(@as(u32, 250), m.read(at, 4));
}

test "the two latches want different keys and do not accept each other's" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrefreq, 4, mrms.key.mrefreq | 125);
    try std.testing.expectEqual(@as(u32, 125), m.extra.mhz);
    m.write(mrms.win_base + mrms.regs.mrefreq, 4, mrms.key.mrcfreq | 125);
    try std.testing.expectEqual(@as(u32, 1), m.extra.refused);
}

test "the two latches are separate registers" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, mrms.key.mrcfreq | 250);
    m.write(mrms.win_base + mrms.regs.mrefreq, 4, mrms.key.mrefreq | 125);
    try std.testing.expectEqual(@as(u32, 250), m.read(mrms.win_base + mrms.regs.mrcfreq, 4));
    try std.testing.expectEqual(@as(u32, 125), m.read(mrms.win_base + mrms.regs.mrefreq, 4));
}

test "MRCPFB has no key and is retained as written" {
    var m = unit();
    const at = mrms.win_base + mrms.regs.mrcpfb;
    try std.testing.expect(!m.prefetching());
    m.write(at, 4, mrms.prefetch_on);
    try std.testing.expect(m.prefetching());
    try std.testing.expectEqual(@as(u32, 1), m.read(at, 4));
    m.write(at, 4, 0);
    try std.testing.expect(!m.prefetching());
}

test "the prefetch dummy reads after a clear read back the cleared word" {
    var m = unit();
    const at = mrms.win_base + mrms.regs.mrcpfb;
    m.write(at, 4, mrms.prefetch_on);
    m.write(at, 4, 0);
    for (0..3) |_| try std.testing.expectEqual(@as(u32, 0), m.read(at, 4));
}

test "a refused store is enough to put the unit in the report" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, 250);
    try std.testing.expect(!m.quiet());
}

test "the window covers the three registers the driver names" {
    try std.testing.expectEqual(@as(u32, 0x4013_C000), mrms.win_base);
    try std.testing.expectEqual(@as(u32, 0x0C), mrms.win_span);
}

test "a frequency store with the buffer still up is counted, not turned away" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, mrms.prefetch_on);
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, mrms.key.mrcfreq | 250);
    try std.testing.expectEqual(@as(u32, 250), m.code.mhz);
    try std.testing.expectEqual(@as(u32, 1), m.code.latched);
    try std.testing.expectEqual(@as(u32, 1), m.hot_changes);
}

test "the other latch answers to the same rule" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, mrms.prefetch_on);
    m.write(mrms.win_base + mrms.regs.mrefreq, 4, mrms.key.mrefreq | 200);
    try std.testing.expectEqual(@as(u32, 200), m.extra.mhz);
    try std.testing.expectEqual(@as(u32, 1), m.hot_changes);
}

test "the driver's own order counts nothing" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, 0);
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, mrms.key.mrcfreq | 250);
    m.write(mrms.win_base + mrms.regs.mrefreq, 4, mrms.key.mrefreq | 250);
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, mrms.prefetch_on);
    try std.testing.expectEqual(@as(u32, 0), m.hot_changes);
    try std.testing.expectEqual(@as(u32, 0), m.early_enables);
    try std.testing.expect(m.prefetching());
}

test "enabling the buffer under the floor is counted" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, mrms.key.mrcfreq | (mrms.threshold_mhz - 1));
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, mrms.prefetch_on);
    try std.testing.expectEqual(@as(u32, 1), m.early_enables);
    try std.testing.expect(m.prefetching());
}

test "the floor itself is high enough" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcfreq, 4, mrms.key.mrcfreq | mrms.threshold_mhz);
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, mrms.prefetch_on);
    try std.testing.expectEqual(@as(u32, 0), m.early_enables);
}

test "a store that puts the buffer down counts nothing either way" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), m.early_enables);
    try std.testing.expect(!m.prefetching());
    try std.testing.expect(m.quiet());
}

test "either count alone is enough to be worth reporting" {
    var m = unit();
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, mrms.prefetch_on);
    m.write(mrms.win_base + mrms.regs.mrcpfb, 4, 0);
    try std.testing.expectEqual(@as(u32, 1), m.early_enables);
    try std.testing.expect(!m.quiet());
}
