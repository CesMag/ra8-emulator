//! The --usb-disk option: blank, an image read from the host, or refused.
const std = @import("std");
const io = std.testing.io;
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const usb = ra8.board.usb;
const option = cli_app.usb_disk_option;

test "blank needs no file" {
    const disk = try option.load(std.testing.allocator, io, ra8.board.usb_plug.blank_spec);
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqual(ra8.board.usb_plug.blank_len, disk.len);
}

test "an image file is read whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "disk.img", .data = &(@as([1024]u8, @splat(0x7E))) });
    const path = try tmp.dir.realPathFileAlloc(io, "disk.img", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const disk = try option.load(std.testing.allocator, io, path);
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqual(@as(usize, 1024), disk.len);
    try std.testing.expectEqual(@as(u8, 0x7E), disk[1023]);
}

test "an image that is not whole sectors is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "odd.img", .data = &(@as([700]u8, @splat(0))) });
    const path = try tmp.dir.realPathFileAlloc(io, "odd.img", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.NotWholeSectors, option.load(std.testing.allocator, io, path));
}

test "a missing image file is refused" {
    try std.testing.expectError(error.FileNotFound, option.load(std.testing.allocator, io, "/nonexistent/ra8.img"));
}

test "no --usb-disk leaves the echo device in the jack" {
    var board_usb = usb.Usb{};
    try option.apply(&board_usb, std.testing.allocator, io, null);
    try std.testing.expect(!board_usb.echo.hasDisk());
}
