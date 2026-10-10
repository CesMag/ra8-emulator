//! The two data FIFO ports: what each will aim at, how wide an access it
//! answers, and which way its pipe runs.
const std = @import("std");
const ra8 = @import("ra8");

const dfifo = ra8.chip.periph.usbhs_dfifo;
const regs = ra8.chip.periph.usbhs_regs;
const usbhs = ra8.chip.periph.usbhs;
const echo_device = ra8.components.usb_echo;
const echo_far = ra8.components.usb_echo_far;

/// MBW programmed for a 16-bit access, aimed at `pipe`.
fn sel16(pipe: u16) u16 {
    return pipe | (regs.dfifo.mbw_16 << regs.dfifo.mbw_shift);
}

test "a data port aims at a data pipe" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(1), null);
    try std.testing.expectEqual(@as(?u32, 1), ports.ports[0].pipe());
    try std.testing.expectEqual(@as(u32, 0), ports.refusals());
}

test "CURPIPE 0 parks a data port without refusing it" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(1), null);
    ports.select(0, sel16(0), null);
    try std.testing.expectEqual(@as(?u32, null), ports.ports[0].pipe());
    try std.testing.expectEqual(@as(u32, 0), ports.refusals());
}

test "a pipe the part does not have aims the port at nothing" {
    var ports: dfifo.Ports = .{};
    ports.select(1, sel16(12), null);
    try std.testing.expectEqual(@as(?u32, null), ports.ports[1].pipe());
    try std.testing.expectEqual(@as(u32, 1), ports.ports[1].bad_pipe);
}

test "two data ports cannot hold one pipe" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(3), null);
    ports.select(1, sel16(3), null);
    try std.testing.expectEqual(@as(?u32, 3), ports.ports[0].pipe());
    try std.testing.expectEqual(@as(?u32, null), ports.ports[1].pipe());
    try std.testing.expectEqual(@as(u32, 1), ports.ports[1].contended);
}

test "the control port's pipe is not a data port's to take" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(2), 2);
    try std.testing.expectEqual(@as(?u32, null), ports.ports[0].pipe());
    try std.testing.expectEqual(@as(u32, 1), ports.ports[0].contended);
}

test "a released pipe can be re-aimed by the other port" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(4), null);
    ports.select(0, sel16(5), null);
    ports.select(1, sel16(4), null);
    try std.testing.expectEqual(@as(?u32, 4), ports.ports[1].pipe());
    try std.testing.expectEqual(@as(u32, 0), ports.refusals());
}

test "MBW says how wide an access the port answers" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(1), null);
    try std.testing.expect(ports.accepts(0, 2));
    try std.testing.expect(!ports.accepts(0, 4));
    try std.testing.expectEqual(@as(u32, 1), ports.ports[0].bad_width);
}

test "an MBW the part does not have answers nothing" {
    var ports: dfifo.Ports = .{};
    ports.select(0, 1 | (3 << regs.dfifo.mbw_shift), null);
    try std.testing.expectEqual(@as(?u3, null), ports.ports[0].width());
    try std.testing.expect(!ports.accepts(0, 1));
}

test "the three access widths MBW can ask for" {
    var ports: dfifo.Ports = .{};
    ports.select(0, 1 | (regs.dfifo.mbw_8 << regs.dfifo.mbw_shift), null);
    try std.testing.expectEqual(@as(?u3, 1), ports.ports[0].width());
    ports.select(0, 1 | (regs.dfifo.mbw_16 << regs.dfifo.mbw_shift), null);
    try std.testing.expectEqual(@as(?u3, 2), ports.ports[0].width());
    ports.select(0, 1 | (regs.dfifo.mbw_32 << regs.dfifo.mbw_shift), null);
    try std.testing.expectEqual(@as(?u3, 4), ports.ports[0].width());
}

test "a data port runs the direction its pipe was configured for" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(1), null);
    try std.testing.expect(ports.runs(0, true, true));
    try std.testing.expect(ports.runs(0, false, false));
    try std.testing.expect(!ports.runs(0, true, false));
    try std.testing.expect(!ports.runs(0, false, true));
    try std.testing.expectEqual(@as(u32, 2), ports.ports[0].wrong_way);
}

test "DCLRM is read off the selector" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(1), null);
    try std.testing.expect(!ports.ports[0].autoClears());
    ports.select(0, sel16(1) | regs.dfifo.dclrm, null);
    try std.testing.expect(ports.ports[0].autoClears());
}

test "a refused aim leaves no pipe number behind in the selector" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(9) | regs.dfifo.dreqe, null);
    ports.select(0, sel16(12) | regs.dfifo.dreqe, null);
    try std.testing.expectEqual(@as(u16, 0), ports.ports[0].sel & regs.fifo.curpipe_mask);
    try std.testing.expect(ports.ports[0].sel & regs.dfifo.dreqe != 0);
}

test "the four offsets each data port owns" {
    try std.testing.expectEqual(@as(?u32, 0), dfifo.portOf(regs.reg.d0fifo));
    try std.testing.expectEqual(@as(?u32, 0), dfifo.portOf(regs.reg.d0fifosel));
    try std.testing.expectEqual(@as(?u32, 0), dfifo.portOf(regs.reg.d0fifoctr));
    try std.testing.expectEqual(@as(?u32, 1), dfifo.portOf(regs.reg.d1fifo));
    try std.testing.expectEqual(@as(?u32, 1), dfifo.portOf(regs.reg.d1fifosel));
    try std.testing.expectEqual(@as(?u32, 1), dfifo.portOf(regs.reg.d1fifoctr));
    try std.testing.expectEqual(@as(?u32, null), dfifo.portOf(regs.reg.cfifo));
}

test "a 32-bit data access reaches the upper half of the port" {
    try std.testing.expect(dfifo.isData(regs.reg.d0fifo + regs.window.word));
    try std.testing.expect(dfifo.isData(regs.reg.d1fifo + regs.window.word));
    try std.testing.expect(!dfifo.isData(regs.reg.d0fifosel));
}

test "a fresh pair is quiet" {
    const ports: dfifo.Ports = .{};
    try std.testing.expect(ports.quiet());
}

/// The device liveHost plugs into the far end.
var echo: echo_device.Device = .{};

/// A host brought far enough up to move bulk payload: powered, in host role,
/// a device on the bus that has been through a reset.
fn liveHost(host: *usbhs.Host) void {
    echo = .{};
    host.xfer.far = echo_far.far(&echo);
    host.attachDevice();
    host.write(regs.window.base + regs.reg.syscfg, 2, regs.syscfg.usbe | regs.syscfg.scke |
        regs.syscfg.dcfm | regs.syscfg.cnen);
    host.write(regs.window.base + regs.reg.dvstctr0, 2, regs.port.vbusen | regs.port.usbrst);
    host.write(regs.window.base + regs.reg.dvstctr0, 2, regs.port.vbusen | regs.port.uact);
}

/// Program PIPE1 as a bulk OUT on endpoint 2 and arm it.
fn bulkOut(host: *usbhs.Host) void {
    host.write(regs.window.base + regs.reg.pipesel, 2, 1);
    host.write(regs.window.base + regs.reg.pipecfg, 2, regs.pipe.dir_transmit | 2);
    host.write(regs.window.base + regs.reg.pipemaxp, 2, 64);
    host.write(regs.window.base + regs.reg.pipectr, 2, regs.pipe.pid_buf);
}

test "a bulk OUT packet goes out through the data port" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    bulkOut(&host);
    echo.state = .configured;
    host.write(regs.window.base + regs.reg.d0fifosel, 2, sel16(1));
    host.write(regs.window.base + regs.reg.d0fifo, 2, 0xBEEF);
    host.write(regs.window.base + regs.reg.d0fifoctr, 2, regs.fifo.bval);
    try std.testing.expect(echo.echo_ready);
    try std.testing.expectEqual(@as(u16, 2), echo.echo_len);
}

test "the payload a data port stages is not read back from a shadow" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    bulkOut(&host);
    host.write(regs.window.base + regs.reg.d0fifosel, 2, sel16(1));
    host.write(regs.window.base + regs.reg.d0fifo, 2, 0x1234);
    // dev let this offset fall to the register shadow, so the store read
    // straight back. An OUT pipe answers nothing on a read.
    try std.testing.expectEqual(@as(u32, 0), host.read(regs.window.base + regs.reg.d0fifo, 2));
    try std.testing.expectEqual(@as(u32, 1), host.xfer.data.ports[0].wrong_way);
}

test "an access of the wrong width moves no bytes" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    bulkOut(&host);
    host.write(regs.window.base + regs.reg.d0fifosel, 2, sel16(1));
    host.write(regs.window.base + regs.reg.d0fifo, 4, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u16, 0), host.xfer.port.out[1].len);
    try std.testing.expectEqual(@as(u32, 1), host.xfer.data.ports[0].bad_width);
}

test "the selector reads back through the window" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    host.write(regs.window.base + regs.reg.d1fifosel, 2, sel16(2));
    try std.testing.expectEqual(
        @as(u32, sel16(2)),
        host.read(regs.window.base + regs.reg.d1fifosel, 2),
    );
}

test "a bus reset keeps what was already refused" {
    var ports: dfifo.Ports = .{};
    ports.select(0, sel16(12), null);
    ports.select(0, sel16(1), null);
    ports.release();
    try std.testing.expectEqual(@as(?u32, null), ports.ports[0].pipe());
    try std.testing.expectEqual(@as(u32, 1), ports.ports[0].bad_pipe);
}

test "a bus reset lets go of both data ports" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    host.write(regs.window.base + regs.reg.d0fifosel, 2, sel16(1));
    host.write(regs.window.base + regs.reg.dvstctr0, 2, regs.port.usbrst);
    host.write(regs.window.base + regs.reg.dvstctr0, 2, regs.port.uact);
    try std.testing.expectEqual(@as(?u32, null), host.xfer.data.ports[0].pipe());
}

test "the window reports what the data ports refused, after a reset" {
    var host: usbhs.Host = .{};
    liveHost(&host);
    host.write(regs.window.base + regs.reg.d0fifosel, 2, sel16(12));
    host.write(regs.window.base + regs.reg.dvstctr0, 2, regs.port.usbrst);
    host.write(regs.window.base + regs.reg.dvstctr0, 2, regs.port.uact);
    try std.testing.expect(host.refusals() != 0);
}
