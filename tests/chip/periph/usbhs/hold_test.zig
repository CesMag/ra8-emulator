//! A bulk OUT packet the HAL marks valid (BVAL) before it arms the pipe
//! (PID=BUF): held, sent on arming, and dropped by a bus reset.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.usbhs_regs;
const usbhs_pipe = ra8.chip.periph.usbhs_pipe;
const xfer = ra8.chip.periph.usbhs_xfer;
const device = ra8.components.usb_echo;
const echo_far = ra8.components.usb_echo_far;

/// Put the device in Configured, so it has a bulk endpoint to take packets on.
fn configure(transfer: *xfer.Transfer) void {
    transfer.usbreq = 0x0500;
    transfer.usbval = 3;
    transfer.launch(true);
    transfer.usbreq = 0x0900;
    transfer.usbval = 1;
    transfer.launch(true);
}

test "BVAL before PID=BUF goes out the moment the pipe is armed" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    configure(&transfer);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0x33221100, 4, 64);
    transfer.commit(&pipes);
    try std.testing.expect(transfer.bemp & (@as(u16, 1) << 2) == 0);
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.pipeArmed(2, &pipes);
    try std.testing.expectEqual(@as(u16, 0), transfer.held);
    try std.testing.expect(transfer.bemp & (@as(u16, 1) << 2) != 0);
    try std.testing.expect(transfer_echo.echo_ready);
}

test "arming a pipe with nothing held sends nothing" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    configure(&transfer);
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.pipeArmed(2, &pipes);
    try std.testing.expectEqual(@as(u16, 0), transfer.bemp);
    try std.testing.expect(!transfer_echo.echo_ready);
}

test "a NAK write keeps a held packet held, and a bus reset drops it" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.port.select(regs.fifo.isel | 3);
    transfer.port.writeData(0x42, 1, 64);
    transfer.commit(&pipes);
    _ = pipes.setControl(3, 0);
    transfer.pipeArmed(3, &pipes);
    try std.testing.expectEqual(@as(u16, 1 << 3), transfer.held);
    transfer.busReset();
    try std.testing.expectEqual(@as(u16, 0), transfer.held);
}
