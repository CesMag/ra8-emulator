//! Plug a disk into the USB stick the HS host sees, for one run. The jack
//! carries the echo device by default, which the self-loop examples talk
//! to; a host example that mounts a drive asks for a disk instead.
//!
//! "blank" is a freshly formatted FAT12 volume. Anything else is a raw image
//! the application reads from the host (cli/usb_disk_option.zig) and hands
//! over as bytes: the run writes to the copy, never back to the file.
const std = @import("std");
const usb = @import("usb.zig");
const usb_disk = @import("ra8_components").usb.stick.disk;

pub const blank_spec = "blank";
/// 256 KiB: big enough for the host examples' files, and still FAT12.
pub const blank_len: usize = 512 * usb_disk.sector_len;
/// The largest image read from the host.
pub const max_image: usize = 64 * 1024 * 1024;
/// The serial stamped on a blank volume, so runs are repeatable.
pub const blank_serial: u32 = 0x5241_3845;

pub const Error = error{ EmptyImage, NotWholeSectors } || usb_disk.Error;

/// A freshly formatted blank volume, owned by `allocator`.
pub fn blank(allocator: std.mem.Allocator) ![]u8 {
    const disk = try allocator.alloc(u8, blank_len);
    errdefer allocator.free(disk);
    _ = try usb_disk.format(disk, blank_serial);
    return disk;
}

/// Refuse image bytes the stick can't serve as whole sectors.
pub fn check(disk: []const u8) Error!void {
    if (disk.len == 0) return error.EmptyImage;
    if (disk.len % usb_disk.sector_len != 0) return error.NotWholeSectors;
}

/// Put `disk` in the stick and the stick behind the echo device's bulk
/// endpoints. The board has to be at its final address: the device keeps a
/// pointer to the stick.
pub fn plug(board_usb: *usb.Usb, disk: []u8) void {
    board_usb.stick.disk = disk;
    board_usb.echo.storage = board_usb.stick.function();
}
