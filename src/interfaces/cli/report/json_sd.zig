//! The `sd` entry of the `dumps` object (RA8EMU-391): the `--dump-sd` card
//! block, the same rows report/dumps.zig prints. Rows of nothing but zeros
//! are counted rather than listed, as the text does; each kept row is its
//! byte offset and its bytes as one lowercase hex string.
const std = @import("std");
const sd_dump = @import("ra8_components").sd_dump;
const sd_image = @import("ra8_components").sd_image;
const Board = @import("ra8_board").board.Board;

/// The card shape, for tests that build a card to read back.
pub const geometry = sd_image.geometry;

/// Null unless `--dump-sd` asked; `on_card` false when the card is shorter.
pub fn block(j: anytype, board: *Board, asked: ?u32) !void {
    const index = asked orelse return j.field("sd", null);
    var bytes: sd_image.Block = undefined;
    const on_card = board.sd.img.read(index, &bytes);
    try j.open("sd", '{');
    try j.field("block", index);
    try j.field("on_card", on_card);
    try j.open("rows", '[');
    var dropped: usize = 0;
    var offset: usize = 0;
    while (on_card and offset < bytes.len) : (offset += sd_dump.row_bytes) {
        const row = bytes[offset..@min(offset + sd_dump.row_bytes, bytes.len)];
        if (sd_dump.blank(row)) {
            dropped += 1;
            continue;
        }
        var hex: [2 * sd_dump.row_bytes]u8 = undefined;
        try j.open(null, '{');
        try j.field("offset", offset);
        try j.field("hex", try std.fmt.bufPrint(&hex, "{x}", .{row}));
        try j.close('}');
    }
    try j.close(']');
    try j.field("zero_rows", dropped);
    try j.close('}');
}
