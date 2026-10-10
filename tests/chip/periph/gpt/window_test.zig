//! Which word a byte offset lands in, and which words this model interprets.
const std = @import("std");

const ra8 = @import("ra8");
const gpt = ra8.chip.periph.gpt;
const window = gpt.window;

test "every lane of a word maps back to the word" {
    var index: u32 = 0;
    while (index < 4) : (index += 1) {
        try std.testing.expectEqual(gpt.off.gtcnt, window.cellOf(gpt.off.gtcnt + index));
    }
}

test "an offset in no interpreted word is its own cell" {
    try std.testing.expectEqual(@as(u32, 0x34), window.cellOf(0x34));
    try std.testing.expect(!window.interpreted(0x34));
}

test "the interpreted set covers the counter, the compares and the buffers" {
    try std.testing.expect(window.interpreted(gpt.off.gtcnt));
    try std.testing.expect(window.interpreted(gpt.off.gtcr + 3));
    try std.testing.expect(window.interpreted(gpt.buffers.off.gtber));
    try std.testing.expect(window.interpreted(gpt.buffers.off.buffer_a));
    try std.testing.expect(window.interpreted(gpt.match.off.gtccra));
}

test "GTWP is not in the interpreted set, so protection can never cover it" {
    try std.testing.expect(!window.interpreted(gpt.protection.off.gtwp));
    try std.testing.expect(!window.protected(gpt.protection.off.gtwp));
}

test "GTST is interpreted but not protected, because the HAL never brackets it" {
    var lane: u32 = 0;
    while (lane < 4) : (lane += 1) {
        try std.testing.expect(window.interpreted(gpt.off.gtst + lane));
        try std.testing.expect(!window.protected(gpt.off.gtst + lane));
    }
}

test "the protected set is everything else the HAL does bracket" {
    try std.testing.expect(window.protected(gpt.off.gtcnt));
    try std.testing.expect(window.protected(gpt.off.gtcr + 3));
    try std.testing.expect(window.protected(gpt.off.gtpr));
    try std.testing.expect(window.protected(gpt.off.gtstr));
    try std.testing.expect(window.protected(gpt.off.gtstp));
    try std.testing.expect(window.protected(gpt.match.off.gtccra));
    try std.testing.expect(window.protected(gpt.buffers.off.gtber));
}

test "a register this model only shadows is outside both sets" {
    try std.testing.expect(!window.interpreted(0x34));
    try std.testing.expect(!window.protected(0x34));
}

test "a lane round trips through merge" {
    const merged = window.merge(0xDEAD_BEEF, 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0xDEAD_11EF), merged);
    try std.testing.expectEqual(@as(u8, 0x11), window.lane(merged, 1));
}
