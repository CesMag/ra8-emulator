//! Tests for served_setup's stageApps (RA8EMU-1142): a served session fills
//! the board's SDHI card with admitted `--app` files and pairs their module
//! ELFs with the loaded-module table.
const std = @import("std");
const io = std.testing.io;
const ra8 = @import("ra8");
const served_setup = ra8.rpc.served_setup;
const ra8app = ra8.board.image.ra8app;

const code_len = 16;
const data_len = 8;
const image_len = ra8app.header_len + code_len + data_len;
const image = "tests/fixtures/fpu/fp_basic.elf";

fn sample() [image_len]u8 {
    var bytes = @as([image_len]u8, @splat(0));
    const words = [_]u32{ ra8app.magic, ra8app.version, 4, code_len, data_len, 0x800, 1, ra8app.Capability.display };
    for (words, 0..) |value, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
    @memcpy(bytes[32..][0..9], "com.hello");
    @memcpy(bytes[64..][0..5], "Hello");
    return bytes;
}

fn staged(tmp: std.testing.TmpDir, name: []const u8, bytes: []const u8) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "a served session stages an admitted app before boot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = sample();
    const path = try staged(tmp, "hello.ra8app", &bytes);
    defer std.testing.allocator.free(path);
    var setup: served_setup.Served = undefined;
    try setup.open(std.testing.allocator, io, image);
    defer setup.deinit();
    try setup.stageApps(io, std.testing.allocator, &.{path});
}

test "a served session refuses a malformed app before boot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes = sample();
    bytes[0] ^= 0xff;
    const path = try staged(tmp, "bad.ra8app", &bytes);
    defer std.testing.allocator.free(path);
    var setup: served_setup.Served = undefined;
    try setup.open(std.testing.allocator, io, image);
    defer setup.deinit();
    try std.testing.expectError(error.Validation, setup.stageApps(io, std.testing.allocator, &.{path}));
}

test "an apps-only stage with no app paths changes nothing" {
    var setup: served_setup.Served = undefined;
    try setup.open(std.testing.allocator, io, image);
    defer setup.deinit();
    try setup.stageApps(io, std.testing.allocator, &.{});
}
