//! RA8EMU-685: the NPU saved busy and loaded into a fresh one matches byte
//! for byte and keeps the fresh NPU's own memory handle.
const std = @import("std");
const ra8 = @import("ra8");
const npu = ra8.chip.periph.npu;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const file = ra8.snapshot.file;
const section = ra8.chip.periph.npu_snapshot;

const Stand = struct { npu: npu.Npu };

fn busy() Stand {
    var board: Stand = .{ .npu = npu.Npu.init() };
    board.npu.reg[3] = 0xCAFE_0001;
    board.npu.state = 0x0000_0004;
    board.npu.jobs = 5;
    board.npu.moved = 4096;
    board.npu.last_op = .add_constant;
    board.npu.last_bytes = 64;
    board.npu.malformed = 2;
    board.npu.vela.jobs = 3;
    board.npu.vela.moved = 1 << 33;
    board.npu.reads = 11;
    board.npu.due_irq = true;
    return board;
}

fn saved(board: *const Stand, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try section.save(board, &list.writer);
}

test "a busy NPU round-trips byte for byte" {
    const board = busy();
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    try saved(&board, &first);

    var fresh: Stand = .{ .npu = npu.Npu.init() };
    try section.load(&fresh, first.written());
    var second = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer second.deinit();
    try saved(&fresh, &second);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    try std.testing.expectEqual(@as(u64, 1 << 33), fresh.npu.vela.moved);
    try std.testing.expectEqual(ra8.chip.periph.npu_cmd.Op.add_constant, fresh.npu.last_op.?);
    try std.testing.expect(fresh.npu.due_irq);
}

test "the target keeps its own memory handle" {
    const board = busy();
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);

    var store = try Store.init(null);
    const memory: Guest = .{ .store = &store };
    var target: Stand = .{ .npu = npu.Npu.init() };
    target.npu.memory = memory;
    try section.load(&target, bytes.written());
    try std.testing.expect(target.npu.memory != null);
    try std.testing.expectEqual(@as(u32, 5), target.npu.jobs);
}

test "a missing or short section leaves the NPU alone" {
    var header = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer header.deinit();
    try file.writeHeader(&header.writer);
    var target: Stand = .{ .npu = npu.Npu.init() };
    try std.testing.expectError(error.Missing, section.load(&target, header.written()));

    const board = busy();
    var bytes = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer bytes.deinit();
    try saved(&board, &bytes);
    try std.testing.expect(std.meta.isError(section.load(&target, bytes.written()[0 .. bytes.written().len - 3])));
    try std.testing.expectEqual(@as(u32, 0), target.npu.jobs);
}
