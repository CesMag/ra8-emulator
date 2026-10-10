//! The two SD cards' halves of the `sd` snapshot section (RA8EMU-664,
//! RA8EMU-1104): the SPI-mode card (card.zig) and the SD-bus card
//! (bus_card.zig). Each goes as its plain state, its image's size, and the
//! blocks something wrote (snapshot/blocks.zig).
//!
//! Not saved, because a load rebuilds them: an image's allocator and its
//! block map. A load is two steps, so the board's section can read every
//! half before it changes anything: `read` gives a `Staged` card, and
//! `install` puts it in place once its block map is built.
const fields = @import("ra8_snapshot").fields;
const blocks = @import("ra8_snapshot").blocks;
const SpiCard = @import("card.zig").Card;
const BusCard = @import("bus_card.zig").Card;

const image_wiring = .{ "allocator", "blocks" };

/// A card read from a payload and not yet in place: the live card with the
/// saved fields read over it, and the blocks its image is to hold.
pub fn Staged(comptime Card: type) type {
    return struct {
        const Self = @This();

        card: Card,
        list: blocks.List,

        /// The block map this card will hold. On failure nothing is left
        /// allocated.
        pub fn build(self: *const Self) error{OutOfMemory}!blocks.Map {
            return self.list.build(self.card.img.allocator);
        }

        /// Put this card in `live`'s place holding `map`, and free the
        /// blocks `live` held.
        pub fn install(self: *Self, live: *Card, map: blocks.Map) void {
            blocks.free(&live.img.blocks);
            self.card.img.blocks = map;
            live.* = self.card;
        }
    };
}

pub fn writeSpi(writer: anytype, card: *const SpiCard) !void {
    try fields.writeExcept(writer, card.*, .{"img"});
    try fields.writeExcept(writer, card.img, image_wiring);
    try blocks.write(writer, &card.img.blocks);
}

pub fn readSpi(cursor: *fields.Cursor, live: *const SpiCard) fields.Error!Staged(SpiCard) {
    var card = live.*;
    try fields.readOver(cursor, &card, .{"img"});
    try fields.readOver(cursor, &card.img, image_wiring);
    return .{ .card = card, .list = try blocks.List.read(cursor, card.img.capacity_blocks) };
}

/// Whether the SPI card's command and reply indexes land inside their
/// buffers.
pub fn spiFits(card: *const SpiCard) bool {
    const reply = card.reply;
    return card.cmd_len <= card.cmd.len and reply.len <= reply.buf.len and reply.pos <= reply.len;
}

/// The SD-bus card in its pre-RA8EMU-1053 field order (state, capacity,
/// past_end), so the bytes did not move when its store became an Image.
pub fn writeBus(writer: anytype, card: *const BusCard) !void {
    try fields.writeExcept(writer, card.*, .{ "img", "past_end" });
    try fields.writeExcept(writer, card.img, image_wiring);
    try fields.writeExcept(writer, card.*, .{ "img", "state" });
    try blocks.write(writer, &card.img.blocks);
}

pub fn readBus(cursor: *fields.Cursor, live: *const BusCard) fields.Error!Staged(BusCard) {
    var card = live.*;
    try fields.readOver(cursor, &card, .{ "img", "past_end" });
    try fields.readOver(cursor, &card.img, image_wiring);
    try fields.readOver(cursor, &card, .{ "img", "state" });
    return .{ .card = card, .list = try blocks.List.read(cursor, card.img.capacity_blocks) };
}
