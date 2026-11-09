//! The shell loop (RA8EMU-763): one frame of the debugger shell. It drains the window's events
//! (quit, the menu strip RA8EMU-957, gutter drags), pumps the session link into the leaves, takes
//! their presses (the menu strip RA8EMU-968, the titles RA8EMU-800, the settings page RA8EMU-963), pays a lit run its slices, and draws the frame (RA8EMU-764) through the platform seam.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const widget_paint = @import("ra8_render").widget_paint;
const raster = @import("ra8_render").raster;
const font = @import("ra8_render").font;
pub const frame_buffer = @import("frame_buffer.zig");
pub const execution = @import("execution.zig");
const platform = @import("../platform.zig");
const shell_press = @import("press.zig");
/// A session served in this process, answering on the shell's own thread.
const Server = @import("server.zig").Server;
const pane_layout = @import("../ui/pane_layout.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const status_capture = @import("../status/capture.zig");
const status_bar = @import("../status/bar.zig");
const session_link = @import("../session_link.zig");
const timeline_model = @import("../timeline_model.zig");
const shell_console = @import("console.zig");
const shell_board = @import("board/board.zig");
const shell_board_input = @import("board/input.zig");
const shell_devices = @import("devices.zig");
const shell_fault = @import("fault.zig");
const shell_camera = @import("camera/camera.zig");
const shell_titles = @import("titles.zig");
const shell_plug = @import("plug.zig");
const shell_camera_file = @import("camera/file.zig");
const shell_startup = @import("startup.zig");
const shell_open = @import("open.zig");
const shell_pick = @import("board_pick.zig");
const shell_registers = @import("registers.zig");
const shell_register_edit = @import("register_edit.zig");
const shell_memory = @import("memory.zig");
const shell_breaks = @import("breaks.zig");
const shell_memory_field = @import("memory_field.zig");
const shell_time = @import("time.zig");
const shell_snaps = @import("snapshots.zig");
const wall_clock = @import("../wall_clock.zig");
const shell_stack = @import("stack.zig");
const shell_source = @import("source.zig");
const shell_locals = @import("locals.zig");
const shell_map = @import("map.zig");
const shell_branches = @import("branch_state.zig");
const shell_diff = @import("diff_state.zig");
const shell_filmstrip = @import("filmstrip_feed.zig");
const history_strip = @import("../ui/history_strip.zig");
const map_pane = @import("../ui/map_pane.zig");
const shell_theme = @import("theme.zig");
const menu_bar = @import("../menu_bar.zig");
const menu_actions = @import("menu_actions.zig");
const shell_recent = @import("recent_menu.zig");
const shell_settings = @import("settings_page.zig");
const shell_pump = @import("pump.zig");
const session_worker = @import("../session_worker.zig");

/// Most arrivals taken off the link in one frame, so a chatty session cannot starve the window.
pub const max_arrivals = execution.max_arrivals;
/// Starts the session on the first image opened (boot.zig).
pub const Boot = struct {
    context: *anyopaque,
    startFn: *const fn (context: *anyopaque, path: []const u8) void,
};
pub const Shell = struct {
    allocator: std.mem.Allocator,
    layout: pane_layout.Layout,
    status: status_bar.Status = .{},
    link: ?*session_link.Link = null,
    painter: ?shell_frame.Painter = null,
    /// The palette in use and its picker (RA8EMU-1165).
    themes: shell_theme.Themes = .{},
    titles: shell_titles.Tracker = .{}, // a deck tab press holds a drag (RA8EMU-958).
    /// The settings page over the shell (RA8EMU-963).
    settings: shell_settings.Page = .{},
    timeline: ?timeline_model.Model = null,
    trace_armed: bool = false,
    console: ?*shell_console.Console = null,
    board: ?*shell_board.Board = null,
    /// The board leaf's pointer: switch clicks and panel touches.
    board_input: ?*shell_board_input.Pointer = null,
    devices: ?*shell_devices.Devices = null,
    /// Each device row's fault mode (RA8EMU-817), stepped by its cell.
    faults: ?*shell_fault.Faults = null,
    camera: ?*shell_camera.Camera = null,
    plug: ?*shell_plug.Plug = null,
    camera_file: ?*shell_camera_file.CameraFile = null,
    /// The `--attach` and `--click` plugs, sent once the image is loaded.
    startup: ?*shell_startup.Startup = null,
    loaded: bool = false,
    registers: ?*shell_registers.Pair = null,
    /// Register edits over the leaves (RA8EMU-946).
    edit: ?*shell_register_edit.Editor = null,
    memory: ?*shell_memory.Pair = null,
    /// The memory leaf's typed symbol field (RA8EMU-934).
    memory_field: ?*shell_memory_field.Pin = null,
    code: ?*shell_memory.Pair = null,
    /// The run-to points clicked on the disassembly leaves (RA8EMU-1171).
    breaks: ?*shell_breaks.Breaks = null,
    /// The call stack leaves, walked again after a load and every stop.
    stack: ?*shell_stack.Pair = null,
    source: ?*shell_source.Pair = null,
    locals: ?*shell_locals.Pair = null,
    /// The memory map leaf (RA8EMU-781): the image's sections over the regions.
    map: ?*shell_map.State = null,
    /// The branch tree leaf: the session's branches, switched by a click.
    branches: ?*shell_branches.Feed = null,
    /// The state diff leaf: the cursor against one recorded stop.
    diff: ?*shell_diff.State = null,
    /// The thumbnails along the history strip, from the navigation index's frames.
    filmstrip: ?*shell_filmstrip.Feed = null,
    /// The time bar's models: the run, the speed field and the clock.
    time: ?*shell_time.Time = null,
    /// Opening another image (RA8EMU-959) and the Board menu's pick (RA8EMU-1152).
    files: ?*shell_open.Open = null,
    pick: ?*shell_pick.Pick = null,
    /// The timeline slice clicks' rewind (RA8EMU-838).
    snaps: shell_snaps.Snapshots = undefined,
    /// The session when it is served in this process; null for a remote one.
    server: ?Server = null,
    /// Starts the session when the first image opens while none is up;
    /// null for a shell that never starts its own.
    boot: ?Boot = null,
    /// The per-user listener outside clients connect to (RA8EMU-1156).
    listener: ?Server = null,
    /// The thread the local session answers on, when it has one of its own.
    worker: ?*session_worker.Worker = null,
    /// Set when a second launch asked for this window (shell/hosted.zig).
    raise: ?*std.atomic.Value(bool) = null,
    /// The wall clock a run is paced against; none, and time stands still.
    clock: ?wall_clock.Clock = null,
    drained: bool = true,
    bar: shell_frame.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The history strip's row, on top of the bar's row (slice 19).
    track: shell_frame.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    held: ?pane_layout.Gutter = null,
    /// The menu strip's state (RA8EMU-957) and the window's width.
    menu: menu_bar.Menu = .{},
    /// The File menu's laid-in recents (RA8EMU-1153), or null when none is kept.
    recent_menu: ?*shell_recent.State = null,
    width: i32 = 0,
    /// The window's height this frame (RA8EMU-963).
    height: i32 = 0,
    /// The pointer's last place, for the wheel and page keys.
    pointer_at: struct { x: i32, y: i32 } = .{ .x = -1, .y = -1 },
    open: bool = true,
    frame: ?raster.Framebuffer = null,
    /// The shell owns `layout` from here on.
    pub fn init(allocator: std.mem.Allocator, layout: pane_layout.Layout) Shell {
        var self: Shell = .{ .allocator = allocator, .layout = layout };
        self.timeline = timeline_model.Model.init(allocator);
        self.snaps = shell_snaps.Snapshots.init(allocator);
        return self;
    }
    pub fn deinit(self: *Shell) void {
        if (self.frame) |*frame| frame.deinit(self.allocator);
        if (self.timeline) |*model| model.deinit();
        self.snaps.deinit();
        if (self.map) |map| map.deinit();
        self.layout.deinit();
    }
    /// The link's state, or closed when the shell has none.
    pub fn state(self: *const Shell) session_link.State {
        const link = self.link orelse return .closed;
        return link.state;
    }
    /// Run one frame. False once the window has asked to close.
    pub fn step(self: *Shell, window: platform.Platform) !bool {
        const size = window.size();
        const width: i32 = @intCast(size.width);
        const height: i32 = @intCast(size.height);
        var solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        defer solved.deinit(self.allocator);
        self.bar = shell_frame.barArea(width, height);
        self.track = shell_frame.trackArea(width, height);
        self.height = height;
        menu_actions.observe(self, window, width);
        while (window.poll()) |event| {
            if (event == .appearance) self.themes.restyle(window.appearance());
            self.handle(window, event, &solved);
        }
        if (!self.open) return false;
        if (!self.themes.styled) self.themes.restyle(window.appearance());
        if (self.raise) |asked| if (asked.swap(false, .acq_rel)) window.focus();
        try execution.exchange(self);
        if (self.registers) |registers| if (self.time) |time| registers.live(time.run.lit, self.now(), self.settings.display.registers.interval());
        try execution.paySlices(self, .fresh);
        if (self.files) |files| {
            if (self.link) |link| files.retry(link, &self.status);
            files.frame(window, &self.status);
        }
        if (!window.visible()) return true;
        if (self.pick) |pick| pick.frame(window);
        solved.deinit(self.allocator);
        solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        var list = draw_list.DrawList.init(self.allocator, size.width, size.height);
        defer list.deinit();
        if (self.board) |board| board.pace(self.now());
        if (self.camera) |camera| camera.pace(self.now(), self.allocator);
        try shell_frame.draw(&list, self.themes.active, .{
            .layout = &self.layout,
            .solved = &solved,
            .strip = status_capture.strip(&self.status, self.state()),
            .bar = if (self.time) |time| time.view(&self.status) else .{},
            .track = self.trackView(),
            .banner = if (self.branches) |feed| feed.state.fork_pending else false,
            .menu = self.menu,
            .width = width,
            .height = height,
            .painter = self.painter,
            .themes = self.themes.view(),
        });
        var target = widget_paint.Target{ .list = &list };
        const paint = target.paint();
        try shell_settings.Page.draw(&self.settings, &paint, &self.themes, self.themes.active, width, height);
        if (try window.show(&list, font.atlas)) return true;
        // raster.draw is the documented temporary composite (RA8EMU-1157).
        const frame = try frame_buffer.fit(&self.frame, self.allocator, size);
        raster.draw(frame, &list, font.atlas);
        try window.present(frame);
        return true;
    }
    /// Apply one input event against this frame's layout.
    pub fn handle(self: *Shell, window: platform.Platform, event: platform.Event, solved: *const pane_layout.Solved) void {
        switch (event) {
            .quit => self.open = false,
            .button => |press| {
                if (press.button != 1) return;
                if (press.down and menu_actions.press(self, window, press.x, press.y)) return;
                if (press.down and self.themes.press(shell_frame.stripUnder(self.bar), press.x, press.y)) return;
                if (press.down and shell_press.pressDropdown(self, press.x, press.y)) return;
                if (press.down) if (self.link) |link| if (shell_press.pressBanner(self, link, press.x, press.y)) return;
                self.held = if (press.down) solved.hit(press.x, press.y) else null;
                if (!press.down) return shell_press.releaseBoard(self, solved, press.x, press.y);
                if (self.held != null) return;
                if (shell_press.pressFields(self, press.x, press.y)) return;
                if (shell_press.pressValue(self, press.x, press.y, solved)) return;
                if (self.titles.press(&self.layout, solved, press.x, press.y)) return;
                if (self.link) |link| if (self.timeline) |*model| if (self.snaps.pressed(link, &self.layout, solved, model, press.x, press.y)) return;
                if (shell_press.pressBoard(self, solved, press.x, press.y)) return;
                if (self.link) |link| if (shell_press.pressLink(self, link, solved, press.x, press.y)) return;
                if (self.link) |link| if (shell_press.pressHistory(self, link, solved, press.x, press.y)) return;
                if (shell_press.pressMap(self, solved, press.x, press.y)) return;
                if (self.registers) |registers| if (registers.clickIn(&self.layout, solved, press.x, press.y)) return;
                if (self.console) |console| if (console.clickIn(&self.layout, solved, press.x, press.y)) return;
                const camera = self.camera orelse return;
                _ = camera.clickIn(&self.layout, solved, press.x, press.y);
            },
            .pointer => |at| {
                self.pointer_at = .{ .x = at.x, .y = at.y };
                const found = self.held orelse return shell_press.moveBoard(self, at.x, at.y);
                const axis = self.layout.node(found.split).body.split.axis;
                self.layout.drag(found, if (axis == .across) at.x else at.y);
            },
            .wheel => |turn| {
                const console = self.console orelse return;
                _ = console.wheelIn(&self.layout, solved, self.pointer_at.x, self.pointer_at.y, turn.dy);
            },
            .text, .key => {
                if (menu_actions.key(self, window, event)) return;
                if (self.edit) |edit| if (self.link) |link| if (edit.handle(link, event)) return;
                if (self.themes.key(event)) return;
                if (shell_press.pageConsole(self, event, solved)) return;
                if (shell_press.stepKeys(self, event, solved)) return;
                if (self.time) |time| if (self.link) |link| if (time.handle(event, link, &self.status)) return;
                if (self.plug) |plug| _ = plug.handle(event);
                if (self.camera_file) |file| _ = file.handle(event);
                if (self.memory_field) |field| _ = field.handle(event);
            },
            .picked, .dropped => |path| {
                self.openImage(path);
                if (self.map) |map| map.build(path);
            },
            .picked_profile => |path| if (self.pick) |pick| pick.picked(path),
            else => {},
        }
    }

    /// The history strip's view: the time bar's track with the filmstrip laid
    /// out along it.
    fn trackView(self: *Shell) history_strip.View {
        const time = self.time orelse return .{};
        const feed = self.filmstrip orelse return time.trackView();
        // A session with a history shows its recorded extent: the frames
        // reach as far as the machine has run.
        const frames = feed.strip.items();
        if (frames.len > 0) {
            const at = time.boardNow();
            time.track.end_ns = @max(frames[frames.len - 1].virtual_ns, at, time.track.end_ns orelse 0);
            time.track.current_ns = at;
        }
        var view = time.trackView();
        feed.strip.updateLayout(shell_frame.toList(self.track), view.track.total());
        view.filmstrip = &feed.strip;
        return view;
    }

    /// Opens `path`: loaded on the session, or the session started on it
    /// when none is up yet.
    pub fn openImage(self: *Shell, path: []const u8) void {
        if (self.link) |link| {
            if (self.files) |files| files.picked(path, link, &self.status);
        } else if (self.boot) |boot| boot.startFn(boot.context, path);
    }

    /// A pane changed the device list: the shell's rows are stale.
    pub fn wants(self: *Shell) void {
        if (self.devices) |devices| devices.want = true;
    }
    /// The wall clock, or zero for a shell that was given none.
    pub fn now(self: *const Shell) u64 {
        const clock = self.clock orelse return 0;
        return clock.now();
    }
    /// The emulated board time, or zero when none is available.
    pub fn boardNow(self: *const Shell) u64 {
        const time = self.time orelse return 0;
        return time.boardNow();
    }
    /// Between two frames: take what a session on a thread of its own has
    /// answered and send a lit run its next slice, so the image is not left
    /// waiting for the window's next frame.
    pub fn service(self: *Shell) !void {
        if (self.server) |server| try server.answer();
        try self.pump();
        try execution.paySlices(self, .same);
    }
    /// Feed what the session sent into the status bar model and the leaves.
    pub fn pump(self: *Shell) !void {
        return shell_pump.pump(self);
    }
};
