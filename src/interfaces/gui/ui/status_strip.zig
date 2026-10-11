//! The status strip (RA8EMU-759): the status bar's line painted along the
//! bottom of the shell window. A dot at the left carries the state's tone
//! (connected, failed, running, halted); the text is cut to whole cells when
//! the window is narrow, never drawn past the strip. src/interfaces/gui/status/capture.zig
//! reads the session's status into a `Strip`; this file never imports it.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

/// The strip sits in the well colour, below the panes' background.
pub const pad: i32 = 4;
pub const dot: i32 = 6;
/// One text line with two pixels of air above and below, plus the border.
pub const height: i32 = @as(i32, @intCast(font.cell_h)) + 5;

pub const Tone = enum {
    waiting,
    good,
    bad,
    running,
    halted,

    pub fn color(self: Tone, theme: *const Theme) Color {
        return switch (self) {
            .waiting => theme.tone().waiting,
            .good => theme.tone().good,
            .bad => theme.tone().bad,
            .running => theme.tone().running,
            .halted => theme.tone().halted,
        };
    }
};

/// What one frame of the strip shows: the dot's tone and the status line.
pub const Strip = struct {
    tone: Tone = .waiting,
    line_buf: [256]u8 = undefined,
    line_len: usize = 0,

    pub fn line(self: *const Strip) []const u8 {
        return self.line_buf[0..self.line_len];
    }
};

/// The strip's place in a window of `width` by `window_h` pixels.
pub fn area(width: i32, window_h: i32) Rect {
    return .{ .x = 0, .y = window_h - height, .w = width, .h = height };
}

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, strip: Rect, view: *const Strip) !void {
    if (strip.empty()) return;
    try list.fill(strip, theme.well);
    try list.fill(.{ .x = strip.x, .y = strip.y, .w = strip.w, .h = 1 }, theme.border);
    try list.pushClip(strip);
    defer list.popClip();
    const middle = strip.y + 1 + @divTrunc(strip.h - 1 - dot, 2);
    // The dot sits on a pill a pixel wider all round.
    try list.fill(.{ .x = strip.x + pad - 1, .y = middle - 1, .w = dot + 2, .h = dot + 2 }, theme.status_pill);
    try list.fill(.{ .x = strip.x + pad, .y = middle, .w = dot, .h = dot }, view.tone.color(theme));
    const line = view.line();
    const left = strip.x + pad + dot + pad + 2;
    const room = strip.x + strip.w - pad - left;
    if (room <= 0) return;
    const shown = font.fit(line, @intCast(room));
    const top = strip.y + 1 + @divTrunc(strip.h - 1 - @as(i32, font.glyph_h), 2);
    try font.draw(list, left, top, shown, theme.ink);
}
