//! An access is the bytes it names, low lane first, on the RIIC window.
const std = @import("std");
const ra8 = @import("ra8");
const riic = ra8.chip.periph.riic;
const access = ra8.chip.periph.bytelanes;
const flag = ra8.chip.periph.riic_flags;
const bus = ra8.chip.periph.riic_bus;
const pi4ioe = ra8.components.pi4ioe;

const ch1 = flag.win_base + flag.channel_stride;

fn at(offset: u32) u32 {
    return ch1 + offset;
}

fn enabled(unit: *riic.Riic, expander: *pi4ioe.Expander) !void {
    try unit.attachDevice(expander.device());
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice);
}

test "a width names that many bytes, and anything odd is a whole word" {
    try std.testing.expectEqual(@as(u32, 1), access.span(1));
    try std.testing.expectEqual(@as(u32, 2), access.span(2));
    try std.testing.expectEqual(@as(u32, 4), access.span(4));
    try std.testing.expectEqual(@as(u32, 4), access.span(3));
}

test "bytes come out of a store low lane first and go back in the same order" {
    try std.testing.expectEqual(@as(u8, 0x21), access.byteAt(0x8765_4321, 0));
    try std.testing.expectEqual(@as(u8, 0x87), access.byteAt(0x8765_4321, 3));
    var answer: u32 = 0;
    answer = access.place(answer, 0x21, 0);
    answer = access.place(answer, 0x87, 3);
    try std.testing.expectEqual(@as(u32, 0x8700_0021), answer);
}

test "a halfword store that enables and STARTs does both, in that order" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try unit.attachDevice(expander.device());
    const word = @as(u32, flag.iccr1.ice) | (@as(u32, flag.iccr2.st) << 8);
    unit.write(at(flag.reg.iccr1), 2, word);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expect(channel.enabled());
    try std.testing.expect(channel.busy);
    try std.testing.expectEqual(@as(u32, 0), channel.uninit);
}

test "the same store byte-wide is the whole of what a driver meant" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try enabled(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
    unit.write(at(flag.reg.icdrt), 1, bus.wire.byte(pi4ioe.address, false));
    // The expander takes the first payload byte as its register pointer and
    // the next one as the value for it.
    unit.write(at(flag.reg.icdrt), 1, 0x03);
    unit.write(at(flag.reg.icdrt), 1, 0x5A);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[flag.line_channel].transfers);
    try std.testing.expectEqual(@as(u32, 1), expander.writes);
    try std.testing.expectEqual(@as(u8, 0x5A), expander.registers[0x03]);
}

test "a halfword read answers ICSR1 low and ICSR2 in the lane above it" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try enabled(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
    const pair = unit.read(at(flag.reg.icsr1), 2);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, channel.status), pair >> 8);
    try std.testing.expect(pair >> 8 & flag.icsr2.tdre != 0);
}

test "a byte read of ICSR2 alone still answers it right-justified" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try enabled(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
    const status = unit.read(at(flag.reg.icsr2), 1);
    try std.testing.expectEqual(@as(u32, flag.icsr2.tdre), status);
}

test "a word store at the data pair puts the address byte on the wire" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try enabled(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
    const word = @as(u32, bus.wire.byte(pi4ioe.address, false)) << 16;
    unit.write(at(flag.reg.icdrt - 2), 4, word);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expect(channel.addressed);
    try std.testing.expect(channel.acked);
}

test "a halfword access is still refused on a disabled interface, once per byte" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try unit.attachDevice(expander.device());
    unit.write(at(flag.reg.icsr1), 2, 0xFFFF);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 2), channel.uninit);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.icsr1), 2));
}

test "an access past the last channel answers zero and holds nothing" {
    var unit = riic.Riic.init();
    const past = flag.win_base + flag.win_span;
    unit.write(past, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(past, 4));
    try std.testing.expect(unit.quiet());
}
