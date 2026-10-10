//! Covers src/interfaces/usbip/server.zig: the operation phase that
//! lists exports and hands one to a host that imports it.
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
const srv = exp.server;

/// An operation request header: version, code, status 0.
fn request(out: *std.Io.Writer.Allocating, code: u16) !void {
    var header: [wire.op_header_len]u8 = undefined;
    (wire.OpHeader{ .code = code }).encode(&header);
    try out.writer.writeAll(&header);
}

/// An OP_REQ_IMPORT for `busid`, NUL padded to 32 bytes.
fn importFor(out: *std.Io.Writer.Allocating, busid: []const u8) !void {
    try request(out, wire.op.req_import);
    var body = @as([wire.busid_len]u8, @splat(0));
    @memcpy(body[0..busid.len], busid);
    try out.writer.writeAll(&body);
}

test "a device list request is answered with the list" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var in: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer in.deinit();
    try request(&in, wire.op.req_devlist);
    var stream: std.Io.Reader = .fixed(in.written());
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const served = try srv.answer(&stream, &out.writer, &items);
    try std.testing.expect(served.? == .listed);
    var want: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    try exp.writeDevlist(&want.writer, &items);
    try std.testing.expectEqualSlices(u8, want.written(), out.written());
}

test "serve lists, refuses an unknown busid, then returns the import" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var in: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer in.deinit();
    try request(&in, wire.op.req_devlist);
    try importFor(&in, "9-9");
    try importFor(&in, "1-1");
    var stream: std.Io.Reader = .fixed(in.written());
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const imported = try srv.serve(&stream, &out.writer, &items);
    try std.testing.expectEqual(&items[0], imported.?);
    const devlist_len = wire.op_header_len + 4 + wire.device_len + 2 * wire.interface_len;
    const refused = out.written()[devlist_len..][0..wire.op_header_len];
    const header = try wire.OpHeader.decode(refused);
    try std.testing.expectEqual(wire.op.rep_import, header.code);
    try std.testing.expectEqual(@as(u32, 1), header.status);
    const accepted = try wire.OpHeader.decode(out.written()[devlist_len + wire.op_header_len ..]);
    try std.testing.expectEqual(@as(u32, 0), accepted.status);
    try std.testing.expectEqual(devlist_len + 2 * wire.op_header_len + wire.device_len, out.written().len);
}

test "a host that hangs up after listing ends serve with null" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var in: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer in.deinit();
    try request(&in, wire.op.req_devlist);
    var stream: std.Io.Reader = .fixed(in.written());
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(@as(?*const exp.Export, null), try srv.serve(&stream, &out.writer, &items));
}

test "a cut header or an unknown operation is an error" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var cut: std.Io.Reader = .fixed(&[_]u8{ 0x01, 0x11, 0x80 });
    try std.testing.expectError(error.Short, srv.answer(&cut, &out.writer, &items));
    var in: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer in.deinit();
    try request(&in, 0x8009);
    var odd: std.Io.Reader = .fixed(in.written());
    try std.testing.expectError(error.BadCommand, srv.answer(&odd, &out.writer, &items));
}
