//! Covers src/chip/periph/sdhi/sdhi_snapshot.zig (RA8EMU-1104): the SD host
//! controller's half of the `sd` section reads back over a fresh unit,
//! keeps that unit's card line, and a word index past a block does not fit.
const std = @import("std");
const ra8 = @import("ra8");
const half = ra8.chip.periph.sdhi_snapshot;
const fields = ra8.snapshot.fields;
const Sdhi = ra8.chip.periph.sdhi.Sdhi;
const sdhi_line = ra8.chip.periph.sdhi_line;
const xfer = ra8.chip.periph.sdhi_xfer;

test "the controller reads back over a fresh unit and keeps its card line" {
    var unit = Sdhi.init();
    unit.regs[2] = 0xDEAD;
    unit.reads = 3;
    unit.app_pending = true;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try half.write(&out.writer, &unit);

    var slot: u8 = 0;
    var fresh = Sdhi.init();
    fresh.card = .{ .context = &slot, .vtable = sdhi_line.absent.vtable };
    var cursor: fields.Cursor = .{ .bytes = out.written() };
    const read = try half.read(&cursor, &fresh);
    try std.testing.expect(cursor.done());
    try std.testing.expect(half.fits(&read));
    try std.testing.expectEqual(@as(u32, 0), fresh.reads);
    try std.testing.expectEqual(@as(u32, 0xDEAD), read.regs[2]);
    try std.testing.expectEqual(@as(u32, 3), read.reads);
    try std.testing.expect(read.app_pending);
    try std.testing.expect(read.card.context == @as(*anyopaque, &slot));
}

test "a cut payload is Truncated" {
    var unit = Sdhi.init();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try half.write(&out.writer, &unit);
    var cursor: fields.Cursor = .{ .bytes = out.written()[0 .. out.written().len - 1] };
    try std.testing.expectError(error.Truncated, half.read(&cursor, &unit));
}

test "a word index past a block does not fit" {
    var unit = Sdhi.init();
    unit.data.word_idx = xfer.words_per_block;
    try std.testing.expect(half.fits(&unit));
    unit.data.word_idx = xfer.words_per_block + 1;
    try std.testing.expect(!half.fits(&unit));
}
