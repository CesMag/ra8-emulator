//! The slice of the Linux V4L2 ABI the webcam source uses (RA8EMU-506):
//! the capability and format structs and their ioctl numbers, laid out as
//! <linux/videodev2.h> does on the host. The ioctl numbers are built from
//! the struct sizes, so they follow the host's word size.

/// A FourCC pixel format code.
pub fn fourcc(code: *const [4]u8) u32 {
    return @as(u32, code[0]) | @as(u32, code[1]) << 8 | @as(u32, code[2]) << 16 | @as(u32, code[3]) << 24;
}

pub const pix_yuyv = fourcc("YUYV");
pub const pix_rgb565 = fourcc("RGBP");
pub const pix_rgb24 = fourcc("RGB3");

pub const buf_type_video_capture: u32 = 1;
pub const field_none: u32 = 1;

pub const cap_video_capture: u32 = 0x0000_0001;
pub const cap_readwrite: u32 = 0x0100_0000;
pub const cap_streaming: u32 = 0x0400_0000;
pub const cap_device_caps: u32 = 0x8000_0000;

/// struct v4l2_capability.
pub const Capability = extern struct {
    driver: [16]u8 = @splat(0),
    card: [32]u8 = @splat(0),
    bus_info: [32]u8 = @splat(0),
    version: u32 = 0,
    capabilities: u32 = 0,
    device_caps: u32 = 0,
    reserved: [3]u32 = @splat(0),

    /// The capabilities of this node: device_caps when the driver fills it.
    pub fn node(self: Capability) u32 {
        return if (self.capabilities & cap_device_caps != 0) self.device_caps else self.capabilities;
    }
};

/// struct v4l2_pix_format.
pub const PixFormat = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    pixelformat: u32 = 0,
    field: u32 = 0,
    bytesperline: u32 = 0,
    sizeimage: u32 = 0,
    colorspace: u32 = 0,
    priv: u32 = 0,
    flags: u32 = 0,
    ycbcr_enc: u32 = 0,
    quantization: u32 = 0,
    xfer_func: u32 = 0,
};

/// struct v4l2_format. The kernel's union holds pointers, so it is
/// word-aligned and 200 bytes long.
pub const Format = extern struct {
    type: u32 = buf_type_video_capture,
    fmt: extern union {
        pix: PixFormat,
        raw: [200]u8 align(@alignOf(usize)),
    } = .{ .raw = @splat(0) },
};

const ioc_write: u32 = 1;
const ioc_read: u32 = 2;

fn ioc(dir: u32, nr: u8, size: usize) u32 {
    return dir << 30 | @as(u32, @intCast(size)) << 16 | @as(u32, 'V') << 8 | nr;
}

pub const vidioc_querycap = ioc(ioc_read, 0, @sizeOf(Capability));
pub const vidioc_g_fmt = ioc(ioc_read | ioc_write, 4, @sizeOf(Format));
pub const vidioc_s_fmt = ioc(ioc_read | ioc_write, 5, @sizeOf(Format));

pub const memory_mmap: u32 = 1;

/// struct v4l2_requestbuffers.
pub const RequestBuffers = extern struct {
    count: u32 = 0,
    type: u32 = buf_type_video_capture,
    memory: u32 = memory_mmap,
    capabilities: u32 = 0,
    flags: u8 = 0,
    reserved: [3]u8 = @splat(0),
};

/// struct timeval as the kernel lays it out in a v4l2_buffer.
pub const TimeVal = extern struct { sec: isize = 0, usec: isize = 0 };

/// struct v4l2_buffer, single-planar.
pub const Buffer = extern struct {
    index: u32 = 0,
    type: u32 = buf_type_video_capture,
    bytesused: u32 = 0,
    flags: u32 = 0,
    field: u32 = 0,
    timestamp: TimeVal = .{},
    timecode: [4]u32 = @splat(0),
    sequence: u32 = 0,
    memory: u32 = memory_mmap,
    m: extern union { offset: u32, userptr: usize } = .{ .userptr = 0 },
    length: u32 = 0,
    reserved2: u32 = 0,
    request_fd: u32 = 0,
};

pub const vidioc_reqbufs = ioc(ioc_read | ioc_write, 8, @sizeOf(RequestBuffers));
pub const vidioc_querybuf = ioc(ioc_read | ioc_write, 9, @sizeOf(Buffer));
pub const vidioc_qbuf = ioc(ioc_read | ioc_write, 15, @sizeOf(Buffer));
pub const vidioc_dqbuf = ioc(ioc_read | ioc_write, 17, @sizeOf(Buffer));
pub const vidioc_streamon = ioc(ioc_write, 18, @sizeOf(u32));
pub const vidioc_streamoff = ioc(ioc_write, 19, @sizeOf(u32));
