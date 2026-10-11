//! The peripheral register pane (RA8EMU-819): the bus's blocks down the
//! left column, the selected block's registers on the right, each with its
//! name, offset, and the live value at the register's width. A value that
//! differs from the snapshot taken before the last stop draws in
//! `highlight`, the registers pane's (RA8EMU-741) mark.
//!
//! The pane never imports the session: gui/periph_capture.zig fills a
//! Snapshot, and draw reads only the snapshot, so the shell redraws
//! without touching a core.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;

const Rect = draw_list.Rect;

pub const pad: i32 = 4;
/// A row is one text line with a pixel of air above and below.
pub const row_h: i32 = @as(i32, @intCast(font.cell_h)) + 4;
/// Blocks the pane can hold; a board maps at most this many.
pub const max_blocks = 16;
/// Registers the pane can hold for one block.
pub const max_registers = 32;
/// Air between the columns, in characters.
const gap: usize = 2;
/// Characters "0x00" takes.
const offset_len: usize = 4;
/// Characters an eight-digit value takes.
const value_len: usize = 8;

pub const Block = struct { name: []const u8, base: u32, size: u32 };
pub const Reg = struct { name: []const u8, offset: u32, width: u8 };

pub const Snapshot = struct {
    blocks: [max_blocks]Block = undefined,
    block_count: usize = 0,
    /// The block whose registers the right side shows.
    selected: usize = 0,
    regs: [max_registers]Reg = undefined,
    reg_count: usize = 0,
    values: [max_registers]u32 = @splat(0),
    /// True where the bus answered the read; a refused register shows no value.
    readable: [max_registers]bool = @splat(false),

    /// Did register `index` change since `before`? Nothing has changed
    /// when there is no earlier snapshot.
    pub fn changedAt(self: *const Snapshot, before: ?*const Snapshot, index: usize) bool {
        const old = before orelse return false;
        if (index >= self.reg_count or index >= old.reg_count) return false;
        return old.values[index] != self.values[index];
    }
};

/// How many rows fit down `area`.
pub fn rows(area: Rect) usize {
    const inner = area.h - 2 * pad;
    if (inner < row_h) return 0;
    return @intCast(@divTrunc(inner, row_h));
}

/// The left column's width: the longest block name plus air.
pub fn blockWidth(snap: *const Snapshot) i32 {
    var widest: usize = 0;
    for (snap.blocks[0..snap.block_count]) |block| widest = @max(widest, font.textWidth(block.name.len));
    return @intCast(widest + 2 * 2);
}

/// Block `index`'s row, or null when it does not fit.
pub fn blockRect(area: Rect, snap: *const Snapshot, index: usize) ?Rect {
    if (@as(i32, @intCast(index)) >= @as(i32, @intCast(rows(area))) or index >= snap.block_count) return null;
    return .{
        .x = area.x + pad,
        .y = area.y + pad + @as(i32, @intCast(index)) * row_h,
        .w = blockWidth(snap),
        .h = row_h,
    };
}

/// Register `index`'s row, or null when it does not fit.
pub fn regRect(area: Rect, snap: *const Snapshot, index: usize) ?Rect {
    if (@as(i32, @intCast(index)) >= @as(i32, @intCast(rows(area))) or index >= snap.reg_count) return null;
    const w = @as(i32, @intCast(2)) + nameWidth(snap) + gapWidth() + offsetWidth() + gapWidth() + valueWidth() + 2;
    const x = area.x + pad + blockWidth(snap) + gapWidth();
    if (x + w > area.x + area.w - pad) return null;
    return .{ .x = x, .y = area.y + pad + @as(i32, @intCast(index)) * row_h, .w = w, .h = row_h };
}

fn nameWidth(snap: *const Snapshot) i32 {
    var widest: usize = 0;
    for (snap.regs[0..snap.reg_count]) |reg| widest = @max(widest, font.textWidth(reg.name.len));
    return @intCast(widest);
}

fn gapWidth() i32 {
    return @intCast(font.textWidth(gap));
}

fn offsetWidth() i32 {
    return @intCast(font.textWidth(offset_len));
}

fn valueWidth() i32 {
    return @intCast(font.textWidth(value_len));
}

/// The block whose row holds (`x`, `y`), or null.
pub fn hit(area: Rect, snap: *const Snapshot, x: i32, y: i32) ?usize {
    for (0..snap.block_count) |index| {
        const rect = blockRect(area, snap, index) orelse return null;
        if (rect.contains(x, y)) return index;
    }
    return null;
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, area: Rect, now: *const Snapshot, before: ?*const Snapshot) !void {
    if (rows(area) == 0) return;
    try list.fill(area, theme.background);
    try list.pushClip(area);
    defer list.popClip();
    for (0..now.block_count) |index| {
        const rect = blockRect(area, now, index) orelse break;
        const picked = index == now.selected;
        if (picked) try list.fill(rect, theme.pc_band_bg);
        try font.draw(list, rect.x + 2, rect.y + 2, now.blocks[index].name, if (picked) theme.pc_cyan else theme.muted);
    }
    for (0..now.reg_count) |index| {
        const rect = regRect(area, now, index) orelse break;
        const reg = now.regs[index];
        const moved = now.readable[index] and now.changedAt(before, index);
        if (moved) try list.fill(rect, theme.dirty_cell_bg);
        try font.draw(list, rect.x + 2, rect.y + 2, reg.name, theme.muted);
        var offset_buffer: [10]u8 = undefined;
        const offset_text = try std.fmt.bufPrint(&offset_buffer, "0x{X:0>2}", .{reg.offset});
        try font.draw(list, rect.x + 2 + nameWidth(now) + gapWidth(), rect.y + 2, offset_text, theme.muted);
        var value_buffer: [8]u8 = undefined;
        const text = if (now.readable[index]) valueText(&value_buffer, now.values[index], reg.width) else "--------";
        const at = rect.x + 2 + nameWidth(now) + gapWidth() + offsetWidth() + gapWidth();
        try font.draw(list, at, rect.y + 2, text, if (moved) theme.highlight else theme.ink);
    }
}

/// The value at `width`'s digits; an undeclared width (0) shows a full word.
fn valueText(buffer: *[8]u8, value: u32, width: u8) []const u8 {
    return switch (width) {
        1 => std.fmt.bufPrint(buffer, "{X:0>2}", .{@as(u8, @truncate(value))}) catch buffer[0..0],
        2 => std.fmt.bufPrint(buffer, "{X:0>4}", .{@as(u16, @truncate(value))}) catch buffer[0..0],
        else => std.fmt.bufPrint(buffer, "{X:0>8}", .{value}) catch buffer[0..0],
    };
}
