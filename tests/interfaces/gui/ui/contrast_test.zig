//! RA8EMU-1136: every text role in src/interfaces/gui/ui/colors.zig reads at
//! WCAG AA (4.5:1) on each surface the GUI draws it on, and every mark that
//! carries meaning without text (a breakpoint square, the pc stripe, a status
//! dot, a lit field outline, a caret) reaches 3:1. The pairs below come from
//! the draw calls in src/interfaces/gui; a new palette (Light, System) keeps
//! the same semantic roles and has to pass this file too. Dividers, faces,
//! bezels, gutters and unlit LEDs are decoration and stay out of it.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const colors = gui_app.colors;
const Color = ra8.render.draw_list.Color;

const text_ratio: f64 = 4.5;
const mark_ratio: f64 = 3.0;

const Pair = struct { name: []const u8, fg: Color, bg: Color };

/// Text roles and the surfaces they are drawn on.
const text_pairs = [_]Pair{
    .{ .name = "ink on background", .fg = colors.ink, .bg = colors.background },
    .{ .name = "ink on title face", .fg = colors.ink, .bg = colors.face },
    .{ .name = "ink on well", .fg = colors.ink, .bg = colors.well },
    .{ .name = "ink on band", .fg = colors.ink, .bg = colors.band },
    .{ .name = "muted on background", .fg = colors.muted, .bg = colors.background },
    .{ .name = "muted on title face", .fg = colors.muted, .bg = colors.face },
    .{ .name = "muted on ribbon", .fg = colors.muted, .bg = colors.ribbon_bg },
    .{ .name = "muted on band", .fg = colors.muted, .bg = colors.band },
    .{ .name = "muted on pc band", .fg = colors.muted, .bg = colors.pc_band_bg },
    .{ .name = "muted on dirty cell", .fg = colors.muted, .bg = colors.dirty_cell_bg },
    .{ .name = "muted on camera preview", .fg = colors.muted, .bg = colors.preview },
    .{ .name = "highlight on background", .fg = colors.highlight, .bg = colors.background },
    .{ .name = "highlight on band", .fg = colors.highlight, .bg = colors.band },
    .{ .name = "highlight on dirty cell", .fg = colors.highlight, .bg = colors.dirty_cell_bg },
    .{ .name = "accent on background", .fg = colors.accent, .bg = colors.background },
    .{ .name = "pc cyan on pc band", .fg = colors.pc_cyan, .bg = colors.pc_band_bg },
    .{ .name = "background on lit run", .fg = colors.background, .bg = colors.run_lit },
    .{ .name = "background on lit pause", .fg = colors.background, .bg = colors.pause_lit },
    .{ .name = "background on lit step", .fg = colors.background, .bg = colors.step_active },
    .{ .name = "background on lit field", .fg = colors.background, .bg = colors.accent },
};

/// Marks that carry meaning on their own and the surfaces under them.
const mark_pairs = [_]Pair{
    .{ .name = "breakpoint on background", .fg = colors.breakpoint, .bg = colors.background },
    .{ .name = "breakpoint on pc band", .fg = colors.breakpoint, .bg = colors.pc_band_bg },
    .{ .name = "source breakpoint on background", .fg = colors.bad, .bg = colors.background },
    .{ .name = "source breakpoint on band", .fg = colors.bad, .bg = colors.band },
    .{ .name = "pc stripe on pc band", .fg = colors.pc_cyan, .bg = colors.pc_band_bg },
    .{ .name = "caret on band", .fg = colors.ink, .bg = colors.band },
    .{ .name = "caret on well", .fg = colors.ink, .bg = colors.well },
    .{ .name = "editing outline on well", .fg = colors.accent, .bg = colors.well },
    .{ .name = "refused outline on well", .fg = colors.bad, .bg = colors.well },
    .{ .name = "waiting dot on pill", .fg = colors.tone.waiting, .bg = colors.status_pill },
    .{ .name = "good dot on pill", .fg = colors.tone.good, .bg = colors.status_pill },
    .{ .name = "bad dot on pill", .fg = colors.tone.bad, .bg = colors.status_pill },
    .{ .name = "running dot on pill", .fg = colors.tone.running, .bg = colors.status_pill },
    .{ .name = "halted dot on pill", .fg = colors.tone.halted, .bg = colors.status_pill },
    .{ .name = "camera on light on preview", .fg = colors.recording, .bg = colors.preview },
};

fn channel(value: u8) f64 {
    const c = @as(f64, @floatFromInt(value)) / 255.0;
    return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

/// WCAG 2.x relative luminance.
fn luminance(color: Color) f64 {
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
}

/// WCAG 2.x contrast ratio, lighter over darker.
pub fn contrast(a: Color, b: Color) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

fn failures(pairs: []const Pair, floor: f64) usize {
    var failed: usize = 0;
    for (pairs) |pair| {
        const ratio = contrast(pair.fg, pair.bg);
        if (ratio >= floor) continue;
        std.debug.print("{s}: {d:.2}:1, needs {d:.1}:1\n", .{ pair.name, ratio, floor });
        failed += 1;
    }
    return failed;
}

test "contrast matches the WCAG reference points" {
    const black = Color.rgb(0, 0, 0);
    const white = Color.rgb(0xFF, 0xFF, 0xFF);
    try std.testing.expectApproxEqAbs(@as(f64, 21.0), contrast(black, white), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), contrast(white, white), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.54), contrast(Color.rgb(0x76, 0x76, 0x76), white), 0.01);
}

test "every text role reads at WCAG AA on each surface it is drawn on" {
    try std.testing.expectEqual(@as(usize, 0), failures(&text_pairs, text_ratio));
}

test "every meaningful mark reaches 3:1 on the surface under it" {
    try std.testing.expectEqual(@as(usize, 0), failures(&mark_pairs, mark_ratio));
}
