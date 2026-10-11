//! The board view `--frame-out` writes (RA8EMU-73): the panel as the GLCDC
//! drove it, set into an EK-RA8D2 outline with the user LEDs in a strip
//! under it, lit in their own colour when the pin drives them on.
//!
//! The panel pixels are copied unchanged, so a frame hash taken from the
//! panel region still matches the GLCDC's own. The outline is drawn, not
//! a photo: the board colour, a black bezel and one square per LED.
const std = @import("std");

/// Board colour around the panel, ARGB8888.
pub const pcb: u32 = 0xFF1B4D2E;
/// The bezel ring drawn round the panel.
pub const bezel: u32 = 0xFF000000;
/// An LED the pin leaves off.
pub const dark: u32 = 0xFF3A3A3A;
/// Board margin round the panel, in pixels.
pub const margin: u32 = 16;
/// Height of the LED strip under the panel.
pub const strip: u32 = 32;
/// Side of one LED square, and the gap between squares.
pub const led_side: u32 = 12;
pub const led_gap: u32 = 12;
/// The EK-RA8D2 panel's size, used for the view when the run left no
/// frame: the board is still drawn, with its LEDs, round a dark panel.
pub const panel_width: u32 = 1024;
pub const panel_height: u32 = 600;

/// One user LED, read from the board by the session.
pub const Led = @import("ra8_session").board.leds.Led;

pub const Size = struct { width: u32, height: u32 };

/// The view's size for a panel of `width` x `height`.
pub fn size(width: u32, height: u32) Size {
    return .{ .width = width + 2 * margin, .height = height + 2 * margin + strip };
}

/// RGB565 widened to opaque ARGB8888, low bits filled from the high ones.
pub fn argbOf(rgb565: u16) u32 {
    const r5: u32 = (rgb565 >> 11) & 0x1F;
    const g6: u32 = (rgb565 >> 5) & 0x3F;
    const b5: u32 = rgb565 & 0x1F;
    const r = (r5 << 3) | (r5 >> 2);
    const g = (g6 << 2) | (g6 >> 4);
    const b = (b5 << 3) | (b5 >> 2);
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

/// Draw the view into `canvas`, which holds size(width, height) pixels.
pub fn compose(canvas: []u32, panel: []const u32, width: u32, height: u32, leds: []const Led) void {
    const view = size(width, height);
    std.debug.assert(canvas.len == @as(usize, view.width) * view.height);
    @memset(canvas, pcb);
    fill(canvas, view.width, margin - 1, margin - 1, width + 2, height + 2, bezel);
    for (0..height) |row| {
        const from = row * width;
        const to = (row + margin) * view.width + margin;
        @memcpy(canvas[to .. to + width], panel[from .. from + width]);
    }
    const top = height + 2 * margin + (strip - led_side) / 2 - margin / 2;
    for (leds, 0..) |led, i| {
        const left = margin + @as(u32, @intCast(i)) * (led_side + led_gap);
        if (left + led_side > view.width) break;
        fill(canvas, view.width, left, top, led_side, led_side, if (led.on) argbOf(led.rgb565) else dark);
    }
}

/// The colour at (x, y) of a view `stride` pixels wide.
pub fn at(canvas: []const u32, stride: u32, x: u32, y: u32) u32 {
    return canvas[@as(usize, y) * stride + x];
}

fn fill(canvas: []u32, stride: u32, x: u32, y: u32, w: u32, h: u32, colour: u32) void {
    for (y..y + h) |row| {
        const start = row * stride + x;
        @memset(canvas[start .. start + w], colour);
    }
}
