//! A window that keeps stills (RA8EMU-500): it stands in front of another
//! platform, passes every event and frame through, and saves every
//! `every`-th presented frame as a numbered PNG (window_still.zig). It
//! works the same in front of the SDL window and the headless one, so a
//! run on a machine with no display still leaves the camera panel's
//! states on disk to view or diff.
const std = @import("std");
const raster = @import("ra8_render").raster;
const platform_mod = @import("platform.zig");
const window_still = @import("window_still.zig");

/// The directory `--window-stills` named, made if missing; null when the
/// run did not ask for stills.
pub fn openDir(io: std.Io, path: ?[]const u8) !?std.Io.Dir {
    const target = path orelse return null;
    return try std.Io.Dir.cwd().createDirPathOpen(io, target, .{});
}

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    inner: platform_mod.Platform,
    io: std.Io,
    dir: std.Io.Dir,
    /// Stills are named `stem-NNNN.png`.
    stem: []const u8,
    /// Keep frame 0, then every `every`-th frame; 0 is treated as 1.
    every: u32 = 1,
    /// Frames presented so far.
    frames: u32 = 0,
    /// Stills written so far; the next one's number.
    saved: u32 = 0,

    pub fn platform(self: *Recorder) platform_mod.Platform {
        return .{ .ctx = self, .vtable = &.{ .poll = poll, .size = size, .scale = scale, .present = present } };
    }

    /// Whether frame `index` is one this recorder keeps.
    pub fn keeps(self: Recorder, index: u32) bool {
        return index % @max(self.every, 1) == 0;
    }

    fn poll(ctx: *anyopaque) ?platform_mod.Event {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.inner.poll();
    }

    fn size(ctx: *anyopaque) platform_mod.Size {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.inner.size();
    }

    fn scale(ctx: *anyopaque) f32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.inner.scale();
    }

    fn present(ctx: *anyopaque, frame: *const raster.Framebuffer) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try self.inner.present(frame);
        defer self.frames += 1;
        if (!self.keeps(self.frames)) return;
        var buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const file_name = try window_still.name(&buffer, self.stem, self.saved);
        try window_still.save(self.allocator, self.io, self.dir, file_name, frame.*);
        self.saved += 1;
    }
};
