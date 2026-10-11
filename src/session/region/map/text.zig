//! The memory map of an image as text (RA8EMU-1093, moved from the
//! `--map` command): one block per linker region (name, range, used/total,
//! percent) with the sections that run there underneath, then the stack
//! reservation, then any section that fits no region. The numbers are
//! region_map.zig's; this file only lays them out.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const sections = @import("../../sections.zig");
const region_map = @import("map.zig");

/// The map of `image` over `regions`, as text.
pub fn render(writer: anytype, image: elf.Image, regions: []const region_map.Region) !void {
    const map = try region_map.build(image, regions);
    for (regions, 0..) |region, index| {
        try regionLine(writer, region, map.used[index]);
        try sectionsIn(writer, image, regions, index);
    }
    try stackLine(writer, map);
    if (map.outside != 0) {
        try writer.print("outside every region: {d} sections, {d} bytes\n", .{ map.outside, map.outside_bytes });
        try sectionsIn(writer, image, regions, null);
    }
}

fn regionLine(writer: anytype, region: region_map.Region, used: u64) !void {
    const last = @as(u64, region.base) + region.size - 1;
    const tenths = if (region.size == 0) 0 else used * 1000 / region.size;
    try writer.print("{s: <8} 0x{x:0>8}-0x{x:0>8}  {d: >8} / {d: >8} bytes  {d}.{d}%\n", .{
        region.name, region.base, last, used, region.size, tenths / 10, tenths % 10,
    });
}

/// The sections placed in region `wanted` (null: in none), each where it
/// runs and, for a stored copy, where it is stored.
fn sectionsIn(writer: anytype, image: elf.Image, regions: []const region_map.Region, wanted: ?usize) !void {
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const found = sections.read(image, index) orelse continue;
        if (found.size == 0) continue;
        if (region_map.regionAt(regions, found.vma, found.size) == wanted) try runLine(writer, found);
        if (!found.stored() or found.lma == found.vma) continue;
        if (region_map.regionAt(regions, found.lma, found.size) == wanted) try storedLine(writer, found);
    }
}

fn runLine(writer: anytype, found: sections.Section) !void {
    if (found.stored() and found.lma != found.vma) {
        try writer.print("  {s: <30} run  0x{x:0>8}  load 0x{x:0>8}  {d: >8}\n", .{ found.name, found.vma, found.lma, found.size });
    } else {
        try writer.print("  {s: <30} run  0x{x:0>8}                   {d: >8}\n", .{ found.name, found.vma, found.size });
    }
}

fn storedLine(writer: anytype, found: sections.Section) !void {
    try writer.print("  {s: <30} load 0x{x:0>8}  (runs at 0x{x:0>8})  {d: >8}\n", .{ found.name, found.lma, found.vma, found.size });
}

fn stackLine(writer: anytype, map: region_map.Map) !void {
    const stack = map.stack orelse return writer.writeAll("stack    not found (no g_ra8_ls_stack_top / g_ra8_ls_stack_size)\n");
    const where = if (stack.region) |index| map.regions[index].name else "no region";
    try writer.print("stack    0x{x:0>8}-0x{x:0>8}  {d: >8} bytes in {s}\n", .{
        stack.base, stack.base +% stack.size -% 1, stack.size, where,
    });
}
