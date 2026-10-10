//! The console pane's channel pick (RA8EMU-206): a strip of one tab per SCI
//! channel across the top of the pane, the log under it. Clicking a tab
//! shows that channel's log. The shown tab is lit, and a channel that has
//! printed anything is labelled brighter than one that is still empty, so
//! a demo talking on a channel other than the console is easy to find.
//! A SAVE tab at the strip's right end writes the shown log to a file.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const console_log = @import("../console_log.zig");
const console_pane = @import("console_pane.zig");
const colors = @import("colors.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const lit = colors.selected_face;
/// The SAVE tab's face, set apart from the lit channel tab.
pub const button = colors.button_face;
/// Characters the widest label takes: "SCI10".
pub const label_len: usize = 5;
/// One tab: the widest label with the pane's pad either side.
pub const tab_w: i32 = @as(i32, @intCast(font.textWidth(label_len))) + 2 * console_pane.pad;
/// The strip: one text row with the pane's pad above and below.
pub const strip_h: i32 = @as(i32, @intCast(font.cell_h)) + 2 * console_pane.pad;

/// The tab strip across the top of `area`; empty when `area` is shorter.
pub fn strip(area: Rect) Rect {
    if (area.h < strip_h) return .{ .x = area.x, .y = area.y, .w = area.w, .h = 0 };
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = strip_h };
}

/// The SAVE tab at the strip's right end; empty when the strip cannot
/// fit it beside at least one channel tab.
pub fn saveTab(area: Rect) Rect {
    const row = strip(area);
    const w: i32 = if (row.w >= 2 * tab_w) tab_w else 0;
    return .{ .x = row.x + row.w - w, .y = row.y, .w = w, .h = row.h };
}

/// What is left of `area` under the strip, for the log.
pub fn below(area: Rect) Rect {
    const top = strip(area).h;
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = area.h - top };
}

/// The tab of `count` that (`x`, `y`) falls on, if any.
pub fn tabAt(area: Rect, count: usize, x: i32, y: i32) ?usize {
    const row = strip(area);
    if (!row.contains(x, y) or saveTab(area).contains(x, y)) return null;
    const index: usize = @intCast(@divTrunc(x - row.x, tab_w));
    return if (index < count) index else null;
}

pub fn draw(list: *draw_list.DrawList, area: Rect, logs: []const console_log.Log, shown: usize) !void {
    const row = strip(area);
    if (row.h == 0) return;
    try list.fill(row, console_pane.panel);
    try list.pushClip(row);
    defer list.popClip();
    for (logs, 0..) |*log, index| {
        const x = row.x + @as(i32, @intCast(index)) * tab_w;
        const tab = Rect{ .x = x, .y = row.y, .w = tab_w, .h = row.h };
        if (index == shown) try list.fill(tab, lit);
        var buffer: [label_len + 4]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "SCI{d}", .{index}) catch continue;
        const busy = log.lines().len > 0 or log.partial().len > 0 or log.dropped > 0;
        try font.draw(list, x + console_pane.pad, row.y + console_pane.pad, label, if (busy) console_pane.ink else console_pane.muted);
    }
    const save = saveTab(area);
    if (save.w == 0) return;
    try list.fill(save, button);
    try font.draw(list, save.x + console_pane.pad, row.y + console_pane.pad, "SAVE", console_pane.ink);
}
