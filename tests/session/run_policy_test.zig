//! Covers src/session/run_policy.zig: what a run asked for, attached to a
//! board, and what the board tells it through run_hook (RA8EMU-1047).
const std = @import("std");
const ra8 = @import("ra8");
const RunPolicy = ra8.session.run_policy.RunPolicy;
const Board = ra8.board.board.Board;

test "a run's policy holds no pacing and no armed soak until a run asks" {
    const asked: RunPolicy = .{};
    try std.testing.expect(asked.pacing == null);
    try std.testing.expect(!asked.soak.armed);
}

test "a board with no policy attached reports to nobody" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(board.run_hook == null);
}

test "an attached policy hears each watchdog reset as its own soak kind" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var asked: RunPolicy = .{};
    asked.soak.armed = true;
    asked.attach(&board);
    const hook = board.run_hook orelse return error.NotAttached;
    hook.resetFn(hook.context, .iwdt, 7);
    hook.resetFn(hook.context, .watchdog, 9);
    const event = asked.soak.event orelse return error.NoEvent;
    try std.testing.expectEqual(@TypeOf(event.kind).iwdt_reset, event.kind);
    try std.testing.expectEqual(@as(u64, 7), event.at_ns);
}

test "an unpaced policy lets a boundary pass untouched" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var asked: RunPolicy = .{};
    asked.attach(&board);
    const hook = board.run_hook orelse return error.NotAttached;
    hook.boundaryFn(hook.context, 1_000_000);
    try std.testing.expect(asked.pacing == null);
    try std.testing.expect(asked.soak.event == null);
}
