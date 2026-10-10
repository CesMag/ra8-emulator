const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.chip.periph.sci;
const sci_spi = ra8.chip.periph.sci_spi;
const sci_status = ra8.chip.periph.sci_status;

const ccr3_simple_spi: u32 = sci_spi.mod.simple_spi << sci_spi.mod.shift;

fn spiChannel(unit: *sci.Sci, index: u32) void {
    unit.write(sci.win_base + sci.stride * index + sci.off_ccr3, 4, ccr3_simple_spi);
    unit.write(sci.win_base + sci.stride * index + sci.off_ccr0, 4, sci.ccr0.te | sci.ccr0.re);
}

fn send(unit: *sci.Sci, index: u32, byte: u8) void {
    unit.write(sci.win_base + sci.stride * index + sci.off_tdr, 4, byte);
}

fn csr(unit: *sci.Sci, index: u32) u32 {
    return unit.read(sci.win_base + sci.stride * index + sci.off_csr, 4);
}

fn rdr(unit: *sci.Sci, index: u32) u32 {
    return unit.read(sci.win_base + sci.stride * index + sci.off_rdr, 4);
}

test "CCR3 selects Simple-SPI only for MOD 011b" {
    try std.testing.expect(sci_spi.simpleSpi(ccr3_simple_spi));
    try std.testing.expect(!sci_spi.simpleSpi(0));
    // The other CCR3 fields do not change the mode.
    try std.testing.expect(sci_spi.simpleSpi(ccr3_simple_spi | 0x0000_00FF));
    // MOD = 010b is clock-synchronous, not Simple SPI.
    try std.testing.expect(!sci_spi.simpleSpi(0b010 << sci_spi.mod.shift));
}

test "CCR3 reads back what firmware wrote" {
    var unit = sci.Sci.init();
    unit.write(sci.win_base + sci.off_ccr3, 4, ccr3_simple_spi | 0x55);
    try std.testing.expectEqual(ccr3_simple_spi | 0x55, unit.read(sci.win_base + sci.off_ccr3, 4));
}

test "a Simple-SPI frame nothing answered clocks the idle line in" {
    var unit = sci.Sci.init();
    spiChannel(&unit, 0);
    try std.testing.expectEqual(@as(u32, 0), csr(&unit, 0) & sci_status.csr.rdrf);
    send(&unit, 0, 0x40);
    // RDRF is up, and the frame that came back is an idle line: all ones.
    try std.testing.expect(csr(&unit, 0) & sci_status.csr.rdrf != 0);
    try std.testing.expectEqual(@as(u32, sci_spi.idle_byte), rdr(&unit, 0));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].idle_frames);
    // One frame out, one frame in, and the queue is empty again.
    try std.testing.expectEqual(@as(u32, 0), csr(&unit, 0) & sci_status.csr.rdrf);
}

test "every frame of a run clocks one in, so a polled transfer loop finishes" {
    var unit = sci.Sci.init();
    spiChannel(&unit, 0);
    for (0..8) |_| {
        send(&unit, 0, 0xFF);
        try std.testing.expectEqual(@as(u32, sci_spi.idle_byte), rdr(&unit, 0));
    }
    try std.testing.expectEqual(@as(u32, 8), unit.channels[0].idle_frames);
    try std.testing.expectEqual(@as(u32, 8), unit.channels[0].received);
}

test "an asynchronous channel clocks nothing in" {
    var unit = sci.Sci.init();
    unit.write(sci.win_base + sci.off_ccr0, 4, sci.ccr0.te | sci.ccr0.re);
    send(&unit, 0, 0x40);
    try std.testing.expectEqual(@as(u32, 0), csr(&unit, 0) & sci_status.csr.rdrf);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].idle_frames);
}

test "a receiver the firmware never enabled hears no idle frame" {
    var unit = sci.Sci.init();
    unit.write(sci.win_base + sci.off_ccr3, 4, ccr3_simple_spi);
    unit.write(sci.win_base + sci.off_ccr0, 4, sci.ccr0.te);
    send(&unit, 0, 0x40);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].idle_frames);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].unheard);
    try std.testing.expectEqual(@as(u32, 0), rdr(&unit, 0));
}

test "a frame the transmitter never sent clocks nothing in" {
    var unit = sci.Sci.init();
    unit.write(sci.win_base + sci.off_ccr3, 4, ccr3_simple_spi);
    unit.write(sci.win_base + sci.off_ccr0, 4, sci.ccr0.re);
    send(&unit, 0, 0x40);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].unsent);
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].idle_frames);
}

test "a device on the line still owns the answer" {
    var unit = sci.Sci.init();
    spiChannel(&unit, 0);
    var card = Echo{ .reply = 0x01 };
    unit.attachDevice(0, card.device());
    send(&unit, 0, 0x40);
    try std.testing.expectEqual(@as(u32, 0x01), rdr(&unit, 0));
    try std.testing.expectEqual(@as(u32, 0), unit.channels[0].idle_frames);
}

test "a device that answers nothing leaves the idle line to clock in" {
    var unit = sci.Sci.init();
    spiChannel(&unit, 0);
    var quiet = Echo{ .reply = null };
    unit.attachDevice(0, quiet.device());
    send(&unit, 0, 0x40);
    try std.testing.expectEqual(@as(u32, sci_spi.idle_byte), rdr(&unit, 0));
    try std.testing.expectEqual(@as(u32, 1), unit.channels[0].idle_frames);
}

/// A stand-in for something on the line: answers one byte, or nothing.
const Echo = struct {
    reply: ?u8,
    held: [1]u8 = undefined,

    fn device(self: *Echo) sci.Device {
        return .{ .context = self, .feedFn = feed };
    }

    fn feed(context: *anyopaque, _: u8) []const u8 {
        const self: *Echo = @ptrCast(@alignCast(context));
        const byte = self.reply orelse return &.{};
        self.held[0] = byte;
        return self.held[0..1];
    }
};
