//! The SDL3 backend behind platform.zig (RA8EMU-616, ADR 0001 in the knowledge base, RA8EMU-A-8).
//! It owns one window, one renderer and one streaming texture, and
//! draws each frame's list through SDL geometry (sdl/geometry.zig). The
//! CPU-rasterized framebuffer, shown as a streaming texture, is the
//! fallback: RA8_GUI_CPU forces it and a geometry failure falls back to it.
//!
//! This file is its own module, built only under -Dgui (the emulator and gui-test).
//! It reaches the rest of the GUI through "gui_app", never by relative import,
//! and `zig build test` never compiles it, so the tests need no SDL.
const std = @import("std");
const gui = @import("gui_app");
const render = @import("ra8_render");
pub const c = @import("c.zig").c;
pub const geometry = @import("geometry.zig");

const Event = gui.platform.Event;
const Size = gui.platform.Size;

pub const Error = error{ SdlInit, SdlWindow, SdlRenderer, SdlTexture, SdlPresent };

pub const Sdl = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: ?*c.SDL_Texture = null,
    texture_size: Size = .{ .width = 0, .height = 0 },
    /// The geometry path (RA8EMU-739); null runs the CPU texture path,
    /// forced by RA8_GUI_CPU or taken when the renderer fails geometry.
    presenter: ?geometry.Presenter = null,
    /// Whether the renderer paces presents to the display itself.
    vsync: bool = false,

    pub fn init(title: [:0]const u8, width: u32, height: u32) Error!Sdl {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return fail(Error.SdlInit);
        errdefer c.SDL_Quit();
        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const window = c.SDL_CreateWindow(title, @intCast(width), @intCast(height), flags) orelse
            return fail(Error.SdlWindow);
        errdefer c.SDL_DestroyWindow(window);
        const renderer = c.SDL_CreateRenderer(window, null) orelse return fail(Error.SdlRenderer);
        const vsync = c.SDL_SetRenderVSync(renderer, 1);
        // Shifted characters reach the console pane as text events.
        _ = c.SDL_StartTextInput(window);
        var self = Sdl{ .window = window, .renderer = renderer, .vsync = vsync };
        if (!cpuForced()) {
            self.presenter = geometry.Presenter.init(std.heap.page_allocator, renderer);
        }
        return self;
    }

    pub fn deinit(self: *Sdl) void {
        if (self.presenter) |*p| p.deinit();
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn platform(self: *Sdl) gui.platform.Platform {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: gui.platform.Platform.VTable = .{
        .poll = poll,
        .size = size,
        .scale = scale,
        .present = present,
        .show = show,
        .interval = interval,
    };

    fn from(ctx: *anyopaque) *Sdl {
        return @ptrCast(@alignCast(ctx));
    }

    fn poll(ctx: *anyopaque) ?Event {
        _ = ctx;
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            if (translate(&ev)) |event| return event;
        }
        return null;
    }

    fn size(ctx: *anyopaque) Size {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(from(ctx).window, &w, &h);
        return .{ .width = @intCast(@max(w, 0)), .height = @intCast(@max(h, 0)) };
    }

    fn scale(ctx: *anyopaque) f32 {
        const s = c.SDL_GetWindowDisplayScale(from(ctx).window);
        return if (s > 0) s else 1.0;
    }

    fn present(ctx: *anyopaque, frame: *const render.raster.Framebuffer) anyerror!void {
        const self = from(ctx);
        const texture = try self.textureFor(frame.width, frame.height);
        const pitch: c_int = @intCast(frame.width * 4);
        if (!c.SDL_UpdateTexture(texture, null, frame.pixels.ptr, pitch)) return fail(Error.SdlPresent);
        _ = c.SDL_RenderClear(self.renderer);
        if (!c.SDL_RenderTexture(self.renderer, texture, null, null)) return fail(Error.SdlPresent);
        if (!c.SDL_RenderPresent(self.renderer)) return fail(Error.SdlPresent);
    }

    /// One frame through geometry. A failure drops to the CPU path for
    /// the rest of the run, so a renderer without geometry still draws.
    fn interval(ctx: *anyopaque) u64 {
        const self: *Sdl = @ptrCast(@alignCast(ctx));
        return if (self.vsync) 0 else gui.present_gate.default_interval_ns;
    }

    fn show(ctx: *anyopaque, list: *const render.draw_list.DrawList, atlas: ?render.raster.Atlas) anyerror!bool {
        const self = from(ctx);
        const presenter = if (self.presenter) |*p| p else return false;
        presenter.frame(list, atlas) catch {
            std.log.warn("gui: geometry drawing failed, using the CPU path", .{});
            presenter.deinit();
            self.presenter = null;
            return false;
        };
        if (!c.SDL_RenderPresent(self.renderer)) return fail(Error.SdlPresent);
        return true;
    }

    /// The streaming texture, recreated when the framebuffer changes size.
    /// RGBA32 is the byte order of draw_list.Color on every host.
    fn textureFor(self: *Sdl, width: u32, height: u32) Error!*c.SDL_Texture {
        if (self.texture) |t| {
            if (self.texture_size.width == width and self.texture_size.height == height) return t;
            c.SDL_DestroyTexture(t);
            self.texture = null;
        }
        const t = c.SDL_CreateTexture(
            self.renderer,
            c.SDL_PIXELFORMAT_RGBA32,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(width),
            @intCast(height),
        ) orelse return fail(Error.SdlTexture);
        _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_NEAREST);
        self.texture = t;
        self.texture_size = .{ .width = width, .height = height };
        return t;
    }
};

/// RA8_GUI_CPU set to anything but empty or "0" forces the CPU path.
fn cpuForced() bool {
    const raw = c.SDL_getenv("RA8_GUI_CPU") orelse return false;
    const value = std.mem.span(raw);
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

/// One SDL event as a platform event, or null for the ones the GUI ignores.
fn translate(ev: *const c.SDL_Event) ?Event {
    return switch (ev.type) {
        c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => .quit,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => .{ .resize = .{
            .width = @intCast(@max(ev.window.data1, 0)),
            .height = @intCast(@max(ev.window.data2, 0)),
        } },
        c.SDL_EVENT_WINDOW_EXPOSED => .expose,
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => .{ .key = .{ .code = ev.key.key, .down = ev.key.down } },
        c.SDL_EVENT_TEXT_INPUT => .{ .text = gui.platform.Text.of(std.mem.span(ev.text.text)) },
        c.SDL_EVENT_MOUSE_MOTION => .{ .pointer = .{ .x = @intFromFloat(ev.motion.x), .y = @intFromFloat(ev.motion.y) } },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => .{ .button = .{
            .button = ev.button.button,
            .down = ev.button.down,
            .x = @intFromFloat(ev.button.x),
            .y = @intFromFloat(ev.button.y),
        } },
        c.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{ .dx = ev.wheel.x, .dy = ev.wheel.y } },
        else => null,
    };
}

fn fail(err: Error) Error {
    std.log.err("{s}: {s}", .{ @errorName(err), c.SDL_GetError() });
    return err;
}
