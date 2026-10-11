//! Covers src/components/sd_card/card/card.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sd_card = ra8.components.sd_card;
const sd_crc = ra8.components.sd_card.crc;
const sd_write = ra8.components.sd_card.write;
const image = ra8.components.sd_card.image;

const block_bytes = image.geometry.block_bytes;

fn unit() sd_card.Card {
    return sd_card.Card.init(std.testing.allocator);
}

/// Clock a six-byte command frame and hand back the first reply byte, which
/// is R1 for everything that answers with one.
fn command(card: *sd_card.Card, index: u8, arg: u32) u8 {
    var frame: [6]u8 = @splat(0);
    frame[0] = sd_card.frame.start_bits | index;
    std.mem.writeInt(u32, frame[1..5], arg, .big);
    frame[5] = 0x01;
    for (frame) |byte| _ = card.exchange(byte);
    return card.exchange(sd_card.token.idle);
}

/// Take the rest of a staged reply, the way a driver reads a whole response
/// before sending the next command.
fn drain(card: *sd_card.Card, count: usize) void {
    var index: usize = 0;
    while (index < count) : (index += 1) _ = card.exchange(sd_card.token.idle);
}

/// The bring-up the driver does: idle, interface condition, then CMD55 and
/// ACMD41 until the card says it is ready.
fn bringUp(card: *sd_card.Card) !void {
    try std.testing.expectEqual(sd_card.r1.idle, command(card, 0, 0));
    try std.testing.expectEqual(sd_card.r1.idle, command(card, 8, 0x1AA));
    drain(card, 4);
    try std.testing.expectEqual(sd_card.r1.idle, command(card, 55, 0));
    try std.testing.expectEqual(sd_card.r1.ready, command(card, 41, 0));
    try std.testing.expect(card.ready);
}

/// Drain a staged block reply: the data token, the payload, and the CRC.
fn takeBlock(card: *sd_card.Card, payload: []u8) !void {
    try std.testing.expectEqual(sd_card.token.data, card.exchange(sd_card.token.idle));
    for (payload) |*slot| slot.* = card.exchange(sd_card.token.idle);
    const high = card.exchange(sd_card.token.idle);
    const low = card.exchange(sd_card.token.idle);
    const sent = (@as(u16, high) << 8) | low;
    try std.testing.expectEqual(sd_crc.crc16(payload), sent);
}

/// Send a block down the write path: token, payload, checksum.
fn sendBlock(card: *sd_card.Card, fill: u8, crc: u16) u8 {
    _ = card.exchange(sd_write.host_token.data);
    var index: usize = 0;
    while (index < block_bytes) : (index += 1) _ = card.exchange(fill);
    _ = card.exchange(@intCast(crc >> 8));
    _ = card.exchange(@intCast(crc & 0xFF));
    return card.exchange(sd_card.token.idle);
}

test "a card nobody has talked to is quiet" {
    var card = unit();
    defer card.deinit();
    try std.testing.expect(card.quiet());
    try std.testing.expectEqual(sd_card.token.idle, card.exchange(sd_card.token.idle));
}

test "the bring-up sequence takes the card out of idle" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expect(!card.quiet());
}

test "CMD8 echoes the check pattern back" {
    var card = unit();
    defer card.deinit();
    try std.testing.expectEqual(sd_card.r1.idle, command(&card, 8, 0x1AA));
    try std.testing.expectEqual(@as(u8, 0), card.exchange(sd_card.token.idle));
    try std.testing.expectEqual(@as(u8, 0), card.exchange(sd_card.token.idle));
    try std.testing.expectEqual(@as(u8, 1), card.exchange(sd_card.token.idle));
    try std.testing.expectEqual(@as(u8, 0xAA), card.exchange(sd_card.token.idle));
}

test "CMD58 reports a high-capacity card once it is up" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 58, 0));
    try std.testing.expectEqual(@as(u8, 0xC0), card.exchange(sd_card.token.idle));
    drain(&card, 3);
}

test "ACMD41 without the CMD55 ahead of it does not bring the card up" {
    var card = unit();
    defer card.deinit();
    try std.testing.expectEqual(sd_card.r1.idle, command(&card, 41, 0));
    try std.testing.expect(!card.ready);
}

test "a read before the card is up is refused, which dev serves" {
    var card = unit();
    defer card.deinit();
    try std.testing.expectEqual(sd_card.r1.idle, command(&card, 17, 0));
    try std.testing.expectEqual(sd_card.token.idle, card.exchange(sd_card.token.idle));
    try std.testing.expectEqual(@as(u32, 1), card.uninit);
    try std.testing.expectEqual(@as(u32, 0), card.reads);
}

test "a write before the card is up is refused too" {
    var card = unit();
    defer card.deinit();
    try std.testing.expectEqual(sd_card.r1.idle, command(&card, 24, 0));
    try std.testing.expectEqual(@as(u32, 1), card.uninit);
    try std.testing.expect(!card.write.active());
}

test "CMD17 hands over a block and its checksum" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 17, 2));
    var payload: [block_bytes]u8 = undefined;
    try takeBlock(&card, &payload);
    for (payload) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(@as(u32, 1), card.reads);
}

test "a block written by CMD24 reads back through CMD17" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 24, 9));
    const filled: [block_bytes]u8 = @splat(0x5A);
    try std.testing.expectEqual(sd_card.token.accepted, sendBlock(&card, 0x5A, sd_crc.crc16(&filled)));
    drain(&card, 2);
    try std.testing.expectEqual(@as(u32, 1), card.writes);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 17, 9));
    var payload: [block_bytes]u8 = undefined;
    try takeBlock(&card, &payload);
    try std.testing.expectEqualSlices(u8, &filled, &payload);
}

test "a write payload whose checksum is wrong is refused once CMD59 turns checking on" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 59, 1));
    try std.testing.expect(card.crc_checks);
    _ = command(&card, 24, 4);
    try std.testing.expectEqual(sd_card.token.crc_error, sendBlock(&card, 0x11, 0));
    try std.testing.expectEqual(@as(u32, 1), card.crc_rejects);
    try std.testing.expectEqual(@as(u32, 0), card.writes);
    try std.testing.expectEqual(@as(usize, 0), card.img.held());
}

test "a card in SPI mode comes up with CRC checking off" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expect(!card.crc_checks);
}

test "a wrong checksum is taken while checking is off, the way ra8_sdmmc_spi writes" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    _ = command(&card, 24, 4);
    // ra8_sdmmc_spi clocks two idle bytes where the checksum goes.
    try std.testing.expectEqual(sd_card.token.accepted, sendBlock(&card, 0x11, 0xFFFF));
    try std.testing.expectEqual(@as(u32, 1), card.writes);
    try std.testing.expectEqual(@as(u32, 1), card.crc_unchecked);
    try std.testing.expectEqual(@as(u32, 0), card.crc_rejects);
    try std.testing.expectEqual(@as(usize, 1), card.img.held());
}

test "a right checksum is not counted as unchecked" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    _ = command(&card, 24, 4);
    const filled: [block_bytes]u8 = @splat(0x11);
    try std.testing.expectEqual(sd_card.token.accepted, sendBlock(&card, 0x11, sd_crc.crc16(&filled)));
    try std.testing.expectEqual(@as(u32, 1), card.writes);
    try std.testing.expectEqual(@as(u32, 0), card.crc_unchecked);
}

test "CMD59 with bit zero clear switches checking back off" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    _ = command(&card, 59, 1);
    try std.testing.expect(card.crc_checks);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 59, 0));
    try std.testing.expect(!card.crc_checks);
    _ = command(&card, 24, 4);
    try std.testing.expectEqual(sd_card.token.accepted, sendBlock(&card, 0x11, 0xFFFF));
}

test "a block taken with an unchecked checksum is not a quiet card" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    _ = command(&card, 24, 4);
    _ = sendBlock(&card, 0x11, 0xFFFF);
    try std.testing.expect(!card.quiet());
    try std.testing.expectEqual(@as(u32, 1), card.crc_unchecked);
}

test "a block past the end of the card is a read error, not zeros" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    const past = image.geometry.default_capacity_blocks;
    try std.testing.expectEqual(sd_card.r1.parameter, command(&card, 17, past));
    try std.testing.expectEqual(sd_card.token.read_error, card.exchange(sd_card.token.idle));
    try std.testing.expectEqual(@as(u32, 1), card.past_end);
}

test "a write past the end of the card is not stored" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    const past = image.geometry.default_capacity_blocks;
    _ = command(&card, 24, past);
    const filled: [block_bytes]u8 = @splat(7);
    try std.testing.expectEqual(sd_card.token.write_error, sendBlock(&card, 7, sd_crc.crc16(&filled)));
    try std.testing.expectEqual(@as(u32, 1), card.past_end);
    try std.testing.expectEqual(@as(usize, 0), card.img.held());
}

test "CMD18 keeps streaming blocks until CMD12 stops it" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 18, 0));
    var payload: [block_bytes]u8 = undefined;
    try takeBlock(&card, &payload);
    // Idle clocking fetches the next block, with no R1 in front of it.
    try takeBlock(&card, &payload);
    try std.testing.expectEqual(@as(u32, 2), card.stream_block);
    _ = command(&card, 12, 0);
    try std.testing.expect(!card.stream);
    try std.testing.expectEqual(@as(u32, 2), card.reads);
}

test "an erase with no range latched is refused, which dev runs on block zero" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    const filled: [block_bytes]u8 = @splat(0xEE);
    _ = command(&card, 24, 0);
    _ = sendBlock(&card, 0xEE, sd_crc.crc16(&filled));
    drain(&card, 2);
    try std.testing.expectEqual(sd_card.r1.parameter, command(&card, 38, 0));
    try std.testing.expectEqual(@as(u32, 1), card.erase_seq);
    try std.testing.expectEqual(@as(usize, 1), card.img.held());
}

test "CMD32 and CMD33 latch a range CMD38 then erases" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    const filled: [block_bytes]u8 = @splat(0xEE);
    _ = command(&card, 24, 6);
    _ = sendBlock(&card, 0xEE, sd_crc.crc16(&filled));
    drain(&card, 2);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 32, 6));
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 33, 7));
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 38, 0));
    try std.testing.expectEqual(@as(u32, 1), card.erased);
    try std.testing.expectEqual(@as(usize, 0), card.img.held());
}

test "the range is spent once it is erased" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    _ = command(&card, 32, 0);
    _ = command(&card, 33, 1);
    _ = command(&card, 38, 0);
    try std.testing.expectEqual(sd_card.r1.parameter, command(&card, 38, 0));
    try std.testing.expectEqual(@as(u32, 1), card.erase_seq);
}

test "CMD9 sizes the card the image actually gives" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    try std.testing.expectEqual(sd_card.r1.ready, command(&card, 9, 0));
    var csd: [16]u8 = undefined;
    try takeBlock(&card, &csd);
    const csize = (@as(u32, csd[7] & 0x3F) << 16) | (@as(u32, csd[8]) << 8) | csd[9];
    try std.testing.expectEqual(card.img.csize(), csize);
    try std.testing.expectEqual(@as(u8, 0x40), csd[0]);
}

test "a multi-block write takes the blocks in order and stop-tran ends it" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    _ = command(&card, 25, 30);
    const first: [block_bytes]u8 = @splat(1);
    _ = card.exchange(sd_write.host_token.multi);
    var index: usize = 0;
    while (index < block_bytes) : (index += 1) _ = card.exchange(1);
    const sum = sd_crc.crc16(&first);
    _ = card.exchange(@intCast(sum >> 8));
    _ = card.exchange(@intCast(sum & 0xFF));
    try std.testing.expectEqual(sd_card.token.accepted, card.exchange(sd_card.token.idle));
    drain(&card, 2);
    _ = card.exchange(sd_write.host_token.stop);
    try std.testing.expect(!card.write.active());
    try std.testing.expectEqual(@as(u32, 1), card.writes);
}

test "a command frame interrupts an open stream instead of being read as clocking" {
    var card = unit();
    defer card.deinit();
    try bringUp(&card);
    _ = command(&card, 18, 0);
    var payload: [block_bytes]u8 = undefined;
    try takeBlock(&card, &payload);
    try std.testing.expect(card.stream);
    try std.testing.expectEqual(sd_card.token.idle, command(&card, 12, 0));
    try std.testing.expectEqual(sd_card.r1.ready, card.exchange(sd_card.token.idle));
    try std.testing.expect(!card.stream);
}

test "a byte that is not a command lead leaves the card idle" {
    var card = unit();
    defer card.deinit();
    try std.testing.expectEqual(sd_card.token.idle, card.exchange(0x00));
    try std.testing.expectEqual(sd_card.token.idle, card.exchange(0xFF));
    try std.testing.expect(!card.collecting);
    try std.testing.expectEqual(@as(u32, 0), card.commands);
}
