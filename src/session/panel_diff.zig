//! What changed between two pictures of one panel (RA8EMU-1126): the
//! smallest box that holds every pixel whose colour differs. The pictures
//! are ARGB words as the GLCDC's output stage captures them; the alpha byte
//! is not part of what a panel shows and is not compared.
const std = @import("std");

pub const Rect = @import("session_event_stream.zig").Event.Rect;

const colour: u32 = 0x00FF_FFFF;

/// The whole of a `width` by `height` panel.
pub fn whole(width: u32, height: u32) Rect {
    return .{ .x = 0, .y = 0, .width = narrow(width), .height = narrow(height) };
}

/// The box of what differs between `before` and `after`, two pictures
/// `width` pixels wide and of one length, or null when they show the same.
pub fn box(before: []const u32, after: []const u32, width: u32) ?Rect {
    if (width == 0 or before.len != after.len) return null;
    const rows = before.len / width;
    var top: usize = 0;
    while (top < rows and firstDiff(before, after, width, top) == null) top += 1;
    if (top == rows) return null;
    var bottom = rows - 1;
    while (firstDiff(before, after, width, bottom) == null) bottom -= 1;
    var left: usize = width;
    var right: usize = 0;
    for (top..bottom + 1) |row| {
        const first = firstDiff(before, after, width, row) orelse continue;
        left = @min(left, first);
        right = @max(right, lastDiff(before, after, width, row));
    }
    return .{ .x = narrow(left), .y = narrow(top), .width = narrow(right - left + 1), .height = narrow(bottom - top + 1) };
}

fn differs(a: u32, b: u32) bool {
    return (a ^ b) & colour != 0;
}

/// The first column of `row` that differs, or null when the row is the same.
fn firstDiff(before: []const u32, after: []const u32, width: u32, row: usize) ?usize {
    const from = row * width;
    for (before[from..][0..width], after[from..][0..width], 0..) |a, b, column| {
        if (differs(a, b)) return column;
    }
    return null;
}

/// The last column of `row` that differs; the row is known to differ.
fn lastDiff(before: []const u32, after: []const u32, width: u32, row: usize) usize {
    const from = row * width;
    var column: usize = width - 1;
    while (!differs(before[from + column], after[from + column])) column -= 1;
    return column;
}

fn narrow(value: usize) u16 {
    return @intCast(@min(value, std.math.maxInt(u16)));
}
