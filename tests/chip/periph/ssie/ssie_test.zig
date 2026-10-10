//! Covers src/chip/periph/ssie.zig.
const std = @import("std");
const ssie = @import("ra8").chip.periph.ssie;

const ch0 = ssie.channelAddress(0);
const ch1 = ssie.channelAddress(1);

fn unit() ssie.Ssie {
    return ssie.Ssie.init();
}

/// Start the transmitter the way a driver does: read SSISR for the idle
/// flag, then set TEN.
fn startTx(block: *ssie.Ssie, base: u32) !void {
    try std.testing.expect(block.read(base + ssie.off_ssisr, 4) & ssie.field.iirq != 0);
    block.write(base + ssie.off_ssicr, 4, ssie.field.ten);
}

test "a fresh channel is idle, empty and quiet" {
    var block = unit();
    try std.testing.expectEqual(ssie.field.iirq, block.read(ch0 + ssie.off_ssisr, 4));
    try std.testing.expectEqual(ssie.field.tde, block.read(ch0 + ssie.off_ssifsr, 4));
    try std.testing.expect(block.quiet());
}

test "IIRQ drops once either direction is enabled, and comes back" {
    var block = unit();
    block.write(ch0 + ssie.off_ssicr, 4, ssie.field.ren);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssisr, 4));
    block.write(ch0 + ssie.off_ssicr, 4, 0);
    try std.testing.expectEqual(ssie.field.iirq, block.read(ch0 + ssie.off_ssisr, 4));
}

test "a sample written with TEN set is transmitted" {
    var block = unit();
    try startTx(&block, ch0);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), block.channels[0].last);
    try std.testing.expectEqual(@as(usize, 0), block.channels[0].staged());
}

test "a sample written with TEN clear is staged, not transmitted" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x0AAA);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(usize, 1), block.channels[0].staged());
}

test "TDE reads clear while the FIFO holds a sample" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 1);
    const held = block.read(ch0 + ssie.off_ssifsr, 4);
    try std.testing.expectEqual(@as(u32, 0), held & ssie.field.tde);
    try startTx(&block, ch0);
    try std.testing.expectEqual(ssie.field.tde, block.read(ch0 + ssie.off_ssifsr, 4));
}

test "SSIFSR reports how many stages the FIFO is holding" {
    var block = unit();
    const tdc = ssie.stage.status.tdc_mask;
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssifsr, 4) & tdc);
    for (0..5) |i| block.write(ch0 + ssie.off_ssiftdr, 4, @intCast(i));
    try std.testing.expectEqual(
        ssie.stage.transmitCount(5),
        block.read(ch0 + ssie.off_ssifsr, 4) & tdc,
    );
}

test "a full FIFO reports the depth, so a driver stops writing" {
    var block = unit();
    for (0..ssie.tx_depth + 4) |i| block.write(ch0 + ssie.off_ssiftdr, 4, @intCast(i));
    try std.testing.expectEqual(
        ssie.stage.transmitCount(ssie.tx_depth),
        block.read(ch0 + ssie.off_ssifsr, 4) & ssie.stage.status.tdc_mask,
    );
}

test "a TFRST pulse empties the transmit FIFO" {
    var block = unit();
    for (0..3) |i| block.write(ch0 + ssie.off_ssiftdr, 4, @intCast(i));
    try std.testing.expectEqual(@as(usize, 3), block.channels[0].staged());
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.stage.reset.both);
    try std.testing.expectEqual(@as(usize, 0), block.channels[0].staged());
    try std.testing.expectEqual(@as(u32, 3), block.channels[0].discarded());
    try std.testing.expectEqual(ssie.field.tde, block.read(ch0 + ssie.off_ssifsr, 4));
}

test "SSIFCR still reads back what was written, reset bits included" {
    var block = unit();
    block.write(ch0 + ssie.off_ssifcr, 4, 0x0000_0033);
    try std.testing.expectEqual(@as(u32, 0x0000_0033), block.read(ch0 + ssie.off_ssifcr, 4));
}

test "a reset bit left set does not re-empty the FIFO on a later store" {
    var block = unit();
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.stage.reset.both);
    for (0..2) |i| block.write(ch0 + ssie.off_ssiftdr, 4, @intCast(i));
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.stage.reset.both | 0x40);
    try std.testing.expectEqual(@as(usize, 2), block.channels[0].staged());
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].discarded());
}

test "a receive FIFO reset alone leaves the transmit stages alone" {
    var block = unit();
    for (0..2) |i| block.write(ch0 + ssie.off_ssiftdr, 4, @intCast(i));
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.stage.reset.receive);
    try std.testing.expectEqual(@as(usize, 2), block.channels[0].staged());
}

test "setting TEN drains what is staged, oldest first" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x11);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x22);
    try startTx(&block, ch0);
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0x22), block.channels[0].last);
    try std.testing.expectEqual(@as(usize, 0), block.channels[0].staged());
}

test "a store past the last stage is dropped, not transmitted" {
    var block = unit();
    for (0..ssie.tx_depth + 3) |i| {
        block.write(ch0 + ssie.off_ssiftdr, 4, @intCast(i));
    }
    try std.testing.expectEqual(ssie.tx_depth, block.channels[0].staged());
    try std.testing.expectEqual(@as(u32, 3), block.channels[0].dropped());
    try startTx(&block, ch0);
    try std.testing.expectEqual(@as(u32, ssie.tx_depth), block.channels[0].transmitted);
}

test "a byte store to TEN leaves the rest of SSICR where it was" {
    var block = unit();
    block.write(ch0 + ssie.off_ssicr, 4, 0x5A5A_5A00);
    block.write(ch0 + ssie.off_ssicr, 1, ssie.field.ten);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A02), block.read(ch0 + ssie.off_ssicr, 4));
    try std.testing.expect(block.channels[0].transmitting());
}

test "a store to SSISR changes nothing a read can see" {
    var block = unit();
    block.write(ch0 + ssie.off_ssisr, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(ssie.field.iirq, block.read(ch0 + ssie.off_ssisr, 4));
    try startTx(&block, ch0);
    block.write(ch0 + ssie.off_ssisr, 4, ssie.field.iirq);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssisr, 4));
}

test "an unmodelled register reads back what was written to it" {
    var block = unit();
    block.write(ch0 + ssie.off_ssifcr, 4, 0x0000_0033);
    try std.testing.expectEqual(@as(u32, 0x0000_0033), block.read(ch0 + ssie.off_ssifcr, 4));
    block.write(ch0 + ssie.off_ssifcr, 1, 0x44);
    try std.testing.expectEqual(@as(u32, 0x0000_0044), block.read(ch0 + ssie.off_ssifcr, 4));
}

test "the receive port has no source behind it" {
    var block = unit();
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssifrdr, 4));
}

test "the channels are separate" {
    var block = unit();
    try startTx(&block, ch1);
    block.write(ch1 + ssie.off_ssiftdr, 4, 0x77);
    try std.testing.expectEqual(@as(u32, 1), block.channels[1].transmitted);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
    try std.testing.expect(block.channels[0].quiet());
    try std.testing.expect(!block.quiet());
}

test "a channel outside the window is not decoded" {
    var block = unit();
    block.write(ssie.win_base + ssie.win_span, 4, 0xFFFF);
    try std.testing.expect(block.quiet());
}

test "a halfword store to SSIFTDR stages nothing" {
    var block = unit();
    try startTx(&block, ch0);
    block.write(ch0 + ssie.off_ssiftdr, 2, 0x5678);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].last);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].refused());
}

test "one sample pushed in two halfword stores becomes no samples" {
    var block = unit();
    try startTx(&block, ch0);
    block.write(ch0 + ssie.off_ssiftdr, 2, 0x5678);
    block.write(ch0 + ssie.off_ssiftdr + 2, 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].refused());
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x1234_5678);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), block.channels[0].last);
}

test "a byte store above the register carries no sample either" {
    var block = unit();
    try startTx(&block, ch0);
    block.write(ch0 + ssie.off_ssiftdr + 3, 1, 0xAB);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].refused());
}

test "a refused store leaves the staged FIFO exactly as it was" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x0000_1111);
    block.write(ch0 + ssie.off_ssiftdr, 1, 0x22);
    try std.testing.expectEqual(@as(usize, 1), block.channels[0].staged());
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].refused());
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssifsr, 4) & ssie.field.tde);
    try startTx(&block, ch0);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0x0000_1111), block.channels[0].last);
}

test "a narrow store to SSICR is still folded into the lanes it names" {
    var block = unit();
    block.write(ch0 + ssie.off_ssicr, 4, 0x5A5A_5A00);
    block.write(ch0 + ssie.off_ssicr, 1, ssie.field.ten);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A02), block.read(ch0 + ssie.off_ssicr, 4));
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].refused());
}

test "a refused store alone is enough to report the channel" {
    var block = unit();
    try std.testing.expect(block.channels[0].quiet());
    block.write(ch0 + ssie.off_ssiftdr, 2, 0x99);
    try std.testing.expect(!block.channels[0].quiet());
    try std.testing.expect(!block.quiet());
}

test "SSIRST empties the transmit FIFO and takes the enables down" {
    var block = unit();
    block.write(ch0 + ssie.off_ssicr, 4, ssie.field.ten | 0x0000_0040);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0xAAAA_AAAA);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].transmitted);
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.reset.mask.ssirst);
    // The mode bit above the enables rides through; REN and TEN do not.
    try std.testing.expectEqual(@as(u32, 0x0000_0040), block.channels[0].ssicr);
    try std.testing.expect(!block.channels[0].transmitting());
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].resetCount());
}

test "a reset throws away what was staged behind a transmitter that never came on" {
    var block = unit();
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x1111_1111);
    block.write(ch0 + ssie.off_ssiftdr, 4, 0x2222_2222);
    try std.testing.expectEqual(@as(usize, 2), block.channels[0].staged());
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.reset.mask.ssirst);
    try std.testing.expectEqual(@as(usize, 0), block.channels[0].staged());
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].discarded());
    // Nothing left to drain, so enabling the transmitter shifts nothing out.
    block.write(ch0 + ssie.off_ssicr, 4, ssie.field.ten);
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].transmitted);
}

test "IIRQ comes back after a reset, so the driver's idle check passes" {
    var block = unit();
    try startTx(&block, ch0);
    try std.testing.expectEqual(@as(u32, 0), block.read(ch0 + ssie.off_ssisr, 4));
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.reset.mask.ssirst);
    try std.testing.expectEqual(ssie.field.iirq, block.read(ch0 + ssie.off_ssisr, 4));
}

test "SSIRST reads back what firmware wrote and only resets on the rising edge" {
    var block = unit();
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.reset.mask.ssirst);
    try std.testing.expectEqual(ssie.reset.mask.ssirst, block.read(ch0 + ssie.off_ssifcr, 4));
    // The bit is held, so another SSIFCR field arriving on top of it is not a
    // second reset.
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.reset.mask.ssirst | 0x0000_000C);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].resetCount());
    block.write(ch0 + ssie.off_ssifcr, 4, 0);
    block.write(ch0 + ssie.off_ssifcr, 4, ssie.reset.mask.ssirst);
    try std.testing.expectEqual(@as(u32, 2), block.channels[0].resetCount());
}

test "a reset on one channel leaves the other running" {
    var block = unit();
    try startTx(&block, ch0);
    try startTx(&block, ch1);
    block.write(ch1 + ssie.off_ssifcr, 4, ssie.reset.mask.ssirst);
    try std.testing.expect(block.channels[0].transmitting());
    try std.testing.expect(!block.channels[1].transmitting());
    try std.testing.expectEqual(@as(u32, 0), block.channels[0].resetCount());
}

test "a halfword store to the top of SSIFCR carries SSIRST" {
    var block = unit();
    try startTx(&block, ch0);
    // SSIRST is bit 16, so it rides in the upper halfword at +2.
    block.write(ch0 + ssie.off_ssifcr + 2, 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 1), block.channels[0].resetCount());
    try std.testing.expect(!block.channels[0].transmitting());
}
