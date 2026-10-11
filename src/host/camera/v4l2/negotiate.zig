//! Agrees a capture format with a V4L2 device (RA8EMU-506).
//!
//! The device is reached through a small ioctl seam so the negotiation runs
//! against a mock in host tests and against a real /dev/videoN at run time.
//! A node must capture video and offer streaming or read I/O. The webcam is
//! asked for YUYV at the size the sensor is programmed for, then RGB565;
//! the driver may adjust the size, and the format it settles on is what
//! the source converts from.
const abi = @import("abi.zig");

/// One ioctl on an open device: 0 on success, otherwise the errno.
pub const Device = struct {
    ctx: *anyopaque,
    ioctlFn: *const fn (ctx: *anyopaque, request: u32, arg: *anyopaque) u16,

    pub fn ioctl(self: Device, request: u32, arg: *anyopaque) u16 {
        return self.ioctlFn(self.ctx, request, arg);
    }
};

pub const Error = error{ QueryFailed, NotCapture, NoIo, NoUsableFormat };

/// Pixel formats the source can convert, most preferred first.
pub const preferred = [_]u32{ abi.pix_yuyv, abi.pix_rgb565 };

/// What the device agreed to deliver.
pub const Agreed = struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    bytesperline: u32,
    sizeimage: u32,
    streaming: bool,
    /// The node takes read() I/O, which the first webcam source uses.
    read_io: bool = false,
};

/// Checks the node can capture, then sets the first preferred format the
/// driver accepts, asking for `width` x `height`.
pub fn negotiate(dev: Device, width: u32, height: u32) Error!Agreed {
    var cap: abi.Capability = .{};
    if (dev.ioctl(abi.vidioc_querycap, &cap) != 0) return error.QueryFailed;
    const node = cap.node();
    if (node & abi.cap_video_capture == 0) return error.NotCapture;
    const streaming = node & abi.cap_streaming != 0;
    if (!streaming and node & abi.cap_readwrite == 0) return error.NoIo;
    for (preferred) |pixelformat| {
        var fmt: abi.Format = .{};
        fmt.fmt.pix = .{ .width = width, .height = height, .pixelformat = pixelformat, .field = abi.field_none };
        if (dev.ioctl(abi.vidioc_s_fmt, &fmt) != 0) continue;
        const pix = fmt.fmt.pix;
        if (pix.pixelformat != pixelformat or pix.width == 0 or pix.height == 0) continue;
        return .{
            .width = pix.width,
            .height = pix.height,
            .pixelformat = pix.pixelformat,
            .bytesperline = pix.bytesperline,
            .sizeimage = pix.sizeimage,
            .streaming = streaming,
            .read_io = node & abi.cap_readwrite != 0,
        };
    }
    return error.NoUsableFormat;
}
