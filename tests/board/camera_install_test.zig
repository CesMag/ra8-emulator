//! Covers src/board/camera_install.zig (RA8EMU-795): an opened source
//! replaces the CEU's source and closes the old one.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.board.Board;
const install = ra8.board.camera_install.install;
const FrameSource = ra8.chip.periph.ceu.camera.frame_source.FrameSource;
const Shape = ra8.chip.periph.ceu.camera.frame_source.Shape;

const Stub = struct {
    closed: u32 = 0,

    fn frame(_: *anyopaque, _: u64, _: Shape) void {}
    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0);
    }
    fn close(context: *anyopaque) void {
        const self: *Stub = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
    const vtable: FrameSource.VTable = .{ .frame = frame, .fill = fill, .close = close };

    fn source(self: *Stub, label: []const u8) FrameSource {
        return .{ .context = self, .vtable = &vtable, .label = label };
    }
};

test "an opened source replaces the old one and closes it" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var old: Stub = .{};
    var next: Stub = .{};
    board.capture.source = old.source("old");
    install(&board, next.source("next"));
    try std.testing.expectEqual(@as(u32, 1), old.closed);
    try std.testing.expectEqual(@as(u32, 0), next.closed);
    try std.testing.expectEqualStrings("next", board.capture.source.label);
    board.capture.source = ra8.chip.periph.ceu.camera.gradient.source();
}
