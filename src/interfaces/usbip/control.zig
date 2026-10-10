//! Endpoint 0 over usbip (RA8EMU-75): a control URB walks the DCP the way
//! the scripted host does, one stage per `advance`. The SETUP goes out on
//! its own boundary; a read takes IN packets until the length is in or a
//! short packet ends it, and a write hands OUT packets over once the driver
//! has read the last one. The status-stage token follows a data stage, then
//! the URB completes on the driver's CCPL or fails on its STALL.
//! SET_ADDRESS is answered here and never reaches the device: the scripted
//! host already addressed it, the way usbip's own stub keeps the address.
//! The bridge offers the device only once the scripted host is done, so the
//! two never share endpoint 0.
const usbfs = @import("ra8_chip").periph.usbfs;
const regs = @import("ra8_chip").periph.usbhs_regs;
const urb = @import("urb.zig");

pub const Stage = enum { setup, data, status, finish };

const max_packet = 64;

pub fn advance(transfer: *urb.Transfer, device: *usbfs.Device, out_data: []const u8, in_buf: []u8) ?urb.Reply {
    const packet = transfer.submit.setup;
    if (packet[0] == 0x00 and packet[1] == 5) return .{ .status = 0, .actual = 0 };
    switch (transfer.stage) {
        .setup => {
            device.setup(packet);
            transfer.stage = if (wanted(transfer, out_data, in_buf) == 0) .finish else .data;
            return null;
        },
        .data => {
            if (stalled(device)) return .{ .status = urb.epipe, .actual = 0 };
            if (packet[0] & 0x80 != 0) read(transfer, device, in_buf) else write(transfer, device, out_data);
            return null;
        },
        .status => {
            device.statusStage();
            transfer.stage = .finish;
            return null;
        },
        .finish => {
            if (stalled(device)) return .{ .status = urb.epipe, .actual = 0 };
            if (idle(device)) return .{ .status = 0, .actual = transfer.moved };
            return null;
        },
    }
}

/// wLength, cut to what the URB can carry in its direction.
fn wanted(transfer: *const urb.Transfer, out_data: []const u8, in_buf: []const u8) u32 {
    const packet = transfer.submit.setup;
    const length: u32 = @as(u32, packet[6]) | (@as(u32, packet[7]) << 8);
    const room = if (packet[0] & 0x80 != 0) @min(in_buf.len, transfer.submit.length) else out_data.len;
    return @intCast(@min(length, room));
}

fn read(transfer: *urb.Transfer, device: *usbfs.Device, in_buf: []u8) void {
    const want = wanted(transfer, &.{}, in_buf);
    var chunk: [max_packet]u8 = undefined;
    const len = device.control.hostTake(&chunk) orelse return;
    const n = @min(len, want - transfer.moved);
    @memcpy(in_buf[transfer.moved..][0..n], chunk[0..n]);
    transfer.moved += n;
    if (len < max_packet or transfer.moved >= want) transfer.stage = .status;
}

fn write(transfer: *urb.Transfer, device: *usbfs.Device, out_data: []const u8) void {
    if (device.control.out.ready) return;
    const want = wanted(transfer, out_data, &.{});
    if (transfer.moved >= want) {
        transfer.stage = .status;
        return;
    }
    const end = @min(want, transfer.moved + max_packet);
    device.control.hostOut(out_data[transfer.moved..end]);
    transfer.moved = end;
}

fn stalled(device: *usbfs.Device) bool {
    return device.read(usbfs.window.base + regs.reg.dcpctr, 2) & regs.dcpctr.pid_stall != 0;
}

fn idle(device: *const usbfs.Device) bool {
    return device.interruptStatus() & usbfs.intsts0.ctsq_mask == usbfs.intsts0.ctsq_idle;
}
