//! CPU1's image read from the host and handed to the chip (RA8EMU-1039).
//! The application reads the file, the board's loader parses it, and the
//! chip's CPU1 bring-up takes only the loaded value.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const loader = @import("ra8_board").image.load;
const second_core = @import("ra8_chip").core.second.core;
const Driver = @import("ra8_chip").core.second.zig.run.Driver;
const Wiring = @import("ra8_chip").core.second.wiring.Wiring;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;

/// Open `driver` on the image at `path` under `dir`. The bytes are written
/// into CPU1's store before this returns, so they are freed here.
pub fn open(driver: *Driver, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, wiring: Wiring, path: []const u8, memory: Guest) !void {
    _ = try openIdentified(driver, allocator, io, dir, wiring, path, memory);
}

/// Open CPU1 on the image at `path` under `dir` and return the identity of
/// the exact ELF bytes it consumed.
pub fn openIdentified(driver: *Driver, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, wiring: Wiring, path: []const u8, memory: Guest) ![16]u8 {
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(second_core.limits.image_bytes));
    defer allocator.free(bytes);
    return openBytes(driver, wiring, bytes, memory);
}

/// Open CPU1 from caller-owned bytes, without host access. The driver
/// consumes the loaded segments before returning and borrows no ELF bytes.
pub fn openBytes(driver: *Driver, wiring: Wiring, bytes: []const u8, memory: Guest) ![16]u8 {
    const loaded = try loader.read(try elf.Image.init(bytes));
    try driver.open(wiring, loaded.image(), memory);
    return @import("ra8_board").snapshot.run.imageIdentity(bytes);
}
