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
const builtin = @import("builtin");
const gui = @import("gui_app");
const render = @import("ra8_render");
pub const c = @import("c.zig").c;
pub const geometry = @import("geometry.zig");
pub const opener = @import("opener.zig").opener;
pub const dialog = @import("dialog.zig");

const Event = gui.platform.Event;
const Size = gui.platform.Size;
const window_size = gui.window.size;
const window_keys = gui.window.keys;
const render_driver = gui.render_driver;

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
    /// Pixels per layout point (RA8EMU-966), set on the renderer so the
    /// shell draws in points and SDL scales every frame up to the pixels.
    ui_scale: u32 = 1,
    /// The OS's file picker for a firmware image (RA8EMU-959).
    files: dialog.Picker = .{ .kind = 0 },

    /// Opens at most of the screen it lands on (window_size.initial) and
    /// never shrinks under window_size.min (RA8EMU-966).
    pub fn init(title: [:0]const u8) Error!Sdl {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return fail(Error.SdlInit);
        errdefer c.SDL_Quit();
        const opening = window_size.initial(usableScreen());
        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const window = c.SDL_CreateWindow(title, @intCast(opening.width), @intCast(opening.height), flags) orelse
            return fail(Error.SdlWindow);
        errdefer c.SDL_DestroyWindow(window);
        _ = c.SDL_SetWindowMinimumSize(window, @intCast(window_size.min.width), @intCast(window_size.min.height));
        var chain: DriverChain = .{ .window = window };
        const picked = render_driver.select(render_driver.hint(builtin.os.tag), &chain) orelse
            return fail(Error.SdlRenderer);
        const renderer = chain.renderer.?;
        const vsync = c.SDL_SetRenderVSync(renderer, 1);
        render_driver.active = std.mem.span(c.SDL_GetRendererName(renderer));
        var note_buf: [128]u8 = undefined;
        if (render_driver.note(picked, &note_buf)) |message| {
            std.debug.print("ra8_gui: {s}\n", .{message});
        }
        const props = c.SDL_GetRendererProperties(renderer);
        const device = c.SDL_GetPointerProperty(props, c.SDL_PROP_RENDERER_GPU_DEVICE_POINTER, null);
        if (device) |d| render_driver.gpu = std.mem.span(c.SDL_GetGPUDeviceDriver(@ptrCast(@alignCast(d))));

        // Shifted characters reach the console pane as text events.
        _ = c.SDL_StartTextInput(window);
        var self = Sdl{ .window = window, .renderer = renderer, .vsync = vsync, .files = .init() };
        if (!cpuForced()) {
            self.presenter = geometry.Presenter.init(std.heap.page_allocator, renderer);
        }
        return self;
    }

    pub fn deinit(self: *Sdl) void {
        render_driver.active = "";
        render_driver.gpu = null;
        self.files.deinit();
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
        .appearance = appearance,
        .focus = focus,
        .open_image = openImage,
        .title = setTitle,
    };

    fn from(ctx: *anyopaque) *Sdl {
        return @ptrCast(@alignCast(ctx));
    }

    /// Raise the window to the front: a second ra8_gui asked (RA8EMU-1156).
    fn focus(ctx: *anyopaque) void {
        const self = from(ctx);
        _ = c.SDL_RaiseWindow(self.window);
    }

    /// The next event, pointer positions in layout points. The full-screen
    /// key is the window's own and never reaches the shell; a size or
    /// display-scale change reads as a resize to the new point size, and a
    /// choice from the file picker as the path chosen.
    fn poll(ctx: *anyopaque) ?Event {
        const self = from(ctx);
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            if (self.files.take(&ev)) |path| return .{ .picked = path };
            if (ev.type == c.SDL_EVENT_KEY_DOWN and !ev.key.repeat and window_keys.togglesFullscreen(ev.key.key, mods(ev.key.mod), mac)) {
                self.toggleFullscreen();
                continue;
            }
            switch (ev.type) {
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => return .{ .resize = size(ctx) },
                else => {},
            }
            _ = c.SDL_ConvertEventToRenderCoordinates(self.renderer, &ev);
            if (translate(&ev)) |event| return event;
        }
        return null;
    }

    fn openImage(ctx: *anyopaque) void {
        const self = from(ctx);
        self.files.show(self.window);
    }

    fn setTitle(ctx: *anyopaque, text: []const u8) void {
        var buf: [256]u8 = undefined;
        const len = @min(text.len, buf.len - 1);
        @memcpy(buf[0..len], text[0..len]);
        buf[len] = 0;
        _ = c.SDL_SetWindowTitle(from(ctx).window, buf[0..len :0].ptr);
    }

    fn toggleFullscreen(self: *Sdl) void {
        const now = (c.SDL_GetWindowFlags(self.window) & c.SDL_WINDOW_FULLSCREEN) != 0;
        _ = c.SDL_SetWindowFullscreen(self.window, !now);
    }

    /// The layout size in points, setting the renderer's scale to match
    /// the display the window is on now.
    fn size(ctx: *anyopaque) Size {
        const self = from(ctx);
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.window, &w, &h);
        const k = window_size.uiScale(scale(ctx));
        if (k != self.ui_scale) {
            const f: f32 = @floatFromInt(k);
            if (c.SDL_SetRenderScale(self.renderer, f, f)) self.ui_scale = k;
        }
        const pixels: Size = .{ .width = @intCast(@max(w, 0)), .height = @intCast(@max(h, 0)) };
        return window_size.points(pixels, self.ui_scale);
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
    fn appearance(ctx: *anyopaque) gui.platform.Appearance {
        _ = ctx;
        return switch (c.SDL_GetSystemTheme()) {
            c.SDL_SYSTEM_THEME_LIGHT => .light,
            c.SDL_SYSTEM_THEME_DARK => .dark,
            else => .unknown,
        };
    }

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

const mac = builtin.os.tag == .macos;

fn mods(held: c.SDL_Keymod) window_keys.Mods {
    return .{
        .ctrl = held & c.SDL_KMOD_CTRL != 0,
        .gui = held & c.SDL_KMOD_GUI != 0,
        .alt = held & c.SDL_KMOD_ALT != 0,
        .shift = held & c.SDL_KMOD_SHIFT != 0,
    };
}

/// The primary screen's usable area in points, or zero when SDL has none.
fn usableScreen() Size {
    var bounds: c.SDL_Rect = undefined;
    if (!c.SDL_GetDisplayUsableBounds(c.SDL_GetPrimaryDisplay(), &bounds)) return .{ .width = 0, .height = 0 };
    return .{ .width = @intCast(@max(bounds.w, 0)), .height = @intCast(@max(bounds.h, 0)) };
}

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
        c.SDL_EVENT_WINDOW_EXPOSED => .expose,
        c.SDL_EVENT_SYSTEM_THEME_CHANGED => .appearance,
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => .{ .key = .{ .code = ev.key.key, .down = ev.key.down, .primary = window_keys.primary(mods(ev.key.mod), mac) } },
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

/// The render-driver chain (RA8EMU-226): `select` calls tryDriver per
/// candidate; the winner's handle stays here.
const DriverChain = struct {
    window: *c.SDL_Window,
    renderer: ?*c.SDL_Renderer = null,

    pub fn tryDriver(self: *DriverChain, name: []const u8) ?*c.SDL_Renderer {
        self.renderer = createNamedRenderer(self.window, name);
        return self.renderer;
    }
};

/// SDL_CreateRenderer for one driver name, copied to a sentinel for SDL.
fn createNamedRenderer(window: *c.SDL_Window, name: []const u8) ?*c.SDL_Renderer {
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const sentinel: [*:0]const u8 = buf[0..name.len :0].ptr;
    return c.SDL_CreateRenderer(window, sentinel);
}
