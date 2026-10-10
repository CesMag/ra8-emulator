//! Covers src/interfaces/usbip/wire.zig: the USB/IP records packed and
//! unpacked byte for byte, against the layout the Linux usbip tools expect.
const std = @import("std");
const cli_app = @import("cli_app");
const wire = cli_app.cli.usbip_wire;

test "an operation header is version, code and status, big-endian" {
    var out: [wire.op_header_len]u8 = undefined;
    (wire.OpHeader{ .code = wire.op.rep_import, .status = 1 }).encode(&out);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x11, 0x00, 0x03, 0, 0, 0, 1 }, &out);
    const back = try wire.OpHeader.decode(&out);
    try std.testing.expectEqual(wire.op.rep_import, back.code);
    try std.testing.expectEqual(@as(u32, 1), back.status);
}

test "a request from another protocol version or cut short is refused" {
    try std.testing.expectError(error.BadVersion, wire.OpHeader.decode(&.{ 0x01, 0x10, 0x80, 0x05, 0, 0, 0, 0 }));
    try std.testing.expectError(error.Short, wire.OpHeader.decode(&.{ 0x01, 0x11, 0x80 }));
}

test "a device record puts path, busid and the descriptor fields where usbip reads them" {
    var out: [wire.device_len]u8 = undefined;
    const device = wire.Device{
        .path = "/sys/devices/ra8/usbhs",
        .busid = "1-1",
        .busnum = 1,
        .devnum = 2,
        .speed = .high,
        .vendor = 0x045B,
        .product = 0x5310,
        .bcd_device = 0x0100,
        .class = 0xEF,
        .subclass = 2,
        .protocol = 1,
        .interfaces = 2,
    };
    try device.encode(&out);
    try std.testing.expectEqualStrings("/sys/devices/ra8/usbhs", out[0..22]);
    try std.testing.expectEqual(@as(u8, 0), out[22]);
    try std.testing.expectEqualStrings("1-1", out[256..259]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3 }, out[288..300]);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x5B, 0x53, 0x10, 0x01, 0x00 }, out[300..306]);
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 2, 1, 1, 1, 2 }, out[306..312]);
}

test "a busid or path that fills its whole field is refused, leaving no NUL" {
    var out: [wire.device_len]u8 = undefined;
    const long = &@as([wire.busid_len:0]u8, @splat('x'));
    const device = wire.Device{ .path = "", .busid = long, .busnum = 1, .devnum = 1, .speed = .full, .vendor = 0, .product = 0, .bcd_device = 0 };
    try std.testing.expectError(error.TooLong, device.encode(&out));
}

test "an interface entry is class, subclass, protocol and a pad byte" {
    var out: [wire.interface_len]u8 = undefined;
    (wire.Interface{ .class = 2, .subclass = 2, .protocol = 1 }).encode(&out);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 1, 0 }, &out);
}

test "an import request names its busid up to the first NUL" {
    var body = @as([wire.busid_len]u8, @splat(0));
    @memcpy(body[0..3], "1-1");
    try std.testing.expectEqualStrings("1-1", try wire.importBusid(&body));
    try std.testing.expectError(error.Short, wire.importBusid(body[0..8]));
}

fn submitBytes(direction: u32) [wire.basic_len]u8 {
    var bytes = @as([wire.basic_len]u8, @splat(0));
    const words = [_]u32{ wire.cmd.submit, 7, 0x0001_0002, direction, 0, 0x200, 18, 0, 0, 0 };
    for (words, 0..) |value, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], value, .big);
    bytes[40..48].* = .{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 };
    return bytes;
}

test "a control submit unpacks its seqnum, endpoint, length and setup packet" {
    const bytes = submitBytes(1);
    const urb = try wire.Submit.decode(&bytes);
    try std.testing.expectEqual(@as(u32, 7), urb.seqnum);
    try std.testing.expectEqual(@as(u32, 0x0001_0002), urb.devid);
    try std.testing.expectEqual(wire.Direction.in, urb.direction);
    try std.testing.expectEqual(@as(u32, 0), urb.ep);
    try std.testing.expectEqual(@as(u32, 18), urb.length);
    try std.testing.expectEqual(@as(u32, 0x200), urb.transfer_flags);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00 }, &urb.setup);
    try std.testing.expectEqual(@as(u32, 0), urb.outBytes());
}

test "an OUT submit carries its length of data after the header" {
    const bytes = submitBytes(0);
    const urb = try wire.Submit.decode(&bytes);
    try std.testing.expectEqual(@as(u32, 18), urb.outBytes());
}

test "a submit with a bad direction or the wrong command is refused" {
    try std.testing.expectError(error.BadDirection, wire.Submit.decode(&submitBytes(2)));
    var unlink = submitBytes(0);
    std.mem.writeInt(u32, unlink[0..4], wire.cmd.unlink, .big);
    try std.testing.expectError(error.BadCommand, wire.Submit.decode(&unlink));
    try std.testing.expectError(error.Short, wire.command(unlink[0..20]));
}

test "an unlink names the seqnum it cancels" {
    var bytes = submitBytes(0);
    std.mem.writeInt(u32, bytes[0..4], wire.cmd.unlink, .big);
    std.mem.writeInt(u32, bytes[20..24], 5, .big);
    const cancel = try wire.Unlink.decode(&bytes);
    try std.testing.expectEqual(@as(u32, 7), cancel.seqnum);
    try std.testing.expectEqual(@as(u32, 5), cancel.victim);
}

test "a submit reply zeroes devid, direction and ep and reports status and length" {
    var out: [wire.basic_len]u8 = undefined;
    wire.retSubmit(&out, 7, 0, 18);
    try std.testing.expectEqual(wire.cmd.ret_submit, try wire.command(&out));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqualSlices(u8, &(@as([12]u8, @splat(0))), out[8..20]);
    try std.testing.expectEqual(@as(u32, 18), std.mem.readInt(u32, out[24..28], .big));
    try std.testing.expectEqualSlices(u8, &(@as([20]u8, @splat(0))), out[28..48]);
}

test "an unlink reply carries a negative errno as status" {
    var out: [wire.basic_len]u8 = undefined;
    wire.retUnlink(&out, 9, -104);
    try std.testing.expectEqual(wire.cmd.ret_unlink, try wire.command(&out));
    try std.testing.expectEqual(@as(i32, -104), std.mem.readInt(i32, out[20..24], .big));
}

test {
    _ = @import("client_test.zig");
}
