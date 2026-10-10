//! Tests for src/interfaces/gui/shell_time.zig (RA8EMU-1118): the time bar's
//! clicks light, pause and step an in-process session's core, the speed
//! field takes the keyboard and sets what a frame owes, and the clock is
//! read once while the image is halted and again while it runs.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Rig = @import("local_rig.zig").Rig;

const proto = ra8.rpc.session_rpc;
const bar = gui_app.time_bar;
const shell_run = gui_app.shell_run;
const shell_time = gui_app.shell_time;
const codes = gui_app.speed_field.codes;
const Status = gui_app.status_bar.Status;
const Time = shell_time.Time;
const Rect = ra8.render.draw_list.Rect;

const image = "tests/fixtures/gpio/blink.elf";
const slow: u64 = 1;
const area: Rect = .{ .x = 0, .y = 100, .w = 480, .h = bar.height };

const Bench = struct {
    rig: Rig,
    status: Status = .{},
    time: Time = .{},
    now_ns: u64 = 0,

    /// The image's clock is 1 GHz and the session runs a few million
    /// instructions a second, so frames are paid at a thousandth of real time.
    fn open(self: *Bench) !void {
        self.* = .{ .rig = undefined };
        try self.rig.open(image);
        errdefer self.rig.deinit();
        try self.rig.load(&self.status, image);
        self.time.field.applied = slow;
    }

    /// Click the middle of `control`.
    fn click(self: *Bench, control: bar.Control) bool {
        const at = bar.Layout.of(area).rect(control);
        return self.time.press(area, at.x + @divTrunc(at.w, 2), at.y + @divTrunc(at.h, 2), &self.status, &self.rig.link);
    }

    /// Let the session answer and feed what it sent to the bar and the status.
    fn exchange(self: *Bench) !void {
        try self.rig.session.answer();
        while (self.rig.link.pump()) |arrival| {
            if (self.time.observe(arrival, self.now_ns) == .boundary) continue;
            self.status.observe(&self.rig.link, arrival);
        }
        _ = self.time.settle(&self.status);
    }

    /// One window frame at the bench's wall time.
    fn frame(self: *Bench) !void {
        self.time.frame(&self.rig.link, self.now_ns);
        while (self.time.run.next(&self.rig.link, self.now_ns)) try self.exchange();
        try self.exchange();
    }
};

test "Run lights the run, frames keep it going, and Pause halts it with no reason of its own" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    const reset = bench.status.run.halted.address;
    try std.testing.expect(bench.click(.run));
    try std.testing.expect(bench.time.run.lit);
    try std.testing.expect(bench.status.run == .running);
    try std.testing.expectEqual(@as(?u32, null), bench.status.run_id);

    try bench.frame();
    try bench.frame();
    try std.testing.expect(bench.status.run == .running);
    try std.testing.expect(bench.time.run.board_ns.? >= 2 * (shell_run.frame_ns * slow / 1000));
    try std.testing.expect(bench.time.view(&bench.status).run_lit);

    try std.testing.expect(bench.click(.pause));
    try std.testing.expect(bench.time.settle(&bench.status));
    const halt = bench.status.run.halted;
    try std.testing.expectEqual(@as(?proto.StopReason, null), halt.reason);
    try std.testing.expect(halt.address != reset);
    try std.testing.expectEqual(try bench.rig.pc(.cpu0), halt.address);
    try std.testing.expect(bench.time.view(&bench.status).pause_lit);
    try std.testing.expect(!bench.time.settle(&bench.status));
}

test "Step runs one instruction on a halted core and does nothing while Run is lit" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    const reset = bench.status.run.halted.address;
    try std.testing.expect(bench.click(.step));
    try bench.rig.settle(&bench.status);
    try std.testing.expectEqual(@as(?proto.StopReason, .stepped), bench.status.run.halted.reason);
    try std.testing.expect(bench.status.run.halted.address != reset);

    try std.testing.expect(bench.click(.run));
    try std.testing.expect(bench.click(.step));
    try std.testing.expectEqual(@as(?u32, null), bench.status.run_id);
    try std.testing.expect(bench.time.run.lit);
}

test "Run does nothing before the image has halted, and Pause nothing while it is halted" {
    var rig: Rig = undefined;
    try rig.open(image);
    defer rig.deinit();
    var status: Status = .{};
    var time: Time = .{};
    const at = bar.Layout.of(area).run;
    try std.testing.expect(time.press(area, at.x + 1, at.y + 1, &status, &rig.link));
    try std.testing.expect(!time.run.lit);
    try std.testing.expect(status.run == .unknown);
    const pause = bar.Layout.of(area).pause;
    try std.testing.expect(time.press(area, pause.x + 1, pause.y + 1, &status, &rig.link));
    try std.testing.expect(!time.settle(&status));
}

test "a click on the speed field takes the keyboard, and Enter sets what a frame owes" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    const link = &bench.rig.link;
    try std.testing.expect(!bench.time.handle(.{ .text = .of("2") }, link));
    try std.testing.expect(bench.click(.field));
    try std.testing.expect(bench.time.editing);
    try std.testing.expect(bench.time.handle(.{ .text = .of("2") }, link));
    try std.testing.expect(bench.time.view(&bench.status).editing);
    try std.testing.expect(bench.time.handle(.{ .key = .{ .code = codes.enter, .down = true } }, link));
    try std.testing.expect(!bench.time.editing);
    try bench.exchange();
    try std.testing.expectEqual(@as(u64, 2000), bench.time.field.applied);
    bench.time.frame(link, 0);
    try std.testing.expectEqual(@as(?u64, 2 * shell_run.frame_ns), bench.time.run.owed_ns);

    try std.testing.expect(bench.click(.field));
    try std.testing.expect(bench.time.handle(.{ .text = .of("max") }, link));
    try std.testing.expect(bench.time.handle(.{ .key = .{ .code = codes.enter, .down = true } }, link));
    try bench.exchange();
    bench.time.frame(link, 0);
    try std.testing.expectEqual(@as(?u64, null), bench.time.run.owed_ns);
}

test "Escape, and a press off the field, let the keyboard go" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    const link = &bench.rig.link;
    try std.testing.expect(bench.click(.field));
    try std.testing.expect(bench.time.handle(.{ .text = .of("7") }, link));
    try std.testing.expect(bench.time.handle(.{ .key = .{ .code = codes.escape, .down = true } }, link));
    try std.testing.expect(!bench.time.editing);
    try std.testing.expectEqual(slow, bench.time.field.applied);

    try std.testing.expect(bench.click(.field));
    try std.testing.expect(!bench.time.press(area, area.x + 1, area.y - 10, &bench.status, link));
    try std.testing.expect(!bench.time.editing);
    // The gap between two controls is the bar's, and lets go as well.
    try std.testing.expect(bench.click(.field));
    try std.testing.expect(bench.time.press(area, area.x + area.w - 1, area.y + 1, &bench.status, link));
    try std.testing.expect(!bench.time.editing);
}

test "the clock is read once while the image is halted and again every poll while it runs" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    try std.testing.expectEqual(@as(?u64, null), bench.time.readout.virtual_ns);
    try bench.frame();
    const at_reset = bench.time.readout.virtual_ns orelse return error.NoClock;
    bench.now_ns += shell_time.poll_ns;
    bench.time.frame(&bench.rig.link, bench.now_ns);
    try std.testing.expect(!bench.time.readout.waiting());

    // Lit, a read goes out as soon as a poll interval has passed, and not
    // again until the next one has.
    try std.testing.expect(bench.click(.run));
    bench.time.frame(&bench.rig.link, bench.now_ns);
    try std.testing.expect(bench.time.readout.waiting());
    try bench.frame();
    bench.time.frame(&bench.rig.link, bench.now_ns);
    try std.testing.expect(!bench.time.readout.waiting());
    bench.now_ns += shell_time.poll_ns;
    try bench.frame();
    try std.testing.expect(bench.time.readout.virtual_ns.? > at_reset);

    // A pause leaves one more read due, so the bar shows where time stopped.
    try std.testing.expect(bench.click(.pause));
    try std.testing.expect(bench.time.settle(&bench.status));
    try bench.frame();
    try std.testing.expectEqual(bench.time.run.board_ns, bench.time.readout.virtual_ns);
}
