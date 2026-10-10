//! Covers src/interfaces/usbip/usbip_listen.zig: a loopback host that lists
//! on one connection and imports on the next gets the export back.
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
const lis = exp.listen;

/// One CDC export listed: header, count, record, two interfaces.
const devlist_len = wire.op_header_len + 4 + wire.device_len + 2 * wire.interface_len;

/// One request header, then `busid` padded to 32 bytes when importing.
fn send(stream: std.Io.net.Stream, code: u16, busid: ?[]const u8) !void {
    var out = stream.writer(std.testing.io, &.{});
    var header: [wire.op_header_len]u8 = undefined;
    (wire.OpHeader{ .code = code }).encode(&header);
    try out.interface.writeAll(&header);
    const name = busid orelse return;
    var body = @as([wire.busid_len]u8, @splat(0));
    @memcpy(body[0..name.len], name);
    try out.interface.writeAll(&body);
}

/// What the scripted host saw.
const Host = struct {
    port: u16,
    listed_len: usize = 0,
    import_status: ?u32 = null,
    failed: bool = false,

    fn run(self: *Host) void {
        self.script() catch {
            self.failed = true;
        };
    }

    fn script(self: *Host) !void {
        const io = std.testing.io;
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port);
        const first = try address.connect(io, .{ .mode = .stream });
        try send(first, wire.op.req_devlist, null);
        var reply: [devlist_len]u8 = undefined;
        var first_in = first.reader(io, &.{});
        try first_in.interface.readSliceAll(&reply);
        self.listed_len = reply.len;
        first.close(io);
        const second = try address.connect(io, .{ .mode = .stream });
        defer second.close(io);
        try send(second, wire.op.req_import, "1-1");
        var header: [wire.op_header_len]u8 = undefined;
        var second_in = second.reader(io, &.{});
        try second_in.interface.readSliceAll(&header);
        self.import_status = (try wire.OpHeader.decode(&header)).status;
    }
};

test "a host lists, reconnects and imports the export" {
    const items = [_]exp.Export{try exp.fromDescriptors(place, &device, &config)};
    var listener = try lis.open(std.testing.io, 0);
    defer listener.deinit(std.testing.io);
    var host = Host{ .port = lis.port(&listener) };
    const thread = try std.Thread.spawn(.{}, Host.run, .{&host});
    const attached = try lis.attach(std.testing.io, &listener, &items);
    thread.join();
    attached.stream.close(std.testing.io);
    try std.testing.expect(!host.failed);
    try std.testing.expectEqual(&items[0], attached.item);
    try std.testing.expectEqual(devlist_len, host.listed_len);
    try std.testing.expectEqual(@as(?u32, 0), host.import_status);
}

test "a bound listener reports a real port and the usbip default is 3240" {
    var listener = try lis.open(std.testing.io, 0);
    defer listener.deinit(std.testing.io);
    try std.testing.expect(lis.port(&listener) != 0);
    try std.testing.expectEqual(@as(u16, 3240), lis.default_port);
}
