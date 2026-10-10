//! The control transfer: a SETUP launched, a data stage drained, a status
//! stage completed, and the steps that are refused.
const std = @import("std");
const ra8 = @import("ra8");
const device = ra8.components.usb_echo;
const echo_far = ra8.components.usb_echo.far;
const regs = ra8.chip.periph.usbhs.regs;
const usbhs_pipe = ra8.chip.periph.usbhs.pipe;
const xfer = ra8.chip.periph.usbhs.xfer;

fn getDescriptor(transfer: *xfer.Transfer, kind: u16, length: u16) void {
    transfer.usbreq = 0x0680;
    transfer.usbval = kind;
    transfer.usbindx = 0;
    transfer.usbleng = length;
    transfer.launch(true);
}

test "a SETUP needs something on the bus that has been reset" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.usbreq = 0x0680;
    transfer.usbleng = 18;
    // dev delivered the token whatever the port said.
    transfer.launch(false);
    try std.testing.expectEqual(@as(u32, 1), transfer.no_device);
    try std.testing.expectEqual(@as(u32, 0), transfer.setups);
    try std.testing.expect(!transfer.in_flight);
}

test "a SETUP nothing answered latches SIGN, not silence" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.usbreq = 0x0680;
    transfer.usbleng = 18;
    transfer.launch(false);
    try std.testing.expect(transfer.intsts1 & regs.int1.sign != 0);
    try std.testing.expect(transfer.intsts1 & regs.int1.sack == 0);
}

test "the driver W0C-clears the latch and the next launch sets it again" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.usbreq = 0x0680;
    transfer.usbleng = 18;
    transfer.launch(false);
    try std.testing.expect(transfer.intsts1 & regs.int1.sign != 0);
    transfer.intsts1 &= ~regs.int1.sign;
    try std.testing.expectEqual(@as(u16, 0), transfer.intsts1);
    transfer.launch(false);
    try std.testing.expect(transfer.intsts1 & regs.int1.sign != 0);
    try std.testing.expectEqual(@as(u32, 2), transfer.no_device);
}

test "exactly one of SACK and SIGN comes back from a launch" {
    var dead_echo: device.Device = .{};
    var dead = xfer.Transfer{ .far = echo_far.far(&dead_echo) };
    dead.usbreq = 0x0680;
    dead.usbval = 0x0100;
    dead.usbleng = 18;
    dead.launch(false);
    try std.testing.expectEqual(regs.int1.sign, dead.intsts1);

    var live_echo: device.Device = .{};
    var live = xfer.Transfer{ .far = echo_far.far(&live_echo) };
    getDescriptor(&live, 0x0100, 18);
    try std.testing.expectEqual(regs.int1.sack, live.intsts1);
}

test "an acked SETUP latches SACK" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    getDescriptor(&transfer, 0x0100, 18);
    try std.testing.expectEqual(@as(u32, 1), transfer.setups);
    try std.testing.expect(transfer.intsts1 & regs.int1.sack != 0);
    try std.testing.expect(transfer.control_read);
}

test "a refused request still ACKs the token it arrived on" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    getDescriptor(&transfer, 0x0300, 4);
    try std.testing.expectEqual(@as(u32, 1), transfer.stalls);
    // The token reached a device, so SACK. What the device would not do
    // with the request is a later stage's business, not the token's.
    try std.testing.expect(transfer.intsts1 & regs.int1.sack != 0);
    try std.testing.expect(transfer.intsts1 & regs.int1.sign == 0);
    try std.testing.expect(!transfer.in_flight);
}

test "a refused request parks the DCP at PID=STALL" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    getDescriptor(&transfer, 0x0300, 4);
    try std.testing.expectEqual(@as(u32, 1), transfer.stalls);
    try std.testing.expectEqual(
        regs.dcpctr.pid_stall,
        transfer.dcpctr & regs.dcpctr.pid_mask,
    );
}

test "a request the device honours leaves the PID field alone" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.dcpctr = regs.dcpctr.pid_buf;
    getDescriptor(&transfer, 0x0100, 18);
    try std.testing.expectEqual(@as(u32, 0), transfer.stalls);
    try std.testing.expectEqual(
        regs.dcpctr.pid_buf,
        transfer.dcpctr & regs.dcpctr.pid_mask,
    );
}

test "the stall lands in the PID field and disturbs nothing else" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.dcpctr = regs.dcpctr.ccpl | regs.dcpctr.bsts;
    getDescriptor(&transfer, 0x0300, 4);
    try std.testing.expect(transfer.dcpctr & regs.dcpctr.ccpl != 0);
    try std.testing.expect(transfer.dcpctr & regs.dcpctr.bsts != 0);
    try std.testing.expectEqual(
        regs.dcpctr.pid_stall,
        transfer.dcpctr & regs.dcpctr.pid_mask,
    );
}

test "a dead-bus launch stalls nothing: there was no device to refuse it" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.usbreq = 0x0680;
    transfer.usbval = 0x0300;
    transfer.usbleng = 4;
    transfer.launch(false);
    try std.testing.expectEqual(@as(u16, 0), transfer.dcpctr & regs.dcpctr.pid_mask);
    try std.testing.expectEqual(@as(u32, 0), transfer.stalls);
}

test "an unsupported request code ACKs too" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    // bRequest is USBREQ's HIGH byte; 0xFF is no chapter-9 request.
    transfer.usbreq = 0xFF00;
    transfer.usbleng = 0;
    transfer.launch(true);
    try std.testing.expectEqual(@as(u32, 1), transfer.stalls);
    try std.testing.expectEqual(regs.int1.sack, transfer.intsts1);
}

test "a SET_CONFIGURATION out of order ACKs and stalls" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.usbreq = 0x0900;
    transfer.usbval = 1;
    transfer.usbleng = 0;
    transfer.launch(true);
    try std.testing.expectEqual(@as(u32, 1), transfer.stalls);
    try std.testing.expectEqual(regs.int1.sack, transfer.intsts1);
}

test "the device's answer shows up on the ready register the host polls" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer, 0x0100, 18);
    const ready = transfer.readyStatus(&pipes);
    try std.testing.expect(ready & regs.status.dcp != 0);
    transfer.port.select(0);
    try std.testing.expectEqual(regs.fifo.frdy | 18, transfer.port.status());
    // The descriptor's own first two bytes: length 18, type 1.
    try std.testing.expectEqual(@as(u32, 0x0112), transfer.port.readData(2));
}

test "the answer is latched once, not on every poll" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer, 0x0100, 18);
    _ = transfer.readyStatus(&pipes);
    transfer.port.select(0);
    _ = transfer.port.readData(4);
    _ = transfer.readyStatus(&pipes);
    try std.testing.expectEqual(@as(u16, 14), transfer.port.in[0].remaining());
}

test "a CCPL with nothing in flight is refused" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    // dev ran the status stage on any store with the bit set.
    transfer.complete();
    try std.testing.expectEqual(@as(u32, 1), transfer.stray_ccpl);
    try std.testing.expectEqual(@as(u16, 0), transfer.brdy);
}

test "a control write's status stage is a zero-length IN packet" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.usbreq = 0x0500; // SET_ADDRESS
    transfer.usbval = 5;
    transfer.usbleng = 0;
    transfer.launch(true);
    transfer.complete();
    try std.testing.expect(transfer.brdy & regs.status.dcp != 0);
    try std.testing.expectEqual(@as(u16, 0), transfer.port.in[0].remaining());
    try std.testing.expectEqual(@as(u8, 5), transfer_echo.address);
}

test "a control read's status stage reports the buffer empty" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    getDescriptor(&transfer, 0x0100, 18);
    transfer.complete();
    try std.testing.expect(transfer.bemp & regs.status.dcp != 0);
}

test "a ready bit clears by writing zero to it" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    transfer.brdy = 0x0005;
    transfer.clearReady(0x0004);
    try std.testing.expectEqual(@as(u16, 0x0004), transfer.brdy);
}

test "a bulk packet on a pipe the host never armed moves nothing" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0x42, 1, 64);
    transfer.commit(&pipes);
    // dev committed whatever PIPECTR said, NAK included. The buffer is valid
    // and held for the pipe, not sent and not refused.
    try std.testing.expectEqual(@as(u16, 1 << 2), transfer.held);
    try std.testing.expectEqual(@as(u32, 0), transfer.refusals());
    try std.testing.expect(!transfer_echo.echo_ready);
}

test "an armed bulk pipe delivers to a configured device and raises BEMP" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.usbreq = 0x0500;
    transfer.usbval = 3;
    transfer.launch(true);
    transfer.usbreq = 0x0900; // SET_CONFIGURATION
    transfer.usbval = 1;
    transfer.launch(true);
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0x33221100, 4, 64);
    transfer.commit(&pipes);
    try std.testing.expect(transfer.bemp & (@as(u16, 1) << 2) != 0);
    try std.testing.expect(transfer_echo.echo_ready);
}

test "the echo comes back on an armed IN pipe" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.usbreq = 0x0500;
    transfer.usbval = 3;
    transfer.launch(true);
    transfer.usbreq = 0x0900;
    transfer.usbval = 1;
    transfer.launch(true);
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0xBEEF, 2, 64);
    transfer.commit(&pipes);
    pipes.pipes[2].in = true;
    const ready = transfer.readyStatus(&pipes);
    try std.testing.expect(ready & (@as(u16, 1) << 2) != 0);
    transfer.port.select(2);
    try std.testing.expectEqual(@as(u32, 0xBEEF), transfer.port.readData(2));
}

test "a bus reset clears the flags and the staging with the device" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer, 0x0100, 18);
    _ = transfer.readyStatus(&pipes);
    transfer.busReset();
    try std.testing.expectEqual(@as(u16, 0), transfer.brdy);
    try std.testing.expectEqual(@as(u16, 0), transfer.port.in[0].len);
    try std.testing.expectEqual(device.State.default, transfer_echo.state);
    try std.testing.expect(!transfer.in_flight);
}

test "a fresh transfer is quiet" {
    const transfer = xfer.Transfer{};
    try std.testing.expect(transfer.quiet());
    try std.testing.expectEqual(@as(u32, 0), transfer.refusals());
}

test "a packet the device refuses stays staged instead of vanishing" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    // Armed pipe, but the device is still in Default: no bulk endpoint yet.
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0xBEEF, 2, 64);
    transfer.commit(&pipes);
    try std.testing.expectEqual(@as(u16, 0), transfer.bemp);
    try std.testing.expectEqual(@as(u32, 1), transfer.refused_out);
    try std.testing.expectEqual(@as(u32, 2), transfer.refused_bytes);
    // The bytes the host wrote are still in the buffer.
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xEF, 0xBE },
        transfer.port.out[2].staged(),
    );
}

test "the refused packet goes out on the next BVAL, once the device is configured" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0xBEEF, 2, 64);
    transfer.commit(&pipes);
    try std.testing.expectEqual(@as(u32, 1), transfer.refused_out);
    // Enumerate, then hand the same staged packet over again.
    transfer.usbreq = 0x0500;
    transfer.usbval = 3;
    transfer.launch(true);
    transfer.usbreq = 0x0900;
    transfer.usbval = 1;
    transfer.launch(true);
    transfer.commit(&pipes);
    try std.testing.expect(transfer.bemp & (@as(u16, 1) << 2) != 0);
    try std.testing.expect(transfer_echo.echo_ready);
    try std.testing.expectEqual(@as(u16, 0), transfer.port.out[2].len);
    try std.testing.expectEqual(@as(u32, 1), transfer.refused_out);
}

test "a taken packet empties the buffer" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.usbreq = 0x0500;
    transfer.usbval = 3;
    transfer.launch(true);
    transfer.usbreq = 0x0900;
    transfer.usbval = 1;
    transfer.launch(true);
    _ = pipes.setControl(2, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 2);
    transfer.port.writeData(0x44332211, 4, 64);
    transfer.commit(&pipes);
    try std.testing.expectEqual(@as(u16, 0), transfer.port.out[2].len);
    try std.testing.expectEqual(@as(u32, 0), transfer.refused_out);
}

test "a refused packet counts as a refusal the run can report" {
    var transfer_echo: device.Device = .{};
    var transfer = xfer.Transfer{ .far = echo_far.far(&transfer_echo) };
    var pipes = usbhs_pipe.Table{};
    _ = pipes.setControl(1, regs.pipe.pid_buf);
    transfer.port.select(regs.fifo.isel | 1);
    transfer.port.writeData(0xAA, 1, 64);
    transfer.commit(&pipes);
    try std.testing.expect(!transfer.quiet());
    try std.testing.expect(transfer.refusals() >= 1);
}
