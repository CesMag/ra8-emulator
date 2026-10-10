//! RA8EMU-682: the board's USB side saved mid-command and loaded into a
//! fresh one compares equal, with the MSC cursors rebuilt over the target's
//! own buffers; the target keeps its own wiring; a missing or short section,
//! or a cursor the target cannot hold, changes nothing.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const usb = ra8.board.snapshot.usb;

const Usb = @FieldType(Board, "usb");
const Hook = @typeInfo(@FieldType(Usb, "bridge")).optional.child;
const Device = @FieldType(Usb, "device");
const Script = @FieldType(Usb, "script");

var disk_a: [2048]u8 = @splat(0x5A);
var disk_b: [2048]u8 = @splat(0x5A);
var context: u8 = 0;

fn poll(ctx: *anyopaque, device: *Device, host: *const Script) void {
    _ = ctx;
    _ = device;
    _ = host;
}

/// The Board's USB field, under the Board's name.
const Stand = struct {
    usb: Usb = .{},

    fn on(disk: []u8) Stand {
        var stand: Stand = .{};
        stand.usb.stick.disk = disk;
        return stand;
    }
};

/// Fills `board` in place: the MSC cursor points into its own scratch, so
/// the stand must not move afterwards.
fn fill(board: *Stand) void {
    board.* = Stand.on(&disk_a);
    board.usb.host.misaligned = 3;
    board.usb.host.xfer.setups = 5;
    board.usb.device.status = 0x12;
    board.usb.script.waited = 7;
    const storage = &board.usb.stick;
    storage.phase = .data_in;
    storage.tag = 0xCAFE;
    storage.commands = 4;
    for (&storage.scratch, 0..) |*byte, i| byte.* = @intCast(i);
    storage.data = storage.scratch[2..10];
    storage.sink = disk_a[512..1024];
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try usb.save(board, &list.writer);
}

test "the USB side round-trips mid-command" {
    var board: Stand = undefined;
    fill(&board);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.on(&disk_a);
    try usb.load(&target, list.written());
    try std.testing.expectEqualDeep(board, target);
    const storage = &target.usb.stick;
    try std.testing.expect(storage.data.ptr == @as([*]const u8, &storage.scratch) + 2);
    try std.testing.expect(storage.sink.ptr == @as([*]u8, &disk_a) + 512);
}

test "a load keeps the target's wiring" {
    var board: Stand = undefined;
    fill(&board);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.on(&disk_b);
    target.usb.bridge = Hook{ .context = &context, .pollFn = poll };
    try usb.load(&target, list.written());
    const storage = &target.usb.stick;
    try std.testing.expectEqual(@as(u32, 5), target.usb.host.xfer.setups);
    try std.testing.expect(storage.disk.ptr == @as([*]u8, &disk_b));
    try std.testing.expect(storage.sink.ptr == @as([*]u8, &disk_b) + 512);
    try std.testing.expect(target.usb.bridge.?.context == @as(*anyopaque, &context));
    try std.testing.expect(target.usb.cable == null);
}

test "a missing, short or unplaceable section changes nothing" {
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target = Stand.on(&disk_b);
    try std.testing.expectError(error.Missing, usb.load(&target, list.written()));
    list.clearRetainingCapacity();
    var board: Stand = undefined;
    fill(&board);
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 3];
    try std.testing.expect(std.meta.isError(usb.load(&target, cut)));
    try std.testing.expectEqualDeep(Stand.on(&disk_b), target);
    var diskless: Stand = .{};
    try std.testing.expectError(error.BadValue, usb.load(&diskless, list.written()));
    try std.testing.expectEqualDeep(Stand{}, diskless);
}
