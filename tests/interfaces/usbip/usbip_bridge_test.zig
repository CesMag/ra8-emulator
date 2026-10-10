//! Covers src/interfaces/usbip/usbip_bridge.zig: the bridge waits for
//! enumeration, binds, takes an import and serves URBs without blocking.
const std = @import("std");
const ra8 = @import("ra8");
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

const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs_regs;
const bridge = exp.bridge;

fn enumerated() usbfs.host.Host {
    var script = usbfs.host.Host{};
    script.device = device;
    @memcpy(script.config[0..config.len], &config);
    script.config_len = config.len;
    script.step = .configured;
    return script;
}

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn openIn(board: *usbfs.Device) void {
    board.write(at(regs.reg.pipesel), 2, 2);
    board.write(at(regs.reg.pipecfg), 2, (1 << pipe.cfg.kind_shift) | pipe.cfg.dir_in | 1);
    board.write(at(regs.reg.pipemaxp), 2, 64);
    board.write(at(regs.reg.pipesel), 2, 0);
}

const Seen = struct { done: std.atomic.Value(bool) = .init(false), actual: u32 = 0, data: [2]u8 = undefined };

/// A host that imports 1-1, submits one bulk IN URB on ep1 and reads its reply.
fn host(port: u16, seen: *Seen) void {
    defer seen.done.store(true, .release);
    const io = std.testing.io;
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const stream = address.connect(io, .{ .mode = .stream }) catch return;
    defer stream.close(io);
    var out = stream.writer(io, &.{});
    var in_buffer: [256]u8 = undefined;
    var in = stream.reader(io, &in_buffer);
    var header: [wire.op_header_len]u8 = undefined;
    (wire.OpHeader{ .code = wire.op.req_import }).encode(&header);
    var busid = @as([wire.busid_len]u8, @splat(0));
    @memcpy(busid[0..3], "1-1");
    out.interface.writeAll(&header) catch return;
    out.interface.writeAll(&busid) catch return;
    var reply: [wire.op_header_len + wire.device_len]u8 = undefined;
    in.interface.readSliceAll(&reply) catch return;
    var submit = @as([wire.basic_len]u8, @splat(0));
    std.mem.writeInt(u32, submit[0..4], wire.cmd.submit, .big);
    std.mem.writeInt(u32, submit[4..8], 1, .big);
    std.mem.writeInt(u32, submit[12..16], 1, .big);
    std.mem.writeInt(u32, submit[16..20], 1, .big);
    std.mem.writeInt(u32, submit[24..28], 64, .big);
    out.interface.writeAll(&submit) catch return;
    var ret: [wire.basic_len]u8 = undefined;
    in.interface.readSliceAll(&ret) catch return;
    seen.actual = std.mem.readInt(u32, ret[24..28], .big);
    in.interface.readSliceAll(seen.data[0..@min(seen.actual, 2)]) catch return;
}

test "nothing is bound while the device has not enumerated" {
    var link = try bridge.Bridge.init(std.testing.allocator, std.testing.io, 0);
    defer link.deinit(std.testing.allocator);
    var board = usbfs.Device{};
    const script = usbfs.host.Host{};
    try std.testing.expectEqual(bridge.Event.none, try link.poll(&board, &script));
    try std.testing.expectEqual(@as(?u16, null), link.port());
}

test "a host imports, submits an IN URB and gets the firmware's packet" {
    var link = try bridge.Bridge.init(std.testing.allocator, std.testing.io, 0);
    defer link.deinit(std.testing.allocator);
    var board = usbfs.Device{};
    openIn(&board);
    const script = enumerated();
    try std.testing.expectEqual(bridge.Event.listening, try link.poll(&board, &script));
    try std.testing.expectEqual(@as(u16, 0x5310), link.exported().?.device.product);
    var seen = Seen{};
    const thread = try std.Thread.spawn(.{}, host, .{ link.port().?, &seen });
    var attached = false;
    var polls: usize = 0;
    while (!seen.done.load(.acquire) and polls < 50_000_000) : (polls += 1) {
        const event = try link.poll(&board, &script);
        if (event == .attached) {
            attached = true;
            board.write(at(regs.reg.cfifosel), 2, 2);
            board.write(at(regs.reg.cfifo), 2, 0x6968);
            board.write(at(regs.reg.cfifoctr), 2, regs.fifo.bval);
        }
        if (event == .none) std.Thread.yield() catch {};
    }
    thread.join();
    try std.testing.expect(attached);
    try std.testing.expectEqual(@as(u32, 2), seen.actual);
    try std.testing.expectEqualSlices(u8, "hi", &seen.data);
}
