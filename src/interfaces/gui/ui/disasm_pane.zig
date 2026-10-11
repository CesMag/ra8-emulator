//! The disassembly pane (RA8EMU-743): instructions decoded forward from a
//! start address, RAD Debugger style. Each row is a gutter (a red square on
//! a breakpoint, an amber '>' at pc), the address, the instruction's
//! halfwords and its text. The pc row sits on a full-width band.
//!
//! gui/disasm_capture.zig fills a Snapshot, from the session or from bytes
//! the shell read over the session link. `draw` reads only the snapshot and
//! the breakpoint addresses it is handed, and the pane never imports the
//! session.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
pub const max_rows: usize = 64;
/// Characters of instruction text a line keeps.
pub const text_cap: usize = 48;
/// Character columns: the gutter, the address, the halfwords, the text.
pub const address_at: usize = 2;
pub const bytes_at: usize = address_at + 8 + 2;
pub const text_at: usize = bytes_at + 9 + 2;
/// The narrowest pane: the columns before the text and room for 16 more.
pub const min_w: i32 = 2 * pad + 2 + @as(i32, @intCast(font.textWidth(text_at + 16)));

pub const Line = struct {
    address: u32 = 0,
    /// 2 or 4 bytes; 0 when the instruction could not be read.
    size: u8 = 0,
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    decoded: bool = false,
    text_buf: [text_cap]u8 = undefined,
    text_len: usize = 0,

    pub fn text(self: *const Line) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn setText(self: *Line, from: []const u8) void {
        self.text_len = @min(from.len, text_cap);
        @memcpy(self.text_buf[0..self.text_len], from[0..self.text_len]);
    }
};

pub const Snapshot = struct {
    pc: u32 = 0,
    count: usize = 0,
    lines: [max_rows]Line = @splat(.{}),
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

/// The breakpoint square in row `row`'s gutter.
pub fn markRect(area: Rect, row: usize) Rect {
    const band = rowRect(area, row);
    return .{ .x = area.x + pad + 2, .y = band.y + 3, .w = font.glyph_w, .h = row_h - 6 };
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, snapshot: *const Snapshot, breaks: []const u32) !void {
    if (area.w < min_w or rows(area) == 0) return;
    try list.fill(area, theme.background);
    try list.pushClip(area);
    defer list.popClip();
    for (0..@min(rows(area), snapshot.count)) |row| {
        const line = &snapshot.lines[row];
        const at_pc = line.address == snapshot.pc;
        if (at_pc) {
            const band = rowRect(area, row);
            try list.fill(band, theme.pc_band_bg);
            try list.fill(.{ .x = band.x, .y = band.y, .w = 2, .h = band.h }, theme.pc_cyan);
        }
        if (std.mem.indexOfScalar(u32, breaks, line.address) != null) try list.fill(markRect(area, row), theme.breakpoint);
        try drawLine(list, theme, area, row, line, at_pc);
    }
}

fn drawLine(list: *draw_list.DrawList, theme: *const Theme, area: Rect, row: usize, line: *const Line, at_pc: bool) !void {
    const x = area.x + pad + 2;
    const y = rowRect(area, row).y + 2;
    if (at_pc) try font.draw(list, x + column(1), y, ">", theme.pc_cyan);
    var address: [8]u8 = undefined;
    try font.draw(list, x + column(address_at), y, try std.fmt.bufPrint(&address, "{X:0>8}", .{line.address}), if (at_pc) theme.pc_cyan else theme.muted);
    var halves: [9]u8 = undefined;
    try font.draw(list, x + column(bytes_at), y, try halfwords(&halves, line), theme.muted);
    const shown = if (line.decoded) line.text() else if (line.size == 0) "<unreadable>" else "<undecoded>";
    const text_x = x + column(text_at);
    const room: u32 = @intCast(@max(area.x + area.w - pad - text_x, 0));
    try font.draw(list, text_x, y, font.fit(shown, room), if (line.decoded) theme.ink else theme.muted);
}

fn halfwords(buffer: *[9]u8, line: *const Line) ![]const u8 {
    const first = std.mem.readInt(u16, line.bytes[0..2], .little);
    const second = std.mem.readInt(u16, line.bytes[2..4], .little);
    return switch (line.size) {
        2 => std.fmt.bufPrint(buffer, "{x:0>4}", .{first}),
        4 => std.fmt.bufPrint(buffer, "{x:0>4} {x:0>4}", .{ first, second }),
        else => "????",
    };
}

fn column(chars: usize) i32 {
    return @intCast(font.textWidth(chars));
}
