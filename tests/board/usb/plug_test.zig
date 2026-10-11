//! Plugging a disk into the HS jack: a blank volume, or image bytes checked
//! for whole sectors.
const std = @import("std");
const ra8 = @import("ra8");
const usb = ra8.board.usb;
const usb_plug = ra8.board.usb_plug;

test "blank is a formatted FAT12 volume the device then serves" {
    const disk = try usb_plug.blank(std.testing.allocator);
    defer std.testing.allocator.free(disk);
    try std.testing.expectEqual(usb_plug.blank_len, disk.len);
    try std.testing.expectEqualStrings("FAT12   ", disk[54..62]);
    var board_usb = usb.Usb{};
    try std.testing.expect(!board_usb.echo.hasDisk());
    usb_plug.plug(&board_usb, disk);
    try std.testing.expect(board_usb.echo.hasDisk());
    try std.testing.expectEqual(@as(u32, 512), board_usb.stick.blocks());
}

test "image bytes must be whole sectors" {
    try usb_plug.check(&(@as([1024]u8, @splat(0))));
    try std.testing.expectError(error.NotWholeSectors, usb_plug.check(&(@as([700]u8, @splat(0)))));
    try std.testing.expectError(error.EmptyImage, usb_plug.check(&.{}));
}
