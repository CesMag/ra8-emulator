//! RA8EMU-667: the DRW engine saved busy and loaded into a fresh one
//! matches byte for byte and keeps the fresh engine's own domain.
const std = @import("std");
const ra8 = @import("ra8");
const drw = ra8.chip.periph.drw;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const file = ra8.snapshot.file;
const raster = ra8.chip.periph.drw_snapshot;

const Stand = struct { raster: drw.Drw };

fn guard() prcr.Prcr {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return unit;
}

fn busy(domain: *const pdctr.Pdctr) Stand {
    var board: Stand = .{ .raster = drw.Drw.init(domain) };
    board.raster.control = 0x11;
    board.raster.pitch = 0x0400_0400;
    board.raster.renders = 7;
    board.raster.pixels = 1 << 20;
    board.raster.texture.texpitch = 512;
    board.raster.limits.edges[1].xadd = -3;
    board.raster.pixel_cache.enabled = true;
    board.raster.pixel_cache.used = 0;
    board.raster.last_decline = .unpowered;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try raster.save(board, &list.writer);
}

test "a busy engine round-trips and the fresh one keeps its domain" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var other = pdctr.Pdctr.init(&lock, .graphics);
    const board = busy(&domain);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{ .raster = drw.Drw.init(&other) };
    try raster.load(&fresh, list.written());
    try std.testing.expect(fresh.raster.domain == &other);
    try std.testing.expectEqual(@as(u32, 7), fresh.raster.renders);
    try std.testing.expectEqual(@as(i32, -3), fresh.raster.limits.edges[1].xadd);
    var again = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer again.deinit();
    try saved(&fresh, &again);
    try std.testing.expectEqualSlices(u8, list.written(), again.written());
}

test "a pixel cache count past its cells is BadValue and nothing changes" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var board = busy(&domain);
    board.raster.pixel_cache.used = board.raster.pixel_cache.cells.len + 1;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{ .raster = drw.Drw.init(&domain) };
    try std.testing.expectError(error.BadValue, raster.load(&fresh, list.written()));
    try std.testing.expectEqual(@as(u32, 0), fresh.raster.renders);
}

test "a missing section or a cut payload leaves the engine untouched" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var fresh: Stand = .{ .raster = drw.Drw.init(&domain) };
    fresh.raster.faults = 9;
    try std.testing.expectError(error.Missing, raster.load(&fresh, list.written()));
    const board = busy(&domain);
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expect(std.meta.isError(raster.load(&fresh, list.written()[0 .. list.written().len - 1])));
    try std.testing.expectEqual(@as(u32, 9), fresh.raster.faults);
}
