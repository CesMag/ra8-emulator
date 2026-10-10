//! Covers src/chip/periph/riic/restart.zig: RS stands until the driver reads it
//! back, and an ICDRT store made inside that window carries nothing.
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

fn start(unit: *riic.Riic) void {
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
}

fn address(unit: *riic.Riic, target: u7, reading: bool) void {
    unit.write(at(flag.reg.icdrt), 1, bus.wire.byte(target, reading));
}

/// Open a write transaction and put one payload byte in, the state the driver
/// is in when it asks for a restart.
fn midTransfer(unit: *riic.Riic, expander: *pi4ioe.Expander) !void {
    try armed(unit, expander);
    start(unit);
    address(unit, pi4ioe.address, false);
    unit.write(at(flag.reg.icdrt), 1, pi4ioe.file.device_id);
}

test "RS stands until the driver reads it back" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);

    try std.testing.expectEqual(
        @as(u32, flag.iccr2.rs),
        unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.rs,
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.rs,
    );
}

test "an address written while RS reads 1 is dropped and counted" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    address(&unit, pi4ioe.address, true);

    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.restart.dropped);
    try std.testing.expect(!channel.reading);
    try std.testing.expect(!channel.addressed);
}

test "the driver can come back with the address once RS reads 0" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    address(&unit, pi4ioe.address, true);
    _ = unit.read(at(flag.reg.iccr2), 1);
    address(&unit, pi4ioe.address, true);

    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.restart.dropped);
    try std.testing.expect(channel.reading);
    try std.testing.expect(channel.addressed);
}

test "a payload byte is dropped inside the restart window too" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);
    const before = unit.channels[flag.line_channel].sent;
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    unit.write(at(flag.reg.icdrt), 1, 0x5A);

    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.restart.dropped);
    try std.testing.expectEqual(before, channel.sent);
}

test "a START opens no restart window" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, pi4ioe.address, false);

    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 0), channel.restart.dropped);
    try std.testing.expect(channel.addressed);
}

test "a repeated START on an idle bus leaves RS clear" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);

    try std.testing.expectEqual(
        @as(u32, 0),
        unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.rs,
    );
    try std.testing.expectEqual(@as(u32, 1), unit.channels[flag.line_channel].rs_idle);
}

test "disabling the interface closes the restart window" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    unit.write(at(flag.reg.iccr1), 1, 0);
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice);
    start(&unit);
    address(&unit, pi4ioe.address, false);

    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 0), channel.restart.dropped);
    try std.testing.expect(channel.addressed);
}

test "a dropped address alone is enough to earn a report line" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    address(&unit, pi4ioe.address, true);
    try std.testing.expect(!unit.channels[flag.line_channel].quiet());
}

// The hasty half of fw/probe/i2crs.c: the address written before RS was read
// back is lost, so the read that follows has nothing staged to serve.
test "the probe's hasty sequence loses the address it wrote too early" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    address(&unit, pi4ioe.address, true);
    _ = unit.read(at(flag.reg.icdrr), 1);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.icdrr), 1));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].restart.dropped);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].received);
}

// The patient half: the driver's own order, which is every in-tree driver's
// order, still reads the register it asked for and drops nothing.
test "the probe's patient sequence reads the register and drops nothing" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    try std.testing.expect(unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.rs != 0);
    address(&unit, pi4ioe.address, true);
    _ = unit.read(at(flag.reg.icdrr), 1);
    try std.testing.expect(unit.read(at(flag.reg.icdrr), 1) != 0);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].restart.dropped);
}

// The window must not outlive the transaction. Silicon clears RS once the
// condition is issued whether or not the driver looks, so a driver that never
// reads ICCR2 back must not have the next transaction's address swallowed.
test "requesting the next condition closes a window nobody read" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try midTransfer(&unit, &expander);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    try std.testing.expect(!unit.channels[1].restart.blocks());

    start(&unit);
    address(&unit, pi4ioe.address, false);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].restart.dropped);
}
