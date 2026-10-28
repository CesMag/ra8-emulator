//! Covers src/session/board/recorded_usbip.zig: the USB/IP traffic a bridge
//! served is recorded once and replays the same device state any number of
//! times with the bridge never polled, a replay with nothing to read is a
//! determinism error rather than a live read, and traffic that arrives
//! while the cursor is in the past waits in the async queue.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../fork_fixture.zig");

const usbfs = ra8.chip.periph.usbfs;
const pipe = usbfs.pipe;
const regs = ra8.chip.periph.usbhs.regs;
const usb = ra8.board.usb;
const traffic = usb.traffic;
const wire = ra8.usbip.wire;
const exp = ra8.usbip.exported;
const recorded = ra8.session.board.recorded_usbip;
const feeder = ra8.session.history_replay_feeder;
const async_traffic = ra8.session.history_async_traffic;
const async_queue = ra8.session.history_async_queue;
const gpa = std.testing.allocator;

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

/// A CMD_SUBMIT OUT on endpoint 2 with `data`, or a CMD_UNLINK of `victim`.
fn command(out: []u8, seqnum: u32, data: []const u8, victim: ?u32) []const u8 {
    @memset(out[0..wire.basic_len], 0);
    put(out, 0, if (victim == null) wire.cmd.submit else wire.cmd.unlink);
    put(out, 4, seqnum);
    if (victim) |v| {
        put(out, 20, v);
        return out[0..wire.basic_len];
    }
    put(out, 16, 2);
    put(out, 24, @intCast(data.len));
    @memcpy(out[wire.basic_len..][0..data.len], data);
    return out[0 .. wire.basic_len + data.len];
}

/// What the firmware sees of the device after the host's traffic.
fn digest(device: *usbfs.Device) u64 {
    var hash = std.hash.Wyhash.init(0);
    for ([_]u32{ regs.reg.intsts0, regs.reg.brdysts, regs.reg.bempsts }) |reg| {
        const value = device.read(at(reg), 2);
        hash.update(std.mem.asBytes(&value));
    }
    hash.update(std.mem.asBytes(&device.endpoints.overrun));
    hash.update(std.mem.asBytes(&device.endpoints.out[0].ready));
    var packet: [64]u8 = undefined;
    const got = device.endpoints.out[0].drain(&packet);
    hash.update(std.mem.asBytes(&got));
    hash.update(packet[0..got]);
    return hash.final();
}

/// The bridge's stand-in: scripted host commands taken through the same
/// session code a socket would feed, with the sink told as the bridge tells it.
const Host = struct {
    polls: u32 = 0,
    sink: ?traffic.Sink = null,
    urbs: exp.session.Session = .{},
    connected: bool = false,
    replayer: exp.replay.Replayer = .{},
    raw: [wire.basic_len + 64]u8 = undefined,

    fn say(self: *Host, event: traffic.Event) void {
        if (self.sink) |s| s.noteFn(s.context, event);
    }

    fn take(self: *Host, bytes: []const u8) void {
        var reader: std.Io.Reader = .fixed(bytes);
        var muted: std.Io.Writer.Discarding = .init(&.{});
        _ = self.urbs.receive(&reader, &muted.writer) catch unreachable;
    }

    fn poll(context: *anyopaque, device: *usbfs.Device, _: *const usbfs.host.Host) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.polls += 1;
        self.step(device);
    }

    /// What the host does at the `n`th poll.
    fn step(self: *Host, device: *usbfs.Device) void {
        const n = self.polls;
        if (n == 2) {
            self.say(.{ .kind = .import, .head = "1-1" });
            self.connected = true;
            self.urbs = .{ .sink = self.sink };
            return;
        }
        if (!self.connected) return;
        switch (n) {
            4 => self.take(command(&self.raw, 1, "hello", null)),
            6 => self.take(command(&self.raw, 2, "abcdefgh", null)),
            9 => self.take(command(&self.raw, 3, "", 2)),
            11 => {
                self.say(.{ .kind = .disconnect });
                self.connected = false;
                self.urbs = .{ .sink = self.sink };
                return;
            },
            else => {},
        }
        var muted: std.Io.Writer.Discarding = .init(&.{});
        const held = if (self.sink) |s| s.holdFn(s.context) else false;
        if (!held) _ = self.urbs.pump(device, &muted.writer) catch {};
    }

    fn tap(context: *anyopaque, sink: ?traffic.Sink) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.sink = sink;
        self.urbs.sink = sink;
    }

    fn feed(context: *anyopaque, device: *usbfs.Device, event: traffic.Event) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(context));
        try self.replayer.feed(device, event);
    }

    fn settle(context: *anyopaque, device: *usbfs.Device) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.replayer.settle(device);
    }

    fn drop(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.connected = false;
        self.urbs = .{ .sink = self.sink };
    }

    fn install(self: *Host, target: *usb.Usb) void {
        target.bridge = .{ .context = self, .pollFn = poll, .port = .{ .tapFn = tap, .feedFn = feed, .pumpFn = settle, .dropFn = drop } };
    }
};

const Run = struct {
    device: usbfs.Device = .{},
    target: usb.Usb = .{},
    script: usbfs.host.Host = .{},

    /// Polls the hook `count` times at rounds 1..count; the firmware takes
    /// the first packet after the 7th.
    fn go(self: *Run, h: *fixture.MockHarness, count: u32) u64 {
        openOut(&self.device);
        for (1..count + 1) |n| {
            h.grid_state.at.r = @intCast(n);
            const hook = self.target.bridge.?;
            hook.pollFn(hook.context, &self.device, &self.script);
            if (n == 7) {
                var packet: [64]u8 = undefined;
                _ = self.device.endpoints.out[0].drain(&packet);
                self.device.endpoints.brdy = 0;
            }
        }
        return digest(&self.device);
    }
};

const Setup = struct {
    h: *fixture.MockHarness,
    history: ra8.session.history.History,

    fn open() !*Setup {
        const self = try gpa.create(Setup);
        self.h = try fixture.MockHarness.init(gpa);
        self.history = try ra8.session.history.History.init(gpa, undefined, 4);
        self.history.attachRecorder(&self.h.recorder);
        self.h.session.history = &self.history;
        self.h.recorder.observe(0);
        return self;
    }

    fn close(self: *Setup) void {
        self.history.deinit();
        if (self.h.session.async_traffic.queue) |*q| q.deinit();
        self.h.deinit();
        gpa.destroy(self);
    }
};

test "traffic is recorded once and replays the same device state twice without polling the bridge" {
    const s = try Setup.open();
    defer s.close();
    var live_host: Host = .{};
    var live: Run = .{};
    live_host.install(&live.target);
    try recorded.attach(gpa, &s.h.session, &live.target);
    const want = live.go(s.h, 14);
    var idle: usbfs.Device = .{};
    openOut(&idle);
    try std.testing.expect(digest(&idle) != want);
    try std.testing.expectEqual(@as(u32, 14), live_host.polls);
    const port = recorded.from(&live.target).?;
    try std.testing.expectEqual(@as(?anyerror, null), port.failed);
    recorded.release(&live.target, &s.h.session);
    try s.h.recorder.commit(1);
    const log = s.h.mock_storage.bytes.items;
    const recorded_len = log.len;

    for (0..2) |_| {
        s.h.grid_state.at.r = 0;
        try feeder.loadSessionInterventions(&s.h.session, log, .at);
        defer feeder.release(&s.h.session);
        var tripwire: Host = .{};
        var again: Run = .{};
        tripwire.install(&again.target);
        try recorded.attach(gpa, &s.h.session, &again.target);
        s.h.session.setReplaying(true);
        defer s.h.session.setReplaying(false);
        try std.testing.expectEqual(want, again.go(s.h, 14));
        try std.testing.expectEqual(@as(u32, 0), tripwire.polls);
        const replay = recorded.from(&again.target).?;
        try std.testing.expectEqual(@as(?anyerror, null), replay.failed);
        // import, two submits, the unlink and the disconnect.
        try std.testing.expectEqual(@as(u64, 5), replay.replayed);
        recorded.release(&again.target, &s.h.session);
    }
    // Replaying recorded nothing new.
    try s.h.recorder.commit(2);
    try std.testing.expectEqual(recorded_len, s.h.mock_storage.bytes.items.len);
}

test "a replay with no recording to read is an error, never a live read" {
    const s = try Setup.open();
    defer s.close();
    var tripwire: Host = .{};
    var run: Run = .{};
    tripwire.install(&run.target);
    try recorded.attach(gpa, &s.h.session, &run.target);
    defer recorded.release(&run.target, &s.h.session);
    s.h.session.setReplaying(true);
    defer s.h.session.setReplaying(false);
    _ = run.go(s.h, 3);
    try std.testing.expectEqual(@as(?anyerror, recorded.Error.UnrecordedTraffic), recorded.from(&run.target).?.failed);
    try std.testing.expectEqual(@as(u32, 0), tripwire.polls);
}

test "traffic that arrives in the past waits in the queue and lands at the recorded end without a fork" {
    const s = try Setup.open();
    defer s.close();
    s.h.session.attachAsyncQueue(async_queue.AsyncQueue.init(gpa, 1024 * 1024));
    var end = s.h.graph.get(0).?.recorded_end;
    end.r = 100;
    try s.h.graph.insertNode(.{ .id = 0, .parent = 0, .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired }, .reason = .base, .recorded_end = end });
    var host: Host = .{};
    var run: Run = .{};
    host.install(&run.target);
    try recorded.attach(gpa, &s.h.session, &run.target);
    defer recorded.release(&run.target, &s.h.session);
    const port = recorded.from(&run.target).?;

    s.h.grid_state.at.r = 20;
    try std.testing.expect(async_traffic.isCursorInPast(&s.h.session));
    host.say(.{ .kind = .import, .head = "1-1" });
    try std.testing.expectEqual(@as(usize, 1), port.held);
    try std.testing.expectEqual(@as(usize, 1), s.h.session.async_traffic.queue.?.count());
    try s.h.recorder.commit(1);
    const before = s.h.mock_storage.bytes.items.len;

    s.h.grid_state.at.r = 100;
    try std.testing.expectEqual(@as(usize, 1), try async_traffic.drainIfNeeded(&s.h.session));
    try std.testing.expectEqual(@as(usize, 0), port.held);
    try s.h.recorder.commit(2);
    try std.testing.expect(s.h.mock_storage.bytes.items.len > before);
    try std.testing.expectEqual(@as(u32, 0), s.h.router.active_line);
}
