//! The USBFS device window: VBUS, the line state after the pull-up, the
//! INTSTS0 flags a driver clears, and the shadow behind the rest.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs.regs;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

test "the window is the controller's own" {
    var device = usbfs.Device{};
    const block = device.block();
    try std.testing.expectEqual(@as(u32, 0x4025_0000), block.base);
    try std.testing.expect(block.covers(at(regs.reg.dcpctr)));
    try std.testing.expect(!block.covers(usbfs.window.base + usbfs.window.span));
}

test "the line stays SE0 until the device pulls D+ up with VBUS present" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.syssts0), 2));
    device.connectVbus();
    try std.testing.expectEqual(@as(u32, regs.port.lnst_j), device.read(at(regs.reg.syssts0), 2));
}

test "host role sees no device-side J-state" {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu | regs.syscfg.dcfm);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.syssts0), 2));
}

test "VBUS latches VBINT and VBSTS follows the jack" {
    var device = usbfs.Device{};
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2));
    device.connectVbus();
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expect(status & usbfs.intsts0.vbint != 0);
    try std.testing.expect(status & usbfs.intsts0.vbsts != 0);
}

test "writing 0 clears VBINT; VBSTS cannot be cleared" {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.vbint));
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, 0), status & usbfs.intsts0.vbint);
    try std.testing.expect(status & usbfs.intsts0.vbsts != 0);
}

test "SYSSTS0 refuses a store" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.syssts0), 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), device.refusals());
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.syssts0), 2));
}

test "everything else reads back what was written" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.dcpmaxp), 2, 0x0040);
    device.write(at(regs.reg.intenb0), 2, 0x9C00);
    try std.testing.expectEqual(@as(u32, 0x0040), device.read(at(regs.reg.dcpmaxp), 2));
    try std.testing.expectEqual(@as(u32, 0x9C00), device.read(at(regs.reg.intenb0), 2));
}

test "an odd address is refused" {
    var device = usbfs.Device{};
    device.write(at(0x21), 1, 0xAA);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(0x21), 1));
    try std.testing.expectEqual(@as(u32, 2), device.refusals());
}

fn pulledUp() usbfs.Device {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    return device;
}

test "the pull-up brings a bus reset: Default state, DVST, full speed" {
    var device = pulledUp();
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_default), status & usbfs.intsts0.dvsq_mask);
    try std.testing.expect(status & usbfs.intsts0.dvst != 0);
    const port = device.read(at(regs.reg.dvstctr0), 2);
    try std.testing.expectEqual(@as(u32, regs.port.rhst_full), port & regs.port.rhst_mask);
}

test "no reset while the module is off or VBUS is absent" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2) & usbfs.intsts0.dvst);
    var off = usbfs.Device{};
    off.connectVbus();
    off.write(at(regs.reg.syscfg), 2, regs.syscfg.dprpu);
    try std.testing.expectEqual(@as(u32, 0), off.read(at(regs.reg.intsts0), 2) & usbfs.intsts0.dvsq_mask);
}

test "clearing DVST leaves the device state alone" {
    var device = pulledUp();
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.dvst));
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, 0), status & usbfs.intsts0.dvst);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_default), status & usbfs.intsts0.dvsq_mask);
}

test "dropping the pull-up goes back to Powered and latches DVST again" {
    var device = pulledUp();
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.dvst));
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe);
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_powered), status & usbfs.intsts0.dvsq_mask);
    try std.testing.expect(status & usbfs.intsts0.dvst != 0);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.dvstctr0), 2) & regs.port.rhst_mask);
}

test "RHST cannot be written; the rest of DVSTCTR0 reads back" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.dvstctr0), 2, regs.port.rhst_high | regs.port.uact);
    try std.testing.expectEqual(@as(u32, regs.port.uact), device.read(at(regs.reg.dvstctr0), 2));
}

const get_descriptor = [8]u8{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 };
/// A no-data request the driver answers (SET_ADDRESS never reaches it).
const set_feature = [8]u8{ 0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };

test "a SETUP fills USBREQ, USBVAL, USBINDX and USBLENG" {
    var device = pulledUp();
    device.setup(get_descriptor);
    try std.testing.expectEqual(@as(u32, 0x0680), device.read(at(regs.reg.usbreq), 2));
    try std.testing.expectEqual(@as(u32, 0x0100), device.read(at(regs.reg.usbval), 2));
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.usbindx), 2));
    try std.testing.expectEqual(@as(u32, 0x12), device.read(at(regs.reg.usbleng), 2));
}

test "a SETUP latches VALID and CTRT and picks the control stage" {
    var device = pulledUp();
    device.setup(get_descriptor);
    var status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expect(status & usbfs.intsts0.valid != 0);
    try std.testing.expect(status & usbfs.intsts0.ctrt != 0);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.ctsq_read_data), status & usbfs.intsts0.ctsq_mask);
    device.setup(set_feature);
    status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.ctsq_no_data_status), status & usbfs.intsts0.ctsq_mask);
    device.setup(.{ 0x21, 0x20, 0, 0, 0, 0, 7, 0 });
    status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.ctsq_write_data), status & usbfs.intsts0.ctsq_mask);
}

test "clearing VALID keeps the stage; firmware cannot write the SETUP fields" {
    var device = pulledUp();
    device.setup(get_descriptor);
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.valid));
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, 0), status & usbfs.intsts0.valid);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.ctsq_read_data), status & usbfs.intsts0.ctsq_mask);
    device.write(at(regs.reg.usbreq), 2, 0);
    try std.testing.expectEqual(@as(u32, 0x0680), device.read(at(regs.reg.usbreq), 2));
    try std.testing.expectEqual(@as(u32, 1), device.refusals());
}

/// VBUS on, pull-up on, DVST cleared: the device sits in Default.
fn attached() usbfs.Device {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.dvst | usbfs.intsts0.vbint));
    return device;
}

fn state(device: *usbfs.Device) u32 {
    return device.read(at(regs.reg.intsts0), 2) & usbfs.intsts0.dvsq_mask;
}

const set_address_5 = [8]u8{ 0x00, 0x05, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00 };
const set_configuration_1 = [8]u8{ 0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
const set_configuration_0 = [8]u8{ 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

test "SET_ADDRESS is answered by the SIE: USBADDR, Address state, DVST, no VALID" {
    var device = attached();
    device.setup(set_address_5);
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_address), status & usbfs.intsts0.dvsq_mask);
    try std.testing.expect(status & usbfs.intsts0.dvst != 0);
    try std.testing.expectEqual(@as(u32, 0), status & (usbfs.intsts0.valid | usbfs.intsts0.ctrt));
    try std.testing.expectEqual(@as(u32, 5), device.read(at(regs.reg.usbaddr), 2));
}

test "SET_CONFIGURATION reaches the driver and moves Address to Configured and back" {
    var device = attached();
    device.setup(set_address_5);
    device.setup(set_configuration_1);
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_configured), status & usbfs.intsts0.dvsq_mask);
    try std.testing.expect(status & usbfs.intsts0.valid != 0);
    device.setup(set_configuration_0);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_address), state(&device));
}

test "SET_CONFIGURATION before an address leaves the device in Default" {
    var device = attached();
    device.setup(set_configuration_1);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_default), state(&device));
}

test "rewriting SYSCFG while attached keeps the address" {
    var device = attached();
    device.setup(set_address_5);
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_address), state(&device));
}

test "CCPL ends the status stage: CTSQ idle, CTRT, CCPL reads back 0" {
    var device = attached();
    device.setup(.{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 });
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.ctrt | usbfs.intsts0.valid));
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl | regs.dcpctr.pid_buf);
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.ctsq_idle), status & usbfs.intsts0.ctsq_mask);
    try std.testing.expect(status & usbfs.intsts0.ctrt != 0);
    const pipe = device.read(at(regs.reg.dcpctr), 2);
    try std.testing.expectEqual(@as(u32, 0), pipe & regs.dcpctr.ccpl);
    try std.testing.expectEqual(@as(u32, regs.dcpctr.pid_buf), pipe & regs.dcpctr.pid_mask);
    try std.testing.expect(pipe & regs.dcpctr.bsts != 0);
}

test "CCPL with no transfer in flight latches nothing" {
    var device = attached();
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2) & usbfs.intsts0.ctrt);
}

test "the status token after a read's data stage moves CTSQ to read status" {
    var device = usbfs.Device{};
    device.setup(.{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 });
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.ctrt));
    device.statusStage();
    const status = device.interruptStatus();
    try std.testing.expectEqual(usbfs.intsts0.ctsq_read_status, status & usbfs.intsts0.ctsq_mask);
    try std.testing.expect(status & usbfs.intsts0.ctrt != 0);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl);
    try std.testing.expectEqual(usbfs.intsts0.ctsq_idle, device.interruptStatus() & usbfs.intsts0.ctsq_mask);
}

test "the status token after a write's data stage moves CTSQ to write status" {
    var device = usbfs.Device{};
    device.setup(.{ 0x21, 0x20, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00 });
    device.statusStage();
    try std.testing.expectEqual(usbfs.intsts0.ctsq_write_status, device.interruptStatus() & usbfs.intsts0.ctsq_mask);
}

test "a status token with no data stage in flight changes nothing" {
    var device = usbfs.Device{};
    device.statusStage();
    try std.testing.expectEqual(usbfs.intsts0.ctsq_idle, device.interruptStatus() & usbfs.intsts0.ctsq_mask);
    try std.testing.expect(device.interruptStatus() & usbfs.intsts0.ctrt == 0);
}

test "a SETUP sets the DCP PID back to NAK, clearing a STALL" {
    var device = usbfs.Device{};
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    device.setup(.{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 });
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.dcpctr), 2) & regs.dcpctr.pid_mask);
}

test {
    _ = @import("pipe_test.zig");
    _ = @import("bulk_test.zig");
}
