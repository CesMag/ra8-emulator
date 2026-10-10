//! Covers src/chip/periph/dtc/dtc_xfer.zig: the TI block a DTC activation reads out of
//! memory, and what one activation leaves behind in it.
const std = @import("std");
const ra8 = @import("ra8");
const xfer = ra8.chip.periph.dtc_xfer;

/// MRA: MD[7:6], SZ[5:4], SM[3:2]. MRB: DM[3:2], DISEL b5, CHNE b7.
fn mode(mra: u8, mrb: u8) u32 {
    return (@as(u32, mra) << 24) | (@as(u32, mrb) << 16);
}

/// A normal-mode byte copy, source and destination both incrementing.
const normal_byte = mode(0b0000_1000, 0b0000_1000);

test "a mode word decodes into the fields the controller works in" {
    const info = xfer.Info.decode(mode(0b1001_1000, 0b0010_0000), 0x2000_0000, 0x2000_1000, 3, 7);
    try std.testing.expectEqual(xfer.Mode.block, info.mode);
    try std.testing.expectEqual(xfer.Width.half, info.width);
    try std.testing.expectEqual(xfer.Addressing.increment, info.source);
    try std.testing.expectEqual(xfer.Addressing.fixed, info.destination);
    try std.testing.expect(info.interrupt_each);
    try std.testing.expect(!info.chained);
    try std.testing.expectEqual(@as(u16, 7), info.cra);
    try std.testing.expectEqual(@as(u16, 3), info.crb);
}

test "the unit width follows SZ" {
    const byte = xfer.Info.decode(mode(0b0000_0000, 0), 0, 0, 0, 1);
    const half = xfer.Info.decode(mode(0b0001_0000, 0), 0, 0, 0, 1);
    const word = xfer.Info.decode(mode(0b0010_0000, 0), 0, 0, 0, 1);
    try std.testing.expectEqual(@as(u32, 1), byte.unit());
    try std.testing.expectEqual(@as(u32, 2), half.unit());
    try std.testing.expectEqual(@as(u32, 4), word.unit());
}

test "normal mode moves one unit per activation, however long the count is" {
    const info = xfer.Info.decode(normal_byte, 0, 0, 0, 512);
    try std.testing.expectEqual(@as(u32, 1), info.burst());
}

test "block mode moves CRAH units per activation" {
    const info = xfer.Info.decode(mode(0b1000_1000, 0b0000_1000), 0, 0, 4, 0x0808);
    try std.testing.expectEqual(@as(u32, 8), info.burst());
}

test "a block size of zero means 256 units" {
    const info = xfer.Info.decode(mode(0b1000_1000, 0b0000_1000), 0, 0, 1, 0);
    try std.testing.expectEqual(xfer.block_wrap, info.burst());
}

test "an address steps by the unit, backwards when the mode says decrement" {
    const word = xfer.Info.decode(mode(0b0010_1100, 0b0000_1000), 0, 0, 0, 4);
    try std.testing.expectEqual(@as(i64, -4), word.step(word.source));
    try std.testing.expectEqual(@as(i64, 4), word.step(word.destination));
    try std.testing.expectEqual(@as(i64, 0), word.step(.fixed));
}

test "one normal activation walks both addresses and spends one unit" {
    var info = xfer.Info.decode(normal_byte, 0x2000_0000, 0x2000_1000, 0, 4);
    info.advance();
    try std.testing.expectEqual(@as(u32, 0x2000_0001), info.sar);
    try std.testing.expectEqual(@as(u32, 0x2000_1001), info.dar);
    try std.testing.expectEqual(@as(u16, 3), info.cra);
    try std.testing.expect(!info.exhausted());
}

test "a fixed destination stays put while the source walks" {
    var info = xfer.Info.decode(mode(0b0000_1000, 0), 0x2000_0000, 0x4000_6000, 0, 2);
    info.advance();
    try std.testing.expectEqual(@as(u32, 0x2000_0001), info.sar);
    try std.testing.expectEqual(@as(u32, 0x4000_6000), info.dar);
}

test "one block activation walks a whole block and spends a block count" {
    var info = xfer.Info.decode(mode(0b1010_1000, 0b0000_1000), 0x2000_0000, 0x2000_1000, 2, 0x0404);
    info.advance();
    try std.testing.expectEqual(@as(u32, 0x2000_0010), info.sar);
    try std.testing.expectEqual(@as(u32, 0x2000_1010), info.dar);
    try std.testing.expectEqual(@as(u16, 1), info.crb);
    // CRA is untouched: CRAL ends back at the CRAH it reloads from.
    try std.testing.expectEqual(@as(u16, 0x0404), info.cra);
}

test "the last unit of a normal descriptor exhausts it" {
    var info = xfer.Info.decode(normal_byte, 0, 0, 0, 1);
    info.advance();
    try std.testing.expect(info.exhausted());
}

test "the last block of a block descriptor exhausts it" {
    var info = xfer.Info.decode(mode(0b1000_1000, 0b0000_1000), 0, 0, 1, 0x0202);
    info.advance();
    try std.testing.expect(info.exhausted());
}

test "repeat, reserved, offset and chained descriptors are refused by name" {
    const repeat = xfer.Info.decode(mode(0b0100_1000, 0b0000_1000), 0, 0, 0, 1);
    const reserved_mode = xfer.Info.decode(mode(0b1100_1000, 0b0000_1000), 0, 0, 0, 1);
    const reserved_width = xfer.Info.decode(mode(0b0011_1000, 0b0000_1000), 0, 0, 0, 1);
    const offset = xfer.Info.decode(mode(0b0000_0100, 0b0000_1000), 0, 0, 0, 1);
    const chained = xfer.Info.decode(mode(0b0000_1000, 0b1000_1000), 0, 0, 0, 1);
    try std.testing.expectEqual(xfer.Unsupported.repeat_mode, repeat.unsupported().?);
    try std.testing.expectEqual(xfer.Unsupported.reserved_mode, reserved_mode.unsupported().?);
    try std.testing.expectEqual(xfer.Unsupported.reserved_width, reserved_width.unsupported().?);
    try std.testing.expectEqual(xfer.Unsupported.offset_addressing, offset.unsupported().?);
    try std.testing.expectEqual(xfer.Unsupported.chained, chained.unsupported().?);
}

test "a plain incrementing copy is supported" {
    const info = xfer.Info.decode(normal_byte, 0, 0, 0, 1);
    try std.testing.expectEqual(@as(?xfer.Unsupported, null), info.unsupported());
}

test "the two counts share one word, CRB in the low half" {
    const info = xfer.Info.decode(normal_byte, 0, 0, 0x0003, 0x0021);
    try std.testing.expectEqual(@as(u32, 0x0021_0003), info.packedCounts());
}

test "an address walk wraps the way a 32-bit pointer does" {
    try std.testing.expectEqual(@as(u32, 0), xfer.walk(0xFFFF_FFFF, 1));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFC), xfer.walk(0, -4));
}

test "walkBy moves the addresses and pays no count" {
    var info = xfer.Info.decode(
        (@as(u32, 0b1001_1000) << 24) | (@as(u32, 0b0000_1000) << 16),
        0x2000_0000,
        0x2000_1000,
        3,
        0x20 << 8,
    );
    info.walkBy(4);
    // Halfword units, so four of them are eight bytes on each side.
    try std.testing.expectEqual(@as(u32, 0x2000_0008), info.sar);
    try std.testing.expectEqual(@as(u32, 0x2000_1008), info.dar);
    try std.testing.expectEqual(@as(u16, 3), info.crb);
    try std.testing.expectEqual(@as(u16, 0x20 << 8), info.cra);
}

test "walking by nothing leaves the descriptor exactly as it was" {
    const start = xfer.Info.decode(0, 0x2000_0000, 0x2000_1000, 1, 2);
    var info = start;
    info.walkBy(0);
    try std.testing.expectEqual(start.sar, info.sar);
    try std.testing.expectEqual(start.dar, info.dar);
    try std.testing.expectEqual(start.packedCounts(), info.packedCounts());
}
