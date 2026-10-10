const std = @import("std");
const ra8 = @import("ra8");
const ipc = ra8.chip.periph.ipc;

fn unit() ipc.Ipc {
    return ipc.Ipc.init();
}

fn reg(channel: usize, offset: u32) u32 {
    return ipc.channelAddress(channel) + offset;
}

test "a fresh unit is quiet and every channel reads idle" {
    var mailbox = unit();
    try std.testing.expect(mailbox.quiet());
    for (0..ipc.ch_count) |channel| {
        try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(channel, ipc.off_sta), 4));
    }
}

test "an ISET store latches the lines it names and STA shows them" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_iset), 4, 0x05);
    try std.testing.expectEqual(@as(u32, 0x05), mailbox.read(reg(0, ipc.off_sta), 4));
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[0].sends);
}

test "bits above the eight IRQ lines are not lines and latch nothing" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_iset), 4, 0xFF00);
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_sta), 4));
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[0].sends);
    try std.testing.expect(!mailbox.raised);
}

test "an IPC0 poke raises the receive event once at the boundary" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_iset), 4, 0x01);
    const due = mailbox.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(ipc.event.ipc0_irq, due.constSlice()[0]);
    // The line is pending in the controller now; a second boundary with no
    // new poke offers nothing.
    try std.testing.expectEqual(@as(usize, 0), mailbox.dueEvents().len);
    try std.testing.expectEqual(@as(u32, 1), mailbox.wakes);
}

test "an IPC1 poke is addressed to a core this build does not run" {
    var mailbox = unit();
    mailbox.write(reg(2, ipc.off_iset), 4, 0x02);
    // dev raises IRQ1 on whichever engine stored, which is the sender.
    try std.testing.expectEqual(@as(usize, 0), mailbox.dueEvents().len);
    try std.testing.expectEqual(@as(u32, 1), mailbox.undelivered);
    // The line is still latched: the message is there if the other core runs.
    try std.testing.expectEqual(@as(u32, 0x02), mailbox.read(reg(2, ipc.off_sta), 4));
}

test "CLR is write-one-to-clear over the pending lines" {
    var mailbox = unit();
    mailbox.write(reg(1, ipc.off_iset), 4, 0x0F);
    mailbox.write(reg(1, ipc.off_clr), 4, 0x09);
    try std.testing.expectEqual(@as(u32, 0x06), mailbox.read(reg(1, ipc.off_sta), 4));
}

test "a pushed word comes back once, in the order it was sent" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_txd), 4, 0xA1B2C3D4);
    mailbox.write(reg(0, ipc.off_txd), 4, 0x11223344);
    try std.testing.expectEqual(ipc.field.rdy, mailbox.read(reg(0, ipc.off_sta), 4) & ipc.field.rdy);
    try std.testing.expectEqual(@as(u32, 0xA1B2C3D4), mailbox.read(reg(0, ipc.off_rxd), 4));
    try std.testing.expectEqual(@as(u32, 0x11223344), mailbox.read(reg(0, ipc.off_rxd), 4));
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_sta), 4) & ipc.field.rdy);
}

test "the FIFO is four stages and FULL says so" {
    var mailbox = unit();
    for (0..ipc.fifo_depth) |i| {
        mailbox.write(reg(0, ipc.off_txd), 4, @intCast(i + 1));
    }
    const status = mailbox.read(reg(0, ipc.off_sta), 4);
    try std.testing.expectEqual(ipc.field.full, status & ipc.field.full);
    try std.testing.expectEqual(@as(u32, 4), mailbox.channels[0].pushes);
}

test "a word a full FIFO could not take is lost, latched and counted" {
    var mailbox = unit();
    for (0..ipc.fifo_depth + 2) |i| {
        mailbox.write(reg(0, ipc.off_txd), 4, @intCast(i + 1));
    }
    try std.testing.expectEqual(@as(u32, 2), mailbox.channels[0].lost);
    try std.testing.expectEqual(ipc.field.ferr, mailbox.read(reg(0, ipc.off_sta), 4) & ipc.field.ferr);
    // The stages hold the first four, not the last four.
    try std.testing.expectEqual(@as(u32, 1), mailbox.read(reg(0, ipc.off_rxd), 4));
}

test "a read of an empty FIFO is a message that never arrived" {
    var mailbox = unit();
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_rxd), 4));
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[0].starved);
    try std.testing.expectEqual(ipc.field.rerr, mailbox.read(reg(0, ipc.off_sta), 4) & ipc.field.rerr);
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[0].pops);
}

test "RCLR and FCLR drop the sticky latches, and only those" {
    var mailbox = unit();
    _ = mailbox.read(reg(0, ipc.off_rxd), 4);
    for (0..ipc.fifo_depth + 1) |i| {
        mailbox.write(reg(0, ipc.off_txd), 4, @intCast(i + 1));
    }
    mailbox.write(reg(0, ipc.off_clr), 4, ipc.field.rclr);
    var status = mailbox.read(reg(0, ipc.off_sta), 4);
    try std.testing.expectEqual(@as(u32, 0), status & ipc.field.rerr);
    try std.testing.expectEqual(ipc.field.ferr, status & ipc.field.ferr);
    mailbox.write(reg(0, ipc.off_clr), 4, ipc.field.fclr);
    status = mailbox.read(reg(0, ipc.off_sta), 4);
    try std.testing.expectEqual(@as(u32, 0), status & ipc.field.ferr);
}

test "RST empties the FIFO and drops RDY with it" {
    var mailbox = unit();
    mailbox.write(reg(3, ipc.off_txd), 4, 0xDEAD);
    mailbox.write(reg(3, ipc.off_txd), 4, 0xBEEF);
    mailbox.write(reg(3, ipc.off_clr), 4, ipc.field.rst);
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(3, ipc.off_sta), 4) & ipc.field.rdy);
    // And the next read finds nothing rather than the dropped words.
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(3, ipc.off_rxd), 4));
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[3].starved);
}

test "channels do not share a FIFO or a pending byte" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_txd), 4, 0x1111);
    mailbox.write(reg(0, ipc.off_iset), 4, 0x01);
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(1, ipc.off_sta), 4));
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[1].pushes);
}

test "the semaphore region is a lock now, not a shadow word" {
    var mailbox = unit();
    // dev answers 0 here and drops the store, so a claim never reads back.
    // Here the read itself takes IPCSEM4, so the next one is told it lost.
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(ipc.win_base + 0x10, 4));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), mailbox.read(ipc.win_base + 0x10, 4));
    try std.testing.expect(!mailbox.quiet());
}

test "a narrow store to the shadow keeps the bytes it does not name" {
    // 0x40 is the gap between the semaphore file and the NMI windows, one of
    // the stretches below the channels that nothing interprets.
    var mailbox = unit();
    mailbox.write(ipc.win_base + 0x40, 4, 0x5A5A_5A5A);
    mailbox.write(ipc.win_base + 0x40, 1, 0xC3);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5AC3), mailbox.read(ipc.win_base + 0x40, 4));
    try std.testing.expectEqual(@as(u32, 0x5A), mailbox.read(ipc.win_base + 0x43, 1));
}

test "a byte store to the top of ISET names no line" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_iset) + 1, 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_sta), 4));
    try std.testing.expect(!mailbox.raised);
}

test "an action register reads back nothing, a status register takes no store" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_iset), 4, 0x01);
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_iset), 4));
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_clr), 4));
    mailbox.write(reg(0, ipc.off_sta), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x01), mailbox.read(reg(0, ipc.off_sta), 4));
}

test "a narrow read of STA names the byte it asked for" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_txd), 4, 0x7777);
    try std.testing.expectEqual(@as(u32, 0x01), mailbox.read(reg(0, ipc.off_sta) + 2, 1));
}

test "a halfword load of RXD is refused and the stage stays where it was" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_txd), 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_rxd), 2));
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[0].narrow_reads);
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[0].pops);
    // The message is still there, whole, for the load that can carry it.
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), mailbox.read(reg(0, ipc.off_rxd), 4));
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[0].pops);
}

test "a byte load of RXD neither drains a stage nor latches RERR" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_txd), 4, 0x1122_3344);
    _ = mailbox.read(reg(0, ipc.off_rxd), 1);
    _ = mailbox.read(reg(0, ipc.off_rxd) + 2, 1);
    try std.testing.expectEqual(@as(u32, 2), mailbox.channels[0].narrow_reads);
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[0].starved);
    try std.testing.expect(!mailbox.channels[0].rerr);
    try std.testing.expectEqual(@as(u32, ipc.field.rdy), mailbox.read(reg(0, ipc.off_sta), 4));
}

test "a narrow store to TXD pushes nothing rather than a part-written message" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_txd), 2, 0xBEEF);
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[0].narrow_writes);
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[0].pushes);
    try std.testing.expectEqual(@as(u32, 0), mailbox.read(reg(0, ipc.off_sta), 4));
}

test "a word store to TXD still carries the whole message" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_txd), 4, 0xA5A5_5A5A);
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[0].narrow_writes);
    try std.testing.expectEqual(@as(u32, 0xA5A5_5A5A), mailbox.read(reg(0, ipc.off_rxd), 4));
}

test "ISET and CLR still take a narrow store on the lanes it names" {
    var mailbox = unit();
    mailbox.write(reg(0, ipc.off_iset), 1, 0x03);
    try std.testing.expectEqual(@as(u32, 0x03), mailbox.read(reg(0, ipc.off_sta), 4));
    mailbox.write(reg(0, ipc.off_clr), 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0x02), mailbox.read(reg(0, ipc.off_sta), 4));
    try std.testing.expectEqual(@as(u32, 0), mailbox.channels[0].narrow_writes);
}

test "a refused narrow access leaves the channel quiet on neither counter" {
    var mailbox = unit();
    _ = mailbox.read(reg(1, ipc.off_rxd), 2);
    mailbox.write(reg(1, ipc.off_txd), 1, 0x11);
    try std.testing.expect(!mailbox.channels[1].quiet());
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[1].narrow_reads);
    try std.testing.expectEqual(@as(u32, 1), mailbox.channels[1].narrow_writes);
}

test {
    _ = @import("repeat_test.zig");
}
