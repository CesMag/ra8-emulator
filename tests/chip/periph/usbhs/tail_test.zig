//! A packet whose length is not a whole number of words: the HS HAL writes
//! the head 32 bits at a time and the tail through CFIFOH and CFIFOHH.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.chip.periph.usbhs.regs;
const usbhs = ra8.chip.periph.usbhs;

const base = regs.window.base;

fn liveHost(host: *usbhs.Host) void {
    host.attachDevice();
    host.write(base + regs.reg.syscfg, 2, regs.syscfg.usbe | regs.syscfg.scke |
        regs.syscfg.dcfm | regs.syscfg.cnen);
    host.write(base + regs.reg.dvstctr0, 2, regs.port.vbusen | regs.port.usbrst);
    host.write(base + regs.reg.dvstctr0, 2, regs.port.vbusen | regs.port.uact);
}

/// PIPE1 as a bulk OUT with a 64-byte packet, aimed at by CFIFO.
fn aimAtBulk(host: *usbhs.Host) void {
    host.write(base + regs.reg.pipesel, 2, 1);
    host.write(base + regs.reg.pipecfg, 2, regs.pipe.dir_transmit | 2);
    host.write(base + regs.reg.pipemaxp, 2, 64);
    host.write(base + regs.reg.pipesel, 2, 0);
    host.write(base + regs.reg.cfifosel, 2, regs.fifo.isel | 1);
}

test "a seven-byte packet lands whole through CFIFO, CFIFOH and CFIFOHH" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    aimAtBulk(&host);
    host.write(base + regs.reg.cfifo, 4, 0x4342_5355);
    host.write(base + regs.reg.cfifo + 2, 2, 0x0201);
    host.write(base + regs.reg.cfifo + 3, 1, 0x03);
    const staged = host.xfer.port.out[1].staged();
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0x53, 0x42, 0x43, 0x01, 0x02, 0x03 }, staged);
    try std.testing.expectEqual(@as(u32, 0), host.misaligned);
}

test "an odd address outside the FIFO port is still refused" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    host.write(base + regs.reg.cfifosel + 1, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 1), host.misaligned);
}
