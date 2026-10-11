//! Tests for src/session/region/map/text.zig: the map text of the EK-RA8D2
//! fixture, checked line by line.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const region_map_text = ra8.session.region.map.text;
const region_map = ra8.session.region.map;

const image_bytes = @embedFile("../../../fixtures/sections/fault_crashlog_hil.elf");

fn rendered(gpa: std.mem.Allocator) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try region_map_text.render(&out.writer, try elf.Image.init(image_bytes), &region_map.ek_ra8d2);
    return out;
}

fn expectLine(text: []const u8, line: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |got| if (std.mem.eql(u8, got, line)) return;
    std.debug.print("missing line: \"{s}\"\n", .{line});
    return error.TestExpectedEqual;
}

test "each region prints its range, used over total and percent" {
    var out = try rendered(std.testing.allocator);
    defer out.deinit();
    try expectLine(out.written(), "MRAM     0x02000000-0x020fffff     13396 /  1048576 bytes  1.2%");
    try expectLine(out.written(), "SRAM     0x22000000-0x220ffeff      2936 /  1048320 bytes  0.2%");
    try expectLine(out.written(), "NOINIT   0x220fff00-0x220fffff        92 /      256 bytes  35.9%");
    try expectLine(out.written(), "ITCM     0x00000000-0x0000ffff         0 /    65536 bytes  0.0%");
}

test "sections sit under their region, .data under both" {
    var out = try rendered(std.testing.allocator);
    defer out.deinit();
    try expectLine(out.written(), "  .text                          run  0x02000200                       8864");
    try expectLine(out.written(), "  .data                          load 0x0200342c  (runs at 0x22000000)        40");
    try expectLine(out.written(), "  .data                          run  0x22000000  load 0x0200342c        40");
    try expectLine(out.written(), "  .noinit                        run  0x220fff00                         92");
    // The stored copy is listed under MRAM, before the SRAM block opens.
    const copy = std.mem.indexOf(u8, out.written(), "load 0x0200342c  (runs").?;
    try std.testing.expect(copy < std.mem.indexOf(u8, out.written(), "SRAM     ").?);
    try std.testing.expect(copy > std.mem.indexOf(u8, out.written(), "MRAM     ").?);
}

test "the stack reservation closes the map and nothing is outside" {
    var out = try rendered(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "stack    0x220fdf00-0x220ffeff      8192 bytes in SRAM\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "outside every region") == null);
}

test "a region list that misses sections prints them as outside" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try region_map_text.render(&out.writer, try elf.Image.init(image_bytes), region_map.ek_ra8d2[0..1]);
    try expectLine(out.written(), "outside every region: 22 sections, 3100 bytes");
    try expectLine(out.written(), "stack    0x220fdf00-0x220ffeff      8192 bytes in no region");
}
