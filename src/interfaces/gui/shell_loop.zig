//! The shell loop (RA8EMU-763): one frame of the debugger shell. It drains
//! the window's events (quit, gutter drags), pumps the session link into the
//! status bar model, the console (RA8EMU-787), the board (RA8EMU-790), the device list (RA8EMU-792) and the camera
//! picker (RA8EMU-796), whose leaf also takes clicks, and the plug picker
//! (RA8EMU-802), a device row's fault cell (RA8EMU-817), and the camera leaf's file field (RA8EMU-799), which take
//! typing, and the registers leaves (RA8EMU-821), read again after a load
//! or a stop, with the memory leaves following each core's SP and the
//! disassembly leaves its PC; a press on a leaf's
//! title changes what it shows (RA8EMU-800). Then it draws the shell frame (RA8EMU-764) and shows it
//! through the platform seam, so SDL and the headless platform run it alike.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const raster = @import("ra8_render").raster;
const font = @import("ra8_render").font;
const platform = @import("platform.zig");
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell_frame.zig");
const status_capture = @import("status_capture.zig");
const status_bar = @import("status_bar.zig");
const session_link = @import("session_link.zig");
const shell_console = @import("shell_console.zig");
const shell_board = @import("shell_board.zig");
const shell_devices = @import("shell_devices.zig");
const shell_fault = @import("shell_fault.zig");
const shell_camera = @import("shell_camera.zig");
const shell_titles = @import("shell_titles.zig");
const shell_plug = @import("shell_plug.zig");
const shell_camera_file = @import("shell_camera_file.zig");
const shell_startup = @import("shell_startup.zig");
const shell_registers = @import("shell_registers.zig");
const shell_memory = @import("shell_memory.zig");

/// Most arrivals taken off the link in one frame, so a chatty session
/// cannot starve the window.
pub const max_arrivals: usize = 64;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    layout: pane_layout.Layout,
    status: status_bar.Status = .{},
    link: ?*session_link.Link = null,
    painter: ?shell_frame.Painter = null,
    console: ?*shell_console.Console = null,
    board: ?*shell_board.Board = null,
    devices: ?*shell_devices.Devices = null,
    /// Each device row's fault mode (RA8EMU-817), stepped by its cell.
    faults: ?*shell_fault.Faults = null,
    camera: ?*shell_camera.Camera = null,
    plug: ?*shell_plug.Plug = null,
    camera_file: ?*shell_camera_file.CameraFile = null,
    /// The `--attach` and `--click` plugs, sent once the image is loaded.
    startup: ?*shell_startup.Startup = null,
    /// Whether the session has answered the image load.
    loaded: bool = false,
    registers: ?*shell_registers.Pair = null,
    memory: ?*shell_memory.Pair = null,
    code: ?*shell_memory.Pair = null,
    /// The splitter being dragged, from its button press to its release.
    held: ?pane_layout.Gutter = null,
    open: bool = true,
    frame: ?raster.Framebuffer = null,

    /// The shell owns `layout` from here on.
    pub fn init(allocator: std.mem.Allocator, layout: pane_layout.Layout) Shell {
        return .{ .allocator = allocator, .layout = layout };
    }

    pub fn deinit(self: *Shell) void {
        if (self.frame) |*frame| frame.deinit(self.allocator);
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
        while (window.poll()) |event| self.handle(event, &solved);
        if (!self.open) return false;
        try self.pump();
        solved.deinit(self.allocator);
        solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        var list = draw_list.DrawList.init(self.allocator, size.width, size.height);
        defer list.deinit();
        try shell_frame.draw(&list, .{
            .layout = &self.layout,
            .solved = &solved,
            .strip = status_capture.strip(&self.status, self.state()),
            .width = width,
            .height = height,
            .painter = self.painter,
        });
        if (try window.show(&list, font.atlas)) return true;
        const frame = try self.fitFrame(size);
        raster.draw(frame, &list, font.atlas);
        try window.present(frame);
        return true;
    }

    /// Apply one input event against this frame's layout.
    pub fn handle(self: *Shell, event: platform.Event, solved: *const pane_layout.Solved) void {
        switch (event) {
            .quit => self.open = false,
            .button => |press| {
                if (press.button != 1) return;
                self.held = if (press.down) solved.hit(press.x, press.y) else null;
                if (!press.down or self.held != null) return;
                if (self.pressFields(press.x, press.y)) return;
                if (shell_titles.press(&self.layout, solved, press.x, press.y)) return;
                if (self.link) |link| if (self.devices) |devices| {
                    if (self.faults) |faults| if (faults.clickIn(link, devices, &self.layout, solved, press.x, press.y)) return;
                    if (devices.clickIn(link, &self.layout, solved, press.x, press.y)) return;
                };
                if (self.registers) |registers| if (registers.clickIn(&self.layout, solved, press.x, press.y)) return;
                const camera = self.camera orelse return;
                _ = camera.clickIn(&self.layout, solved, press.x, press.y);
            },
            .pointer => |at| {
                const found = self.held orelse return;
                const axis = self.layout.node(found.split).body.split.axis;
                self.layout.drag(found, if (axis == .across) at.x else at.y);
            },
            .text, .key => {
                if (self.plug) |plug| _ = plug.handle(event);
                if (self.camera_file) |file| _ = file.handle(event);
            },
            else => {},
        }
    }

    /// Offer a press to both text fields, so the one it misses lets go.
    fn pressFields(self: *Shell, x: i32, y: i32) bool {
        const in_plug = if (self.plug) |plug| plug.press(x, y) else false;
        const in_file = if (self.camera_file) |file| file.press(x, y) else false;
        return in_plug or in_file;
    }

    /// Feed what the session sent into the status bar model and the leaves.
    pub fn pump(self: *Shell) !void {
        const link = self.link orelse return;
        if (self.console) |console| console.attach(link);
        if (self.board) |board| board.attach(link);
        if (self.devices) |devices| devices.attach(link);
        if (self.camera) |camera| {
            if (self.camera_file) |file| _ = file.apply(camera);
            camera.attach(link);
        }
        if (self.plug) |plug| _ = plug.attach(link);
        if (self.startup) |startup| if (self.loaded) startup.attach(link);
        if (self.registers) |registers| registers.attach(link);
        if (self.memory) |memory| memory.attach(link);
        if (self.code) |code| code.attach(link);
        var taken: usize = 0;
        while (taken < max_arrivals) : (taken += 1) {
            const arrival = link.pump() orelse return;
            const loading = self.status.load_id;
            self.status.observe(link, arrival);
            const answered = loading != null and self.status.load_id == null;
            if (answered) self.loaded = true;
            self.observeCore(answered, arrival);
            if (self.console) |console| try console.observe(arrival);
            if (self.board) |board| try board.observe(arrival);
            if (self.devices) |devices| devices.observe(arrival);
            if (self.faults) |faults| if (faults.observe(arrival)) if (self.devices) |devices| {
                devices.want = true;
            };
            if (self.camera) |camera| camera.observe(arrival);
            if (self.plug) |plug| if (plug.observe(arrival)) if (self.devices) |devices| {
                devices.want = true;
            };
            if (self.startup) |startup| if (startup.observe(arrival)) if (self.devices) |devices| {
                devices.want = true;
            };
        }
    }

    /// The registers, memory and code leaves: all start over after a load,
    /// then take the arrival, and memory and code follow each core's fresh
    /// registers.
    fn observeCore(self: *Shell, loaded: bool, arrival: session_link.Arrival) void {
        const registers = self.registers orelse return;
        if (loaded) registers.reload();
        registers.observe(arrival);
        for ([_]?*shell_memory.Pair{ self.memory, self.code }) |leaf| if (leaf) |memory| {
            if (loaded) memory.reload();
            memory.observe(arrival);
            memory.follow(registers);
        };
    }

    fn fitFrame(self: *Shell, size: platform.Size) !*raster.Framebuffer {
        if (self.frame) |*frame| {
            if (frame.width == size.width and frame.height == size.height) return frame;
            frame.deinit(self.allocator);
            self.frame = null;
        }
        self.frame = try raster.Framebuffer.init(self.allocator, size.width, size.height);
        return &self.frame.?;
    }
};
