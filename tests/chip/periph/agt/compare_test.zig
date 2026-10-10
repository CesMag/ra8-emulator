//! Covers src/chip/periph/agt/compare.zig: AGTCMSR's two compare-match enables,
//! and what the AGT channel does with a crossing on a side nobody armed.
const std = @import("std");
const ra8 = @import("ra8");

const cmp = ra8.chip.periph.agt_compare;
const agt = ra8.chip.periph.agt;

const ch0 = agt.win_base;

fn arm(unit: *agt.Agt, cmsr: u8, period: u16, compare_a: u16) void {
    unit.write(ch0 + agt.off.cmsr, 1, cmsr);
    unit.write(ch0 + agt.off.cnt, 2, period);
    unit.write(ch0 + agt.off.cma, 2, compare_a);
    unit.write(ch0 + agt.off.cr, 1, agt.control.tstart);
}

test "the enable bit of each side is the one the header names" {
    try std.testing.expectEqual(@as(u8, 0x01), cmp.Side.a.enable());
    try std.testing.expectEqual(@as(u8, 0x10), cmp.Side.b.enable());
    try std.testing.expectEqual(@as(u8, 0x02), cmp.Side.a.output());
    try std.testing.expectEqual(@as(u8, 0x20), cmp.Side.b.output());
}

test "a cleared AGTCMSR arms neither side" {
    try std.testing.expect(!cmp.enabled(0x00, .a));
    try std.testing.expect(!cmp.enabled(0x00, .b));
}

test "each enable arms only its own side" {
    try std.testing.expect(cmp.enabled(cmp.mask.tcmea, .a));
    try std.testing.expect(!cmp.enabled(cmp.mask.tcmea, .b));
    try std.testing.expect(cmp.enabled(cmp.mask.tcmeb, .b));
    try std.testing.expect(!cmp.enabled(cmp.mask.tcmeb, .a));
}

test "the output bits do not arm a side on their own" {
    try std.testing.expect(!cmp.enabled(cmp.mask.toea | cmp.mask.topola, .a));
    try std.testing.expect(!cmp.enabled(cmp.mask.toeb | cmp.mask.topolb, .b));
}

test "driving needs the enable as well as the output bit" {
    try std.testing.expect(!cmp.driving(cmp.mask.toea, .a));
    try std.testing.expect(!cmp.driving(cmp.mask.tcmea, .a));
    try std.testing.expect(cmp.driving(cmp.mask.tcmea | cmp.mask.toea, .a));
}

test "the side names are the ones the flags are called by" {
    try std.testing.expectEqualStrings("A", cmp.Side.a.name());
    try std.testing.expectEqualStrings("B", cmp.Side.b.name());
}

test "AGTCMSR reads back what was written" {
    var unit = agt.Agt.init();
    unit.write(ch0 + agt.off.cmsr, 1, cmp.mask.tcmea | cmp.mask.toea);
    try std.testing.expectEqual(
        @as(u32, cmp.mask.tcmea | cmp.mask.toea),
        unit.read(ch0 + agt.off.cmsr, 1),
    );
}

test "a crossing with the function disabled raises no flag and is counted" {
    var unit = agt.Agt.init();
    arm(&unit, 0x00, 0x4000, 0x3800);
    unit.tick();
    const channel = unit.channels[0];
    try std.testing.expectEqual(@as(u32, 0), channel.matches_a);
    try std.testing.expect(channel.masked != 0);
    try std.testing.expectEqual(@as(u8, 0), channel.cr & agt.control.tcmaf);
}

test "the same crossing with TCMEA set raises TCMAF" {
    var unit = agt.Agt.init();
    arm(&unit, cmp.mask.tcmea, 0x4000, 0x3800);
    unit.tick();
    const channel = unit.channels[0];
    try std.testing.expectEqual(@as(u32, 1), channel.matches_a);
    try std.testing.expectEqual(@as(u32, 0), channel.masked);
    try std.testing.expect(channel.cr & agt.control.tcmaf != 0);
}

test "a compare of zero is armed when AGTCMSR says so" {
    var unit = agt.Agt.init();
    arm(&unit, cmp.mask.tcmea, 0x0400, 0x0000);
    unit.tick();
    try std.testing.expect(unit.channels[0].matches_a != 0);
}

test "comparing() reports whether either side is armed" {
    var unit = agt.Agt.init();
    try std.testing.expect(!unit.channels[0].comparing());
    unit.write(ch0 + agt.off.cmsr, 1, cmp.mask.tcmeb);
    try std.testing.expect(unit.channels[0].comparing());
}
