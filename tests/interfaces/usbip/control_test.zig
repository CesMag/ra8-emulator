//! Covers src/interfaces/usbip/control.zig: endpoint 0 URBs walk the
//! DCP stage by stage and end on the driver's CCPL or STALL.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs.regs;
const urb = ra8.usbip.exported.urb;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn attached() usbfs.Device {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    return device;
}

fn transfer(setup: [8]u8, in: bool, length: u32) urb.Transfer {
    return .{ .submit = .{ .seqnum = 1, .devid = 0x10002, .direction = if (in) .in else .out, .ep = 0, .transfer_flags = 0, .length = length, .start_frame = 0, .packets = 0, .interval = 0, .setup = setup } };
}

/// The driver's side: stage `bytes` on the DCP and commit them.
fn send(device: *usbfs.Device, bytes: []const u8) void {
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    for (bytes) |byte| device.write(at(regs.reg.cfifo), 1, byte);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
}

fn ccpl(device: *usbfs.Device) void {
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl | regs.dcpctr.pid_buf);
}

const get_device = [8]u8{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 };
const descriptor = [18]u8{ 18, 1, 0, 2, 2, 0, 0, 64, 0x5B, 0x04, 0x10, 0x53, 0, 1, 1, 2, 3, 1 };

test "a GET_DESCRIPTOR read comes back with the driver's bytes" {
    var device = attached();
    var urb_in = transfer(get_device, true, 18);
    var buf: [18]u8 = undefined;
    try std.testing.expect(urb_in.advance(&device, &.{}, &buf) == null);
    try std.testing.expectEqual(@as(u32, 0x0680), device.read(at(regs.reg.usbreq), 2));
    send(&device, &descriptor);
    try std.testing.expect(urb_in.advance(&device, &.{}, &buf) == null);
    try std.testing.expect(urb_in.advance(&device, &.{}, &buf) == null);
    try std.testing.expect(urb_in.advance(&device, &.{}, &buf) == null);
    ccpl(&device);
    try std.testing.expectEqual(urb.Reply{ .status = 0, .actual = 18 }, urb_in.advance(&device, &.{}, &buf).?);
    try std.testing.expectEqualSlices(u8, &descriptor, &buf);
}

test "a request the driver stalls fails as EPIPE" {
    var device = attached();
    var urb_in = transfer(.{ 0x80, 0x06, 0x00, 0x0F, 0x00, 0x00, 0x05, 0x00 }, true, 5);
    var buf: [5]u8 = undefined;
    try std.testing.expect(urb_in.advance(&device, &.{}, &buf) == null);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    try std.testing.expectEqual(urb.Reply{ .status = urb.epipe, .actual = 0 }, urb_in.advance(&device, &.{}, &buf).?);
}

test "a no-data request completes on CCPL" {
    var device = attached();
    var urb_out = transfer(.{ 0x01, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, false, 0);
    try std.testing.expect(urb_out.advance(&device, &.{}, &.{}) == null);
    try std.testing.expect(urb_out.advance(&device, &.{}, &.{}) == null);
    ccpl(&device);
    try std.testing.expectEqual(urb.Reply{ .status = 0, .actual = 0 }, urb_out.advance(&device, &.{}, &.{}).?);
}

test "a control write hands its data to the driver before the status stage" {
    var device = attached();
    var urb_out = transfer(.{ 0x21, 0x20, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00 }, false, 3);
    try std.testing.expect(urb_out.advance(&device, "abc", &.{}) == null);
    try std.testing.expect(urb_out.advance(&device, "abc", &.{}) == null);
    try std.testing.expect(device.control.out.ready);
    device.control.out.clear();
    try std.testing.expect(urb_out.advance(&device, "abc", &.{}) == null);
    try std.testing.expect(urb_out.advance(&device, "abc", &.{}) == null);
    try std.testing.expectEqual(usbfs.intsts0.ctsq_write_status, device.interruptStatus() & usbfs.intsts0.ctsq_mask);
    ccpl(&device);
    try std.testing.expectEqual(urb.Reply{ .status = 0, .actual = 3 }, urb_out.advance(&device, "abc", &.{}).?);
}

test "SET_ADDRESS is answered without touching the device" {
    var device = attached();
    var urb_out = transfer(.{ 0x00, 0x05, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00 }, false, 0);
    try std.testing.expectEqual(urb.Reply{ .status = 0, .actual = 0 }, urb_out.advance(&device, &.{}, &.{}).?);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.usbaddr), 2));
}
