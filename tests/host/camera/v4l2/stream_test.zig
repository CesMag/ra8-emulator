//! Covers src/host/camera/v4l2_stream.zig against a mock streaming
//! driver, and the streaming ABI sizes on a 64-bit host.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.host.camera;
const abi = webcam.v4l2;
const vs = webcam.stream;

const frame_len = 8;

/// A driver with `granted` buffers of `frame_len` bytes in one backing
/// array; each dequeue fills the oldest queued buffer with its sequence.
const Driver = struct {
    granted: u32 = 4,
    backing: [vs.buffer_count * frame_len]u8 = @splat(0),
    queued: [vs.buffer_count]bool = @splat(false),
    streaming: bool = false,
    sequence: u8 = 0,
    short: bool = false,
    mapped: u32 = 0,
    released: bool = false,
    fail_map_at: ?u32 = null,

    fn ioctl(ctx: *anyopaque, request: u32, arg: *anyopaque) u16 {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        if (request == abi.vidioc_reqbufs) {
            const r: *abi.RequestBuffers = @ptrCast(@alignCast(arg));
            if (r.count == 0) self.released = true else r.count = self.granted;
        } else if (request == abi.vidioc_querybuf) {
            const b: *abi.Buffer = @ptrCast(@alignCast(arg));
            b.m = .{ .offset = b.index * frame_len };
            b.length = frame_len;
        } else if (request == abi.vidioc_qbuf) {
            const b: *abi.Buffer = @ptrCast(@alignCast(arg));
            self.queued[b.index] = true;
        } else if (request == abi.vidioc_dqbuf) {
            return self.dequeue(@ptrCast(@alignCast(arg)));
        } else if (request == abi.vidioc_streamon) {
            self.streaming = true;
        } else if (request == abi.vidioc_streamoff) {
            self.streaming = false;
        } else return 25;
        return 0;
    }

    fn dequeue(self: *Driver, b: *abi.Buffer) u16 {
        if (!self.streaming) return 22;
        const index = std.mem.indexOfScalar(bool, &self.queued, true) orelse return 11;
        self.queued[index] = false;
        self.sequence += 1;
        @memset(self.backing[index * frame_len ..][0..frame_len], self.sequence);
        b.index = @intCast(index);
        b.bytesused = if (self.short) frame_len / 2 else frame_len;
        return 0;
    }

    fn map(ctx: *anyopaque, offset: u32, length: u32) ?[]u8 {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        if (self.fail_map_at) |at| if (offset / frame_len == at) return null;
        self.mapped += 1;
        return self.backing[offset..][0..length];
    }

    fn unmap(ctx: *anyopaque, memory: []u8) void {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        _ = memory;
        self.mapped -= 1;
    }

    fn device(self: *Driver) webcam.negotiate.Device {
        return .{ .ctx = self, .ioctlFn = ioctl };
    }

    fn mapper(self: *Driver) vs.Mapper {
        return .{ .ctx = self, .mapFn = map, .unmapFn = unmap };
    }
};

test "the streaming ABI matches videodev2.h on a 64-bit host" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(abi.RequestBuffers));
    try std.testing.expectEqual(@as(u32, 0xC0145608), abi.vidioc_reqbufs);
    try std.testing.expectEqual(@as(u32, 0x40045612), abi.vidioc_streamon);
    try std.testing.expectEqual(@as(u32, 0x40045613), abi.vidioc_streamoff);
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 88), @sizeOf(abi.Buffer));
        try std.testing.expectEqual(@as(usize, 64), @offsetOf(abi.Buffer, "m"));
        try std.testing.expectEqual(@as(u32, 0xC0585609), abi.vidioc_querybuf);
        try std.testing.expectEqual(@as(u32, 0xC058560F), abi.vidioc_qbuf);
        try std.testing.expectEqual(@as(u32, 0xC0585611), abi.vidioc_dqbuf);
    }
}

test "frames come out in order and every buffer goes back to the driver" {
    var driver: Driver = .{};
    var stream = try vs.Stream.start(driver.device(), driver.mapper());
    try std.testing.expect(driver.streaming);
    try std.testing.expectEqual(@as(u32, 4), driver.mapped);
    var out: [frame_len]u8 = undefined;
    for (1..10) |n| {
        try std.testing.expect(stream.readFrame(&out));
        try std.testing.expectEqual(@as(u8, @intCast(n)), out[0]);
    }
    stream.stop();
    try std.testing.expect(!driver.streaming);
    try std.testing.expectEqual(@as(u32, 0), driver.mapped);
    try std.testing.expect(driver.released);
}

test "a short frame is not handed on, and the stream keeps going" {
    var driver: Driver = .{ .short = true };
    var stream = try vs.Stream.start(driver.device(), driver.mapper());
    defer stream.stop();
    var out = @as([frame_len]u8, @splat(0xEE));
    try std.testing.expect(!stream.readFrame(&out));
    try std.testing.expectEqual(@as(u8, 0xEE), out[0]);
    driver.short = false;
    try std.testing.expect(stream.readFrame(&out));
}

test "fewer buffers than asked are used; none at all is refused" {
    var two: Driver = .{ .granted = 2 };
    var stream = try vs.Stream.start(two.device(), two.mapper());
    try std.testing.expectEqual(@as(u32, 2), stream.count);
    stream.stop();
    var none: Driver = .{ .granted = 0 };
    try std.testing.expectError(error.NoBuffers, vs.Stream.start(none.device(), none.mapper()));
}

test "a mapping that fails part way unmaps what was mapped" {
    var driver: Driver = .{ .fail_map_at = 2 };
    try std.testing.expectError(error.MapFailed, vs.Stream.start(driver.device(), driver.mapper()));
    try std.testing.expectEqual(@as(u32, 0), driver.mapped);
    try std.testing.expect(driver.released);
}
