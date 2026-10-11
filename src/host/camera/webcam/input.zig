//! The host webcam as the camera (RA8EMU-506): each armed capture reads
//! one frame from the negotiated V4L2 node, decodes YUYV or RGB565 to RGB
//! and returns it from picture(), which the camera's hosted source turns
//! into the format and size the firmware programmed (RA8EMU-1011).
//!
//! Frames arrive through a capture seam: the V4L2 fd at run time, a fake
//! in host tests. Rows are read at the driver's bytesperline, which may be
//! padded past width * 2. A failed read keeps the last frame, says so once
//! and never stops the run; before the first frame the capture is black.
const std = @import("std");
const decoded = @import("../decoded_image.zig");
const raw = @import("../pipe/frame.zig");
const abi = @import("../v4l2/abi.zig");
const negotiate = @import("../v4l2/negotiate.zig");

/// One frame's bytes from the device: true when `out` was filled.
pub const Capture = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, out: []u8) bool,
    closeFn: *const fn (ctx: *anyopaque) void,
};

pub const OpenError = error{ UnsupportedFormat, BadGeometry, OutOfMemory } || decoded.DecodeError;

/// The pipe decoder's name for a negotiated FourCC.
pub fn rawFormat(pixelformat: u32) ?raw.Format {
    if (pixelformat == abi.pix_yuyv) return .yuyv;
    if (pixelformat == abi.pix_rgb565) return .rgb565;
    if (pixelformat == abi.pix_rgb24) return .rgb24;
    return null;
}

pub const Webcam = struct {
    allocator: std.mem.Allocator,
    capture: Capture,
    agreed: negotiate.Agreed,
    format: raw.Format,
    device_path: []const u8,
    bytes: []u8,
    image: decoded.Image,
    frames: u64 = 0,
    failed: bool = false,

    pub fn open(allocator: std.mem.Allocator, capture: Capture, agreed: negotiate.Agreed, device_path: []const u8) OpenError!*Webcam {
        const format = rawFormat(agreed.pixelformat) orelse return error.UnsupportedFormat;
        const row = @as(usize, agreed.width) * format.bytesPerPixel();
        if (agreed.bytesperline < row or agreed.width % 2 != 0) return error.BadGeometry;
        const image = try decoded.Image.alloc(allocator, agreed.width, agreed.height);
        errdefer image.deinit(allocator);
        const bytes = try allocator.alloc(u8, @as(usize, agreed.bytesperline) * agreed.height);
        errdefer allocator.free(bytes);
        const self = try allocator.create(Webcam);
        self.* = .{
            .allocator = allocator,
            .capture = capture,
            .agreed = agreed,
            .format = format,
            .device_path = device_path,
            .bytes = bytes,
            .image = image,
        };
        @memset(image.pixels, 0);
        return self;
    }

    /// Read and decode one frame, keeping the last one on a failed read.
    pub fn pull(self: *Webcam) void {
        if (!self.capture.readFn(self.capture.ctx, self.bytes)) {
            if (!self.failed) std.debug.print("camera: webcam read failed on {s}; holding the last frame\n", .{self.device_path});
            self.failed = true;
            return;
        }
        const width = self.agreed.width;
        const stride = self.agreed.bytesperline;
        const used = @as(usize, width) * self.format.bytesPerPixel();
        const row = width * decoded.Image.bytes_per_pixel;
        for (0..self.agreed.height) |y| {
            const line = self.bytes[y * stride ..][0..used];
            raw.toRgb(self.format, line, self.image.pixels[y * row ..][0..row]);
        }
        self.frames += 1;
    }

    /// The frame at a capture: read one from the device, or keep the last.
    pub fn picture(self: *Webcam, _: u64) decoded.Image {
        self.pull();
        return self.image;
    }

    pub fn close(self: *Webcam) void {
        const allocator = self.allocator;
        self.capture.closeFn(self.capture.ctx);
        allocator.free(self.bytes);
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};
