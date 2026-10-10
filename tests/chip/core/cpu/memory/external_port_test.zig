const std = @import("std");
const ra8 = @import("ra8");
const port = ra8.chip.core.cpu.memory.external_port;

test "geometry decodes both apertures and the Non-secure SDRAM alias" {
    const geometry: port.Geometry = .{ .ospi = 1024 * 1024, .sdram = 2 * 1024 * 1024 };
    const flash = geometry.locate(0x8000_0010, 4).?;
    try std.testing.expectEqual(port.Kind.ospi, flash.kind);
    try std.testing.expectEqual(@as(u32, 0x10), flash.offset);
    const alias = geometry.locate(port.sdram_alias_base + 0x20, 4).?;
    try std.testing.expectEqual(port.Kind.sdram, alias.kind);
    try std.testing.expectEqual(@as(u32, 0x20), alias.offset);
    try std.testing.expect(geometry.locate(0x6820_0000, 1) == null);
    try std.testing.expect(geometry.overlaps(0x681F_FFFF, 2));
    try std.testing.expect(!geometry.overlaps(0x6820_0000, 4));
}

test "the controller's whole aperture counts as external past the capacity" {
    try std.testing.expect(port.supportedOverlap(0x8FFF_FFFF, 1));
    try std.testing.expect(port.supportedOverlap(0x6FFF_FFFF, 1));
    try std.testing.expect(!port.supportedOverlap(0x7000_0000, 4));
}
