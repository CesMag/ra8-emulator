//! The self-loop cable's bulk side: the USBHS host's bulk packets reach the
//! pipe the USBFS driver opened for the endpoint, and only what that driver
//! commits comes back.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs.regs;
const Loop = ra8.components.usb_loop_cable.Loop;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

/// The driver opens a bulk pipe the way ra8_usb_device.c does.
fn open(device: *usbfs.Device, n: u16, endpoint: u16, in: bool) void {
    const dir: u16 = if (in) pipe.cfg.dir_in else 0;
    device.write(at(regs.reg.pipesel), 2, n);
    device.write(at(regs.reg.pipecfg), 2, (1 << pipe.cfg.kind_shift) | dir | endpoint);
    device.write(at(regs.reg.pipemaxp), 2, 64);
    device.write(at(regs.reg.pipesel), 2, 0);
}

/// The CDC echo the selftest runs: bulk OUT on EP2, bulk IN on EP1.
fn echoDevice() usbfs.Device {
    var device = usbfs.Device{};
    open(&device, 1, 2, false);
    open(&device, 2, 1, true);
    return device;
}

test "a bulk OUT packet reaches the driver through its pipe" {
    var device = echoDevice();
    var loop = Loop{ .device = &device };
    try std.testing.expect(loop.bulkOut(2, "ping"));
    try std.testing.expectEqual(@as(u32, 1 << 1), device.read(at(regs.reg.brdysts), 2));
    device.write(at(regs.reg.cfifosel), 2, 1);
    try std.testing.expectEqual(@as(u32, 0x676E6970), device.read(at(regs.reg.cfifo), 4));
    try std.testing.expectEqual(@as(u32, 1), loop.bulk_outs);
}

test "the driver's echo comes back on the IN endpoint" {
    var device = echoDevice();
    var loop = Loop{ .device = &device };
    var into: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?u16, null), loop.bulkIn(1, &into));
    device.write(at(regs.reg.cfifosel), 2, 2);
    device.write(at(regs.reg.cfifo), 4, 0x676E6F70);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
    const len = loop.bulkIn(1, &into).?;
    try std.testing.expectEqualSlices(u8, "pong", into[0..len]);
    try std.testing.expectEqual(@as(u32, 1), loop.bulk_ins);
}

test "a full OUT pipe NAKs the next packet until the driver drains it" {
    var device = echoDevice();
    var loop = Loop{ .device = &device };
    try std.testing.expect(loop.bulkOut(2, "a"));
    try std.testing.expect(!loop.bulkOut(2, "b"));
    device.write(at(regs.reg.cfifosel), 2, 1);
    _ = device.read(at(regs.reg.cfifo), 1);
    try std.testing.expect(loop.bulkOut(2, "b"));
}

test "an endpoint with no opened pipe is NAKed and counted" {
    var device = usbfs.Device{};
    var loop = Loop{ .device = &device };
    var into: [8]u8 = undefined;
    try std.testing.expect(!loop.bulkOut(2, "x"));
    try std.testing.expectEqual(@as(?u16, null), loop.bulkIn(1, &into));
    try std.testing.expectEqual(@as(u32, 2), loop.unopened);
}
