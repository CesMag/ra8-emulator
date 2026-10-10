//! Everything a command-line flag asked to be printed once the run is over.
//!
//! These are the reader's own questions, not the board's account of itself:
//! a named global read out of RAM, one card block as hex, the core
//! registers as the run left them. They come after the block reports and
//! they answer to a flag, so a run that passed none of those flags prints
//! nothing from this file at all.
//!
//! Its own file rather than four more functions in src/interfaces/cli/main.zig, which is
//! wiring: this is output, it is the only part of the output that a flag
//! rather than the board decides, and src/board is where the words about a
//! run live.
const std = @import("std");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const elf = @import("../../../image/elf.zig");
const cli = @import("../cli.zig");
const symbols = @import("../../../session/symbols.zig");
const sd_dump = @import("ra8_components").sd_dump;
const sd_image = @import("ra8_components").sd_image;
const registers = @import("../../../session/registers.zig");
const json_regs = @import("json_regs.zig");

/// Read each `--dump-sym` global out of RAM and print it.
///
/// The shape of the line is load-bearing: the firmware's own
/// emulator-in-the-loop suite parses it with a regex over
/// "dump-sym : <name> @0x<addr> = <decimal> ", so the name, the address,
/// the decimal value and something after it all have to be there. A symbol
/// the image does not carry, or an address that will not read, says so
/// plainly instead of printing a number nothing measured.
pub fn dumpSymbols(out: anytype, io: std.Io, core: Guest, image: elf.Image, options: cli.Options) !void {
    if (options.dumps().len == 0) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var images: [2]elf.Image = .{ image, undefined };
    var count: usize = 1;
    if (try nonSecure(arena.allocator(), io, options)) |second| {
        images[1] = second;
        count = 2;
    }
    for (options.dumps()) |name| {
        const address = symbols.addressInAny(images[0..count], name) orelse {
            try out.print("  dump-sym      : {s} <unresolved>\n", .{name});
            continue;
        };
        const value = core.readWord(address) catch {
            try out.print("  dump-sym      : {s} @0x{X:0>8} <unreadable>\n", .{ name, address });
            continue;
        };
        try out.print(
            "  dump-sym      : {s} @0x{X:0>8} = {d} (0x{X:0>8})\n",
            .{ name, address, value, value },
        );
    }
}

/// The `--ns` image again, for its symbol table: a global the Non-Secure
/// side keeps (a heartbeat the bench reads by memprobe) is named only there.
/// The run already loaded its segments; this reads the file once more and
/// nothing else, so a run without `--ns` reads nothing.
pub fn nonSecure(allocator: std.mem.Allocator, io: std.Io, options: cli.Options) !?elf.Image {
    const path = options.ns_path orelse return null;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20));
    return try elf.Image.init(bytes);
}

/// One card block back as hex, when `--dump-sd` asked for it.
///
/// Rows of nothing but zeros are dropped: a block of a freshly formatted
/// volume is mostly zeros, and the few rows carrying a directory entry or a
/// boot field are the whole reason to look. The count of dropped rows is
/// printed so a reader can tell an elided block from a short one.
pub fn dumpBlock(out: anytype, board: anytype, options: cli.Options) !void {
    const index = options.dump_sd orelse return;
    var block: sd_image.Block = undefined;
    if (!board.sd.img.read(index, &block)) {
        try out.print("  dump-sd       : block {d} is not on this card\n", .{index});
        return;
    }
    try out.print("  dump-sd       : block {d} (0x{X})\n", .{ index, index });
    var offset: usize = 0;
    var dropped: usize = 0;
    while (offset < block.len) : (offset += sd_dump.row_bytes) {
        const end = @min(offset + sd_dump.row_bytes, block.len);
        const bytes = block[offset..end];
        if (sd_dump.blank(bytes)) {
            dropped += 1;
            continue;
        }
        var buf: sd_dump.Buffer = undefined;
        try out.print("{s}\n", .{sd_dump.row(&buf, offset, bytes)});
    }
    if (dropped > 0) try out.print("  dump-sd       : {d} zero row(s) not shown\n", .{dropped});
}

/// The core registers as the run left them, when `--dump-regs` asked.
///
/// At a break this is the function's own call boundary, so r0-r3 and the
/// words at the stack pointer are still its arguments. The registers come
/// from the same reader `--report json` uses; the line keeps the engine
/// run's layout, which the firmware's regexes parse (RA8EMU-638). A value
/// the source will not give is printed as unreadable, never as a zero.
pub fn dumpRegisters(out: anytype, reader: json_regs.Reader, core: Guest, options: cli.Options) !void {
    if (!options.dump_regs) return;
    try out.print("  dump-regs     :", .{});
    for (registers.dumped, 0..) |named, index| {
        if (reader.register(named.which)) |value| {
            try out.print(" {s} 0x{X:0>8}", .{ named.name, value });
        } else try out.print(" {s} <unreadable>", .{named.name});
        if (registers.endsLine(index)) try out.print("\n                 ", .{});
    }
    const sp = reader.register(.sp) orelse return out.print("sp unreadable\n", .{});
    for (0..registers.limits.stack_words) |index| {
        const at = registers.stackWord(sp, index);
        if (core.readWord(at)) |value| {
            try out.print(" [sp+{d}] 0x{X:0>8}", .{ index * 4, value });
        } else |_| try out.print(" [sp+{d}] <unreadable>", .{index * 4});
    }
    try out.print("\n", .{});
}
