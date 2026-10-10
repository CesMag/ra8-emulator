//! Covers src/chip/periph/riic/rx.zig: the dummy read that starts the clock, the
//! bytes served after it, and the reads past the end of what was staged.
const std = @import("std");
const ra8 = @import("ra8");
const rx = ra8.chip.periph.riic_rx;
const flag = ra8.chip.periph.riic_flags;

test "a fresh path holds nothing and is quiet" {
    var path = rx.Rx{};
    try std.testing.expect(!path.holding());
    try std.testing.expect(path.quiet());
}

test "the first access is the dummy read that starts the clock" {
    var path = rx.Rx{};
    path.staged[0] = 0xA5;
    path.stage(1, 0);

    var status: u8 = flag.icsr2.rdrf;
    try std.testing.expectEqual(@as(?u8, null), path.take(&status));
    try std.testing.expect(path.holding());
    try std.testing.expectEqual(@as(?u8, 0xA5), path.take(&status));
}

test "RDRF stands while a byte is waiting and goes away with the last" {
    var path = rx.Rx{};
    path.staged[0] = 1;
    path.staged[1] = 2;
    path.stage(2, 0);

    var status: u8 = 0;
    _ = path.take(&status);
    _ = path.take(&status);
    try std.testing.expectEqual(flag.icsr2.rdrf, status & flag.icsr2.rdrf);
    _ = path.take(&status);
    try std.testing.expectEqual(@as(u8, 0), status & flag.icsr2.rdrf);
    try std.testing.expect(!path.holding());
}

test "a read past the end answers nothing and is counted" {
    var path = rx.Rx{};
    path.staged[0] = 7;
    path.stage(1, 0);

    var status: u8 = 0;
    _ = path.take(&status);
    _ = path.take(&status);
    try std.testing.expectEqual(@as(?u8, null), path.take(&status));
    try std.testing.expectEqual(@as(u32, 1), path.overread);
    try std.testing.expect(!path.quiet());
}

test "opening a frame empties the path and arms the dummy read again" {
    var path = rx.Rx{};
    path.staged[0] = 9;
    path.stage(1, 0);
    var status: u8 = 0;
    _ = path.take(&status);
    _ = path.take(&status);

    path.open();
    try std.testing.expect(!path.holding());
    try std.testing.expectEqual(@as(?u8, null), path.take(&status));
}

test "an empty answer holds nothing at all" {
    var path = rx.Rx{};
    path.stage(0, 0);
    try std.testing.expect(!path.holding());
}

test "a stretched byte raises RDRF at its virtual deadline and not before" {
    var clock = ra8.chip.periph.clocks.timebase.TimeBase{};
    var path = rx.Rx{ .clock = &clock };
    path.staged[0] = 0x11;
    path.staged[1] = 0x22;
    path.stage(2, 500);
    const status: u8 = flag.icsr2.rdrf;
    try std.testing.expectEqual(@as(u8, 0), path.visible(status) & flag.icsr2.rdrf);
    clock.advance(499);
    try std.testing.expect(!path.landed());
    clock.advance(1);
    try std.testing.expectEqual(flag.icsr2.rdrf, path.visible(status) & flag.icsr2.rdrf);
}

test "each byte of a stretched read waits its own stretch" {
    var clock = ra8.chip.periph.clocks.timebase.TimeBase{};
    var path = rx.Rx{ .clock = &clock };
    path.staged[0] = 0x11;
    path.staged[1] = 0x22;
    path.stage(2, 100);
    var status: u8 = flag.icsr2.rdrf;
    try std.testing.expectEqual(@as(?u8, null), path.take(&status)); // dummy read
    clock.advance(100);
    try std.testing.expectEqual(@as(?u8, 0x11), path.take(&status));
    try std.testing.expect(!path.landed());
    try std.testing.expectEqual(@as(u8, 0), path.visible(status) & flag.icsr2.rdrf);
    clock.advance(100);
    try std.testing.expectEqual(@as(?u8, 0x22), path.take(&status));
    try std.testing.expect(path.quiet());
}

test "reading ICDRR before the stretched byte lands keeps it and counts" {
    var clock = ra8.chip.periph.clocks.timebase.TimeBase{};
    var path = rx.Rx{ .clock = &clock };
    path.staged[0] = 0x5A;
    path.stage(1, 200);
    var status: u8 = flag.icsr2.rdrf;
    _ = path.take(&status); // dummy read
    try std.testing.expectEqual(@as(?u8, null), path.take(&status));
    try std.testing.expectEqual(@as(u32, 1), path.early);
    try std.testing.expect(!path.quiet());
    clock.advance(200);
    try std.testing.expectEqual(@as(?u8, 0x5A), path.take(&status));
}

test "without a clock a stretch never waits" {
    var path = rx.Rx{};
    path.staged[0] = 0x01;
    path.stage(1, 1_000_000);
    try std.testing.expectEqual(flag.icsr2.rdrf, path.visible(flag.icsr2.rdrf));
}
