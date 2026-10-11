//! Covers src/session/board/camera.zig (RA8EMU-1114): a host input the
//! caller opened becomes the board's camera source and the old source is
//! closed, and no input is the camera model's own gradient.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.board.Board;
const board_camera = ra8.session.board.camera;
const gradient = ra8.chip.periph.ceu.camera.gradient;

/// A host input that hands over one fixed pixel and counts its closes.
const Input = struct {
    closed: u32 = 0,
    pixel: [3]u8 = .{ 0x10, 0x20, 0x30 },

    pub fn picture(self: *Input, _: u64) ra8.components.camera.convert.Frame {
        return .{ .width = 1, .height = 1, .pixels = &self.pixel };
    }
    pub fn close(self: *Input) void {
        self.closed += 1;
    }
    pub fn label(_: *const Input) []const u8 {
        return "test input";
    }
    pub fn detail(_: *const Input) []const u8 {
        return "one pixel";
    }
};

test "an opened input becomes the camera source, and the next one closes it" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var first: Input = .{};
    var second: Input = .{};
    try board_camera.install(&board, std.testing.allocator, @as(?*Input, &first));
    try std.testing.expectEqualStrings("test input", board.capture.source.label);
    try std.testing.expectEqualStrings("one pixel", board.capture.source.detail);
    try std.testing.expectEqual(@as(u32, 0), first.closed);

    try board_camera.install(&board, std.testing.allocator, @as(?*Input, &second));
    try std.testing.expectEqual(@as(u32, 1), first.closed);
    try std.testing.expectEqual(@as(u32, 0), second.closed);

    try board_camera.install(&board, std.testing.allocator, @as(?*Input, null));
    try std.testing.expectEqual(@as(u32, 1), second.closed);
    try std.testing.expectEqualStrings(gradient.source().label, board.capture.source.label);
}

test "no input is the gradient" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    try board_camera.install(&board, std.testing.allocator, @as(?*Input, null));
    try std.testing.expectEqualStrings(gradient.source().label, board.capture.source.label);
}
