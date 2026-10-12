//! The call stack pane (RA8EMU-744): one row per frame of a core's call
//! chain, innermost first, walked with the image's .debug_frame the way
//! `backtrace` is (session/report.zig). Each row is the frame number, the
//! pc, the function with its offset, and FILE:LINE when the line table has
//! it. The innermost frame is amber; the shell's selected frame sits on a
//! band. A frame an exception interrupted carries a muted '~' in its gutter.
//!
//! The session walks the chain (src/interfaces/rpc/session/backtrace.zig) and
//! gui/shell/stack.zig copies names into the snapshot, so `draw` holds no
//! slice into the link's buffer and the shell keeps a snapshot past a reload.
//! The pane never imports the session.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;
const widget_paint = @import("ra8_render").widget_paint;
const widget = @import("ra8_widget");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
/// The most frames a backtrace walks; gui/shell/stack.zig checks it
/// against the wire's limit at comptime.
pub const max_frames: usize = 32;
/// Characters a function name and a file name keep.
pub const name_cap: usize = 40;
pub const file_cap: usize = 32;
/// Character columns: the gutter, the number, the pc, the function.
pub const number_at: usize = 2;
pub const pc_at: usize = number_at + 3 + 1;
pub const name_at: usize = pc_at + 8 + 2;
/// The narrowest pane: the columns before the name and room for 8 more.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(name_at + 8)));

pub const Frame = struct {
    pc: u32 = 0,
    /// An exception sits between this frame and the one inside it.
    interrupted: bool = false,
    offset: u32 = 0,
    name_buf: [name_cap]u8 = undefined,
    name_len: usize = 0,
    file_buf: [file_cap]u8 = undefined,
    file_len: usize = 0,
    /// 0 when the line table does not cover the frame.
    line: u32 = 0,

    pub fn name(self: *const Frame) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn file(self: *const Frame) []const u8 {
        return self.file_buf[0..self.file_len];
    }
};

pub const Snapshot = struct {
    count: usize = 0,
    frames: [max_frames]Frame = @splat(.{}),
};

/// How many rows fit down `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// Row `row`'s full-width band.
pub fn rowRect(area: Rect, row: usize) Rect {
    return .{ .x = area.x, .y = area.y + pad + @as(i32, @intCast(row)) * row_h, .w = area.w, .h = row_h };
}

/// The frame under a click at `y`, or null outside the rows.
pub fn frameAt(area: Rect, snapshot: *const Snapshot, y: i32) ?usize {
    if (y < area.y + pad) return null;
    const row: usize = @intCast(@divTrunc(y - area.y - pad, row_h));
    if (row >= @min(rows(area), snapshot.count)) return null;
    return row;
}

/// Draw the pane through the shared Paint table (RA8EMU-1159): the
/// background and the selected-frame band fill dispatch through the table,
/// and the text is the firmware's label widget, so no pane code emits raw
/// glyph commands.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, snapshot: *const Snapshot, selected: usize) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.pushClip(area);
    defer list.popClip();
    var target = widget_paint.Target{ .list = list };
    const paint = target.paint();
    fillArea(&paint, area, word(theme.background));
    for (0..@min(rows(area), snapshot.count)) |row| {
        if (row == selected) fillArea(&paint, rowRect(area, row), word(theme.band));
        drawFrame(&paint, theme, area, row, &snapshot.frames[row], row == selected);
    }
}

fn drawFrame(table: *const widget.types.Paint, theme: *const Theme, area: Rect, row: usize, frame: *const Frame, on_band: bool) void {
    const x = area.x + pad + 2;
    const y = rowRect(area, row).y + 2;
    const bg = word(if (on_band) theme.band else theme.background);
    const lead = if (row == 0) theme.highlight else theme.muted;
    if (frame.interrupted) drawText(table, x, y, "~", word(theme.muted), bg);
    var number: [4]u8 = undefined;
    const num = std.fmt.bufPrint(&number, "#{d}", .{row}) catch return;
    drawText(table, x + column(number_at), y, num, word(lead), bg);
    var pc: [8]u8 = undefined;
    const pc_text = std.fmt.bufPrint(&pc, "{X:0>8}", .{frame.pc}) catch return;
    drawText(table, x + column(pc_at), y, pc_text, word(lead), bg);
    var text: [name_cap + file_cap + 24]u8 = undefined;
    const name_x = x + column(name_at);
    const room: u32 = @intCast(@max(area.x + area.w - pad - name_x, 0));
    const called = frameLabel(&text, frame);
    drawText(table, name_x, y, font.fit(called, room), word(if (frame.name_len == 0) theme.muted else if (row == 0) theme.highlight else theme.ink), bg);
    const used = font.textWidth(called.len + 1);
    if (frame.line == 0 or used >= room) return;
    var where: [file_cap + 12]u8 = undefined;
    const at = std.fmt.bufPrint(&where, "{s}:{d}", .{ frame.file(), frame.line }) catch return;
    drawText(table, name_x + @as(i32, @intCast(used)), y, font.fit(at, room - used), word(theme.muted), bg);
}

fn frameLabel(buffer: []u8, frame: *const Frame) []const u8 {
    if (frame.name_len == 0) return std.fmt.bufPrint(buffer, "??", .{}) catch "";
    if (frame.offset == 0) return std.fmt.bufPrint(buffer, "{s}", .{frame.name()}) catch "";
    return std.fmt.bufPrint(buffer, "{s}+{d}", .{ frame.name(), frame.offset }) catch "";
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}

/// One line of text as the firmware's label widget (RA8EMU-1159): the label
/// owns the face and the aligned rendering; the rect is this line's cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [128]u8 = undefined;
    const n = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..n], text[0..n]);
    buffer[n] = 0;
    var descriptor = widget.label.Label{
        .paint = table,
        .text = buffer[0..n :0].ptr,
        .fg = fg,
        .bg = bg,
        .pad = 0,
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{
        .x = x,
        .y = y,
        .w = @intCast(font.textWidth(text.len)),
        .h = @intCast(font.cell_h),
    };
    w.vt.?.render.?(&w);
}

/// `area` filled with `color` through the shared Paint table.
fn fillArea(table: *const widget.types.Paint, area: Rect, color: u32) void {
    table.fill_rect.?(table.user, area.x, area.y, area.w, area.h, color);
}

/// `color` as the widget's 0x00RRGGBB colour word.
fn word(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
