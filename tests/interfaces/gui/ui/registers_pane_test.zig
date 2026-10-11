//! Covers src/interfaces/gui/ui/registers_pane.zig (RA8EMU-741, groups RA8EMU-945):
//! headers and cells run down a column and then across, a folded group
//! keeps only its header, the pane rasterises to pinned golden frames open
//! with the system group folded and with
//! the fpu group folded to its header, an MVE core draws q0-q7 as lanes of
//! the S bank after VPR, expanded and folded (RA8EMU-947), a changed
//! register is the only text
//! drawn in the changed colour, and a pane too small for one cell draws
//! nothing.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const api = ra8.session.api;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const pane = gui_app.registers_pane;

const Rect = draw_list.Rect;
/// Eight rows down, eight columns across: room for the core, system and
/// fpu headers and their 58 registers.
const area = Rect{ .x = 0, .y = 0, .w = 2 * pane.pad + 8 * 120, .h = 2 * pane.pad + 8 * pane.row_h };
/// Twelve columns across: room for all four headers and every cell.
const wide = Rect{ .x = 0, .y = 0, .w = 2 * pane.pad + 12 * 120, .h = area.h };
const system_folded: pane.Fold = .{ false, true, false, false };
const fpu_folded: pane.Fold = .{ false, false, true, false };
const mve_folded: pane.Fold = .{ false, false, false, true };

/// Where register `name` sits in the pane.
fn named(name: []const u8) usize {
    for (pane.names, 0..) |each, index| {
        if (std.mem.eql(u8, each, name)) return index;
    }
    unreachable;
}

fn sample() pane.Snapshot {
    var snapshot: pane.Snapshot = .{};
    for (&snapshot.values, 0..) |*value, index| value.* = 0x1000_0000 + @as(u32, @intCast(index)) * 0x0101;
    return snapshot;
}

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,

    fn init() !Scene {
        return initFor(area);
    }

    fn initFor(rect: Rect) !Scene {
        const w: u32 = @intCast(rect.w);
        const h: u32 = @intCast(rect.h);
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, w, h), .frame = try raster.Framebuffer.init(std.testing.allocator, w, h) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, now: pane.Snapshot, before: ?pane.Snapshot, fold: pane.Fold) !void {
        try self.renderIn(area, now, before, fold);
    }

    fn renderIn(self: *Scene, rect: Rect, now: pane.Snapshot, before: ?pane.Snapshot, fold: pane.Fold) !void {
        try pane.draw(&self.list, rect, now, before, fold);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
    }
};

test "headers and cells run down a column and then across" {
    try std.testing.expectEqual(@as(usize, 8), pane.rows(area));
    try std.testing.expectEqual(@as(usize, 8), pane.columns(area));
    const core = pane.headerRect(area, pane.open, 0).?;
    try std.testing.expectEqual(pane.pad, core.x);
    try std.testing.expectEqual(pane.pad, core.y);
    const first = pane.cellRect(area, pane.open, 0).?;
    try std.testing.expectEqual(pane.pad, first.x);
    try std.testing.expectEqual(pane.pad + pane.row_h, first.y);
    const eighth = pane.cellRect(area, pane.open, 7).?;
    try std.testing.expectEqual(pane.pad + 120, eighth.x);
    try std.testing.expectEqual(pane.pad, eighth.y);
    const system = pane.headerRect(area, pane.open, 1).?;
    try std.testing.expectEqual(pane.pad + 2 * 120, system.x);
    try std.testing.expectEqual(pane.pad + 2 * pane.row_h, system.y);
    const fpu = pane.headerRect(area, pane.open, 2).?;
    try std.testing.expectEqual(pane.pad + 3 * 120, fpu.x);
    try std.testing.expectEqual(pane.pad + 3 * pane.row_h, fpu.y);
    const last = pane.cellRect(area, pane.open, 57).?;
    try std.testing.expectEqual(pane.pad + 7 * 120, last.x);
    try std.testing.expectEqual(pane.pad + 4 * pane.row_h, last.y);
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, pane.open, pane.cells));
}

test "a folded group keeps only its header, and the next group moves up" {
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, system_folded, 17));
    try std.testing.expectEqual(pane.headerRect(area, pane.open, 1), pane.headerRect(area, system_folded, 1));
    const core_folded: pane.Fold = .{ true, false, false, false };
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, core_folded, 0));
    try std.testing.expectEqual(pane.pad + pane.row_h, pane.headerRect(area, core_folded, 1).?.y);
    try std.testing.expectEqual(pane.pad + 2 * pane.row_h, pane.cellRect(area, core_folded, 17).?.y);
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, fpu_folded, 25));
    try std.testing.expectEqual(@as(?Rect, null), pane.cellRect(area, fpu_folded, 57));
    try std.testing.expectEqual(pane.headerRect(area, pane.open, 2), pane.headerRect(area, fpu_folded, 2));
}

test "a press finds a group header and nothing on a cell" {
    const header = pane.headerRect(area, pane.open, 1).?;
    try std.testing.expectEqual(@as(?usize, 1), pane.headerAt(area, pane.open, false, header.x + 1, header.y + 1));
    const cell = pane.cellRect(area, pane.open, 0).?;
    try std.testing.expectEqual(@as(?usize, null), pane.headerAt(area, pane.open, false, cell.x + 1, cell.y + 1));
}

test "the pane rasterises to the pinned golden frame with every group open" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(sample(), sample(), pane.open);
    try std.testing.expectEqual(@as(u64, 4969007086328797543), scene.digest());
}

test "the pane rasterises to the pinned golden frame with the system group folded" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(sample(), sample(), system_folded);
    try std.testing.expectEqual(@as(u64, 15679738979028817615), scene.digest());
}

test "the pane rasterises to the pinned golden frame with the fpu group folded to its header" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(sample(), sample(), fpu_folded);
    try std.testing.expectEqual(@as(u64, 10667715961952123429), scene.digest());
}

test "the MVE group is VPR, then q0-q7 as four lanes each, read from the S bank" {
    const s0 = named("s0");
    const vpr = named("vpr");
    try std.testing.expectEqual(pane.groups[3].first, vpr);
    try std.testing.expectEqualStrings("vpr", pane.label(vpr));
    try std.testing.expectEqualStrings("q0[0]", pane.label(pane.names.len));
    try std.testing.expectEqualStrings("q1[0]", pane.label(pane.names.len + 4));
    try std.testing.expectEqualStrings("q7[3]", pane.label(pane.cells - 1));
    try std.testing.expectEqual(s0 + 4, pane.valueIndex(pane.names.len + 4));
    try std.testing.expectEqual(s0 + 31, pane.valueIndex(pane.cells - 1));
    try std.testing.expect(pane.hasMve(api.Core.cpu0));
    try std.testing.expect(!pane.hasMve(api.Core.cpu1));
}

test "an MVE header is found only on an MVE core" {
    const header = pane.headerRect(wide, pane.open, 3).?;
    try std.testing.expectEqual(@as(?usize, 3), pane.headerAt(wide, pane.open, true, header.x + 1, header.y + 1));
    try std.testing.expectEqual(@as(?usize, null), pane.headerAt(wide, pane.open, false, header.x + 1, header.y + 1));
}

test "the pane rasterises to the pinned golden frame with the MVE group open" {
    var scene = try Scene.initFor(wide);
    defer scene.deinit();
    var now = sample();
    now.mve = true;
    try scene.renderIn(wide, now, now, pane.open);
    try std.testing.expectEqual(@as(u64, 9925232080576388107), scene.digest());
}

test "the pane rasterises to the pinned golden frame with the MVE group folded to its header" {
    var scene = try Scene.initFor(wide);
    defer scene.deinit();
    var now = sample();
    now.mve = true;
    try scene.renderIn(wide, now, now, mve_folded);
    try std.testing.expectEqual(@as(u64, 8090772449662505419), scene.digest());
}

test "a changed S register marks its q lane too" {
    var scene = try Scene.initFor(wide);
    defer scene.deinit();
    var before = sample();
    before.mve = true;
    var now = before;
    const s5 = named("s5");
    now.values[s5] +%= 1;
    try scene.renderIn(wide, now, before, pane.open);
    const lane = pane.cellRect(wide, pane.open, pane.names.len + 5).?;
    const at = pane.valueOrigin(lane);
    var hits: usize = 0;
    for (0..@intCast(font.cell_h)) |dy| for (0..@intCast(font.textWidth(8))) |dx| {
        const x = at.x + @as(i32, @intCast(dx));
        const y = at.y + @as(i32, @intCast(dy));
        if (std.meta.eql(scene.frame.at(@intCast(x), @intCast(y)), pane.changed)) hits += 1;
    };
    try std.testing.expect(hits > 0);
}

test "a changed register is the only text in the changed colour" {
    var scene = try Scene.init();
    defer scene.deinit();
    var now = sample();
    now.values[1] +%= 1;
    now.values[19] +%= 2;
    try scene.render(now, sample(), pane.open);
    var moved: usize = 0;
    for (scene.list.commands.items) |command| {
        if (command.shape == .glyph and std.meta.eql(command.shape.glyph.color, pane.changed)) moved += 1;
    }
    try std.testing.expectEqual(@as(usize, 16), moved);
    for (0..scene.frame.height) |y| {
        for (0..scene.frame.width) |x| {
            if (!std.meta.eql(scene.frame.at(@intCast(x), @intCast(y)), pane.changed)) continue;
            try std.testing.expect(inValue(1, x, y) or inValue(19, x, y));
        }
    }
}

fn inValue(index: usize, x: usize, y: usize) bool {
    const at = pane.valueOrigin(pane.cellRect(area, pane.open, index).?);
    const span = Rect{ .x = at.x, .y = at.y, .w = @intCast(font.textWidth(8)), .h = font.glyph_h };
    return span.contains(@intCast(x), @intCast(y));
}

test "no earlier snapshot marks nothing, and a pane too small draws nothing" {
    var scene = try Scene.init();
    defer scene.deinit();
    try scene.render(sample(), null, pane.open);
    for (scene.frame.pixels) |pixel| try std.testing.expect(!std.meta.eql(pixel, pane.changed));
    scene.list.clear();
    try pane.draw(&scene.list, .{ .x = 0, .y = 0, .w = 60, .h = 200 }, sample(), null, pane.open);
    try std.testing.expectEqual(@as(usize, 0), scene.list.commands.items.len);
}
