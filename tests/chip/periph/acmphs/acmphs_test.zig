const std = @import("std");
const ra8 = @import("ra8");

const acmphs = ra8.chip.periph.acmphs;
const output = ra8.chip.periph.acmphs.output;

fn ctl(unit: usize) u32 {
    return acmphs.channelAddress(unit) + acmphs.off.cmpctl;
}

fn mon(unit: usize) u32 {
    return acmphs.channelAddress(unit) + acmphs.off.cmpmon;
}

test "an untouched block stays out of the report" {
    var block = acmphs.Acmphs.init();
    try std.testing.expect(block.quiet());
}

test "CMPCTL reads back what firmware wrote" {
    var block = acmphs.Acmphs.init();
    const value = output.mask.hcmpon | output.mask.cinv | output.mask.coe;
    block.write(ctl(0), 1, value);
    try std.testing.expectEqual(@as(u32, value), block.read(ctl(0), 1));
}

test "CMPMON is read-only and the store is counted" {
    var block = acmphs.Acmphs.init();
    block.write(ctl(1), 1, output.mask.hcmpon);
    block.write(mon(1), 1, 0x01);
    try std.testing.expectEqual(@as(u32, 1), block.channels[1].refused);
    try std.testing.expectEqual(@as(u32, 0), block.read(mon(1), 1));
}

test "a channel with HCMPON clear monitors nothing and the poll is counted dark" {
    var block = acmphs.Acmphs.init();
    try std.testing.expectEqual(@as(u32, 0), block.read(mon(2), 1));
    try std.testing.expectEqual(@as(u32, 1), block.channels[2].dark_polls);
    try std.testing.expectEqual(@as(u32, 0), block.channels[2].polls);
}

test "an operating inverted channel reads high" {
    var block = acmphs.Acmphs.init();
    block.write(ctl(3), 1, output.mask.hcmpon | output.mask.cinv);
    try std.testing.expectEqual(@as(u32, output.cmpmon), block.read(mon(3), 1));
    try std.testing.expectEqual(@as(u32, 1), block.channels[3].polls);
}

test "the input selects read back per channel" {
    var block = acmphs.Acmphs.init();
    const base = acmphs.channelAddress(4);
    block.write(base + acmphs.off.cmpsel0, 1, 0x05);
    block.write(base + acmphs.off.cmpsel1, 1, 0x0B);
    try std.testing.expectEqual(@as(u32, 0x05), block.read(base + acmphs.off.cmpsel0, 1));
    try std.testing.expectEqual(@as(u32, 0x0B), block.read(base + acmphs.off.cmpsel1, 1));
    try std.testing.expectEqual(@as(u32, 0), block.read(acmphs.channelAddress(5) + acmphs.off.cmpsel0, 1));
}

test "the interrupt registers are stored and read back, and raise nothing" {
    var block = acmphs.Acmphs.init();
    const base = acmphs.channelAddress(0);
    block.write(base + acmphs.off.cpintctl, 1, 0x03);
    block.write(base + acmphs.off.cpmskctl, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0x03), block.read(base + acmphs.off.cpintctl, 1));
    try std.testing.expectEqual(@as(u32, 0x01), block.read(base + acmphs.off.cpmskctl, 1));
}

test "an unnamed offset in the window is shadowed" {
    var block = acmphs.Acmphs.init();
    const base = acmphs.channelAddress(0);
    block.write(base + 0x20, 1, 0x77);
    try std.testing.expectEqual(@as(u32, 0x77), block.read(base + 0x20, 1));
}

test "a word read of CMPCTL puts it in the low byte" {
    var block = acmphs.Acmphs.init();
    block.write(ctl(0), 1, output.mask.hcmpon);
    try std.testing.expectEqual(@as(u32, output.mask.hcmpon), block.read(ctl(0), 4));
}

test "a read-modify-write of CMPCTL keeps the enable and adds the polarity" {
    var block = acmphs.Acmphs.init();
    block.write(ctl(0), 1, output.mask.hcmpon);
    const current: u8 = @truncate(block.read(ctl(0), 1));
    block.write(ctl(0), 1, current | output.mask.cinv);
    try std.testing.expect(block.channels[0].operating());
    try std.testing.expect(block.channels[0].inverted());
}

test "channels do not share state" {
    var block = acmphs.Acmphs.init();
    block.write(ctl(0), 1, output.mask.hcmpon);
    try std.testing.expect(block.channels[0].operating());
    try std.testing.expect(!block.channels[1].operating());
}
