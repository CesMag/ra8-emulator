//! RA8EMU-688: a whole attached board saved and loaded into a freshly
//! attached one matches byte for byte, and a file from another part, or one
//! without a part section, is refused before anything changes.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("../../interfaces/cli/store_board.zig");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const section = ra8.board.snapshot.board;

/// A store and the board attached to it, built in place so the board's
/// wiring points at this rig and not at a copy.
const Rig = struct {
    store: store_board.Store,
    board: Board,

    fn build(rig: *Rig) !void {
        rig.store = try store_board.Store.init(null);
        errdefer rig.store.deinit();
        rig.board = Board.init(std.testing.allocator);
        errdefer rig.board.deinit();
        try store_board.attach(&rig.board, .{ .store = &rig.store });
    }

    fn deinit(rig: *Rig) void {
        rig.board.deinit();
        rig.store.deinit();
    }
};

fn saved(board: *const Board, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try section.save(board, &list.writer);
}

test "a whole board loaded into a fresh one saves the same bytes" {
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    rig.board.c6.reply = .{0x5A};
    rig.board.c6.wire.replies_sent = 6;
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try saved(&rig.board, &first);

    var fresh: Rig = undefined;
    try fresh.build();
    defer fresh.deinit();
    try section.load(&fresh.board, first.written());
    try std.testing.expectEqual(@as(u8, 0x5A), fresh.board.c6.reply[0]);
    try std.testing.expectEqual(@as(u32, 6), @as(u32, @intCast(fresh.board.c6.wire.replies_sent)));
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try saved(&fresh.board, &second);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
}

test "a file from another part is refused and the board is untouched" {
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    rig.board.c6.reply = .{0x5A};
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&rig.board, &bytes);

    var other: Rig = undefined;
    try other.build();
    defer other.deinit();
    other.board.part = .ra8p1;
    const before = other.board.c6.reply[0];
    try std.testing.expectError(error.WrongPart, section.load(&other.board, bytes.written()));
    try std.testing.expectEqual(before, other.board.c6.reply[0]);
}

test "a file without a part section is refused" {
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try file.writeHeader(&bytes.writer);
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    try std.testing.expectError(error.Missing, section.load(&rig.board, bytes.written()));
}
