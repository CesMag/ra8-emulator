const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.chip.periph.sci;
const sci_lin = ra8.chip.periph.sci_lin;

const channel_base = sci.win_base + sci.stride * 3;

fn programmed(unit: *sci.Sci) void {
    unit.write(channel_base + sci_lin.off.xcr0, 4, sci_lin.xcr0.bfe | 2);
    unit.write(channel_base + sci_lin.off.xcr2, 4, 0x0013 << sci_lin.xcr2.bflw_shift);
}

test "TCST is spent on the store, so the driver's poll for the self-clear ends" {
    var unit = sci.Sci.init();
    programmed(&unit);
    unit.write(channel_base + sci_lin.off.xcr1, 4, sci_lin.xcr1.tcst);
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel_base + sci_lin.off.xcr1, 4) & sci_lin.xcr1.tcst);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[3].lin.breaks);
}

test "the break latches XSR0.BFOF and XFCLR takes it back down" {
    var unit = sci.Sci.init();
    programmed(&unit);
    unit.write(channel_base + sci_lin.off.xcr1, 4, sci_lin.xcr1.tcst);
    try std.testing.expectEqual(sci_lin.xsr0.bfof, unit.read(channel_base + sci_lin.off.xsr0, 4));
    unit.write(channel_base + sci_lin.off.xfclr, 4, sci_lin.xsr0.bfof);
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel_base + sci_lin.off.xsr0, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel_base + sci_lin.off.xfclr, 4));
}

test "the settings bits of XCR1 stay where a store put them" {
    var unit = sci.Sci.init();
    programmed(&unit);
    const settings = sci_lin.xcr1.sdst | sci_lin.xcr1.bmen;
    unit.write(channel_base + sci_lin.off.xcr1, 4, settings | sci_lin.xcr1.tcst);
    try std.testing.expectEqual(settings, unit.read(channel_base + sci_lin.off.xcr1, 4));
}

test "a TCST pulse with XCR0.BFE clear puts no break on the wire" {
    var unit = sci.Sci.init();
    unit.write(channel_base + sci_lin.off.xcr1, 4, sci_lin.xcr1.tcst);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[3].lin.breaks);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[3].lin.unenabled);
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel_base + sci_lin.off.xsr0, 4));
}

test "a byte store above TCST carries no command, whatever the word reads" {
    var unit = sci.Sci.init();
    programmed(&unit);
    unit.write(channel_base + sci_lin.off.xcr1 + 2, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[3].lin.breaks);
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), unit.read(channel_base + sci_lin.off.xcr1, 4));
}

test "XSR0 and XSR1 are the block's, and a store to either is refused" {
    var unit = sci.Sci.init();
    unit.write(channel_base + sci_lin.off.xsr0, 4, 0xFFFF_FFFF);
    unit.write(channel_base + sci_lin.off.xsr1, 4, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel_base + sci_lin.off.xsr0, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(channel_base + sci_lin.off.xsr1, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.channels[3].lin.status_stores);
}

test "the break-field length is BFLW plus one, and the reset value is the max" {
    var unit = sci.Sci.init();
    programmed(&unit);
    try std.testing.expectEqual(@as(u32, 0x14), unit.channels[3].lin.length());
    unit.write(channel_base + sci_lin.off.xcr2, 4, sci_lin.xcr2.bflw_max << sci_lin.xcr2.bflw_shift);
    try std.testing.expectEqual(@as(u32, 0xFFFF), unit.channels[3].lin.length());
}

test "a channel that never ran LIN stays quiet" {
    var unit = sci.Sci.init();
    programmed(&unit);
    try std.testing.expect(unit.quiet());
    unit.write(channel_base + sci_lin.off.xcr1, 4, sci_lin.xcr1.tcst);
    try std.testing.expect(!unit.quiet());
}
