const std = @import("std");
const ra8 = @import("ra8");
const sd_card = ra8.components.sd_card;
const sd_line = ra8.components.sd_card.line;
const sci = ra8.chip.periph.sci;
const sci_spi = ra8.chip.periph.sci.spi;

/// CCR3 with MOD set to Simple-SPI, the way ra8_sci_spi_init writes it.
const simple_spi_ccr3: u32 = sci_spi.mod.simple_spi << sci_spi.mod.shift;

test "the card is on Pmod2, which is SCI0" {
    try std.testing.expectEqual(@as(usize, 0), sd_line.line_channel);
}

test "one byte in, the card's one byte back" {
    var card = sd_card.Card.init(std.testing.allocator);
    defer card.deinit();
    var line = sd_line.Line.init(&card);

    const reply = line.feed(0xFF);
    try std.testing.expectEqual(@as(usize, 1), reply.len);
    try std.testing.expectEqual(@as(u8, 0xFF), reply[0]);
}

test "the answer survives until the next byte is clocked" {
    var card = sd_card.Card.init(std.testing.allocator);
    defer card.deinit();
    var line = sd_line.Line.init(&card);

    const first = line.feed(0xFF);
    try std.testing.expectEqual(@as(u8, 0xFF), first[0]);
    _ = line.feed(0xFF);
    try std.testing.expectEqual(@as(usize, 1), first.len);
}

test "the card is on the channel's SPI pins, so it is spi_only" {
    var card = sd_card.Card.init(std.testing.allocator);
    defer card.deinit();
    var line = sd_line.Line.init(&card);
    try std.testing.expect(line.device().spi_only);
}

test "a CMD0 frame clocked through the line is answered as a command" {
    var card = sd_card.Card.init(std.testing.allocator);
    defer card.deinit();
    var line = sd_line.Line.init(&card);

    for (cmd0) |byte| _ = line.feed(byte);
    try std.testing.expect(!card.quiet());
}

/// CMD0, as ra8_sdmmc_spi clocks it: the command byte, four argument bytes
/// and the CRC7 with its stop bit.
const cmd0 = [_]u8{ 0x40, 0x00, 0x00, 0x00, 0x00, 0x95 };

fn clockFrame(block: *sci.Sci) void {
    const window = sci.win_base + sci.stride * sd_line.line_channel;
    for (cmd0) |byte| block.write(window + sci.off_tdr, 4, byte);
}

test "a channel running as a UART does not reach the card" {
    var block = sci.Sci{};
    var card = sd_card.Card.init(std.testing.allocator);
    defer card.deinit();
    var line = sd_line.Line.init(&card);
    block.attachDevice(sd_line.line_channel, line.device());

    const window = sci.win_base + sci.stride * sd_line.line_channel;
    block.write(window + sci.off_ccr0, 4, sci.ccr0.te | sci.ccr0.re);
    clockFrame(&block);
    try std.testing.expect(card.quiet());
}

test "the same frame in Simple-SPI mode does reach the card" {
    var block = sci.Sci{};
    var card = sd_card.Card.init(std.testing.allocator);
    defer card.deinit();
    var line = sd_line.Line.init(&card);
    block.attachDevice(sd_line.line_channel, line.device());

    const window = sci.win_base + sci.stride * sd_line.line_channel;
    block.write(window + sci.off_ccr3, 4, simple_spi_ccr3);
    block.write(window + sci.off_ccr0, 4, sci.ccr0.te | sci.ccr0.re);
    clockFrame(&block);
    try std.testing.expect(!card.quiet());
}
