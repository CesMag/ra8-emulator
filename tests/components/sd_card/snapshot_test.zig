//! Covers src/components/sd_card/snapshot.zig (RA8EMU-1104): each SD
//! card's half of the `sd` section reads back into a fresh card holding the
//! same blocks, nothing changes before `install`, the SD-bus card keeps its
//! historical field order, and a block past the card's end is refused.
const std = @import("std");
const ra8 = @import("ra8");
const cards = ra8.components.sd_card.snapshot;
const fields = ra8.snapshot.fields;
const SpiCard = ra8.components.sd_card.Card;
const bus_card = ra8.components.sd_card.bus_card;
const BusCard = bus_card.Card;
const allocator = std.testing.allocator;

fn filled(byte: u8) [512]u8 {
    return @splat(byte);
}

fn busySpi() !SpiCard {
    var card = SpiCard.init(allocator);
    errdefer card.deinit();
    try std.testing.expect(card.img.write(7, &filled(0xA5)));
    try std.testing.expect(card.img.write(2, &filled(0x3C)));
    card.ready = true;
    card.commands = 12;
    return card;
}

test "the SPI card's half reads back into a fresh card with its blocks" {
    var card = try busySpi();
    defer card.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try cards.writeSpi(&out.writer, &card);

    var fresh = SpiCard.init(allocator);
    defer fresh.deinit();
    try std.testing.expect(fresh.img.write(9, &filled(1)));
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    var staged = try cards.readSpi(&cursor, &fresh);
    try std.testing.expect(cursor.done());
    try std.testing.expect(cards.spiFits(&staged.card));
    try std.testing.expectEqual(@as(u32, 0), fresh.commands);
    try std.testing.expectEqual(@as(usize, 1), fresh.img.held());

    staged.install(&fresh, try staged.build());
    try std.testing.expectEqual(@as(u32, 12), fresh.commands);
    try std.testing.expect(fresh.ready);
    try std.testing.expectEqual(@as(usize, 2), fresh.img.held());
    var block: [512]u8 = undefined;
    try std.testing.expect(fresh.img.read(7, &block));
    try std.testing.expectEqual(@as(u8, 0xA5), block[511]);
    var again = std.Io.Writer.Allocating.init(allocator);
    defer again.deinit();
    try cards.writeSpi(&again.writer, &fresh);
    try std.testing.expectEqualSlices(u8, out.written(), again.written());
}

test "the SD-bus card goes as state, capacity, past_end, then its blocks" {
    var card = BusCard.init(allocator);
    defer card.deinit();
    card.state = .tran;
    card.past_end = 0x0102_0304;
    try std.testing.expect(card.write(40, &filled(0x77)));
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try cards.writeBus(&out.writer, &card);
    const bytes = out.written();
    try std.testing.expectEqual(@as(usize, 1 + 4 + 4 + 4 + 4 + 512), bytes.len);
    try std.testing.expectEqual(@as(u8, @backingInt(bus_card.State.tran)), bytes[0]);
    try std.testing.expectEqual(card.img.capacity_blocks, std.mem.readInt(u32, bytes[1..5], .little));
    try std.testing.expectEqual(@as(u32, 0x0102_0304), std.mem.readInt(u32, bytes[5..9], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[9..13], .little));
    try std.testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, bytes[13..17], .little));
    try std.testing.expectEqual(@as(u8, 0x77), bytes[17]);

    var fresh = BusCard.init(allocator);
    defer fresh.deinit();
    var cursor: fields.Cursor = .{ .bytes = bytes };
    var staged = try cards.readBus(&cursor, &fresh);
    try std.testing.expect(cursor.done());
    try std.testing.expectEqual(bus_card.State.idle, fresh.state);
    staged.install(&fresh, try staged.build());
    try std.testing.expectEqual(bus_card.State.tran, fresh.state);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), fresh.past_end);
    try std.testing.expectEqual(@as(u32, 1), fresh.held());
}

test "a block past the card's end or out of order is refused before anything is built" {
    var card = try busySpi();
    defer card.deinit();
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try cards.writeSpi(&out.writer, &card);
    const bytes = out.written();
    // Blocks are written 2 then 7. Renumber the first past the second, then
    // past the card's end.
    const first = std.mem.indexOf(u8, bytes, &[_]u8{ 2, 0, 0, 0 } ++ @as([4]u8, @splat(0x3C))).?;
    var fresh = SpiCard.init(allocator);
    defer fresh.deinit();
    for ([_]u32{ 9, 0xFFFF_FFF0 }) |number| {
        std.mem.writeInt(u32, bytes[first..][0..4], number, .little);
        var cursor: fields.Cursor = .{ .bytes = bytes };
        try std.testing.expectError(error.BadValue, cards.readSpi(&cursor, &fresh));
    }
    try std.testing.expectEqual(@as(usize, 0), fresh.img.held());
}

test "a command or reply index outside its buffer does not fit" {
    var card = SpiCard.init(allocator);
    defer card.deinit();
    try std.testing.expect(cards.spiFits(&card));
    card.cmd_len = card.cmd.len + 1;
    try std.testing.expect(!cards.spiFits(&card));
    card.cmd_len = 0;
    card.reply.len = 2;
    card.reply.pos = 3;
    try std.testing.expect(!cards.spiFits(&card));
}
