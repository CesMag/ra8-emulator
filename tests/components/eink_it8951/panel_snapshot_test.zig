//! RA8EMU-669: the e-paper panel saved with pixels on both planes and
//! loaded into a fresh one matches byte for byte, keeps the fresh panel's
//! refresh hook, and leaks nothing.
const std = @import("std");
const ra8 = @import("ra8");
const eink = ra8.components.eink;
const file = ra8.snapshot.file;
const panel = ra8.components.panel_snapshot;

const Stand = struct { panel: eink.Panel };

fn fresh(width: u16, height: u16) Stand {
    var board: Stand = .{ .panel = eink.Panel.init() };
    board.panel.planes.allocator = std.testing.allocator;
    board.panel.planes.geometry = .{ .width = width, .height = height };
    return board;
}

fn busy() Stand {
    var board = fresh(4, 3);
    _ = board.panel.planes.ready();
    board.panel.planes.image.set(1, 2, 0xA0);
    board.panel.planes.glass.set(3, 0, 0x5F);
    board.panel.vcom_mv = 1500;
    board.panel.register_count = 2;
    board.panel.refreshes = 6;
    board.panel.data_index = 70_000;
    board.panel.display_args[4] = 2;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try panel.save(board, &list.writer);
}

var repaints: u32 = 0;
fn repaint(context: *anyopaque) void {
    _ = context;
    repaints += 1;
}

test "a panel with pixels round-trips, keeps its hook, and leaks nothing" {
    var board = busy();
    defer board.panel.deinit();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = fresh(2, 2);
    defer target.panel.deinit();
    _ = target.panel.planes.ready();
    target.panel.refresh_hook = .{ .context = &target, .refreshFn = repaint };
    try panel.load(&target, list.written());
    try std.testing.expect(target.panel.refresh_hook != null);
    try std.testing.expectEqual(@as(u8, 0xA0), target.panel.planes.image.pixel(1, 2));
    try std.testing.expectEqual(@as(u8, 0x5F), target.panel.planes.glass.pixel(3, 0));
    try std.testing.expectEqual(@as(u16, 1500), target.panel.vcom_mv);
    try std.testing.expectEqual(@as(u32, 70_000), target.panel.data_index);
    var again = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer again.deinit();
    try saved(&target, &again);
    try std.testing.expectEqualSlices(u8, list.written(), again.written());
}

test "a plane that misses the geometry or a register count past the slots is BadValue" {
    var board = busy();
    defer board.panel.deinit();
    var target = fresh(2, 2);
    defer target.panel.deinit();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    board.panel.planes.geometry = .{ .width = 5, .height = 3 };
    try saved(&board, &list);
    try std.testing.expectError(error.BadValue, panel.load(&target, list.written()));
    board.panel.planes.geometry = .{ .width = 4, .height = 3 };
    board.panel.register_count = board.panel.registers.len + 1;
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expectError(error.BadValue, panel.load(&target, list.written()));
    try std.testing.expectEqual(@as(u32, 0), target.panel.refreshes);
    try std.testing.expectEqual(@as(u16, 2), target.panel.planes.geometry.width);
}

test "a missing section or a cut payload leaves the panel untouched" {
    var target = fresh(2, 2);
    defer target.panel.deinit();
    target.panel.stray = 9;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    try std.testing.expectError(error.Missing, panel.load(&target, list.written()));
    var board = busy();
    defer board.panel.deinit();
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expect(std.meta.isError(panel.load(&target, list.written()[0 .. list.written().len - 1])));
    try std.testing.expectEqual(@as(u32, 9), target.panel.stray);
}
