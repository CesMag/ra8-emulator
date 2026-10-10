//! Covers src/chip/periph/glcdc/scan.zig: reading a framebuffer out of guest
//! memory and saying what is in it, and the five cases that are not a
//! picture.
const std = @import("std");
const ra8 = @import("ra8");

const scan = ra8.chip.periph.glcdc.scan;
const clut = ra8.chip.periph.glcdc.clut;
const pixel = ra8.chip.periph.glcdc.pixel;
const store_memory = @import("../store_memory.zig");
const Guest = store_memory.Guest;
const memmap = ra8.chip.core.memmap;

const fb_base: u32 = memmap.sram_base;
const sram_end: u32 = memmap.sram_end;

/// A machine with the board's RAM mapped, which is all a scan needs.
fn shape(width: u32, height: u32, stride: u32, format: pixel.Format) scan.Shape {
    return .{
        .base = fb_base,
        .width = width,
        .height = height,
        .stride = stride,
        .bits = format.bits(),
        .decode = format.decoder(),
        .indexed = format.indexed(),
        .window_end = sram_end,
    };
}

test "a fetched pixel comes out little-endian at every width" {
    const line = [_]u8{ 0x34, 0x12, 0x78, 0x56 };
    try std.testing.expectEqual(@as(u32, 0x5678_1234), scan.fetch(&line, 0, 32));
    try std.testing.expectEqual(@as(u32, 0x1234), scan.fetch(&line, 0, 16));
    try std.testing.expectEqual(@as(u32, 0x5678), scan.fetch(&line, 1, 16));
    try std.testing.expectEqual(@as(u32, 0x34), scan.fetch(&line, 0, 8));
}

test "a sub-byte pixel is taken from the high end of its byte first" {
    const line = [_]u8{0b1010_0011};
    // CLUT4: the left pixel is the high nibble.
    try std.testing.expectEqual(@as(u32, 0xA), scan.fetch(&line, 0, 4));
    try std.testing.expectEqual(@as(u32, 0x3), scan.fetch(&line, 1, 4));
    // CLUT1: the left pixel is bit 7.
    try std.testing.expectEqual(@as(u32, 1), scan.fetch(&line, 0, 1));
    try std.testing.expectEqual(@as(u32, 0), scan.fetch(&line, 1, 1));
    try std.testing.expectEqual(@as(u32, 1), scan.fetch(&line, 7, 1));
}

test "a fetch past the end of a line reads as zero rather than off it" {
    const line = [_]u8{ 1, 2 };
    try std.testing.expectEqual(@as(u32, 0), scan.fetch(&line, 4, 16));
    try std.testing.expectEqual(@as(u32, 0), scan.fetch(&line, 9, 1));
}

test "a line of visible pixels is not the stride" {
    const padded = shape(4, 2, 64, .rgb565);
    try std.testing.expectEqual(@as(u32, 8), padded.lineBytes());
    const packed_clut1 = shape(16, 1, 8, .clut1);
    try std.testing.expectEqual(@as(u32, 2), packed_clut1.lineBytes());
}

test "scanning an RGB565 framebuffer hashes the colours that are in it" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    // Two pixels of pure red, two of pure blue.
    try core.write(fb_base, &[_]u8{ 0x00, 0xF8, 0x00, 0xF8, 0x1F, 0x00, 0x1F, 0x00 });

    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    const picture = scanner.run(core, shape(4, 1, 8, .rgb565), &palette).?;
    try std.testing.expectEqual(@as(u32, 4), picture.pixels);
    try std.testing.expectEqual(@as(u32, 2), picture.colours);
    try std.testing.expectEqual(@as(u32, 0), picture.blank);
    try std.testing.expect(picture.hash != scan.fnv.offset);
    try std.testing.expectEqual(@as(u32, 1), scanner.scans);
}

test "the stride's padding is not hashed" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try core.write(fb_base, &[_]u8{ 0x00, 0xF8, 0x1F, 0x00 });
    // The same two pixels, once tightly packed and once with a padded stride
    // and junk in the padding, hash the same.
    var palette = clut.Palette{};
    var tight = scan.Scanner{};
    const packed_picture = tight.run(core, shape(2, 1, 4, .rgb565), &palette).?;

    try core.write(fb_base, &[_]u8{ 0x00, 0xF8, 0x1F, 0x00, 0xAA, 0xBB, 0xCC, 0xDD });
    try core.write(fb_base + 8, &[_]u8{ 0x00, 0xF8, 0x1F, 0x00, 0xEE, 0xFF, 0x11, 0x22 });
    var padded = scan.Scanner{};
    const two_rows = padded.run(core, shape(2, 2, 8, .rgb565), &palette).?;

    try std.testing.expectEqual(@as(u32, 4), two_rows.pixels);
    try std.testing.expectEqual(@as(u32, 2), two_rows.colours);
    _ = packed_picture;
}

test "a CLUT framebuffer scans out the palette's colours, not its indices" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    // Four CLUT4 pixels in two bytes: indices 1, 2, 2, 1.
    try core.write(fb_base, &[_]u8{ 0x12, 0x21 });

    var palette = clut.Palette{};
    palette.store(0, 1, 0xFF00_00FF);
    palette.store(0, 2, 0xFF00_FF00);

    var scanner = scan.Scanner{};
    const picture = scanner.run(core, shape(4, 1, 2, .clut4), &palette).?;
    try std.testing.expectEqual(@as(u32, 4), picture.pixels);
    try std.testing.expectEqual(@as(u32, 2), picture.colours);
    try std.testing.expectEqual(@as(u32, 0), picture.blank);
}

test "the same indices through a different palette are a different picture" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try core.write(fb_base, &[_]u8{ 0x12, 0x21 });

    var first = clut.Palette{};
    first.store(0, 1, 0xFF00_00FF);
    first.store(0, 2, 0xFF00_FF00);
    var second = clut.Palette{};
    second.store(0, 1, 0xFFFF_0000);
    second.store(0, 2, 0xFF00_FF00);

    var scanner = scan.Scanner{};
    const one = scanner.run(core, shape(4, 1, 2, .clut4), &first).?.hash;
    const other = scanner.run(core, shape(4, 1, 2, .clut4), &second).?.hash;
    // dev hashes the index bytes, so both of these come out identical there.
    try std.testing.expect(one != other);
}

test "a CLUT layer over an empty palette is refused, not hashed" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    try core.write(fb_base, &[_]u8{ 0x12, 0x21 });

    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    try std.testing.expect(scanner.run(core, shape(4, 1, 2, .clut4), &palette) == null);
    try std.testing.expectEqual(@as(u32, 1), scanner.count(.no_palette));
    try std.testing.expectEqual(scan.Refusal.no_palette, scanner.last_refusal.?);
}

test "a framebuffer whose last line runs off the end of RAM is refused" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    var running = shape(4, 8, 2048, .rgb565);
    running.base = sram_end - 4096;
    running.window_end = sram_end;
    try std.testing.expect(scanner.run(core, running, &palette) == null);
    try std.testing.expectEqual(@as(u32, 1), scanner.count(.off_ram));
}

test "a base in no RAM window at all is refused the same way" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    var nowhere = shape(4, 1, 8, .rgb565);
    nowhere.window_end = null;
    try std.testing.expect(scanner.run(core, nowhere, &palette) == null);
    try std.testing.expectEqual(@as(u32, 1), scanner.count(.off_ram));
}

test "a panel larger than the scan will walk is refused" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    try std.testing.expect(scanner.run(core, shape(4096, 4096, 16384, .argb8888), &palette) == null);
    try std.testing.expectEqual(@as(u32, 1), scanner.count(.too_big));
}

test "a line wider than the read buffer is refused rather than cut down" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    // 2048 ARGB8888 pixels is 8 KiB of line, past the 4 KiB chunk.
    try std.testing.expect(scanner.run(core, shape(2048, 1, 8192, .argb8888), &palette) == null);
    try std.testing.expectEqual(@as(u32, 1), scanner.count(.too_big));
}

test "a cleared framebuffer reads as blank pixels, not as no picture" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    // ARGB8888 zeroes: decoded alpha is zero, so every pixel is transparent.
    const picture = scanner.run(core, shape(8, 2, 32, .argb8888), &palette).?;
    try std.testing.expectEqual(@as(u32, 16), picture.pixels);
    try std.testing.expectEqual(@as(u32, 16), picture.blank);
    try std.testing.expectEqual(@as(u32, 1), picture.colours);
}

test "an RGB888 framebuffer of zeroes is opaque black, not blank" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    const picture = scanner.run(core, shape(4, 1, 16, .rgb888), &palette).?;
    try std.testing.expectEqual(@as(u32, 0), picture.blank);
}

test "a scanner that never ran is quiet, and one that refused is not" {
    var scanner = scan.Scanner{};
    try std.testing.expect(scanner.quiet());
    try std.testing.expect(scanner.refuseNoLayer() == null);
    try std.testing.expect(!scanner.quiet());
    try std.testing.expectEqual(@as(u32, 1), scanner.count(.no_layer));
    try std.testing.expect(scanner.refuseOutputOff() == null);
    try std.testing.expectEqual(@as(u32, 1), scanner.count(.output_off));
}

test "colour counting stops at the sample bound instead of growing" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    // 256 CLUT8 pixels, each a distinct index, each a distinct colour.
    var line: [256]u8 = undefined;
    for (&line, 0..) |*byte, index| byte.* = @intCast(index);
    try core.write(fb_base, &line);

    var palette = clut.Palette{};
    for (0..256) |index| palette.store(0, @intCast(index), 0xFF00_0000 | @as(u32, @intCast(index)));

    var scanner = scan.Scanner{};
    const picture = scanner.run(core, shape(256, 1, 256, .clut8), &palette).?;
    try std.testing.expectEqual(@as(u32, 256), picture.pixels);
    try std.testing.expectEqual(scan.colour_sample, picture.colours);
}

test "pixels accumulate across scans and the last picture is kept" {
    const core = try store_memory.open();
    defer store_memory.close(core);
    var palette = clut.Palette{};
    var scanner = scan.Scanner{};
    _ = scanner.run(core, shape(4, 1, 8, .rgb565), &palette);
    _ = scanner.run(core, shape(4, 2, 8, .rgb565), &palette);
    try std.testing.expectEqual(@as(u32, 2), scanner.scans);
    try std.testing.expectEqual(@as(u32, 12), scanner.pixels);
    try std.testing.expectEqual(@as(u32, 8), scanner.last.?.pixels);
    try std.testing.expect(scanner.last_refusal == null);
}
