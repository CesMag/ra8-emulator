//! Covers src/interfaces/usbip/usbip_export.zig: the export built from a
//! CDC ACM device's own descriptors, and the DEVLIST and IMPORT replies.
const std = @import("std");
const cli_app = @import("cli_app");
const wire = cli_app.cli.usbip_wire;
const exp = cli_app.cli.usbip_export;

/// A CDC ACM device: class 0xEF/2/1 (IAD), VID 0x045B PID 0x5310, bcd 1.00.
const device = [_]u8{ 18, 1, 0x00, 0x02, 0xEF, 0x02, 0x01, 64, 0x5B, 0x04, 0x10, 0x53, 0x00, 0x01, 1, 2, 3, 1 };

/// Configuration 1: an IAD, a CDC communication interface with one
/// functional descriptor and an interrupt endpoint, a data interface with
/// two bulk endpoints, and an alternate setting that must not be listed.
const config = [_]u8{
    9,  2,  75,   0,    2,    1, 0,    0x80, 50,
    8,  11, 0,    2,    2,    2, 1,    0,    9,
    4,  0,  0,    1,    2,    2, 1,    0,    5,
    36, 0,  0x10, 0x01, 7,    5, 0x83, 3,    16,
    0,  16, 9,    4,    1,    0, 2,    0x0A, 0,
    0,  0,  7,    5,    0x81, 2, 0,    2,    0,
    7,  5,  0x01, 2,    0,    2, 0,    9,    4,
    1,  1,  0,    0x0A, 0,    0, 0,
};

const place = exp.Place{ .path = "/sys/devices/ra8/usbhs", .busid = "1-1", .speed = .high };

test "the export takes its ids and class from the device descriptor" {
    const item = try exp.fromDescriptors(place, &device, &config);
    try std.testing.expectEqual(@as(u16, 0x045B), item.device.vendor);
    try std.testing.expectEqual(@as(u16, 0x5310), item.device.product);
    try std.testing.expectEqual(@as(u16, 0x0100), item.device.bcd_device);
    try std.testing.expectEqual(@as(u8, 0xEF), item.device.class);
    try std.testing.expectEqual(@as(u8, 2), item.device.subclass);
    try std.testing.expectEqual(@as(u8, 1), item.device.protocol);
    try std.testing.expectEqual(@as(u8, 1), item.device.configurations);
    try std.testing.expectEqual(@as(u8, 1), item.device.configuration_value);
    try std.testing.expectEqual(@as(u8, 2), item.device.interfaces);
    try std.testing.expectEqual(wire.Speed.high, item.device.speed);
}

test "each interface's first alternate setting is listed in order" {
    const item = try exp.fromDescriptors(place, &device, &config);
    const list = item.list();
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(@as(u8, 2), list[0].class);
    try std.testing.expectEqual(@as(u8, 2), list[0].subclass);
    try std.testing.expectEqual(@as(u8, 1), list[0].protocol);
    try std.testing.expectEqual(@as(u8, 0x0A), list[1].class);
}

test "a short or mistyped descriptor is refused" {
    try std.testing.expectError(error.BadDescriptor, exp.fromDescriptors(place, device[0..8], &config));
    try std.testing.expectError(error.BadDescriptor, exp.fromDescriptors(place, &device, device[0..9]));
    var broken = config;
    broken[9] = 0;
    try std.testing.expectError(error.BadDescriptor, exp.fromDescriptors(place, &device, &broken));
}

test "the device list carries the count, the record and its interfaces" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var buf: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try exp.writeDevlist(&stream, &items);
    const out = stream.buffered();
    try std.testing.expectEqual(wire.op_header_len + 4 + wire.device_len + 2 * wire.interface_len, out.len);
    const header = try wire.OpHeader.decode(out);
    try std.testing.expectEqual(wire.op.rep_devlist, header.code);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[8..12], .big));
    try std.testing.expectEqualStrings("1-1", out[12 + 256 .. 12 + 259]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 1, 0, 0x0A, 0, 0, 0 }, out[12 + wire.device_len ..]);
}

test "an empty device list is the header and a zero count" {
    var buf: [16]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try exp.writeDevlist(&stream, &.{});
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x11, 0x00, 0x05, 0, 0, 0, 0, 0, 0, 0, 0 }, stream.buffered());
}

test "an import of an exported busid answers status 0 and the record" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var body = @as([wire.busid_len]u8, @splat(0));
    @memcpy(body[0..3], "1-1");
    const found = try exp.find(&items, &body);
    try std.testing.expect(found != null);
    var buf: [wire.op_header_len + wire.device_len]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try exp.writeImport(&stream, found);
    const header = try wire.OpHeader.decode(&buf);
    try std.testing.expectEqual(wire.op.rep_import, header.code);
    try std.testing.expectEqual(@as(u32, 0), header.status);
    try std.testing.expectEqual(buf.len, stream.buffered().len);
}

test "an import of an unknown busid answers status 1 with no record" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var body = @as([wire.busid_len]u8, @splat(0));
    @memcpy(body[0..3], "2-1");
    const found = try exp.find(&items, &body);
    try std.testing.expect(found == null);
    var buf: [64]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try exp.writeImport(&stream, found);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x11, 0x00, 0x03, 0, 0, 0, 1 }, stream.buffered());
}

test {
    _ = @import("usbip_server_test.zig");
    _ = @import("usbip_listen_test.zig");
    _ = @import("usbip_board_test.zig");
    _ = @import("usbip_run_test.zig");
    _ = @import("usbip_urb_test.zig");
    _ = @import("usbip_control_test.zig");
    _ = @import("usbip_session_test.zig");
    _ = @import("usbip_bridge_test.zig");
}
