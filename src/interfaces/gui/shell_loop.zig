//! The shell loop (RA8EMU-763): one frame of the debugger shell. It drains
//! the window's events (quit, gutter drags), pumps the session link into the
//! status bar model, the console (RA8EMU-787), the board (RA8EMU-790), the device list (RA8EMU-792) and the camera
//! picker (RA8EMU-796), whose leaf also takes clicks, as does the board leaf
//! for its switches and its panel (RA8EMU-1119), and the plug picker
//! (RA8EMU-802), a device row's fault cell (RA8EMU-817), and the camera leaf's file field (RA8EMU-799), which take
//! typing, and the registers leaves (RA8EMU-821), read again after a load
//! or a stop, with the memory leaves following each core's SP and the
//! disassembly leaves its PC; a press on a leaf's
//! title changes what it shows (RA8EMU-800). The time bar (RA8EMU-1118)
//! takes its clicks and typing, and while Run is lit each frame pays the
//! board its slices here: a session served in this process answers on this
//! thread between them, so the frame never waits on more than one slice.
//! Then it draws the shell frame (RA8EMU-764) and shows it through the
//! platform seam, so SDL and the headless platform run it alike.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const raster = @import("ra8_render").raster;
const font = @import("ra8_render").font;
const platform = @import("platform.zig");
const pane_layout = @import("ui/pane_layout.zig");
const colors = @import("ui/colors.zig");
const shell_frame = @import("ui/shell_frame.zig");
const status_capture = @import("status_capture.zig");
const status_bar = @import("status_bar.zig");
const session_link = @import("session_link.zig");
const shell_console = @import("shell_console.zig");
const shell_board = @import("shell_board.zig");
const shell_board_input = @import("shell_board_input.zig");
const shell_devices = @import("shell_devices.zig");
const shell_fault = @import("shell_fault.zig");
const shell_camera = @import("shell_camera.zig");
const shell_titles = @import("shell_titles.zig");
const shell_plug = @import("shell_plug.zig");
const shell_camera_file = @import("shell_camera_file.zig");
const shell_startup = @import("shell_startup.zig");
const shell_registers = @import("shell_registers.zig");
const shell_stack = @import("shell_stack.zig");
const shell_memory = @import("shell_memory.zig");
const shell_time = @import("shell_time.zig");
const wall_clock = @import("wall_clock.zig");

/// Most arrivals taken off the link in one frame, so a chatty session
/// cannot starve the window.
pub const max_arrivals: usize = 64;

/// A session served in this process (local_session.zig): asked, it answers
/// everything the shell has sent, on the shell's own thread.
pub const Server = struct {
    context: *anyopaque,
    answerFn: *const fn (context: *anyopaque) anyerror!void,

    pub fn answer(self: Server) !void {
        return self.answerFn(self.context);
    }
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    layout: pane_layout.Layout,
    status: status_bar.Status = .{},
    link: ?*session_link.Link = null,
    painter: ?shell_frame.Painter = null,
    /// The palette every leaf, bar and strip paints with.
    theme: *const colors.Theme = colors.of(.dark),
    /// Repaint `theme` from the OS appearance (RA8EMU-962): read on the
    /// first frame and again whenever the OS reports a change.
    follow_os: bool = false,
    /// The OS appearance has been read at least once.
    styled: bool = false,
    console: ?*shell_console.Console = null,
    board: ?*shell_board.Board = null,
    /// The pointer on the board leaf: switch clicks and panel touches.
    board_input: ?*shell_board_input.Pointer = null,
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
    /// The call stack leaves, walked again after a load and every stop.
    stack: ?*shell_stack.Pair = null,
    /// The time bar's models: the run, the speed field and the clock.
    time: ?*shell_time.Time = null,
    /// The session when it is served in this process; null for a remote one.
    server: ?Server = null,
    /// The wall clock a run is paced against; without one time stands still.
    clock: ?wall_clock.Clock = null,
    /// The last pump took everything the session had sent.
    drained: bool = true,
    /// Where the time bar was drawn this frame.
    bar: draw_list.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The splitter being dragged, from its button press to its release.
    held: ?pane_layout.Gutter = null,
    /// Where the pointer last was, for the wheel and page keys.
    pointer_at: struct { x: i32, y: i32 } = .{ .x = -1, .y = -1 },
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
        self.bar = shell_frame.barArea(width, height);
        if (!self.styled) self.restyle(window);
        while (window.poll()) |event| {
            if (event == .appearance) self.restyle(window);
            self.handle(event, &solved);
        }
        if (!self.open) return false;
        try self.exchange();
        try self.paySlices();
        solved.deinit(self.allocator);
        solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        var list = draw_list.DrawList.init(self.allocator, size.width, size.height);
        defer list.deinit();
        try shell_frame.draw(&list, self.theme, .{
            .layout = &self.layout,
            .solved = &solved,
            .strip = status_capture.strip(&self.status, self.state()),
            .bar = if (self.time) |time| time.view(&self.status) else .{},
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

    /// Pick the palette from the OS appearance when following it; an OS
    /// with no answer gets Light.
    fn restyle(self: *Shell, window: platform.Platform) void {
        self.styled = true;
        if (!self.follow_os) return;
        self.theme = colors.resolve(.system, window.appearance() == .dark);
    }

    /// Apply one input event against this frame's layout.
    pub fn handle(self: *Shell, event: platform.Event, solved: *const pane_layout.Solved) void {
        switch (event) {
            .quit => self.open = false,
            .button => |press| {
                if (press.button != 1) return;
                self.held = if (press.down) solved.hit(press.x, press.y) else null;
                if (!press.down) return self.releaseBoard(press.x, press.y);
                if (self.held != null) return;
                if (self.pressFields(press.x, press.y)) return;
                if (shell_titles.press(&self.layout, solved, press.x, press.y)) return;
                if (self.pressBoard(solved, press.x, press.y)) return;
                if (self.link) |link| if (self.devices) |devices| {
                    if (self.faults) |faults| if (faults.clickIn(link, devices, &self.layout, solved, press.x, press.y)) return;
                    if (devices.clickIn(link, &self.layout, solved, press.x, press.y)) return;
                };
                if (self.registers) |registers| if (registers.clickIn(&self.layout, solved, press.x, press.y)) return;
                const camera = self.camera orelse return;
                _ = camera.clickIn(&self.layout, solved, press.x, press.y);
            },
            .pointer => |at| {
                self.pointer_at = .{ .x = at.x, .y = at.y };
                const found = self.held orelse return self.moveBoard(at.x, at.y);
                const axis = self.layout.node(found.split).body.split.axis;
                self.layout.drag(found, if (axis == .across) at.x else at.y);
            },
            .wheel => |turn| {
                const console = self.console orelse return;
                _ = console.wheelIn(&self.layout, solved, self.pointer_at.x, self.pointer_at.y, turn.dy);
            },
            .text, .key => {
                if (self.pageConsole(event, solved)) return;
                if (self.time) |time| if (self.link) |link| {
                    if (time.handle(event, link)) return;
                };
                if (self.plug) |plug| _ = plug.handle(event);
                if (self.camera_file) |file| _ = file.handle(event);
            },
            else => {},
        }
    }

    /// Page Up or Page Down over a console leaf (RA8EMU-1122).
    fn pageConsole(self: *Shell, event: platform.Event, solved: *const pane_layout.Solved) bool {
        const key = switch (event) {
            .key => |key| key,
            else => return false,
        };
        const console = self.console orelse return false;
        if (!key.down) return false;
        return console.pageIn(&self.layout, solved, self.pointer_at.x, self.pointer_at.y, key.code);
    }

    /// Offer a press to the text fields and the time bar, so each one it
    /// misses lets the keyboard go.
    fn pressFields(self: *Shell, x: i32, y: i32) bool {
        const in_plug = if (self.plug) |plug| plug.press(x, y) else false;
        const in_file = if (self.camera_file) |file| file.press(x, y) else false;
        return self.pressBar(x, y) or in_plug or in_file;
    }

    fn pressBar(self: *Shell, x: i32, y: i32) bool {
        const time = self.time orelse return false;
        const link = self.link orelse return false;
        return time.press(self.bar, x, y, &self.status, link);
    }

    /// Board time for an input: what the time bar last knew, or zero.
    fn boardNow(self: *const Shell) u64 {
        const time = self.time orelse return 0;
        return time.boardNow();
    }

    /// Offer a left press to the board leaf: a switch, or the panel.
    fn pressBoard(self: *Shell, solved: *const pane_layout.Solved, x: i32, y: i32) bool {
        const pointer = self.board_input orelse return false;
        const board = self.board orelse return false;
        return pointer.down(board, &self.layout, solved, x, y, self.boardNow());
    }

    fn moveBoard(self: *Shell, x: i32, y: i32) void {
        const pointer = self.board_input orelse return;
        const board = self.board orelse return;
        pointer.move(board, x, y);
    }

    /// The left button came up: the board leaf sends the click or the touch
    /// it had under way, if any.
    fn releaseBoard(self: *Shell, x: i32, y: i32) void {
        const pointer = self.board_input orelse return;
        const board = self.board orelse return;
        const link = self.link orelse return;
        pointer.up(board, link, x, y, self.boardNow());
    }

    /// The wall clock, or zero for a shell that was given none.
    fn now(self: *const Shell) u64 {
        const clock = self.clock orelse return 0;
        return clock.now();
    }

    /// One round with the session: send what is due and take what has
    /// arrived, and when the session is served in this process let it answer
    /// and take that too.
    fn exchange(self: *Shell) !void {
        try self.pump();
        const server = self.server orelse return;
        try server.answer();
        try self.pump();
    }

    /// Pay what this frame owes a lit run (shell_run.zig), one slice at a
    /// time: each is answered and taken before the next goes out, and none
    /// goes out while the session's earlier output is still unread. A
    /// session in another process answers in its own time, so it gets one
    /// slice a frame.
    fn paySlices(self: *Shell) !void {
        const time = self.time orelse return;
        const link = self.link orelse return;
        time.frame(link, self.now());
        while (self.drained and time.run.next(link, self.now())) {
            const server = self.server orelse return;
            try server.answer();
            try self.pump();
        }
    }

    /// A pause the time bar settled: the status bar shows the halt, and the
    /// core's leaves read it again.
    fn settle(self: *Shell) void {
        const time = self.time orelse return;
        if (!time.settle(&self.status)) return;
        if (self.registers) |registers| registers.refresh();
        if (self.stack) |stack| stack.refresh();
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
        if (self.stack) |stack| stack.attach(link);
        self.drained = false;
        var taken: usize = 0;
        while (taken < max_arrivals) : (taken += 1) {
            const arrival = link.pump() orelse {
                self.drained = true;
                break;
            };
            // A slice's end is not a stop: the run goes on.
            if (self.time) |time| if (time.observe(arrival, self.now()) == .boundary) continue;
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
        self.settle();
    }

    /// The stack, registers, memory and code leaves: all start over after a load,
    /// then take the arrival, and memory and code follow each core's fresh
    /// registers.
    fn observeCore(self: *Shell, loaded: bool, arrival: session_link.Arrival) void {
        if (self.stack) |stack| {
            if (loaded) stack.reload();
            stack.observe(arrival);
        }
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
