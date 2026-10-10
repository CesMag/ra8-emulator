//! Display operations exposed by a live session (RA8EMU-556).
const std = @import("std");

pub const Error = error{ NoDisplay, BadFrameShape };

/// An owned native-resolution grayscale panel frame and its virtual capture time.
pub const Frame = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    virtual_ns: u64,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// Encode the grayscale plane as a lossless P6 PPM with equal RGB channels.
    pub fn ppm(self: Frame, allocator: std.mem.Allocator) ![]u8 {
        const count = std.math.mul(usize, self.width, self.height) catch return Error.BadFrameShape;
        if (self.width == 0 or self.height == 0 or self.pixels.len != count) return Error.BadFrameShape;
        const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ self.width, self.height });
        defer allocator.free(header);
        const body_len = std.math.mul(usize, self.pixels.len, 3) catch return Error.BadFrameShape;
        const output = try allocator.alloc(u8, header.len + body_len);
        errdefer allocator.free(output);
        @memcpy(output[0..header.len], header);
        var at = header.len;
        for (self.pixels) |gray| {
            output[at] = gray;
            output[at + 1] = gray;
            output[at + 2] = gray;
            at += 3;
        }
        return output;
    }
};

/// The gray a panel pixel shows as: its ARGB word's luma, alpha ignored.
pub fn grayscale(argb: u32) u8 {
    const red = (argb >> 16) & 0xFF;
    const green = (argb >> 8) & 0xFF;
    const blue = argb & 0xFF;
    return @intCast((red * 299 + green * 587 + blue * 114 + 500) / 1000);
}

/// Board-specific code supplies virtual-time progress and panel capture.
pub const Display = struct {
    context: *anyopaque,
    waitSettledFn: *const fn (*anyopaque, timeout_ns: u64) anyerror!void,
    frameFn: *const fn (*anyopaque, allocator: std.mem.Allocator) anyerror!Frame,
    /// Starts or stops watching the panel for a viewer that wants every
    /// frame it shows. Null for a display with nothing to arm.
    watchFn: ?*const fn (*anyopaque, on: bool) void = null,

    pub fn waitSettled(self: Display, timeout_ns: u64) anyerror!void {
        return self.waitSettledFn(self.context, timeout_ns);
    }

    pub fn frame(self: Display, allocator: std.mem.Allocator) anyerror!Frame {
        return self.frameFn(self.context, allocator);
    }

    /// A viewer wants every frame the panel shows from now on (`on`), or
    /// one that did no longer does.
    pub fn watch(self: Display, on: bool) void {
        const set = self.watchFn orelse return;
        set(self.context, on);
    }
};
