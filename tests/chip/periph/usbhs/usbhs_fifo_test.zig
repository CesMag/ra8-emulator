//! The CFIFO port: where it is aimed, what it will move, and what it refuses.
const std = @import("std");
const ra8 = @import("ra8");
const fifo = ra8.chip.periph.usbhs_fifo;
const regs = ra8.chip.periph.usbhs_regs;

test "a fresh port is aimed at nothing" {
    var port = fifo.Port{};
    try std.testing.expect(port.pipe() == null);
    try std.testing.expectEqual(@as(u16, 0), port.status());
    try std.testing.expect(port.quiet());
}

test "a pipe the part does not have aims the port at nothing" {
    var port = fifo.Port{};
    // dev took CURPIPE modulo ten, so twelve landed on the control pipe.
    port.select(12);
    try std.testing.expect(port.pipe() == null);
    try std.testing.expectEqual(@as(u32, 1), port.bad_pipe);
}

test "a pipe in range aims the port" {
    var port = fifo.Port{};
    port.select(3);
    try std.testing.expectEqual(@as(u32, 3), port.pipe().?);
}

test "the read side is not ready until something is staged" {
    var port = fifo.Port{};
    port.select(0);
    try std.testing.expectEqual(@as(u16, 0), port.status());
    try std.testing.expectEqual(@as(u32, 0), port.readData(2));
    try std.testing.expectEqual(@as(u32, 1), port.not_ready);
}

test "a staged packet reports its length and comes back LSB first" {
    var port = fifo.Port{};
    port.select(0);
    port.in[0].fill(&[_]u8{ 0x12, 0x34, 0x56, 0x78 });
    try std.testing.expectEqual(regs.fifo.frdy | 4, port.status());
    try std.testing.expectEqual(@as(u32, 0x3412), port.readData(2));
    try std.testing.expectEqual(regs.fifo.frdy | 2, port.status());
    try std.testing.expectEqual(@as(u32, 0x7856), port.readData(2));
}

test "a read past the staged length is refused, not served with zeros" {
    var port = fifo.Port{};
    port.select(0);
    port.in[0].fill(&[_]u8{ 0x01, 0x02 });
    _ = port.readData(2);
    // dev kept serving zeros here forever, and the driver counted them.
    try std.testing.expectEqual(@as(u32, 0), port.readData(2));
    try std.testing.expectEqual(@as(u32, 1), port.not_ready);
}

test "a short packet drops ready as its last byte leaves" {
    var port = fifo.Port{};
    port.select(0);
    port.in[0].fill(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(u32, 0x7F), port.readData(1));
    try std.testing.expect(!port.in[0].ready);
}

test "a word read across a short packet's tail takes the last bytes" {
    // The HS HAL reads a 1-3 byte tail as one whole word at CFIFO and
    // keeps the low bytes; the slots past the packet are don't-care.
    var port = fifo.Port{};
    port.select(0);
    port.in[0].fill(&[_]u8{ 0xAA, 0xBB, 0xCC });
    try std.testing.expectEqual(@as(u32, 0x00CCBBAA), port.readData(4));
    try std.testing.expectEqual(@as(u32, 0), port.overdrain);
    try std.testing.expect(!port.in[0].ready);
}

test "a read from a zero-length packet is counted" {
    var port = fifo.Port{};
    port.select(0);
    port.in[0].fill(&[_]u8{});
    try std.testing.expectEqual(@as(u32, 0), port.readData(4));
    try std.testing.expectEqual(@as(u32, 1), port.overdrain);
}

test "the write side takes bytes LSB first up to the packet size" {
    var port = fifo.Port{};
    port.select(regs.fifo.isel | 2);
    try std.testing.expect(port.writing());
    port.writeData(0xDDCCBBAA, 4, 64);
    try std.testing.expectEqual(@as(u16, 4), port.out[2].len);
    try std.testing.expectEqual(@as(u8, 0xAA), port.out[2].data[0]);
    try std.testing.expectEqual(@as(u8, 0xDD), port.out[2].data[3]);
}

test "a packet past what the endpoint carries is refused" {
    var port = fifo.Port{};
    port.select(regs.fifo.isel | 1);
    port.writeData(0x11223344, 4, 2);
    // dev appended to its own 512-byte cap and delivered a packet no
    // endpoint could accept.
    try std.testing.expectEqual(@as(u16, 2), port.out[1].len);
    try std.testing.expectEqual(@as(u32, 1), port.oversize);
}

test "a write with the port aimed at nothing moves nothing" {
    var port = fifo.Port{};
    port.select(11);
    port.writeData(0xFF, 1, 64);
    try std.testing.expectEqual(@as(u32, 2), port.bad_pipe);
}

test "BCLR throws away the side the port is aimed at" {
    var port = fifo.Port{};
    port.select(regs.fifo.isel | 4);
    port.writeData(0xABCD, 2, 64);
    port.clear();
    try std.testing.expectEqual(@as(u16, 0), port.out[4].len);
    port.select(4);
    port.in[4].fill(&[_]u8{ 1, 2 });
    port.clear();
    try std.testing.expectEqual(@as(u16, 0), port.in[4].len);
}

test "the write side is ready whether or not anything is staged" {
    var port = fifo.Port{};
    port.select(regs.fifo.isel | 1);
    try std.testing.expectEqual(regs.fifo.frdy, port.status());
}

test "draining a staging hands the bytes over and empties it" {
    var staging = fifo.Staging{};
    staging.fill(&[_]u8{ 9, 8, 7 });
    var into: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 3), staging.drain(&into));
    try std.testing.expectEqual(@as(u8, 8), into[1]);
    try std.testing.expectEqual(@as(u16, 0), staging.len);
    try std.testing.expect(!staging.ready);
}

test "peeking at a staging leaves it exactly as it was" {
    var staging = fifo.Staging{};
    staging.fill(&[_]u8{ 4, 5, 6 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 5, 6 }, staging.staged());
    // Looking is not taking: a caller that goes on to refuse the bytes has
    // not emptied the buffer by asking what is in it.
    try std.testing.expectEqual(@as(u16, 3), staging.len);
    try std.testing.expect(staging.ready);
}
