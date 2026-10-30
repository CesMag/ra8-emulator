//! Bounds and whole-state oracle checks for the counting-loop fixture.
const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("window_rig.zig");
const memmap = ra8.chip.core.memmap;

test "the boot image and counting loop fit the window fixture" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    const store = &rig.opened.state.cpu0.store.?;
    const image = try ra8.board.image.load.read(rig.opened.state.image);
    try std.testing.expect(image.count > 0);
    for (image.maps.items()) |range| {
        try std.testing.expect(store.span(range.base, range.size()) != null);
    }
    for (image.segments[0..image.count]) |segment| {
        try std.testing.expectEqualSlices(u8, segment.bytes, store.span(segment.paddr, segment.bytes.len).?);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x68, 0x40, 0x1C, 0x08, 0x60, 0xFB, 0xE7 }, store.span(memmap.sram_base + 0x6000, 8).?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, store.span(rig_mod.counter_addr, 4).?);
}

test "the whole-state oracle covers both ends of external memory and CPU and board state" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    const base = try rig.full();
    defer std.testing.allocator.free(base);
    const digest = try rig.digest();
    const memory = rig.opened.state.profile.memory;
    const addresses = [_]u32{
        memmap.sdram_base,
        memmap.sdram_base + memory.sdram.size - 1,
        0x8000_0000,
        0x8000_0000 + memory.ospi.size - 1,
    };
    for (addresses) |address| {
        try rig.opened.guest().write(address, &.{0x5a});
        try std.testing.expect(!std.mem.eql(u8, &digest, &try rig.digest()));
        try rig.port().restoreFull(base);
        try std.testing.expectEqualSlices(u8, &digest, &try rig.digest());
    }
    rig.opened.primaryCpu().regs.low[3] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &digest, &try rig.digest()));
    try rig.port().restoreFull(base);
    rig.opened.state.board.time.base.cycles += 1;
    try std.testing.expect(!std.mem.eql(u8, &digest, &try rig.digest()));
    try rig.port().restoreFull(base);
    try std.testing.expectEqualSlices(u8, &digest, &try rig.digest());
}
