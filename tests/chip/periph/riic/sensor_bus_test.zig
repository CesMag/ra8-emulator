//! SCCB through the actual RIIC transfer machine, not just the sensor callbacks.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.periph.riic.bus;
const flags = ra8.chip.periph.riic.flags;
const ov5640 = ra8.components.ov5640;
const expander = ra8.components.pi4ioe;
const riic = ra8.chip.periph.riic;

const ch1 = flags.win_base + flags.channel_stride;

fn at(offset: u32) u32 {
    return ch1 + offset;
}

fn write(unit: *riic.Riic, offset: u32, value: u8) void {
    unit.write(at(offset), 1, value);
}

fn start(unit: *riic.Riic) void {
    write(unit, flags.reg.iccr2, flags.iccr2.st);
}

fn address(unit: *riic.Riic, target: u7, read: bool) void {
    write(unit, flags.reg.icdrt, bus.wire.byte(target, read));
}

fn readRegister(unit: *riic.Riic, register: u16) u8 {
    start(unit);
    address(unit, ov5640.address, false);
    write(unit, flags.reg.icdrt, @truncate(register >> 8));
    write(unit, flags.reg.icdrt, @truncate(register));

    write(unit, flags.reg.iccr2, flags.iccr2.rs);
    while (unit.read(at(flags.reg.iccr2), 1) & flags.iccr2.rs != 0) {}
    address(unit, ov5640.address, true);
    write(unit, flags.reg.icmr3, flags.icmr3.wait | flags.icmr3.ackwp);
    write(unit, flags.reg.icmr3, flags.icmr3.wait | flags.icmr3.ackwp | flags.icmr3.ackbt);
    write(unit, flags.reg.icmr3, flags.icmr3.wait | flags.icmr3.ackbt);
    _ = unit.read(at(flags.reg.icdrr), 1);
    write(unit, flags.reg.iccr2, flags.iccr2.sp);
    const value: u8 = @truncate(unit.read(at(flags.reg.icdrr), 1));
    write(unit, flags.reg.icmr3, 0);
    return value;
}

test "RIIC repeated-start reads the OV5640 chip ID over SCCB" {
    var unit = riic.Riic.init();
    var sensor = ov5640.Sensor{};
    try unit.attachDevice(sensor.device());
    write(&unit, flags.reg.iccr1, flags.iccr1.ice);

    try std.testing.expectEqual(ov5640.reg.id_high_value, readRegister(&unit, ov5640.reg.id_high));
    try std.testing.expectEqual(ov5640.reg.id_low_value, readRegister(&unit, ov5640.reg.id_low));
    try std.testing.expectEqual(@as(u32, 2), sensor.id_reads);
    try std.testing.expectEqual(@as(u32, 4), unit.channels[flags.line_channel].sent);
    try std.testing.expectEqual(@as(u32, 2), unit.channels[flags.line_channel].received);
    try std.testing.expectEqual(@as(u32, 2), unit.channels[flags.line_channel].transfers);
    try std.testing.expect(!unit.channels[flags.line_channel].busy);
}

test "RIIC STOP after one byte releases a long responder frame" {
    var unit = riic.Riic.init();
    var part = expander.Expander{};
    try unit.attachDevice(part.device());
    write(&unit, flags.reg.iccr1, flags.iccr1.ice);

    start(&unit);
    address(&unit, expander.address, false);
    write(&unit, flags.reg.icdrt, 0);
    write(&unit, flags.reg.iccr2, flags.iccr2.rs);
    while (unit.read(at(flags.reg.iccr2), 1) & flags.iccr2.rs != 0) {}
    address(&unit, expander.address, true);
    write(&unit, flags.reg.icmr3, flags.icmr3.wait | flags.icmr3.ackwp);
    write(&unit, flags.reg.icmr3, flags.icmr3.wait | flags.icmr3.ackwp | flags.icmr3.ackbt);
    write(&unit, flags.reg.icmr3, flags.icmr3.wait | flags.icmr3.ackbt);
    _ = unit.read(at(flags.reg.icdrr), 1);
    write(&unit, flags.reg.iccr2, flags.iccr2.sp);
    const value: u8 = @truncate(unit.read(at(flags.reg.icdrr), 1));
    try std.testing.expectEqual(@as(u8, 0), value);
    write(&unit, flags.reg.icmr3, 0);

    try std.testing.expect(!unit.channels[flags.line_channel].busy);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[flags.line_channel].transfers);
}
