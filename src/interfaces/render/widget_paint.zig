//! Paints ra8-firmware widgets into the GUI draw list (RA8EMU-719).
//!
//! The firmware widgets draw through a `Paint` table of C-callconv callbacks.
//! `Target` fills that table with callbacks that append to a draw list, so the
//! same label, button or list the board renders lands in raster.zig here.
//! Text goes through our own 6x8 cell font; the widget's background fill is
//! its own `fill_rect`, so `draw_text` ignores `bg`.

const std = @import("std");
const widget = @import("ra8_widget");
const draw_list = @import("draw_list.zig");
const font = @import("gfx_font.zig");

const log = std.log.scoped(.widget);

// The widgets reach box layout, UI rect and widget core symbols through
// `extern fn`; the firmware's host package exports them from Zig.
comptime {
    _ = @import("ra8_widget_host");
}

/// Firmware widgets report misuse through this symbol; on the host it is a
/// warning in our log rather than the board's UART.
export fn ra8_log_emit_error(tag: [*:0]const u8, message: [*:0]const u8) void {
    log.warn("{s}: {s}", .{ std.mem.span(tag), std.mem.span(message) });
}

/// One widget paint pass into `list`. A callback cannot return an error
/// through the C ABI, so an append that runs out of memory sets `failed`.
pub const Target = struct {
    list: *draw_list.DrawList,
    failed: bool = false,

    pub fn paint(self: *Target) widget.types.Paint {
        return .{ .user = self, .fill_rect = fillRect, .draw_text = drawText, .text_size = textSize };
    }
};

/// 0x00RRGGBB, the firmware's colour word, as an opaque draw-list colour.
pub fn colorOf(word: u32) draw_list.Color {
    return draw_list.Color.rgb(@truncate(word >> 16), @truncate(word >> 8), @truncate(word));
}

fn targetOf(user: ?*anyopaque) *Target {
    return @ptrCast(@alignCast(user.?));
}

fn fillRect(user: ?*anyopaque, x: i32, y: i32, w: i32, h: i32, color: u32) callconv(.c) void {
    const target = targetOf(user);
    target.list.fill(.{ .x = x, .y = y, .w = w, .h = h }, colorOf(color)) catch {
        target.failed = true;
    };
}

fn drawText(user: ?*anyopaque, x: i32, y: i32, str: [*:0]const u8, fg: u32, _: u32) callconv(.c) void {
    const target = targetOf(user);
    font.draw(target.list, x, y, std.mem.span(str), colorOf(fg)) catch {
        target.failed = true;
    };
}

fn textSize(_: ?*anyopaque, str: [*:0]const u8, out_w: *i32, out_h: *i32) callconv(.c) void {
    out_w.* = @intCast(font.textWidth(std.mem.len(str)));
    out_h.* = @intCast(font.cell_h);
}
