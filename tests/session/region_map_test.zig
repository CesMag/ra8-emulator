//! The region map on a real EK-RA8D2 image: per-region usage adds up to the
//! section sizes, .data takes room in MRAM and SRAM, and the 8K stack sits
//! directly under NOINIT at the top of SRAM.
const std = @import("std");
const ra8 = @import("ra8");
const elf = ra8.board.image.elf;
const sections = ra8.session.sections;
const region_map = ra8.session.region_map;

const image_bytes = @embedFile("../fixtures/sections/fault_crashlog_hil.elf");

fn mapOf() !region_map.Map {
    return region_map.build(try elf.Image.init(image_bytes), &region_map.ek_ra8d2);
}

fn used(map: region_map.Map, name: []const u8) u64 {
    return map.used[map.find(name).?];
}

test "per-region usage matches the sections objdump lists" {
    const map = try mapOf();
    // .vectors 0x200 + .text 0x236c + .rodata 0xfba + .ARM.exidx 0x28, plus
    // the 0x28-byte stored copy of .data.
    try std.testing.expectEqual(@as(u64, 0x3576), used(map, "MRAM"));
    try std.testing.expectEqual(@as(u64, 11 * 4), used(map, "OFS_CFG"));
    try std.testing.expectEqual(@as(u64, 7 * 4), used(map, "OFS_OTP"));
    // .data 0x28 + .bss 0xb30 + .stack_canary 0x20.
    try std.testing.expectEqual(@as(u64, 0xb78), used(map, "SRAM"));
    try std.testing.expectEqual(@as(u64, 0x5c), used(map, "NOINIT"));
    try std.testing.expectEqual(@as(u64, 0), used(map, "SDRAM"));
    try std.testing.expectEqual(@as(usize, 0), map.outside);
}

test "usage adds up to the section sizes plus each stored copy" {
    const image = try elf.Image.init(image_bytes);
    const map = try region_map.build(image, &region_map.ek_ra8d2);
    var rows: [32]sections.Section = undefined;
    var expected: u64 = 0;
    for (rows[0..sections.list(image, &rows)]) |row| {
        expected += row.size;
        if (row.stored() and row.lma != row.vma) expected += row.size;
    }
    var total: u64 = 0;
    for (map.used[0..map.regions.len]) |bytes| total += bytes;
    try std.testing.expectEqual(expected, total);
    const sram = map.find("SRAM").?;
    try std.testing.expectEqual(region_map.ek_ra8d2[sram].size - 0xb78, map.free(sram));
}

test ".data is counted in both MRAM and SRAM" {
    const data = sections.byName(try elf.Image.init(image_bytes), ".data").?;
    const map = try mapOf();
    try std.testing.expectEqual(map.find("SRAM"), region_map.regionAt(map.regions, data.vma, data.size));
    try std.testing.expectEqual(map.find("MRAM"), region_map.regionAt(map.regions, data.lma, data.size));
}

test "the 8K stack sits directly under NOINIT at the top of SRAM" {
    const map = try mapOf();
    const stack = map.stack.?;
    const noinit = region_map.ek_ra8d2[map.find("NOINIT").?];
    try std.testing.expectEqual(@as(u32, 8 * 1024), stack.size);
    try std.testing.expectEqual(noinit.base, stack.base + stack.size);
    try std.testing.expectEqual(map.find("SRAM"), stack.region);
}

test "a section outside every region is reported, not dropped" {
    // Only MRAM: everything that runs in SRAM, NOINIT or option memory is
    // now outside, and the stack has no region.
    const image = try elf.Image.init(image_bytes);
    const map = try region_map.build(image, region_map.ek_ra8d2[0..1]);
    try std.testing.expectEqual(@as(u64, 0x3576), map.used[0]);
    // 11 OFS_CFG + 7 OFS_OTP + .data + .bss + .stack_canary + .noinit.
    try std.testing.expectEqual(@as(usize, 22), map.outside);
    try std.testing.expectEqual(@as(u64, 44 + 28 + 0xb78 + 0x5c), map.outside_bytes);
    try std.testing.expectEqual(@as(?usize, null), map.stack.?.region);
}

test "a span straddling a region's end fits nowhere" {
    const regions = [_]region_map.Region{.{ .name = "A", .base = 0x100, .size = 0x100 }};
    try std.testing.expectEqual(@as(?usize, 0), region_map.regionAt(&regions, 0x1f0, 0x10));
    try std.testing.expectEqual(@as(?usize, null), region_map.regionAt(&regions, 0x1f0, 0x11));
    try std.testing.expectEqual(@as(?usize, null), region_map.regionAt(&regions, 0xff, 1));
}

test "too many regions is refused" {
    const image = try elf.Image.init(image_bytes);
    const many = @as([region_map.max_regions + 1]region_map.Region, @splat(.{ .name = "X", .base = 0, .size = 1 }));
    try std.testing.expectError(region_map.Error.TooManyRegions, region_map.build(image, &many));
}
