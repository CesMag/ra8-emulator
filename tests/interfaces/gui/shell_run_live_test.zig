//! The shell runs an image from its window (RA8EMU-1118, RA8EMU-1099): a
//! headless window clicks Run, Pause and Step on the time bar of a shell
//! whose session is served in-process, the way ra8_gui's is. The image goes
//! on frame after frame while the window keeps presenting, Pause halts it
//! between slices and the registers leaf reads the core again, Step runs
//! one instruction, and a speed typed into the bar scales what a frame pays.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Manual = @import("manual_clock.zig").Manual;

const proto = ra8.rpc.session_rpc;
const Env = proto.Client.Env;
const bar = gui_app.time_bar;
const shell_frame = gui_app.shell_frame;
const shell_run = gui_app.shell_run;
const codes = gui_app.speed_field.codes;
const Headless = gui_app.headless.Headless;
const frame_ns = shell_run.frame_ns;

/// Blinks LED1 twice and then parks in a loop, so it never stops by itself.
/// Its clock is 1 GHz and the session runs a few million instructions a
/// second, so the bar's speed starts at a thousandth of real time here.
const image = "tests/fixtures/gpio/blink.elf";
const slow: u64 = 1;
/// What a frame owes at `slow`.
const owed_ns: u64 = frame_ns * slow / 1000;
const width = 640;
const height = 480;
/// The board time one slice may land past its target: a few cycles.
const slack_ns: u64 = 10;

const Live = struct {
    session: gui_app.local_session.LocalSession,
    rx: []u8,
    tx: []u8,
    link: gui_app.session_link.Link,
    shell: gui_app.shell_loop.Shell,
    window: Headless,
    clock: Manual,
    time: gui_app.shell_time.Time,
    registers: gui_app.shell_registers.Pair,

    /// Opens in place and steps until the image has loaded and halted.
    fn open(self: *Live) !void {
        const gpa = std.testing.allocator;
        try self.session.open(gpa, std.testing.io, image);
        self.rx = try gpa.alloc(u8, 2 * Env.max_frame);
        self.tx = try gpa.alloc(u8, Env.max_frame);
        self.link.open(self.session.transport(), self.rx, self.tx);
        self.shell = .init(gpa, try gui_app.pane_layout.twoCore(gpa));
        self.window = .init(gpa, width, height);
        self.clock = .{ .step_ns = 1000 };
        self.time = .{};
        self.time.field.applied = slow;
        self.registers = .{};
        self.shell.link = &self.link;
        self.shell.server = gui_app.shell_main.served(&self.session);
        self.shell.clock = self.clock.clock();
        self.shell.time = &self.time;
        self.shell.registers = &self.registers;
        try self.step();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try self.shell.status.load(&self.link, image, bytes);
        try self.untilRead(0);
    }

    fn deinit(self: *Live) void {
        const gpa = std.testing.allocator;
        self.window.deinit();
        self.shell.deinit();
        gpa.free(self.tx);
        gpa.free(self.rx);
        self.session.deinit();
    }

    fn step(self: *Live) !void {
        try std.testing.expect(try self.shell.step(self.window.platform()));
    }

    /// Step until the core is halted and the registers leaf has published
    /// a batch after batch `serial`, for at most thirty frames.
    fn untilRead(self: *Live, serial: u32) !void {
        const registers = &self.registers.cores[0];
        for (0..30) |_| {
            if (self.shell.status.run == .halted and registers.serial != serial and !registers.want and registers.left == 0) return;
            try self.step();
        }
        return error.NeverSettled;
    }

    fn rect(control: bar.Control) ra8.render.draw_list.Rect {
        return bar.Layout.of(shell_frame.barArea(width, height)).rect(control);
    }

    /// Press and release the left button in the middle of `control`.
    fn click(self: *Live, control: bar.Control) !void {
        const at = rect(control);
        const x = at.x + @divTrunc(at.w, 2);
        const y = at.y + @divTrunc(at.h, 2);
        try self.window.feed(.{ .button = .{ .button = 1, .down = true, .x = x, .y = y } });
        try self.window.feed(.{ .button = .{ .button = 1, .down = false, .x = x, .y = y } });
    }

    fn board(self: *const Live) u64 {
        return self.time.run.board_ns.?;
    }

    fn pc(self: *const Live) u32 {
        return self.registers.cores[0].value(.pc).?;
    }
};

test "ra8_gui's image opens halted, with Pause lit and nothing run" {
    var live: Live = undefined;
    try live.open();
    defer live.deinit();
    const halt = live.shell.status.run.halted;
    try std.testing.expectEqual(@as(?proto.StopReason, null), halt.reason);
    try std.testing.expectEqual(live.pc(), halt.address);
    try std.testing.expectEqual(@as(?u64, null), live.time.run.board_ns);
    for (0..3) |_| try live.step();
    try std.testing.expect(!live.time.run.lit);
    const frame = live.window.last.?;
    const pause = Live.rect(.pause);
    try std.testing.expectEqual(bar.lit, frame.at(@intCast(pause.x + 1), @intCast(pause.y + 1)));
    try std.testing.expectEqual(bar.face, frame.at(@intCast(Live.rect(.run).x + 1), @intCast(Live.rect(.run).y + 1)));
}

test "Run keeps the image going frame after frame while the window keeps presenting" {
    var live: Live = undefined;
    try live.open();
    defer live.deinit();
    const serial = live.registers.cores[0].serial;
    try live.click(.run);
    try live.step();
    try std.testing.expect(live.shell.status.run == .running);
    var at = live.board();
    try std.testing.expect(at >= owed_ns);
    for (0..4) |_| {
        const presents = live.window.presents;
        try live.step();
        try std.testing.expectEqual(presents + 1, live.window.presents);
        try std.testing.expect(live.shell.status.run == .running);
        const moved = live.board() - at;
        try std.testing.expect(moved >= owed_ns and moved < owed_ns + slack_ns);
        at = live.board();
    }
    // A slice's end is not a stop: no leaf read the core while it ran.
    try std.testing.expectEqual(serial, live.registers.cores[0].serial);
    try std.testing.expect(!live.registers.cores[0].want);
    // The bar shows it: Run is lit and Pause is not, and the strip says so.
    const frame = live.window.last.?;
    try std.testing.expectEqual(bar.lit, frame.at(@intCast(Live.rect(.run).x + 1), @intCast(Live.rect(.run).y + 1)));
    try std.testing.expectEqual(bar.face, frame.at(@intCast(Live.rect(.pause).x + 1), @intCast(Live.rect(.pause).y + 1)));
    var line: [256]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try live.shell.status.text(live.link.state, &line), "| running"));
}

test "Pause halts the image between slices and the registers leaf reads the core again" {
    var live: Live = undefined;
    try live.open();
    defer live.deinit();
    const reset = live.shell.status.run.halted.address;
    const serial = live.registers.cores[0].serial;
    try live.click(.run);
    try live.step();
    try live.step();
    try live.click(.pause);
    try live.step();
    const halt = live.shell.status.run.halted;
    try std.testing.expectEqual(@as(?proto.StopReason, null), halt.reason);
    try std.testing.expect(halt.address != reset);
    try std.testing.expect(!live.time.run.lit);
    const stopped_at = live.board();
    try live.untilRead(serial);
    for (0..3) |_| try live.step();
    try std.testing.expectEqual(stopped_at, live.board());
    try std.testing.expectEqual(halt.address, live.pc());
    try std.testing.expectEqual(@as(?u64, stopped_at), live.time.readout.virtual_ns);

    // Run again carries on from there.
    try live.click(.run);
    try live.step();
    try std.testing.expect(live.shell.status.run == .running);
    try std.testing.expect(live.board() >= stopped_at + owed_ns);
}

test "Step runs one instruction and the registers leaf follows it" {
    var live: Live = undefined;
    try live.open();
    defer live.deinit();
    const reset = live.shell.status.run.halted.address;
    const serial = live.registers.cores[0].serial;
    try live.click(.step);
    try live.step();
    try live.untilRead(serial);
    const halt = live.shell.status.run.halted;
    try std.testing.expectEqual(@as(?proto.StopReason, .stepped), halt.reason);
    try std.testing.expect(halt.address != reset);
    try std.testing.expectEqual(halt.address, live.pc());
    try std.testing.expect(live.registers.cores[0].serial != serial);
    try std.testing.expect(!live.time.run.lit);
}

test "a speed typed into the bar's field scales what each frame pays" {
    var live: Live = undefined;
    try live.open();
    defer live.deinit();
    try live.click(.field);
    try live.window.feed(.{ .text = .of("0.004") });
    try live.window.feed(.{ .key = .{ .code = codes.enter, .down = true } });
    for (0..3) |_| try live.step();
    try std.testing.expectEqual(@as(u64, 4), live.time.field.applied);
    try live.click(.run);
    try live.step();
    const at = live.board();
    try live.step();
    const moved = live.board() - at;
    try std.testing.expect(moved >= 4 * owed_ns and moved < 4 * owed_ns + slack_ns);
}
