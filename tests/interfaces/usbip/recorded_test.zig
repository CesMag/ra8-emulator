//! Covers the recorded USB/IP port over a real bridge: a host on a loopback
//! socket imports the device and writes two OUT URBs, the traffic is
//! recorded, and a replay with the socket gone, the listener closed and the
//! bridge never polled leaves the device exactly as the live run did.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../../session/fork_fixture.zig");

const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs.regs;
const usb = ra8.board.usb;
const wire = ra8.usbip.wire;
const exp = ra8.usbip.exported;
const recorded = ra8.session.board.recorded_usbip;
const feeder = ra8.session.history_replay_feeder;
const gpa = std.testing.allocator;

/// A CDC ACM device: class 0xEF/2/1 (IAD), VID 0x045B PID 0x5310, bcd 1.00.
const device_descriptor = [_]u8{ 18, 1, 0x00, 0x02, 0xEF, 0x02, 0x01, 64, 0x5B, 0x04, 0x10, 0x53, 0x00, 0x01, 1, 2, 3, 1 };

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

fn enumerated() usbfs.host.Host {
    var script = usbfs.host.Host{};
    script.device = device_descriptor;
    @memcpy(script.config[0..config.len], &config);
    script.config_len = config.len;
    script.step = .configured;
    return script;
}

fn at(offset: u32) u32 {
    return usbfs.window.base + offset;
}

fn openOut(device: *usbfs.Device) void {
    device.write(at(regs.reg.pipesel), 2, 1);
    device.write(at(regs.reg.pipecfg), 2, (1 << pipe.cfg.kind_shift) | 2);
    device.write(at(regs.reg.pipemaxp), 2, 64);
    device.write(at(regs.reg.pipesel), 2, 0);
}

fn put(bytes: []u8, from: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[from..][0..4], value, .big);
}

const Seen = struct { done: std.atomic.Value(bool) = .init(false), ok: bool = false };

/// A host that imports 1-1, writes two OUT URBs on endpoint 2, reads both
/// replies and hangs up.
fn client(port: u16, seen: *Seen) void {
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
    for ([_][]const u8{ "hello", "world" }, 1..) |text, seqnum| {
        var submit = @as([wire.basic_len]u8, @splat(0));
        put(&submit, 0, wire.cmd.submit);
        put(&submit, 4, @intCast(seqnum));
        put(&submit, 16, 2);
        put(&submit, 24, @intCast(text.len));
        out.interface.writeAll(&submit) catch return;
        out.interface.writeAll(text) catch return;
        var ret: [wire.basic_len]u8 = undefined;
        in.interface.readSliceAll(&ret) catch return;
    }
    seen.ok = true;
}

/// What the firmware sees of the device after the host's traffic.
fn digest(device: *usbfs.Device) u64 {
    var hash = std.hash.Wyhash.init(0);
    for ([_]u32{ regs.reg.intsts0, regs.reg.brdysts, regs.reg.bempsts }) |reg| {
        const value = device.read(at(reg), 2);
        hash.update(std.mem.asBytes(&value));
    }
    hash.update(std.mem.asBytes(&device.endpoints.overrun));
    var packet: [64]u8 = undefined;
    const got = device.endpoints.out[0].drain(&packet);
    hash.update(packet[0..got]);
    return hash.final();
}

/// The firmware's side of the loop: after the poll at each round it takes a
/// waiting packet, noting the round so a replay takes it at the same one.
const Firmware = struct {
    taken: [8]u32 = undefined,
    count: usize = 0,
    seen: [8][]const u8 = undefined,
    bytes: [8][64]u8 = undefined,
    lens: [8]usize = undefined,

    fn after(self: *Firmware, device: *usbfs.Device, round: u32, replay: bool) void {
        if (replay) {
            if (self.count < self.lens.len and self.taken[self.count] == round) self.take(device, round);
            return;
        }
        if (device.endpoints.out[0].ready) self.take(device, round);
    }

    fn take(self: *Firmware, device: *usbfs.Device, round: u32) void {
        const n = device.endpoints.out[0].drain(&self.bytes[self.count]);
        self.lens[self.count] = n;
        self.taken[self.count] = round;
        self.count += 1;
        device.endpoints.brdy = 0;
    }
};

test "a loopback host's traffic is recorded live and replays with the socket gone" {
    const h = try fixture.MockHarness.init(gpa);
    defer h.deinit();
    var history = try ra8.session.history.History.init(gpa, undefined, 4);
    defer history.deinit();
    history.attachRecorder(&h.recorder);
    h.session.history = &history;
    h.recorder.observe(0);
    const script = enumerated();

    // Live: a bridge on an ephemeral loopback port, recorded.
    var target: usb.Usb = .{};
    try exp.run.install(&target, gpa, std.testing.io, 0);
    const live: *exp.run.Live = @ptrCast(@alignCast(target.bridge.?.context));
    defer {
        live.link.deinit(gpa);
        gpa.destroy(live);
    }
    try recorded.attach(gpa, &h.session, &target);
    var device: usbfs.Device = .{};
    openOut(&device);
    var firmware: Firmware = .{};
    var seen = Seen{};
    var thread: ?std.Thread = null;
    var round: u32 = 0;
    var extra: u32 = 0;
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 20_000;
    while (extra < 40 and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        round += 1;
        h.grid_state.at.r = round;
        const hook = target.bridge.?;
        hook.pollFn(hook.context, &device, &script);
        firmware.after(&device, round, false);
        if (thread == null) {
            if (live.link.port()) |port| thread = try std.Thread.spawn(.{}, client, .{ port, &seen });
        }
        if (seen.done.load(.acquire)) extra += 1 else std.Thread.yield() catch {};
    }
    if (!seen.done.load(.acquire)) {
        if (live.link.conn) |*conn| conn.stream.shutdown(std.testing.io, .both) catch {};
    }
    if (thread) |t| t.join();
    try std.testing.expect(seen.ok);
    try std.testing.expectEqual(@as(usize, 2), firmware.count);
    try std.testing.expectEqualSlices(u8, "hello", firmware.bytes[0][0..firmware.lens[0]]);
    try std.testing.expectEqualSlices(u8, "world", firmware.bytes[1][0..firmware.lens[1]]);
    const want = digest(&device);
    const port_gone = live.link.port().?;
    try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&target).?.failed);
    recorded.release(&target, &h.session);
    try h.recorder.commit(1);
    const log = h.mock_storage.bytes.items;

    // Replay: a fresh bridge that is never polled, and the old listener closed.
    if (live.link.listener) |*listener| listener.deinit(std.testing.io);
    live.link.listener = null;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port_gone);
    try std.testing.expectError(error.ConnectionRefused, address.connect(std.testing.io, .{ .mode = .stream }));

    var again: usb.Usb = .{};
    try exp.run.install(&again, gpa, std.testing.io, 0);
    const quiet: *exp.run.Live = @ptrCast(@alignCast(again.bridge.?.context));
    defer {
        quiet.link.deinit(gpa);
        gpa.destroy(quiet);
    }
    try recorded.attach(gpa, &h.session, &again);
    defer recorded.release(&again, &h.session);
    for (0..2) |_| {
        h.grid_state.at.r = 0;
        try feeder.loadSessionInterventions(&h.session, log, .at);
        defer feeder.release(&h.session);
        h.session.setReplaying(true);
        defer h.session.setReplaying(false);
        var replayed: usbfs.Device = .{};
        openOut(&replayed);
        var second: Firmware = .{};
        second.taken = firmware.taken;
        for (1..round + 1) |n| {
            h.grid_state.at.r = @intCast(n);
            const hook = again.bridge.?;
            hook.pollFn(hook.context, &replayed, &script);
            second.after(&replayed, @intCast(n), true);
        }
        try std.testing.expectEqual(@as(usize, 2), second.count);
        try std.testing.expectEqualSlices(u8, firmware.bytes[1][0..firmware.lens[1]], second.bytes[1][0..second.lens[1]]);
        try std.testing.expectEqual(want, digest(&replayed));
        try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&again).?.failed);
        try std.testing.expectEqual(@as(?u16, null), quiet.link.port());
    }
}
