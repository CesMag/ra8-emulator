//! Host tests for the theme picker (RA8EMU-1165): where the button, its chip
//! and the popover sit on the status strip, clear of the window's corner,
//! what a point lands on, each icon drawn pixel for pixel, and pinned
//! CPU-backend golden frames of the chip alone and of the popover out, in
//! both palettes.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const colors = gui_app.colors;
const picker = gui_app.theme_picker;
const strip = gui_app.status_strip;
const dark = &colors.palettes.dark;
const light = &colors.palettes.light;

const Rect = draw_list.Rect;
const width = 160;
const height = 100;
const bar = strip.area(width, height);

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,

    fn init() !Scene {
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, width, height), .frame = try raster.Framebuffer.init(std.testing.allocator, width, height) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    /// The window's background, then the picker on it.
    fn render(self: *Scene, theme: *const colors.Theme, view: picker.View) !void {
        self.list.clear();
        try self.list.fill(.{ .x = 0, .y = 0, .w = width, .h = height }, theme.background);
        try picker.draw(&self.list, theme, bar, view);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
    }

    fn at(self: *const Scene, x: i32, y: i32) draw_list.Color {
        return self.frame.at(@intCast(x), @intCast(y));
    }
};

test "the button takes the strip's right end and the status line keeps the rest" {
    const at = picker.button(bar);
    try std.testing.expectEqual(Rect{ .x = width - picker.width, .y = bar.y, .w = picker.width, .h = bar.h }, at);
    const rest = picker.rest(bar);
    try std.testing.expectEqual(Rect{ .x = 0, .y = bar.y, .w = width - picker.width, .h = bar.h }, rest);
}

test "a strip too narrow for the button has none and keeps its whole width" {
    const narrow: Rect = .{ .x = 0, .y = 0, .w = picker.width - 1, .h = strip.height };
    try std.testing.expect(picker.button(narrow).empty());
    try std.testing.expectEqual(narrow, picker.rest(narrow));
    try std.testing.expectEqual(@as(?picker.Hit, null), picker.hit(narrow, true, narrow.w - 1, 5));
    var list = draw_list.DrawList.init(std.testing.allocator, 32, 32);
    defer list.deinit();
    try picker.draw(&list, dark, narrow, .{ .open = true });
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "the chip sits in the button, a margin in from the window's edge and off its foot" {
    const at = picker.button(bar);
    const chip = picker.chipOf(bar);
    try std.testing.expectEqual(@as(i32, width - picker.margin), chip.x + chip.w);
    try std.testing.expect(picker.margin >= 11);
    try std.testing.expect(chip.x >= at.x + picker.pad and chip.y > at.y);
    try std.testing.expect(chip.y + chip.h < height);
    try std.testing.expectEqual(picker.side + 2, chip.w);
    try std.testing.expectEqual(picker.side + 2, chip.h);
}

test "the popover stands on the strip, its right edge on the chip's, one row per theme" {
    const box = picker.popover(bar);
    const chip = picker.chipOf(bar);
    try std.testing.expectEqual(chip.x + chip.w, box.x + box.w);
    try std.testing.expectEqual(bar.y, box.y + box.h);
    try std.testing.expectEqualSlices(colors.Choice, &.{ .light, .dark, .system }, &picker.rows);
    var last = box.y;
    for (picker.rows, 0..) |_, index| {
        const at = picker.row(bar, index);
        try std.testing.expect(at.y > last and at.x > box.x and at.x + at.w < box.x + box.w);
        try std.testing.expect(at.y + at.h <= bar.y);
        last = at.y;
    }
}

test "a point lands on the button, and on a row only while the popover is out" {
    const at = picker.button(bar);
    try std.testing.expectEqual(@as(?picker.Hit, .button), picker.hit(bar, false, at.x, at.y));
    try std.testing.expectEqual(@as(?picker.Hit, .button), picker.hit(bar, true, at.x + at.w - 1, at.y + at.h - 1));
    try std.testing.expectEqual(@as(?picker.Hit, null), picker.hit(bar, false, at.x - 1, at.y));
    for (picker.rows, 0..) |choice, index| {
        const row = picker.row(bar, index);
        try std.testing.expectEqual(@as(?picker.Hit, .{ .row = choice }), picker.hit(bar, true, row.x, row.y));
        try std.testing.expectEqual(@as(?picker.Hit, null), picker.hit(bar, false, row.x, row.y));
    }
    try std.testing.expectEqual(@as(?picker.Hit, null), picker.hit(bar, true, 2, 2));
}

test "the button shows the icon of the theme in use, pixel for pixel" {
    var scene = try Scene.init();
    defer scene.deinit();
    const chip = picker.chipOf(bar);
    const left = chip.x + 1;
    const top = chip.y + 1;
    for (picker.rows) |choice| {
        try scene.render(dark, .{ .choice = choice });
        const mask = picker.icon(choice);
        var lit: usize = 0;
        for (mask, 0..) |bits, line| {
            var column: i32 = 0;
            while (column < picker.side) : (column += 1) {
                const on = bits >> @intCast(picker.side - 1 - column) & 1 != 0;
                lit += @intFromBool(on);
                const want = if (on) dark.ink else dark.face;
                try std.testing.expectEqual(want, scene.at(left + column, top + @as(i32, @intCast(line))));
            }
        }
        try std.testing.expect(lit > 30);
    }
    try std.testing.expect(!std.mem.eql(u16, picker.icon(.light), picker.icon(.dark)));
    try std.testing.expect(!std.mem.eql(u16, picker.icon(.dark), picker.icon(.system)));
}

test "folded, the strip's top line runs on over the button and nothing is drawn above it" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(dark, .{ .choice = .dark });
    var x: i32 = picker.button(bar).x;
    while (x < width) : (x += 1) {
        try std.testing.expectEqual(dark.border, scene.at(x, bar.y));
        try std.testing.expectEqual(dark.background, scene.at(x, bar.y - 1));
    }
}

test "folded, the chip is a bordered face on the strip's well, in both palettes" {
    var scene = try Scene.init();
    defer scene.deinit();
    const chip = picker.chipOf(bar);
    for ([_]*const colors.Theme{ dark, light }) |theme| {
        try scene.render(theme, .{ .choice = .system });
        for ([_]i32{ chip.x, chip.x + chip.w - 1 }) |x| {
            for ([_]i32{ chip.y, chip.y + chip.h - 1 }) |y| try std.testing.expectEqual(theme.control_border, scene.at(x, y));
        }
        // The monitor's top-left pixel is clear, so the face shows there.
        try std.testing.expectEqual(theme.face, scene.at(chip.x + 1, chip.y + 1));
        try std.testing.expectEqual(theme.well, scene.at(chip.x - 1, chip.y + 4));
        try std.testing.expectEqual(theme.well, scene.at(chip.x + chip.w, chip.y + 4));
        try std.testing.expectEqual(theme.well, scene.at(width - 1, chip.y + 4));
    }
}

test "out, the popover marks the theme in use and joins the button in one outline" {
    var scene = try Scene.init();
    defer scene.deinit();
    for (picker.rows, 0..) |choice, active| {
        try scene.render(dark, .{ .choice = choice, .open = true });
        for (picker.rows, 0..) |_, index| {
            const row = picker.row(bar, index);
            const want = if (index == active) dark.band else dark.face;
            try std.testing.expectEqual(want, scene.at(row.x + row.w - 2, row.y + 1));
        }
    }
    const box = picker.popover(bar);
    const chip = picker.chipOf(bar);
    const right = chip.x + chip.w - 1;
    const foot = chip.y + chip.h - 1;
    // The shared right edge runs from the popover's top to the chip's foot.
    var y: i32 = box.y;
    while (y <= foot) : (y += 1) try std.testing.expectEqual(dark.control_border, scene.at(right, y));
    // Nothing closes the popover off from the chip under it.
    try std.testing.expectEqual(dark.face, scene.at(chip.x + 2, bar.y));
    try std.testing.expectEqual(dark.face, scene.at(chip.x + 2, bar.y + 1));
    try std.testing.expectEqual(dark.control_border, scene.at(chip.x - 2, bar.y));
    try std.testing.expectEqual(dark.control_border, scene.at(box.x, box.y + 5));
    try std.testing.expectEqual(dark.control_border, scene.at(chip.x, chip.y + 5));
    try std.testing.expectEqual(dark.control_border, scene.at(chip.x + 3, foot));
    // The strip keeps its own look to the right of the chip.
    try std.testing.expectEqual(dark.border, scene.at(width - 1, bar.y));
    try std.testing.expectEqual(dark.well, scene.at(width - 1, foot));
}

test "the picker rasterises to the pinned golden frames" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(dark, .{ .choice = .dark });
    try std.testing.expectEqual(@as(u64, 12535633278405975110), scene.digest());
    try scene.render(dark, .{ .choice = .dark, .open = true });
    try std.testing.expectEqual(@as(u64, 5429106914451383086), scene.digest());
    try scene.render(light, .{ .choice = .light, .open = true });
    try std.testing.expectEqual(@as(u64, 15906714194783620575), scene.digest());
    try scene.render(light, .{ .choice = .system, .open = true });
    try std.testing.expectEqual(@as(u64, 4269888253187784919), scene.digest());
}
