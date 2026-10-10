//! The control-block vocabulary: ring arithmetic and the checks a probe makes
//! before it trusts a descriptor.
const std = @import("std");
const ra8 = @import("ra8");
const block = ra8.chip.periph.rtt.block;
const memmap = ra8.chip.core.memmap;

fn up(buf: u32, size: u32, write: u32, read: u32) block.Up {
    return .{ .buf = buf, .size = size, .write = write, .read = read };
}

test "pending counts forward without a wrap" {
    try std.testing.expectEqual(@as(u32, 20), up(0x2200_0000, 64, 30, 10).pending());
}

test "pending counts around the wrap" {
    try std.testing.expectEqual(@as(u32, 14), up(0x2200_0000, 64, 4, 54).pending());
}

test "pending is zero when the offsets meet" {
    try std.testing.expectEqual(@as(u32, 0), up(0x2200_0000, 64, 7, 7).pending());
}

test "the first run stops at the end of the ring" {
    try std.testing.expectEqual(@as(u32, 10), up(0x2200_0000, 64, 4, 54).firstRun(14));
}

test "the first run is the whole ask when it fits" {
    try std.testing.expectEqual(@as(u32, 20), up(0x2200_0000, 64, 30, 10).firstRun(20));
}

test "a live descriptor passes" {
    try std.testing.expectEqual(@as(?block.Reject, null), block.check(1, up(0x2200_1000, 64, 30, 10)));
}

test "no up-buffer is refused" {
    try std.testing.expectEqual(block.Reject.no_up_buffer, block.check(0, up(0x2200_1000, 64, 0, 0)).?);
}

test "an absurd up-buffer count is refused" {
    try std.testing.expectEqual(block.Reject.too_many_up_buffers, block.check(4096, up(0x2200_1000, 64, 0, 0)).?);
}

test "a null ring pointer is refused" {
    try std.testing.expectEqual(block.Reject.empty_ring, block.check(1, up(0, 64, 0, 0)).?);
}

test "a zero-length ring is refused" {
    try std.testing.expectEqual(block.Reject.empty_ring, block.check(1, up(0x2200_1000, 0, 0, 0)).?);
}

test "a ring bigger than the cap is refused" {
    try std.testing.expectEqual(block.Reject.huge_ring, block.check(1, up(0x2200_1000, 1 << 21, 0, 0)).?);
}

test "an offset past the ring is refused" {
    try std.testing.expectEqual(block.Reject.offset_past_ring, block.check(1, up(0x2200_1000, 64, 64, 0)).?);
}

test "a ring outside RAM is refused, which dev does not check" {
    try std.testing.expectEqual(block.Reject.ring_off_ram, block.check(1, up(0x4000_0000, 64, 0, 0)).?);
}

test "a ring running off the end of RAM is refused" {
    const straddling = memmap.sram_end - 0x20;
    try std.testing.expectEqual(block.Reject.ring_off_ram, block.check(1, up(straddling, 4096, 0, 0)).?);
}

test "RAM holds a span that ends exactly at the end of a window" {
    try std.testing.expect(memmap.debugHolds(memmap.sram_end - 0x100, 0x100));
}

test "RAM holds nothing of zero length" {
    try std.testing.expect(!memmap.debugHolds(0x2200_0000, 0));
}

test "a ring in the DTCM is taken, the scan window is not the ring rule" {
    try std.testing.expectEqual(@as(?block.Reject, null), block.check(1, up(0x2000_0100, 128, 0, 0)));
}

test "a ring in the external SDRAM is taken" {
    try std.testing.expectEqual(@as(?block.Reject, null), block.check(1, up(0x6800_0000, 1024, 0, 0)));
}

test "a ring in the Non-secure SDRAM alias is taken" {
    try std.testing.expectEqual(@as(?block.Reject, null), block.check(1, up(0x7800_0000, 1024, 0, 0)));
}

test "a ring straddling the end of the DTCM is still refused" {
    try std.testing.expectEqual(block.Reject.ring_off_ram, block.check(1, up(0x2000_FFE0, 4096, 0, 0)).?);
}

test "the id matches only where it is spelled" {
    const bytes = "..SEGGER RTT..";
    try std.testing.expect(block.idAt(bytes, 2));
    try std.testing.expect(!block.idAt(bytes, 1));
    try std.testing.expect(!block.idAt(bytes, 13));
}
