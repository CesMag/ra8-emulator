//! Host tests for the shell's pane painter (RA8EMU-773): each kind names the
//! feed it waits for, an empty leaf stays blank, and the note lands in muted
//! ink inside every non-empty leaf's body of the two-core layout.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const status_capture = gui_app.status_capture;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell_frame;
const panes = gui_app.shell_panes;

const width: i32 = 480;
const height: i32 = 320;

test "every kind but empty names the feed it waits for" {
    try std.testing.expectEqual(@as(?[]const u8, null), panes.waitingFor(.empty));
    for ([_]pane_layout.Kind{ .board, .camera, .console, .devices, .registers, .memory, .disasm }) |kind| {
        const note = panes.waitingFor(kind).?;
        try std.testing.expect(std.mem.startsWith(u8, note, "waiting for "));
    }
}

test "a body too small for a row gets no note" {
    try std.testing.expectEqual(null, panes.noteAt(.{ .x = 0, .y = 0, .w = 2 * frame.pad, .h = 40 }));
    try std.testing.expectEqual(null, panes.noteAt(.{ .x = 0, .y = 0, .w = 200, .h = font.glyph_h - 1 }));
}

/// Whether any pixel in `area` is `color`.
fn holds(pixels: *const raster.Framebuffer, area: draw_list.Rect, color: draw_list.Color) bool {
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            if (std.meta.eql(pixels.at(@intCast(x), @intCast(y)), color)) return true;
        }
    }
    return false;
}

test "the two-core shell shows each leaf's note in muted ink in its body" {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, width, height);
    defer solved.deinit(gpa);
    var list = draw_list.DrawList.init(gpa, width, height);
    defer list.deinit();
    var pixels = try raster.Framebuffer.init(gpa, width, height);
    defer pixels.deinit(gpa);
    const status: gui_app.status_bar.Status = .{};
    var painter: panes.Panes = .{};
    try frame.draw(&list, dark, .{ .layout = &layout, .solved = &solved, .strip = status_capture.strip(&status, .closed), .width = width, .height = height, .painter = painter.painter() });
    raster.draw(&pixels, &list, font.atlas);
    try std.testing.expectEqual(@as(usize, 6), solved.panes.items.len);
    for (solved.panes.items) |leaf| {
        const at = panes.noteAt(frame.bodyOf(leaf.area)).?;
        const row: draw_list.Rect = .{ .x = at.x, .y = at.y, .w = @intCast(at.room), .h = font.glyph_h };
        try std.testing.expect(holds(&pixels, row, dark.muted));
    }
}
