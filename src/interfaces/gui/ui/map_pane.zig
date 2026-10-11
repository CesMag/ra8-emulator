//! The memory map pane (RA8EMU-781): one vertical bar per linker region that
//! holds anything, low addresses at the top, with each section a block
//! scaled to its size and coloured by kind; what is left of the bar is
//! free. Hovering a block names it with its range and size, and for a
//! section stored apart from where it runs, draws a line to the other copy.
//! A click gives the address the memory pane should move to.

const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;
const layout_mod = @import("../map_layout.zig");
const Layout = layout_mod.Layout;
const Block = layout_mod.Block;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
pub const gap: i32 = 6;
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const max_bars = 16;
const min_bar_w: i32 = 8;
const min_bar_h: i32 = 16;

/// Bar `slot` of `count` across `area`, below the label row and above the
/// hover row.
pub fn barRect(area: Rect, slot: usize, count: usize) Rect {
    const n: i32 = @intCast(count);
    const width = @divTrunc(area.w - 2 * pad - (n - 1) * gap, n);
    const x = area.x + pad + @as(i32, @intCast(slot)) * (width + gap);
    return .{ .x = x, .y = area.y + pad + row_h, .w = width, .h = area.h - 2 * pad - 2 * row_h };
}

/// Where `block` sits inside its region's bar, at least one pixel tall.
pub fn blockRect(layout: *const Layout, bar: Rect, block: Block) Rect {
    const region = layout.map.regions[block.region];
    const height: u64 = @intCast(bar.h);
    const top = (@as(u64, block.start - region.base) * height) / region.size;
    const bottom = ((block.end() - region.base) * height) / region.size;
    const tall: i32 = @intCast(@max(1, bottom - top));
    return .{ .x = bar.x + 1, .y = bar.y + @as(i32, @intCast(top)), .w = bar.w - 2, .h = tall };
}

fn usable(area: Rect, count: usize) bool {
    if (count == 0) return false;
    const bar = barRect(area, 0, count);
    return bar.w >= min_bar_w and bar.h >= min_bar_h;
}

/// The block under (x, y), the last drawn first, or null.
pub fn hit(layout: *const Layout, area: Rect, x: i32, y: i32) ?usize {
    var slots: [max_bars]usize = undefined;
    const bars = layout.bars(&slots);
    if (!usable(area, bars.len)) return null;
    var index = layout.count;
    while (index > 0) {
        index -= 1;
        const block = layout.blocks[index];
        const slot = std.mem.indexOfScalar(usize, bars, block.region) orelse continue;
        if (blockRect(layout, barRect(area, slot, bars.len), block).contains(x, y)) return index;
    }
    return null;
}

/// The address a click at (x, y) moves the memory pane to: the start of the
/// block under it.
pub fn click(layout: *const Layout, area: Rect, x: i32, y: i32) ?u32 {
    const index = hit(layout, area, x, y) orelse return null;
    return layout.blocks[index].start;
}

pub fn color(theme: *const Theme, kind: layout_mod.Kind) draw_list.Color {
    return switch (kind) {
        .code => theme.accent,
        .read_only => theme.pc_cyan,
        .initialised => theme.good,
        .zero_fill => theme.band,
        .no_init => theme.muted,
        .stack => theme.selected_face,
    };
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, layout: *const Layout, hover: ?usize) !void {
    var slots: [max_bars]usize = undefined;
    const bars = layout.bars(&slots);
    if (!usable(area, bars.len)) return;
    try list.fill(area, theme.background);
    try list.pushClip(area);
    defer list.popClip();
    for (bars, 0..) |region, slot| try drawBar(list, theme, layout, barRect(area, slot, bars.len), region, hover);
    if (hover) |index| try drawHover(list, theme, area, layout, bars, index);
}

fn drawBar(list: *draw_list.DrawList, theme: *const Theme, layout: *const Layout, bar: Rect, region: usize, hover: ?usize) !void {
    const name = font.fit(layout.map.regions[region].name, @intCast(bar.w));
    try font.draw(list, bar.x, bar.y - row_h + 2, name, theme.ink);
    try list.fill(bar, theme.border);
    try list.fill(.{ .x = bar.x + 1, .y = bar.y + 1, .w = bar.w - 2, .h = bar.h - 2 }, theme.well);
    for (layout.items(), 0..) |block, index| {
        if (block.region != region) continue;
        const shown = if (hover == index) theme.highlight else color(theme, block.kind);
        try list.fill(blockRect(layout, bar, block), shown);
    }
}

fn drawHover(list: *draw_list.DrawList, theme: *const Theme, area: Rect, layout: *const Layout, bars: []const usize, index: usize) !void {
    const block = layout.blocks[index];
    var buffer: [128]u8 = undefined;
    const text = try describe(&buffer, layout, block);
    const y = area.y + area.h - pad - row_h + 2;
    try font.draw(list, area.x + pad, y, font.fit(text, @intCast(area.w - 2 * pad)), theme.ink);
    const other = block.pair orelse return;
    const from = centre(layout, area, bars, block) orelse return;
    const to = centre(layout, area, bars, layout.blocks[other]) orelse return;
    try list.line(from.x, from.y, to.x, to.y, theme.ink);
}

/// "name 0xSTART-0xEND N B", with where the other copy of a stored section is.
pub fn describe(buffer: []u8, layout: *const Layout, block: Block) ![]const u8 {
    const last: u32 = @intCast(block.end() - 1);
    const head = try std.fmt.bufPrint(buffer, "{s} {X:0>8}-{X:0>8} {d} B", .{ block.name, block.start, last, block.size });
    const other = block.pair orelse return head;
    const word = if (block.load) "runs at" else "loaded from";
    const tail = try std.fmt.bufPrint(buffer[head.len..], ", {s} {X:0>8}", .{ word, layout.blocks[other].start });
    return buffer[0 .. head.len + tail.len];
}

fn centre(layout: *const Layout, area: Rect, bars: []const usize, block: Block) ?struct { x: i32, y: i32 } {
    const slot = std.mem.indexOfScalar(usize, bars, block.region) orelse return null;
    const box = blockRect(layout, barRect(area, slot, bars.len), block);
    return .{ .x = box.x + @divTrunc(box.w, 2), .y = box.y + @divTrunc(box.h, 2) };
}
