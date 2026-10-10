const std = @import("std");
const ra8 = @import("ra8");
const backing = ra8.board.external_backing;
const Store = ra8.chip.core.cpu.memory.store.Store;

test "a borrowing store shares the backing's SDRAM and fabric" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var config = ra8.board.external_memory.Config{};
    config.ospi.size = 1024 * 1024;
    config.sdram.size = 1024 * 1024;
    var external = try backing.Backing.init(try ra8.board.external_memory.Layout.init(config), board.nor.window());
    defer external.deinit();
    var first = try Store.init(null);
    defer first.deinit();
    first.attachExternal(external.port());
    var second = try Store.init(&first);
    defer second.deinit();
    try std.testing.expect(backing.fabricOf(&first).? == external.fabric);
    try std.testing.expect(backing.fabricOf(&second).? == external.fabric);
    try std.testing.expect(!second.owns_port);
    const cpu1 = ra8.chip.core.cpu.memory.guest.Guest{ .store = &second, .initiator = .cpu1 };
    try cpu1.write(0x6800_0004, &.{0x5a});
    try std.testing.expectEqual(@as(u8, 0x5a), external.sdram[4]);
    try std.testing.expectEqual(@as(u64, 1), external.fabric.counters(.sdram, 0).bytes_written);
}

test "a store with no board backing reports no fabric" {
    var store = try Store.init(null);
    defer store.deinit();
    try std.testing.expect(backing.fabricOf(&store) == null);
}
