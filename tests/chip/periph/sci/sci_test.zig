//! Covers SCI_B registers and transmit gate; line capture is tested separately.
const std = @import("std");
const ra8 = @import("ra8");
const sci = ra8.chip.periph.sci;
comptime {
    _ = @import("input_test.zig");
    _ = @import("reply_test.zig");
}

/// Open a channel the way ra8_sci_open does: receiver and transmitter on.
fn open(unit: *sci.Sci, channel: usize) void {
    unit.write(sci.regAddress(channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
}

fn put(unit: *sci.Sci, channel: usize, text: []const u8) void {
    for (text) |byte| unit.write(sci.regAddress(channel, sci.off_tdr), 4, byte);
}

test "the transmitter reads drained so a polled put falls through" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const status = unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4);
    try std.testing.expect(status & sci.csr.tdre != 0);
    try std.testing.expect(status & sci.csr.tend != 0);
    try std.testing.expect(status & sci.csr.rxdmon != 0);
    try std.testing.expect(status & sci.csr.rdrf == 0);
}

test "a console line is latched on the newline that finishes it" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    put(&unit, sci.console_channel, "hello, ra8d2!\r\n");
    try std.testing.expectEqualStrings("hello, ra8d2!", unit.line.slice());
    try std.testing.expectEqual(@as(u32, 1), unit.line.lines);
    try std.testing.expectEqual(@as(u32, 15), unit.console().transmitted);
}

test "an unfinished line is not latched until its newline arrives" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    put(&unit, sci.console_channel, "first\nsecond");
    try std.testing.expectEqualStrings("first", unit.line.slice());
    put(&unit, sci.console_channel, "\n");
    try std.testing.expectEqualStrings("second", unit.line.slice());
}

test "a write with the transmitter disabled is dropped, not sent" {
    var unit = sci.Sci.init();
    put(&unit, sci.console_channel, "x");
    try std.testing.expectEqual(@as(u32, 0), unit.console().transmitted);
    try std.testing.expectEqual(@as(u32, 1), unit.console().unsent);
    try std.testing.expectEqual(@as(usize, 0), unit.line.slice().len);
}

test "a queued byte comes back out of RDR oldest first" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "ok");
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4) & sci.csr.rdrf != 0);
    try std.testing.expectEqual(@as(u32, 'o'), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    try std.testing.expectEqual(@as(u32, 'k'), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    try std.testing.expectEqual(@as(u32, 2), unit.console().received);
}

test "a queued byte stays queued while the receiver is disabled" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te);
    unit.feed(sci.console_channel, "z");
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4) & sci.csr.rdrf == 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
    open(&unit, sci.console_channel);
    try std.testing.expectEqual(@as(u32, 'z'), unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4));
}

test "the FIFO status registers follow the same queue" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_frsr), 4));
    unit.feed(sci.console_channel, "a");
    const frsr = unit.read(sci.regAddress(sci.console_channel, sci.off_frsr), 4);
    try std.testing.expect(frsr & sci.fifo.frsr_dr != 0);
    try std.testing.expect(frsr & sci.fifo.frsr_rdf != 0);
    const ftsr = unit.read(sci.regAddress(sci.console_channel, sci.off_ftsr), 4);
    try std.testing.expect(ftsr & sci.fifo.ftsr_tdfe != 0);
}

test "the flag-clear strobes read zero and clear nothing derived" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "q");
    unit.write(sci.regAddress(sci.console_channel, sci.off_cfclr), 4, 0x8000_0000);
    unit.write(sci.regAddress(sci.console_channel, sci.off_ffclr), 4, 0x0000_0001);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_cfclr), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(sci.console_channel, sci.off_ffclr), 4));
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4) & sci.csr.rdrf != 0);
}

test "channels do not share state" {
    var unit = sci.Sci.init();
    open(&unit, 0);
    open(&unit, sci.console_channel);
    put(&unit, 0, "binary");
    unit.feed(0, "r");
    try std.testing.expectEqual(@as(u32, 6), unit.channels[0].transmitted);
    try std.testing.expectEqual(@as(u32, 0), unit.console().transmitted);
    // Only the console channel carries text; SCI0 moves SPI frames, so its
    // traffic never reaches the line buffer.
    try std.testing.expectEqual(@as(usize, 0), unit.line.slice().len);
    try std.testing.expectEqual(@as(u32, 'r'), unit.read(sci.regAddress(0, sci.off_rdr), 4));
}

test "the control shadow reads back what the driver wrote" {
    var unit = sci.Sci.init();
    const value = sci.ccr0.te | sci.ccr0.re | sci.ccr0.rie;
    unit.write(sci.regAddress(3, sci.off_ccr0), 4, value);
    try std.testing.expectEqual(value, unit.read(sci.regAddress(3, sci.off_ccr0), 4));
    try std.testing.expect(unit.channels[3].enabled(sci.ccr0.rie));
    try std.testing.expect(!unit.channels[3].enabled(sci.ccr0.tie));
}

test "an untouched block stays out of the report" {
    var unit = sci.Sci.init();
    try std.testing.expect(unit.quiet());
    open(&unit, 1);
    try std.testing.expect(unit.quiet());
    put(&unit, 1, "!");
    try std.testing.expect(!unit.quiet());
}

test "the block covers every channel and nothing past the last one" {
    var unit = sci.Sci.init();
    const block = unit.block();
    try std.testing.expectEqual(sci.win_base, block.base);
    try std.testing.expectEqual(sci.win_span, block.size);
    try std.testing.expect(block.covers(sci.regAddress(sci.channels - 1, sci.off_csr)));
    try std.testing.expect(!block.covers(sci.win_base + sci.win_span));
}

test "no console event is due until the firmware arms one" {
    var unit = sci.Sci.init();
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "TXI and TEI are due while their enables stand with TE" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.tie | sci.ccr0.teie);
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 2), due.len);
    try std.testing.expectEqual(sci.event.txi, due.constSlice()[0]);
    try std.testing.expectEqual(sci.event.tei, due.constSlice()[1]);
}

test "an armed transmit interrupt with TE clear is not due" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.tie | sci.ccr0.teie);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "RXI is due only while a byte is actually queued" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.re | sci.ccr0.rie);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);

    unit.feed(sci.console_channel, "x");
    const due = unit.dueEvents();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(sci.event.rxi, due.constSlice()[0]);

    _ = unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

test "only the console channel raises events" {
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(0, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.tie);
    try std.testing.expectEqual(@as(usize, 0), unit.dueEvents().len);
}

/// A device that answers a fixed burst without the modem's own rules.
const Echo = struct {
    reply: []const u8 = "ok",
    on: u8 = '!',
    fed: u32 = 0,

    fn feed(context: *anyopaque, byte: u8) []const u8 {
        const self: *Echo = @ptrCast(@alignCast(context));
        self.fed += 1;
        return if (byte == self.on) self.reply else &.{};
    }

    fn device(self: *Echo) sci.Device {
        return .{ .context = self, .feedFn = feed };
    }
};

test "what a device drives back is queued for the firmware to read" {
    var unit = sci.Sci.init();
    var thing = Echo{};
    unit.attachDevice(7, thing.device());
    open(&unit, 7);
    put(&unit, 7, "a!");
    try std.testing.expectEqual(@as(u32, 2), thing.fed);
    try std.testing.expectEqual(@as(u32, 'o'), unit.read(sci.regAddress(7, sci.off_rdr), 4));
    try std.testing.expectEqual(@as(u32, 'k'), unit.read(sci.regAddress(7, sci.off_rdr), 4));
}

test "a reply arriving with the receiver disabled is lost, not banked" {
    var unit = sci.Sci.init();
    var thing = Echo{};
    unit.attachDevice(7, thing.device());
    unit.write(sci.regAddress(7, sci.off_ccr0), 4, sci.ccr0.te);
    put(&unit, 7, "!");
    try std.testing.expectEqual(@as(u32, 2), unit.channels[7].unheard);
    // Enabling the receiver afterwards does not bring the answer back.
    unit.write(sci.regAddress(7, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(7, sci.off_rdr), 4));
}

test "a byte the transmitter never sent never reaches the line" {
    var unit = sci.Sci.init();
    var thing = Echo{};
    unit.attachDevice(7, thing.device());
    unit.write(sci.regAddress(7, sci.off_ccr0), 4, sci.ccr0.re);
    put(&unit, 7, "!");
    try std.testing.expectEqual(@as(u32, 0), thing.fed);
    try std.testing.expectEqual(@as(u32, 1), unit.channels[7].unsent);
}

test "a channel with nothing on its line is unchanged" {
    var unit = sci.Sci.init();
    open(&unit, 7);
    put(&unit, 7, "AT\r");
    try std.testing.expectEqual(@as(u32, 3), unit.channels[7].transmitted);
    try std.testing.expectEqual(@as(u32, 0), unit.read(sci.regAddress(7, sci.off_rdr), 4));
}

test "a device goes on one channel only" {
    var unit = sci.Sci.init();
    var thing = Echo{};
    unit.attachDevice(7, thing.device());
    open(&unit, 8);
    put(&unit, 8, "!");
    try std.testing.expectEqual(@as(u32, 0), thing.fed);
}

test "a byte poll of CSR's top byte sees TDRE, which is bit 29" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const top = unit.read(sci.regAddress(sci.console_channel, sci.off_csr) + 3, 1);
    try std.testing.expect(top & (sci.csr.tdre >> 24) != 0);
    try std.testing.expect(top & (sci.csr.tend >> 24) != 0);
}

test "a halfword poll of CSR's low half sees RXDMON, which is bit 15" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const low = unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 2);
    try std.testing.expect(low & sci.csr.rxdmon != 0);
}

test "a byte read of FTSR carries TDFE" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const byte = unit.read(sci.regAddress(sci.console_channel, sci.off_ftsr), 1);
    try std.testing.expect(byte & sci.fifo.ftsr_tdfe != 0);
}

test "a byte store to CCR0 leaves the interrupt enables above it alone" {
    var unit = sci.Sci.init();
    const at = sci.regAddress(sci.console_channel, sci.off_ccr0);
    unit.write(at, 4, sci.ccr0.te | sci.ccr0.tie);
    unit.write(at, 1, sci.ccr0.te | sci.ccr0.re);
    try std.testing.expectEqual(
        sci.ccr0.te | sci.ccr0.re | sci.ccr0.tie,
        unit.read(at, 4),
    );
}

test "a byte-wide polled put still sends, and the console line captures it" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const tdr = sci.regAddress(sci.console_channel, sci.off_tdr);
    for ("hi\n") |byte| unit.write(tdr, 1, byte);
    try std.testing.expectEqual(@as(u32, 3), unit.console().transmitted);
    try std.testing.expectEqualStrings("hi", unit.line.slice());
}

test "a narrow store above TDAT carries no character, and is counted" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.write(sci.regAddress(sci.console_channel, sci.off_tdr) + 1, 1, 'Z');
    try std.testing.expectEqual(@as(u32, 0), unit.console().transmitted);
    try std.testing.expectEqual(@as(u32, 1), unit.console().unnamed_stores);
}

test "a byte load above RDAT takes nothing and leaves the byte queued" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "A");
    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 0), unit.read(rdr + 1, 1));
    try std.testing.expectEqual(@as(u32, 1), unit.console().unnamed_reads);
    try std.testing.expectEqual(@as(u32, 0), unit.console().received);
    try std.testing.expectEqual(@as(u32, 'A'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.console().received);
}

test "a halfword load of RDR's top half takes nothing either" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "hi");
    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 0), unit.read(rdr + 2, 2));
    try std.testing.expectEqual(@as(u32, 1), unit.console().unnamed_reads);
    try std.testing.expectEqual(@as(u32, 'h'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 'i'), unit.read(rdr, 4));
}

test "a refused load leaves RDRF standing for the load that names RDAT" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "q");
    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    _ = unit.read(rdr + 3, 1);
    const status = unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4);
    try std.testing.expect(status & sci.csr.rdrf != 0);
    try std.testing.expectEqual(@as(u32, 'q'), unit.read(rdr, 1));
}

test "a byte or halfword load that names RDAT still carries the character" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.feed(sci.console_channel, "no");
    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 'n'), unit.read(rdr, 1));
    try std.testing.expectEqual(@as(u32, 'o'), unit.read(rdr, 2));
    try std.testing.expectEqual(@as(u32, 2), unit.console().received);
    try std.testing.expectEqual(@as(u32, 0), unit.console().unnamed_reads);
}

test "a refused load of an empty RDR is still counted and takes nothing" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 0), unit.read(rdr + 1, 1));
    try std.testing.expectEqual(@as(u32, 1), unit.console().unnamed_reads);
    try std.testing.expectEqual(@as(u32, 0), unit.console().received);
}

test "a store to CSR is refused and counted, and the word still derives" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const at = sci.regAddress(sci.console_channel, sci.off_csr);
    unit.write(at, 4, 0);
    unit.write(at + 3, 1, 0);
    try std.testing.expectEqual(@as(u32, 2), unit.console().status_stores);
    try std.testing.expect(unit.read(at, 4) & sci.csr.tdre != 0);
}

test "a store to FRSR or FTSR is refused the same way" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.write(sci.regAddress(sci.console_channel, sci.off_frsr), 4, 0xFFFF_FFFF);
    unit.write(sci.regAddress(sci.console_channel, sci.off_ftsr), 4, 0);
    try std.testing.expectEqual(@as(u32, 2), unit.console().status_stores);
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_ftsr), 4) & sci.fifo.ftsr_tdfe != 0);
}

test "the clear strobes are accepted no-ops, not refusals" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    unit.write(sci.regAddress(sci.console_channel, sci.off_cfclr), 4, 0xFFFF_FFFF);
    unit.write(sci.regAddress(sci.console_channel, sci.off_ffclr), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.console().status_stores);
    try std.testing.expect(unit.read(sci.regAddress(sci.console_channel, sci.off_csr), 4) & sci.csr.tdre != 0);
}

fn flood(unit: *sci.Sci, channel: usize) void {
    var block: [sci.limits.rx_queue + 8]u8 = undefined;
    @memset(&block, 'q');
    unit.feed(channel, &block);
}

// The clear-errors sequence clears ORER bit 24 only at CFCLR+3.
test "an overrun shows up in CSR and only ORERC's lane clears it" {
    var unit = sci.Sci.init();
    open(&unit, sci.console_channel);
    const csr = sci.regAddress(sci.console_channel, sci.off_csr);
    const cfclr = sci.regAddress(sci.console_channel, sci.off_cfclr);
    flood(&unit, sci.console_channel);
    try std.testing.expect(unit.read(csr, 4) & sci.csr.orer != 0);
    while (unit.read(sci.regAddress(sci.console_channel, sci.off_rdr), 4) != 0) {}
    try std.testing.expect(unit.read(csr, 4) & sci.csr.orer != 0);
    unit.write(cfclr, 1, 0x01);
    try std.testing.expect(unit.read(csr, 4) & sci.csr.orer != 0);
    unit.write(cfclr + 3, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0), unit.read(csr, 4) & sci.csr.orer);
    try std.testing.expectEqual(@as(u32, 1), unit.console().errors.overruns);
}
