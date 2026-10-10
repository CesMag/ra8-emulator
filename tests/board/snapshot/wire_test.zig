//! RA8EMU-666: the I2C wire saved busy and loaded into a fresh one matches
//! byte for byte and keeps the fresh wire's own device registries.
const std = @import("std");
const ra8 = @import("ra8");
const i2c = ra8.board.i2c;
const file = ra8.snapshot.file;
const wire = ra8.board.snapshot.wire;

const Stand = struct { wire: i2c.Wire = .{} };

fn busy() Stand {
    var board: Stand = .{};
    board.wire.controller.channels[0].transfers = 5;
    board.wire.controller.channels[1].status = 0x40;
    board.wire.controller.devices.held_low = true;
    board.wire.touchline.transfers = 3;
    board.wire.touchline.staged_len = 2;
    board.wire.touchline.served = 1;
    board.wire.expander.writes = 2;
    board.wire.sensor.format = 0x30;
    board.wire.panel.queued_len = 1;
    board.wire.panel.reported = 4;
    board.wire.imu.reads = 6;
    board.wire.gauge.battery.soc_pct = 40;
    board.wire.gauge.high = 0x12;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try wire.save(board, &list.writer);
}

test "a busy wire round-trips and the fresh wire keeps its registries" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{};
    try fresh.wire.controller.attachDevice(fresh.wire.expander.device());
    try wire.load(&fresh, list.written());
    try std.testing.expect(fresh.wire.controller.devices.devices[0] != null);
    try std.testing.expect(fresh.wire.controller.devices.held_low);
    var again = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer again.deinit();
    try saved(&fresh, &again);
    try std.testing.expectEqualSlices(u8, list.written(), again.written());
    try std.testing.expectEqual(@as(u8, 40), fresh.wire.gauge.battery.soc_pct);
}

test "a stage or queue index past its buffer is BadValue and nothing changes" {
    var board = busy();
    board.wire.touchline.staged_len = board.wire.touchline.staged.len + 1;
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var fresh: Stand = .{};
    try std.testing.expectError(error.BadValue, wire.load(&fresh, list.written()));
    board = busy();
    board.wire.panel.queued_pos = board.wire.panel.queued_len + 1;
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expectError(error.BadValue, wire.load(&fresh, list.written()));
    try std.testing.expectEqual(@as(u32, 0), fresh.wire.touchline.transfers);
}

test "a missing section or a cut payload leaves the wire untouched" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var fresh: Stand = .{};
    fresh.wire.imu.writes = 9;
    try std.testing.expectError(error.Missing, wire.load(&fresh, list.written()));
    const board = busy();
    list.clearRetainingCapacity();
    try saved(&board, &list);
    try std.testing.expect(std.meta.isError(wire.load(&fresh, list.written()[0 .. list.written().len - 1])));
    try std.testing.expectEqual(@as(u32, 9), fresh.wire.imu.writes);
}
