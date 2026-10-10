//! RA8EMU-689: a whole run (memory, cores, board) saved and loaded into a
//! fresh run saves the same bytes; another part's file is refused before
//! anything changes, and a file without a core it is asked for is refused.
const std = @import("std");
const ra8 = @import("ra8");
const store_board = @import("../../interfaces/cli/store_board.zig");
const fixture = @import("../../chip/core/cpu/exception/ram.zig");
const Board = ra8.board.board.Board;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const run = ra8.board.snapshot.run;

const word_at: u32 = 0x2200_0040;

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

fn saved(rig: *const Rig, cores: []const *const Cpu, list: *std.Io.Writer.Allocating) !void {
    try run.save(&list.writer, &rig.store, cores, &rig.board);
}

test "a whole run loaded into a fresh one saves the same bytes" {
    var ram: fixture.Ram = .{};
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    rig.store.span(word_at, 4).?[0] = 0x7E;
    rig.board.c6.reply = .{0x5A};
    var zero = try fixture.boot(&ram);
    var one = try fixture.boot(&ram);
    zero.regs.low[4] = 0x1234_5678;
    one.regs.low[4] = 0x0BAD_F00D;
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try saved(&rig, &.{ &zero, &one }, &first);

    var fresh: Rig = undefined;
    try fresh.build();
    defer fresh.deinit();
    var fresh_zero = try fixture.boot(&ram);
    var fresh_one = try fixture.boot(&ram);
    try run.load(first.written(), &fresh.store, &.{ &fresh_zero, &fresh_one }, &fresh.board);
    try std.testing.expectEqual(@as(u8, 0x7E), fresh.store.span(word_at, 4).?[0]);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), fresh_zero.regs.low[4]);
    try std.testing.expectEqual(@as(u32, 0x0BAD_F00D), fresh_one.regs.low[4]);
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try saved(&fresh, &.{ &fresh_zero, &fresh_one }, &second);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
}

test "another part's file is refused before anything changes" {
    var ram: fixture.Ram = .{};
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    rig.store.span(word_at, 4).?[0] = 0x7E;
    var zero = try fixture.boot(&ram);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&rig, &.{&zero}, &bytes);

    var other: Rig = undefined;
    try other.build();
    defer other.deinit();
    other.board.part = .ra8p1;
    var other_zero = try fixture.boot(&ram);
    other_zero.regs.low[4] = 0x4444_4444;
    try std.testing.expectError(error.WrongPart, run.load(bytes.written(), &other.store, &.{&other_zero}, &other.board));
    try std.testing.expectEqual(@as(u8, 0), other.store.span(word_at, 4).?[0]);
    try std.testing.expectEqual(@as(u32, 0x4444_4444), other_zero.regs.low[4]);
}

test "a file without a core it is asked for is refused" {
    var ram: fixture.Ram = .{};
    var rig: Rig = undefined;
    try rig.build();
    defer rig.deinit();
    var zero = try fixture.boot(&ram);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&rig, &.{&zero}, &bytes);

    var fresh: Rig = undefined;
    try fresh.build();
    defer fresh.deinit();
    var fresh_zero = try fixture.boot(&ram);
    var fresh_one = try fixture.boot(&ram);
    try std.testing.expectError(error.Missing, run.load(bytes.written(), &fresh.store, &.{ &fresh_zero, &fresh_one }, &fresh.board));
}
