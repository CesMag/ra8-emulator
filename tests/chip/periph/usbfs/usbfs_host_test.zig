//! The scripted host on the USBFS jack, against a stand-in driver that
//! answers each request the way a device stack would.
const std = @import("std");
const ra8 = @import("ra8");
const usbfs = ra8.chip.periph.usbfs;
const regs = ra8.chip.periph.usbhs_regs;
const Host = usbfs.host.Host;

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

const device_descriptor = [18]u8{ 18, 1, 0x00, 0x02, 2, 0, 0, 64, 0x5B, 0x04, 0x01, 0x00, 0, 1, 1, 2, 3, 1 };
/// A whole configuration set: header, one interface, one bulk IN endpoint.
const config_descriptor = [25]u8{
    9, 2, 25,   0, 1,  1,    0, 0x80, 50,
    9, 4, 0,    0, 1,  0xFF, 0, 0,    0,
    7, 5, 0x81, 2, 64, 0,    0,
};

/// String descriptor 0 listing US English, and "RA8" as the iProduct string.
const languages = [4]u8{ 4, 3, 0x09, 0x04 };
const product = [8]u8{ 8, 3, 'R', 0, 'A', 0, '8', 0 };

fn attached() usbfs.Device {
    var device = usbfs.Device{};
    device.connectVbus();
    device.write(at(regs.reg.syscfg), 2, regs.syscfg.usbe | regs.syscfg.dprpu);
    return device;
}

fn send(device: *usbfs.Device, bytes: []const u8) void {
    device.write(at(regs.reg.cfifosel), 2, regs.fifo.isel);
    for (bytes) |byte| device.write(at(regs.reg.cfifo), 1, byte);
    device.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
}

/// Answer a pending SETUP: descriptors for GET_DESCRIPTOR, nothing for the
/// rest, then CCPL to end the status stage.
fn answer(device: *usbfs.Device) void {
    const status = device.read(at(regs.reg.intsts0), 2);
    if (status & usbfs.intsts0.valid == 0) return;
    device.write(at(regs.reg.intsts0), 2, ~@as(u32, usbfs.intsts0.valid));
    const request = device.read(at(regs.reg.usbreq), 2);
    const value = device.read(at(regs.reg.usbval), 2);
    const length = device.read(at(regs.reg.usbleng), 2);
    if (request == 0x0680 and value == 0x0100) send(device, &device_descriptor);
    if (request == 0x0680 and value == 0x0200) send(device, config_descriptor[0..@min(length, config_descriptor.len)]);
    if (request == 0x0880) send(device, &.{1});
    if (request == 0x0680 and value == 0x0300) send(device, &languages);
    if (request == 0x0680 and value == 0x0302) send(device, &product);
    if (request == 0x0080) send(device, &.{ 1, 0 });
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl | regs.dcpctr.pid_buf);
}

test "a device that answers is enumerated to Configured" {
    var device = attached();
    var host = Host{};
    var i: u32 = 0;
    while (i < 100 and !host.done()) : (i += 1) {
        host.tick(&device);
        answer(&device);
    }
    try std.testing.expect(host.done());
    try std.testing.expectEqualSlices(u8, &device_descriptor, &host.device);
    try std.testing.expectEqualSlices(u8, &config_descriptor, host.configuration());
    try std.testing.expectEqual(@as(u8, 1), host.config_value[0]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0 }, &host.status);
    try std.testing.expectEqualSlices(u8, &languages, host.languages[0..4]);
    try std.testing.expectEqualSlices(u8, &product, host.product[0..8]);
    try std.testing.expectEqual(usbfs.host.Answer.ack, host.interface);
    try std.testing.expectEqual(usbfs.host.Answer.ack, host.halt_set);
    try std.testing.expectEqual(usbfs.host.Answer.ack, host.halt_clear);
    const status = device.read(at(regs.reg.intsts0), 2);
    try std.testing.expectEqual(@as(u32, usbfs.intsts0.dvsq_configured), status & usbfs.intsts0.dvsq_mask);
    try std.testing.expectEqual(@as(u32, usbfs.host.requests.address), device.read(at(regs.reg.usbaddr), 2));
}

test "the host waits while nothing pulls D+ up" {
    var device = usbfs.Device{};
    var host = Host{};
    host.tick(&device);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.waiting, host.step);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.intsts0), 2) & usbfs.intsts0.valid);
}

test "a driver that never answers ends the script in failed" {
    var device = attached();
    var host = Host{ .patience = 5 };
    var i: u32 = 0;
    while (i < 20) : (i += 1) host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.failed, host.step);
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, host.failed_on);
    try std.testing.expect(!host.done());
}

test "the host does not move on until the driver ends the status stage" {
    var device = attached();
    var host = Host{};
    host.tick(&device);
    host.tick(&device);
    send(&device, &device_descriptor);
    var i: u32 = 0;
    while (i < 5) : (i += 1) host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, host.step);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.set_address, host.step);
}

test "once the data is in, the host sends the status token before waiting on CCPL" {
    var device = attached();
    var host = Host{};
    host.tick(&device);
    host.tick(&device);
    send(&device, &device_descriptor);
    host.tick(&device);
    host.tick(&device);
    const stage = device.interruptStatus() & usbfs.intsts0.ctsq_mask;
    try std.testing.expectEqual(usbfs.intsts0.ctsq_read_status, stage);
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, host.step);
}

test "the first read asks for the whole 18-byte device descriptor" {
    const packet = usbfs.host.requests.device_descriptor;
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x06, 0x00, 0x01, 0, 0, 18, 0 }, &packet);
}

test "SET_ADDRESS moves the device to the host's one address" {
    const packet = usbfs.host.requests.set_address;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x05, 1, 0, 0, 0, 0, 0 }, &packet);
}

test "SET_CONFIGURATION picks configuration value 1" {
    const packet = usbfs.host.requests.set_configuration;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x09, 1, 0, 0, 0, 0, 0 }, &packet);
}

test "the second configuration read asks for wTotalLength bytes" {
    const packet = usbfs.host.requests.configDescriptor(75);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 75, 0 }, &packet);
}

test "before the full read the host holds the nine-byte header" {
    var host = Host{};
    host.config[0] = 9;
    try std.testing.expectEqual(@as(usize, 9), host.configuration().len);
    host.config_len = 25;
    try std.testing.expectEqual(@as(usize, 25), host.configuration().len);
}

test "GET_CONFIGURATION asks for the one-byte configuration value" {
    const packet = usbfs.host.requests.get_configuration;
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x08, 0, 0, 0, 0, 1, 0 }, &packet);
}

test "GET_STATUS asks the device for its two status bytes" {
    const packet = usbfs.host.requests.get_status;
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x00, 0, 0, 0, 0, 2, 0 }, &packet);
}

test "after SET_CONFIGURATION the host reads the value back, then the status" {
    var device = attached();
    var host = Host{ .step = .set_configuration };
    var i: u32 = 0;
    while (i < 100 and host.step == .set_configuration) : (i += 1) {
        host.tick(&device);
        answer(&device);
    }
    try std.testing.expectEqual(usbfs.host.Step.get_configuration, host.step);
    while (i < 200 and host.step == .get_configuration) : (i += 1) {
        host.tick(&device);
        answer(&device);
    }
    try std.testing.expectEqual(usbfs.host.Step.get_status, host.step);
    try std.testing.expectEqual(@as(u8, 1), host.config_value[0]);
}

test "a device that never answers GET_STATUS leaves the host short of configured" {
    var device = attached();
    var host = Host{ .step = .get_status, .patience = 5 };
    var i: u32 = 0;
    while (i < 20) : (i += 1) host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.failed, host.step);
}

test "a string read asks for up to 255 bytes of the index in that language" {
    const packet = usbfs.host.requests.stringDescriptor(2, 0x0409);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x06, 2, 3, 0x09, 0x04, 0xFF, 0 }, &packet);
}

test "a short packet ends a read before the requested length" {
    var device = attached();
    var host = Host{ .step = .string_languages };
    host.device[15] = 2;
    host.tick(&device);
    send(&device, &languages);
    host.tick(&device);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.intsts0.ctsq_read_status, device.interruptStatus() & usbfs.intsts0.ctsq_mask);
    try std.testing.expectEqualSlices(u8, &languages, host.languages[0..4]);
}

test "a device that names no product skips the product string" {
    var device = attached();
    var host = Host{ .step = .string_product };
    host.languages[0] = 4;
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.set_interface, host.step);
}

test "the product string is asked for in the device's first language" {
    var device = attached();
    var host = Host{ .step = .string_product };
    host.device[15] = 2;
    @memcpy(host.languages[0..4], &languages);
    host.tick(&device);
    try std.testing.expectEqual(@as(u32, 0x0302), device.read(at(regs.reg.usbval), 2));
    try std.testing.expectEqual(@as(u32, 0x0409), device.read(at(regs.reg.usbindx), 2));
}

test "SET_INTERFACE asks for alternate 0 of interface 0" {
    const packet = usbfs.host.requests.set_interface;
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x0B, 0, 0, 0, 0, 0, 0 }, &packet);
}

test "a STALL is a valid answer to SET_INTERFACE" {
    var device = attached();
    var host = Host{ .step = .set_interface };
    host.tick(&device);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.configured, host.step);
    try std.testing.expectEqual(usbfs.host.Answer.stall, host.interface);
}

test "a STALL on SET_CONFIGURATION ends the script in failed" {
    var device = attached();
    var host = Host{ .step = .set_configuration };
    host.tick(&device);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.failed, host.step);
    try std.testing.expectEqual(usbfs.host.Step.set_configuration, host.failed_on);
}

test "the halt requests name the feature and the endpoint" {
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 0, 0, 0x81, 0, 0, 0 }, &usbfs.host.requests.endpointHalt(true, 0x81));
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0, 0, 0x81, 0, 0, 0 }, &usbfs.host.requests.endpointHalt(false, 0x81));
}

test "the first endpoint is found by walking the descriptors" {
    try std.testing.expectEqual(@as(?u8, 0x81), usbfs.host.firstEndpoint(&config_descriptor));
    try std.testing.expectEqual(@as(?u8, null), usbfs.host.firstEndpoint(config_descriptor[0..18]));
    try std.testing.expectEqual(@as(?u8, null), usbfs.host.firstEndpoint(&.{ 0, 2, 0 }));
}

test "the host halts the first endpoint, then clears it" {
    var device = attached();
    var host = Host{ .step = .set_halt };
    @memcpy(host.config[0..config_descriptor.len], &config_descriptor);
    host.config_len = config_descriptor.len;
    host.tick(&device);
    try std.testing.expectEqual(@as(u32, 0x0302), device.read(at(regs.reg.usbreq), 2));
    try std.testing.expectEqual(@as(u32, 0x81), device.read(at(regs.reg.usbindx), 2));
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.clear_halt, host.step);
    host.tick(&device);
    try std.testing.expectEqual(@as(u32, 0x0102), device.read(at(regs.reg.usbreq), 2));
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.configured, host.step);
    try std.testing.expectEqual(usbfs.host.Answer.ack, host.halt_set);
    try std.testing.expectEqual(usbfs.host.Answer.stall, host.halt_clear);
}

test "a set with no endpoints skips the halt requests" {
    var device = attached();
    var host = Host{ .step = .set_interface };
    @memcpy(host.config[0..18], config_descriptor[0..18]);
    host.config_len = 18;
    host.tick(&device);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.ccpl);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.configured, host.step);
}

test "a device that names no strings skips string descriptor 0" {
    var device = attached();
    var host = Host{ .step = .string_languages };
    @memcpy(&host.device, &device_descriptor);
    @memset(host.device[14..17], 0);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.set_interface, host.step);
    try std.testing.expectEqual(@as(u32, 0), device.read(at(regs.reg.usbreq), 2));
}

test "a STALL on GET_CONFIGURATION is noted and the host moves on" {
    var device = attached();
    var host = Host{ .step = .get_configuration };
    host.tick(&device);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.get_status, host.step);
    try std.testing.expectEqual(usbfs.host.Answer.stall, host.config_answer);
}

test "a STALL on a descriptor read ends the script in failed" {
    var device = attached();
    var host = Host{ .step = .device_descriptor };
    host.tick(&device);
    device.write(at(regs.reg.dcpctr), 2, regs.dcpctr.pid_stall);
    host.tick(&device);
    try std.testing.expectEqual(usbfs.host.Step.failed, host.step);
    try std.testing.expectEqual(usbfs.host.Step.device_descriptor, host.failed_on);
}
