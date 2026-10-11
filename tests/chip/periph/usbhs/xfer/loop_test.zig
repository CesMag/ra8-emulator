//! The USBHS transfer engine over the self-loop cable: every answer the
//! polled host sees is one the USBFS driver committed on the other jack.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs.regs;
const usbhs_pipe = ra8.chip.periph.usbhs.pipe;
const xfer = ra8.chip.periph.usbhs.xfer;
const Loop = ra8.components.usb.loop_cable.Loop;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn attached() usbfs.Device {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    return device;
}

fn getDescriptor(transfer: *xfer.Transfer) void {
    transfer.usbreq = 0x0680;
    transfer.usbval = 0x0100;
    transfer.usbindx = 0;
    transfer.usbleng = 18;
    transfer.launch(true);
}

/// The device driver commits one IN packet on a pipe through CFIFO.
fn commit(device: *usbfs.Device, curpipe: u16, bytes: []const u8) void {
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel | curpipe);
    for (bytes) |byte| device.write(at(regs.reg.cfifo), 1, byte);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
}

/// The device driver opens a bulk pipe the way ra8_usb_device.c does.
fn open(device: *usbfs.Device, n: u16, endpoint: u16, in: bool) void {
    const dir: u16 = if (in) usbfs.pipe.cfg.dir_in else 0;
    device.write(at(regs.reg.pipesel), 2, n);
    device.write(at(regs.reg.pipecfg), 2, (1 << usbfs.pipe.cfg.kind_shift) | dir | endpoint);
    device.write(at(regs.reg.pipemaxp), 2, 64);
    device.write(at(regs.reg.pipesel), 2, 0);
}

test "the SETUP crosses at once and the reply waits for the device driver" {
    var device = attached();
    var loop = Loop{ .device = &device };
    var transfer = xfer.Transfer{ .far = loop.far() };
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer);
    try std.testing.expectEqual(@as(u32, 1), loop.setups);
    try std.testing.expectEqual(@as(u32, 0x0680), device.read(at(regs.reg.usbreq), 2));
    try std.testing.expectEqual(@as(u32, 18), device.read(at(regs.reg.usbleng), 2));
    try std.testing.expectEqual(@as(u16, 0), transfer.readyStatus(&pipes) & regs.status.dcp);
    commit(&device, 0, &.{ 18, 1, 0, 2 });
    try std.testing.expect(transfer.readyStatus(&pipes) & regs.status.dcp != 0);
    transfer.port.select(0);
    try std.testing.expectEqual(@as(u32, 0x0112), transfer.port.readData(2));
}

test "a STALL the device driver sets reaches the host's DCPCTR" {
    var device = attached();
    var loop = Loop{ .device = &device };
    var transfer = xfer.Transfer{ .far = loop.far() };
    var pipes = usbhs_pipe.Table{};
    getDescriptor(&transfer);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    _ = transfer.readyStatus(&pipes);
    try std.testing.expectEqual(regs.dcpctr.pid_stall, transfer.dcpctr & regs.dcpctr.pid_mask);
    try std.testing.expectEqual(@as(u32, 1), transfer.stalls);
    try std.testing.expect(!transfer.in_flight);
    _ = transfer.readyStatus(&pipes);
    try std.testing.expectEqual(@as(u32, 1), transfer.stalls);
}

test "a bulk IN packet the driver commits lands on the host pipe for its endpoint" {
    var device = attached();
    var loop = Loop{ .device = &device };
    var transfer = xfer.Transfer{ .far = loop.far() };
    var pipes = usbhs_pipe.Table{};
    pipes.pipes[1] = .{ .endpoint = 1, .in = true, .pid = regs.pipe.pid_buf };
    open(&device, 2, 1, true);
    try std.testing.expectEqual(@as(u16, 0), transfer.readyStatus(&pipes) & (1 << 1));
    commit(&device, 2, "pong");
    try std.testing.expect(transfer.readyStatus(&pipes) & (1 << 1) != 0);
    try std.testing.expectEqualSlices(u8, "pong", transfer.port.in[1].staged());
}

test "a bulk OUT packet the host commits reaches the driver's pipe" {
    var device = attached();
    var loop = Loop{ .device = &device };
    var transfer = xfer.Transfer{ .far = loop.far() };
    var pipes = usbhs_pipe.Table{};
    pipes.pipes[2] = .{ .endpoint = 2, .in = false, .pid = regs.pipe.pid_buf };
    open(&device, 1, 2, false);
    transfer.port.select(2);
    transfer.port.writeData(0x676E6970, 4, 64);
    transfer.commit(&pipes);
    try std.testing.expect(transfer.bemp & (1 << 2) != 0);
    try std.testing.expectEqual(@as(u32, 1 << 1), device.read(at(regs.reg.brdysts), 2));
    try std.testing.expectEqual(@as(u32, 0), transfer.refused_out);
}

test "a bulk OUT packet with no pipe opened on the device stays staged" {
    var device = attached();
    var loop = Loop{ .device = &device };
    var transfer = xfer.Transfer{ .far = loop.far() };
    var pipes = usbhs_pipe.Table{};
    pipes.pipes[2] = .{ .endpoint = 2, .in = false, .pid = regs.pipe.pid_buf };
    transfer.port.select(2);
    transfer.port.writeData(0x41, 1, 64);
    transfer.commit(&pipes);
    try std.testing.expectEqual(@as(u32, 1), transfer.refused_out);
    try std.testing.expectEqual(@as(u16, 1), transfer.port.out[2].len);
}

test "a NAKed bulk OUT packet goes again on BEMPSTS once the driver opens its pipe" {
    var device = attached();
    var loop = Loop{ .device = &device };
    var transfer = xfer.Transfer{ .far = loop.far() };
    var pipes = usbhs_pipe.Table{};
    pipes.pipes[2] = .{ .endpoint = 2, .in = false, .pid = regs.pipe.pid_buf };
    transfer.port.select(2);
    transfer.port.writeData(0x41, 1, 64);
    transfer.commit(&pipes);
    try std.testing.expectEqual(@as(u16, 0), transfer.emptyStatus(&pipes) & (1 << 2));
    open(&device, 1, 2, false);
    try std.testing.expect(transfer.emptyStatus(&pipes) & (1 << 2) != 0);
    try std.testing.expectEqual(@as(u16, 0), transfer.port.out[2].len);
    try std.testing.expectEqual(@as(u32, 0), transfer.refused_bytes);
    try std.testing.expectEqual(@as(u32, 1), loop.bulk_outs);
}

test "BEMPSTS without a cable is the latched status alone" {
    var transfer = xfer.Transfer{};
    var pipes = usbhs_pipe.Table{};
    transfer.bemp = 1 << 3;
    try std.testing.expectEqual(@as(u16, 1 << 3), transfer.emptyStatus(&pipes));
}
