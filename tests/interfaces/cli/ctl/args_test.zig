//! Tests the `ctl cpu-load` argument normalization.
const std = @import("std");
const cli_app = @import("cli_app");
const ctl_args = cli_app.cli.ctl_args;

test "cpu-load options become ordinary run arguments" {
    const args = try ctl_args.parse(&.{ "emu", "ctl", "cpu-load", "blink.elf", "--from", "16", "--to", "32", "--cpu", "zig" });
    try std.testing.expectEqualSlices([]const u8, &.{ "emu", "blink.elf", "--cpu-load-from", "16", "--cpu-load-to", "32", "--cpu", "zig" }, args.slice());
}

test "cpu-load argument normalization rejects missing commands and values" {
    try std.testing.expectError(error.MissingCommand, ctl_args.parse(&.{ "emu", "ctl" }));
    try std.testing.expectError(error.UnknownCommand, ctl_args.parse(&.{ "emu", "ctl", "regs" }));
    try std.testing.expectError(error.MissingImage, ctl_args.parse(&.{ "emu", "ctl", "cpu-load" }));
    try std.testing.expectError(error.MissingValue, ctl_args.parse(&.{ "emu", "ctl", "cpu-load", "blink.elf", "--from" }));
}
