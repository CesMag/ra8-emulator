//! The flame graph pane (RA8EMU-835): one row of boxes per stack depth
//! under the model's zoom root, the root on top. A box's width is its
//! total's share of its parent's box (gui/flame/model.zig owns the edges).
//! A box's colour comes from an FNV-1a hash of its name over the theme's
//! hues, so a function keeps its colour between refreshes and zooms. The
//! hovered box sits on the highlight, and the bottom line reads its name,
//! total, share of the window and self. The pane never imports the session.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;
const flame_model = @import("../flame/model.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Model = flame_model.Model;

pub const pad: i32 = 4;
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
/// The label the tree's unnamed root box carries.
pub const root_label = "all";
/// A box narrower than three characters gets no label.
pub const label_min: i32 = @intCast(font.textWidth(3));
/// The narrowest pane: room for a tip line of 24 characters.
pub const min_w: i32 = 2 * pad + @as(i32, @intCast(font.textWidth(24)));

/// How many box rows fit down `area`, above the tip line.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad - row_h;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// The pixels a span of `width` is measured over.
pub fn width(area: Rect) i32 {
    return area.w - 2 * pad;
}

/// The box for a span on drawn row `depth`.
pub fn boxRect(area: Rect, depth: u32, span: flame_model.Span) Rect {
    const top = area.y + pad + @as(i32, @intCast(depth)) * row_h;
    return .{ .x = area.x + pad + span.x, .y = top, .w = span.w, .h = row_h - 1 };
}

/// The tip line under the rows.
pub fn tipRect(area: Rect) Rect {
    return .{ .x = area.x + pad, .y = area.y + area.h - pad - row_h, .w = width(area), .h = row_h };
}

/// The node under (x, y), or null for an empty spot or the tip line.
pub fn nodeAt(area: Rect, model: *const Model, x: i32, y: i32) ?u32 {
    if (y < area.y + pad) return null;
    const depth: usize = @intCast(@divTrunc(y - area.y - pad, row_h));
    if (depth >= rows(area)) return null;
    return model.hit(x - area.x - pad, @intCast(depth), width(area));
}

/// The colour a box called `called` is filled with.
pub fn hue(theme: *const Theme, called: []const u8) Color {
    const hues = [_]Color{ theme.hue.blue, theme.hue.purple, theme.hue.green, theme.hue.yellow, theme.hue.red };
    return hues[std.hash.Fnv1a_32.hash(called) % hues.len];
}

/// The name a node's box and tip show.
pub fn label(model: *const Model, node: u32) []const u8 {
    return if (node == 0) root_label else model.name(node);
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, model: *const Model, hover: ?u32) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.fill(area, theme.background);
    try list.pushClip(area);
    defer list.popClip();
    for (0..model.nodes.items.len) |index| {
        const node: u32 = @intCast(index);
        const depth = model.row(node) orelse continue;
        if (depth >= rows(area)) continue;
        const span = model.span(node, width(area)) orelse continue;
        if (span.w <= 0) continue;
        try drawBox(list, theme, boxRect(area, depth, span), label(model, node), hover == node);
    }
    if (hover) |node| try drawTip(list, theme, area, model, node);
}

fn drawBox(list: *draw_list.DrawList, theme: *const Theme, box: Rect, called: []const u8, hovered: bool) !void {
    const inner: Rect = .{ .x = box.x, .y = box.y, .w = @max(box.w - 1, 1), .h = box.h };
    try list.fill(inner, if (hovered) theme.highlight else hue(theme, called));
    if (box.w < label_min) return;
    const room: u32 = @intCast(box.w - 4);
    try font.draw(list, box.x + 2, box.y + 2, font.fit(called, room), theme.background);
}

fn drawTip(list: *draw_list.DrawList, theme: *const Theme, area: Rect, model: *const Model, node: u32) !void {
    if (node >= model.nodes.items.len or model.row(node) == null) return;
    const at = model.get(node);
    const window = @max(model.window(), 1);
    var text: [160]u8 = undefined;
    const line = try std.fmt.bufPrint(&text, "{s}  total {d} ({d}%)  self {d}", .{ label(model, node), at.total, at.total * 100 / window, at.self });
    const tip = tipRect(area);
    try font.draw(list, tip.x, tip.y + 2, font.fit(line, @intCast(tip.w)), theme.ink);
}
