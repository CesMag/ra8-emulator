//! Covers src/components/sd_card/fat.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fat = ra8.components.sd_fat;

const small = fat.Layout{
    .total_sectors = 65536,
    .sectors_per_cluster = 4,
    .reserved_sectors = 1,
    .fat_sectors = 64,
    .root_sectors = 32,
    .clusters = 16000,
};

const large = fat.Layout{
    .total_sectors = 2_097_152,
    .sectors_per_cluster = 8,
    .reserved_sectors = 32,
    .fat_sectors = 2048,
    .root_sectors = 0,
    .clusters = 261_000,
};

fn read16(sector: *const fat.Sector, at: usize) u16 {
    return std.mem.readInt(u16, sector[at..][0..2], .little);
}

fn read32(sector: *const fat.Sector, at: usize) u32 {
    return std.mem.readInt(u32, sector[at..][0..4], .little);
}

test "a label is padded to the field and uppercased" {
    var field: [fat.label_len]u8 = undefined;
    try fat.labelField(&field, "book");
    try std.testing.expectEqualSlices(u8, "BOOK       ", &field);
}

test "an empty label is the whole field of spaces" {
    var field: [fat.label_len]u8 = undefined;
    try fat.labelField(&field, "");
    try std.testing.expectEqualSlices(u8, "           ", &field);
}

test "a label longer than the field is refused, not truncated" {
    var field: [fat.label_len]u8 = undefined;
    try std.testing.expectError(error.BadLabel, fat.labelField(&field, "TWELVECHARS!"));
}

test "a label carrying a byte the field cannot hold is refused" {
    var field: [fat.label_len]u8 = undefined;
    try std.testing.expectError(error.BadLabel, fat.labelField(&field, "ra8\x01"));
    try std.testing.expectError(error.BadLabel, fat.labelField(&field, "a/b"));
    try std.testing.expectError(error.BadLabel, fat.labelField(&field, "a*b"));
    try std.testing.expectError(error.BadLabel, fat.labelField(&field, "a.b"));
}

test "the boot frame carries the jump, the OEM name and the signature" {
    const boot = try fat.bootSector16(small, 2, "ra8");
    try std.testing.expectEqualSlices(u8, &fat.value.jump, boot[0..3]);
    try std.testing.expectEqualSlices(u8, fat.value.oem, boot[3..11]);
    try std.testing.expectEqual(@as(u8, 0x55), boot[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), boot[511]);
}

test "a FAT16 boot sector states the geometry it was solved for" {
    const boot = try fat.bootSector16(small, 2, "ra8");
    try std.testing.expectEqual(@as(u16, 512), read16(&boot, fat.offset.bytes_per_sector));
    try std.testing.expectEqual(@as(u8, 4), boot[fat.offset.sectors_per_cluster]);
    try std.testing.expectEqual(@as(u16, 1), read16(&boot, fat.offset.reserved_sectors));
    try std.testing.expectEqual(@as(u8, 2), boot[fat.offset.fats]);
    try std.testing.expectEqual(@as(u16, 512), read16(&boot, fat.offset.root_entries));
    try std.testing.expectEqual(@as(u16, 64), read16(&boot, fat.offset.fat_sectors16));
    try std.testing.expectEqual(@as(u8, 0xF8), boot[fat.offset.media]);
    try std.testing.expectEqualSlices(u8, "FAT16   ", boot[fat.offset16.fs_type..][0..8]);
    try std.testing.expectEqualSlices(u8, "RA8        ", boot[fat.offset16.label..][0..11]);
}

test "a sector count too wide for the 16-bit field lands in the 32-bit one" {
    var wide = small;
    wide.total_sectors = 200_000;
    const boot = try fat.bootSector16(wide, 2, "ra8");
    try std.testing.expectEqual(@as(u16, 0), read16(&boot, fat.offset.total_sectors16));
    try std.testing.expectEqual(@as(u32, 200_000), read32(&boot, fat.offset.total_sectors32));

    const narrow = try fat.bootSector16(small, 2, "ra8");
    try std.testing.expectEqual(@as(u16, 0), read16(&narrow, fat.offset.total_sectors16));
    try std.testing.expectEqual(@as(u32, 65536), read32(&narrow, fat.offset.total_sectors32));
}

test "a small card states its sector count in the 16-bit field" {
    var tiny = small;
    tiny.total_sectors = 40_000;
    const boot = try fat.bootSector16(tiny, 2, "ra8");
    try std.testing.expectEqual(@as(u16, 40_000), read16(&boot, fat.offset.total_sectors16));
    try std.testing.expectEqual(@as(u32, 0), read32(&boot, fat.offset.total_sectors32));
}

test "a FAT32 boot sector points at the root cluster, the FSInfo and the backup" {
    const boot = try fat.bootSector32(large, 2, "library");
    try std.testing.expectEqual(@as(u16, 0), read16(&boot, fat.offset.root_entries));
    try std.testing.expectEqual(@as(u16, 0), read16(&boot, fat.offset.fat_sectors16));
    try std.testing.expectEqual(@as(u32, 2048), read32(&boot, fat.offset32.fat_sectors32));
    try std.testing.expectEqual(@as(u32, 2), read32(&boot, fat.offset32.root_cluster));
    try std.testing.expectEqual(@as(u16, 1), read16(&boot, fat.offset32.fs_info));
    try std.testing.expectEqual(@as(u16, 6), read16(&boot, fat.offset32.backup_boot));
    try std.testing.expectEqualSlices(u8, "FAT32   ", boot[fat.offset32.fs_type..][0..8]);
    try std.testing.expectEqualSlices(u8, "LIBRARY    ", boot[fat.offset32.label..][0..11]);
}

test "the serial number follows the card's size, so it is the same every run" {
    const once = try fat.bootSector32(large, 2, "ra8");
    const again = try fat.bootSector32(large, 2, "ra8");
    const serial = read32(&once, fat.offset32.volume_id);
    try std.testing.expectEqual(serial, read32(&again, fat.offset32.volume_id));
    try std.testing.expectEqual(fat.value.volume_id_seed | large.total_sectors, serial);
}

test "a bad label refuses the whole boot sector" {
    try std.testing.expectError(error.BadLabel, fat.bootSector16(small, 2, "WAY TOO LONG"));
    try std.testing.expectError(error.BadLabel, fat.bootSector32(large, 2, "WAY TOO LONG"));
}

test "the FSInfo sector carries its three signatures and the free count" {
    const info = fat.fsInfoSector(large.clusters);
    try std.testing.expectEqual(fat.value.fsinfo_lead, read32(&info, fat.fsinfo_offset.lead));
    try std.testing.expectEqual(fat.value.fsinfo_structure, read32(&info, fat.fsinfo_offset.structure));
    try std.testing.expectEqual(fat.value.fsinfo_trail, read32(&info, fat.fsinfo_offset.trail));
    try std.testing.expectEqual(large.clusters - 1, read32(&info, fat.fsinfo_offset.free_clusters));
    try std.testing.expectEqual(@as(u32, 3), read32(&info, fat.fsinfo_offset.next_free));
}

test "the FAT heads reserve the first entries and allocate nothing else" {
    const head16 = fat.fatHead16();
    try std.testing.expectEqual(@as(u16, 0xFFF8), read16(&head16, 0));
    try std.testing.expectEqual(@as(u16, 0xFFFF), read16(&head16, 2));
    try std.testing.expectEqual(@as(u16, 0), read16(&head16, 4));

    const head32 = fat.fatHead32();
    try std.testing.expectEqual(@as(u32, 0x0FFF_FFF8), read32(&head32, 0));
    try std.testing.expectEqual(@as(u32, 0x0FFF_FFFF), read32(&head32, 4));
    try std.testing.expectEqual(@as(u32, 0x0FFF_FFFF), read32(&head32, 8));
    try std.testing.expectEqual(@as(u32, 0), read32(&head32, 12));
}
