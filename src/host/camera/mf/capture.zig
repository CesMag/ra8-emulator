//! A Media Foundation reader as the webcam source's capture (RA8EMU-501):
//! each read takes one sample from the open reader, flattens it, and copies
//! YUY2 through as YUYV or turns RGB32 (B, G, R, X, top-down) into RGB24,
//! so the same Webcam that decodes V4L2 frames decodes these. A gap,
//! the end of the stream, a failed call or a short buffer is a failed read,
//! which the source answers by holding the last frame.
const std = @import("std");
const abi = @import("abi.zig");
const com = @import("com.zig");
const mf_open = @import("open.zig");
const v4l2 = @import("../v4l2/abi.zig");
const negotiate = @import("../v4l2/negotiate.zig");
const source = @import("../webcam/input.zig");
const consent = @import("../webcam/consent.zig");

/// How many empty samples (stream ticks) one read waits through.
pub const gap_tries = 4;

pub const MfCapture = struct {
    allocator: std.mem.Allocator,
    reader: mf_open.Reader,
    name: [24]u8 = undefined,
    name_len: usize = 0,

    /// Takes the reader; closing the capture closes it.
    pub fn create(allocator: std.mem.Allocator, reader: mf_open.Reader) error{OutOfMemory}!*MfCapture {
        const self = try allocator.create(MfCapture);
        self.* = .{ .allocator = allocator, .reader = reader };
        return self;
    }

    /// Names the camera for the log lines and the source's detail.
    pub fn setName(self: *MfCapture, text: []const u8) void {
        self.name_len = @min(text.len, self.name.len);
        @memcpy(self.name[0..self.name_len], text[0..self.name_len]);
    }

    pub fn named(self: *const MfCapture) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn capture(self: *MfCapture) source.Capture {
        return .{ .ctx = self, .readFn = read, .closeFn = close };
    }

    /// The layout the bytes handed to Webcam have.
    pub fn agreed(self: *const MfCapture) negotiate.Agreed {
        const r = self.reader;
        const pixel: u32 = if (r.subtype == .yuy2) 2 else 3;
        const format = if (r.subtype == .yuy2) v4l2.pix_yuyv else v4l2.pix_rgb24;
        return .{ .width = r.width, .height = r.height, .pixelformat = format, .bytesperline = r.width * pixel, .sizeimage = r.width * pixel * r.height, .streaming = true };
    }

    fn read(ctx: *anyopaque, out: []u8) bool {
        const self: *MfCapture = @ptrCast(@alignCast(ctx));
        const sample = self.next() orelse return false;
        defer com.release(sample);
        var buffer: ?*anyopaque = null;
        if (!abi.succeeded(com.toContiguous(sample, &buffer)) or buffer == null) return false;
        defer com.release(buffer.?);
        var bytes: ?[*]u8 = null;
        var length: u32 = 0;
        if (!abi.succeeded(com.lock(buffer.?, &bytes, &length)) or bytes == null) return false;
        defer _ = com.unlock(buffer.?);
        return copy(self.reader.subtype, bytes.?[0..length], out);
    }

    /// The next real sample, waiting through a few gaps; null on an error or the end.
    fn next(self: *MfCapture) ?*anyopaque {
        for (0..gap_tries) |_| {
            var flags: u32 = 0;
            var sample: ?*anyopaque = null;
            if (!abi.succeeded(com.readSample(self.reader.reader, abi.first_video_stream, &flags, &sample))) return null;
            if (flags & abi.end_of_stream != 0) {
                if (sample) |s| com.release(s);
                return null;
            }
            if (sample) |s| return s;
        }
        return null;
    }

    fn close(ctx: *anyopaque) void {
        const self: *MfCapture = @ptrCast(@alignCast(ctx));
        self.reader.close();
        if (self.name_len > 0) consent.logStopStderr(self.named());
        self.allocator.destroy(self);
    }
};

/// Fills `out` from one locked frame; false when the frame is too short.
pub fn copy(subtype: mf_open.Subtype, frame: []const u8, out: []u8) bool {
    switch (subtype) {
        .yuy2 => {
            if (frame.len < out.len) return false;
            @memcpy(out, frame[0..out.len]);
        },
        .rgb32 => {
            const pixels = out.len / 3;
            if (frame.len < pixels * 4) return false;
            for (0..pixels) |i| {
                out[i * 3 + 0] = frame[i * 4 + 2];
                out[i * 3 + 1] = frame[i * 4 + 1];
                out[i * 3 + 2] = frame[i * 4 + 0];
            }
        },
    }
    return true;
}
