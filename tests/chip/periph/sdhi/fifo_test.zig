//! Covers src/chip/periph/sdhi/fifo.zig: what one SD_BUF0 access comes to, and
//! what a block the card refuses does to the phase behind it.
const std = @import("std");
const ra8 = @import("ra8");
const fifo = ra8.chip.periph.sdhi_fifo;
const card = ra8.components.sd_bus_card;
const bus_line = ra8.components.sd_bus_line;
const xfer = ra8.chip.periph.sdhi_xfer;

/// The first block past the end of the card.
const off_card: u32 = card.geometry.capacity_blocks;

fn disk() card.Card {
    return card.Card.init(std.testing.allocator);
}

/// Drain a whole block a word at a time, answering what the last word came to.
fn drain(transfer: *xfer.Transfer, on: *card.Card) fifo.Outcome {
    var last: fifo.Outcome = .word;
    for (0..xfer.words_per_block) |_| last = fifo.read(transfer, bus_line.line(on), 4).outcome;
    return last;
}

/// Fill a whole block a word at a time, answering what the last word came to.
fn fill(transfer: *xfer.Transfer, on: *card.Card, value: u32) fifo.Outcome {
    var last: fifo.Outcome = .word;
    for (0..xfer.words_per_block) |_| last = fifo.write(transfer, bus_line.line(on), 4, value);
    return last;
}

test "an access narrower than the port moves nothing" {
    var on = disk();
    defer on.deinit();
    var transfer = xfer.Transfer{};
    transfer.arm(.read, 0, 1);
    try std.testing.expectEqual(fifo.Outcome.narrow, fifo.read(&transfer, bus_line.line(&on), 2).outcome);
    try std.testing.expectEqual(fifo.Outcome.narrow, fifo.write(&transfer, bus_line.line(&on), 1, 0xAA));
    try std.testing.expectEqual(@as(u32, 0), transfer.word_idx);
}

test "a FIFO with nothing armed behind it starves" {
    var on = disk();
    defer on.deinit();
    var transfer = xfer.Transfer{};
    try std.testing.expectEqual(fifo.Outcome.starved, fifo.read(&transfer, bus_line.line(&on), 4).outcome);
    try std.testing.expectEqual(fifo.Outcome.starved, fifo.write(&transfer, bus_line.line(&on), 4, 0xAA));
}

test "the last word of the last block ends the phase" {
    var on = disk();
    defer on.deinit();
    var transfer = xfer.Transfer{};
    transfer.arm(.read, 4, 1);
    try std.testing.expectEqual(fifo.Outcome.ended, drain(&transfer, &on));
    try std.testing.expectEqual(xfer.Phase.none, transfer.phase);
}

test "a block the card refuses ends a read phase instead of staging zeros" {
    var on = disk();
    defer on.deinit();
    var transfer = xfer.Transfer{};
    transfer.arm(.read, off_card - 1, 2);
    // The first block is real, so its last word finishes it and the next one
    // is asked for: that one is off the end of the card.
    try std.testing.expectEqual(fifo.Outcome.lost, drain(&transfer, &on));
    try std.testing.expectEqual(xfer.Phase.none, transfer.phase);
    try std.testing.expectEqual(@as(u32, 1), on.past_end);
}

test "a block the card refuses ends a write phase and is not counted as written" {
    var on = disk();
    defer on.deinit();
    var transfer = xfer.Transfer{};
    transfer.arm(.write, off_card, 1);
    try std.testing.expectEqual(fifo.Outcome.lost, fill(&transfer, &on, 0xDEAD_BEEF));
    try std.testing.expectEqual(xfer.Phase.none, transfer.phase);
    try std.testing.expectEqual(@as(u32, 0), on.held());
    try std.testing.expectEqual(@as(u32, 1), on.past_end);
}

test "the blocks that landed before a refused one stay landed" {
    var on = disk();
    defer on.deinit();
    var transfer = xfer.Transfer{};
    transfer.arm(.write, off_card - 1, 2);
    // The first block is the last one the card holds; the second is not.
    try std.testing.expectEqual(fifo.Outcome.block, fill(&transfer, &on, 0x1234_5678));
    try std.testing.expectEqual(fifo.Outcome.lost, fill(&transfer, &on, 0x1234_5678));
    try std.testing.expectEqual(@as(u32, 1), on.held());
    var block: [card.geometry.block_bytes]u8 = undefined;
    try std.testing.expect(on.read(off_card - 1, &block));
    try std.testing.expectEqual(@as(u8, 0x78), block[0]);
}

test "loading a block the card refuses stops the phase" {
    var on = disk();
    defer on.deinit();
    var transfer = xfer.Transfer{};
    transfer.arm(.read, off_card, 1);
    try std.testing.expect(!fifo.load(&transfer, bus_line.line(&on)));
    try std.testing.expectEqual(xfer.Phase.none, transfer.phase);
    transfer.arm(.read, 0, 1);
    try std.testing.expect(fifo.load(&transfer, bus_line.line(&on)));
    try std.testing.expectEqual(xfer.Phase.read, transfer.phase);
}
