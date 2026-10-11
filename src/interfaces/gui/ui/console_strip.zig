//! The console leaf's tool strip (RA8EMU-1122): one text row across the
//! top of the leaf with the save tab at its right end, the log under it.
//! The tab reads SAVE, then SAVED or FAILED after a save.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const console_pane = @import("console_pane.zig");
const console_save = @import("../console_save.zig");
const Theme = @import("colors.zig").Theme;

const Rect = draw_list.Rect;

/// The strip: one text row with the pane's pad above and below.
pub const strip_h: i32 = @as(i32, @intCast(font.cell_h)) + 2 * console_pane.pad;
/// The save tab: the widest label with the pane's pad either side.
pub const tab_w: i32 = @as(i32, @intCast(font.textWidth(console_save.label_len))) + 2 * console_pane.pad;

/// The strip across the top of `area`; no height when `area` is shorter.
pub fn strip(area: Rect) Rect {
    const h: i32 = if (area.h >= strip_h) strip_h else 0;
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = h };
}

/// The save tab at the strip's right end; empty when the strip is too
/// short or too narrow to hold it.
pub fn saveTab(area: Rect) Rect {
    const row = strip(area);
    const w: i32 = if (row.h > 0 and row.w >= tab_w) tab_w else 0;
    return .{ .x = row.x + row.w - w, .y = row.y, .w = w, .h = if (w > 0) row.h else 0 };
}

/// What is left of `area` under the strip, for the log.
pub fn below(area: Rect) Rect {
    const top = strip(area).h;
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = area.h - top };
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, outcome: console_save.Outcome) !void {
    const row = strip(area);
    if (row.h == 0) return;
    try list.fill(row, theme.face);
    const tab = saveTab(area);
    if (tab.w == 0) return;
    try list.fill(tab, theme.button_face);
    const ink = if (outcome == .failed) theme.bad else theme.ink;
    try font.draw(list, tab.x + console_pane.pad, tab.y + console_pane.pad, outcome.label(), ink);
}
