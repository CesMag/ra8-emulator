//! Drives the ESP32-C6 link through SCI2 Simple-SPI, the way firmware does.
const std = @import("std");
const ra8 = @import("ra8");
const c6 = ra8.components.esp_hosted;
const frame = c6.frame;
const gpio = ra8.chip.periph.gpio;
const sci = ra8.chip.periph.sci;
const sci_spi = ra8.chip.periph.sci.spi;

const caps = [_]u8{ 0x22, 15, 0x44, 1, 0, 0x45, 1, 0x0D, 0x46, 1, 0, 0x47, 1, 80, 0x48, 1, 60 };

fn spiMode(serial: *sci.Sci) void {
    serial.write(sci.regAddress(c6.channel, sci.off_ccr3), 4, sci_spi.mod.simple_spi << sci_spi.mod.shift);
    serial.write(sci.regAddress(c6.channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
}

fn transfer(serial: *sci.Sci, sent: *const [frame.frame_size]u8, got: *[frame.frame_size]u8) void {
    for (sent, got) |byte, *out| {
        serial.write(sci.regAddress(c6.channel, sci.off_tdr), 4, byte);
        out.* = @truncate(serial.read(sci.regAddress(c6.channel, sci.off_rdr), 4));
    }
}

test "caps frame over SCI2 brings back Event_ESPInit with a valid checksum" {
    var serial = sci.Sci.init();
    var pins = gpio.Gpio.init();
    var peer = c6.C6{};
    peer.init(&serial, &pins);
    spiMode(&serial);

    var sent: [frame.frame_size]u8 = undefined;
    var got: [frame.frame_size]u8 = undefined;
    try frame.build(&sent, .{ .interface = .priv }, &caps);
    transfer(&serial, &sent, &got);
    try std.testing.expect((try frame.parse(&got)).header.isFiller());
    try std.testing.expect(pins.pinLevel(c6.data_ready_port, c6.data_ready_pin));

    frame.filler(&sent);
    transfer(&serial, &sent, &got);
    const reply = try frame.parse(&got);
    try std.testing.expectEqual(frame.Interface.serial, reply.header.interface);
    try std.testing.expectEqual(frame.checksum(got[0 .. frame.header_size + reply.header.len]), reply.header.checksum);
    try std.testing.expectEqualSlices(u8, "RPCEvt", reply.payload[3..9]);
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x03, 0x10, 0x81, 0x06, 0x8A, 0x30, 0x00 }, reply.payload[12..]);
    try std.testing.expect(!pins.pinLevel(c6.data_ready_port, c6.data_ready_pin));
}
