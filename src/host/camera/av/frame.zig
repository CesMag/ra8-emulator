//! Frames off the macOS capture delegate (RA8EMU-502). AVFoundation hands
//! the delegate a CVPixelBuffer on its own dispatch queue; the delegate
//! locks it and puts the bytes here, and the emulator's read takes the
//! newest one. 2vuy (U, Y0, V, Y1) is swizzled to YUYV and BGRA turned into
//! RGB24, so the webcam input that decodes V4L2 and Media Foundation frames
//! decodes these too. Rows honour the buffer's bytes-per-row padding.
const std = @import("std");
const v4l2 = @import("../v4l2/abi.zig");

/// CoreVideo OSTypes the capture asks for.
pub const cv_2vuy: u32 = 0x3276_7579; // '2vuy', kCVPixelFormatType_422YpCbCr8
pub const cv_bgra: u32 = 0x4247_5241; // 'BGRA', kCVPixelFormatType_32BGRA

pub const Pixel = enum { uyvy, bgra };

pub fn pixelOf(os_type: u32) ?Pixel {
    if (os_type == cv_2vuy) return .uyvy;
    if (os_type == cv_bgra) return .bgra;
    return null;
}

/// The FourCC the webcam input decodes for what this pixel becomes.
pub fn pixelformat(pixel: Pixel) u32 {
    return switch (pixel) {
        .uyvy => v4l2.pix_yuyv,
        .bgra => v4l2.pix_rgb24,
    };
}

fn inBytes(pixel: Pixel, width: usize) usize {
    return switch (pixel) {
        .uyvy => width * 2,
        .bgra => width * 4,
    };
}

pub fn outBytes(pixel: Pixel, width: usize) usize {
    return switch (pixel) {
        .uyvy => width * 2,
        .bgra => width * 3,
    };
}

/// Copies one locked buffer into `out` as YUYV or RGB24. False when the
/// buffer or `out` is too short or the geometry can't be a frame.
pub fn copy(pixel: Pixel, src: []const u8, stride: usize, width: usize, height: usize, out: []u8) bool {
    const in_row = inBytes(pixel, width);
    const out_row = outBytes(pixel, width);
    if (width == 0 or height == 0 or stride < in_row) return false;
    if (pixel == .uyvy and width % 2 != 0) return false;
    if (src.len < stride * (height - 1) + in_row or out.len < out_row * height) return false;
    for (0..height) |y| {
        const row = src[y * stride ..][0..in_row];
        const dst = out[y * out_row ..][0..out_row];
        switch (pixel) {
            .uyvy => swizzle(row, dst),
            .bgra => toRgb(row, dst),
        }
    }
    return true;
}

fn swizzle(row: []const u8, dst: []u8) void {
    var i: usize = 0;
    while (i < row.len) : (i += 4) {
        dst[i] = row[i + 1];
        dst[i + 1] = row[i];
        dst[i + 2] = row[i + 3];
        dst[i + 3] = row[i + 2];
    }
}

fn toRgb(row: []const u8, dst: []u8) void {
    for (0..row.len / 4) |p| {
        dst[p * 3] = row[p * 4 + 2];
        dst[p * 3 + 1] = row[p * 4 + 1];
        dst[p * 3 + 2] = row[p * 4];
    }
}

/// The newest converted frame, handed from the delegate's queue to the
/// emulator's read through a triple buffer: the delegate fills `back`, the
/// read copies from `front`, and the third slot sits in `middle` with a
/// fresh bit. One writer and one reader, no lock. A buffer whose size isn't
/// the agreed one is dropped, and a failed copy never reaches the reader.
pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    pixel: Pixel,
    width: usize,
    height: usize,
    slots: [3][]u8,
    back: u8 = 0,
    front: u8 = 1,
    middle: std.atomic.Value(u8) = .init(2),

    const fresh: u8 = 0x4;
    const index: u8 = 0x3;

    pub fn init(allocator: std.mem.Allocator, pixel: Pixel, width: usize, height: usize) error{OutOfMemory}!Mailbox {
        const bytes = outBytes(pixel, width) * height;
        const block = try allocator.alloc(u8, bytes * 3);
        return .{
            .allocator = allocator,
            .pixel = pixel,
            .width = width,
            .height = height,
            .slots = .{ block[0..bytes], block[bytes..][0..bytes], block[2 * bytes ..][0..bytes] },
        };
    }

    pub fn deinit(self: *Mailbox) void {
        self.allocator.free(self.slots[0].ptr[0 .. self.slots[0].len * 3]);
    }

    /// From the delegate: keep this buffer as the newest frame.
    pub fn put(self: *Mailbox, src: []const u8, stride: usize, width: usize, height: usize) bool {
        if (width != self.width or height != self.height) return false;
        if (!copy(self.pixel, src, stride, width, height, self.slots[self.back])) return false;
        self.back = self.middle.swap(self.back | fresh, .acq_rel) & index;
        return true;
    }

    /// From the read: the newest frame once; false until another arrives.
    pub fn take(self: *Mailbox, out: []u8) bool {
        if (out.len < self.slots[0].len) return false;
        if (self.middle.load(.acquire) & fresh == 0) return false;
        self.front = self.middle.swap(self.front, .acq_rel) & index;
        @memcpy(out[0..self.slots[0].len], self.slots[self.front]);
        return true;
    }
};
