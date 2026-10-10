//! The device on the far end: what it answers, and what it refuses.
const std = @import("std");
const ra8 = @import("ra8");
const device = ra8.components.usb_echo;
const setup = ra8.chip.periph.usbhs.setup;

fn get(code: u8, value: u16, length: u16) setup.Packet {
    return .{ .request_type = 0x80, .code = code, .value = value, .length = length };
}

fn set(code: u8, value: u16) setup.Packet {
    return .{ .request_type = 0x00, .code = code, .value = value };
}

test "a fresh device is in Default with no address" {
    const part = device.Device{};
    try std.testing.expectEqual(device.State.default, part.state);
    try std.testing.expectEqual(@as(u8, 0), part.address);
    try std.testing.expect(part.quiet());
}

test "the device descriptor comes back whole" {
    var part = device.Device{};
    try std.testing.expect(part.handle(get(setup.request.get_descriptor, 0x0100, 18)));
    try std.testing.expect(part.reply_ready);
    var into: [64]u8 = undefined;
    const len = part.takeReply(&into);
    try std.testing.expectEqual(@as(u16, 18), len);
    try std.testing.expectEqual(@as(u8, 18), into[0]);
    try std.testing.expectEqual(device.descriptors.device[1], into[1]);
    try std.testing.expect(!part.reply_ready);
}

test "a short read is cut to what the host asked for" {
    var part = device.Device{};
    // The first pass of the two-pass descriptor read asks for eight bytes.
    try std.testing.expect(part.handle(get(setup.request.get_descriptor, 0x0200, 8)));
    try std.testing.expectEqual(@as(u16, 8), part.reply_len);
}

test "a descriptor the device does not have is stalled" {
    var part = device.Device{};
    try std.testing.expect(!part.handle(get(setup.request.get_descriptor, 0x0300, 4)));
    try std.testing.expectEqual(@as(u32, 1), part.unsupported);
    try std.testing.expect(!part.reply_ready);
}

test "a request the device does not implement is stalled" {
    var part = device.Device{};
    try std.testing.expect(!part.handle(set(0x0B, 0)));
    try std.testing.expectEqual(@as(u32, 1), part.unsupported);
}

test "SET_ADDRESS moves the device out of Default" {
    var part = device.Device{};
    try std.testing.expect(part.handle(set(setup.request.set_address, 7)));
    try std.testing.expectEqual(device.State.address, part.state);
    try std.testing.expectEqual(@as(u8, 7), part.address);
}

test "a configuration before an address is refused" {
    var part = device.Device{};
    try std.testing.expect(!part.handle(set(setup.request.set_configuration, 1)));
    try std.testing.expectEqual(device.State.default, part.state);
    try std.testing.expectEqual(@as(u32, 1), part.out_of_order);
}

test "a configuration after an address takes" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    try std.testing.expect(part.handle(set(setup.request.set_configuration, 1)));
    try std.testing.expectEqual(device.State.configured, part.state);
    try std.testing.expectEqual(@as(u8, 1), part.configuration);
}

test "configuration zero puts the device back to Address" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    _ = part.handle(set(setup.request.set_configuration, 0));
    try std.testing.expectEqual(device.State.address, part.state);
}

test "a configured device cannot be re-addressed" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    try std.testing.expect(!part.handle(set(setup.request.set_address, 9)));
    try std.testing.expectEqual(@as(u8, 7), part.address);
}

test "an unconfigured device has no endpoints to take a bulk packet" {
    var part = device.Device{};
    try std.testing.expect(!part.bulkOut(&[_]u8{ 1, 2, 3 }));
    try std.testing.expect(!part.echo_ready);
    try std.testing.expectEqual(@as(u32, 1), part.out_of_order);
}

test "a configured device echoes what it was given" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    try std.testing.expect(part.bulkOut(&[_]u8{ 0x55, 0xAA, 0x01 }));
    var into: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 3), part.takeEcho(&into));
    try std.testing.expectEqual(@as(u8, 0xAA), into[1]);
    try std.testing.expect(!part.echo_ready);
}

test "a bus reset drops the device back to Default" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    part.busReset();
    try std.testing.expectEqual(device.State.default, part.state);
    try std.testing.expectEqual(@as(u8, 0), part.address);
    try std.testing.expectEqual(@as(u8, 0), part.configuration);
}

test "a bus reset takes the endpoint's packet with it" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    try std.testing.expect(part.bulkOut(&[_]u8{ 0xEF, 0xBE }));
    try std.testing.expect(part.echo_ready);
    part.busReset();
    try std.testing.expect(!part.echo_ready);
    try std.testing.expectEqual(@as(u16, 0), part.echo_len);
}

test "a device in Default cannot be made to answer from the endpoint" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    _ = part.bulkOut(&[_]u8{ 0x55, 0xAA });
    part.busReset();
    var into: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 0), part.takeEcho(&into));
}

test "the endpoint works again once the device is configured anew" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    _ = part.bulkOut(&[_]u8{ 0x55, 0xAA });
    part.busReset();
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    try std.testing.expect(part.bulkOut(&[_]u8{ 0x0D, 0xF0, 0x01 }));
    var into: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 3), part.takeEcho(&into));
    try std.testing.expectEqual(@as(u8, 0x0D), into[0]);
}

test "a bus reset does not count as a refusal" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 7));
    _ = part.handle(set(setup.request.set_configuration, 1));
    _ = part.bulkOut(&[_]u8{ 0x55, 0xAA });
    const before = part.refusals();
    part.busReset();
    try std.testing.expectEqual(before, part.refusals());
}

test "GET_CONFIGURATION reports what the device took" {
    var part = device.Device{};
    _ = part.handle(set(setup.request.set_address, 3));
    _ = part.handle(set(setup.request.set_configuration, 1));
    try std.testing.expect(part.handle(get(setup.request.get_configuration, 0, 1)));
    var into: [4]u8 = undefined;
    try std.testing.expectEqual(@as(u16, 1), part.takeReply(&into));
    try std.testing.expectEqual(@as(u8, 1), into[0]);
}
