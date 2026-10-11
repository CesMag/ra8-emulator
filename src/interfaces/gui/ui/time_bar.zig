//! The time bar (RA8EMU-807): run, pause and step buttons, the speed field
//! and the clock readout as one row of draw-list commands, plus the hit test
//! that maps a click to a control. It paints plain values; the status, the
//! speed field and the readout models fill them in gui/time.bar_capture.zig,
//! which also turns a click into a run, step or pause (RA8EMU-1086). The shell
//! (RA8EMU-201) places the bar; this file only lays it out, paints it and
//! answers clicks.
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const widget_paint = @import("ra8_render").widget_paint;
const widget = @import("ra8_widget");
const Theme = @import("colors.zig").Theme;

const Color = draw_list.Color;
const Rect = draw_list.Rect;

pub const pad: i32 = 4;
pub const gap: i32 = 4;
/// A control is a glyph with three pixels of air above and below.
pub const control_h: i32 = font.glyph_h + 6;
/// The controls, a pixel of border on top, and air around them.
pub const height: i32 = control_h + 7;
/// The longest speed text the field shows; gui/time.bar_capture.zig pins it
/// to the speed field's own limit.
pub const field_chars: usize = 12;

pub const Control = enum {
    run,
    pause,
    step,
    field,

    pub fn label(self: Control) []const u8 {
        return switch (self) {
            .run => "Run",
            .pause => "Pause",
            .step => "Step",
            .field => "",
        };
    }
};

/// Where each control sits in a bar, left to right, each cut to the bar; the
/// clock takes what is left. A control that does not fit comes out empty.
pub const Layout = struct {
    run: Rect,
    pause: Rect,
    step: Rect,
    field: Rect,
    clock: Rect,

    pub fn of(bar: Rect) Layout {
        const top = bar.y + 1 + @divTrunc(bar.h - 1 - control_h, 2);
        var x = bar.x + pad;
        const run = place(bar, &x, top, .run);
        const pause_at = place(bar, &x, top, .pause);
        const step = place(bar, &x, top, .step);
        const field = place(bar, &x, top, .field);
        const clock = bar.intersect(.{ .x = x, .y = top, .w = bar.x + bar.w - pad - x, .h = control_h });
        return .{ .run = run, .pause = pause_at, .step = step, .field = field, .clock = clock };
    }

    /// The next control at `x.*`, cut to the bar; moves `x` past it and the gap.
    fn place(bar: Rect, x: *i32, top: i32, control: Control) Rect {
        const w = width(control);
        const at = bar.intersect(.{ .x = x.*, .y = top, .w = w, .h = control_h });
        x.* += w + gap;
        return at;
    }

    pub fn rect(self: Layout, control: Control) Rect {
        return switch (control) {
            .run => self.run,
            .pause => self.pause,
            .step => self.step,
            .field => self.field,
        };
    }
};

/// A button fits its label with a pad each side; the field fits its longest text.
pub fn width(control: Control) i32 {
    const chars = if (control == .field) field_chars else control.label().len;
    return @as(i32, @intCast(font.textWidth(chars))) + 2 * pad;
}

/// What the bar paints, as plain values filled from the models that own them.
pub const View = struct {
    /// Run lights while the core runs; Pause lights while it is halted.
    run_lit: bool = false,
    pause_lit: bool = false,
    /// What the speed field shows.
    field: []const u8 = "",
    /// The session refused the last speed sent.
    field_refused: bool = false,
    /// The field has the keyboard: it reads what is typed and shows a caret.
    editing: bool = false,
    /// The clock readout line.
    clock: []const u8 = "",
};

pub fn draw(list: *draw_list.DrawList, theme: *const Theme, bar: Rect, view: View) !void {
    if (bar.empty()) return;
    try list.pushClip(bar);
    defer list.popClip();
    try list.fill(bar, theme.ribbon_bg);
    try list.fill(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, theme.border);
    const layout = Layout.of(bar);
    var target = widget_paint.Target{ .list = list };
    const paint = target.paint();
    for ([_]Control{ .run, .pause, .step }) |control| {
        try button(&paint, theme, layout.rect(control), control, view);
    }
    try fieldBox(list, theme, layout.field, view);
    try clock(&paint, theme, layout.clock, view);
    if (target.failed) return error.OutOfMemory;
}

fn lights(control: Control, view: View) bool {
    return switch (control) {
        .run => view.run_lit,
        .pause => view.pause_lit,
        .step, .field => false,
    };
}

/// The control as the firmware's push-button widget (RA8EMU-1158): the
/// widget owns the face, border and label look; the theme only fills the
/// descriptor, with the lit look on `face_pressed`.
fn button(paint: *const widget.types.Paint, theme: *const Theme, area: Rect, control: Control, view: View) !void {
    if (area.empty()) return;
    const on = lights(control, view);
    var descriptor = widget.button.Button{
        .paint = paint,
        .text = switch (control) {
            .run => "Run",
            .pause => "Pause",
            .step => "Step",
            .field => "",
        },
        .on_press = null,
        .fg = word(if (on) theme.background else theme.ink),
        .face = word(theme.face),
        .face_pressed = word(switch (control) {
            .run => theme.runLit(),
            .pause => theme.pauseLit(),
            .step => theme.step_active,
            .field => theme.accent,
        }),
        .border = word(if (on) switch (control) {
            .run => theme.good,
            .pause => theme.highlight,
            .step => theme.step_active,
            .field => theme.accent,
        } else theme.control_border),
        .presses = 0,
        .pad = 3,
        .border_w = 1,
        .alignment = .center,
        .pressed = on,
        .reserved = 0,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.button.ra8_widget_button_init(&w, &descriptor);
    w.rect = .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h };
    w.vt.?.render.?(&w);
}

/// The clock readout as the firmware's label widget, one line on the bar's
/// own background.
fn clock(paint: *const widget.types.Paint, theme: *const Theme, area: Rect, view: View) !void {
    if (area.empty()) return;
    var buf: [160]u8 = undefined;
    const n = @min(view.clock.len, buf.len - 1);
    @memcpy(buf[0..n], view.clock);
    buf[n] = 0;
    var descriptor = widget.label.Label{
        .paint = paint,
        .text = buf[0..n :0].ptr,
        .fg = word(theme.muted),
        .bg = word(theme.ribbon_bg),
        .pad = pad,
        .alignment = .left,
        .face = .sans,
    };
    var w: widget.types.Widget = undefined;
    _ = widget.label.ra8_widget_label_init(&w, &descriptor);
    w.rect = .{ .x = area.x, .y = area.y, .w = area.w, .h = area.h };
    w.vt.?.render.?(&w);
}

fn fieldBox(list: *draw_list.DrawList, theme: *const Theme, area: Rect, view: View) !void {
    if (area.empty()) return;
    try list.fill(area, theme.well);
    try outline(list, area, if (view.field_refused) theme.bad else if (view.editing) theme.accent else theme.control_border);
    const shown = view.field;
    try text(list, area, shown, theme.ink);
    if (!view.editing) return;
    const caret_x = area.x + pad + @as(i32, @intCast(font.textWidth(shown.len)));
    try list.fill(.{ .x = caret_x, .y = area.y + 2, .w = 1, .h = area.h - 4 }, theme.ink);
}

fn outline(list: *draw_list.DrawList, area: Rect, color: Color) !void {
    try list.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, color);
    try list.fill(.{ .x = area.x, .y = area.y + area.h - 1, .w = area.w, .h = 1 }, color);
    try list.fill(.{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, color);
    try list.fill(.{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h }, color);
}

/// `line` from a pad in, centred down `area`, cut to whole cells inside it.
fn text(list: *draw_list.DrawList, area: Rect, line: []const u8, color: Color) !void {
    const room = area.w - 2 * pad;
    if (room <= 0) return;
    const shown = font.fit(line, @intCast(room));
    const top = area.y + @divTrunc(area.h - @as(i32, font.glyph_h), 2);
    try font.draw(list, area.x + pad, top, shown, color);
}

/// The control under (`x`, `y`) in `bar`, or null for the gaps and the clock.
pub fn hit(bar: Rect, x: i32, y: i32) ?Control {
    const layout = Layout.of(bar);
    for ([_]Control{ .run, .pause, .step, .field }) |control| {
        if (layout.rect(control).contains(x, y)) return control;
    }
    return null;
}
