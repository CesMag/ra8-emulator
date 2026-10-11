//! A blank disk for the USB stick (stick.zig): a FAT12 superfloppy (the boot
//! sector and BPB at LBA 0, no partition table) written into a buffer the
//! caller owns. The host examples mount whatever is in the jack, write a
//! file and read it back, so the disk starts empty and writable.
//!
//! One sector per cluster keeps the layout plain. FAT12 holds below 4085
//! clusters (MS FAT spec section 3.5), which bounds the disk size.
const std = @import("std");

pub const sector_len: usize = 512;
pub const reserved: u32 = 1;
pub const fats: u32 = 2;
pub const root_entries: u32 = 64;
pub const media: u8 = 0xF8;
pub const min_sectors: usize = 16;
pub const max_sectors: usize = 4084;

pub const Error = error{BadSize};

pub const Geometry = struct {
    sectors: u32,
    fat_sectors: u32,
    root_sectors: u32,
    data_start: u32,
    clusters: u32,

    pub fn fatStart(self: Geometry, index: u32) u32 {
        return reserved + index * self.fat_sectors;
    }

    pub fn rootStart(self: Geometry) u32 {
        return reserved + fats * self.fat_sectors;
    }
};

/// The layout a disk of `len` bytes gets. The FAT is sized as if every
/// sector were a cluster, so it always covers the clusters there are.
pub fn geometry(len: usize) Error!Geometry {
    if (len % sector_len != 0) return error.BadSize;
    const count = len / sector_len;
    if (count < min_sectors or count > max_sectors) return error.BadSize;
    const sectors: u32 = @intCast(count);
    const root_sectors: u32 = root_entries * 32 / sector_len;
    const fat_bytes = (sectors + 2) * 3 / 2 + 1;
    const fat_sectors: u32 = @intCast((fat_bytes + sector_len - 1) / sector_len);
    const data_start = reserved + fats * fat_sectors + root_sectors;
    return .{
        .sectors = sectors,
        .fat_sectors = fat_sectors,
        .root_sectors = root_sectors,
        .data_start = data_start,
        .clusters = sectors - data_start,
    };
}

/// Format `disk` as an empty FAT12 volume. Everything it held is gone.
pub fn format(disk: []u8, serial: u32) Error!Geometry {
    const layout = try geometry(disk.len);
    @memset(disk, 0);
    writeBoot(disk[0..sector_len], layout, serial);
    var index: u32 = 0;
    while (index < fats) : (index += 1) {
        const at = layout.fatStart(index) * sector_len;
        disk[at..][0..3].* = .{ media, 0xFF, 0xFF };
    }
    return layout;
}

fn writeBoot(boot: []u8, layout: Geometry, serial: u32) void {
    boot[0..3].* = .{ 0xEB, 0x3C, 0x90 };
    boot[3..11].* = "RA8EMU  ".*;
    put16(boot, 11, sector_len);
    boot[13] = 1;
    put16(boot, 14, reserved);
    boot[16] = @intCast(fats);
    put16(boot, 17, root_entries);
    put16(boot, 19, layout.sectors);
    boot[21] = media;
    put16(boot, 22, layout.fat_sectors);
    put16(boot, 24, 32);
    put16(boot, 26, 2);
    boot[36] = 0x80;
    boot[38] = 0x29;
    std.mem.writeInt(u32, boot[39..43], serial, .little);
    boot[43..54].* = "RA8EMU DISK".*;
    boot[54..62].* = "FAT12   ".*;
    boot[510] = 0x55;
    boot[511] = 0xAA;
}

fn put16(boot: []u8, at: usize, value: anytype) void {
    std.mem.writeInt(u16, boot[at..][0..2], @intCast(value), .little);
}
