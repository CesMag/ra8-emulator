//! Covers src/board/quiet_due.zig.
const std = @import("std");
const ra8 = @import("ra8");
const quiet_due = ra8.board.boundary.quiet_due;
const ulpt = ra8.chip.periph.ulpt;

test "a fresh board is quiet until its next queued event" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expect(quiet_due.quietUntilDue(&board));
}

test "a running low-power timer keeps the board busy" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.lowpower.channels[1].cr |= ulpt.control.tstart;
    try std.testing.expect(!quiet_due.quietUntilDue(&board));
}

test "an armed transfer channel keeps the board busy" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.dma.channels[3].dmcnt |= ra8.chip.periph.dmac.field.dte;
    try std.testing.expect(!quiet_due.quietUntilDue(&board));
}

fn onFrame(context: *anyopaque, when_ns: u64) void {
    _ = context;
    _ = when_ns;
}

test "the panel's next vsync is an edge ahead of now" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    // Board.init leaves the display for attach(); the output stage with a
    // viewer on it is all vsyncDue reads.
    board.display.output = .{ .vsync = .{ .sink = .{ .context = &board, .frame = onFrame } } };
    try std.testing.expect(quiet_due.vsyncDue(&board) > 0);
}

test "a panel nobody watches gives no vsync edge" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.display.output = .{};
    try std.testing.expectEqual(@as(u64, 0), quiet_due.vsyncDue(&board));
}

test "stopped GPT channels give no edge" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try std.testing.expectEqual(@as(u64, 0), quiet_due.gptDue(&board));
}

test "a running GPT channel's next wrap is an edge ahead of now" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.pwm.channels[0].cr |= ra8.chip.periph.gpt.control.cst;
    try std.testing.expect(quiet_due.gptDue(&board) > 0);
}
