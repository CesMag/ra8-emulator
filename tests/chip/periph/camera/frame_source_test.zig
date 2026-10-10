//! Covers src/chip/periph/camera/frame_source.zig: the CEU reaches a source only
//! through the interface, so a source swapped in is the one asked.
const std = @import("std");
const ra8 = @import("ra8");

const frame_source = ra8.chip.periph.ceu.camera.frame_source;

const Spy = struct {
    frames: u32 = 0,
    when: u64 = 0,
    shape: frame_source.Shape = .{ .width = 0, .lines = 0 },
    fills: u32 = 0,
    closed: bool = false,

    fn source(self: *Spy) frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(context: *anyopaque, when: u64, shape: frame_source.Shape) void {
        const self: *Spy = @ptrCast(@alignCast(context));
        self.frames += 1;
        self.when = when;
        self.shape = shape;
    }

    fn fill(context: *anyopaque, row: u32, column: u32, out: []u8) void {
        const self: *Spy = @ptrCast(@alignCast(context));
        self.fills += 1;
        @memset(out, @truncate(row * 16 + column));
    }

    fn close(context: *anyopaque) void {
        const self: *Spy = @ptrCast(@alignCast(context));
        self.closed = true;
    }
};

test "the interface forwards frame, fill and close to the source behind it" {
    var spy = Spy{};
    const source = spy.source();
    source.frame(1234, .{ .width = 8, .lines = 2 });
    try std.testing.expectEqual(@as(u32, 1), spy.frames);
    try std.testing.expectEqual(@as(u64, 1234), spy.when);
    try std.testing.expectEqual(@as(u32, 8), spy.shape.width);
    try std.testing.expectEqual(@as(u32, 2), spy.shape.lines);

    var line: [4]u8 = undefined;
    source.fill(1, 2, &line);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 18, 18, 18, 18 }, &line);
    try std.testing.expectEqual(@as(u32, 1), spy.fills);

    source.close();
    try std.testing.expect(spy.closed);
}
