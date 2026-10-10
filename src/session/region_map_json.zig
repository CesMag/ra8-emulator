//! The memory map of an image as one JSON object (RA8EMU-794), for
//! `ctl map --json`. The same numbers region_map.zig builds and `--map`
//! prints: per region its range, used bytes and the sections placed there
//! (a stored section's load copy listed under its load region with copy
//! "load"), then the stack reservation, then what fits no region.
//!
//! {"regions":[{"name","base","size","used","sections":[{"name","vma",
//!  "lma","size","kind","copy"}]}],"stack":{"base","size","region"}|null,
//!  "outside":{"count","bytes","sections":[...]}}
const std = @import("std");
const elf = @import("../board/image/elf.zig");
const sections = @import("sections.zig");
const region_map = @import("region_map.zig");

pub fn write(writer: *std.Io.Writer, image: elf.Image, regions: []const region_map.Region) !void {
    const map = try region_map.build(image, regions);
    var ws: std.json.Stringify = .{ .writer = writer };
    try ws.beginObject();
    try ws.objectField("regions");
    try ws.beginArray();
    for (regions, 0..) |region, index| {
        try ws.beginObject();
        try field(&ws, "name", region.name);
        try field(&ws, "base", region.base);
        try field(&ws, "size", region.size);
        try field(&ws, "used", map.used[index]);
        try placed(&ws, image, regions, index);
        try ws.endObject();
    }
    try ws.endArray();
    try stack(&ws, map);
    try ws.objectField("outside");
    try ws.beginObject();
    try field(&ws, "count", map.outside);
    try field(&ws, "bytes", map.outside_bytes);
    try placed(&ws, image, regions, null);
    try ws.endObject();
    try ws.endObject();
}

fn field(ws: anytype, name: []const u8, value: anytype) !void {
    try ws.objectField(name);
    try ws.write(value);
}

/// The "sections" array of region `wanted` (null: in none).
fn placed(ws: anytype, image: elf.Image, regions: []const region_map.Region, wanted: ?usize) !void {
    try ws.objectField("sections");
    try ws.beginArray();
    var index: u16 = 0;
    while (index < image.header().e_shnum) : (index += 1) {
        const found = sections.read(image, index) orelse continue;
        if (found.size == 0) continue;
        if (region_map.regionAt(regions, found.vma, found.size) == wanted) try entry(ws, found, "run");
        if (!found.stored() or found.lma == found.vma) continue;
        if (region_map.regionAt(regions, found.lma, found.size) == wanted) try entry(ws, found, "load");
    }
    try ws.endArray();
}

fn entry(ws: anytype, found: sections.Section, copy: []const u8) !void {
    try ws.beginObject();
    try field(ws, "name", found.name);
    try field(ws, "vma", found.vma);
    try field(ws, "lma", found.lma);
    try field(ws, "size", found.size);
    try field(ws, "kind", @tagName(found.kind));
    try field(ws, "copy", copy);
    try ws.endObject();
}

fn stack(ws: anytype, map: region_map.Map) !void {
    try ws.objectField("stack");
    const found = map.stack orelse return ws.write(null);
    try ws.beginObject();
    try field(ws, "base", found.base);
    try field(ws, "size", found.size);
    try ws.objectField("region");
    if (found.region) |index| try ws.write(map.regions[index].name) else try ws.write(null);
    try ws.endObject();
}
