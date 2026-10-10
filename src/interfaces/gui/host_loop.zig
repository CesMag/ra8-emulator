//! The host shell's window loop (RA8EMU-646): each frame drains the
//! window's events into the panes, lets the camera follow its pane, runs
//! one slice of the emulation, then draws the board view and the panes and
//! presents them.
//!
//! It drives the run through `Run` and the window through the platform
//! seam, so the SDL window and the headless one run it the same way and a
//! test can step a short run and read back what it presented. The board is
//! the same composition `--frame-out` writes (board_view.zig), drawn at its
//! own size in the top-left corner with the camera pane to its right.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const raster = @import("ra8_render").raster;
const present_gate = @import("present_gate.zig");
const font = @import("ra8_render").font;
const platform = @import("platform.zig");
const camera_pane = @import("camera_pane.zig");
const console_pane = @import("ui/console_pane.zig");
const console_log = @import("console_log.zig");
const console_scroll = @import("console_scroll.zig");
const console_pick = @import("ui/console_pick.zig");
const console_keys = @import("console_keys.zig");
const console_save = @import("console_save.zig");
const camera_view = @import("ui/camera_view.zig");
const camera_media = @import("camera_media.zig");
const camera_thumb = @import("camera_thumb.zig");
const media_row = @import("ui/camera_media_row.zig");
const camera_devices = @import("camera_devices.zig");
const consent_store = @import("camera_consent_store.zig");
const FrameSource = @import("camera_switch.zig").FrameSource;
const SourceSwap = @import("source_swap.zig").SourceSwap;
const devices_panel = @import("devices_panel.zig");
const devices_pane = @import("ui/devices_pane.zig");
const plug_post = @import("plug_post.zig");
pub const board_view = @import("ra8_render").board_view;
const Color = draw_list.Color;

/// What the board shows right now: the panel's ARGB pixels and the LEDs.
pub const Board = struct {
    panel: []const u32,
    width: u32,
    height: u32,
    leds: []const board_view.Led,
};

/// Where the CEU reads its frames from, for the camera pane to swap.
pub const Camera = struct {
    source: *FrameSource,
    format_control: *const u8,
    /// Set when the engine installs picks itself at its parks (RA8EMU-227);
    /// the loop then posts there and never writes `source`.
    swap: ?*SourceSwap = null,
};

/// The emulation the loop drives.
pub const Run = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Runs one frame's slice; false once the run has ended.
        step: *const fn (ctx: *anyopaque) bool,
        board: *const fn (ctx: *anyopaque) Board,
        /// Null when the board has no camera.
        camera: *const fn (ctx: *anyopaque) ?Camera,
    };
};

pub const background = camera_view.background;

/// ARGB8888 as an RGBA colour.
pub fn colorOf(argb: u32) Color {
    return .{ .r = @truncate(argb >> 16), .g = @truncate(argb >> 8), .b = @truncate(argb), .a = @truncate(argb >> 24) };
}

/// Where the camera pane sits beside a board view of `view`.
pub fn paneLayout(view: board_view.Size) camera_view.Layout {
    return .{ .x = @intCast(view.width + camera_view.gap), .y = @intCast(board_view.margin) };
}

/// The strip under the board view the console pane draws into.
pub fn consoleArea(window: platform.Platform, board: Board) draw_list.Rect {
    const view = board_view.size(board.width, board.height);
    return console_pane.under(view.width, view.height, window.size().height);
}

pub const Loop = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pane: camera_pane.Pane = .{ .layout = .{ .x = 0, .y = 0 } },
    canvas: []u32 = &.{},
    pixels: []Color = &.{},
    frame: ?raster.Framebuffer = null,
    devices: ?camera_devices.Devices = null,
    /// Where the host's webcams are listed again each time the webcam comes
    /// up (its dialog opens or it becomes the source), so one plugged in
    /// after the window opened is offered; null keeps the adopted list.
    device_dir: ?std.Io.Dir = null,
    /// The pictures and clips the pane offers, and every earlier listing:
    /// a running source and the pane's arguments may still name a file from
    /// one, so no listing is freed before the loop is.
    media: ?camera_media.Media = null,
    retired: std.ArrayListUnmanaged(camera_media.Media) = .empty,
    /// Where the project's pictures and clips are listed again each time
    /// the image or video source comes up; null offers none.
    media_dir: ?std.Io.Dir = null,
    /// The chosen picture's or clip's preview and the name it was read from; the
    /// name points into a listing, which outlives the loop's frames.
    thumb: ?camera_thumb.Thumb = null,
    thumb_of: []const u8 = "",
    /// Where Always for this project is kept; null keeps it for this run.
    project: ?std.Io.Dir = null,
    /// The console the pane under the board shows; null shows none.
    console: ?*const console_log.Log = null,
    /// Every channel's console the pane's tabs pick from, and the one shown;
    /// empty shows `console` with no tabs.
    consoles: []const console_log.Log = &.{},
    channel: usize = 0,
    /// Where keys typed with the pointer over the console go; null drops them.
    typed: ?*console_keys.Typed = null,
    /// The devices pane under the camera's media row (RA8EMU-703) and the
    /// post its clicks queue on; null shows no pane.
    plugs: ?*devices_panel.Panel = null,
    posted: ?*plug_post.PlugPost = null,
    scroll: console_scroll.Scroll = .{},
    /// Where the pointer was last seen, so a wheel over the console scrolls it.
    pointer: struct { x: i32, y: i32 } = .{ .x = -1, .y = -1 },
    quit: bool = false,
    /// Skips presenting a list identical to the last one (RA8EMU-732).
    gate: present_gate.Gate = .{},

    pub fn deinit(self: *Loop) void {
        if (self.devices) |*devices| devices.deinit();
        if (self.media) |*media| media.deinit();
        for (self.retired.items) |*media| media.deinit();
        self.retired.deinit(self.allocator);
        if (self.thumb) |thumb| thumb.deinit(self.allocator);
        self.allocator.free(self.canvas);
        self.allocator.free(self.pixels);
        if (self.frame) |*frame| frame.deinit(self.allocator);
    }

    /// Hands the pane the host's webcams to offer; the loop frees them.
    pub fn adoptDevices(self: *Loop, devices: camera_devices.Devices) void {
        if (self.devices) |*old| old.deinit();
        self.devices = devices;
        self.pane.devices = devices.numbers;
    }

    /// Lists the webcams in `dir` now and again whenever the webcam comes
    /// up. The caller keeps `dir` open while the loop runs.
    pub fn useDeviceDir(self: *Loop, dir: std.Io.Dir) void {
        self.device_dir = dir;
        self.relist();
    }

    /// A listing that fails keeps the webcams already offered.
    fn relist(self: *Loop) void {
        const dir = self.device_dir orelse return;
        const found = camera_devices.list(self.allocator, self.io, dir) catch return;
        self.adoptDevices(found);
    }

    fn wantsMedia(self: *const Loop) bool {
        return self.pane.panel.active == .image or self.pane.panel.active == .video;
    }

    fn wantsWebcam(self: *const Loop) bool {
        return self.pane.panel.asking or self.pane.panel.active == .webcam;
    }

    /// Hands the pane the project's pictures and clips; the loop frees them.
    /// When the earlier listing cannot be kept, the new one is dropped.
    pub fn adoptMedia(self: *Loop, found: camera_media.Media) void {
        var media = found;
        if (self.media) |old| self.retired.append(self.allocator, old) catch {
            media.deinit();
            return;
        };
        self.media = media;
        self.pane.pictures = media.images;
        self.pane.clips = media.videos;
    }

    /// Lists the pictures and clips in `dir` now and again whenever the
    /// image or video source comes up. The caller keeps `dir` open.
    pub fn useMediaDir(self: *Loop, dir: std.Io.Dir) void {
        self.media_dir = dir;
        self.relistMedia();
    }

    /// A listing that fails keeps the files already offered.
    fn relistMedia(self: *Loop) void {
        const dir = self.media_dir orelse return;
        const found = camera_media.list(self.allocator, self.io, dir) catch return;
        self.adoptMedia(found);
    }

    /// Reads the preview again when the chosen picture or clip changed; any
    /// other source, no pick, or a file that will not decode shows none.
    fn refreshThumb(self: *Loop) void {
        const wanted = switch (self.pane.panel.active) {
            .image => self.pane.args.image,
            .video => self.pane.args.video,
            else => "",
        };
        if (std.mem.eql(u8, wanted, self.thumb_of)) return;
        if (self.thumb) |thumb| thumb.deinit(self.allocator);
        self.thumb = null;
        self.thumb_of = wanted;
        const dir = self.media_dir orelse return;
        if (wanted.len == 0) return;
        self.thumb = camera_thumb.load(self.allocator, self.io, dir, wanted) catch null;
    }

    /// Lists `panel` under the media row; refusals come back through `post`.
    pub fn useDevices(self: *Loop, panel: *devices_panel.Panel, post: *plug_post.PlugPost) void {
        self.plugs = panel;
        self.posted = post;
    }

    /// The devices pane fills what is left under the thumbnail's row.
    pub fn devicesArea(self: *const Loop, size: platform.Size) draw_list.Rect {
        const thumb = self.thumbArea();
        const top = thumb.y + thumb.h + camera_view.gap;
        const left = self.pane.layout.x;
        const w: i32 = @as(i32, @intCast(size.width)) - left;
        const h: i32 = @as(i32, @intCast(size.height)) - top;
        return .{ .x = left, .y = top, .w = @max(w, 0), .h = @max(h, 0) };
    }

    /// A click the camera pane left goes to the devices pane; a plug the
    /// session refuses leaves the row as it was.
    fn clickDevices(self: *Loop, event: platform.Event, size: platform.Size) void {
        const panel = self.plugs orelse return;
        if (event != .button) return;
        const press = event.button;
        if (!press.down or press.button != camera_pane.primary_button) return;
        _ = devices_pane.click(panel, self.devicesArea(size), press.x, press.y) catch {};
    }

    /// Plugs the board refused at the last park put their rows back.
    fn settleRefused(self: *Loop) void {
        const panel = self.plugs orelse return;
        const post = self.posted orelse return;
        var buffer: [plug_post.limits.pending]plug_post.Request = undefined;
        for (post.takeRefused(&buffer)) |request| panel.refused(request.at, request.name);
    }

    /// The preview goes in the slot after the media row's last file.
    fn thumbArea(self: *const Loop) draw_list.Rect {
        const row = media_row.rowFor(self.pane.layout, self.pane.devices.len);
        return row.slot(self.pane.media().len);
    }

    /// Keeps Always in `project`, starting from what an earlier run saved.
    pub fn useProject(self: *Loop, project: std.Io.Dir) void {
        self.project = project;
        if (consent_store.load(self.io, project)) self.pane.panel.always = true;
    }

    /// One frame. Returns false once the run ended or the window closed;
    /// a closed window stops before the slice runs.
    pub fn tick(self: *Loop, window: platform.Platform, run: Run) !bool {
        const before = run.vtable.board(run.ctx);
        self.pane.layout = paneLayout(board_view.size(before.width, before.height));
        const always = self.pane.panel.always;
        const wanted = self.wantsWebcam();
        const kind = self.pane.panel.active;
        while (window.poll()) |event| {
            switch (event) {
                .quit => self.quit = true,
                .expose => self.gate.force(),
                .pointer => |at| self.pointer = .{ .x = at.x, .y = at.y },
                .wheel => |turn| self.wheel(turn.dy, consoleArea(window, before)),
                .key => |key| if (key.down) if (console_keys.byteOf(key.code)) |byte|
                    self.typeBytes(&.{byte}, consoleArea(window, before)),
                .text => |text| self.typeBytes(text.slice(), consoleArea(window, before)),
                else => if (!self.pane.handle(event) and !self.clickConsole(event, consoleArea(window, before)))
                    self.clickDevices(event, window.size()),
            }
        }
        self.settleRefused();
        if (self.pane.panel.always and !always) self.remember();
        if (self.wantsWebcam() and !wanted) self.relist();
        if (self.pane.panel.active != kind and self.wantsMedia()) self.relistMedia();
        self.refreshThumb();
        if (self.quit) return false;
        if (run.vtable.camera(run.ctx)) |camera| {
            if (camera.swap) |swap| {
                self.pane.settleInto(self.allocator, self.io, swap, camera.format_control);
            } else self.pane.settle(self.allocator, self.io, camera.source, camera.format_control);
        }
        const running = run.vtable.step(run.ctx);
        if (self.console) |log| self.scroll.follow(log);
        try self.draw(window, run.vtable.board(run.ctx));
        return running;
    }

    /// Shows `logs[channel]`, with a tab per log to pick another.
    pub fn useConsoles(self: *Loop, logs: []const console_log.Log, channel: usize) void {
        self.consoles = logs;
        self.channel = channel;
        self.console = &logs[channel];
        self.scroll = .{};
        self.scroll.follow(self.console.?);
    }
    fn clickConsole(self: *Loop, event: platform.Event, area: draw_list.Rect) bool {
        if (event != .button or self.consoles.len == 0) return false;
        const press = event.button;
        if (!press.down or press.button != camera_pane.primary_button) return false;
        if (console_save.click(area, press.x, press.y, self.io, self.project, self.consoles, self.channel)) return true;
        const channel = console_pick.tabAt(area, self.consoles.len, press.x, press.y) orelse return false;
        self.useConsoles(self.consoles, channel);
        return true;
    }
    /// Keys typed with the pointer over the console go to the channel it
    /// shows.
    fn typeBytes(self: *Loop, bytes: []const u8, area: draw_list.Rect) void {
        const typed = self.typed orelse return;
        if (!area.contains(self.pointer.x, self.pointer.y)) return;
        for (bytes) |byte| typed.post(@intCast(self.channel), byte);
    }
    fn wheel(self: *Loop, dy: f32, area: draw_list.Rect) void {
        const log = self.console orelse return;
        if (area.contains(self.pointer.x, self.pointer.y)) self.scroll.wheel(dy, log);
    }

    /// A project that will not take the marker asks again next run.
    fn remember(self: *Loop) void {
        const project = self.project orelse return;
        consent_store.save(self.io, project) catch {};
    }

    fn draw(self: *Loop, window: platform.Platform, board: Board) !void {
        const view = board_view.size(board.width, board.height);
        try self.fitBoard(@as(usize, view.width) * view.height);
        board_view.compose(self.canvas, board.panel, board.width, board.height, board.leds);
        for (self.canvas, self.pixels) |argb, *pixel| pixel.* = colorOf(argb);
        const size = window.size();
        var list = draw_list.DrawList.init(self.allocator, size.width, size.height);
        defer list.deinit();
        try list.fill(list.bounds, background);
        const area = draw_list.Rect{ .x = 0, .y = 0, .w = @intCast(view.width), .h = @intCast(view.height) };
        try list.image(area, .{ .width = view.width, .height = view.height, .pixels = self.pixels });
        try self.pane.draw(&list);
        try camera_thumb.draw(&list, self.thumbArea(), self.thumb);
        if (self.plugs) |panel| try devices_pane.draw(&list, self.devicesArea(size), panel.*);
        const strip = consoleArea(window, board);
        if (self.consoles.len > 0) try console_pick.draw(&list, strip, self.consoles, self.channel);
        const lines = if (self.consoles.len > 0) console_pick.below(strip) else strip;
        if (self.console) |log| try console_pane.draw(&list, lines, log, self.scroll.back);
        const digest = present_gate.digest(&list);
        const now: i128 = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
        if (!self.gate.due(digest, now, window.interval())) return;
        if (!try window.show(&list, font.atlas)) {
            const frame = try self.fitFrame(size);
            raster.draw(frame, &list, font.atlas);
            try window.present(frame);
        }
        self.gate.presented(digest, now);
    }

    fn fitBoard(self: *Loop, count: usize) !void {
        if (self.canvas.len == count) return;
        self.allocator.free(self.canvas);
        self.allocator.free(self.pixels);
        self.canvas = &.{};
        self.pixels = &.{};
        self.canvas = try self.allocator.alloc(u32, count);
        self.pixels = try self.allocator.alloc(Color, count);
    }

    fn fitFrame(self: *Loop, size: platform.Size) !*raster.Framebuffer {
        if (self.frame) |*frame| {
            if (frame.width == size.width and frame.height == size.height) return frame;
            frame.deinit(self.allocator);
            self.frame = null;
        }
        self.frame = try raster.Framebuffer.init(self.allocator, size.width, size.height);
        return &self.frame.?;
    }
};
