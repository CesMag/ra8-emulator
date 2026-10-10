//! Covers src/interfaces/usbip/urb.zig: bulk URBs through the pipes
//! the firmware opened, one packet at a time, and the stalls and unlinks
//! around them.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs.regs;
const urb = ra8.usbip.exported.urb;
const wire = ra8.usbip.wire;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn open(device: *usbfs.Device, n: u16, endpoint: u16, in: bool) void {
    const dir: u16 = if (in) pipe.cfg.dir_in else 0;
    device.write(at(regs.reg.pipesel), 2, n);
    device.write(at(regs.reg.pipecfg), 2, (1 << pipe.cfg.kind_shift) | dir | endpoint);
    device.write(at(regs.reg.pipemaxp), 2, 64);
    device.write(at(regs.reg.pipesel), 2, 0);
}

fn submit(direction: wire.Direction, ep: u32, length: u32) urb.Transfer {
    return .{ .submit = .{ .seqnum = 7, .devid = 0x10002, .direction = direction, .ep = ep, .transfer_flags = 0, .length = length, .start_frame = 0, .packets = 0, .interval = 0, .setup = @as([8]u8, @splat(0)) } };
}

test "a short bulk OUT URB lands in the driver's pipe in one packet" {
    var device = usbfs.Device{};
    open(&device, 1, 2, false);
    var transfer = submit(.out, 2, 3);
    const reply = transfer.advance(&device, "abc", &.{}).?;
    try std.testing.expectEqual(urb.Reply{ .status = 0, .actual = 3 }, reply);
    try std.testing.expectEqual(@as(u32, 1 << 1), device.read(at(regs.reg.brdysts), 2));
}

test "a long OUT URB waits while the pipe still holds its first packet" {
    var device = usbfs.Device{};
    open(&device, 1, 2, false);
    var transfer = submit(.out, 2, 100);
    const data = @as([100]u8, @splat(0x5A));
    try std.testing.expectEqual(@as(?urb.Reply, null), transfer.advance(&device, &data, &.{}));
    try std.testing.expectEqual(@as(u32, 64), transfer.moved);
    try std.testing.expectEqual(@as(?urb.Reply, null), transfer.advance(&device, &data, &.{}));
    try std.testing.expectEqual(@as(u32, 64), transfer.moved);
    try std.testing.expectEqual(@as(u32, 0), device.refusals());
}

test "a bulk IN URB waits for the driver, then ends on its short packet" {
    var device = usbfs.Device{};
    open(&device, 2, 1, true);
    var transfer = submit(.in, 1, 64);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?urb.Reply, null), transfer.advance(&device, &.{}, &buf));
    device.write(at(regs.reg.cfifosel), 2, 2);
    device.write(at(regs.reg.cfifo), 2, 0x6968);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
    const reply = transfer.advance(&device, &.{}, &buf).?;
    try std.testing.expectEqual(urb.Reply{ .status = 0, .actual = 2 }, reply);
    try std.testing.expectEqualSlices(u8, "hi", buf[0..2]);
}

test "an endpoint nobody opened stalls" {
    var device = usbfs.Device{};
    var stray = submit(.out, 3, 1);
    try std.testing.expectEqual(urb.Reply{ .status = urb.epipe, .actual = 0 }, stray.advance(&device, "x", &.{}).?);
}

test "unlink catches the URB in flight and leaves a finished one alone" {
    var pending: ?urb.Transfer = submit(.in, 1, 64);
    try std.testing.expectEqual(@as(i32, 0), urb.unlink(&pending, 8));
    try std.testing.expect(pending != null);
    try std.testing.expectEqual(urb.econnreset, urb.unlink(&pending, 7));
    try std.testing.expectEqual(@as(?urb.Transfer, null), pending);
    try std.testing.expectEqual(@as(i32, 0), urb.unlink(&pending, 7));
}
