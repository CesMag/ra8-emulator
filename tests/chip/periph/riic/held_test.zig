//! Covers the bus-held-low fault (RA8EMU-519): riic_bus.Registry.hold and
//! how the RIIC controller sees a line it cannot drive.
const std = @import("std");
const ra8 = @import("ra8");
const riic = ra8.chip.periph.riic;
const flag = ra8.chip.periph.riic.flags;
const bus = ra8.chip.periph.riic.bus;
const pi4ioe = ra8.components.pi4ioe;

const ch1 = flag.win_base + flag.channel_stride;

fn at(offset: u32) u32 {
    return ch1 + offset;
}

fn armed(unit: *riic.Riic, expander: *pi4ioe.Expander) !void {
    try unit.attachDevice(expander.device());
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice);
}

fn bbsy(unit: *riic.Riic) bool {
    return unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.bbsy != 0;
}

/// START, address the expander, one data byte, STOP.
fn writeOne(unit: *riic.Riic, byte: u8) void {
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
    unit.write(at(flag.reg.icdrt), 1, bus.wire.byte(pi4ioe.address, false));
    unit.write(at(flag.reg.icdrt), 1, byte);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
}

test "a free bus reads not busy and a transfer goes through" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    try std.testing.expect(!bbsy(&unit));
    writeOne(&unit, 0x01);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[flag.line_channel].transfers);
}

test "a held-low bus reads busy and refuses every START" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.devices.hold(true);
    try std.testing.expect(bbsy(&unit));
    writeOne(&unit, 0x01);
    writeOne(&unit, 0x02);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 0), channel.transfers);
    try std.testing.expectEqual(@as(u32, 2), channel.st_busy);
    try std.testing.expect(channel.no_start > 0);
    try std.testing.expect(!channel.quiet());
    try std.testing.expect(bbsy(&unit));
}

test "letting the line go frees the bus and the next START works" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.devices.hold(true);
    writeOne(&unit, 0x01);
    unit.devices.hold(false);
    try std.testing.expect(!bbsy(&unit));
    writeOne(&unit, 0x01);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[flag.line_channel].transfers);
}

test "the hold is on the shared bus, so every channel sees it" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.write(flag.win_base + flag.reg.iccr1, 1, flag.iccr1.ice);
    unit.devices.hold(true);
    try std.testing.expect(unit.read(flag.win_base + flag.reg.iccr2, 1) & flag.iccr2.bbsy != 0);
    try std.testing.expect(bbsy(&unit));
}
