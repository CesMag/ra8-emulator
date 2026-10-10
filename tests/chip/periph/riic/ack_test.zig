//! Covers src/chip/periph/riic/ack.zig: ACKBT moves only with ACKWP already in
//! force, so the enable and the set are two separate stores.
const std = @import("std");
const ra8 = @import("ra8");
const riic = ra8.chip.periph.riic;
const flag = ra8.chip.periph.riic_flags;
const pi4ioe = ra8.components.pi4ioe;

const ch1 = flag.win_base + flag.channel_stride;

fn at(offset: u32) u32 {
    return ch1 + offset;
}

fn armed(unit: *riic.Riic, expander: *pi4ioe.Expander) !void {
    try unit.attachDevice(expander.device());
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice);
}

fn mode(unit: *riic.Riic) u8 {
    return @truncate(unit.read(at(flag.reg.icmr3), 1));
}

test "ACKBT set with no enable in force is held off and counted" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u8, 0), mode(&unit) & flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].ack.protected);
}

test "the enable and the set in one store do not carry the set" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.ackwp | flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u8, flag.icmr3.ackwp), mode(&unit) & flag.icmr3.ackwp);
    try std.testing.expectEqual(@as(u8, 0), mode(&unit) & flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].ack.protected);
}

// internal_i2c_set_nack in ra8_i2c.c, the order HUM Ch 39.2.5 Note 1 asks
// for: enable, set, disable, as three separate register writes.
test "the driver's three separate writes set ACKBT and leave it set" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, mode(&unit) | flag.icmr3.ackwp);
    unit.write(at(flag.reg.icmr3), 1, mode(&unit) | flag.icmr3.ackbt);
    unit.write(at(flag.reg.icmr3), 1, mode(&unit) & ~flag.icmr3.ackwp);

    try std.testing.expectEqual(@as(u8, flag.icmr3.ackbt), mode(&unit) & flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u8, 0), mode(&unit) & flag.icmr3.ackwp);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].ack.protected);
}

test "clearing ACKBT needs the enable too" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, mode(&unit) | flag.icmr3.ackwp);
    unit.write(at(flag.reg.icmr3), 1, mode(&unit) | flag.icmr3.ackbt);
    unit.write(at(flag.reg.icmr3), 1, mode(&unit) & ~flag.icmr3.ackwp);

    unit.write(at(flag.reg.icmr3), 1, mode(&unit) & ~flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u8, flag.icmr3.ackbt), mode(&unit) & flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].ack.protected);

    unit.write(at(flag.reg.icmr3), 1, mode(&unit) | flag.icmr3.ackwp);
    unit.write(at(flag.reg.icmr3), 1, mode(&unit) & ~flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u8, 0), mode(&unit) & flag.icmr3.ackbt);
}

test "the unprotected bits move with or without the enable" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.wait | flag.icmr3.rdrfs | flag.icmr3.smbs);
    try std.testing.expectEqual(
        @as(u8, flag.icmr3.wait | flag.icmr3.rdrfs | flag.icmr3.smbs),
        mode(&unit),
    );
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].ack.protected);
}

test "a store that leaves ACKBT where it is needs no enable" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.wait);
    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.wait | flag.icmr3.rdrfs);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[1].ack.protected);
}

test "the protection is per channel" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.ackbt);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[1].ack.protected);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].ack.protected);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[2].ack.protected);
}

test "a held-off store leaves the rest of the byte alone" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.ackbt | flag.icmr3.wait);
    try std.testing.expectEqual(@as(u8, flag.icmr3.wait), mode(&unit));
}
