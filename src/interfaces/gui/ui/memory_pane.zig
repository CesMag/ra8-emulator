//! The memory pane (RA8EMU-746): a hex dump of one core's memory, Ozone
//! style. Each row is an eight-digit address, sixteen bytes in hex with a
//! gap after the eighth, then the same bytes as ASCII. A byte the session
//! cannot read draws as "??" in the hex and '?' in the ASCII, both muted.
//!
//! gui/memory_capture.zig fills a Snapshot from the session at a base
//! address; `draw` reads only the snapshot, so the shell scrolls by
//! capturing again at a new base. The pane never imports the session.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;
const widget_paint = @import("ra8_render").widget_paint;
const widget = @import("ra8_widget");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const per_row: usize = 16;
/// The most rows one snapshot holds: more than any pane shows at once.
pub const max_rows: usize = 64;
/// Characters before the hex: eight address digits and a gap.
pub const hex_at: usize = 10;
/// Characters before the ASCII: the hex bytes, the gap after the eighth
/// byte, and two more.
pub const ascii_at: usize = hex_at + per_row * 3 + 2;
pub const row_len: usize = ascii_at + per_row;
/// The narrowest pane that holds a whole row.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(row_len)));

const cells = max_rows * per_row;

pub const Snapshot = struct {
    base: u32 = 0,
    /// Rows captured, from `base` up.
    count: usize = 0,
    bytes: [cells]u8 = @splat(0),
    readable: [cells]bool = @splat(false),

    pub fn rowAddress(self: *const Snapshot, row: usize) u32 {
        return self.base +% @as(u32, @intCast(row * per_row));
    }
};

/// How many rows fit down `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// The character column byte `index` of a row starts at.
pub fn hexColumn(index: usize) usize {
    return hex_at + index * 3 + @intFromBool(index >= per_row / 2);
}

/// Where row `row`'s text starts.
pub fn rowOrigin(area: Rect, row: usize) struct { x: i32, y: i32 } {
    return .{ .x = area.x + pad + 2, .y = area.y + pad + 2 + @as(i32, @intCast(row)) * row_h };
}

/// Draw the pane through the shared Paint table (RA8EMU-1159): the
/// background fill dispatches through the table and the text is the
/// firmware's label widget, so no pane code emits raw glyph commands.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, snapshot: *const Snapshot) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.pushClip(area);
    defer list.popClip();
    var target = widget_paint.Target{ .list = list };
    const paint = target.paint();
    fillArea(&paint, area, word(theme.background));
    for (0..@min(rows(area), snapshot.count)) |row| drawRow(&paint, theme, area, snapshot, row);
}

fn drawRow(table: *const widget.types.Paint, theme: *const Theme, area: Rect, snapshot: *const Snapshot, row: usize) void {
    const at = rowOrigin(area, row);
    var buffer: [8]u8 = undefined;
    const addr = std.fmt.bufPrint(&buffer, "{X:0>8}", .{snapshot.rowAddress(row)}) catch return;
    drawText(table, at.x, at.y, addr, word(theme.muted), word(theme.background));
    for (0..per_row) |index| {
        const cell = row * per_row + index;
        drawByte(table, theme, at.x, at.y, index, snapshot.bytes[cell], snapshot.readable[cell]);
    }
}

fn drawByte(table: *const widget.types.Paint, theme: *const Theme, x: i32, y: i32, index: usize, byte: u8, readable: bool) void {
    const bg = word(theme.background);
    const hex_x = x + column(hexColumn(index));
    const ascii_x = x + column(ascii_at + index);
    if (!readable) {
        drawText(table, hex_x, y, "??", word(theme.muted), bg);
        return drawText(table, ascii_x, y, "?", word(theme.muted), bg);
    }
    var buffer: [2]u8 = undefined;
    const hex = std.fmt.bufPrint(&buffer, "{X:0>2}", .{byte}) catch return;
    drawText(table, hex_x, y, hex, word(theme.ink), bg);
    const printable = byte >= 0x21 and byte < 0x7F;
    const shown = [1]u8{if (printable) byte else '.'};
    drawText(table, ascii_x, y, &shown, word(if (printable) theme.ink else theme.muted), bg);
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}

/// One line of text as the firmware's label widget (RA8EMU-1159): the label
/// owns the face and the aligned rendering; the rect is this line's cell.
fn drawText(table: *const widget.types.Paint, x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var buffer: [64]u8 = undefined;
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
