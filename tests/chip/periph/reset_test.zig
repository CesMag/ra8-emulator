//! Covers src/chip/periph/reset.zig: the reset-cause registers, the write-zero-to
//! -clear ack, and the watchdog's request for a reboot.
const std = @import("std");
const ra8 = @import("ra8");

const reset = ra8.chip.periph.reset;

const r0 = reset.rstsr0.base;
const r1 = reset.rstsr1.base;

test "a cold boot reads back a power-on reset and nothing else" {
    var unit = reset.Reset.init();
    try std.testing.expectEqual(@as(u32, reset.cause.porf), unit.read(r0, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(r1, 4));
    try std.testing.expect(unit.quiet());
}

test "a watchdog reset clears PORF and latches WDTRF" {
    var unit = reset.Reset.init();
    unit.request(.watchdog);
    try std.testing.expectEqual(@as(u32, 0), unit.read(r0, 1));
    try std.testing.expectEqual(@as(u32, reset.cause.wdtrf), unit.read(r1, 4));
    try std.testing.expect(unit.latched(reset.cause.wdtrf));
    try std.testing.expect(!unit.latched(reset.cause.swrf));
}

test "the request is handed over once, so one underflow is one reboot" {
    var unit = reset.Reset.init();
    unit.request(.watchdog);
    try std.testing.expectEqual(reset.Source.watchdog, unit.takeRequest().?);
    try std.testing.expectEqual(@as(?reset.Source, null), unit.takeRequest());
    // The cause stays latched after the request is taken: that is the whole
    // point of it, the firmware coming back up reads it.
    try std.testing.expect(unit.latched(reset.cause.wdtrf));
    try std.testing.expectEqual(@as(u32, 1), unit.requests);
}

test "a software reset and a watchdog reset can both be latched" {
    var unit = reset.Reset.init();
    unit.setCause(.software);
    unit.setCause(.iwdt);
    try std.testing.expectEqual(
        @as(u32, reset.cause.swrf | reset.cause.iwdtrf),
        unit.read(r1, 4),
    );
}

test "a written zero clears the cause flag" {
    var unit = reset.Reset.init();
    unit.setCause(.watchdog);
    unit.write(r1, 4, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(r1, 4));
    try std.testing.expectEqual(@as(u32, 0), unit.bad_acks);
}

test "a written one leaves the flag standing and counts as a bad ack" {
    var unit = reset.Reset.init();
    unit.setCause(.watchdog);
    // The polarity that catches drivers: elsewhere a status flag is cleared
    // by writing a one, and here that keeps the bit.
    unit.write(r1, 4, reset.cause.wdtrf);
    try std.testing.expectEqual(@as(u32, reset.cause.wdtrf), unit.read(r1, 4));
    try std.testing.expectEqual(@as(u32, 1), unit.bad_acks);
}

test "clearing one cause flag leaves the others alone" {
    var unit = reset.Reset.init();
    unit.setCause(.watchdog);
    unit.setCause(.software);
    unit.write(r1, 4, ~reset.cause.wdtrf);
    try std.testing.expect(!unit.latched(reset.cause.wdtrf));
    try std.testing.expect(unit.latched(reset.cause.swrf));
}

test "PORF clears on a written zero the same way" {
    var unit = reset.Reset.init();
    unit.write(r0, 1, 0);
    try std.testing.expectEqual(@as(u32, 0), unit.read(r0, 1));
}

test "a write of one at PORF keeps it and is counted" {
    var unit = reset.Reset.init();
    unit.write(r0, 1, reset.cause.porf);
    try std.testing.expectEqual(@as(u32, reset.cause.porf), unit.read(r0, 1));
    try std.testing.expectEqual(@as(u32, 1), unit.bad_acks);
}

test "a write at a flag that is already clear acks nothing" {
    var unit = reset.Reset.init();
    unit.write(r0, 1, 0);
    unit.write(r0, 1, reset.cause.porf);
    try std.testing.expectEqual(@as(u32, 0), unit.bad_acks);
}

test "CWSF is a plain bit, set by a written one and not a cause flag" {
    var unit = reset.Reset.init();
    unit.write(r0 + reset.rstsr0.off_r2, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0x01), unit.read(r0 + reset.rstsr0.off_r2, 1));
    unit.write(r0 + reset.rstsr0.off_r3, 1, 0x02);
    try std.testing.expectEqual(@as(u32, 0x02), unit.read(r0 + reset.rstsr0.off_r3, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.bad_acks);
}

test "RSTSR1 answers a byte read at its own offset" {
    var unit = reset.Reset.init();
    unit.setCause(.watchdog);
    try std.testing.expectEqual(@as(u32, reset.cause.wdtrf), unit.read(r1, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(r1 + 1, 1));
}

test "an address inside the window but past the three registers reads zero" {
    var unit = reset.Reset.init();
    try std.testing.expectEqual(@as(u32, 0), unit.read(r0 + 0x02, 1));
}

test "the block descriptors claim the two windows and nothing between them" {
    var unit = reset.Reset.init();
    const status = unit.statusBlock();
    const cause_block = unit.causeBlock();
    try std.testing.expect(status.covers(r1));
    try std.testing.expect(!status.covers(r0));
    try std.testing.expect(cause_block.covers(r0));
    try std.testing.expect(cause_block.covers(r0 + reset.rstsr0.off_r3));
    try std.testing.expect(!cause_block.covers(r0 + reset.rstsr0.span));
}

test "a run that only ever booted cold stays out of the report" {
    var unit = reset.Reset.init();
    try std.testing.expect(unit.quiet());
    unit.write(r0, 1, 0);
    try std.testing.expect(unit.quiet());
    unit.setCause(.watchdog);
    try std.testing.expect(!unit.quiet());
}

test "the cause names are the ones the report prints" {
    try std.testing.expectEqualStrings("WDT", reset.name(.watchdog));
    try std.testing.expectEqualStrings("IWDT", reset.name(.iwdt));
    try std.testing.expectEqualStrings("SW", reset.name(.software));
}
