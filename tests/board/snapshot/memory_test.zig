//! RA8EMU-659: guest memory saved into a snapshot and loaded into a fresh
//! store reads back byte-identical.
const std = @import("std");
const ra8 = @import("ra8");
const file = ra8.snapshot.file;
const memory = ra8.board.snapshot.memory;
const memmap = ra8.chip.core.memmap;

const window_base: u32 = 0x9000_0000;

fn put(store: *const memory.Store, address: u32, text: []const u8) void {
    @memcpy(store.span(address, text.len).?, text);
}

fn snapshot(store: *const memory.Store, list: *std.Io.Writer.Allocating) !void {
    try file.writeHeader(&list.writer);
    try memory.save(store, &list.writer);
}

fn restore(bytes: []const u8) !memory.Store {
    var store = try memory.Store.init(null);
    errdefer store.deinit();
    const section = (try file.Reader.find(bytes, .memory)).?;
    try memory.load(&store, section.payload);
    return store;
}

test "every region and a mapped window come back byte-identical" {
    var first = try memory.Store.init(null);
    defer first.deinit();
    try first.map(window_base, 0x2000);
    put(&first, memmap.mram_base + 0x10, "flash");
    put(&first, memmap.sram_base + 0x1234, "sram");
    put(&first, memmap.sdram_end - 4, "end!");
    put(&first, window_base + 0x1ffc, "win!");
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&first, &list);
    var second = try restore(list.written());
    defer second.deinit();
    for (memmap.ram) |entry| {
        try std.testing.expectEqualSlices(u8, first.region(entry.base).?, second.region(entry.base).?);
    }
    try std.testing.expectEqualSlices(u8, first.span(window_base, 0x2000).?, second.span(window_base, 0x2000).?);
    try std.testing.expectEqualStrings("sram", second.span(memmap.ns_sram_base + 0x1234, 4).?);
}

test "only non-zero pages are written" {
    var store = try memory.Store.init(null);
    defer store.deinit();
    put(&store, memmap.sram_base, "x");
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&store, &list);
    try std.testing.expect(list.written().len < 2 * memory.page);
}

test "external fabric counters and pending contention survive a snapshot" {
    var config = ra8.board.external_memory.Config{};
    config.ospi.size = 1024 * 1024;
    config.sdram.size = 1024 * 1024;
    const layout = try ra8.board.external_memory.Layout.init(config);
    var flash1 = ra8.components.nor_flash.Flash.init(std.testing.allocator);
    defer flash1.deinit();
    var first = try memory.Store.init(null);
    defer first.deinit();
    var external1 = try ra8.board.external_backing.Backing.init(layout, flash1.window());
    defer external1.deinit();
    first.attachExternal(external1.port());
    external1.fabric.note(.cpu0, layout.locate(0x6800_0040, 4).?, .read, 4);
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&first, &list);

    var flash2 = ra8.components.nor_flash.Flash.init(std.testing.allocator);
    defer flash2.deinit();
    var second = try memory.Store.init(null);
    defer second.deinit();
    var external2 = try ra8.board.external_backing.Backing.init(layout, flash2.window());
    defer external2.deinit();
    second.attachExternal(external2.port());
    const section = (try file.Reader.find(list.written(), .memory)).?;
    try memory.load(&second, section.payload);
    const counters = external2.fabric.counters(.sdram, 0);
    try std.testing.expectEqual(@as(u64, 4), counters.bytes_read);
    try std.testing.expect(external2.fabric.takePending(.cpu0) != 0);

    var changed = config;
    changed.sdram.width = 16;
    var flash3 = ra8.components.nor_flash.Flash.init(std.testing.allocator);
    defer flash3.deinit();
    var mismatched = try memory.Store.init(null);
    defer mismatched.deinit();
    var external3 = try ra8.board.external_backing.Backing.init(try ra8.board.external_memory.Layout.init(changed), flash3.window());
    defer external3.deinit();
    mismatched.attachExternal(external3.port());
    try std.testing.expectError(error.LayoutMismatch, memory.load(&mismatched, section.payload));
}

test "a second core saves its own regions, not the SRAM it borrows" {
    var first = try memory.Store.init(null);
    defer first.deinit();
    var second = try memory.Store.init(&first);
    defer second.deinit();
    put(&first, memmap.sram_base, "shared");
    put(&second, memmap.mram_base, "cpu1");
    var list = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer list.deinit();
    try snapshot(&second, &list);
    var back = try restore(list.written());
    defer back.deinit();
    try std.testing.expectEqualStrings("cpu1", back.span(memmap.mram_base, 4).?);
    try std.testing.expectEqual(@as(u8, 0), back.span(memmap.sram_base, 1).?[0]);
}

test "a region whose size changed is refused" {
    var store = try memory.Store.init(null);
    defer store.deinit();
    var payload: [16]u8 = undefined;
    for ([_]u32{ 1, memmap.sram_base, 4, 0 }, 0..) |value, index| {
        std.mem.writeInt(u32, payload[index * 4 ..][0..4], value, .little);
    }
    try std.testing.expectError(error.SizeMismatch, memory.load(&store, &payload));
    try std.testing.expectError(error.Truncated, memory.load(&store, payload[0..6]));
}
