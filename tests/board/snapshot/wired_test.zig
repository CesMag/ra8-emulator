//! RA8EMU-679: the media and comms units with top-level wiring, saved with
//! non-default state and loaded into fresh units, compare equal; the target
//! keeps its own wiring; a missing or short section changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const wired = ra8.board.snapshot.wired;

fn Unit(comptime name: []const u8) type {
    return @FieldType(Board, name);
}

var guard_a = Unit("protection").init();
var guard_b = Unit("protection").init();

/// The Board's wired media and comms fields, under the Board's names.
const Stand = struct {
    capture: Unit("capture"),
    mailbox: Unit("mailbox"),
    modem: Unit("modem"),
    trace: Unit("trace"),
    domains: Unit("domains"),

    fn wiredTo(guard: anytype) Stand {
        var stand: Stand = .{
            .capture = Unit("capture").init(),
            .mailbox = Unit("mailbox").init(),
            .modem = .{},
            .trace = .{},
            .domains = Unit("domains").init(guard),
        };
        stand.mailbox.attrib.protection = guard;
        return stand;
    }
};

fn busy() Stand {
    var board = Stand.wiredTo(&guard_a);
    board.capture.frames = 3;
    board.capture.last_width = 320;
    board.capture.last_decline = @fromBackingInt(@intCast(0));
    board.mailbox.wakes = 2;
    board.mailbox.attrib.sar = 0x55;
    board.modem.answered = 4;
    board.modem.len = 2;
    board.trace.ticks = 9;
    board.trace.found = 0x2000_0100;
    board.domains.graphics.power_ons = 1;
    board.domains.eswm.power_offs = 5;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try wired.save(board, &list.writer);
}

test "every wired media and comms unit round-trips" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.wiredTo(&guard_a);
    try wired.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
}

test "a load keeps the target's wiring" {
    const board = busy();
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.wiredTo(&guard_b);
    try wired.load(&target, list.written());
    try std.testing.expectEqual(@as(u32, 3), target.capture.frames);
    try std.testing.expect(target.domains.graphics.protection == &guard_b);
    try std.testing.expect(target.domains.eswm.protection == &guard_b);
    try std.testing.expect(target.mailbox.attrib.protection.? == &guard_b);
    try std.testing.expect(target.trace.memory == null);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target = Stand.wiredTo(&guard_b);
    try std.testing.expectError(error.Missing, wired.load(&target, list.written()));
    list.clearRetainingCapacity();
    const board = busy();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 3];
    try std.testing.expect(std.meta.isError(wired.load(&target, cut)));
    try std.testing.expectEqualDeep(Stand.wiredTo(&guard_b), target);
}
