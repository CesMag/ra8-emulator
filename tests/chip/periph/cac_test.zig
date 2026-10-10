//! Covers src/chip/periph/cac.zig: the measurement ends, the flags are sticky, and
//! the window registers answer a byte at a time.
const std = @import("std");
const ra8 = @import("ra8");

const cac = ra8.chip.periph.cac;
const periph = ra8.chip.periph.registry;

fn unit() cac.Cac {
    return cac.Cac.init();
}

/// Program a window the way a driver does, then start the measurement.
fn runOnce(unit_ptr: *cac.Cac, lower: u16, upper: u16) void {
    unit_ptr.write(cac.regAddress(cac.off_callvr), 2, lower);
    unit_ptr.write(cac.regAddress(cac.off_caulvr), 2, upper);
    unit_ptr.write(cac.regAddress(cac.off_cacr0), 1, cac.cfme);
}

test "a measurement ends and lands inside the programmed window" {
    var u = unit();
    try std.testing.expect(u.quiet());
    runOnce(&u, 1000, 1100);

    try std.testing.expect(u.flagSet(cac.status.mendf));
    try std.testing.expect(!u.flagSet(cac.status.ferrf));
    const count = u.read(cac.regAddress(cac.off_cacntbr), 2);
    try std.testing.expectEqual(@as(u32, 1050), count);
    try std.testing.expect(count >= 1000 and count <= 1100);
    try std.testing.expect(!u.quiet());
    try std.testing.expectEqual(@as(u32, 1), u.measurements);
}

test "CASTR is read-only, and a flag survives a write to it" {
    var u = unit();
    runOnce(&u, 10, 20);
    u.write(cac.regAddress(cac.off_castr), 1, 0);
    try std.testing.expect(u.flagSet(cac.status.mendf));
    try std.testing.expectEqual(
        @as(u32, cac.status.mendf),
        u.read(cac.regAddress(cac.off_castr), 1),
    );
}

test "CAICR clears the flag it names and leaves the others alone" {
    var u = unit();
    runOnce(&u, 500, 100); // Upside down: FERRF as well as MENDF.
    try std.testing.expect(u.flagSet(cac.status.ferrf));
    try std.testing.expect(u.flagSet(cac.status.mendf));

    u.write(cac.regAddress(cac.off_caicr), 1, cac.clear.mendfcl);
    try std.testing.expect(!u.flagSet(cac.status.mendf));
    try std.testing.expect(u.flagSet(cac.status.ferrf));

    u.write(cac.regAddress(cac.off_caicr), 1, cac.clear.ferrfcl);
    try std.testing.expectEqual(@as(u32, 0), u.read(cac.regAddress(cac.off_castr), 1));
}

test "an upside-down window reports a frequency error, not a pass" {
    var u = unit();
    runOnce(&u, 0x8000, 0x0100);
    try std.testing.expect(u.flagSet(cac.status.ferrf));
    try std.testing.expectEqual(
        @as(u32, 0x0100),
        u.read(cac.regAddress(cac.off_cacntbr), 2),
    );
}

test "a second measurement does not clear a flag the driver never cleared" {
    var u = unit();
    runOnce(&u, 400, 100); // FERRF latches here.
    u.write(cac.regAddress(cac.off_cacr0), 1, 0); // CFME low: the unit stops.
    runOnce(&u, 100, 400); // A good window this time.

    try std.testing.expect(u.flagSet(cac.status.mendf));
    try std.testing.expect(u.flagSet(cac.status.ferrf));
    try std.testing.expectEqual(@as(u32, 2), u.measurements);
}

test "CFME held high does not restart the measurement" {
    var u = unit();
    runOnce(&u, 100, 200);
    u.write(cac.regAddress(cac.off_cacr0), 1, cac.cfme);
    try std.testing.expectEqual(@as(u32, 1), u.measurements);
}

test "the clear strobes read back as zero, the enables read back" {
    var u = unit();
    u.write(cac.regAddress(cac.off_caicr), 1, cac.clear.all | 0x03);
    try std.testing.expectEqual(@as(u32, 0x03), u.read(cac.regAddress(cac.off_caicr), 1));
}

test "the control shadows read back what was written" {
    var u = unit();
    u.write(cac.regAddress(cac.off_cacr1), 1, 0x5A);
    u.write(cac.regAddress(cac.off_cacr2), 1, 0xA5);
    try std.testing.expectEqual(@as(u32, 0x5A), u.read(cac.regAddress(cac.off_cacr1), 1));
    try std.testing.expectEqual(@as(u32, 0xA5), u.read(cac.regAddress(cac.off_cacr2), 1));
}

test "a byte-wide driver reaches both halves of the window registers" {
    var u = unit();
    u.write(cac.regAddress(cac.off_caulvr), 1, 0x34);
    u.write(cac.regAddress(cac.off_caulvr + 1), 1, 0x12);
    try std.testing.expectEqual(@as(u32, 0x1234), u.read(cac.regAddress(cac.off_caulvr), 2));
    try std.testing.expectEqual(@as(u32, 0x12), u.read(cac.regAddress(cac.off_caulvr + 1), 1));
}

test "the block answers through the bus in both security windows" {
    var u = unit();
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    try bus.add(u.block());

    bus.write(cac.regAddress(cac.off_callvr), 2, 2000);
    bus.write(cac.regAddress(cac.off_caulvr), 2, 3000);
    bus.write(cac.regAddress(cac.off_cacr0), 1, cac.cfme);
    try std.testing.expectEqual(@as(u32, 2500), bus.read(cac.regAddress(cac.off_cacntbr), 2));
    try std.testing.expectEqual(
        @as(u32, cac.status.mendf),
        bus.read(cac.regAddress(cac.off_castr), 1),
    );
}

test "programming the window with the measurement stopped is not counted hot" {
    var u = unit();
    u.write(cac.regAddress(cac.off_cacr1), 1, 0x01);
    u.write(cac.regAddress(cac.off_cacr2), 1, 0x02);
    u.write(cac.regAddress(cac.off_callvr), 2, 1000);
    u.write(cac.regAddress(cac.off_caulvr), 2, 1100);
    try std.testing.expectEqual(@as(u32, 0), u.hot_config);
    try std.testing.expect(u.quiet());
}

test "a clock select moved with CFME set is counted" {
    var u = unit();
    runOnce(&u, 1000, 1100);
    try std.testing.expect(u.measuring());
    u.write(cac.regAddress(cac.off_cacr2), 1, 0x02);
    try std.testing.expectEqual(@as(u32, 1), u.hot_config);
}

test "a window limit moved with CFME set is counted, and still lands" {
    var u = unit();
    runOnce(&u, 1000, 1100);
    u.write(cac.regAddress(cac.off_caulvr), 2, 2000);
    try std.testing.expectEqual(@as(u32, 1), u.hot_config);
    try std.testing.expectEqual(
        @as(u32, 2000),
        u.read(cac.regAddress(cac.off_caulvr), 2),
    );
}

test "every byte of a hot halfword store is counted" {
    var u = unit();
    runOnce(&u, 1000, 1100);
    u.write(cac.regAddress(cac.off_callvr), 1, 0x10);
    u.write(cac.regAddress(cac.off_callvr + 1), 1, 0x20);
    try std.testing.expectEqual(@as(u32, 2), u.hot_config);
}

test "CACR0 and CAICR are outside the rule" {
    var u = unit();
    runOnce(&u, 1000, 1100);
    u.write(cac.regAddress(cac.off_caicr), 1, cac.clear.mendfcl);
    u.write(cac.regAddress(cac.off_cacr0), 1, 0);
    try std.testing.expectEqual(@as(u32, 0), u.hot_config);
    try std.testing.expect(!u.measuring());
}

test "stopping the measurement reopens the window to configuration" {
    var u = unit();
    runOnce(&u, 1000, 1100);
    u.write(cac.regAddress(cac.off_cacr0), 1, 0);
    u.write(cac.regAddress(cac.off_cacr1), 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0), u.hot_config);
}

test "a hot store alone is enough to earn a report line" {
    var u = unit();
    u.write(cac.regAddress(cac.off_cacr0), 1, cac.cfme);
    u.write(cac.regAddress(cac.off_cacr1), 1, 0x01);
    try std.testing.expect(!u.quiet());
}
