//! The INTSTS0 summary over the control transfer: BRDY and BEMP latch
//! alongside their per-pipe bits, so a driver dispatching on the mask sees
//! the same packets a poller does.
const std = @import("std");
const ra8 = @import("ra8");
const device = ra8.components.usb_echo;
const echo_far = ra8.components.usb_echo_far;
const regs = ra8.chip.periph.usbhs_regs;
const usbhs_pipe = ra8.chip.periph.usbhs_pipe;
const xfer = ra8.chip.periph.usbhs_xfer;

fn getDescriptor(transfer: *xfer.Transfer, kind: u16, length: u16) void {
    transfer.usbreq = 0x0680;
    transfer.usbval = kind;
    transfer.usbindx = 0;
    transfer.usbleng = length;
    transfer.launch(true);
}

test "a control reply raises the INTSTS0 summary, not just BRDYSTS" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    try std.testing.expectEqual(@as(u16, 0), transfer.interruptStatus(&pipes));
    getDescriptor(&transfer, 0x0100, 18);
    // The dispatcher reads the mask and never touches BRDYSTS itself.
    try std.testing.expect(transfer.interruptStatus(&pipes) & regs.int0.brdy != 0);
    try std.testing.expect(transfer.brdy & regs.status.dcp != 0);
}

test "a staged packet going out raises the INTSTS0 empty summary" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.port.select(regs.fifo.isel);
    transfer.port.writeData(0xAA, 1, 64);
    transfer.commit(&pipes);
    try std.testing.expect(transfer.interruptStatus(&pipes) & regs.int0.bemp != 0);
    try std.testing.expect(transfer.interruptStatus(&pipes) & regs.int0.brdy == 0);
}

test "a new packet re-raises the summary after it was acked" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer, 0x0100, 18);
    _ = transfer.interruptStatus(&pipes);
    transfer.clearInterrupt(~regs.int0.brdy);
    transfer.clearReady(~regs.status.dcp);
    getDescriptor(&transfer, 0x0100, 18);
    try std.testing.expect(transfer.interruptStatus(&pipes) & regs.int0.brdy != 0);
}

test "nothing on the bus raises no summary at all" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.usbreq = 0x0680;
    transfer.usbleng = 18;
    transfer.launch(false);
    try std.testing.expectEqual(@as(u16, 0), transfer.interruptStatus(&pipes));
}
