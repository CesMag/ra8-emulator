//! Covers src/session/zig_stop.zig: the `--stop-sym` counter a Zig
//! run watches (RA8EMU-603).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const zig_stop = cli_app.zig_run.stop_sym;
const Builder = @import("symbol_image.zig").Builder;

test "a --stop-sym name resolves to its address and floor" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.board.image.elf.Image.init(Builder.build(&bytes, &.{"g_tick"}, &.{0x2200_08D8}));
    const watch = zig_stop.resolve(image, null, "g_tick", 3) orelse return error.TestExpectedStop;
    try std.testing.expectEqual(@as(u32, 0x2200_08D8), watch.address);
    try std.testing.expectEqual(@as(u32, 3), watch.reaches);
}

test "no --stop-sym means nothing is watched" {
    var bytes: [4096]u8 align(4) = undefined;
    const image = try ra8.board.image.elf.Image.init(Builder.build(&bytes, &.{"g_tick"}, &.{0x2200_08D8}));
    try std.testing.expect(zig_stop.resolve(image, null, null, 0) == null);
}

test "--ms gives a window in SysTick periods" {
    const due = zig_stop.deadline(4000) orelse return error.TestExpectedDeadline;
    try std.testing.expectEqual(@as(u64, 4000), due.periods);
    try std.testing.expect(zig_stop.deadline(null) == null);
}

test "the verdict says which of counter, deadline and budget ended the run" {
    var buffer: [128]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    const spent: ra8.chip.core.deadline.Deadline = .{ .periods = 50, .reached = true };
    try zig_stop.verdict(&stream, null, null, spent, 0x10, 99);
    try std.testing.expectEqualStrings("stopped clean after 50 ms, pc 0x00000010\n", stream.buffered());
    stream.end = 0;
    try zig_stop.verdict(&stream, "g_tick", .{ .address = 0x2200_0000, .reaches = 3 }, spent, 0x10, 99);
    try std.testing.expectEqualStrings("ran 50 ms, g_tick never reached 3, pc 0x00000010\n", stream.buffered());
    stream.end = 0;
    try zig_stop.verdict(&stream, "g_tick", .{ .address = 0x2200_0000, .reaches = 3 }, null, 0x10, 99);
    try std.testing.expectEqualStrings("ran 99 instructions, g_tick never reached 3, pc 0x00000010\n", stream.buffered());
    stream.end = 0;
    try zig_stop.verdict(&stream, null, null, null, 0x10, 99);
    try std.testing.expectEqualStrings("", stream.buffered());
}
