//! The source pane (RA8EMU-745): the source lines around the line a core's
//! pc belongs to, read through the image's DWARF line table. Each row is a
//! gutter (a red square on a breakpoint, an amber '>' at the current line),
//! the line number and the text; the current line sits on a full-width band.
//! A click in the gutter sets or clears a breakpoint on that line.
//!
//! gui/source_capture.zig fills a Snapshot and sets or clears the gutter's
//! breakpoints through the session; this pane never imports the session.
//! Until the session can list a core's breakpoints (RA8EMU-765), `Marks`
//! remembers the ones this gutter set, with the ids that clear them.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const colors = @import("colors.zig");

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const background = colors.background;
pub const muted = colors.muted;
pub const ink = colors.ink;
pub const current_band = colors.band;
pub const current_ink = colors.highlight;
pub const break_mark = colors.bad;
pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const max_rows: usize = 48;
/// Characters of a source line a row keeps.
pub const text_cap: usize = 120;
pub const path_cap: usize = 256;
pub const max_marks: usize = 32;
/// Character columns: the gutter, the line number, the text.
pub const number_at: usize = 2;
pub const number_len: usize = 5;
pub const text_at: usize = number_at + number_len + 1;
/// The narrowest pane: the columns before the text and room for 16 more.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(text_at + 16)));

pub const Row = struct {
    number: u32 = 0,
    buf: [text_cap]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Row) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const State = enum { no_line, no_file, shown };

pub const Snapshot = struct {
    pc: u32 = 0,
    state: State = .no_line,
    path_buf: [path_cap]u8 = undefined,
    path_len: usize = 0,
    /// The line pc belongs to.
    current: u32 = 0,
    count: usize = 0,
    rows: [max_rows]Row = @splat(.{}),

    pub fn path(self: *const Snapshot) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// A breakpoint the gutter set: its file (hashed) and line, and the
/// session's id that clears it. gui/source_capture.zig checks at comptime
/// that the session's breakpoint id is a u32.
pub const Mark = struct {
    file: u64,
    line: u32,
    id: u32,
};

/// The breakpoints this gutter set on one core.
pub const Marks = struct {
    items: [max_marks]Mark = undefined,
    len: usize = 0,

    pub fn find(self: *const Marks, file: []const u8, line: u32) ?usize {
        const key = std.hash.Fnv1a_64.hash(file);
        for (self.items[0..self.len], 0..) |mark, index| {
            if (mark.file == key and mark.line == line) return index;
        }
        return null;
    }
};

/// The line under a click at (`x`, `y`) when it lands in the gutter of a
/// shown row.
pub fn lineAt(area: Rect, snapshot: *const Snapshot, x: i32, y: i32) ?u32 {
    if (snapshot.state != .shown) return null;
    if (x < area.x or x >= area.x + pad + 2 + column(number_at)) return null;
    const top = area.y + pad;
    if (y < top) return null;
    const row: usize = @intCast(@divTrunc(y - top, row_h));
    if (row >= @min(rows(area), snapshot.count)) return null;
    return snapshot.rows[row].number;
}

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

/// The breakpoint square in row `row`'s gutter.
pub fn markRect(area: Rect, row: usize) Rect {
    const band = rowRect(area, row);
    return .{ .x = area.x + pad + 2, .y = band.y + 3, .w = font.glyph_w, .h = row_h - 6 };
}

pub fn draw(list: *draw_list.DrawList, area: Rect, snapshot: *const Snapshot, marks: *const Marks) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.fill(area, background);
    try list.pushClip(area);
    defer list.popClip();
    var message: [path_cap + 32]u8 = undefined;
    switch (snapshot.state) {
        .no_line => return drawText(list, area, 0, text_at, try std.fmt.bufPrint(&message, "No line information for 0x{X:0>8}", .{snapshot.pc}), muted),
        .no_file => return drawText(list, area, 0, text_at, try std.fmt.bufPrint(&message, "{s}: No such file", .{snapshot.path()}), muted),
        .shown => {},
    }
    for (0..@min(rows(area), snapshot.count)) |row| {
        const line = &snapshot.rows[row];
        const current = line.number == snapshot.current;
        if (current) try list.fill(rowRect(area, row), current_band);
        if (marks.find(snapshot.path(), line.number) != null) try list.fill(markRect(area, row), break_mark);
        if (current) try drawText(list, area, row, 1, ">", current_ink);
        var number: [number_len]u8 = undefined;
        try drawText(list, area, row, number_at, try std.fmt.bufPrint(&number, "{d: >5}", .{line.number}), if (current) current_ink else muted);
        try drawText(list, area, row, text_at, line.text(), ink);
    }
}

fn drawText(list: *draw_list.DrawList, area: Rect, row: usize, at: usize, text: []const u8, color: Color) !void {
    const x = area.x + pad + 2 + column(at);
    const room: u32 = @intCast(@max(area.x + area.w - pad - x, 0));
    try font.draw(list, x, rowRect(area, row).y + 2, font.fit(text, room), color);
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}
