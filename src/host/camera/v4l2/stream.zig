//! Memory-mapped V4L2 capture (RA8EMU-506), for the many UVC webcams that
//! offer no read() I/O. A few driver buffers are requested, mapped and
//! queued, then streaming starts; each frame dequeues the next filled
//! buffer, copies it out and queues it again. Stopping turns the stream
//! off, unmaps and releases the buffers.
//!
//! The device and the mapping both go through seams, so host tests drive
//! the whole sequence against a mock driver.
const abi = @import("abi.zig");
const negotiate = @import("negotiate.zig");

/// How many buffers the stream asks the driver for.
pub const buffer_count = 4;

/// Maps and unmaps one driver buffer.
pub const Mapper = struct {
    ctx: *anyopaque,
    mapFn: *const fn (ctx: *anyopaque, offset: u32, length: u32) ?[]u8,
    unmapFn: *const fn (ctx: *anyopaque, memory: []u8) void,
};

pub const Error = error{ RequestFailed, NoBuffers, QueryFailed, MapFailed, QueueFailed, StreamOnFailed };

pub const Stream = struct {
    dev: negotiate.Device,
    mapper: Mapper,
    maps: [buffer_count][]u8 = undefined,
    count: u32 = 0,

    /// Requests, maps and queues the buffers, then starts streaming.
    pub fn start(dev: negotiate.Device, mapper: Mapper) Error!Stream {
        var self: Stream = .{ .dev = dev, .mapper = mapper };
        var request: abi.RequestBuffers = .{ .count = buffer_count };
        if (dev.ioctl(abi.vidioc_reqbufs, &request) != 0) return error.RequestFailed;
        if (request.count == 0) return error.NoBuffers;
        errdefer self.release();
        const count = @min(request.count, buffer_count);
        for (0..count) |index| {
            var buffer: abi.Buffer = .{ .index = @intCast(index) };
            if (dev.ioctl(abi.vidioc_querybuf, &buffer) != 0) return error.QueryFailed;
            self.maps[index] = mapper.mapFn(mapper.ctx, buffer.m.offset, buffer.length) orelse return error.MapFailed;
            self.count += 1;
            if (dev.ioctl(abi.vidioc_qbuf, &buffer) != 0) return error.QueueFailed;
        }
        var kind: u32 = abi.buf_type_video_capture;
        if (dev.ioctl(abi.vidioc_streamon, &kind) != 0) return error.StreamOnFailed;
        return self;
    }

    /// Copies the next filled frame into `out`; false when none came or
    /// it was shorter than `out`. The buffer is queued again either way.
    pub fn readFrame(self: *Stream, out: []u8) bool {
        var buffer: abi.Buffer = .{};
        if (self.dev.ioctl(abi.vidioc_dqbuf, &buffer) != 0) return false;
        if (buffer.index >= self.count) return false;
        const filled = self.maps[buffer.index][0..@min(buffer.bytesused, self.maps[buffer.index].len)];
        const whole = filled.len >= out.len;
        if (whole) @memcpy(out, filled[0..out.len]);
        _ = self.dev.ioctl(abi.vidioc_qbuf, &buffer);
        return whole;
    }

    /// Stops streaming and gives the buffers back.
    pub fn stop(self: *Stream) void {
        var kind: u32 = abi.buf_type_video_capture;
        _ = self.dev.ioctl(abi.vidioc_streamoff, &kind);
        self.release();
    }

    fn release(self: *Stream) void {
        for (self.maps[0..self.count]) |memory| self.mapper.unmapFn(self.mapper.ctx, memory);
        self.count = 0;
        var request: abi.RequestBuffers = .{ .count = 0 };
        _ = self.dev.ioctl(abi.vidioc_reqbufs, &request);
    }
};
