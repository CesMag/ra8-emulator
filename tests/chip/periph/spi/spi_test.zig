//! Covers src/chip/periph/spi/spi.zig.
const std = @import("std");
const spi = @import("ra8").chip.periph.spi;

const ch0 = spi.channelAddress(0);
const ch1 = spi.channelAddress(1);

fn unit() spi.Spi {
    return spi.Spi.init();
}

/// Bring a channel up the way the polling driver does: arm the non-inverting
/// tie while SPE is still clear, then enable.
fn startLoopback(block: *spi.Spi, base: u32) void {
    block.write(base + spi.off_spcr2, 4, spi.field.splp2);
    block.write(base + spi.off_spcr, 4, spi.field.spe);
}

/// Programme SPCMD0's data length the way the driver does before a transfer.
fn setWidth(block: *spi.Spi, base: u32, encoding: u32) void {
    block.write(base + spi.frame.off.spcmd0, 4, encoding << spi.frame.field.spb_shift);
}

/// One frame, driver order: wait for TX empty, store, wait for RX full, read.
fn exchange(block: *spi.Spi, base: u32, word: u32) !u32 {
    try std.testing.expect(block.read(base + spi.off_spsr, 4) & spi.field.sptef != 0);
    block.write(base + spi.off_spdr, 4, word);
    try std.testing.expect(block.read(base + spi.off_spsr, 4) & spi.field.sprf != 0);
    return block.read(base + spi.off_spdr, 4);
}

test "a fresh channel is quiet and reports no status at all" {
    var block = unit();
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4));
    try std.testing.expect(block.quiet());
}

test "SPTEF comes up with SPE and goes away with it" {
    var block = unit();
    block.write(ch0 + spi.off_spcr, 4, spi.field.spe);
    try std.testing.expectEqual(spi.field.sptef, block.read(ch0 + spi.off_spsr, 4));
    block.write(ch0 + spi.off_spcr, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4));
}

test "a frame under the non-inverting tie comes back as it went out" {
    var block = unit();
    startLoopback(&block, ch0);
    try std.testing.expectEqual(@as(u32, 0x5A), try exchange(&block, ch0, 0x5A));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].frames);
    try std.testing.expectEqual(@as(u32, 0x5A), block.channels[0].last);
}

test "the inverting tie returns the complement, inside the frame" {
    var block = unit();
    block.write(ch0 + spi.off_spcr2, 4, spi.field.splp);
    block.write(ch0 + spi.off_spcr, 4, spi.field.spe);
    try std.testing.expectEqual(@as(u32, 0xA5), try exchange(&block, ch0, 0x5A));
}

test "with no tie and no device the shifter clocks in an idle zero" {
    var block = unit();
    block.write(ch0 + spi.off_spcr, 4, spi.field.spe);
    try std.testing.expectEqual(@as(u32, 0), try exchange(&block, ch0, 0x5A));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].frames);
}

test "a store to a channel that was never enabled moves nothing" {
    var block = unit();
    block.write(ch0 + spi.off_spcr2, 4, spi.field.splp2);
    block.write(ch0 + spi.off_spdr, 4, 0x5A);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].frames);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].refused);
    // dev would have echoed it: here nothing is waiting to be read.
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4));
}

test "the received frame is taken once, not served again" {
    var block = unit();
    startLoopback(&block, ch0);
    try std.testing.expectEqual(@as(u32, 0x3C), try exchange(&block, ch0, 0x3C));
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4) & spi.field.sprf);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spdr, 4));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].starved);
}

test "a completed frame raises CENDF and SPSRC clears it" {
    var block = unit();
    startLoopback(&block, ch0);
    _ = try exchange(&block, ch0, 0x11);
    try std.testing.expect(block.read(ch0 + spi.off_spsr, 4) & spi.field.cendf != 0);
    block.write(ch0 + spi.off_spsrc, 4, spi.field.cendf);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4) & spi.field.cendf);
    // SPTEF is not SPSRC's to clear: the channel is still running.
    try std.testing.expect(block.read(ch0 + spi.off_spsr, 4) & spi.field.sptef != 0);
}

test "SPSRC clears the receive flags without handing over the frame" {
    var block = unit();
    startLoopback(&block, ch0);
    block.write(ch0 + spi.off_spdr, 4, 0x77);
    block.write(ch0 + spi.off_spsrc, 4, spi.field.sprf | spi.field.spdrf);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4) & spi.field.sprf);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spdr, 4));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].starved);
}

test "a store to SPSR changes nothing" {
    var block = unit();
    block.write(ch0 + spi.off_spsr, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4));
    try std.testing.expect(block.quiet());
}

test "a byte store to SPE keeps the bytes above it" {
    var block = unit();
    block.write(ch0 + spi.off_spcr, 4, 0x5A5A_5A00);
    block.write(ch0 + spi.off_spcr, 1, spi.field.spe);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A01), block.read(ch0 + spi.off_spcr, 4));
    try std.testing.expect(block.channels[0].enabled());
}

test "a halfword store to the top of SPCR2 keeps the tie it arms" {
    var block = unit();
    block.write(ch0 + spi.off_spcr2, 4, 0x0000_1234);
    block.write(ch0 + spi.off_spcr2 + 2, 2, spi.field.splp2 >> 16);
    try std.testing.expectEqual(@as(u32, 0x0002_1234), block.read(ch0 + spi.off_spcr2, 4));
    try std.testing.expect(block.channels[0].loopback());
}

test "only the frame width is clocked, the bits above it are not" {
    var block = unit();
    startLoopback(&block, ch0);
    try std.testing.expectEqual(@as(u32, 0x9E), try exchange(&block, ch0, 0x1234_9E));
    try std.testing.expectEqual(@as(u32, 0x9E), block.channels[0].last);
}

test "an unmodelled register in the window reflects what was written" {
    var block = unit();
    block.write(ch0 + 0x20, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), block.read(ch0 + 0x20, 4));
    try std.testing.expectEqual(@as(u32, 0xAD), block.read(ch0 + 0x22, 1));
}

test "the channels are separate" {
    var block = unit();
    startLoopback(&block, ch0);
    _ = try exchange(&block, ch0, 0x42);
    block.write(ch1 + spi.off_spdr, 4, 0x42);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].frames);
    try std.testing.expectEqual(@as(u32, 0), block.channels[1].frames);
    try std.testing.expectEqual(@as(u32, 1), block.channels[1].refused);
}

test "an address past the last channel answers with nothing" {
    var block = unit();
    block.write(spi.win_base + spi.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(spi.win_base + spi.win_span, 4));
    try std.testing.expect(block.quiet());
}

test "a byte read of SPDR cannot carry a 16-bit frame, and the register keeps it" {
    var block = unit();
    startLoopback(&block, ch0);
    setWidth(&block, ch0, spi.frame.spb.sixteen);
    block.write(ch0 + spi.off_spdr, 4, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spdr, 1));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].narrow_reads);
    try std.testing.expect(block.read(ch0 + spi.off_spsr, 4) & spi.field.sprf != 0);
    try std.testing.expectEqual(@as(u32, 0x1234), block.read(ch0 + spi.off_spdr, 4));
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].starved);
}

test "two halfword reads of a 32-bit frame take nothing, one word read takes it" {
    var block = unit();
    startLoopback(&block, ch0);
    setWidth(&block, ch0, spi.frame.spb.thirty_two);
    block.write(ch0 + spi.off_spdr, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spdr, 2));
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spdr + 2, 2));
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].narrow_reads);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), block.read(ch0 + spi.off_spdr, 4));
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].starved);
}

test "two halfword stores of a 32-bit frame clock nothing, not two half frames" {
    var block = unit();
    startLoopback(&block, ch0);
    setWidth(&block, ch0, spi.frame.spb.thirty_two);
    block.write(ch0 + spi.off_spdr, 2, 0xBEEF);
    block.write(ch0 + spi.off_spdr + 2, 2, 0xDEAD);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].frames);
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].narrow_writes);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spsr, 4) & spi.field.sprf);
}

test "a byte access still carries the eight-bit default" {
    var block = unit();
    startLoopback(&block, ch0);
    block.write(ch0 + spi.off_spdr, 1, 0x5A);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].frames);
    try std.testing.expectEqual(@as(u32, 0x5A), block.read(ch0 + spi.off_spdr, 1));
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].narrow_reads);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].narrow_writes);
}

test "an access above the bottom lane of SPDR names no frame" {
    var block = unit();
    startLoopback(&block, ch0);
    block.write(ch0 + spi.off_spdr + 2, 1, 0x5A);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].frames);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].narrow_writes);
}

test "a refused SPDR store is counted as narrow before it is counted as disabled" {
    var block = unit();
    setWidth(&block, ch0, spi.frame.spb.sixteen);
    block.write(ch0 + spi.off_spdr, 1, 0x5A);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].narrow_writes);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].refused);
    try std.testing.expect(!block.quiet());
}

test "SPCR2 takes the tie while the channel is stopped" {
    var block = unit();
    block.write(ch0 + spi.off_spcr2, 4, spi.field.splp2);
    try std.testing.expectEqual(@as(u32, spi.field.splp2), block.read(ch0 + spi.off_spcr2, 4));
    try std.testing.expect(block.channels[0].loopback());
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].locked.ignored);
}

test "SPCR2 does not move once SPE is set" {
    var block = unit();
    block.write(ch0 + spi.off_spcr, 4, spi.field.spe);
    block.write(ch0 + spi.off_spcr2, 4, spi.field.splp2);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spcr2, 4));
    try std.testing.expect(!block.channels[0].loopback());
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].locked.ignored);
}

test "a tie armed before the enable survives the enable" {
    var block = unit();
    startLoopback(&block, ch0);
    try std.testing.expectEqual(@as(u32, spi.field.splp2), block.read(ch0 + spi.off_spcr2, 4));
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].locked.ignored);
    try std.testing.expectEqual(@as(u32, 0x5A), try exchange(&block, ch0, 0x5A));
}

test "a teardown that clears SPCR2 before SPE leaves the tie standing" {
    var block = unit();
    startLoopback(&block, ch0);
    block.write(ch0 + spi.off_spcr2, 4, 0);
    try std.testing.expectEqual(@as(u32, spi.field.splp2), block.read(ch0 + spi.off_spcr2, 4));
    block.write(ch0 + spi.off_spcr, 4, 0);
    block.write(ch0 + spi.off_spcr2, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + spi.off_spcr2, 4));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].locked.ignored);
}

test "a narrow SPCR2 store is refused by the lock too" {
    var block = unit();
    block.write(ch0 + spi.off_spcr2, 4, spi.field.splp2);
    block.write(ch0 + spi.off_spcr, 4, spi.field.spe);
    block.write(ch0 + spi.off_spcr2 + 2, 2, 0);
    try std.testing.expectEqual(@as(u32, spi.field.splp2), block.read(ch0 + spi.off_spcr2, 4));
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].locked.ignored);
}

test "the lock is per channel" {
    var block = unit();
    block.write(ch0 + spi.off_spcr, 4, spi.field.spe);
    block.write(ch0 + spi.off_spcr2, 4, spi.field.splp2);
    block.write(ch1 + spi.off_spcr2, 4, spi.field.splp2);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].locked.ignored);
    try std.testing.expectEqual(@as(u32, 0), block.channels[1].locked.ignored);
    try std.testing.expectEqual(@as(u32, spi.field.splp2), block.read(ch1 + spi.off_spcr2, 4));
}
