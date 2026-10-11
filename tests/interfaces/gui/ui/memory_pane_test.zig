//! Covers src/interfaces/gui/ui/memory_pane.zig (RA8EMU-746): a row's
//! columns line up, the pane rasterises to a pinned golden frame,
//! unreadable bytes draw only muted "??" and '?', and a pane too narrow
//! draws nothing and rows stop at what was captured.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.memory_pane;

const Rect = draw_list.Rect;
/// Exactly one row wide and four rows deep.
const area = Rect{ .x = 0, .y = 0, .w = pane.min_w, .h = 2 * pane.pad + 4 * pane.row_h };

/// Four rows of mixed printable and unprintable bytes; the last row's top
/// half cannot be read.
fn sample() pane.Snapshot {
    var snapshot: pane.Snapshot = .{ .base = 0x2000_0100, .count = 4 };
    for (0..4 * pane.per_row) |index| {
        snapshot.bytes[index] = @intCast((index * 7 + 0x20) & 0xFF);
        snapshot.readable[index] = index < 3 * pane.per_row + 8;
    }
    return snapshot;
}

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,

    fn init() !Scene {
        const w: u32 = @intCast(area.w);
        const h: u32 = @intCast(area.h);
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, w, h), .frame = try raster.Framebuffer.init(std.testing.allocator, w, h) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, snapshot: *const pane.Snapshot) !void {
        try pane.draw(&self.list, dark, area, snapshot);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
    }

    /// Glyphs drawn in `color`.
    fn glyphs(self: *const Scene, color: draw_list.Color) usize {
        var count: usize = 0;
        for (self.list.commands.items) |command| {
            if (command.shape == .glyph and std.meta.eql(command.shape.glyph.color, color)) count += 1;
        }
        return count;
    }
};

test "a row is an address, sixteen hex bytes with a gap after the eighth, then ASCII" {
    try std.testing.expectEqual(@as(usize, 76), pane.row_len);
    try std.testing.expectEqual(pane.hex_at + 21, pane.hexColumn(7));
    try std.testing.expectEqual(pane.hex_at + 25, pane.hexColumn(8));
    try std.testing.expectEqual(pane.ascii_at, pane.hexColumn(15) + 4);
    try std.testing.expectEqual(@as(usize, 4), pane.rows(area));
    try std.testing.expectEqual(pane.pad + 2 + 3 * pane.row_h, pane.rowOrigin(area, 3).y);
}

test "the pane rasterises to the pinned golden frame" {
    var scene = try Scene.init();
    defer scene.deinit();
    const snapshot = sample();
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(u64, 11025890780803989611), scene.digest());
}

test "unreadable bytes draw only muted question marks" {
    var scene = try Scene.init();
    defer scene.deinit();
    var snapshot: pane.Snapshot = .{ .base = 0, .count = 1 };
    @memset(snapshot.bytes[0..pane.per_row], 'A');
    @memset(snapshot.readable[0..12], true);
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(usize, 12 * 3), scene.glyphs(dark.ink));
    try std.testing.expectEqual(@as(usize, 8 + 4 * 3), scene.glyphs(dark.muted));
}

test "a pane too narrow draws nothing, and rows stop at what was captured" {
    var scene = try Scene.init();
    defer scene.deinit();
    var snapshot: pane.Snapshot = .{ .base = 0, .count = 2 };
    @memset(snapshot.bytes[0 .. 2 * pane.per_row], 'A');
    @memset(snapshot.readable[0 .. 2 * pane.per_row], true);
    try pane.draw(&scene.list, dark, .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = area.h }, &snapshot);
    try std.testing.expectEqual(@as(usize, 0), scene.list.commands.items.len);
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(usize, 2 * (8 + 32 + 16)), scene.glyphs(dark.ink) + scene.glyphs(dark.muted));
}
