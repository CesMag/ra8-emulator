//! An ELF file read off disk and parsed (RA8EMU-1087): where ra8_emulator
//! opens the image it runs. A failure is printed with the path and which
//! half failed, reading or parsing.
const std = @import("std");
const elf = @import("../../board/image/elf.zig");

/// Read the image off disk and parse it, saying which of the two failed.
pub fn open(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !elf.Image {
    const bytes = try read(io, allocator, path);
    return elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// The file behind `path`, or a printed complaint and the error that caused
/// it. The bytes outlive the file and are owned by the caller's arena.
pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}
