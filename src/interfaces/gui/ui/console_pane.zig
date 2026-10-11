//! The console pane (RA8EMU-206): one channel's log drawn as the newest
//! lines that fit, oldest at the top, each stamped with the virtual time it
//! ended at, and the line still being printed last without a stamp. When its
//! area leaves no room for a row it draws nothing. Scrolled `back` lines
//! from the newest it shows the finished lines ending there and hides the
//! unfinished one.
//! Read-only: it draws what console_log.Log holds.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const console_log = @import("../console/log.zig");
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// Space round the text inside the pane, and between it and the board.
pub const pad: i32 = 4;
/// Characters a time stamp takes: "[   1.000000000] ".
pub const stamp_len: usize = 17;

/// The strip under a board view `view_w` x `view_h` in a window
/// `window_h` high.
pub fn under(view_w: u32, view_h: u32, window_h: u32) Rect {
    const top: i32 = @as(i32, @intCast(view_h)) + pad;
    return .{ .x = 0, .y = top, .w = @intCast(view_w), .h = @max(@as(i32, @intCast(window_h)) - top, 0) };
}

/// How many text rows fit in `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < font.glyph_h) return 0;
    return @intCast(@divTrunc(inner, @as(i32, @intCast(font.cell_h))));
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, log: *const console_log.Log, back: usize) !void {
    const count = rows(area);
    if (count == 0) return;
    try list.fill(area, theme.background);
    try list.pushClip(area);
    defer list.popClip();
    const partial = if (back == 0) log.partial() else "";
    const room = count - @intFromBool(partial.len > 0);
    const lines = log.lines();
    const end = @max(lines.len -| back, @min(room, lines.len));
    const first = end -| room;
    const width: u32 = @intCast(@max(area.w - 2 * pad, 0));
    const x = area.x + pad;
    var y = area.y + pad;
    for (lines[first..end]) |entry| {
        try drawEntry(list, theme, x, y, width, entry);
        y += @intCast(font.cell_h);
    }
    if (partial.len > 0) try font.draw(list, x + @as(i32, @intCast(font.textWidth(stamp_len))), y, font.fit(partial, width -| font.textWidth(stamp_len)), theme.ink);
}

fn drawEntry(list: *draw_list.DrawList, theme: *const Theme, x: i32, y: i32, width: u32, entry: console_log.Entry) !void {
    var buffer: [stamp_len + 8]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    console_log.stamp(&stream, entry.at_ns) catch {};
    const stamp = stream.buffered();
    try font.draw(list, x, y, font.fit(stamp, width), theme.muted);
    const left = font.textWidth(stamp.len);
    try font.draw(list, x + @as(i32, @intCast(left)), y, font.fit(entry.text, width -| left), theme.ink);
}
