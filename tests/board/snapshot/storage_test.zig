//! RA8EMU-674: the option MRAM and the xSPI flash saved with non-default
//! state and written contents load back into fresh units that save the same
//! bytes, numbers outside a part or out of order are refused, and a missing
//! or short section changes nothing and leaves nothing allocated.
const std = @import("std");
const ra8 = @import("ra8");
const Board = ra8.board.board.Board;
const file = ra8.snapshot.file;
const storage = ra8.board.snapshot.storage;
const allocator = std.testing.allocator;

const Options = @FieldType(Board, "options");
const Flash = @FieldType(Board, "flash");
const Nor = @FieldType(Board, "nor");

/// The Board's sparse memories, under the Board's names.
const Stand = struct {
    options: Options,
    flash: Flash,
    nor: Nor,

    fn init() Stand {
        return .{ .options = Options.init(allocator), .flash = .{}, .nor = Nor.init(allocator) };
    }

    fn deinit(self: *Stand) void {
        self.options.deinit();
        self.nor.deinit();
    }
};

const cell = 0x02E0_7610;

fn busy() !Stand {
    var board = Stand.init();
    errdefer board.deinit();
    try board.options.otp.program(cell, &.{ 0x12, 0x34, 0x56, 0x78 });
    board.options.shadow[2] = 0xCAFE;
    board.options.stream.len = 4;
    board.options.locked = true;
    board.options.programs = 3;
    try board.nor.program(0x2000, 0x0F);
    try board.nor.program(0x10_0004, 0xA5);
    board.flash.shadow[1] = 0x55;
    board.flash.write_enabled = true;
    board.flash.erases = 2;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try storage.save(board, &list.writer);
}

test "both memories round-trip with their contents" {
    var board = try busy();
    defer board.deinit();
    var list = std.Io.Writer.Allocating.init(allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.init();
    defer target.deinit();
    try storage.load(&target, list.written());
    var again = std.Io.Writer.Allocating.init(allocator);
    defer again.deinit();
    try saved(&target, &again);
    try std.testing.expectEqualSlices(u8, list.written(), again.written());
    try std.testing.expectEqual(@as(u8, 0x34), target.options.otp.byte(cell + 1));
    try std.testing.expectEqual(@as(u8, 0xA5), target.nor.byte(0x10_0004));
    try std.testing.expectEqual(@as(u32, 2), target.nor.live());
    try std.testing.expect(target.options.locked);
}

test "a different configured flash capacity is refused" {
    var board = try busy();
    defer board.deinit();
    var list = std.Io.Writer.Allocating.init(allocator);
    defer list.deinit();
    try saved(&board, &list);
    var target = Stand.init();
    defer target.deinit();
    try target.nor.resize(32 * 1024 * 1024);
    try std.testing.expectError(error.BadValue, storage.load(&target, list.written()));
    try std.testing.expectEqual(@as(u32, 0), target.nor.live());
}

test "a sector past the part is refused" {
    var board = try busy();
    defer board.deinit();
    var list = std.Io.Writer.Allocating.init(allocator);
    defer list.deinit();
    try saved(&board, &list);
    // The last sector entry's number sits 4 KiB + 4 bytes from the end.
    const at = list.written().len - 4 - 0x1000;
    std.mem.writeInt(u32, list.written()[at..][0..4], 0xFFFF, .little);
    var target = Stand.init();
    defer target.deinit();
    try std.testing.expectError(error.BadValue, storage.load(&target, list.written()));
    try std.testing.expectEqual(@as(u32, 0), target.nor.live());
    try std.testing.expect(!target.options.locked);
}

test "a missing or short section changes nothing" {
    var list = std.Io.Writer.Allocating.init(allocator);
    defer list.deinit();
    try file.writeHeader(&list.writer);
    var target = Stand.init();
    defer target.deinit();
    try std.testing.expectError(error.Missing, storage.load(&target, list.written()));
    list.clearRetainingCapacity();
    var board = try busy();
    defer board.deinit();
    try saved(&board, &list);
    const cut = list.written()[0 .. list.written().len - 1];
    try std.testing.expect(std.meta.isError(storage.load(&target, cut)));
    try std.testing.expectEqual(@as(u32, 0), target.options.otp.live());
    try std.testing.expectEqual(@as(u32, 0), target.nor.live());
}
