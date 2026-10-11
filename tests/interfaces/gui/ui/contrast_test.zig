//! RA8EMU-1136: every text role in src/interfaces/gui/ui/t.zig reads at
//! WCAG AA (4.5:1) on each surface the GUI draws it on, and every mark that
//! carries meaning without text (a breakpoint square, the pc stripe, a status
//! dot, a lit field outline, a caret) reaches 3:1. The pairs below come from
//! the draw calls in src/interfaces/gui. RA8EMU-961: every palette in
//! t.palettes is held to the same pairs, so Dark and Light (and whatever
//! System resolves to, which is one of them) all pass. Dividers, faces,
//! bezels, gutters and unlit LEDs are decoration and stay out of it.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const colors = gui_app.colors;
const Theme = colors.Theme;
const Color = ra8.render.draw_list.Color;

const text_ratio: f64 = 4.5;
const mark_ratio: f64 = 3.0;

const Pair = struct { name: []const u8, fg: Color, bg: Color };

/// Text roles and the surfaces they are drawn on.
fn textPairs(t: *const Theme) [20]Pair {
    return .{
        .{ .name = "ink on background", .fg = t.ink, .bg = t.background },
        .{ .name = "ink on title face", .fg = t.ink, .bg = t.face },
        .{ .name = "ink on well", .fg = t.ink, .bg = t.well },
        .{ .name = "ink on band", .fg = t.ink, .bg = t.band },
        .{ .name = "muted on background", .fg = t.muted, .bg = t.background },
        .{ .name = "muted on title face", .fg = t.muted, .bg = t.face },
        .{ .name = "muted on ribbon", .fg = t.muted, .bg = t.ribbon_bg },
        .{ .name = "muted on band", .fg = t.muted, .bg = t.band },
        .{ .name = "muted on pc band", .fg = t.muted, .bg = t.pc_band_bg },
        .{ .name = "muted on dirty cell", .fg = t.muted, .bg = t.dirty_cell_bg },
        .{ .name = "muted on camera preview", .fg = t.muted, .bg = t.preview },
        .{ .name = "highlight on background", .fg = t.highlight, .bg = t.background },
        .{ .name = "highlight on band", .fg = t.highlight, .bg = t.band },
        .{ .name = "highlight on dirty cell", .fg = t.highlight, .bg = t.dirty_cell_bg },
        .{ .name = "accent on background", .fg = t.accent, .bg = t.background },
        .{ .name = "pc cyan on pc band", .fg = t.pc_cyan, .bg = t.pc_band_bg },
        .{ .name = "background on lit run", .fg = t.background, .bg = t.runLit() },
        .{ .name = "background on lit pause", .fg = t.background, .bg = t.pauseLit() },
        .{ .name = "background on lit step", .fg = t.background, .bg = t.step_active },
        .{ .name = "background on lit field", .fg = t.background, .bg = t.accent },
    };
}

/// Marks that carry meaning on their own and the surfaces under them.
fn markPairs(t: *const Theme) [15]Pair {
    const tone = t.tone();
    return .{
        .{ .name = "breakpoint on background", .fg = t.breakpoint, .bg = t.background },
        .{ .name = "breakpoint on pc band", .fg = t.breakpoint, .bg = t.pc_band_bg },
        .{ .name = "source breakpoint on background", .fg = t.bad, .bg = t.background },
        .{ .name = "source breakpoint on band", .fg = t.bad, .bg = t.band },
        .{ .name = "pc stripe on pc band", .fg = t.pc_cyan, .bg = t.pc_band_bg },
        .{ .name = "caret on band", .fg = t.ink, .bg = t.band },
        .{ .name = "caret on well", .fg = t.ink, .bg = t.well },
        .{ .name = "editing outline on well", .fg = t.accent, .bg = t.well },
        .{ .name = "refused outline on well", .fg = t.bad, .bg = t.well },
        .{ .name = "waiting dot on pill", .fg = tone.waiting, .bg = t.status_pill },
        .{ .name = "good dot on pill", .fg = tone.good, .bg = t.status_pill },
        .{ .name = "bad dot on pill", .fg = tone.bad, .bg = t.status_pill },
        .{ .name = "running dot on pill", .fg = tone.running, .bg = t.status_pill },
        .{ .name = "halted dot on pill", .fg = tone.halted, .bg = t.status_pill },
        .{ .name = "camera on light on preview", .fg = t.recording, .bg = t.preview },
    };
}

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

fn failures(palette: []const u8, pairs: []const Pair, floor: f64) usize {
    var failed: usize = 0;
    for (pairs) |pair| {
        const ratio = contrast(pair.fg, pair.bg);
        if (ratio >= floor) continue;
        std.debug.print("{s}: {s}: {d:.2}:1, needs {d:.1}:1\n", .{ palette, pair.name, ratio, floor });
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

/// Every baked-in palette, by name.
const palettes = [_]struct { name: []const u8, theme: *const Theme }{
    .{ .name = "dark", .theme = &colors.palettes.dark },
    .{ .name = "light", .theme = &colors.palettes.light },
};

test "every text role reads at WCAG AA on each surface it is drawn on, in every palette" {
    var failed: usize = 0;
    for (palettes) |palette| {
        const pairs = textPairs(palette.theme);
        failed += failures(palette.name, &pairs, text_ratio);
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "every meaningful mark reaches 3:1 on the surface under it, in every palette" {
    var failed: usize = 0;
    for (palettes) |palette| {
        const pairs = markPairs(palette.theme);
        failed += failures(palette.name, &pairs, mark_ratio);
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "every theme choice has a palette under test" {
    for (std.enums.values(colors.Choice)) |choice| {
        var found = false;
        for (palettes) |palette| found = found or palette.theme == colors.of(choice);
        try std.testing.expect(found);
    }
}
