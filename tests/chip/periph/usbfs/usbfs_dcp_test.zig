//! The USBFS control FIFO port on the DCP: IN packets the driver stages and
//! commits, OUT packets the host hands in, and the accesses it refuses.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs_regs;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

test "an IN packet staged with ISEL and committed with BVAL reaches the host" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    device.write(at(regs.reg.cfifo), 4, 0x0110_0112);
    device.write(at(regs.reg.cfifo), 2, 0x0000);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy | 6), device.read(at(regs.reg.cfifoctr), 2));
    var into: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?u16, null), device.control.hostTake(&into));
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
    const len = device.control.hostTake(&into) orelse return error.NothingSent;
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x01, 0x10, 0x01, 0x00, 0x00 }, into[0..len]);
    try std.testing.expectEqual(@as(u32, 1), device.control.packets_sent);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy), device.read(at(regs.reg.cfifoctr), 2));
}

test "an OUT packet from the host is read back with ISEL clear, DTLN counting down" {
    var device = usbfs.Device{};
    device.control.hostOut(&.{ 0x80, 0x25, 0x00, 0x00, 0x00, 0x00, 0x08 });
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy | 7), device.read(at(regs.reg.cfifoctr), 2));
    try std.testing.expectEqual(@as(u32, 0x0000_2580), device.read(at(regs.reg.cfifo), 4));
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy | 3), device.read(at(regs.reg.cfifoctr), 2));
    try std.testing.expectEqual(@as(u32, 0x0000), device.read(at(regs.reg.cfifo), 2));
    try std.testing.expectEqual(@as(u32, 0x08), device.read(at(regs.reg.cfifo), 1));
    try std.testing.expectEqual(@as(u32, 0), device.refusals());
}

test "BCLR throws away the side the port faces" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    device.write(at(regs.reg.cfifo), 2, 0xBEEF);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bclr);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy), device.read(at(regs.reg.cfifoctr), 2));
    device.control.hostOut(&.{ 1, 2, 3 });
    device.write(at(regs.reg.cfifosel), 2, 0);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bclr);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy), device.read(at(regs.reg.cfifoctr), 2));
}

test "reading with nothing from the host is refused and reads 0" {
    var device = usbfs.Device{};
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.cfifo), 2));
    try std.testing.expectEqual(@as(u32, 1), device.refusals());
}

test "a pipe other than the DCP aims the port at nothing" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel | 3);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.cfifoctr), 2));
    device.write(at(regs.reg.cfifo), 2, 0x1234);
    try std.testing.expectEqual(@as(u32, 2), device.refusals());
    try std.testing.expectEqual(@as(u32, regs.fifo.isel | 3), device.read(at(regs.reg.cfifosel), 2));
}

test "an IN packet past the DCP's packet size stops at it" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    var i: u32 = 0;
    while (i < 17) : (i += 1) device.write(at(regs.reg.cfifo), 4, i);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy | 64), device.read(at(regs.reg.cfifoctr), 2));
    try std.testing.expectEqual(@as(u32, 1), device.control.oversize);
}

test "an OUT packet from the host raises BRDY until the driver clears it" {
    var device = usbfs.Device{};
    device.control.hostOut(&.{ 1, 2 });
    try std.testing.expectEqual(@as(u32, regs.status.dcp), device.read(at(regs.reg.brdysts), 2));
    try std.testing.expect(device.read(at(regs.reg.intsts0), 2) & regs.int0.brdy != 0);
    device.write(at(regs.reg.brdysts), 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, regs.status.dcp), device.read(at(regs.reg.brdysts), 2));
    device.write(at(regs.reg.brdysts), 2, ~@as(u32, regs.status.dcp));
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.brdysts), 2));
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2) & regs.int0.brdy);
}

test "BEMP latches once the host takes the committed IN packet, not before" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    device.write(at(regs.reg.cfifo), 2, 0x0112);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.bempsts), 2));
    var into: [64]u8 = undefined;
    _ = device.control.hostTake(&into) orelse return error.NothingSent;
    try std.testing.expectEqual(@as(u32, regs.status.dcp), device.read(at(regs.reg.bempsts), 2));
    try std.testing.expect(device.read(at(regs.reg.intsts0), 2) & regs.int0.bemp != 0);
    device.write(at(regs.reg.bempsts), 2, 0);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2) & regs.int0.bemp);
}

test "the IN side is not ready while a committed packet waits for the host" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    device.write(at(regs.reg.cfifo), 1, 0x09);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.cfifoctr), 2) & regs.fifo.frdy);
    var into: [64]u8 = undefined;
    _ = device.control.hostTake(&into) orelse return error.NothingSent;
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy), device.read(at(regs.reg.cfifoctr), 2) & regs.fifo.frdy);
}
