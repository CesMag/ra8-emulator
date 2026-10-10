//! A FrameSource over one native RGB frame: the bytes come out converted
//! to the firmware's pixel format and scaled to the size it programmed.
//! Decoding sources hold one of these and swap `input` as their input
//! moves; the CEU only ever sees destination bytes.
const frame_source = @import("ra8_chip").periph.frame_source;
const convert = @import("pixel_convert.zig");

pub const Converted = struct {
    input: convert.Frame,
    format: convert.Format,
    shape: frame_source.Shape = .{ .width = 0, .lines = 0 },

    pub fn source(self: *Converted) frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(context: *anyopaque, _: u64, shape: frame_source.Shape) void {
        const self: *Converted = @ptrCast(@alignCast(context));
        self.shape = shape;
    }

    fn fill(context: *anyopaque, row: u32, column: u32, out: []u8) void {
        const self: *Converted = @ptrCast(@alignCast(context));
        const shape = self.shape;
        for (out, 0..) |*byte, index| {
            const at = column + @as(u32, @intCast(index));
            byte.* = convert.byteAt(self.input, self.format, row, at, shape.width, shape.lines);
        }
    }

    fn close(_: *anyopaque) void {}
};
