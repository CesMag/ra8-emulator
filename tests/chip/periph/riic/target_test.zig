//! The RIIC target role: the synthetic controller's write-then-read script,
//! and the own address it refuses to answer at.
const std = @import("std");
const ra8 = @import("ra8");
const target = ra8.chip.periph.riic.target;
const flag = ra8.chip.periph.riic.flags;
const bus = ra8.chip.periph.riic.bus;

/// SARL registers hold the address byte, so a 7-bit own address of 0x21 sits
/// in the register as 0x42.
fn own(address: u7) [3]u8 {
    return .{ bus.wire.byte(address, false), 0, 0 };
}

test "an idle responder matches nothing" {
    var responder = target.Target{};
    try std.testing.expect(responder.quiet());
    try std.testing.expectEqual(@as(u8, 0), responder.matched());
    try std.testing.expectEqual(@as(u8, 0), responder.receive());
}

test "ICSER with a slot enabled arms the write phase" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    try std.testing.expect(responder.armed);
    try std.testing.expectEqual(target.Phase.writing, responder.phase);
    try std.testing.expectEqual(@as(u7, 0x21), responder.own_address);
    try std.testing.expectEqual(flag.icsr2.rdrf, responder.status);
}

test "ICSER with no slot enabled disarms it again" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    responder.open(0, own(0x21));
    try std.testing.expect(!responder.armed);
    try std.testing.expectEqual(target.Phase.idle, responder.phase);
}

test "an own address of zero is not an own address" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, .{ 0, 0, 0 });
    try std.testing.expect(!responder.armed);
    try std.testing.expectEqual(@as(u32, 1), responder.unaddressed);
    // dev latched it and answered at the general call address instead.
    try std.testing.expectEqual(@as(u7, 0), responder.own_address);
}

test "the enabled slot decides which own address is used" {
    var responder = target.Target{};
    responder.open(flag.icser.sar1e, .{ 0x42, 0x54, 0x66 });
    try std.testing.expectEqual(@as(u7, 0x2A), responder.own_address);
    responder.open(flag.icser.sar2e, .{ 0x42, 0x54, 0x66 });
    try std.testing.expectEqual(@as(u7, 0x33), responder.own_address);
}

/// Drain the controller's write the way the driver does: the dummy address
/// read, both payload bytes, then the store that clears the STOP the last of
/// them raised. That clear is what opens the read phase.
fn drainWrite(responder: *target.Target) void {
    _ = responder.receive();
    _ = responder.receive();
    _ = responder.receive();
    responder.acknowledge(~flag.icsr2.stop);
}

test "the write phase serves the address byte, then the payload" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    try std.testing.expectEqual(bus.wire.byte(0x21, false), responder.receive());
    try std.testing.expectEqual(target.script.payload[0], responder.receive());
    try std.testing.expectEqual(flag.icsr2.rdrf, responder.status);
    try std.testing.expectEqual(target.script.payload[1], responder.receive());
    try std.testing.expectEqual(flag.icsr2.stop, responder.status);
}

test "the own-address match holds through both phases and drops after" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    try std.testing.expectEqual(flag.icsr1.aas0, responder.matched());
    drainWrite(&responder);
    try std.testing.expectEqual(flag.icsr1.aas0, responder.matched());
}

test "TRS is asserted only while the controller is reading" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    try std.testing.expectEqual(@as(u8, 0), responder.direction(0) & flag.iccr2.trs);
    drainWrite(&responder);
    try std.testing.expectEqual(flag.iccr2.trs, responder.direction(0) & flag.iccr2.trs);
}

test "a matching echo runs the script to completion" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    var cycle: u32 = 0;
    while (cycle < target.script.cycles) : (cycle += 1) {
        drainWrite(&responder);
        for (target.script.payload) |byte| responder.transmit(byte);
        responder.acknowledge(~(flag.icsr2.nackf | flag.icsr2.stop));
    }
    try std.testing.expectEqual(target.script.cycles, responder.cycles);
    try std.testing.expect(!responder.mismatched);
    try std.testing.expectEqual(target.Phase.done, responder.phase);
    try std.testing.expectEqual(@as(u8, 0), responder.status);
}

test "a wrong echo is a mismatch" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    drainWrite(&responder);
    responder.transmit(0xDE);
    responder.transmit(0x00);
    responder.acknowledge(0);
    try std.testing.expect(responder.mismatched);
    try std.testing.expectEqual(@as(u32, 1), responder.cycles);
}

test "a short echo is a mismatch too" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    drainWrite(&responder);
    responder.transmit(target.script.payload[0]);
    responder.status |= flag.icsr2.nackf;
    responder.acknowledge(0);
    try std.testing.expect(responder.mismatched);
}

test "a byte transmitted outside the read phase goes nowhere" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    responder.transmit(0xFF);
    try std.testing.expectEqual(@as(usize, 0), responder.echoed);
}

test "the capture buffer bounds a firmware that will not stop talking" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    drainWrite(&responder);
    var sent: usize = 0;
    while (sent < target.script.capture + 4) : (sent += 1) responder.transmit(0xAA);
    try std.testing.expectEqual(target.script.capture + 4, responder.echoed);
    responder.acknowledge(0);
    try std.testing.expect(responder.mismatched);
}

test "the controller NACKs the last byte it wanted" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    drainWrite(&responder);
    try std.testing.expectEqual(@as(u8, 0), responder.status & flag.icsr2.nackf);
    responder.transmit(target.script.payload[0]);
    try std.testing.expectEqual(@as(u8, 0), responder.status & flag.icsr2.nackf);
    responder.transmit(target.script.payload[1]);
    try std.testing.expectEqual(flag.icsr2.nackf, responder.status & flag.icsr2.nackf);
    try std.testing.expectEqual(flag.icsr2.stop, responder.status & flag.icsr2.stop);
    try std.testing.expectEqual(@as(u32, 1), responder.nacked);
}

test "TDRE stays up under the NACK, so the send loop never waits it out" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    drainWrite(&responder);
    for (target.script.payload) |byte| responder.transmit(byte);
    try std.testing.expectEqual(flag.icsr2.tdre, responder.status & flag.icsr2.tdre);
    try std.testing.expectEqual(flag.icsr2.tend, responder.status & flag.icsr2.tend);
}

test "clearing RDRF between payload bytes does not open the read phase" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    _ = responder.receive();
    responder.acknowledge(~flag.icsr2.rdrf);
    try std.testing.expectEqual(target.Phase.writing, responder.phase);
    try std.testing.expectEqual(target.script.payload[0], responder.receive());
}

test "clearing the error flags mid-frame does not skip the script forward" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    const errors = flag.icsr2.al | flag.icsr2.nackf | flag.icsr2.tmof;
    responder.acknowledge(~errors);
    try std.testing.expectEqual(target.Phase.writing, responder.phase);
    try std.testing.expectEqual(@as(u32, 0), responder.cycles);
}

test "a store clearing nothing at all leaves the phase where it was" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    drainWrite(&responder);
    responder.acknowledge(0xFF);
    try std.testing.expectEqual(target.Phase.reading, responder.phase);
}

test "the read phase ends on the fall of NACKF, not on any store" {
    var responder = target.Target{};
    responder.open(flag.icser.sar0e, own(0x21));
    drainWrite(&responder);
    for (target.script.payload) |byte| responder.transmit(byte);
    responder.acknowledge(~flag.icsr2.stop);
    try std.testing.expectEqual(target.Phase.reading, responder.phase);
    try std.testing.expectEqual(@as(u32, 0), responder.cycles);
    responder.acknowledge(~flag.icsr2.nackf);
    try std.testing.expectEqual(@as(u32, 1), responder.cycles);
    try std.testing.expect(!responder.mismatched);
}
