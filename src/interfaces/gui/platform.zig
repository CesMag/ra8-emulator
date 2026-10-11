//! The window the GUI draws into (RA8EMU-617, ADR 0001 in the knowledge base, RA8EMU-A-8):
//! input events in, an RGBA framebuffer out. SDL3 is one backend
//! (RA8EMU-616); headless.zig is another, for tests and the board's
//! golden images. Nothing above this seam knows which one it has.
const draw_list = @import("ra8_render").draw_list;
const raster = @import("ra8_render").raster;

pub const Size = struct { width: u32, height: u32 };

/// Text the window typed (SDL text input: shifted and composed
/// characters), first bytes of its UTF-8 kept.
pub const Text = struct {
    bytes: [8]u8 = undefined,
    len: u8 = 0,

    pub fn of(utf8: []const u8) Text {
        var text = Text{};
        const count = @min(utf8.len, text.bytes.len);
        @memcpy(text.bytes[0..count], utf8[0..count]);
        text.len = @intCast(count);
        return text;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Whether the OS is set to a light or dark appearance (RA8EMU-962).
/// Unknown when the backend or the desktop gives no answer.
pub const Appearance = enum { unknown, light, dark };

pub const Event = union(enum) {
    quit,
    /// The OS appearance changed; read it again with `appearance`.
    appearance,
    resize: Size,
    /// The window was uncovered and must be drawn again.
    expose,
    key: struct {
        code: u32,
        down: bool,
        /// The OS's shortcut modifier was held: Cmd on macOS, Ctrl elsewhere.
        primary: bool = false,
    },
    text: Text,
    pointer: struct { x: i32, y: i32 },
    button: struct { button: u8, down: bool, x: i32, y: i32 },
    wheel: struct { dx: f32, dy: f32 },
    /// The image chosen in the picker `openImage` put up (RA8EMU-959). The
    /// path is the backend's and holds until the next poll; a picker that
    /// was cancelled sends nothing.
    picked: []const u8,
};

/// How an executable opens and closes its window. ra8_gui passes
/// sdl/opener.zig's SDL window to the shell; a test passes a headless one.
/// `open` is null when no window can be had.
pub const Opener = struct {
    open: *const fn () ?Platform,
    close: *const fn () void,
};

pub const Platform = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll: *const fn (ctx: *anyopaque) ?Event,
        size: *const fn (ctx: *anyopaque) Size,
        scale: *const fn (ctx: *anyopaque) f32,
        present: *const fn (ctx: *anyopaque, frame: *const raster.Framebuffer) anyerror!void,
        /// Draws and shows a list on the backend itself (SDL geometry,
        /// RA8EMU-739). Null, or false back, means rasterize and present.
        show: ?*const fn (ctx: *anyopaque, list: *const draw_list.DrawList, atlas: ?raster.Atlas) anyerror!bool = null,
        /// The least time between presents (RA8EMU-732); null is no cap.
        interval: ?*const fn (ctx: *anyopaque) u64 = null,
        /// The OS light or dark setting (RA8EMU-962); null is unknown.
        appearance: ?*const fn (ctx: *anyopaque) Appearance = null,
        /// Raises the window to the front (RA8EMU-1156); null on backends
        /// that have no window to raise.
        focus: ?*const fn (ctx: *anyopaque) void = null,
        /// Puts up the OS's own file picker for a firmware image
        /// (RA8EMU-959) and returns at once; the choice comes back as a
        /// `picked` event. Null for a backend with no picker.
        open_image: ?*const fn (ctx: *anyopaque) void = null,
        /// Sets the window's title; null for a backend with none.
        title: ?*const fn (ctx: *anyopaque, text: []const u8) void = null,
    };

    /// The next input event, or null once this frame's events are drained.
    pub fn poll(self: Platform) ?Event {
        return self.vtable.poll(self.ctx);
    }

    /// The drawable size in pixels.
    pub fn size(self: Platform) Size {
        return self.vtable.size(self.ctx);
    }

    /// Pixels per logical point (2.0 on a Retina display).
    pub fn scale(self: Platform) f32 {
        return self.vtable.scale(self.ctx);
    }

    /// Show `frame`; the backend copies what it needs before returning.
    pub fn present(self: Platform, frame: *const raster.Framebuffer) !void {
        return self.vtable.present(self.ctx, frame);
    }

    /// Show `list` drawn by the backend. False when the backend has no
    /// such path or gave it up, so the caller rasterizes into a
    /// framebuffer and calls present: the CPU path stays the fallback.
    pub fn show(self: Platform, list: *const draw_list.DrawList, atlas: ?raster.Atlas) !bool {
        const backend_show = self.vtable.show orelse return false;
        return backend_show(self.ctx, list, atlas);
    }

    /// Nanoseconds the next present must wait after the last; 0 is no cap.
    pub fn interval(self: Platform) u64 {
        const get = self.vtable.interval orelse return 0;
        return get(self.ctx);
    }

    /// The OS light or dark setting, or unknown when the backend has none.
    pub fn appearance(self: Platform) Appearance {
        const get = self.vtable.appearance orelse return .unknown;
        return get(self.ctx);
    }

    /// Raise the window to the front; a no-op on backends without one.
    pub fn focus(self: Platform) void {
        const raise = self.vtable.focus orelse return;
        raise(self.ctx);
    }

    /// Put up the OS's file picker for a firmware image. It does not wait:
    /// a choice arrives later as a `picked` event. False when the backend
    /// has no picker.
    pub fn openImage(self: Platform) bool {
        const put_up = self.vtable.open_image orelse return false;
        put_up(self.ctx);
        return true;
    }

    /// Set the window's title, on a backend that has one.
    pub fn title(self: Platform, text: []const u8) void {
        const set = self.vtable.title orelse return;
        set(self.ctx, text);
    }
};
