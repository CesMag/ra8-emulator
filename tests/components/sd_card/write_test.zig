//! Covers src/components/sd_card/write.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sd_crc = ra8.components.sd_card.crc;
const sd_write = ra8.components.sd_card.write;

const block_bytes = ra8.components.sd_card.image.geometry.block_bytes;

/// Send a whole payload and its checksum, and hand back what the last byte
/// did, which is the only byte that finishes a block.
fn sendBlock(unit: *sd_write.Write, fill: u8, crc: u16) sd_write.Outcome {
    var index: usize = 0;
    while (index < block_bytes) : (index += 1) {
        _ = unit.feed(fill);
    }
    _ = unit.feed(@intCast(crc >> 8));
    return unit.feed(@intCast(crc & 0xFF));
}

test "a fresh write is not in a data phase at all" {
    var unit = sd_write.Write{};
    try std.testing.expect(!unit.active());
    try std.testing.expectEqual(sd_write.Outcome.none, unit.feed(0xFE));
}

test "the payload starts at the data token and not before it" {
    var unit = sd_write.Write{};
    unit.begin(4, false);
    try std.testing.expect(unit.active());
    _ = unit.feed(0xFF);
    try std.testing.expectEqual(sd_write.Phase.token, unit.phase);
    _ = unit.feed(sd_write.host_token.data);
    try std.testing.expectEqual(sd_write.Phase.data, unit.phase);
}

test "a whole block with a matching checksum commits" {
    var unit = sd_write.Write{};
    unit.begin(4, false);
    _ = unit.feed(sd_write.host_token.data);
    const payload: [block_bytes]u8 = @splat(0x5A);
    const done = sendBlock(&unit, 0x5A, sd_crc.crc16(&payload));
    try std.testing.expect(done.commit.crc_ok);
    try std.testing.expectEqual(@as(u32, 4), done.commit.block);
    try std.testing.expectEqualSlices(u8, &payload, &unit.buf);
    try std.testing.expect(!unit.active());
}

test "a checksum that does not match is reported, not hidden" {
    var unit = sd_write.Write{};
    unit.begin(0, false);
    _ = unit.feed(sd_write.host_token.data);
    const done = sendBlock(&unit, 0x11, 0x0000);
    try std.testing.expect(!done.commit.crc_ok);
}

test "a multi-block write re-arms on the next block" {
    var unit = sd_write.Write{};
    unit.begin(8, true);
    _ = unit.feed(sd_write.host_token.multi);
    const payload: [block_bytes]u8 = @splat(0);
    const first = sendBlock(&unit, 0, sd_crc.crc16(&payload));
    try std.testing.expectEqual(@as(u32, 8), first.commit.block);
    try std.testing.expectEqual(sd_write.Phase.token, unit.phase);
    _ = unit.feed(sd_write.host_token.multi);
    const second = sendBlock(&unit, 0, sd_crc.crc16(&payload));
    try std.testing.expectEqual(@as(u32, 9), second.commit.block);
}

test "stop-tran ends a multi-block write" {
    var unit = sd_write.Write{};
    unit.begin(2, true);
    try std.testing.expectEqual(sd_write.Outcome.stopped, unit.feed(sd_write.host_token.stop));
    try std.testing.expect(!unit.active());
}

test "stop-tran is not a token a single-block write acts on" {
    var unit = sd_write.Write{};
    unit.begin(2, false);
    try std.testing.expectEqual(sd_write.Outcome.none, unit.feed(sd_write.host_token.stop));
    try std.testing.expect(unit.active());
}

test "idle clocking between the command and the payload is ignored" {
    var unit = sd_write.Write{};
    unit.begin(1, false);
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        try std.testing.expectEqual(sd_write.Outcome.none, unit.feed(0xFF));
    }
    try std.testing.expectEqual(sd_write.Phase.token, unit.phase);
}
