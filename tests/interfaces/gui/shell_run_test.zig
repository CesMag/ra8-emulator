//! Tests for src/interfaces/gui/shell_run.zig (RA8EMU-1118): a lit run pays
//! each frame's board time in slices against an in-process session, a
//! slice's end is a boundary and not a stop, a pause hands back the halt,
//! the unit follows what the host can do, and a refused slice or a real stop
//! ends the run.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Rig = @import("local_rig.zig").Rig;
const Manual = @import("manual_clock.zig").Manual;

const proto = ra8.rpc.session_rpc;
const shell_run = gui_app.shell_run;
const Run = shell_run.Run;
const Status = gui_app.status_bar.Status;
const frame_ns = shell_run.frame_ns;

/// Blinks LED1 twice and then parks in a loop, so it never stops by itself.
/// Its clock is 1 GHz and the session runs a few million instructions a
/// second, so the frames here are paid at a thousandth of real time.
const image = "tests/fixtures/gpio/blink.elf";
const slow: u64 = 1;
/// What a frame owes at `slow`.
const owed_ns: u64 = frame_ns * slow / 1000;
/// The board time one slice may land past its target: a few cycles.
const slack_ns: u64 = 10;

const Seen = struct { slices: u32 = 0, boundaries: u32 = 0, stops: u32 = 0 };

fn take(rig: *Rig, run: *Run, clock: *Manual, seen: *Seen) void {
    while (rig.link.pump()) |arrival| switch (run.observe(arrival, clock.read())) {
        .slice => seen.slices += 1,
        .boundary => seen.boundaries += 1,
        .other => if (arrival == .event and arrival.event.topic == @backingInt(proto.Topic.stop)) {
            seen.stops += 1;
        },
    };
}

/// Pay one frame the way the shell does: each slice is answered and taken
/// before the next goes out.
fn payFrame(rig: *Rig, run: *Run, clock: *Manual, milli: u64) !Seen {
    var seen: Seen = .{};
    run.frame(clock.read(), milli);
    while (run.next(&rig.link, clock.read())) {
        try rig.session.answer();
        take(rig, run, clock, &seen);
    }
    return seen;
}

/// An `advance` answer that moved board time by `moved_ns` and ran on.
var advanced_buf: [64]u8 = undefined;
fn advanced(moved_ns: u64) ![]const u8 {
    return proto.encode(proto.Advanced, .{ .core = .cpu0, .from_ns = 0, .to_ns = moved_ns, .reason = .count, .address = 0 }, &advanced_buf);
}

const Bench = struct {
    rig: Rig,
    status: Status = .{},
    clock: Manual = .{ .step_ns = 1000 },
    run: Run = .{},

    fn open(self: *Bench) !void {
        self.* = .{ .rig = undefined };
        try self.rig.open(image);
        errdefer self.rig.deinit();
        try self.rig.load(&self.status, image);
        self.run.start(self.status.run.halted.address);
    }

    fn pay(self: *Bench, milli: u64) !Seen {
        return payFrame(&self.rig, &self.run, &self.clock, milli);
    }
};

test "a frame pays what it owes in growing slices, and no slice's end is a stop" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    // From a unit far under what the frame owes, as on a host that was slow.
    bench.run.unit_ns = 1000;
    const first = try bench.pay(slow);
    try std.testing.expect(first.slices > 2);
    try std.testing.expectEqual(first.slices, first.boundaries);
    try std.testing.expectEqual(@as(u32, 0), first.stops);
    try std.testing.expectEqual(@as(?u64, 0), bench.run.owed_ns);
    try std.testing.expect(bench.run.unit_ns > 1000);
    _ = try bench.pay(slow);
    try std.testing.expect(bench.run.unit_ns >= owed_ns);
    const before = bench.run.board_ns.?;

    const steady = try bench.pay(slow);
    try std.testing.expectEqual(@as(u32, 1), steady.slices);
    const moved = bench.run.board_ns.? - before;
    try std.testing.expect(moved >= owed_ns and moved < owed_ns + slack_ns);
    try std.testing.expect(bench.run.lit);
    try std.testing.expectEqual(try bench.rig.pc(.cpu0), bench.run.address);
}

test "the unit never grows past one frame of board time" {
    var run: Run = .{ .lit = true, .unit_ns = frame_ns - 1 };
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    run.frame(0, gui_app.speed_field.max_wire);
    run.until_ns = std.math.maxInt(u64);
    try std.testing.expect(run.next(&bench.rig.link, 0));
    try std.testing.expectEqual(frame_ns - 1, run.asked_ns);
    // Answered in no time at all: the unit doubles, to the frame and no further.
    _ = run.observe(.{ .response = .{ .id = run.slice_id.?, .result = .{ .ok = try advanced(frame_ns - 1) } } }, 0);
    try std.testing.expectEqual(frame_ns, run.unit_ns);
}

test "the speed scales what a frame owes, and a frame owes nothing from the one before" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    _ = try bench.pay(2);
    var before = bench.run.board_ns.?;
    _ = try bench.pay(1);
    var moved = bench.run.board_ns.? - before;
    try std.testing.expect(moved >= frame_ns / 1000 and moved < frame_ns / 1000 + slack_ns);

    before = bench.run.board_ns.?;
    _ = try bench.pay(4);
    moved = bench.run.board_ns.? - before;
    try std.testing.expect(moved >= frame_ns * 4 / 1000 and moved < frame_ns * 4 / 1000 + slack_ns);
}

test "max pays slices until the frame's share of wall time is spent" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    bench.clock.step_ns = shell_run.share_ns / 16;
    bench.run.unit_ns = 1000;
    const seen = try bench.pay(gui_app.speed_field.max_wire);
    try std.testing.expectEqual(@as(?u64, null), bench.run.owed_ns);
    try std.testing.expect(seen.slices >= 2 and seen.slices < 16);
    try std.testing.expect(bench.clock.now_ns >= bench.run.until_ns);
    try std.testing.expect(!bench.run.next(&bench.rig.link, bench.clock.read()));
}

test "a clock that stands still cannot hold a max frame past its slice limit" {
    var run: Run = .{ .lit = true, .until_ns = 1, .sent = shell_run.max_slices, .owed_ns = null };
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    try std.testing.expect(!run.next(&bench.rig.link, 0));
    run.sent = shell_run.max_slices - 1;
    try std.testing.expect(run.next(&bench.rig.link, 0));
}

test "a pause hands back where the last slice left the core, once" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    _ = try bench.pay(slow);
    bench.run.pause();
    try std.testing.expect(!bench.run.lit);
    const at = bench.run.halted() orelse return error.NoHalt;
    try std.testing.expectEqual(try bench.rig.pc(.cpu0), at);
    try std.testing.expectEqual(@as(?u32, null), bench.run.halted());
    const after = try bench.pay(slow);
    try std.testing.expectEqual(@as(u32, 0), after.slices);
}

test "a pause while a slice is out settles when the slice answers" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    bench.run.frame(bench.clock.read(), slow);
    try std.testing.expect(bench.run.next(&bench.rig.link, bench.clock.read()));
    try std.testing.expect(!bench.run.next(&bench.rig.link, bench.clock.read()));
    bench.run.pause();
    try std.testing.expectEqual(@as(?u32, null), bench.run.halted());
    var seen: Seen = .{};
    try bench.rig.session.answer();
    take(&bench.rig, &bench.run, &bench.clock, &seen);
    try std.testing.expectEqual(Seen{ .slices = 1, .boundaries = 1 }, seen);
    try std.testing.expectEqual(@as(?u32, bench.run.address), bench.run.halted());
}

test "a slice that overran the frame's share shrinks the unit in proportion, down to the least" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    bench.clock.step_ns = 0;
    var seen: Seen = .{};
    bench.run.frame(0, 1000);
    try std.testing.expect(bench.run.next(&bench.rig.link, 0));
    try bench.rig.session.answer();
    bench.clock.now_ns = 4 * shell_run.share_ns;
    take(&bench.rig, &bench.run, &bench.clock, &seen);
    try std.testing.expectEqual(shell_run.first_unit_ns / 4, bench.run.unit_ns);

    bench.run.frame(bench.clock.now_ns, 1000);
    try std.testing.expect(bench.run.next(&bench.rig.link, bench.clock.now_ns));
    try bench.rig.session.answer();
    bench.clock.now_ns += 1000 * shell_run.share_ns;
    take(&bench.rig, &bench.run, &bench.clock, &seen);
    try std.testing.expectEqual(shell_run.least_unit_ns, bench.run.unit_ns);
}

test "nothing goes out unless Run is lit" {
    var rig: Rig = undefined;
    try rig.open(image);
    defer rig.deinit();
    var run: Run = .{};
    run.frame(0, 1000);
    try std.testing.expect(!run.next(&rig.link, 0));
    try std.testing.expectEqual(@as(?u32, null), run.slice_id);
}

test "a slice the session refuses ends the run where it was" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    var run: Run = .{ .core = .cpu1 };
    run.start(0x1234);
    const seen = try payFrame(&bench.rig, &run, &bench.clock, 1000);
    try std.testing.expectEqual(@as(u32, 1), seen.slices);
    try std.testing.expect(run.refused and !run.lit);
    try std.testing.expectEqual(@as(?u32, 0x1234), run.halted());
}

test "a stop for a reason of its own ends the run and leaves its stop event for the others" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.rig.deinit();
    // Past the blinking, into the loop the image parks in.
    for (0..4) |_| _ = try bench.pay(slow);
    bench.run.pause();
    const parked = bench.run.halted().?;
    _ = try bench.rig.link.send(proto.Point, .set_breakpoint, .{ .core = .cpu0, .address = parked });
    bench.run.start(parked);
    const seen = try bench.pay(slow);
    try std.testing.expectEqual(@as(u32, 1), seen.slices);
    try std.testing.expectEqual(@as(u32, 0), seen.boundaries);
    try std.testing.expectEqual(@as(u32, 1), seen.stops);
    try std.testing.expect(!bench.run.lit);
    try std.testing.expectEqual(@as(?u32, null), bench.run.halted());
    try std.testing.expectEqual(parked, bench.run.address);
}
