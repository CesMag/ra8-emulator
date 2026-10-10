//! Covers src/chip/periph/riic/stop.zig: a STOP asked for mid-frame waits for the
//! last byte and the WAIT clear before it fires.
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

fn address(unit: *riic.Riic, reading: bool) void {
    unit.write(at(flag.reg.icdrt), 1, bus.wire.byte(pi4ioe.address, reading));
}

/// Address the expander for a read and take the dummy byte that starts the
/// clock, leaving the frame holding what it staged.
fn openRead(unit: *riic.Riic) void {
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
    address(unit, true);
    _ = unit.read(at(flag.reg.icdrr), 1);
}

fn drain(unit: *riic.Riic) void {
    while (unit.channels[flag.line_channel].rx.holding()) {
        _ = unit.read(at(flag.reg.icdrr), 1);
    }
}

fn busy(unit: *riic.Riic) bool {
    return unit.read(at(flag.reg.iccr2), 1) & flag.iccr2.bbsy != 0;
}

fn channel(unit: *riic.Riic) *riic.Channel {
    return &unit.channels[flag.line_channel];
}

test "a stop asked for with the frame still holding a byte does not fire" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    openRead(&unit);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    try std.testing.expect(busy(&unit));
    try std.testing.expect(channel(&unit).stop.pending);
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).stop.deferred);
    try std.testing.expectEqual(@as(u32, 0), channel(&unit).transfers);
}

test "the last byte of the frame lets the requested stop fire" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    openRead(&unit);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    drain(&unit);

    try std.testing.expect(!busy(&unit));
    try std.testing.expect(!channel(&unit).stop.pending);
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).transfers);
}

test "WAIT holds the condition after the last byte is taken" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    openRead(&unit);

    unit.write(at(flag.reg.icmr3), 1, flag.icmr3.wait);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    drain(&unit);
    try std.testing.expect(busy(&unit));

    // The driver drops WAIT and ACKBT together at the end of the frame.
    unit.write(at(flag.reg.icmr3), 1, 0);
    try std.testing.expect(!busy(&unit));
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).transfers);
}

test "a stop with nothing holding it still fires at once" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.st);
    address(&unit, false);
    unit.write(at(flag.reg.icdrt), 1, 0x00);
    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);

    try std.testing.expect(!busy(&unit));
    try std.testing.expectEqual(@as(u32, 0), channel(&unit).stop.deferred);
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).transfers);
}

test "the transfer is counted after the one requested byte, not the request" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    openRead(&unit);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    _ = unit.read(at(flag.reg.icdrr), 1);
    // STOP limits the response to the current byte, which closes the frame.
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).received);
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).transfers);

    drain(&unit);
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).transfers);
}

test "a stop asked for on an idle channel is not deferred" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    try std.testing.expectEqual(@as(u32, 0), channel(&unit).stop.deferred);
    try std.testing.expect(!channel(&unit).stop.pending);
}

test "a reset drops a condition that never fired" {
    var unit = riic.Riic.init();
    var expander = pi4ioe.Expander{};
    try armed(&unit, &expander);
    openRead(&unit);

    unit.write(at(flag.reg.iccr2), 1, flag.iccr2.sp);
    try std.testing.expect(channel(&unit).stop.pending);

    unit.write(at(flag.reg.iccr1), 1, flag.iccr1.ice | flag.iccr1.iicrst);
    try std.testing.expect(!channel(&unit).stop.pending);
    // The count is the run's record and stays.
    try std.testing.expectEqual(@as(u32, 1), channel(&unit).stop.deferred);
}
