//! RA8EMU-681: SSIE and SPI, whose wiring sits in their channel arrays,
//! saved with non-default state and loaded into fresh units, compare equal;
//! the target keeps its own wiring; a missing or short section changes
//! nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const channels = ra8.chip.snapshot.channels;

fn Unit(comptime name: []const u8) type {
    return @FieldType(Board, name);
}

const Listener = @typeInfo(@FieldType(@typeInfo(@FieldType(Unit("audio"), "channels")).array.child, "listener")).optional.child;
const Device = @typeInfo(@FieldType(@typeInfo(@FieldType(Unit("spi"), "channels")).array.child, "device")).optional.child;

var context_a: u8 = 0;
var context_b: u8 = 0;

fn heard(context: *anyopaque, word: u32) void {
    _ = context;
    _ = word;
}

fn echo(context: *anyopaque, byte: u8) u8 {
    _ = context;
    return byte;
}

/// The Board's audio and SPI fields, under the Board's names.
const Stand = struct {
    audio: Unit("audio") = Unit("audio").init(),
    spi: Unit("spi") = Unit("spi").init(),

    fn wiredTo(context: *u8) Stand {
        var stand: Stand = .{};
        stand.audio.channels[0].listener = Listener{ .context = context, .sample = heard };
        stand.spi.channels[1].device = Device{ .context = context, .exchangeFn = echo };
        return stand;
    }
};

fn busy() Stand {
    var board = Stand.wiredTo(&context_a);
    board.audio.channels[0].ssicr = 0x0000_0303;
    board.audio.channels[1].transmitted = 12;
    board.spi.channels[1].spcr = 0x48;
    board.spi.channels[0].frames = 6;
    board.spi.channels[1].width = 16;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try channels.save(board, &list.writer);
}

test "SSIE and SPI round-trip" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.wiredTo(&context_a);
    try channels.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a load keeps the target's wiring" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target: Stand = .{};
    target.spi.channels[0].device = Device{ .context = &context_b, .exchangeFn = echo };
    try channels.load(&target, list.written());
    try std.testing.expectEqual(@as(u32, 12), target.audio.channels[1].transmitted);
    try std.testing.expect(target.audio.channels[0].listener == null);
    try std.testing.expect(target.spi.channels[1].device == null);
    try std.testing.expect(target.spi.channels[0].device.?.context == @as(*anyopaque, &context_b));
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target = Stand.wiredTo(&context_b);
    try std.testing.expectError(error.Missing, channels.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 3];
    try std.testing.expect(std.meta.isError(channels.load(&target, cut)));
    try std.testing.expectEqualDeep(Stand.wiredTo(&context_b), target);
}
