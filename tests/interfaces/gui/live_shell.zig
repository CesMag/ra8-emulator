//! The shell as ra8_gui builds it, on a headless window with its session
//! served in-process and a clock the test moves: the fixture of the tests
//! that click the real shell loop (shell_run_live_test.zig,
//! shell_board_live_test.zig).
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Manual = @import("manual_clock.zig").Manual;

const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const bar = gui_app.time_bar;
const shell_frame = gui_app.shell.frame;
const Headless = gui_app.headless.Headless;

pub const width = 640;
pub const height = 480;

pub const Live = struct {
    session: gui_app.local_session.LocalSession,
    /// Frozen at zero: the shell's run sizing read no clock off the old
    /// loopback, so the native stamp must read none either.
    worker_clock: Manual = .{},
    worker: gui_app.session_worker.Worker,
    link: gui_app.session_link.Link,
    shell: gui_app.shell.loop.Shell,
    window: Headless,
    clock: Manual,
    time: gui_app.shell.time.Time,
    registers: gui_app.shell.registers.Pair,
    board: gui_app.shell.board.Board,
    pointer: gui_app.shell.board.input.Pointer,
    panes: gui_app.shell.panes.Panes,
    stack: gui_app.shell.stack.Pair,
    files: gui_app.shell.open.Open,
    branches: gui_app.shell.branch_state.Feed,
    diff: gui_app.shell.diff_state.State,
    filmstrip: gui_app.shell.filmstrip_feed.Feed,

    /// Opens in place and steps until `image` has loaded and halted. The
    /// bar's speed starts at `milli` thousandths of real time: the fixture
    /// images run a 1 GHz clock, which the session cannot keep up with.
    pub fn open(self: *Live, image: []const u8, milli: u64) !void {
        return self.openWith(image, milli, null, null);
    }

    /// `open` on a session that records `history`, with `prepare` run on the
    /// served session before the shell has stepped once. A recording session
    /// is left as the image opened it, with no load of the shell's own.
    pub fn openWith(self: *Live, image: []const u8, milli: u64, history: ?ra8.rpc.served_setup.HistoryOpts, prepare: ?*const fn (*Live) anyerror!void) !void {
        // Field defaults do not apply to an `undefined` rig; reset first.
        self.worker_clock = .{};
        const gpa = std.testing.allocator;
        try self.session.openWith(gpa, std.testing.io, image, null, history);
        if (prepare) |run| try run(self);
        self.worker.bind(std.testing.io, gpa, &self.session, self.worker_clock.clock());
        self.link.openNative(&self.worker.native);
        self.shell = .init(gpa, try gui_app.pane_layout.twoCore(gpa));
        self.window = .init(gpa, width, height);
        self.clock = .{ .step_ns = 1000 };
        self.time = .{};
        self.time.field.applied = milli;
        self.registers = .{};
        self.stack = .{};
        self.board = .init(gpa);
        self.pointer = .{};
        self.branches = .{};
        self.diff = .{};
        self.filmstrip = .{};
        self.panes = .{ .board = &self.board, .board_input = &self.pointer, .stack = &self.stack, .branches = &self.branches, .diff = &self.diff.view };
        self.shell.branches = &self.branches;
        self.shell.diff = &self.diff;
        self.shell.filmstrip = &self.filmstrip;
        self.shell.link = &self.link;
        self.shell.server = self.worker.inlineServer();
        self.shell.clock = self.clock.clock();
        self.shell.time = &self.time;
        self.shell.registers = &self.registers;
        self.shell.stack = &self.stack;
        self.shell.board = &self.board;
        self.shell.board_input = &self.pointer;
        self.shell.painter = self.panes.painter();
        self.files = .{ .io = std.testing.io, .allocator = gpa };
        self.shell.files = &self.files;
        try self.step();
        if (history != null) return;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try self.shell.status.load(&self.link, image, bytes);
        try self.untilRead(0);
    }

    /// Bring up cpu1 from `path` in the already-open session (RA8EMU-1192).
    pub fn openSecond(self: *Live, path: []const u8) !void {
        try self.session.openSecond(path);
        try self.step();
    }

    pub fn deinit(self: *Live) void {
        self.board.deinit();
        self.window.deinit();
        self.shell.deinit();
        self.worker.deinit();
        self.session.deinit();
    }

    /// One frame of the shell.
    pub fn step(self: *Live) !void {
        try std.testing.expect(try self.shell.step(self.window.platform()));
    }

    /// Step until the core is halted and the registers leaf has published
    /// a batch after batch `serial`, for at most thirty frames.
    pub fn untilRead(self: *Live, serial: u32) !void {
        return self.untilReadOn(0, serial);
    }

    /// Step until core `index`'s registers leaf has published a batch after
    /// batch `serial`, for at most thirty frames (RA8EMU-1192).
    pub fn untilReadOn(self: *Live, index: usize, serial: u32) !void {
        const registers = &self.registers.cores[index];
        for (0..30) |_| {
            // The open burst leaves reads queued in the mailbox; a command
            // sent before they drain is dropped as back-pressure, so settle
            // waits for the whole link to go quiet, not just the leaf.
            const quiet = if (self.link.native) |native|
                native.count == 0 and native.link.pendingCount() == 0 and native.ring_count == 0
            else
                false;
            if (quiet and self.shell.status.run == .halted and registers.serial != serial and registers.now != null and !registers.want and registers.left == 0) return;
            try self.step();
        }
        return error.NeverSettled;
    }

    /// Where `control` sits on the time bar.
    pub fn barRect(control: bar.Control) draw_list.Rect {
        return bar.Layout.of(shell_frame.toList(shell_frame.barArea(width, height))).rect(control);
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

    /// Step until cpu0's stack leaf shows a chain whose innermost frame is
    /// at `pc` with no ask due or in flight, for at most thirty frames.
    pub fn untilStack(self: *Live, pc_at: u32) !void {
        return self.untilStackOn(0, pc_at);
    }

    /// Step until core `index`'s stack leaf shows a chain whose innermost
    /// frame is at `pc` with no ask due or in flight, thirty frames at most.
    pub fn untilStackOn(self: *Live, index: usize, pc_at: u32) !void {
        const stack = &self.stack.cores[index];
        for (0..30) |_| {
            if (stack.now) |*now| if (now.count != 0 and now.frames[0].pc == pc_at and !stack.want and stack.asked == null) return;
            try self.step();
        }
        return error.NeverSettled;
    }

    /// CPU0's PC as the registers leaf shows it.
    pub fn pc(self: *const Live) u32 {
        return self.registers.cores[0].value(.pc).?;
    }

    /// Core `index`'s PC as the registers leaf shows it (RA8EMU-1192).
    pub fn pcOn(self: *const Live, index: usize) u32 {
        return self.registers.cores[index].value(.pc).?;
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
