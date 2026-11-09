//! Platform decorator intercepting poll and present for scripting and video capture (RA8EMU-1120).
//! Everything else it passes to the window behind it, so the shell drives
//! the same window whether a script or a recording is on or not. A frame
//! the window draws itself (`show`) is a frame like a presented one; while
//! a recording is on every frame is rasterized instead, so it can be kept.
const std = @import("std");
const platform_mod = @import("../platform.zig");
const raster = @import("ra8_render").raster;
const draw_list = @import("ra8_render").draw_list;
const runner_mod = @import("../script/runner.zig");
const writer_mod = @import("writer.zig");
const cursor_mod = @import("cursor.zig");
const shell_loop = @import("../shell/loop.zig");
const shell_run = @import("../shell/run.zig");

const Framebuffer = raster.Framebuffer;
const Platform = platform_mod.Platform;
const Event = platform_mod.Event;
const Size = platform_mod.Size;
const Appearance = platform_mod.Appearance;

pub const default_fps: u32 = 30;
pub const nominal_hz: u64 = 60;

pub const Capture = struct {
    allocator: std.mem.Allocator,
    inner: Platform,
    runner: ?*runner_mod.Runner = null,
    writer: ?*writer_mod.Writer = null,
    shell: ?*const shell_loop.Shell = null,
    show_cursor: bool = false,
    fps: u32 = default_fps,

    frame_counter: u32 = 0,
    polled_this_frame: bool = false,
    last_video_frame: ?u32 = null,
    overlay_frame: ?Framebuffer = null,

    pub fn init(allocator: std.mem.Allocator, inner: Platform) Capture {
        return .{
            .allocator = allocator,
            .inner = inner,
        };
    }

    pub fn deinit(self: *Capture) void {
        if (self.overlay_frame) |*of| of.deinit(self.allocator);
    }

    pub fn bind(self: *Capture, shell: *const shell_loop.Shell) void {
        self.shell = shell;
    }

    pub fn unbind(self: *Capture) void {
        self.shell = null;
    }

    pub fn platform(self: *Capture) Platform {
        return .{
            .ctx = self,
            .vtable = &.{
                .poll = poll,
                .size = size,
                .scale = scale,
                .present = present,
                .show = show,
                .interval = interval,
                .set_vsync = setVsync,
                .refresh = refresh,
                .appearance = appearance,
                .focus = focus,
                .open_image = openImage,
                .open_profile = openProfile,
                .title = title,
                .toggle_fullscreen = toggleFullscreen,
                .fullscreen = fullscreen,
                .visible = visible,
                .position = position,
            },
        };
    }

    fn poll(ctx: *anyopaque) ?Event {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (!self.polled_this_frame) {
            self.polled_this_frame = true;
            if (self.runner) |runner| {
                const s = self.inner.size();
                const w: i32 = @intCast(s.width);
                const h: i32 = @intCast(s.height);
                const wall_ns = if (self.shell) |sh| sh.now() else 0;
                const virtual_ns = if (self.shell) |sh| sh.boardNow() else @as(u64, self.frame_counter) * shell_run.frame_ns;
                if (self.shell) |sh| {
                    runner.advanceWithVirtual(&sh.layout, w, h, sh.board, wall_ns, virtual_ns, self.frame_counter) catch {};
                }
            }
        }

        if (self.runner) |runner| {
            if (runner.poll()) |ev| return ev;
        }
        return self.inner.poll();
    }

    fn size(ctx: *anyopaque) Size {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.size();
    }

    fn scale(ctx: *anyopaque) f32 {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.scale();
    }

    /// One frame is on screen: the script's next frame may poll.
    fn shown(self: *Capture) void {
        self.frame_counter += 1;
        self.polled_this_frame = false;
    }

    fn present(ctx: *anyopaque, frame: *const Framebuffer) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        defer self.shown();

        if (self.writer) |writer| {
            const video_idx = @as(u32, @intCast(@divTrunc(@as(u64, self.frame_counter) * self.fps, nominal_hz)));
            if (self.last_video_frame == null or video_idx > self.last_video_frame.?) {
                self.last_video_frame = video_idx;
                const virtual_ns = @as(u64, self.frame_counter) * shell_run.frame_ns;

                if (self.show_cursor and self.runner != null) {
                    try self.ensureOverlay(frame.width, frame.height);
                    if (self.overlay_frame) |*of| {
                        @memcpy(of.pixels, frame.pixels);
                        const runner = self.runner.?;
                        cursor_mod.draw(of, runner.cursor_x, runner.cursor_y, runner.ripples.items, self.frame_counter);
                        try writer.record(of, virtual_ns);
                    }
                } else {
                    try writer.record(frame, virtual_ns);
                }
            }
        }

        return self.inner.present(frame);
    }

    fn ensureOverlay(self: *Capture, width: u32, height: u32) !void {
        if (self.overlay_frame) |of| {
            if (of.width == width and of.height == height) return;
            self.overlay_frame.?.deinit(self.allocator);
            self.overlay_frame = null;
        }
        self.overlay_frame = try Framebuffer.init(self.allocator, width, height);
    }

    /// A recording needs the frame's pixels, so it takes the rasterized
    /// path through `present`; otherwise the window may draw the list itself.
    fn show(ctx: *anyopaque, list: *const draw_list.DrawList, atlas: ?raster.Atlas) anyerror!bool {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.writer != null) return false;
        const drew = try self.inner.show(list, atlas);
        if (drew) self.shown();
        return drew;
    }

    fn title(ctx: *anyopaque, text: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.inner.title(text);
    }

    fn toggleFullscreen(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.inner.toggleFullscreen();
    }

    fn fullscreen(ctx: *anyopaque) bool {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.fullscreen();
    }

    fn visible(ctx: *anyopaque) bool {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.visible();
    }

    fn position(ctx: *anyopaque) ?platform_mod.Pos {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.position();
    }

    fn interval(ctx: *anyopaque) u64 {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.interval();
    }

    fn setVsync(ctx: *anyopaque, on: bool) bool {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.setVsync(on);
    }

    fn refresh(ctx: *anyopaque) u32 {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.refresh();
    }

    fn appearance(ctx: *anyopaque) Appearance {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.appearance();
    }

    fn focus(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.inner.focus();
    }

    fn openImage(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        _ = self.inner.openImage();
    }

    fn openProfile(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        _ = self.inner.openProfile();
    }
};
