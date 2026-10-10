//! The blank USB disk: a FAT12 superfloppy a FAT driver can mount.
const std = @import("std");
const ra8 = @import("ra8");
const usb_disk = ra8.components.usb_stick.disk;

var image = @as([512 * usb_disk.sector_len]u8, @splat(0xCC));

fn rd16(at: usize) u16 {
    return std.mem.readInt(u16, image[at..][0..2], .little);
}

test "a 256 KiB disk lays out as FAT12" {
    const layout = try usb_disk.geometry(image.len);
    try std.testing.expectEqual(@as(u32, 512), layout.sectors);
    try std.testing.expectEqual(@as(u32, 2), layout.fat_sectors);
    try std.testing.expectEqual(@as(u32, 4), layout.root_sectors);
    try std.testing.expectEqual(@as(u32, 9), layout.data_start);
    try std.testing.expectEqual(@as(u32, 503), layout.clusters);
    try std.testing.expect(layout.clusters < 4085);
}

test "the FAT covers every cluster the disk has" {
    for ([_]usize{ 16, 512, 2000, usb_disk.max_sectors }) |count| {
        const layout = try usb_disk.geometry(count * usb_disk.sector_len);
        const needed = (layout.clusters + 2) * 3 / 2 + 1;
        try std.testing.expect(layout.fat_sectors * usb_disk.sector_len >= needed);
        try std.testing.expect(layout.clusters < 4085);
    }
}

test "sizes that are not whole sectors or are out of range are refused" {
    try std.testing.expectError(error.BadSize, usb_disk.geometry(513));
    try std.testing.expectError(error.BadSize, usb_disk.geometry(8 * usb_disk.sector_len));
    try std.testing.expectError(error.BadSize, usb_disk.geometry(5000 * usb_disk.sector_len));
}

test "format writes a BPB a FAT driver reads, and empties the disk" {
    const layout = try usb_disk.format(&image, 0x1234_5678);
    try std.testing.expectEqual(@as(u8, 0x55), image[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), image[511]);
    try std.testing.expectEqual(@as(u16, 512), rd16(11));
    try std.testing.expectEqual(@as(u8, 1), image[13]);
    try std.testing.expectEqual(@as(u16, 1), rd16(14));
    try std.testing.expectEqual(@as(u8, 2), image[16]);
    try std.testing.expectEqual(@as(u16, 64), rd16(17));
    try std.testing.expectEqual(@as(u16, 512), rd16(19));
    try std.testing.expectEqual(usb_disk.media, image[21]);
    try std.testing.expectEqual(@as(u16, 2), rd16(22));
    try std.testing.expectEqualStrings("FAT12   ", image[54..62]);
    for (0..2) |index| {
        const at = layout.fatStart(@intCast(index)) * usb_disk.sector_len;
        try std.testing.expectEqualSlices(u8, &.{ 0xF8, 0xFF, 0xFF, 0x00 }, image[at..][0..4]);
    }
    const root = layout.rootStart() * usb_disk.sector_len;
    try std.testing.expect(std.mem.allEqual(u8, image[root..][0 .. 64 * 32], 0));
    try std.testing.expectEqual(@as(u8, 0), image[image.len - 1]);
}
