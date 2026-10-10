//! RA8EMU-663: the SCI unit saved busy and loaded into a fresh one matches
//! on every saved field and keeps the fresh unit's own wiring.
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.chip.periph.sci;
const file = ra8.snapshot.file;
const serial = ra8.chip.periph.sci_snapshot;

const Stand = struct { serial: sci.Sci = .{} };

var answer: [1]u8 = .{0x5A};

fn echo(_: *anyopaque, _: u8) []const u8 {
    return answer[0..];
}

fn write(_: ?*anyopaque, _: []const u8) anyerror!void {}

fn busy() Stand {
    var board: Stand = .{};
    board.serial.channels[3].control = 0x30;
    board.serial.channels[3].transmitted = 41;
    board.serial.channels[3].receive("hi");
    board.serial.channels[3].errors.raiseOverrun();
    board.serial.channels[9].lin.breaks = 2;
    board.serial.channels[9].ccr3 = 0x1000;
    board.serial.line.pending[0] = 'o';
    board.serial.line.pending_len = 1;
    board.serial.line.lines = 7;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try serial.save(board, &list.writer);
}

test "every saved field round-trips and the fresh unit keeps its wiring" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{};
    var context: u8 = 0;
    fresh.serial.attachDevice(0, .{ .context = &context, .feedFn = echo, .spi_only = true });
    fresh.serial.line.setSink(.{ .writeFn = write });
    try serial.load(&fresh, list.written());
    try std.testing.expect(fresh.serial.channels[0].device.?.context == @as(*anyopaque, &context));
    try std.testing.expect(fresh.serial.line.sink != null);
    var again = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer again.deinit();
    try saved(&fresh, &again);
    try std.testing.expectEqualSlices(u8, list.written(), again.written());
    try std.testing.expectEqual(@as(?u8, 'h'), fresh.serial.channels[3].rx.pop());
}

test "a ring or line index past its buffer is BadValue and nothing changes" {
    var board = busy();
    board.serial.channels[5].rx.head = sci.limits.rx_queue;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{};
    try std.testing.expectError(error.BadValue, serial.load(&fresh, list.written()));
    try std.testing.expectEqual(@as(u32, 0), fresh.serial.channels[3].transmitted);
    board = busy();
    board.serial.line.last_len = board.serial.line.last.len + 1;
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expectError(error.BadValue, serial.load(&fresh, list.written()));
    try std.testing.expectEqual(@as(u32, 0), fresh.serial.line.lines);
}

test "a missing section or a cut payload leaves the unit untouched" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var fresh: Stand = .{};
    fresh.serial.channels[1].received = 9;
    try std.testing.expectError(error.Missing, serial.load(&fresh, list.written()));
    const board = busy();
    list.clearRetainingCapacity();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 1];
    const result = serial.load(&fresh, cut);
    try std.testing.expect(std.meta.isError(result));
    try std.testing.expectEqual(@as(u32, 9), fresh.serial.channels[1].received);
}
