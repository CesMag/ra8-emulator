//! Tests for --realtime, --speed, --run-for and the pace line (src/board/run/pacing.zig).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const parse = cli_app.cli.parse;
const clocks = ra8.chip.periph.clocks;
const time_policy = ra8.board.run;
const realtime = time_policy.pacing;

test "a run is unpaced unless it asks for --realtime" {
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(plain.speed == null);
    const paced = try parse(&[_][]const u8{ "emu", "a.elf", "--realtime" });
    try std.testing.expectEqual(@as(?u64, 1000), paced.speed);
}

test "an unpaced run prints no pace line" {
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try realtime.line(&stream, null, 0);
    try std.testing.expectEqualStrings("", stream.buffered());
}

test "the pace line gives requested and achieved speed, drift and slips" {
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try realtime.write(&stream, .{
        .requested_milli = 1000,
        .achieved_milli = 987,
        .drift_ns = 12_345_678,
        .slips = 2,
        .slept_ns = 0,
    });
    try std.testing.expectEqualStrings(
        "pace: requested 1.000x, achieved 0.987x, drift 12.345 ms, 2 slips\n",
        stream.buffered(),
    );
}

test "attaching paces the board's time from where it stands" {
    var time = clocks.Time{};
    time.base.advance(3_000);
    var attached: ?realtime.Pacing = null;
    realtime.attachHost(&attached, time.base.now(), std.testing.io, 1000);
    const paced = attached.?;
    try std.testing.expectEqual(@as(u64, 3_000), paced.last_ns);
    try std.testing.expectEqual(@as(u64, 1000), paced.pacer.speed_milli);
}

test "--speed sets the factor, and max leaves the run unpaced" {
    const quarter = try parse(&[_][]const u8{ "emu", "a.elf", "--speed", "0.25" });
    try std.testing.expectEqual(@as(?u64, 250), quarter.speed);
    const flat = try parse(&[_][]const u8{ "emu", "a.elf", "--speed", "max" });
    try std.testing.expect(flat.speed == null);
    try std.testing.expectError(error.NotPositive, parse(&[_][]const u8{ "emu", "a.elf", "--speed", "0" }));
    try std.testing.expectError(error.NotANumber, parse(&[_][]const u8{ "emu", "a.elf", "--speed", "fast" }));
}

test "a run skips idle stretches unless it asks for --no-idle-skip" {
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(plain.idle_skip);
    const skipping = try parse(&[_][]const u8{ "emu", "a.elf", "--idle-skip" });
    try std.testing.expect(skipping.idle_skip);
    const stepping = try parse(&[_][]const u8{ "emu", "a.elf", "--no-idle-skip" });
    try std.testing.expect(!stepping.idle_skip);
}

test "--run-for is a window of the image's own milliseconds (RA8EMU-762)" {
    const week = try parse(&[_][]const u8{ "emu", "a.elf", "--run-for", "7d" });
    try std.testing.expectEqual(@as(?u64, 7 * 24 * 3600 * 1000), week.ms);
    try std.testing.expectEqual(@as(?usize, null), week.instructions);
    try std.testing.expect(week.run_for);
    const plain = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "100" });
    try std.testing.expect(!plain.run_for);
    const short = try parse(&[_][]const u8{ "emu", "a.elf", "--run-for", "90m" });
    try std.testing.expectEqual(@as(?u64, 90 * 60 * 1000), short.ms);
    try std.testing.expectError(error.NoUnit, parse(&[_][]const u8{ "emu", "a.elf", "--run-for", "90" }));
}

test "--run-for times a run as --ms does and keeps the 1 GHz ceiling" {
    const ten = try parse(&[_][]const u8{ "emu", "a.elf", "--run-for", "10s" });
    const same = try parse(&[_][]const u8{ "emu", "a.elf", "--ms", "10000" });
    const stop_sym = cli_app.zig_run.stop_sym;
    try std.testing.expectEqual(stop_sym.deadline(same.ms).?.periods, stop_sym.deadline(ten.ms).?.periods);
    try std.testing.expectEqual(same.budgetFor(false), ten.budgetFor(false));
    // An image that never arms SysTick still gets 10 s at 1 GHz, plus boot.
    const at_1ghz = clocks.timebase.default_hz * 10;
    try std.testing.expectEqual(at_1ghz + cli_app.cli.budget, ten.budgetFor(false));
    const later = try parse(&[_][]const u8{ "emu", "a.elf", "--ms", "5", "--run-for", "2s" });
    try std.testing.expectEqual(@as(?u64, 2000), later.ms);
}
