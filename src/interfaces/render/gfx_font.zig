//! The host window's label font (RA8EMU-1145): the firmware's 8x16 sans
//! face from ra8_gfx, so desktop text uses the same glyphs as the panel.
//! Printable ASCII is drawn through ra8_gfx at compile time into a
//! raster.Atlas, sixteen cells to a row. No font files are read at run time.
const std = @import("std");
const gfx = @import("ra8_gfx");
const raster = @import("raster.zig");
const draw_list = @import("draw_list.zig");

pub const glyph_w: u32 = gfx.text.sans.width;
pub const glyph_h: u32 = gfx.text.sans.height;
pub const cell_w: u32 = glyph_w;
pub const cell_h: u32 = glyph_h;
pub const first: u8 = 0x20;
pub const last: u8 = 0x7E;
const per_row: u32 = 16;
const rows: u32 = (last - first + per_row) / per_row;
const atlas_w = per_row * cell_w;
const atlas_h = rows * cell_h;

const coverage: [atlas_w * atlas_h]u8 = expand();

/// The font's atlas, for raster.draw.
pub const atlas = raster.Atlas{ .width = atlas_w, .height = atlas_h, .coverage = &coverage };

/// Where a glyph's cell starts in the atlas.
pub const Cell = struct { x: u32, y: u32 };

/// The cell for `char`; anything outside printable ASCII shows as '?'.
pub fn cell(char: u8) Cell {
    const shown = if (char < first or char > last) '?' else char;
    const index: u32 = shown - first;
    return .{ .x = index % per_row * cell_w, .y = index / per_row * cell_h };
}

/// Pixels `len` characters take across.
pub fn textWidth(len: usize) u32 {
    return @intCast(len * cell_w);
}

/// The longest start of `text` that fits in `max_px` pixels across.
pub fn fit(text: []const u8, max_px: u32) []const u8 {
    return text[0..@min(text.len, max_px / cell_w)];
}

/// Adds `text` to the list with its top-left at (`x`, `y`), one glyph per
/// character; spaces add nothing.
pub fn draw(list: *draw_list.DrawList, x: i32, y: i32, text: []const u8, color: draw_list.Color) !void {
    for (text, 0..) |char, index| {
        if (char == ' ') continue;
        const at = cell(char);
        const left = x + @as(i32, @intCast(index * cell_w));
        try list.glyph(.{ .x = left, .y = y, .w = glyph_w, .h = glyph_h }, at.x, at.y, color);
    }
}

/// Adds `text`, cut to whole cells that fit with a pixel spare each side,
/// centred in `area`. An area shorter than a glyph still gets it centred:
/// it hangs over the top and the foot alike and the clip takes the rest.
pub fn centred(list: *draw_list.DrawList, area: draw_list.Rect, text: []const u8, color: draw_list.Color) !void {
    const shown = fit(text, @intCast(@max(area.w - 2, 0)));
    if (shown.len == 0) return;
    const x = area.x + draw_list.centre(area.w, @intCast(textWidth(shown.len)));
    const y = area.y + draw_list.centre(area.h, glyph_h);
    try draw(list, x, y, shown, color);
}

const Sink = struct { out: *[atlas_w * atlas_h]u8 };

fn plot(user: ?*anyopaque, x: i32, y: i32, color: u32) callconv(.c) void {
    if (color == 0 or x < 0 or y < 0) return;
    const sink: *Sink = @ptrCast(@alignCast(user.?));
    sink.out[@as(u32, @intCast(y)) * atlas_w + @as(u32, @intCast(x))] = 255;
}

fn expand() [atlas_w * atlas_h]u8 {
    @setEvalBranchQuota(2_000_000);
    var out = @as([atlas_w * atlas_h]u8, @splat(0));
    var sink = Sink{ .out = &out };
    var char: u8 = first;
    while (char <= last) : (char += 1) {
        const origin = cell(char);
        const run = [2:0]u8{ char, 0 };
        gfx.text.drawSans(&run, @intCast(origin.x), @intCast(origin.y), 0xFFFFFF, 0, &sink, plot);
    }
    return out;
}
