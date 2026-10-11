//! Tests for src/chip/core/part/map.zig: each part's geometry against its
//! datasheet row, and against what src/chip/core/memmap.zig maps.

const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const part_map = ra8.chip.core.part.map;

fn expectDualCoreRow(geometry: part_map.Geometry) !void {
    try std.testing.expectEqual(@as(u32, 1024 * 1024), geometry.mram_bytes);
    try std.testing.expectEqual(@as(u32, 1664 * 1024), geometry.sram_bytes);
    try std.testing.expectEqual(@as(u32, 256 * 1024), geometry.cpu0TcmBytes());
    try std.testing.expectEqual(@as(u32, 128 * 1024), geometry.cpu1TcmBytes());
    try std.testing.expectEqual(@as(u32, 32 * 1024), 2 * geometry.cpu0_cache_bank_bytes);
    try std.testing.expectEqual(@as(u32, 32 * 1024), 2 * geometry.cpu1_cache_bank_bytes);
}

test "the RA8D2 matches its datasheet's dual-core row" {
    const geometry = part_map.of(.ra8d2);
    try expectDualCoreRow(geometry);
    try std.testing.expect(std.mem.indexOf(u8, geometry.source, "Table 1.14") != null);
}

test "the RA8P1 matches its datasheet's dual-core row" {
    const geometry = part_map.of(.ra8p1);
    try expectDualCoreRow(geometry);
    try std.testing.expect(std.mem.indexOf(u8, geometry.source, "Table 1.15") != null);
}

test "the mapped SRAM is exactly the part's SRAM on both parts" {
    for ([_]ra8.chip.core.part.Part{ .ra8d2, .ra8p1 }) |part| {
        const geometry = part_map.of(part);
        try std.testing.expectEqual(memmap.sram_base, geometry.sram_base);
        try std.testing.expectEqual(memmap.sram_end - memmap.sram_base, geometry.sram_bytes);
    }
}

test "the M85 DTCM window mapped today sits inside the bank" {
    const geometry = part_map.of(.ra8p1);
    try std.testing.expect(memmap.dtcm_end - memmap.dtcm_base <= geometry.cpu0_tcm_bank_bytes);
}
