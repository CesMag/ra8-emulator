//! The shell frame (RA8EMU-764): the docked window chrome drawn from the
//! pane layout (RA8EMU-754). Each leaf gets a title bar naming its pane and
//! the core it is bound to, the splitters show as gutters, and the time bar
//! (RA8EMU-807) and the status strip (RA8EMU-759) run along the bottom. What
//! goes inside a leaf comes from a painter, so the window loop fills it and a
//! test can leave it bare.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const pane_layout = @import("pane_layout.zig");
const status_strip = @import("status_strip.zig");
const time_bar = @import("time_bar.zig");
const colors = @import("colors.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Pane = pane_layout.Pane;
const Layout = pane_layout.Layout;
const Solved = pane_layout.Solved;

pub const background = colors.background;
pub const title_fill = colors.face;
pub const gutter_fill = colors.gutter;
pub const ink = status_strip.ink;
pub const muted = colors.muted;
pub const pad: i32 = 4;
pub const title_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;

/// Fills one leaf's body. The frame has already cleared it and clipped to it.
pub const Painter = struct {
    context: *anyopaque,
    paint: *const fn (context: *anyopaque, list: *draw_list.DrawList, pane: Pane, body: Rect) anyerror!void,
};

/// Everything one frame of the shell shows.
pub const Shell = struct {
    layout: *const Layout,
    solved: *const Solved,
    /// The status strip's view, from gui/status_capture.zig.
    strip: status_strip.Strip,
    /// The time bar's view, from gui/shell_time.zig; a bare frame draws it
    /// with nothing lit.
    bar: time_bar.View = .{},
    width: i32,
    height: i32,
    painter: ?Painter = null,
};

pub fn kindName(kind: pane_layout.Kind) []const u8 {
    return switch (kind) {
        .empty => "Empty",
        .board => "Board",
        .console => "Console",
        .camera => "Camera",
        .devices => "Devices",
        .registers => "Registers",
        .memory => "Memory",
        .disasm => "Disassembly",
    };
}

pub fn coreName(core: pane_layout.Core) []const u8 {
    return switch (core) {
        .cpu0 => "CPU0",
        .cpu1 => "CPU1",
    };
}

/// The panes' share of the window: everything above the time bar and the
/// status strip.
pub fn panesArea(width: i32, height: i32) Rect {
    return .{ .x = 0, .y = 0, .w = width, .h = @max(0, height - status_strip.height - time_bar.height) };
}

/// The time bar's row, on top of the status strip.
pub fn barArea(width: i32, height: i32) Rect {
    return .{ .x = 0, .y = height - status_strip.height - time_bar.height, .w = width, .h = time_bar.height };
}

pub fn titleOf(area: Rect) Rect {
    return .{ .x = area.x, .y = area.y, .w = area.w, .h = @min(title_h, area.h) };
}

pub fn bodyOf(area: Rect) Rect {
    const top = @min(title_h, area.h);
    return .{ .x = area.x, .y = area.y + top, .w = area.w, .h = area.h - top };
}

/// Lays the panes out for a window of `width` by `height` pixels.
pub fn solve(layout: *const Layout, allocator: std.mem.Allocator, width: i32, height: i32) !Solved {
    return layout.solve(allocator, panesArea(width, height));
}

pub fn draw(list: *draw_list.DrawList, shell: Shell) !void {
    for (shell.solved.gutters.items) |found| try list.fill(found.area, gutter_fill);
    for (shell.solved.panes.items) |placed| {
        const pane = shell.layout.pane(placed.index) orelse continue;
        try drawLeaf(list, pane, placed.area, shell.painter);
    }
    try time_bar.draw(list, barArea(shell.width, shell.height), shell.bar);
    const strip = status_strip.area(shell.width, shell.height);
    try status_strip.draw(list, strip, &shell.strip);
}

fn drawLeaf(list: *draw_list.DrawList, pane: Pane, area: Rect, painter: ?Painter) !void {
    if (area.empty()) return;
    try list.pushClip(area);
    defer list.popClip();
    try list.fill(area, background);
    const title = titleOf(area);
    try list.fill(title, title_fill);
    const top = title.y + @divTrunc(title.h - @as(i32, font.glyph_h), 2);
    const core = coreName(pane.core);
    const core_w: i32 = @intCast(font.textWidth(core.len));
    const room = title.w - 2 * pad;
    if (room > 0) try font.draw(list, title.x + pad, top, font.fit(kindName(pane.kind), @intCast(room)), ink);
    const name_w: i32 = @intCast(font.textWidth(kindName(pane.kind).len));
    if (room >= name_w + pad + core_w) try font.draw(list, title.x + title.w - pad - core_w, top, core, muted);
    const p = painter orelse return;
    const body = bodyOf(area);
    if (body.empty()) return;
    try list.pushClip(body);
    defer list.popClip();
    try p.paint(p.context, list, pane, body);
}
