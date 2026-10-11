//! Draws the camera panel and turns clicks on it into picks and answers
//! (RA8EMU-500). It only reads and changes a `camera_panel.Panel`; the
//! shell sends each pick to the session, which opens the source
//! (shell_camera.zig).
//!
//! A row of one button per source, the active one ringed; a dot that is
//! red while the webcam is the source; and, while the webcam permission is
//! being asked, a dialog of Allow once, Always for this project and Cancel.
//! Each button has its own colour and a short label in the built-in font
//! (RA8EMU-677). While Always stands, the dialog row holds one button that
//! takes it back (RA8EMU-1124), clear of the dialog's own three so a second
//! click on Always cannot land on it.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const camera_panel = @import("../camera_panel.zig");
const font = @import("ra8_render").font;
const Theme = @import("colors.zig").Theme;
const Color = draw_list.Color;
const Rect = draw_list.Rect;
const Panel = camera_panel.Panel;
const Kind = camera_panel.Kind;
const Answer = camera_panel.Answer;

pub const button: i32 = 24;
pub const gap: i32 = 4;
pub const dot: i32 = 8;

/// Each source's button colour.
pub fn colorOf(theme: *const Theme, kind: Kind) Color {
    return switch (kind) {
        .gradient => theme.muted,
        .image => theme.hue.blue,
        .video => theme.hue.purple,
        .pipe => theme.hue.green,
        .webcam => theme.hue.yellow,
    };
}

/// Each source's button label, three cells at most.
pub fn labelOf(kind: Kind) []const u8 {
    return switch (kind) {
        .gradient => "GRD",
        .image => "IMG",
        .video => "VID",
        .pipe => "PIP",
        .webcam => "CAM",
    };
}

/// Each answer's button label.
pub fn answerLabel(reply: Answer) []const u8 {
    return switch (reply) {
        .allow_once => "ONE",
        .always => "ALW",
        .cancel => "NO",
    };
}

/// The label and colour of the button that takes Always back.
pub const withdraw_label = "FORGET ALWAYS";

/// Label ink that reads on `fill`: the dark background on light fills,
/// the light ring colour on dark ones.
pub fn inkOn(theme: *const Theme, fill: Color) Color {
    const luma = @as(u32, fill.r) * 299 + @as(u32, fill.g) * 587 + @as(u32, fill.b) * 114;
    return if (luma > 128 * 1000) theme.preview else theme.ink;
}

/// Each answer's button colour.
pub fn answerColor(theme: *const Theme, reply: Answer) Color {
    return switch (reply) {
        .allow_once => theme.hue.green,
        .always => theme.hue.blue,
        .cancel => theme.hue.red,
    };
}

/// Where everything sits, from the panel's top-left corner.
pub const Layout = struct {
    x: i32,
    y: i32,

    const kinds = std.enums.values(Kind);

    /// The whole panel: the source row over the dialog row.
    pub fn area(self: Layout) Rect {
        const w = @as(i32, @intCast(kinds.len + 1)) * (button + gap) + gap;
        return .{ .x = self.x, .y = self.y, .w = w, .h = 2 * (button + gap) + gap };
    }

    pub fn source(self: Layout, kind: Kind) Rect {
        const at: i32 = @intCast(@backingInt(kind));
        return .{ .x = self.x + gap + at * (button + gap), .y = self.y + gap, .w = button, .h = button };
    }

    pub fn indicator(self: Layout) Rect {
        const at: i32 = @intCast(kinds.len);
        const x = self.x + gap + at * (button + gap) + @divTrunc(button - dot, 2);
        return .{ .x = x, .y = self.y + gap + @divTrunc(button - dot, 2), .w = dot, .h = dot };
    }

    pub fn dialog(self: Layout, reply: Answer) Rect {
        const at: i32 = @intCast(@backingInt(reply));
        const y = self.y + 2 * gap + button;
        return .{ .x = self.x + gap + at * (button + gap), .y = y, .w = button, .h = button };
    }

    /// The button that takes Always back: the rest of the dialog row,
    /// after the last answer's slot.
    pub fn withdraw(self: Layout) Rect {
        const at: i32 = @intCast(std.enums.values(Answer).len);
        const left = gap + at * (button + gap);
        return .{ .x = self.x + left, .y = self.y + 2 * gap + button, .w = self.area().w - left - gap, .h = button };
    }
};

/// Appends the panel as it stands to `list`.
pub fn draw(list: *draw_list.DrawList, theme: *const Theme, layout: Layout, panel: Panel) !void {
    try list.fill(layout.area(), theme.preview);
    for (Layout.kinds) |kind| {
        const at = layout.source(kind);
        if (kind == panel.active) {
            try list.fill(.{ .x = at.x - 2, .y = at.y - 2, .w = at.w + 4, .h = at.h + 4 }, theme.ink);
        }
        try list.fill(at, colorOf(theme, kind));
        try font.centred(list, at, labelOf(kind), inkOn(theme, colorOf(theme, kind)));
    }
    try list.fill(layout.indicator(), if (panel.cameraOn()) theme.recording else theme.border);
    if (panel.always) {
        try list.fill(layout.withdraw(), theme.hue.blue);
        try font.centred(list, layout.withdraw(), withdraw_label, inkOn(theme, theme.hue.blue));
    }
    if (!panel.asking) return;
    for (std.enums.values(Answer)) |reply| {
        try list.fill(layout.dialog(reply), answerColor(theme, reply));
        try font.centred(list, layout.dialog(reply), answerLabel(reply), inkOn(theme, answerColor(theme, reply)));
    }
}

/// Applies a click at (`x`, `y`) to `panel`. While the dialog is open only
/// its buttons and the source row answer; a click anywhere else is not the
/// panel's. While Always stands, its button takes it back. Returns whether
/// the panel took the click.
pub fn click(panel: *Panel, layout: Layout, x: i32, y: i32) bool {
    if (panel.asking) {
        for (std.enums.values(Answer)) |reply| {
            if (layout.dialog(reply).contains(x, y)) {
                panel.answer(reply);
                return true;
            }
        }
    }
    if (panel.always and layout.withdraw().contains(x, y)) {
        panel.withdraw();
        return true;
    }
    for (Layout.kinds) |kind| {
        if (layout.source(kind).contains(x, y)) {
            panel.pick(kind);
            return true;
        }
    }
    return layout.area().contains(x, y);
}
