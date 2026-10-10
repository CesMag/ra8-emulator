//! Covers src/interfaces/cli/state_args.zig: `--save-state` and
//! `--load-state` (RA8EMU-696), `--snapshot-at` and `--restore` (RA8EMU-769).
const std = @import("std");
const cli_app = @import("cli_app");

const state_args = cli_app.zig_run.state_args;

test "both flags take a path and leave the index on it" {
    var options: state_args.Options = .{};
    const argv = [_][]const u8{ "--save-state", "a.state", "--load-state", "b.state" };
    var index: usize = 0;
    try std.testing.expect(try state_args.parse(&options, &argv, &index));
    try std.testing.expectEqual(@as(usize, 1), index);
    index = 2;
    try std.testing.expect(try state_args.parse(&options, &argv, &index));
    try std.testing.expectEqualStrings("a.state", options.save.?);
    try std.testing.expectEqualStrings("b.state", options.load.?);
    try std.testing.expect(options.wanted());
}

test "a flag with no path is said plainly" {
    var options: state_args.Options = .{};
    const argv = [_][]const u8{"--load-state"};
    var index: usize = 0;
    try std.testing.expectError(error.MissingValue, state_args.parse(&options, &argv, &index));
}

test "other flags are left for the next parser" {
    var options: state_args.Options = .{};
    const argv = [_][]const u8{"--frames-out"};
    var index: usize = 0;
    try std.testing.expect(!try state_args.parse(&options, &argv, &index));
    try std.testing.expect(!options.wanted());
}

test "snapshot-at takes TIME:PATH and restore takes the load path" {
    var options: state_args.Options = .{};
    const argv = [_][]const u8{ "--snapshot-at", "40us:out/a.state", "--restore", "b.state" };
    var index: usize = 0;
    try std.testing.expect(try state_args.parse(&options, &argv, &index));
    index = 2;
    try std.testing.expect(try state_args.parse(&options, &argv, &index));
    try std.testing.expectEqual(@as(u64, 40_000), options.at.?.ns);
    try std.testing.expectEqualStrings("out/a.state", options.at.?.path);
    try std.testing.expect(!options.at.?.written);
    try std.testing.expectEqualStrings("b.state", options.load.?);
    try std.testing.expect(options.wanted());
}

test "times take ns, us, ms, s or bare seconds; bad ones are said plainly" {
    try std.testing.expectEqual(@as(u64, 100), try state_args.parseTime("100ns"));
    try std.testing.expectEqual(@as(u64, 500_000_000), try state_args.parseTime("500ms"));
    try std.testing.expectEqual(@as(u64, 2_000_000_000), try state_args.parseTime("2s"));
    try std.testing.expectEqual(@as(u64, 3_000_000_000), try state_args.parseTime("3"));
    try std.testing.expectError(error.BadTime, state_args.parseTime("fast"));
    try std.testing.expectError(error.BadTime, state_args.parseTime("99999999999999999999s"));
    try std.testing.expectError(error.BadSnapshotAt, state_args.parseAt("500ms"));
    try std.testing.expectError(error.BadSnapshotAt, state_args.parseAt("500ms:"));
}
