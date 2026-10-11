//! Tests for CLI frame capture arguments in src/interfaces/cli/frames_args.zig.
const std = @import("std");
const cli_app = @import("cli_app");
const cli = cli_app.cli;

test "frame sequence flags are optional and validate the scan interval" {
    const defaults = try cli.parse(&.{ "emu", "a.elf" });
    try std.testing.expect(defaults.frames.frames_out == null);
    try std.testing.expect(defaults.frames.gif_out == null);
    try std.testing.expect(defaults.frames.video_out == null);
    try std.testing.expectEqual(@as(usize, 1), defaults.frames.frames_every);

    const asked = try cli.parse(&.{ "emu", "a.elf", "--frames-out", "frames", "--gif-out", "movie.gif", "--frames-every", "2" });
    try std.testing.expectEqualStrings("frames", asked.frames.frames_out.?);
    try std.testing.expectEqualStrings("movie.gif", asked.frames.gif_out.?);
    try std.testing.expectEqual(@as(usize, 2), asked.frames.frames_every);
    try std.testing.expectError(error.BadValue, cli.parse(&.{ "emu", "a.elf", "--frames-every", "0" }));
    try std.testing.expectError(error.MissingValue, cli.parse(&.{ "emu", "a.elf", "--frames-out" }));
    try std.testing.expectError(error.MissingValue, cli.parse(&.{ "emu", "a.elf", "--gif-out" }));
}

test "frame-on-settle captures to its own directory with a virtual stability window" {
    const parsed = try cli_app.cli.parse(&.{ "emu", "image.elf", "--frame-on-settle", "settled", "--settle-window-ms", "75" });
    try std.testing.expectEqualStrings("settled", parsed.frames.frame_on_settle.?);
    try std.testing.expectEqual(@as(u64, 75_000_000), parsed.frames.settle_window_ns);
}

test "--gui is not a command-line flag: the window is ra8_gui" {
    try std.testing.expectError(error.UnknownFlag, cli.parse(&.{ "emu", "a.elf", "--gui" }));
}

test "the window stills flags are ra8_gui's: the command line refuses them" {
    try std.testing.expectError(error.UnknownFlag, cli.parse(&.{ "emu", "a.elf", "--window-stills", "shots" }));
    try std.testing.expectError(error.UnknownFlag, cli.parse(&.{ "emu", "a.elf", "--window-stills-every", "30" }));
}

test "video output argument takes a path" {
    const parsed = try cli.parse(&.{ "emu", "image.elf", "--video-out", "capture.y4m" });
    try std.testing.expectEqualStrings("capture.y4m", parsed.frames.video_out.?);
}
