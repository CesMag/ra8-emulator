//! The self-loop cable: the USBHS host's control transfers reach the USBFS
//! device model, and only what the device driver writes comes back.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs_regs;
const Loop = ra8.components.usb_loop_cable.Loop;

const get_device = [8]u8{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 };
const set_config = [8]u8{ 0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
const set_line_coding = [8]u8{ 0x21, 0x20, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00 };

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn attached() usbfs.Device {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    return device;
}

/// The device driver commits one IN packet on the DCP.
fn commit(device: *usbfs.Device, bytes: []const u8) void {
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    for (bytes) |byte| device.write(at(regs.reg.cfifo), 1, byte);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
}

fn complete(device: *usbfs.Device) void {
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl);
}

test "a SETUP from the host reaches the device driver's registers" {
    var device = attached();
    var loop = Loop{ .device = &device };
    loop.setup(get_device);
    try std.testing.expectEqual(@as(u32, 0x0680), device.read(at(regs.reg.usbreq), 2));
    try std.testing.expectEqual(@as(u32, 0x0100), device.read(at(regs.reg.usbval), 2));
    try std.testing.expectEqual(@as(u32, 18), device.read(at(regs.reg.usbleng), 2));
    try std.testing.expectEqual(usbfs.intsts0.ctsq_read_data, device.interruptStatus() & usbfs.intsts0.ctsq_mask);
    try std.testing.expectEqual(@as(u32, 1), loop.setups);
}

test "the host's IN token takes only what the driver committed" {
    var device = attached();
    var loop = Loop{ .device = &device };
    loop.setup(get_device);
    var into: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?u16, null), loop.takeIn(&into));
    const descriptor = [_]u8{ 18, 1, 0x00, 0x02, 2, 0, 0, 64 };
    commit(&device, &descriptor);
    const len = loop.takeIn(&into) orelse return error.NoPacket;
    try std.testing.expectEqualSlices(u8, &descriptor, into[0..len]);
    try std.testing.expectEqual(@as(?u16, null), loop.takeIn(&into));
    try std.testing.expectEqual(@as(u32, 1), loop.ins);
}

test "a control read is pending until the driver sets CCPL" {
    var device = attached();
    var loop = Loop{ .device = &device };
    loop.setup(get_device);
    try std.testing.expectEqual(.pending, loop.answer());
    loop.statusStage();
    try std.testing.expectEqual(.pending, loop.answer());
    complete(&device);
    try std.testing.expectEqual(.ack, loop.answer());
}

test "an OUT data stage lands in the DCP buffer for the driver" {
    var device = attached();
    var loop = Loop{ .device = &device };
    loop.setup(set_line_coding);
    const coding = [_]u8{ 0x00, 0xC2, 0x01, 0x00, 0x00, 0x00, 0x08 };
    loop.out(&coding);
    try std.testing.expect(device.control.brdy);
    device.write(at(regs.reg.cfifosel), 2, 0);
    var got: [coding.len]u8 = undefined;
    for (&got) |*byte| byte.* = @truncate(device.read(at(regs.reg.cfifo), 1));
    try std.testing.expectEqualSlices(u8, &coding, &got);
}

test "a STALL on the device's DCP is the host's failed transfer" {
    var device = attached();
    var loop = Loop{ .device = &device };
    loop.setup(set_line_coding);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    try std.testing.expectEqual(.stall, loop.answer());
}

test "SET_ADDRESS and SET_CONFIGURATION move the device the host enumerates" {
    var device = attached();
    var loop = Loop{ .device = &device };
    try std.testing.expectEqual(usbfs.intsts0.dvsq_default, loop.deviceState());
    loop.setup(.{ 0x00, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(usbfs.intsts0.dvsq_address, loop.deviceState());
    loop.setup(set_config);
    complete(&device);
    try std.testing.expectEqual(usbfs.intsts0.dvsq_configured, loop.deviceState());
    try std.testing.expectEqual(.ack, loop.answer());
}
