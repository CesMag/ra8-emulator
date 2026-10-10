const std = @import("std");
const ra8 = @import("ra8");
const sci_device = ra8.chip.periph.sci_device;

const Answering = struct {
    last: u8 = 0,
    answer: [1]u8 = .{0},

    fn feed(self: *Answering, byte: u8) []const u8 {
        self.last = byte;
        self.answer[0] = byte ^ 0xFF;
        return self.answer[0..1];
    }

    fn thunk(context: *anyopaque, byte: u8) []const u8 {
        const self: *Answering = @ptrCast(@alignCast(context));
        return self.feed(byte);
    }

    fn device(self: *Answering, spi_only: bool) sci_device.Device {
        return .{ .context = self, .feedFn = thunk, .spi_only = spi_only };
    }
};

test "a device is handed the byte and answers with what it drove back" {
    var listener = Answering{};
    const on_line = listener.device(false);
    const reply = on_line.feed(0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), listener.last);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqual(@as(u8, 0xA5), reply[0]);
}

test "a UART device leaves spi_only false" {
    var listener = Answering{};
    try std.testing.expect(!listener.device(false).spi_only);
}

test "a device wired to the SPI pins says so" {
    var listener = Answering{};
    try std.testing.expect(listener.device(true).spi_only);
}
