//! `ra8_emulator --map <elf>`: the memory map of a firmware image, printed
//! like the summary at the end of a linker map, then exit.
//!
//! One block per linker region (name, range, used/total, percent) with the
//! sections that run there underneath: name, run address, load address when
//! it differs, size. A section stored apart from where it runs (.data) also
//! shows under the region holding its stored copy, so each block's lines add
//! up to its used figure. Then the stack reservation, then any section that
//! fits no region. region_map_text.zig lays the map out; this file opens the
//! image and prints it.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const region_map = @import("ra8_session").region_map;
const region_map_text = @import("ra8_session").region_map_text;

const usage = "usage: ra8_emulator --map <firmware.elf>\n";

/// The whole command: argv[1] is "--map", argv[2] the image.
pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    if (argv.len != 3) {
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return 2;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, argv[2], allocator, .limited(1 << 30)) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ argv[2], @errorName(err) });
        return 1;
    };
    const image = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ argv[2], @errorName(err) });
        return 1;
    };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try region_map_text.render(&stdout.interface, image, &region_map.ek_ra8d2);
    try stdout.interface.flush();
    return 0;
}
