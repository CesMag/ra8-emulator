//! RA8EMU-668: the GLCDC saved busy and loaded into a fresh one matches
//! byte for byte and keeps the fresh controller's domain and vsync hook.
const std = @import("std");
const ra8 = @import("ra8");
const glcdc = ra8.chip.periph.glcdc;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const file = ra8.snapshot.file;
const display = ra8.chip.periph.glcdc_snapshot;

const Stand = struct { display: glcdc.Glcdc };

fn guard() prcr.Prcr {
    var unit = prcr.Prcr.init();
    unit.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    return unit;
}

fn busy(domain: *const pdctr.Pdctr) Stand {
    var board: Stand = .{ .display = glcdc.Glcdc.init(domain) };
    board.display.registers[3] = 0xDEAD_BEEF;
    board.display.palettes[1].store(0, 7, 0xFF11_2233);
    board.display.palettes[1].selected = 1;
    board.display.blends[0].base_colour = 0x0055_AA00;
    board.display.output.commits = 4;
    board.display.output.gamma_on = true;
    board.display.timing.h_active = 1024;
    board.display.system.frames = 60;
    board.display.starts = 2;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try display.save(board, &list.writer);
}

var frames: u32 = 0;
fn onFrame(context: *anyopaque, when_ns: u64) void {
    _ = context;
    _ = when_ns;
    frames += 1;
}

test "a busy controller round-trips and the fresh one keeps its wiring" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var other = pdctr.Pdctr.init(&lock, .graphics);
    const board = busy(&domain);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{ .display = glcdc.Glcdc.init(&other) };
    fresh.display.output.vsync = .{ .sink = .{ .context = &other, .frame = onFrame } };
    try display.load(&fresh, list.written());
    try std.testing.expect(fresh.display.domain == &other);
    try std.testing.expect(fresh.display.output.vsync != null);
    try std.testing.expectEqual(@as(u32, 0xFF11_2233), fresh.display.palettes[1].planes[0][7]);
    try std.testing.expectEqual(@as(u32, 1024), fresh.display.timing.h_active);
    var again = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer again.deinit();
    try saved(&fresh, &again);
    try std.testing.expectEqualSlices(u8, list.written(), again.written());
}

test "a palette plane or filled count out of range is BadValue and nothing changes" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var board = busy(&domain);
    board.display.palettes[0].selected = 2;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{ .display = glcdc.Glcdc.init(&domain) };
    try std.testing.expectError(error.BadValue, display.load(&fresh, list.written()));
    board.display.palettes[0].selected = 0;
    board.display.palettes[0].filled[1] = 257;
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expectError(error.BadValue, display.load(&fresh, list.written()));
    try std.testing.expectEqual(@as(u32, 0), fresh.display.starts);
}

test "a missing section or a cut payload leaves the controller untouched" {
    const lock = guard();
    var domain = pdctr.Pdctr.init(&lock, .graphics);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var fresh: Stand = .{ .display = glcdc.Glcdc.init(&domain) };
    fresh.display.latches = 9;
    try std.testing.expectError(error.Missing, display.load(&fresh, list.written()));
    const board = busy(&domain);
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expect(std.meta.isError(display.load(&fresh, list.written()[0 .. list.written().len - 1])));
    try std.testing.expectEqual(@as(u32, 9), fresh.display.latches);
}
