//! RA8EMU-568: `--sd-image` backs the SDHI card with a raw host image. The
//! card's sparse store is the copy-on-write overlay: reads come from the
//! image, writes stay in memory, and only host disk_file.replace rewrites the file.
const std = @import("std");
const io = std.testing.io;
const ra8 = @import("ra8");
const card = ra8.components.sd_card.bus_card;
const sd_image = ra8.components.sd_card.image;
const disk_file = ra8.host.disk_file;
const sd_format = ra8.components.sd_card.format;

const Block = [card.geometry.block_bytes]u8;

/// A formatted FAT16 card as raw bytes, with one root entry "BOOK    EPB".
fn fatImage(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var img = sd_image.Image.init(allocator);
    defer img.deinit();
    const mib = sd_format.smallestCardMib(.fat16).?;
    try std.testing.expect(img.resize(mib * 2048));
    const volume = try sd_format.apply(&img, .fat16, "SDIMG");
    const layout = volume.layout;
    const root = layout.reserved_sectors + sd_format.rule.fats * layout.fat_sectors;
    var entry: Block = @as([512]u8, @splat(0));
    @memcpy(entry[0..11], "BOOK    EPB");
    entry[11] = 0x20;
    _ = img.write(root, &entry);
    try disk_file.replace(io, dir, "card.img", &img);
    return dir.readFileAlloc(io, "card.img", allocator, .unlimited);
}

test "a loaded image is the card: boot sector, root entry and its size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try fatImage(std.testing.allocator, tmp.dir);
    defer std.testing.allocator.free(bytes);
    var unit = card.Card.init(std.testing.allocator);
    defer unit.deinit();
    try unit.loadBytes(bytes);
    var block: Block = undefined;
    try std.testing.expect(unit.read(0, &block));
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0xAA }, block[510..512]);
    try std.testing.expectEqualSlices(u8, bytes[0..512], &block);
    const blocks: u32 = @intCast(bytes.len / 512);
    try std.testing.expectEqual(blocks, unit.capacity());
    const c_size = blocks / card.geometry.csize_unit - 1;
    try std.testing.expectEqual((c_size & 0xFFFF) << 16, unit.csd()[1]);
    try std.testing.expect(!unit.read(blocks, &block));
    const found = std.mem.indexOf(u8, bytes, "BOOK    EPB").?;
    try std.testing.expect(unit.read(@intCast(found / 512), &block));
    try std.testing.expectEqualSlices(u8, "BOOK    EPB", block[found % 512 ..][0..11]);
}

test "writes stay in the overlay until the card is saved back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try fatImage(std.testing.allocator, tmp.dir);
    defer std.testing.allocator.free(bytes);
    var unit = card.Card.init(std.testing.allocator);
    defer unit.deinit();
    try unit.loadBytes(bytes);
    const scribble: Block = @as([512]u8, @splat(0x5A));
    try std.testing.expect(unit.write(3, &scribble));
    const before = try tmp.dir.readFileAlloc(io, "card.img", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualSlices(u8, bytes, before);
    try disk_file.replace(io, tmp.dir, "card.img", &unit);
    const after = try tmp.dir.readFileAlloc(io, "card.img", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqual(bytes.len, after.len);
    try std.testing.expectEqualSlices(u8, &scribble, after[3 * 512 ..][0..512]);
    try std.testing.expectEqualSlices(u8, bytes[0..512], after[0..512]);
}

test "an image that is not whole C_SIZE units, or a card already holding data, is refused" {
    var unit = card.Card.init(std.testing.allocator);
    defer unit.deinit();
    const odd = @as([1024]u8, @splat(0));
    try std.testing.expectError(error.BadImageSize, unit.loadBytes(&odd));
    try std.testing.expectError(error.BadImageSize, unit.loadBytes(&.{}));
    const one: Block = @as([512]u8, @splat(1));
    try std.testing.expect(unit.write(0, &one));
    const whole = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(whole);
    @memset(whole, 0);
    try std.testing.expectError(error.CardNotBlank, unit.loadBytes(whole));
    try std.testing.expectEqual(card.geometry.capacity_blocks, unit.capacity());
}
