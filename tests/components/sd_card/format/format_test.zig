//! Covers src/components/sd_card/format/format.zig.
const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.components.sd_card.format;
const image = ra8.components.sd_card.image;
const fat = ra8.components.sd_card.fat;

const megabyte_blocks: u32 = 1024 * 1024 / image.geometry.block_bytes;

fn card(megabytes: u32) image.Image {
    var img = image.Image.init(std.testing.allocator);
    std.debug.assert(img.resize(megabytes * megabyte_blocks));
    return img;
}

fn read16(sector: *const image.Block, at: usize) u16 {
    return std.mem.readInt(u16, sector[at..][0..2], .little);
}

fn read32(sector: *const image.Block, at: usize) u32 {
    return std.mem.readInt(u32, sector[at..][0..4], .little);
}

test "a width is named, never guessed" {
    try std.testing.expectEqual(format.Kind.fat16, format.Kind.parse("fat16").?);
    try std.testing.expectEqual(format.Kind.fat32, format.Kind.parse("FAT32").?);
    try std.testing.expect(format.Kind.parse("fat12") == null);
    try std.testing.expect(format.Kind.parse("") == null);
}

test "a 32 MiB card solves to a FAT16 volume inside the 16-bit range" {
    const layout = try format.solve(.fat16, 32 * megabyte_blocks);
    try std.testing.expectEqual(@as(u32, 32 * megabyte_blocks), layout.total_sectors);
    try std.testing.expectEqual(@as(u32, 1), layout.reserved_sectors);
    try std.testing.expectEqual(@as(u32, 32), layout.root_sectors);
    try std.testing.expect(layout.clusters >= format.rule.fat16_min_clusters);
    try std.testing.expect(layout.clusters <= format.rule.fat16_max_clusters);
    try std.testing.expect(layout.fat_sectors * 256 * layout.sectors_per_cluster >= layout.clusters);
}

test "the cluster grows until the count fits under the 16-bit ceiling" {
    const small = try format.solve(.fat16, 32 * megabyte_blocks);
    const big = try format.solve(.fat16, 512 * megabyte_blocks);
    try std.testing.expect(big.sectors_per_cluster > small.sectors_per_cluster);
    try std.testing.expect(big.clusters <= format.rule.fat16_max_clusters);
}

test "a card with more clusters than a 16-bit FAT can address is refused" {
    // dev caps the cluster size and writes the BPB anyway.
    try std.testing.expectError(
        error.TooManyClusters,
        format.solve(.fat16, 8 * 1024 * megabyte_blocks),
    );
}

test "a card with too few clusters for the width it was asked for is refused" {
    try std.testing.expectError(error.TooFewClusters, format.solve(.fat16, 2 * megabyte_blocks));
    try std.testing.expectError(error.TooFewClusters, format.solve(.fat32, 32 * megabyte_blocks));
}

test "a card smaller than its own metadata is refused, not wrapped around" {
    try std.testing.expectError(error.CardTooSmall, format.solve(.fat16, 16));
    try std.testing.expectError(error.CardTooSmall, format.solve(.fat32, 16));
}

test "a 64 MiB card solves to a FAT32 volume above the 32-bit floor" {
    const layout = try format.solve(.fat32, 64 * megabyte_blocks);
    try std.testing.expectEqual(@as(u32, 32), layout.reserved_sectors);
    try std.testing.expectEqual(@as(u32, 0), layout.root_sectors);
    try std.testing.expect(layout.clusters >= format.rule.fat32_min_clusters);
}

test "a formatted FAT16 card carries its boot sector and both FAT copies" {
    var img = card(32);
    defer img.deinit();
    const volume = try format.apply(&img, .fat16, "book");
    var block: image.Block = undefined;

    try std.testing.expect(img.read(0, &block));
    try std.testing.expectEqual(@as(u8, 0x55), block[510]);
    try std.testing.expectEqualSlices(u8, "FAT16   ", block[fat.offset16.fs_type..][0..8]);
    try std.testing.expectEqualSlices(u8, "BOOK       ", block[fat.offset16.label..][0..11]);

    try std.testing.expect(img.read(volume.layout.reserved_sectors, &block));
    try std.testing.expectEqual(@as(u16, 0xFFF8), read16(&block, 0));
    try std.testing.expect(img.read(volume.layout.reserved_sectors + volume.layout.fat_sectors, &block));
    try std.testing.expectEqual(@as(u16, 0xFFF8), read16(&block, 0));
}

test "a formatted FAT32 card carries the backup boot sector and its FSInfo" {
    var img = card(64);
    defer img.deinit();
    const volume = try format.apply(&img, .fat32, "library");
    var block: image.Block = undefined;

    try std.testing.expect(img.read(0, &block));
    try std.testing.expectEqualSlices(u8, "FAT32   ", block[fat.offset32.fs_type..][0..8]);
    try std.testing.expect(img.read(fat.fsinfo_sector, &block));
    try std.testing.expectEqual(fat.value.fsinfo_lead, read32(&block, fat.fsinfo_offset.lead));

    // The pair dev leaves half-written: the backup boot sector AND its FSInfo.
    try std.testing.expect(img.read(fat.backup_sector, &block));
    try std.testing.expectEqualSlices(u8, "FAT32   ", block[fat.offset32.fs_type..][0..8]);
    try std.testing.expect(img.read(fat.backup_sector + fat.fsinfo_sector, &block));
    try std.testing.expectEqual(fat.value.fsinfo_lead, read32(&block, fat.fsinfo_offset.lead));
    try std.testing.expectEqual(volume.layout.clusters - 1, read32(&block, fat.fsinfo_offset.free_clusters));
}

test "a format clears what the card was still holding in the metadata region" {
    var img = card(32);
    defer img.deinit();
    const junk: image.Block = @splat(0xA5);
    try std.testing.expect(img.write(3, &junk));
    try std.testing.expect(img.write(40, &junk));
    const beyond: u32 = 40_000;
    try std.testing.expect(img.write(beyond, &junk));

    const volume = try format.apply(&img, .fat16, "book");
    try std.testing.expect(volume.cleared >= 2);

    var block: image.Block = undefined;
    try std.testing.expect(img.read(3, &block));
    for (block) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(img.read(40, &block));
    for (block) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    // Past the metadata region a format changes nothing: the data area is the
    // volume's to hand out, not the formatter's to wipe.
    try std.testing.expect(img.read(beyond, &block));
    try std.testing.expectEqualSlices(u8, &junk, &block);
}

test "a bad label refuses the format and leaves the card alone" {
    var img = card(32);
    defer img.deinit();
    try std.testing.expectError(error.BadLabel, format.apply(&img, .fat16, "FAR TOO LONG"));
    var block: image.Block = undefined;
    try std.testing.expect(img.read(0, &block));
    for (block) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a refused width writes nothing at all" {
    var img = card(32);
    defer img.deinit();
    try std.testing.expectError(error.TooFewClusters, format.apply(&img, .fat32, "ra8"));
    try std.testing.expectEqual(@as(usize, 0), img.held());
}

test "the default card is big enough for FAT32" {
    const mib = format.smallestCardMib(.fat32) orelse return error.TestExpectedSize;
    const default_mib = image.geometry.default_capacity_blocks / megabyte_blocks;
    try std.testing.expect(default_mib >= mib);
}

test "the smallest card the search names really does format" {
    inline for (.{ format.Kind.fat16, format.Kind.fat32 }) |kind| {
        const mib = format.smallestCardMib(kind) orelse return error.TestExpectedSize;
        _ = try format.solve(kind, mib * megabyte_blocks);
    }
}

test "one megabyte below the floor is refused" {
    inline for (.{ format.Kind.fat16, format.Kind.fat32 }) |kind| {
        const mib = format.smallestCardMib(kind) orelse return error.TestExpectedSize;
        if (mib > 1) {
            try std.testing.expectError(
                error.TooFewClusters,
                format.solve(kind, (mib - 1) * megabyte_blocks),
            );
        }
    }
}

test "a FAT16 card has a ceiling and the card above it is refused" {
    const mib = format.largestCardMib(.fat16) orelse return error.TestExpectedSize;
    _ = try format.solve(.fat16, mib * megabyte_blocks);
    try std.testing.expectError(
        error.TooManyClusters,
        format.solve(.fat16, (mib + 1) * megabyte_blocks),
    );
}

test "the default card formats as FAT16 and FAT32" {
    const blocks = image.geometry.default_capacity_blocks;
    _ = try format.solve(.fat32, blocks);
    _ = try format.solve(.fat16, blocks);
}
