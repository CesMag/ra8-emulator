//! Covers src/chip/periph/sdhi/xfer.zig.
const std = @import("std");
const ra8 = @import("ra8");
const xfer = ra8.chip.periph.sdhi_xfer;

test "a fresh transfer has no phase in flight" {
    const data = xfer.Transfer{};
    try std.testing.expectEqual(xfer.Phase.none, data.phase);
    try std.testing.expectEqual(@as(u32, 0), data.blocks_left);
}

test "arming with a count of zero still moves one block" {
    var data = xfer.Transfer{};
    data.arm(.read, 9, 0);
    try std.testing.expectEqual(@as(u32, 1), data.blocks_left);
    try std.testing.expectEqual(@as(u32, 9), data.lba);
}

test "arming clears the staging buffer" {
    var data = xfer.Transfer{};
    _ = data.push(0xDEAD_BEEF);
    data.arm(.write, 0, 1);
    try std.testing.expectEqual(@as(u32, 0), data.pop().value);
}

test "a word comes back little endian, the way the bus wrote it" {
    var data = xfer.Transfer{};
    data.arm(.write, 0, 1);
    _ = data.push(0x1122_3344);
    data.word_idx = 0;
    try std.testing.expectEqual(@as(u32, 0x1122_3344), data.pop().value);
    try std.testing.expectEqual(@as(u8, 0x44), data.stage[0]);
}

test "the last word of a block says so" {
    var data = xfer.Transfer{};
    data.arm(.read, 0, 1);
    for (0..xfer.words_per_block - 1) |_| {
        try std.testing.expect(!data.pop().done);
    }
    try std.testing.expect(data.pop().done);
}

test "a filled block reports itself once" {
    var data = xfer.Transfer{};
    data.arm(.write, 0, 1);
    for (0..xfer.words_per_block - 1) |_| {
        try std.testing.expect(!data.push(0));
    }
    try std.testing.expect(data.push(0));
}

test "a multi block transfer moves to the next address" {
    var data = xfer.Transfer{};
    data.arm(.read, 40, 3);
    try std.testing.expect(data.advance());
    try std.testing.expectEqual(@as(u32, 41), data.lba);
    try std.testing.expectEqual(@as(u32, 0), data.word_idx);
    try std.testing.expectEqual(xfer.Phase.read, data.phase);
}

test "the last block ends the phase" {
    var data = xfer.Transfer{};
    data.arm(.write, 5, 1);
    try std.testing.expect(!data.advance());
    try std.testing.expectEqual(xfer.Phase.none, data.phase);
}

test "stop drops whatever was in flight" {
    var data = xfer.Transfer{};
    data.arm(.read, 5, 8);
    _ = data.pop();
    data.stop();
    try std.testing.expectEqual(xfer.Phase.none, data.phase);
    try std.testing.expectEqual(@as(u32, 0), data.blocks_left);
    try std.testing.expectEqual(@as(u32, 0), data.word_idx);
}
