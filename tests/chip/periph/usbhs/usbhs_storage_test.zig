//! The device's bulk endpoints with a disk plugged in: a CBW committed on
//! an OUT pipe comes back as data and a CSW on the IN pipe.
const std = @import("std");
const ra8 = @import("ra8");
const device = ra8.components.usb_echo;
const echo_far = ra8.components.usb_echo_far;
const msc = ra8.components.usb_stick;
const regs = ra8.chip.periph.usbhs_regs;
const setup = ra8.chip.periph.usbhs_setup;
const usbhs_pipe = ra8.chip.periph.usbhs_pipe;
const xfer = ra8.chip.periph.usbhs_xfer;

var disk = @as([2 * msc.block_len]u8, @splat(0x5A));
var stick: msc.Target = .{};

fn set(code: u8, value: u16) setup.Packet {
    return .{ .request_type = 0x00, .code = code, .value = value };
}

fn configured() device.Device {
    stick = .{ .disk = &disk };
    var part = device.Device{ .storage = stick.function() };
    _ = part.handle(set(setup.request.set_address, 1));
    _ = part.handle(set(setup.request.set_configuration, 1));
    return part;
}

fn cbw(tag: u32, length: u32, cdb: []const u8) [msc.cbw_len]u8 {
    var packet = @as([msc.cbw_len]u8, @splat(0));
    std.mem.writeInt(u32, packet[0..4], msc.cbw_signature, .little);
    std.mem.writeInt(u32, packet[4..8], tag, .little);
    std.mem.writeInt(u32, packet[8..12], length, .little);
    packet[12] = 0x80;
    @memcpy(packet[15 .. 15 + cdb.len], cdb);
    return packet;
}

test "without a disk the bulk endpoint still echoes" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 1));
    _ = part.handle(set(setup.request.set_configuration, 1));
    try std.testing.expect(!part.hasDisk());
    try std.testing.expect(part.bulkOut(&[_]u8{ 1, 2 }));
    try std.testing.expect(part.bulkPending());
    var into: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 2), part.takeIn(&into));
}

test "with a disk a CBW is a command, answered with data then a CSW" {
    var part = configured();
    try std.testing.expect(part.bulkOut(&cbw(9, 8, &.{msc.op.read_capacity10})));
    try std.testing.expect(part.bulkPending());
    var into: [512]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 8), part.takeIn(&into));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, into[0..4], .big));
    try std.testing.expectEqual(@as(u16, msc.csw_len), part.takeIn(&into));
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, into[4..8], .little));
    try std.testing.expect(!part.bulkPending());
}

test "a packet that isn't a CBW is refused on a disk device" {
    var part = configured();
    try std.testing.expect(!part.bulkOut(&[_]u8{ 1, 2, 3 }));
    try std.testing.expectEqual(@as(u32, 1), part.out_of_order);
}

test "a bus reset drops the command the disk was answering" {
    var part = configured();
    _ = part.bulkOut(&cbw(1, 512, &.{ msc.op.read10, 0, 0, 0, 0, 0, 0, 0, 1, 0 }));
    part.busReset();
    try std.testing.expect(!part.bulkPending());
}

test "the transfer engine hands the disk's answer to an armed IN pipe" {
    stick = .{ .disk = &disk };
    var echo = device.Device{ .storage = stick.function() };
    var transfer = xfer.Transfer{ .far = echo_far.far(&echo) };
    var pipes = usbhs_pipe.Table{};
    transfer.usbreq = 0x0500;
    transfer.usbval = 1;
    transfer.launch(true);
    transfer.usbreq = 0x0900;
    transfer.usbval = 1;
    transfer.launch(true);
    try std.testing.expect(echo.bulkOut(&cbw(4, 512, &.{ msc.op.read10, 0, 0, 0, 0, 1, 0, 0, 1, 0 })));
    _ = pipes.setControl(1, regs.pipe.pid_buf);
    pipes.pipes[1].in = true;
    const ready = transfer.readyStatus(&pipes);
    try std.testing.expect(ready & (@as(u16, 1) << 1) != 0);
    try std.testing.expectEqual(@as(u16, 512), transfer.port.in[1].len);
    try std.testing.expectEqual(@as(u8, 0x5A), transfer.port.in[1].data[0]);
}
