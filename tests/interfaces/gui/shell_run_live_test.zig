//! The shell runs an image from its window (RA8EMU-1118, RA8EMU-1099): a
//! headless window clicks Run, Pause and Step on the time bar of a shell
//! whose session is served in-process, the way ra8_gui's is. The image goes
//! on frame after frame while the window keeps presenting, Pause halts it
//! between slices and the registers leaf reads the core again, Step runs
//! one instruction, and a speed typed into the bar scales what a frame pays.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Live = @import("live_shell.zig").Live;

const proto = ra8.rpc.session.rpc;
const bar = gui_app.time_bar;
const codes = gui_app.speed_field.codes;
const frame_ns = gui_app.shell.run.frame_ns;

/// Blinks LED1 twice and then parks in a loop, so it never stops by itself.
/// Its clock is 1 GHz and the session runs a few million instructions a
/// second, so the bar's speed starts at a thousandth of real time here.
const image = "tests/fixtures/gpio/blink.elf";
const slow: u64 = 1;
/// What a frame owes at `slow`.
const owed_ns: u64 = frame_ns * slow / 1000;
/// The board time one slice may land past its target: a few cycles.
const slack_ns: u64 = 10;

test "ra8_gui's image opens halted, with Pause lit and nothing run" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    const halt = live.shell.status.run.halted;
    try std.testing.expectEqual(@as(?proto.StopReason, null), halt.reason);
    try std.testing.expectEqual(live.pc(), halt.address);
    try std.testing.expectEqual(@as(?u64, null), live.time.run.board_ns);
    for (0..3) |_| try live.step();
    try std.testing.expect(!live.time.run.lit);
    const pause = Live.barRect(.pause);
    const run = Live.barRect(.run);
    try std.testing.expectEqual(dark.pauseLit(), live.pixel(pause.x + 1, pause.y + 1));
    try std.testing.expectEqual(dark.face, live.pixel(run.x + 1, run.y + 1));
}

test "Run keeps the image going frame after frame while the window keeps presenting" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    const serial = live.registers.cores[0].serial;
    try live.click(.run);
    try live.step();
    try std.testing.expect(live.shell.status.run == .running);
    var at = live.boardTime();
    try std.testing.expect(at >= owed_ns);
    for (0..4) |_| {
        const presents = live.window.presents;
        try live.step();
        try std.testing.expectEqual(presents + 1, live.window.presents);
        try std.testing.expect(live.shell.status.run == .running);
        const moved = live.boardTime() - at;
        try std.testing.expect(moved >= owed_ns and moved < owed_ns + slack_ns);
        at = live.boardTime();
    }
    // A slice's end is not a stop: no leaf read the core while it ran.
    try std.testing.expectEqual(serial, live.registers.cores[0].serial);
    try std.testing.expect(!live.registers.cores[0].want);
    // The bar shows it: Run is lit and Pause is not, and the strip says so.
    const pause = Live.barRect(.pause);
    const run = Live.barRect(.run);
    try std.testing.expectEqual(dark.runLit(), live.pixel(run.x + 1, run.y + 1));
    try std.testing.expectEqual(dark.face, live.pixel(pause.x + 1, pause.y + 1));
    var line: [256]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try live.shell.status.text(live.link.state, &line), "| running"));
}

test "Pause halts the image between slices and the registers leaf reads the core again" {
    var live: Live = undefined;
    try live.open(image, slow);
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
    const stopped_at = live.boardTime();
    try live.untilRead(serial);
    for (0..3) |_| try live.step();
    try std.testing.expectEqual(stopped_at, live.boardTime());
    try std.testing.expectEqual(halt.address, live.pc());
    try std.testing.expectEqual(@as(?u64, stopped_at), live.time.readout.virtual_ns);

    // Run again carries on from there.
    try live.click(.run);
    try live.step();
    try std.testing.expect(live.shell.status.run == .running);
    try std.testing.expect(live.boardTime() >= stopped_at + owed_ns);
}

test "Step runs one instruction and the registers leaf follows it" {
    var live: Live = undefined;
    try live.open(image, slow);
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
    try live.open(image, slow);
    defer live.deinit();
    try live.click(.field);
    try live.window.feed(.{ .text = .of("0.004") });
    try live.window.feed(.{ .key = .{ .code = codes.enter, .down = true } });
    for (0..3) |_| try live.step();
    try std.testing.expectEqual(@as(u64, 4), live.time.field.applied);
    try live.click(.run);
    try live.step();
    const at = live.boardTime();
    try live.step();
    const moved = live.boardTime() - at;
    try std.testing.expect(moved >= 4 * owed_ns and moved < 4 * owed_ns + slack_ns);
}
