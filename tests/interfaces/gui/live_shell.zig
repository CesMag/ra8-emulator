//! The shell as ra8_gui builds it, on a headless window with its session
//! served in-process and a clock the test moves: the fixture of the tests
//! that click the real shell loop (shell_run_live_test.zig,
//! shell_board_live_test.zig).
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Manual = @import("manual_clock.zig").Manual;

const proto = ra8.rpc.session_rpc;
const Env = proto.Client.Env;
const draw_list = ra8.render.draw_list;
const bar = gui_app.time_bar;
const shell_frame = gui_app.shell_frame;
const Headless = gui_app.headless.Headless;

pub const width = 640;
pub const height = 480;

pub const Live = struct {
    session: gui_app.local_session.LocalSession,
    rx: []u8,
    tx: []u8,
    link: gui_app.session_link.Link,
    shell: gui_app.shell_loop.Shell,
    window: Headless,
    clock: Manual,
    time: gui_app.shell_time.Time,
    registers: gui_app.shell_registers.Pair,
    board: gui_app.shell_board.Board,
    pointer: gui_app.shell_board_input.Pointer,
    panes: gui_app.shell_panes.Panes,

    /// Opens in place and steps until `image` has loaded and halted. The
    /// bar's speed starts at `milli` thousandths of real time: the fixture
    /// images run a 1 GHz clock, which the session cannot keep up with.
    pub fn open(self: *Live, image: []const u8, milli: u64) !void {
        const gpa = std.testing.allocator;
        try self.session.open(gpa, std.testing.io, image);
        self.rx = try gpa.alloc(u8, 2 * Env.max_frame);
        self.tx = try gpa.alloc(u8, Env.max_frame);
        self.link.open(self.session.transport(), self.rx, self.tx);
        self.shell = .init(gpa, try gui_app.pane_layout.twoCore(gpa));
        self.window = .init(gpa, width, height);
        self.clock = .{ .step_ns = 1000 };
        self.time = .{};
        self.time.field.applied = milli;
        self.registers = .{};
        self.board = .init(gpa);
        self.pointer = .{};
        self.panes = .{ .board = &self.board, .board_input = &self.pointer };
        self.shell.link = &self.link;
        self.shell.server = gui_app.shell_main.served(&self.session);
        self.shell.clock = self.clock.clock();
        self.shell.time = &self.time;
        self.shell.registers = &self.registers;
        self.shell.board = &self.board;
        self.shell.board_input = &self.pointer;
        self.shell.painter = self.panes.painter();
        try self.step();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try self.shell.status.load(&self.link, image, bytes);
        try self.untilRead(0);
    }

    pub fn deinit(self: *Live) void {
        const gpa = std.testing.allocator;
        self.board.deinit();
        self.window.deinit();
        self.shell.deinit();
        gpa.free(self.tx);
        gpa.free(self.rx);
        self.session.deinit();
    }

    /// One frame of the shell.
    pub fn step(self: *Live) !void {
        try std.testing.expect(try self.shell.step(self.window.platform()));
    }

    /// Step until the core is halted and the registers leaf has published
    /// a batch after batch `serial`, for at most thirty frames.
    pub fn untilRead(self: *Live, serial: u32) !void {
        const registers = &self.registers.cores[0];
        for (0..30) |_| {
            if (self.shell.status.run == .halted and registers.serial != serial and !registers.want and registers.left == 0) return;
            try self.step();
        }
        return error.NeverSettled;
    }

    /// Where `control` sits on the time bar.
    pub fn barRect(control: bar.Control) draw_list.Rect {
        return bar.Layout.of(shell_frame.barArea(width, height)).rect(control);
    }

    /// Press or release the left button at (`x`, `y`).
    pub fn button(self: *Live, down: bool, x: i32, y: i32) !void {
        try self.window.feed(.{ .button = .{ .button = 1, .down = down, .x = x, .y = y } });
    }

    /// Press and release the left button in the middle of `area`.
    pub fn clickIn(self: *Live, area: draw_list.Rect) !void {
        const x = area.x + @divTrunc(area.w, 2);
        const y = area.y + @divTrunc(area.h, 2);
        try self.button(true, x, y);
        try self.button(false, x, y);
    }

    pub fn click(self: *Live, control: bar.Control) !void {
        try self.clickIn(barRect(control));
    }

    /// The body of the layout's board leaf.
    pub fn boardBody(self: *Live) !draw_list.Rect {
        const gpa = std.testing.allocator;
        var solved = try shell_frame.solve(&self.shell.layout, gpa, width, height);
        defer solved.deinit(gpa);
        for (solved.panes.items) |placed| {
            const pane = self.shell.layout.pane(placed.index) orelse continue;
            if (pane.kind == .board) return shell_frame.bodyOf(placed.area);
        }
        return error.NoBoardLeaf;
    }

    /// Board time at the end of the last slice.
    pub fn boardTime(self: *const Live) u64 {
        return self.time.run.board_ns.?;
    }

    /// CPU0's PC as the registers leaf shows it.
    pub fn pc(self: *const Live) u32 {
        return self.registers.cores[0].value(.pc).?;
    }

    /// The pixel at (`x`, `y`) of the last frame the window was shown.
    pub fn pixel(self: *const Live, x: i32, y: i32) draw_list.Color {
        return self.window.last.?.at(@intCast(x), @intCast(y));
    }

    /// The pixel in the middle of `area` of the last frame.
    pub fn middle(self: *const Live, area: draw_list.Rect) draw_list.Color {
        return self.pixel(area.x + @divTrunc(area.w, 2), area.y + @divTrunc(area.h, 2));
    }
};
