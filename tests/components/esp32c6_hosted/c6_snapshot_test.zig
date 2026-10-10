//! RA8EMU-687: the ESP32-C6 saved mid-exchange and loaded into a fresh one
//! matches byte for byte and keeps the fresh one's own pins.
const std = @import("std");
const ra8 = @import("ra8");
const esp_hosted = ra8.components.esp_hosted;
const gpio = ra8.chip.periph.gpio;
const file = ra8.snapshot.file;
const section = ra8.components.c6_snapshot;

const Stand = struct { c6: esp_hosted.C6 };

fn fresh() Stand {
    var board: Stand = .{ .c6 = .{} };
    @memset(&board.c6.wire.rx, 0);
    @memset(&board.c6.wire.tx, 0);
    for (&board.c6.wire.queue.slots) |*slot| @memset(slot, 0);
    return board;
}

fn fill(board: *Stand) void {
    board.c6.reply = .{0x5A};
    board.c6.wire.rx[0] = 0x01;
    board.c6.wire.tx[2] = 0x7E;
    board.c6.wire.offset = 9;
    board.c6.wire.caps_seen = true;
    board.c6.wire.caps_len = 3;
    board.c6.wire.caps[1] = 0x44;
    board.c6.wire.boot_queued = true;
    board.c6.wire.boots_sent = 2;
    board.c6.wire.queue.slots[1][0] = 0x33;
    board.c6.wire.queue.head = 1;
    board.c6.wire.queue.len = 1;
    board.c6.wire.replies_sent = 6;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try section.save(board, &list.writer);
}

test "a C6 mid-exchange round-trips byte for byte" {
    var board = fresh();
    fill(&board);
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try saved(&board, &first);

    var target = fresh();
    try section.load(&target, first.written());
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try saved(&target, &second);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    try std.testing.expectEqual(@as(u8, 0x33), target.c6.wire.queue.slots[1][0]);
    try std.testing.expectEqual(@as(u32, 6), target.c6.wire.replies_sent);
}

test "the target keeps its own pins and a bad queue is refused" {
    var board = fresh();
    fill(&board);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);

    var pins: gpio.Gpio = undefined;
    var target = fresh();
    target.c6.pins = &pins;
    try section.load(&target, bytes.written());
    try std.testing.expect(target.c6.pins == &pins);

    board.c6.wire.queue.len = board.c6.wire.queue.slots.len + 1;
    bytes.clearRetainingCapacity();
    try saved(&board, &bytes);
    var other = fresh();
    try std.testing.expectError(error.BadValue, section.load(&other, bytes.written()));
    try std.testing.expectEqual(@as(u32, 0), other.c6.wire.replies_sent);
}

test "a missing or short section leaves the C6 alone" {
    var header = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer header.deinit();
    try file.writeHeader(&header.writer);
    var target = fresh();
    try std.testing.expectError(error.Missing, section.load(&target, header.written()));

    var board = fresh();
    fill(&board);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);
    try std.testing.expect(std.meta.isError(section.load(&target, bytes.written()[0 .. bytes.written().len - 3])));
    try std.testing.expectEqual(@as(u32, 0), target.c6.wire.boots_sent);
}

fn fakeLookup(_: ?*anyopaque, _: ?std.Io, _: []const u8, _: *[esp_hosted.dns.max_answers][4]u8) !u8 {
    return 0;
}

test "snapshot failure preserves the live bridge and success resets it" {
    var board = fresh();
    fill(&board);
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);

    var target = fresh();
    target.c6.wire.bridge.resolver.lookupFn = fakeLookup;
    try std.testing.expect(std.meta.isError(section.load(&target, bytes.written()[0 .. bytes.written().len - 1])));
    try std.testing.expect(target.c6.wire.bridge.resolver.lookupFn == fakeLookup);
    try section.load(&target, bytes.written());
    try std.testing.expect(target.c6.wire.bridge.resolver.lookupFn != fakeLookup);
}
