//! Covers src/session/board/recorded_c6.zig: the host frames a C6 bridge put
//! on the guest's queue are recorded once and land again at the very same
//! calls on any number of replays, with the host network closed and no
//! socket created; a recorded frame the replay never reaches is a
//! determinism error on the session.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../fork_fixture.zig");

const hosted = ra8.components.esp_hosted;
const eth = hosted.eth;
const frame = hosted.frame;
const host_net = hosted.host_net;
const Bridge = hosted.net.Bridge;
const Queue = hosted.queue.Queue;
const recorded = ra8.session.board.recorded_c6;
const feeder = ra8.session.history_replay_feeder;
const api = ra8.session.api;
const gpa = std.testing.allocator;

/// The host network stand-in: counts every call into it.
const Host = struct {
    var opens: u32 = 0;
    var sends: u32 = 0;
    var recvs: u32 = 0;
    /// Set when the "server" has bytes for the guest.
    var answer_ready: bool = false;
    var answered: bool = false;

    fn reset() void {
        opens = 0;
        sends = 0;
        recvs = 0;
        answer_ready = false;
        answered = false;
    }
    fn open(_: host_net.Kind) anyerror!host_net.Handle {
        opens += 1;
        return @fromBackingInt(@intCast(7));
    }
    fn connect(_: host_net.Handle, _: host_net.Address) anyerror!host_net.Connect {
        return .done;
    }
    fn writable(_: host_net.Handle) anyerror!bool {
        return true;
    }
    fn finished(_: host_net.Handle) anyerror!void {}
    fn send(_: host_net.Handle, bytes: []const u8) anyerror!usize {
        sends += 1;
        return bytes.len;
    }
    fn recv(_: host_net.Handle, out: []u8, _: host_net.Receive) anyerror!usize {
        recvs += 1;
        if (!answer_ready or answered) return error.WouldBlock;
        answered = true;
        @memcpy(out[0..5], "hello");
        return 5;
    }
    fn shutdownSend(_: host_net.Handle) anyerror!void {}
    fn close(_: host_net.Handle) void {}
    const net: host_net.Net = .{
        .open = open,
        .connect = connect,
        .writable = writable,
        .finished = finished,
        .send = send,
        .recv = recv,
        .shutdownSend = shutdownSend,
        .close = close,
    };
};

const guest_route = eth.Route{
    .src_mac = hosted.station.mac,
    .dst_mac = hosted.station.bssid,
    .src_ip = hosted.dhcp.lease_ip,
    .dst_ip = hosted.dhcp.server_ip,
    .src_port = 40000,
    .dst_port = 8080,
};

/// One frame the guest popped off the queue, and the round it popped it.
const Seen = struct { r: u64, bytes: []u8 };

const Run = struct {
    bridge: Bridge = .{},
    queue: Queue = .{},
    seen: std.ArrayList(Seen) = .empty,

    fn deinit(self: *Run) void {
        for (self.seen.items) |item| gpa.free(item.bytes);
        self.seen.deinit(gpa);
    }

    fn forward(self: *Run, seq: u32, ack: u32, flags: u8, payload: []const u8) void {
        var bytes: [frame.max_payload]u8 = undefined;
        const len = eth.tcpFrame(&bytes, guest_route, seq, ack, flags, 1460, payload).?;
        _ = self.bridge.forward(&self.queue, bytes[0..len]);
    }

    fn drain(self: *Run, r: u64) !void {
        var hosted_frame: [frame.frame_size]u8 = undefined;
        while (self.queue.pop(&hosted_frame)) {
            const parsed = try frame.parse(&hosted_frame);
            try self.seen.append(gpa, .{ .r = r, .bytes = try gpa.dupe(u8, parsed.payload) });
        }
    }

    /// The guest's side of one short fetch, over rounds 1 to 7. Round 3
    /// forwards two frames before the board polls, so two calls of one site
    /// land at one position.
    fn go(self: *Run, h: *fixture.MockHarness) !void {
        for (1..8) |n| {
            h.grid_state.at.r = @intCast(n);
            switch (n) {
                1 => self.forward(100, 0, eth.TcpFlag.syn, &.{}),
                2 => self.forward(101, 0xC6000001, eth.TcpFlag.ack, &.{}),
                3 => {
                    self.forward(101, 0xC6000001, eth.TcpFlag.psh | eth.TcpFlag.ack, "ping");
                    self.forward(101, 0xC6000001, eth.TcpFlag.ack, &.{});
                },
                5 => Host.answer_ready = true,
                else => {},
            }
            self.bridge.poll(&self.queue);
            try self.drain(h.grid_state.at.r);
        }
    }
};

fn heldFn(context: *anyopaque) bool {
    const session: *api.Session = @ptrCast(@alignCast(context));
    return session.outputMuted();
}

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
        self.h.deinit();
        gpa.destroy(self);
    }
};

fn wire(run: *Run, s: *Setup, net: ?host_net.Net) !void {
    run.bridge.net = net;
    run.bridge.hold = .{ .context = &s.h.session, .heldFn = heldFn };
    try recorded.attach(gpa, &s.h.session, &run.bridge);
}

fn expectSame(want: *const Run, got: *const Run) !void {
    try std.testing.expectEqual(want.seen.items.len, got.seen.items.len);
    for (want.seen.items, got.seen.items) |w, g| {
        try std.testing.expectEqual(w.r, g.r);
        try std.testing.expectEqualSlices(u8, w.bytes, g.bytes);
    }
}

test "frames are recorded once and land at the same calls on every replay with no host socket" {
    const s = try Setup.open();
    defer s.close();
    Host.reset();
    var live: Run = .{};
    defer live.deinit();
    try wire(&live, s, Host.net);
    try live.go(s.h);
    try std.testing.expectEqual(@as(u32, 1), Host.opens);
    try std.testing.expect(live.seen.items.len >= 4);
    try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&live.bridge).?.failed);
    recorded.release(&live.bridge);
    try s.h.recorder.commit(1);
    const log = s.h.mock_storage.bytes.items;
    const recorded_len = log.len;

    for (0..2) |_| {
        Host.reset();
        s.h.grid_state.at.r = 0;
        try feeder.loadSessionInterventions(&s.h.session, log, .at);
        defer feeder.release(&s.h.session);
        var again: Run = .{};
        defer again.deinit();
        // The host network is up but the replay must never reach it.
        try wire(&again, s, Host.net);
        s.h.session.setReplaying(true);
        defer s.h.session.setReplaying(false);
        try again.go(s.h);
        try std.testing.expectEqual(@as(u32, 0), Host.opens);
        try std.testing.expectEqual(@as(u32, 0), Host.sends);
        try std.testing.expectEqual(@as(u32, 0), Host.recvs);
        const port = recorded.from(&again.bridge).?;
        try std.testing.expectEqual(@as(?anyerror, null), port.failed);
        try std.testing.expectEqual(@as(u64, live.seen.items.len), port.replayed);
        try expectSame(&live, &again);
        recorded.release(&again.bridge);
    }
    // Replaying recorded nothing new.
    try s.h.recorder.commit(2);
    try std.testing.expectEqual(recorded_len, s.h.mock_storage.bytes.items.len);
}

test "with the host network closed a replay still lands the frames and creates no socket" {
    const s = try Setup.open();
    defer s.close();
    Host.reset();
    var live: Run = .{};
    defer live.deinit();
    try wire(&live, s, Host.net);
    try live.go(s.h);
    recorded.release(&live.bridge);
    try s.h.recorder.commit(1);

    Host.reset();
    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, s.h.mock_storage.bytes.items, .at);
    defer feeder.release(&s.h.session);
    var closed: Run = .{};
    defer closed.deinit();
    try wire(&closed, s, null);
    defer recorded.release(&closed.bridge);
    s.h.session.setReplaying(true);
    defer s.h.session.setReplaying(false);
    try closed.go(s.h);
    try std.testing.expectEqual(@as(u32, 0), Host.opens);
    try expectSame(&live, &closed);
    try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&closed.bridge).?.failed);
    try std.testing.expect(s.h.session.replay_failure == null);
}

test "a recorded frame the replay never reaches is a determinism error on the session" {
    const s = try Setup.open();
    defer s.close();
    Host.reset();
    var live: Run = .{};
    defer live.deinit();
    try wire(&live, s, Host.net);
    try live.go(s.h);
    recorded.release(&live.bridge);
    try s.h.recorder.commit(1);

    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, s.h.mock_storage.bytes.items, .at);
    defer feeder.release(&s.h.session);
    var skipping: Run = .{};
    defer skipping.deinit();
    try wire(&skipping, s, null);
    defer recorded.release(&skipping.bridge);
    s.h.session.setReplaying(true);
    defer s.h.session.setReplaying(false);
    // The replay's guest forwards nothing at round 1, so the recorded
    // SYN-ACK is due at a position the replay passes without landing it.
    for (1..4) |n| {
        s.h.grid_state.at.r = @intCast(n);
        skipping.bridge.poll(&skipping.queue);
    }
    try std.testing.expectEqual(@as(?anyerror, recorded.Error.MissedLanding), recorded.from(&skipping.bridge).?.failed);
    const failure = s.h.session.replay_failure.?;
    try std.testing.expectEqual(ra8.session.stop_machine.ReplaySource.c6, failure.source);
    try std.testing.expectEqual(@as(anyerror, recorded.Error.MissedLanding), failure.err);
}
