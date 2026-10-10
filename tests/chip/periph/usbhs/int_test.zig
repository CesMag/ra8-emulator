//! INTSTS0's latched summary bits: raised with the packet, acked W0C.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.usbhs.regs;
const usbhs_int = ra8.chip.periph.usbhs.int;

test "a fresh summary names nothing" {
    var summary = usbhs_int.Summary{};
    try std.testing.expectEqual(@as(u16, 0), summary.value());
}

test "ready and empty are separate bits" {
    var summary = usbhs_int.Summary{};
    summary.ready();
    try std.testing.expect(summary.value() & regs.int0.brdy != 0);
    try std.testing.expect(summary.value() & regs.int0.bemp == 0);
    summary.empty();
    try std.testing.expect(summary.value() & regs.int0.bemp != 0);
}

test "raising twice latches once" {
    var summary = usbhs_int.Summary{};
    summary.ready();
    const once = summary.value();
    summary.ready();
    try std.testing.expectEqual(once, summary.value());
}

test "a written zero clears its bit and a written one preserves it" {
    var summary = usbhs_int.Summary{};
    summary.ready();
    summary.empty();
    // ra8_usb_dispatch acks only the bits it read.
    summary.ack(~regs.int0.brdy);
    try std.testing.expectEqual(@as(u16, 0), summary.value() & regs.int0.brdy);
    try std.testing.expect(summary.value() & regs.int0.bemp != 0);
}

test "an ack of all ones clears nothing" {
    var summary = usbhs_int.Summary{};
    summary.ready();
    summary.ack(0xFFFF);
    try std.testing.expect(summary.value() & regs.int0.brdy != 0);
}

test "a bus reset drops both bits" {
    var summary = usbhs_int.Summary{};
    summary.ready();
    summary.empty();
    summary.busReset();
    try std.testing.expectEqual(@as(u16, 0), summary.value());
}

test "a bus reset leaves bits this model does not raise alone" {
    var summary = usbhs_int.Summary{};
    summary.bits = regs.int0.nrdy | regs.int0.brdy;
    summary.busReset();
    try std.testing.expectEqual(regs.int0.nrdy, summary.value());
}
