//! The RIIC controller: the transfer machine, and the bus conditions it
//! refuses that dev let pass.
const std = @import("std");
const ra8 = @import("ra8");
const riic = ra8.chip.periph.riic;
const flag = ra8.chip.periph.riic_flags;
const bus = ra8.chip.periph.riic_bus;
const pi4ioe = ra8.components.pi4ioe;
const ov5640 = ra8.components.ov5640;

const ch1 = flag.win_base + flag.channel_stride;

fn at(offset: u32) u32 {
    return ch1 + offset;
}

/// A board with the expander on it, brought up the way a driver would.
fn armed(unit: *riic.Riic, expander: *pi4ioe.Expander) !void {
    try unit.attachDevice(expander.device());
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice);
}

fn start(unit: *riic.Riic) void {
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
}

fn stop(unit: *riic.Riic) void {
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
}

fn address(unit: *riic.Riic, target: u7, reading: bool) void {
    unit.write(at(flag.reg.icdrt), 1, bus.wire.byte(target, reading));
}

test "the window covers three channels and nothing past them" {
    var unit = riic.Riic.init();
    try std.testing.expectEqual(@as(u32, 0x4025_E000), riic.win_base);
    try std.testing.expectEqual(@as(u32, 0x300), riic.win_span);
    try std.testing.expect(unit.quiet());
    const block = unit.block();
    try std.testing.expect(block.covers(riic.win_base));
    try std.testing.expect(!block.covers(riic.win_base + riic.win_span));
}

test "a transfer needs an enabled interface" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try unit.attachDevice(expander.device());
    start(&unit);
    address(&unit, pi4ioe.address, false);
    unit.write(at(flag.reg.icdrt), 1, 0x01);
    stop(&unit);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 0), channel.transfers);
    try std.testing.expect(channel.uninit >= 4);
    try std.testing.expectEqual(@as(u32, 0), expander.writes);
}

test "ICCR1 answers while the interface is disabled, so it can be enabled" {
    var unit = riic.Riic.init();
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice);
    try std.testing.expectEqual(flag.iccr1.ice, unit.read(at(flag.reg.iccr1), 1));
    try std.testing.expectEqual(@as(u32, 0), unit.channels[flag.line_channel].uninit);
}

test "an interface held in IICRST does not move the bus, and says so" {
    var unit = riic.Riic.init();
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice | flag.iccr1.iicrst);
    start(&unit);
    try std.testing.expect(!unit.channels[flag.line_channel].busy);
    // Powered but held: the refusal is IICRST, not a missing ICE, so it is
    // counted apart from the never-enabled case.
    try std.testing.expectEqual(@as(u32, 1), unit.channels[flag.line_channel].held);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[flag.line_channel].uninit);
}

test "a write transaction reaches the device and ends at STOP" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, pi4ioe.address, false);
    unit.write(at(flag.reg.icdrt), 1, 0x03);
    unit.write(at(flag.reg.icdrt), 1, 0x5A);
    stop(&unit);
    try std.testing.expectEqual(@as(u8, 0x5A), expander.registers[0x03]);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.transfers);
    try std.testing.expectEqual(@as(u32, 2), channel.sent);
}

test "BBSY tracks the open transaction and the request bits auto-clear" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.bbsy);
    start(&unit);
    try std.testing.expectEqual(@as(u32, flag.iccr2.bbsy), unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.bbsy);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.st);
    stop(&unit);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.bbsy);
}

test "an address nothing answers is NACKed, which is what a scan reads" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, 0x11, false);
    try std.testing.expectEqual(@as(u32, flag.icsr2.nackf), unit.read(at(flag.reg.icsr2), 1) & flag.icsr2.nackf);
    stop(&unit);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.nacks);
    // A NACKed address closes without counting as a transfer.
    try std.testing.expectEqual(@as(u32, 0), channel.transfers);
}

test "payload after a NACKed address goes nowhere" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, 0x11, false);
    unit.write(at(flag.reg.icdrt), 1, 0x01);
    stop(&unit);
    try std.testing.expectEqual(@as(u32, 0), expander.writes);
}

test "a read serves the device's bytes after the dummy first read" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, pi4ioe.address, false);
    unit.write(at(flag.reg.icdrt), 1, pi4ioe.file.device_id);
    stop(&unit);
    start(&unit);
    address(&unit, pi4ioe.address, true);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.icdrr), 1));
    try std.testing.expectEqual(@as(u32, pi4ioe.file.device_id_value), unit.read(at(flag.reg.icdrr), 1));
    stop(&unit);
}

test "reading past what the device staged is refused, not served as data" {
    var unit = riic.Riic.init();
    var sensor = ov5640.Sensor{};
    try unit.attachDevice(sensor.device());
    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice);
    start(&unit);
    address(&unit, ov5640.address, false);
    unit.write(at(flag.reg.icdrt), 1, 0x30);
    unit.write(at(flag.reg.icdrt), 1, 0x0A);
    stop(&unit);
    start(&unit);
    address(&unit, ov5640.address, true);
    _ = unit.read(at(flag.reg.icdrr), 1);
    try std.testing.expectEqual(@as(u32, 0x56), unit.read(at(flag.reg.icdrr), 1));
    // The sensor had one byte to say. dev kept RDRF up and served zeros.
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.icdrr), 1) & flag.icsr2.rdrf);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.rx.overread);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.icsr2), 1) & flag.icsr2.rdrf);
}

test "a START on a busy bus is refused, not a fresh transfer" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, pi4ioe.address, false);
    start(&unit);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.st_busy);
    // dev tore the open transfer down: the address selection survives here.
    try std.testing.expect(channel.addressed);
    try std.testing.expectEqual(@as(u7, pi4ioe.address), channel.target_7b);
}

test "a repeated START on an idle bus has nothing to repeat" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.rs_idle);
    try std.testing.expect(!channel.busy);
}

test "a repeated START on a busy bus turns the transfer around" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, pi4ioe.address, false);
    unit.write(at(flag.reg.icdrt), 1, pi4ioe.file.device_id);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.rs);
    // The driver waits for RS to read back clear before the address.
    _ = unit.read(at(flag.reg.iccr2), 1);
    address(&unit, pi4ioe.address, true);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 0), channel.rs_idle);
    try std.testing.expectEqual(@as(u32, 0), channel.restart.dropped);
    try std.testing.expect(channel.reading);
}

test "ICDRT with no transaction open begins nothing" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    address(&unit, pi4ioe.address, false);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expectEqual(@as(u32, 1), channel.no_start);
    // dev took the byte as an address phase and selected the expander.
    try std.testing.expect(!channel.addressed);
    try std.testing.expect(!channel.busy);
}

test "a STOP on an idle bus closes nothing" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    stop(&unit);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[flag.line_channel].transfers);
}

test "ICSR2 is write-0-to-clear" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, 0x11, false);
    unit.write(at(flag.reg.icsr2), 1, ~@as(u32, flag.icsr2.nackf));
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(flag.reg.icsr2), 1) & flag.icsr2.nackf);
}

test "the stop callback reaches the device that answered" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, pi4ioe.address, false);
    unit.write(at(flag.reg.icdrt), 1, 0x02);
    unit.write(at(flag.reg.icdrt), 1, 0x77);
    stop(&unit);
    start(&unit);
    address(&unit, pi4ioe.address, false);
    unit.write(at(flag.reg.icdrt), 1, 0x09);
    unit.write(at(flag.reg.icdrt), 1, 0x88);
    stop(&unit);
    try std.testing.expectEqual(@as(u8, 0x77), expander.registers[0x02]);
    try std.testing.expectEqual(@as(u8, 0x88), expander.registers[0x09]);
}

test "an unmodelled register reflects what was written to it" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.write(at(flag.reg.icmr3 + 1), 1, 0x3C);
    try std.testing.expectEqual(@as(u32, 0x3C), unit.read(at(flag.reg.icmr3 + 1), 1));
}

test "the unprotected ICMR3 bits reflect what was written to them" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.wait | flag.icmr3.rdrfs);
    try std.testing.expectEqual(
        @as(u32, flag.icmr3.wait | flag.icmr3.rdrfs),
        unit.read(at(flag.reg.icmr3), 1),
    );
}

test "an offset past the modelled register file answers zero" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.write(at(0x40), 1, 0xAA);
    try std.testing.expectEqual(@as(u32, 0), unit.read(at(0x40), 1));
}

test "the other two channels have nothing on them" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try unit.attachDevice(expander.device());
    unit.write(flag.win_base + flag.reg.iccr1, 1, flag.iccr1.ice);
    unit.write(flag.win_base + flag.reg.iccr2, 1, flag.iccr2.st);
    unit.write(flag.win_base + flag.reg.icdrt, 1, bus.wire.byte(pi4ioe.address, false));
    // One registry, so channel 0 finds the expander too: dev shared its bus
    // the same way, and nothing in this tree gives a per-channel routing.
    try std.testing.expect(unit.channels[0].acked);
    try std.testing.expect(unit.channels[2].quiet());
}

test "ICSER arms the responder and the controller path steps aside" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    unit.write(at(flag.reg.sarl0), 1, bus.wire.byte(0x21, false));
    unit.write(at(flag.reg.icser), 1, flag.icser.sar0e);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expect(channel.target.armed);
    try std.testing.expectEqual(@as(u32, flag.icsr1.aas0), unit.read(at(flag.reg.icsr1), 1));
    try std.testing.expectEqual(@as(u32, bus.wire.byte(0x21, false)), unit.read(at(flag.reg.icdrr), 1));
}

test "disabling the interface drops the transfer it was in the middle of" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    start(&unit);
    address(&unit, pi4ioe.address, false);
    unit.write(at(flag.reg.iccr1), 1, 0);
    const channel = &unit.channels[flag.line_channel];
    try std.testing.expect(!channel.busy);
    try std.testing.expect(!channel.addressed);
}

test "a device may not be attached twice at one address" {
    var unit = riic.Riic.init();
    var first = pi4ioe.Expander{};
    var second = pi4ioe.Expander{};
    try unit.attachDevice(first.device());
    try std.testing.expectError(bus.Error.AddressTaken, unit.attachDevice(second.device()));
}

test {
    _ = @import("sensor_bus_test.zig");
}
