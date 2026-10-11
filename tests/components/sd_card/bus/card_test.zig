//! Covers src/components/sd_card/bus_card.zig.
const std = @import("std");
const ra8 = @import("ra8");
const card = ra8.components.sd_card.bus_card;

fn unit() card.Card {
    return card.Card.init(std.testing.allocator);
}

/// Walk the identification sequence the way an image does, so a test about
/// a block transfer starts from a selected card.
fn identify(unit_card: *card.Card) void {
    unit_card.powerUp();
    _ = unit_card.publishCid();
    _ = unit_card.takeAddress();
    unit_card.select(@intCast(card.response.rca_value >> 16));
}

test "a fresh card is idle and holds nothing" {
    var unit_card = unit();
    defer unit_card.deinit();
    try std.testing.expectEqual(card.State.idle, unit_card.state);
    try std.testing.expectEqual(@as(u32, 0), unit_card.held());
    try std.testing.expect(!unit_card.canTransfer());
}

test "the identification sequence walks idle to transfer" {
    var unit_card = unit();
    defer unit_card.deinit();
    unit_card.powerUp();
    try std.testing.expectEqual(card.State.ready, unit_card.state);
    try std.testing.expect(unit_card.publishCid());
    try std.testing.expectEqual(card.State.ident, unit_card.state);
    try std.testing.expect(unit_card.takeAddress());
    try std.testing.expectEqual(card.State.stby, unit_card.state);
    unit_card.select(1);
    try std.testing.expect(unit_card.canTransfer());
}

test "a step taken out of order is refused" {
    var unit_card = unit();
    defer unit_card.deinit();
    try std.testing.expect(!unit_card.publishCid());
    try std.testing.expect(!unit_card.takeAddress());
    try std.testing.expectEqual(card.State.idle, unit_card.state);
}

test "CMD7 for another address deselects" {
    var unit_card = unit();
    defer unit_card.deinit();
    identify(&unit_card);
    unit_card.select(2);
    try std.testing.expectEqual(card.State.stby, unit_card.state);
    try std.testing.expect(!unit_card.canTransfer());
}

test "CMD0 puts a selected card back in idle" {
    var unit_card = unit();
    defer unit_card.deinit();
    identify(&unit_card);
    unit_card.goIdle();
    try std.testing.expectEqual(card.State.idle, unit_card.state);
}

test "a block nobody wrote reads as zeros" {
    var unit_card = unit();
    defer unit_card.deinit();
    var block: [card.geometry.block_bytes]u8 = @splat(0xAA);
    try std.testing.expect(unit_card.read(7, &block));
    for (block) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a written block comes back and is held" {
    var unit_card = unit();
    defer unit_card.deinit();
    var written: [card.geometry.block_bytes]u8 = @splat(0);
    written[0] = 0x5A;
    written[card.geometry.block_bytes - 1] = 0xC3;
    try std.testing.expect(unit_card.write(12, &written));
    try std.testing.expectEqual(@as(u32, 1), unit_card.held());
    var read_back: [card.geometry.block_bytes]u8 = undefined;
    try std.testing.expect(unit_card.read(12, &read_back));
    try std.testing.expectEqualSlices(u8, &written, &read_back);
}

test "an address past the end of the card is refused and counted" {
    var unit_card = unit();
    defer unit_card.deinit();
    const past = card.geometry.capacity_blocks;
    var block: [card.geometry.block_bytes]u8 = @splat(0);
    try std.testing.expect(!unit_card.write(past, &block));
    try std.testing.expect(!unit_card.read(past, &block));
    try std.testing.expectEqual(@as(u32, 2), unit_card.past_end);
    try std.testing.expectEqual(@as(u32, 0), unit_card.held());
}

test "release frees the blocks and powers the card down" {
    var unit_card = unit();
    defer unit_card.deinit();
    identify(&unit_card);
    const block: [card.geometry.block_bytes]u8 = @splat(1);
    try std.testing.expect(unit_card.write(3, &block));
    unit_card.release();
    try std.testing.expectEqual(@as(u32, 0), unit_card.held());
    try std.testing.expectEqual(card.State.idle, unit_card.state);
}

test "the CSD encodes this card's capacity" {
    var unit_card = unit();
    defer unit_card.deinit();
    const words = unit_card.csd();
    const c_size = (card.geometry.capacity_blocks / card.geometry.csize_unit) - 1;
    try std.testing.expectEqual(card.response.csd_v2, words[3]);
    try std.testing.expectEqual((c_size >> 16) & 0x3F, words[2]);
    try std.testing.expectEqual((c_size & 0xFFFF) << 16, words[1]);
    try std.testing.expectEqual(@as(u32, 0), words[0]);
}
