//! Covers src/chip/core/cpu/memory/store.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const Store = ra8.chip.core.cpu.memory.store.Store;

test "every region is backed, and comes up zeroed" {
    var store = try Store.init(null);
    defer store.deinit();
    for (memmap.ram) |region| {
        const bytes = store.region(region.base).?;
        try std.testing.expectEqual(@as(usize, region.size), bytes.len);
        try std.testing.expectEqual(@as(u8, 0), bytes[0]);
        try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
    }
}

test "a Non-secure view is the same bytes as its Secure region" {
    var store = try Store.init(null);
    defer store.deinit();
    store.span(memmap.sram_base + 0x200, 1).?[0] = 0x5A;
    try std.testing.expectEqual(@as(u8, 0x5A), store.span(memmap.ns_sram_base + 0x200, 1).?[0]);
    store.span(memmap.ns_sdram_base + 4, 1).?[0] = 0xA5;
    try std.testing.expectEqual(@as(u8, 0xA5), store.span(memmap.sdram_base + 4, 1).?[0]);
    store.span(memmap.mram_base + 8, 1).?[0] = 0x3C;
    try std.testing.expectEqual(@as(u8, 0x3C), store.span(memmap.ns_mram_base + 8, 1).?[0]);
}

test "a second core borrows the shared SRAM and keeps its own MRAM, TCMs and PPB" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(&first);
    defer second.deinit();
    first.span(memmap.sram_base, 1).?[0] = 0x11;
    try std.testing.expectEqual(@as(u8, 0x11), second.span(memmap.ns_sram_base, 1).?[0]);
    try std.testing.expectEqual(first.region(memmap.sdram_base).?.ptr, second.region(memmap.sdram_base).?.ptr);
    for ([_]u32{ memmap.mram_base, memmap.dtcm_base, memmap.ppb_base }) |base| {
        try std.testing.expect(first.region(base).?.ptr != second.region(base).?.ptr);
    }
}

test "a borrower's deinit leaves the lender's pages alone" {
    var first = try Store.init(null);
    defer first.deinit();
    var second = try Store.init(&first);
    second.deinit();
    first.span(memmap.sram_base, 1).?[0] = 0x22;
    try std.testing.expectEqual(@as(u8, 0x22), first.span(memmap.ns_sram_base, 1).?[0]);
}

test "a span outside every region, or across a region's end, is refused" {
    var store = try Store.init(null);
    defer store.deinit();
    try std.testing.expect(store.span(0x4000_0000, 4) == null);
    try std.testing.expect(store.span(memmap.sram_end - 2, 4) == null);
    try std.testing.expect(store.span(memmap.sram_end - 4, 4) != null);
    try std.testing.expect(store.region(0x4000_0000) == null);
}

test "a store maps a window outside memmap and refuses one inside a region" {
    var store = try Store.init(null);
    defer store.deinit();
    try store.map(0x02C1_E000, 0x1000);
    try std.testing.expect(store.span(0x02C1_EDA0, 8) != null);
    try std.testing.expectError(error.Mapped, store.map(0x02C1_E000, 0x1000));
    try std.testing.expectError(error.Mapped, store.map(memmap.sram_base, 0x1000));
}

fn put(store: *const Store, address: u32, value: u32) void {
    std.mem.writeInt(u32, store.span(address, 4).?[0..4], value, .little);
}

fn get(store: *const Store, address: u32) u32 {
    return std.mem.readInt(u32, store.span(address, 4).?[0..4], .little);
}

test "the SRAM pair and the SDRAM pair are separate memories" {
    var store = try Store.init(null);
    defer store.deinit();
    put(&store, memmap.sram_base + 0x80, 0xAAAA_AAAA);
    try std.testing.expectEqual(@as(u32, 0), get(&store, memmap.sdram_base + 0x80));
}

test "a store comes up zeroed even where the last one wrote" {
    {
        var first = try Store.init(null);
        defer first.deinit();
        put(&first, memmap.sram_base + 0x80, 0xAAAA_AAAA);
        put(&first, memmap.sdram_base + 0x2000, 0xAAAA_AAAA);
    }
    var store = try Store.init(null);
    defer store.deinit();
    try std.testing.expectEqual(@as(u32, 0), get(&store, memmap.ns_sram_base + 0x80));
    try std.testing.expectEqual(@as(u32, 0), get(&store, memmap.sdram_base + 0x2000));
}

test "the cpu1 marker handshake crosses both the alias and the core" {
    // cpu1_main.c: CPU1 is a permanent-NS controller and writes its boot
    // markers through the Non-secure view; CPU0 reads the standard one.
    var cpu0 = try Store.init(null);
    defer cpu0.deinit();
    var cpu1 = try Store.init(&cpu0);
    defer cpu1.deinit();
    put(&cpu1, memmap.ns_sram_base + 0x0010_0200, 0xB055_A55A);
    try std.testing.expectEqual(@as(u32, 0xB055_A55A), get(&cpu0, memmap.sram_base + 0x0010_0200));
    put(&cpu0, memmap.sdram_base + 0x40, 0x1111_1111);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), get(&cpu1, memmap.ns_sdram_base + 0x40));
    put(&cpu1, memmap.ns_sdram_base + 0x44, 0x3333_3333);
    try std.testing.expectEqual(@as(u32, 0x3333_3333), get(&cpu0, memmap.sdram_base + 0x44));
}

test "a borrower keeps its own code MRAM" {
    var cpu0 = try Store.init(null);
    defer cpu0.deinit();
    var cpu1 = try Store.init(&cpu0);
    defer cpu1.deinit();
    put(&cpu0, memmap.mram_base + 0x100, 0xC0DE_DEAD);
    try std.testing.expectEqual(@as(u32, 0), get(&cpu1, memmap.mram_base + 0x100));
}

test "the Non-secure MRAM view is the store's own code MRAM (RA8EMU-412)" {
    var store = try Store.init(null);
    defer store.deinit();
    // Where a relinked Non-secure image's vector table sits (RA8FW-510).
    put(&store, memmap.mram_base + 0x8_0000, 0x1208_00F1);
    try std.testing.expectEqual(@as(u32, 0x1208_00F1), get(&store, memmap.ns_mram_base + 0x8_0000));
    put(&store, memmap.ns_mram_base + 0x8_0004, 0xC0DE_0001);
    try std.testing.expectEqual(@as(u32, 0xC0DE_0001), get(&store, memmap.mram_base + 0x8_0004));
}

test "the PPB is backed per store and starts zeroed (RA8EMU-416)" {
    var store = try Store.init(null);
    defer store.deinit();
    const ppb = store.region(memmap.ppb_base).?;
    try std.testing.expectEqual(@as(usize, memmap.ppb_size), ppb.len);
    try std.testing.expectEqual(@as(u32, 0), get(&store, memmap.scb.ccr));
    put(&store, memmap.scb.ccr, 0x0007_0200);
    try std.testing.expectEqual(@as(u32, 0x0007_0200), std.mem.readInt(u32, ppb[0xED14..][0..4], .little));
    var other = try Store.init(null);
    defer other.deinit();
    try std.testing.expectEqual(@as(u32, 0), get(&other, memmap.scb.ccr));
}

test "configured external memory shares NOR and instruments SDRAM aliases" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var config = ra8.board.external.memory.Config{};
    config.ospi.size = 1024 * 1024;
    config.sdram.size = 1024 * 1024;
    try board.nor.resize(config.ospi.size);
    var store = try Store.init(null);
    defer store.deinit();
    var external = try ra8.board.external.backing.Backing.init(try ra8.board.external.memory.Layout.init(config), board.nor.window());
    defer external.deinit();
    store.attachExternal(external.port());
    const cpu = ra8.chip.core.cpu.memory.guest.Guest{ .store = &store, .initiator = .cpu0 };
    try cpu.write(0x8000_0010, &.{0x0f});
    try std.testing.expectEqual(@as(u8, 0x0f), board.nor.byte(0x10));
    var byte: [1]u8 = undefined;
    try cpu.read(0x7800_0020, &byte);
    try std.testing.expect(cpu.backed(0x8000_0000, 4));
    try std.testing.expectError(error.Unmapped, cpu.read(0x6810_0000, &byte));
    try std.testing.expectError(error.Mapped, cpu.map(0x680F_FFFF, 2));
    try std.testing.expectError(error.Mapped, cpu.map(0x8010_0000, 0x1000));
    const counters = external.fabric.counters(.sdram, 100);
    try std.testing.expectEqual(@as(u64, 1), counters.bytes_read);
    try std.testing.expectEqual(@as(u64, 0x21), counters.read_high_water_bytes);
}
