//! The devices pane (RA8EMU-703): devices_panel.zig's rows drawn one per
//! line, the endpoint on the left as the debugger and `--faults FILE`
//! spell it, the part on it (or "empty") on the right, and a click on a
//! row toggling it through the session. It draws nothing when no row fits.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const devices_panel = @import("../devices_panel.zig");
const colors = @import("colors.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Endpoint = devices_panel.Endpoint;

pub const background = colors.background;
pub const ink = colors.ink;
pub const muted = colors.muted;
pub const fitted = colors.fitted_band;
pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
/// Characters the endpoint column takes: "i2c:touch@0x36" plus a gap.
pub const endpoint_len: usize = 16;

/// The endpoint as `endpoint.parse` reads it back: i2c:riic@0x36,
/// spi:spi1@ssl0, uart:sci3, gpio:P106.
pub fn label(buffer: []u8, at: Endpoint) []const u8 {
    return switch (at) {
        .i2c => |i| std.fmt.bufPrint(buffer, "i2c:{s}@0x{X:0>2}", .{ @tagName(i.line), i.address }),
        .spi => |s| std.fmt.bufPrint(buffer, "spi:spi{d}@ssl{d}", .{ s.channel, s.select }),
        .uart => |u| std.fmt.bufPrint(buffer, "uart:sci{d}", .{u.channel}),
        .gpio => |g| std.fmt.bufPrint(buffer, "gpio:P{X}{d:0>2}", .{ g.port, g.pin }),
    } catch "?";
}

/// Row `index`'s strip inside `area`.
pub fn rowRect(area: Rect, index: usize) Rect {
    const at: i32 = @intCast(index);
    return .{ .x = area.x + pad, .y = area.y + pad + at * row_h, .w = @max(area.w - 2 * pad, 0), .h = row_h };
}

/// How many rows fit in `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

pub fn draw(list: *draw_list.DrawList, area: Rect, panel: devices_panel.Panel) !void {
    const count = @min(rows(area), panel.rows.len);
    if (count == 0) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    for (panel.rows[0..count], 0..) |row, index| try drawRow(list, rowRect(area, index), row);
}

fn drawRow(list: *draw_list.DrawList, strip: Rect, row: devices_panel.Row) !void {
    if (row.part != null) try list.fill(strip, fitted);
    const width: u32 = @intCast(strip.w);
    const y = strip.y + 2;
    var buffer: [24]u8 = undefined;
    try font.draw(list, strip.x + 2, y, font.fit(label(&buffer, row.at), width), muted);
    const left = font.textWidth(endpoint_len);
    const part = row.part orelse "empty";
    try font.draw(list, strip.x + 2 + @as(i32, @intCast(left)), y, font.fit(part, width -| left), if (row.part != null) ink else muted);
}

/// The row under (`x`, `y`), or null when the click missed every row.
pub fn hit(area: Rect, panel: devices_panel.Panel, x: i32, y: i32) ?usize {
    const count = @min(rows(area), panel.rows.len);
    for (0..count) |index| {
        if (rowRect(area, index).contains(x, y)) return index;
    }
    return null;
}

/// Toggles the row under (`x`, `y`) through the session; false when the
/// click missed every row. A refused change comes back as its error.
pub fn click(panel: *devices_panel.Panel, area: Rect, x: i32, y: i32) anyerror!bool {
    const index = hit(area, panel.*, x, y) orelse return false;
    try panel.click(index);
    return true;
}
