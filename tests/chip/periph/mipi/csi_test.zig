//! Tests for the MIPI CSI-2 receiver window.
const std = @import("std");
const ra8 = @import("ra8");

const csi = ra8.chip.periph.mipi_csi;
const short = ra8.chip.periph.mipi_csi_short;

fn at(offset: u32) u32 {
    return csi.win_base + offset;
}

test "a fresh receiver is quiet" {
    var block = csi.MipiCsi.init();
    try std.testing.expect(block.quiet());
    try std.testing.expect(!block.receiving());
}

test "MCG reports the version, lane count and FIFO depth, not zero" {
    var block = csi.MipiCsi.init();
    const mcg = block.read(at(csi.off.mcg), 4);
    try std.testing.expectEqual(csi.capability.version, mcg & 0xF);
    try std.testing.expectEqual(csi.capability.lanes, (mcg >> 8) & 0xF);
    try std.testing.expectEqual(short.depth, (mcg >> 16) & 0xFF);
}

test "the clear handshake ends: GFCLR raises GCD, releasing it drops GCD" {
    var block = csi.MipiCsi.init();
    // This is the spin ra8_mipi_csi_short_packet_clear_fifo runs, bounded
    // at 1024 polls. Against a sparse cell it never saw GCD at all.
    block.write(at(csi.off.gsiu), 4, short.update.clear);
    const raised = block.read(at(csi.off.gsst), 4);
    try std.testing.expect(raised & short.status.cleared != 0);
    block.write(at(csi.off.gsiu), 4, 0);
    const released = block.read(at(csi.off.gsst), 4);
    try std.testing.expect(released & short.status.cleared == 0);
    try std.testing.expectEqual(@as(u32, 1), block.clears);
}

test "holding GFCLR high does not count a second clear" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.gsiu), 4, short.update.clear);
    block.write(at(csi.off.gsiu), 4, short.update.clear);
    try std.testing.expectEqual(@as(u32, 1), block.clears);
}

test "GSST reads are counted, because they are the driver's wait" {
    var block = csi.MipiCsi.init();
    _ = block.read(at(csi.off.gsst), 4);
    _ = block.read(at(csi.off.gsst), 4);
    try std.testing.expectEqual(@as(u32, 2), block.polls);
}

test "an empty FIFO answers empty rather than a made-up header" {
    var block = csi.MipiCsi.init();
    const gsst = block.read(at(csi.off.gsst), 4);
    try std.testing.expectEqual(@as(u32, 0), short.queuedIn(gsst));
    try std.testing.expectEqual(@as(u32, 0), block.read(at(csi.off.gsht), 4));
}

test "FINC against an empty queue is counted, not wrapped" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.gsiu), 4, short.update.advance);
    try std.testing.expectEqual(@as(u32, 1), block.empty_advances);
    try std.testing.expectEqual(@as(u32, 0), block.queued);
}

test "GFEN is counted as a re-enable" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.gsiu), 4, short.update.reenable);
    try std.testing.expectEqual(@as(u32, 1), block.reenables);
}

test "the read-only words refuse a store" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.mcg), 4, 0xFFFF_FFFF);
    block.write(at(csi.off.rtst), 4, csi.reset_status.busy);
    block.write(at(csi.off.gsst), 4, short.status.cleared);
    block.write(at(csi.off.gsht), 4, 0x1234);
    try std.testing.expectEqual(@as(u32, 4), block.refused);
    // And none of them kept what was written.
    try std.testing.expectEqual(csi.capability.word(), block.read(at(csi.off.mcg), 4));
    try std.testing.expectEqual(@as(u32, 0), block.read(at(csi.off.rtst), 4));
    try std.testing.expectEqual(@as(u32, 0), block.read(at(csi.off.gsht), 4));
}

test "RTST reads clear, so the init spin ends on its first poll" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.rtct), 4, csi.reset_control.request);
    try std.testing.expectEqual(@as(u32, 0), block.read(at(csi.off.rtst), 4) & csi.reset_status.busy);
    try std.testing.expectEqual(@as(u32, 1), block.resets);
}

test "a reset drops a pending clear handshake" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.gsiu), 4, short.update.clear);
    block.write(at(csi.off.rtct), 4, csi.reset_control.request);
    try std.testing.expect(block.read(at(csi.off.gsst), 4) & short.status.cleared == 0);
}

test "RTCT without VSRST does nothing" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.rtct), 4, 0);
    try std.testing.expectEqual(@as(u32, 0), block.resets);
}

test "RXEN is counted on the rising edge only" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.gsct), 4, short.control.store);
    block.write(at(csi.off.mct3), 4, csi.receive.enable);
    block.write(at(csi.off.mct3), 4, csi.receive.enable);
    try std.testing.expect(block.receiving());
    try std.testing.expectEqual(@as(u32, 1), block.enables);
    try std.testing.expectEqual(@as(u32, 0), block.blind_enables);
}

test "receiving with short-packet storing off is its own count" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.mct3), 4, csi.receive.enable);
    try std.testing.expectEqual(@as(u32, 1), block.enables);
    try std.testing.expectEqual(@as(u32, 1), block.blind_enables);
}

test "GSCT reads back what was written" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.gsct), 4, short.control.store | 4);
    const gsct = block.read(at(csi.off.gsct), 4);
    try std.testing.expect(short.storing(gsct));
    try std.testing.expectEqual(@as(u32, 4), short.thresholdOf(gsct));
}

test "an unmodelled word in the window is a plain shadow" {
    var block = csi.MipiCsi.init();
    const dlst0 = csi.win_base + 0x080;
    block.write(dlst0, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), block.read(dlst0, 4));
}

test "a narrow read is served out of the word it lands in" {
    var block = csi.MipiCsi.init();
    try std.testing.expectEqual(csi.capability.lanes, block.read(at(csi.off.mcg) + 1, 1) & 0xF);
    try std.testing.expectEqual(csi.capability.word() & 0xFFFF, block.read(at(csi.off.mcg), 2));
}

test "a byte store into GSCT merges without counting a GSST poll" {
    var block = csi.MipiCsi.init();
    block.write(at(csi.off.gsct), 1, 0x0C);
    try std.testing.expectEqual(@as(u32, 0x0C), short.thresholdOf(block.read(at(csi.off.gsct), 4)));
    try std.testing.expectEqual(@as(u32, 0), block.polls);
}

test "an access past the window is dropped" {
    var block = csi.MipiCsi.init();
    block.write(csi.win_base + csi.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), block.read(csi.win_base + csi.win_span, 4));
    try std.testing.expect(block.quiet());
}

test "the block advertises the whole documented window" {
    var block = csi.MipiCsi.init();
    const desc = block.block();
    try std.testing.expectEqual(csi.win_base, desc.base);
    try std.testing.expectEqual(@as(u32, 0x298), desc.size);
}
