//! Covers src/components/fault_lines.zig on the e-ink panel (SPI) and the
//! AT modem (UART).
const std = @import("std");
const ra8 = @import("ra8");
const lines = ra8.components.model.fault.lines;
const eink = ra8.components.eink;
const modem = ra8.components.modem_at;

/// Clock "AT\r" through a UART device and return the reply to the CR.
fn sayAt(device: anytype) []const u8 {
    _ = device.feed('A');
    _ = device.feed('T');
    return device.feed('\r');
}

test "with no fault the panel and the modem answer as themselves" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    var spi_fault = lines.Spi.wrap(panel.device());
    var plain = eink.Panel.init();
    defer plain.deinit();
    try std.testing.expectEqual(plain.exchange(0x00), spi_fault.device().exchange(0x00));
    var unit = modem.Modem{};
    var uart = lines.Uart.wrap(unit.device());
    try std.testing.expectEqualStrings("\r\nOK\r\n", sayAt(uart.device()));
}

test "a disconnected panel reads back a floating line and hears nothing" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    var spi_fault = lines.Spi.wrap(panel.device());
    spi_fault.set(.disconnected);
    const device = spi_fault.device();
    for (0..4) |_| try std.testing.expectEqual(lines.floating, device.exchange(0x12));
    try std.testing.expect(panel.high == null);
}

test "a disconnected modem goes silent and hears nothing" {
    var unit = modem.Modem{};
    var uart = lines.Uart.wrap(unit.device());
    uart.set(.disconnected);
    try std.testing.expectEqual(@as(usize, 0), sayAt(uart.device()).len);
    try std.testing.expect(unit.quiet());
}

test "a stuck line reads back one value, and the part still hears" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    var spi_fault = lines.Spi.wrap(panel.device());
    spi_fault.set(.{ .stuck = 0x5A });
    try std.testing.expectEqual(@as(u8, 0x5A), spi_fault.device().exchange(0x12));
    try std.testing.expectEqual(@as(?u8, 0x12), panel.high);
    var unit = modem.Modem{};
    var uart = lines.Uart.wrap(unit.device());
    uart.set(.{ .stuck = '#' });
    try std.testing.expectEqualStrings("######", sayAt(uart.device()));
    try std.testing.expectEqual(@as(u32, 1), unit.answered);
}

test "garbage is the same noise for the same seed, on both lines" {
    var first = modem.Modem{};
    var a = lines.Uart.wrap(first.device());
    a.set(.{ .garbage = 9 });
    var second = modem.Modem{};
    var b = lines.Uart.wrap(second.device());
    b.set(.{ .garbage = 9 });
    const noise = sayAt(a.device());
    try std.testing.expectEqualSlices(u8, noise, sayAt(b.device()));
    try std.testing.expect(!std.mem.eql(u8, noise, "\r\nOK\r\n"));
    var p1 = eink.Panel.init();
    defer p1.deinit();
    var s1 = lines.Spi.wrap(p1.device());
    s1.set(.{ .garbage = 9 });
    var p2 = eink.Panel.init();
    defer p2.deinit();
    var s2 = lines.Spi.wrap(p2.device());
    s2.set(.{ .garbage = 9 });
    for (0..8) |_| try std.testing.expectEqual(s1.device().exchange(0), s2.device().exchange(0));
}

test "a UART wrapper keeps the part's wiring" {
    var unit = modem.Modem{};
    var uart = lines.Uart.wrap(unit.device());
    try std.testing.expect(!uart.device().spi_only);
}
