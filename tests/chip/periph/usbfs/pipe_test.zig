//! The USBFS pipe window: PIPESEL picks a pipe, PIPECFG, PIPEMAXP and
//! PIPEPERI follow it, PIPEnCTR stands per pipe, and find() routes.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs.regs;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

/// PIPECFG for a bulk pipe on an endpoint, the way the driver composes it.
fn bulk(endpoint: u16, in: bool) u16 {
    const dir: u16 = if (in) pipe.cfg.dir_in else 0;
    return (1 << pipe.cfg.kind_shift) | dir | endpoint;
}

fn open(device: *usbfs.Device, n: u16, config: u16, max_packet: u16) void {
    device.write(at(regs.reg.pipesel), 2, n);
    device.write(at(regs.reg.pipecfg), 2, config);
    device.write(at(regs.reg.pipemaxp), 2, max_packet);
    device.write(at(regs.reg.pipesel), 2, 0);
}

test "the pipe registers are the pipe model's" {
    try std.testing.expect(pipe.Pipes.owns(regs.reg.pipesel));
    try std.testing.expect(pipe.Pipes.owns(regs.reg.pipecfg));
    try std.testing.expect(pipe.Pipes.owns(regs.reg.pipectr));
    try std.testing.expect(pipe.Pipes.owns(regs.reg.pipectr + 16));
    try std.testing.expect(!pipe.Pipes.owns(regs.reg.pipectr + 18));
    try std.testing.expect(!pipe.Pipes.owns(regs.reg.dcpctr));
}

test "PIPECFG and PIPEMAXP follow the selected pipe" {
    var device = usbfs.Device{};
    open(&device, 1, bulk(2, false), 64);
    open(&device, 2, bulk(1, true), 32);
    device.write(at(regs.reg.pipesel), 2, 1);
    try std.testing.expectEqual(@as(u32, bulk(2, false)), device.read(at(regs.reg.pipecfg), 2));
    try std.testing.expectEqual(@as(u32, 64), device.read(at(regs.reg.pipemaxp), 2));
    device.write(at(regs.reg.pipesel), 2, 2);
    try std.testing.expectEqual(@as(u32, bulk(1, true)), device.read(at(regs.reg.pipecfg), 2));
    try std.testing.expectEqual(@as(u32, 32), device.read(at(regs.reg.pipemaxp), 2));
    try std.testing.expectEqual(@as(u32, 2), device.read(at(regs.reg.pipesel), 2));
}

test "with no pipe selected the window reads zero and drops writes" {
    var device = usbfs.Device{};
    open(&device, 3, bulk(1, true), 64);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.pipecfg), 2));
    const before = device.refusals();
    device.write(at(regs.reg.pipecfg), 2, 0xFFFF);
    try std.testing.expectEqual(before + 1, device.refusals());
    try std.testing.expectEqual(bulk(1, true), device.pipes.get(3).?.config);
}

test "PIPEnCTR keeps PID and ACLRM per pipe" {
    var device = usbfs.Device{};
    const ctr4 = regs.reg.pipectr + 2 * 3;
    device.write(at(ctr4), 2, @backingInt(pipe.Pid.buf) | pipe.ctr.aclrm);
    try std.testing.expectEqual(pipe.Pid.buf, device.pipes.get(4).?.pid());
    try std.testing.expectEqual(@as(u32, 1 | pipe.ctr.aclrm), device.read(at(ctr4), 2));
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.pipectr), 2));
}

test "SQSET and SQCLR move the toggle and do not read back" {
    var device = usbfs.Device{};
    const ctr1 = regs.reg.pipectr;
    device.write(at(ctr1), 2, pipe.ctr.sqset);
    try std.testing.expect(device.pipes.get(1).?.toggle());
    try std.testing.expectEqual(@as(u32, pipe.ctr.sqmon), device.read(at(ctr1), 2));
    device.write(at(ctr1), 2, pipe.ctr.sqclr);
    try std.testing.expect(!device.pipes.get(1).?.toggle());
}

test "find routes an endpoint and direction to the pipe the driver opened" {
    var device = usbfs.Device{};
    open(&device, 1, bulk(2, false), 64);
    open(&device, 2, bulk(1, true), 64);
    open(&device, 3, (2 << pipe.cfg.kind_shift) | pipe.cfg.dir_in | 3, 8);
    try std.testing.expectEqual(@as(?u4, 1), device.pipes.find(2, false));
    try std.testing.expectEqual(@as(?u4, 2), device.pipes.find(1, true));
    try std.testing.expectEqual(@as(?u4, 3), device.pipes.find(3, true));
    try std.testing.expectEqual(pipe.Kind.interrupt, device.pipes.get(3).?.kind());
    try std.testing.expectEqual(@as(?u4, null), device.pipes.find(2, true));
}
