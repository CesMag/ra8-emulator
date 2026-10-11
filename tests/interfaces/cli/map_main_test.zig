//! `ra8_emulator --map`: the binary prints region.map.text's map of the
//! EK-RA8D2 fixture and exits 0, and refuses a missing image.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const elf = ra8.board.image.elf;
const region_map_text = ra8.session.region.map.text;
const region_map = ra8.session.region.map;

const fixture = "tests/fixtures/sections/fault_crashlog_hil.elf";
const image_bytes = @embedFile("../../fixtures/sections/fault_crashlog_hil.elf");

fn rendered(gpa: std.mem.Allocator) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try region_map_text.render(&out.writer, try elf.Image.init(image_bytes), &region_map.ek_ra8d2);
    return out;
}

test "the binary prints the same map and exits 0" {
    const gpa = std.testing.allocator;
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_paths.emulator, "--map", fixture } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    var out = try rendered(gpa);
    defer out.deinit();
    try std.testing.expectEqualStrings(out.written(), result.stdout);
}

test "a missing image argument is a usage error" {
    const gpa = std.testing.allocator;
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_paths.emulator, "--map" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, result.term);
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, "usage: ra8_emulator --map"));
}
