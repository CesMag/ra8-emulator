//! The USBFS CFIFO port aimed at an opened bulk pipe: the IN side the driver
//! writes and commits, the OUT side the host fills, and the per-pipe
//! BRDYSTS and BEMPSTS bits.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs.regs;

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

test "an IN pipe stages, commits with BVAL and the host takes the packet" {
    var device = usbfs.Device{};
    open(&device, 2, 1, true);
    device.write(at(regs.reg.cfifosel), 2, 2);
    device.write(at(regs.reg.cfifo), 2, 0x6968);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy | 2), device.read(at(regs.reg.cfifoctr), 2));
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.cfifoctr), 2));
    var into: [64]u8 = undefined;
    const len = device.endpoints.hostTake(2, &into).?;
    try std.testing.expectEqualSlices(u8, "hi", into[0..len]);
    try std.testing.expectEqual(@as(u32, 1 << 2), device.read(at(regs.reg.bempsts), 2));
    try std.testing.expect(device.read(at(regs.reg.intsts0), 2) & regs.int0.bemp != 0);
    try std.testing.expectEqual(@as(?u16, null), device.endpoints.hostTake(2, &into));
    try std.testing.expectEqual(@as(u32, 0), device.refusals());
}

test "an OUT pipe hands the host's packet to the driver and raises BRDY" {
    var device = usbfs.Device{};
    open(&device, 1, 2, false);
    try std.testing.expect(device.endpoints.hostOut(&device.pipes, 1, "abc"));
    try std.testing.expectEqual(@as(u32, 1 << 1), device.read(at(regs.reg.brdysts), 2));
    device.write(at(regs.reg.cfifosel), 2, 1);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy | 3), device.read(at(regs.reg.cfifoctr), 2));
    try std.testing.expectEqual(@as(u32, 0x6261), device.read(at(regs.reg.cfifo), 2));
    try std.testing.expectEqual(@as(u32, 0x63), device.read(at(regs.reg.cfifo), 1));
    device.write(at(regs.reg.brdysts), 2, ~@as(u16, 1 << 1));
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.brdysts), 2));
    try std.testing.expectEqual(@as(u32, 0), device.refusals());
}

test "a second host packet before the driver drained the first is refused" {
    var device = usbfs.Device{};
    open(&device, 1, 2, false);
    try std.testing.expect(device.endpoints.hostOut(&device.pipes, 1, "a"));
    try std.testing.expect(!device.endpoints.hostOut(&device.pipes, 1, "b"));
    try std.testing.expectEqual(@as(u32, 1), device.endpoints.overrun);
}

test "the wrong side of a pipe is refused" {
    var device = usbfs.Device{};
    open(&device, 1, 2, false);
    open(&device, 2, 1, true);
    device.write(at(regs.reg.cfifosel), 2, 1);
    device.write(at(regs.reg.cfifo), 2, 0x1234);
    device.write(at(regs.reg.cfifosel), 2, 2);
    _ = device.read(at(regs.reg.cfifo), 2);
    try std.testing.expectEqual(@as(u32, 2), device.endpoints.bad_pipe);
    try std.testing.expect(!device.endpoints.hostOut(&device.pipes, 2, "x"));
}

test "selecting an opened pipe leaves the DCP alone" {
    var device = usbfs.Device{};
    open(&device, 3, 1, true);
    device.write(at(regs.reg.cfifosel), 2, 3);
    try std.testing.expectEqual(@as(u32, 0), device.control.bad_pipe);
    device.write(at(regs.reg.cfifosel), 2, 0);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy), device.read(at(regs.reg.cfifoctr), 2) & regs.fifo.frdy);
}

test "BCLR throws away a staged IN packet" {
    var device = usbfs.Device{};
    open(&device, 2, 1, true);
    device.write(at(regs.reg.cfifosel), 2, 2);
    device.write(at(regs.reg.cfifo), 2, 0xAAAA);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bclr);
    try std.testing.expectEqual(@as(u32, regs.fifo.frdy), device.read(at(regs.reg.cfifoctr), 2));
}
