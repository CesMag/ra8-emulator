//! A camera fed by a host input (RA8EMU-1011): a still picture, a clip, a
//! raw pipe or a webcam that the application opened from ra8_host. The input
//! hands over packed R, G, B bytes, three a pixel, and this wraps it as the
//! FrameSource the CEU reads: converted to the format the firmware last
//! wrote into the OV5640's FORMAT CONTROL register and scaled to the size it
//! programmed. The camera never opens a host file or device itself.
const std = @import("std");
const frame_source = @import("ra8_chip").periph.frame_source;
const convert = @import("pixel_convert.zig");
const converted = @import("converted_source.zig");
const gradient = @import("ra8_chip").periph.gradient_source;

/// OV5640 FORMAT CONTROL (0x4300): bits 7:4 pick the output format. 0x6 is
/// RGB565. 0x3 is YUV422, which the camera example writes (0x30), and the
/// model reads every other value as YUV422 too, the only other format the
/// converter produces.
pub fn formatFor(control: u8) convert.Format {
    return if (control >> 4 == 0x6) .rgb565 else .yuv422;
}

/// The FrameSource for a host input the application opened, or the
/// gradient when there is none (`input` is null). `input` also has
/// `label()` and `detail()`, which the report prints. The source owns the
/// input, and on an error this closes it.
pub fn wrap(allocator: std.mem.Allocator, input: anytype, format_control: *const u8) !frame_source.FrameSource {
    const opened = input orelse return gradient.source();
    errdefer opened.close();
    return Hosted(@TypeOf(opened.*)).open(allocator, opened, format_control, opened.label(), opened.detail());
}

/// The FrameSource over `Input`: a host object with `picture(self, when)`,
/// which returns a value with `width`, `height` and RGB888 `pixels` for a
/// capture armed at `when` emulated ns, and `close(self)`.
pub fn Hosted(comptime Input: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        input: *Input,
        converted: converted.Converted,
        /// The sensor's FORMAT CONTROL byte, read again at every capture.
        format_control: *const u8,

        /// The source owns `input` from here on, and closing it closes the
        /// input. On an error the caller still owns `input`.
        pub fn open(allocator: std.mem.Allocator, input: *Input, format_control: *const u8, label: []const u8, detail: []const u8) !frame_source.FrameSource {
            const self = try allocator.create(Self);
            // frame() reads the sensor register before each capture, on the
            // engine thread; opening never touches the board (RA8EMU-227).
            self.* = .{
                .allocator = allocator,
                .input = input,
                .converted = .{ .input = .{ .width = 0, .height = 0, .pixels = &.{} }, .format = .yuv422 },
                .format_control = format_control,
            };
            return .{ .context = self, .vtable = &vtable, .label = label, .detail = detail };
        }

        const vtable = frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

        fn frame(context: *anyopaque, when: u64, shape: frame_source.Shape) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const picture = self.input.picture(when);
            self.converted.input = .{ .width = picture.width, .height = picture.height, .pixels = picture.pixels };
            self.converted.format = formatFor(self.format_control.*);
            self.converted.source().frame(when, shape);
        }

        fn fill(context: *anyopaque, row: u32, column: u32, out: []u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.converted.source().fill(row, column, out);
        }

        fn close(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const allocator = self.allocator;
            self.input.close();
            allocator.destroy(self);
        }
    };
}
