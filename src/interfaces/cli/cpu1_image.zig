//! CPU1's image read from the host and handed to the chip (RA8EMU-1039).
//! The application reads the file, the board's loader parses it, and the
//! chip's CPU1 bring-up takes only the loaded value.
const std = @import("std");
const elf = @import("../../board/image/elf.zig");
const loader = @import("../../board/image/load.zig");
const second_core = @import("ra8_chip").core.second_core;
const Driver = @import("ra8_chip").core.second_zig_run.Driver;
const Wiring = @import("ra8_chip").core.second_wiring.Wiring;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;

/// Open `driver` on the image at `path`. The bytes are written into CPU1's
/// store before this returns, so they are freed here.
pub fn open(driver: *Driver, allocator: std.mem.Allocator, io: std.Io, wiring: Wiring, path: []const u8, memory: Guest) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(second_core.limits.image_bytes));
    defer allocator.free(bytes);
    const loaded = try loader.read(try elf.Image.init(bytes));
    try driver.open(wiring, loaded.image(), memory);
}
