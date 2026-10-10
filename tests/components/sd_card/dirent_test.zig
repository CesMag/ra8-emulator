//! RA8EMU-563: the image builder's directory entries.
const std = @import("std");
const dirent = @import("ra8").components.sd_card.dirent;

test "an 8.3 upper-case name is kept and takes one slot" {
    try std.testing.expect(dirent.isShort("README.TXT"));
    try std.testing.expectEqualStrings("README  TXT", &dirent.shortName("README.TXT", 0));
    try std.testing.expectEqual(@as(usize, 1), try dirent.slots("README.TXT"));
}

test "a long or lower-case name gets BASE~N and long entries" {
    try std.testing.expect(!dirent.isShort("readme.txt"));
    try std.testing.expect(!dirent.isShort("A~1.TXT"));
    try std.testing.expectEqualStrings("MOBYDI~1EPU", &dirent.shortName("Moby Dick.epub", 1));
    try std.testing.expectEqualStrings("T~12       ", &dirent.shortName("été", 12));
    try std.testing.expectEqual(@as(usize, 3), try dirent.slots("Moby Dick - Whale.epub"));
}

test "long entries run last chunk first, carry the short name's checksum and pad with FFFF" {
    var out: [3]dirent.Entry = undefined;
    const used = try dirent.put(&out, "Moby Dick - Whale.epub", 1, dirent.attr.archive, 7, 100);
    try std.testing.expectEqual(@as(usize, 3), used);
    const name11 = dirent.shortName("Moby Dick - Whale.epub", 1);
    try std.testing.expectEqual(@as(u8, 0x42), out[0][0]);
    try std.testing.expectEqual(@as(u8, 0x01), out[1][0]);
    try std.testing.expectEqual(dirent.checksum(&name11), out[0][13]);
    try std.testing.expectEqual(dirent.attr.long_name, out[1][11]);
    // Chunk 2 holds units 13..21 ("Whale.epub" tail), a 0 terminator, then FFFF.
    try std.testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, out[0][30..32], .little));
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, out[2][26..28], .little));
    try std.testing.expectEqual(@as(u32, 100), std.mem.readInt(u32, out[2][28..32], .little));
    try std.testing.expectEqual(dirent.stamp.date, std.mem.readInt(u16, out[2][24..26], .little));
}
