//! `zig build usbip-attach -- PORT [VID:PID] [LEN] [--tty]` (RA8EMU-75):
//! attach the device `--usbip PORT` exports the way `usbip list` and
//! `usbip attach` do, then check it end to end. It reads the device
//! descriptor over ep0 and loops LEN bytes through bulk OUT 0x02 and bulk IN
//! 0x81, the echo pair usb_printer_vendor (1209:0001, the default) and
//! usb_selftest_cdc (1209:0017) both expose. `--tty` first sends what Linux
//! cdc-acm sends when a tty opens: SET_LINE_CODING 115200 8N1 and
//! SET_CONTROL_LINE_STATE with DTR and RTS. Exits 1 on the first step that
//! does not hold.
const std = @import("std");
const client = @import("usbip_client");
const attach = client.attach;

const max_len = 64;
/// Each direction's stream buffer, the size the emulator's listener uses.
const buffer_len = 256;

/// What the command line asks for.
const Want = struct {
    vendor: u16 = 0x1209,
    product: u16 = 0x0001,
    len: u16 = max_len,
    tty: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) return fail("usage: usbip_attach PORT [VID:PID] [LEN] [--tty]", .{});
    const text = argv[1];
    const port = std.fmt.parseInt(u16, text, 10) catch return fail("bad port {s}", .{text});
    var want = Want{};
    for (argv[2..]) |arg| try parse(&want, arg);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };

    var record: [312]u8 = undefined;
    const listed = try list(io, address, &record);
    std.debug.print("usbip_attach: listed {s} {x:0>4}:{x:0>4}\n", .{ listed.busid, listed.vendor, listed.product });
    if (listed.vendor != want.vendor or listed.product != want.product) return fail("not {x:0>4}:{x:0>4}", .{ want.vendor, want.product });

    var busid: [32]u8 = undefined;
    const name = busid[0..listed.busid.len];
    @memcpy(name, listed.busid);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var in: [buffer_len]u8 = undefined;
    var out: [buffer_len]u8 = undefined;
    var stream_reader = stream.reader(io, &in);
    var stream_writer = stream.writer(io, &out);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;
    const devid = (try attach.import(reader, writer, name, &record)).devid();
    std.debug.print("usbip_attach: imported {s}\n", .{name});
    try descriptor(reader, writer, devid, want);
    if (want.tty) try openTty(reader, writer, devid);
    try loopback(reader, writer, devid, want.len);
    std.debug.print("usbip_attach: passed\n", .{});
}

fn parse(want: *Want, arg: []const u8) !void {
    if (std.mem.eql(u8, arg, "--tty")) {
        want.tty = true;
    } else if (std.mem.indexOfScalar(u8, arg, ':')) |colon| {
        want.vendor = std.fmt.parseInt(u16, arg[0..colon], 16) catch return fail("bad VID:PID {s}", .{arg});
        want.product = std.fmt.parseInt(u16, arg[colon + 1 ..], 16) catch return fail("bad VID:PID {s}", .{arg});
    } else {
        want.len = std.fmt.parseInt(u16, arg, 10) catch return fail("bad argument {s}", .{arg});
        if (want.len == 0 or want.len > max_len) return fail("LEN must be 1..{d}", .{max_len});
    }
}

fn list(io: std.Io, address: std.Io.net.IpAddress, record: *[312]u8) !client.Listed {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var in: [buffer_len]u8 = undefined;
    var out: [buffer_len]u8 = undefined;
    var reader = stream.reader(io, &in);
    var writer = stream.writer(io, &out);
    return (try attach.first(&reader.interface, &writer.interface, record)) orelse fail("no exports", .{});
}

/// GET_DESCRIPTOR(device) on ep0: idVendor and idProduct must match the list.
fn descriptor(reader: anytype, writer: anytype, devid: u32, want: Want) !void {
    var in: [18]u8 = undefined;
    const urb = client.Urb{ .seqnum = 1, .devid = devid, .direction = .in, .ep = 0, .length = 18, .setup = client.getDescriptor(1, 0, 18) };
    const back = try attach.transfer(reader, writer, urb, &.{}, &in);
    if (back.status != 0 or back.actual != 18) return fail("device descriptor: status {d}, {d} bytes", .{ back.status, back.actual });
    const id_vendor = std.mem.readInt(u16, in[8..10], .little);
    const id_product = std.mem.readInt(u16, in[10..12], .little);
    std.debug.print("usbip_attach: device descriptor {x:0>4}:{x:0>4}\n", .{ id_vendor, id_product });
    if (id_vendor != want.vendor or id_product != want.product) return fail("descriptor does not match the list", .{});
}

/// What cdc-acm does on open: line coding 115200 8N1 to interface 0, then
/// DTR and RTS up. Both are class OUT requests on ep0.
fn openTty(reader: anytype, writer: anytype, devid: u32) !void {
    const coding = [7]u8{ 0x00, 0xC2, 0x01, 0x00, 0, 0, 8 };
    try control(reader, writer, devid, 4, .{ 0x21, 0x20, 0, 0, 0, 0, 7, 0 }, &coding);
    try control(reader, writer, devid, 5, .{ 0x21, 0x22, 3, 0, 0, 0, 0, 0 }, &.{});
    std.debug.print("usbip_attach: tty opened (115200 8N1, DTR and RTS)\n", .{});
}

fn control(reader: anytype, writer: anytype, devid: u32, seqnum: u32, setup: [8]u8, data: []const u8) !void {
    const urb = client.Urb{ .seqnum = seqnum, .devid = devid, .direction = .out, .ep = 0, .length = @intCast(data.len), .setup = setup };
    const back = try attach.transfer(reader, writer, urb, data, &.{});
    if (back.status != 0) return fail("class request {x:0>2}: status {d}", .{ setup[1], back.status });
}

/// Bulk OUT on ep 2, then bulk IN on ep 1: the firmware echoes the packet.
fn loopback(reader: anytype, writer: anytype, devid: u32, len: u16) !void {
    var buffer: [max_len]u8 = undefined;
    const out = buffer[0..len];
    for (out, 0..) |*byte, i| byte.* = @truncate(i * 7 + 3);
    const sent = try attach.transfer(reader, writer, .{ .seqnum = 2, .devid = devid, .direction = .out, .ep = 2, .length = len }, out, &.{});
    if (sent.status != 0 or sent.actual != len) return fail("bulk OUT: status {d}, {d} bytes", .{ sent.status, sent.actual });
    var in: [max_len]u8 = undefined;
    const back = try attach.transfer(reader, writer, .{ .seqnum = 3, .devid = devid, .direction = .in, .ep = 1, .length = max_len }, &.{}, &in);
    if (back.status != 0 or back.actual != len) return fail("bulk IN: status {d}, {d} bytes", .{ back.status, back.actual });
    if (!std.mem.eql(u8, out, in[0..len])) return fail("bulk IN does not echo bulk OUT", .{});
    std.debug.print("usbip_attach: loopback {d} bytes echoed\n", .{len});
}

fn fail(comptime format: []const u8, values: anytype) error{Failed} {
    std.debug.print("usbip_attach: " ++ format ++ "\n", values);
    std.process.exit(1);
}
