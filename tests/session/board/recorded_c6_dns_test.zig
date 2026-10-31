//! DNS replies traverse the real worker, bridge and Session landing record.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../fork_fixture.zig");
const hosted = ra8.components.esp_hosted;
const recorded = ra8.session.board.recorded_c6;
const feeder = ra8.session.history_replay_feeder;
const gpa = std.testing.allocator;

const Resolver = struct {
    calls: std.atomic.Value(u32) = .init(0),
    address: [4]u8 = .{ 192, 0, 2, 7 },

    fn lookup(context: ?*anyopaque, _: ?std.Io, name: []const u8, out: *[hosted.dns.max_answers][4]u8) !u8 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        _ = self.calls.fetchAdd(1, .release);
        if (!std.mem.eql(u8, name, "host.ra8")) return error.UnexpectedName;
        out[0] = self.address;
        return 1;
    }
};

fn held(context: *anyopaque) bool {
    const session: *ra8.session.api.Session = @ptrCast(@alignCast(context));
    return session.outputMuted();
}

fn attach(bridge: *hosted.net.Bridge, h: *fixture.MockHarness, resolver: *Resolver) !void {
    bridge.resolver = .{ .context = resolver, .lookupFn = Resolver.lookup };
    bridge.worker = hosted.worker.Worker.of(ra8.host.worker);
    bridge.hold = .{ .context = &h.session, .heldFn = held };
    try recorded.attach(gpa, &h.session, bridge);
}

fn close(bridge: *hosted.net.Bridge) void {
    // Finish the callback even on failure before its context leaves scope.
    if (bridge.dns_bridge.thread) |thread| {
        bridge.dns_bridge.thread = null;
        bridge.dns_bridge.worker.?.join(thread);
    }
    recorded.release(bridge);
    bridge.deinit();
}

fn request() [26]u8 {
    var bytes: [26]u8 = @splat(0);
    bytes[0..2].* = .{ 0x12, 0x34 };
    bytes[2] = 1;
    bytes[5] = 1;
    bytes[12] = 4;
    @memcpy(bytes[13..17], "host");
    bytes[17] = 3;
    @memcpy(bytes[18..21], "ra8");
    bytes[23] = 1;
    bytes[25] = 1;
    return bytes;
}

fn exchange(bridge: *hosted.net.Bridge) ![hosted.frame.frame_size]u8 {
    var queue: hosted.queue.Queue = .{};
    bridge.poll(&queue); // Poll zero at this position has no answer yet.
    try std.testing.expectEqual(@as(usize, 0), queue.len);
    const route: hosted.eth.Route = .{ .src_mac = hosted.station.mac, .dst_mac = hosted.station.bssid, .src_ip = hosted.dhcp.lease_ip, .dst_ip = hosted.dhcp.server_ip, .src_port = 40000, .dst_port = hosted.dns.port };
    var ethernet: [hosted.frame.max_payload]u8 = undefined;
    const len = hosted.eth.udpFrame(&ethernet, route, &request()).?;
    try std.testing.expectEqual(hosted.net.Result.handled, bridge.forward(&queue, ethernet[0..len]));
    // Waiting completes the worker without moving the Session position or
    // polling a landing. The answer belongs to poll ordinal one.
    if (bridge.dns_bridge.job) |job| {
        const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 5000;
        while (job.state.load(.acquire) != .ready) {
            if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() >= deadline) return error.WorkerTimeout;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), queue.len);
    bridge.poll(&queue);
    var response: [hosted.frame.frame_size]u8 = undefined;
    try std.testing.expect(queue.pop(&response));
    bridge.poll(&queue);
    try std.testing.expectEqual(@as(usize, 0), queue.len);
    return response;
}

test "DNS answer records its exact poll and replays twice without resolver or worker access" {
    const h = try fixture.MockHarness.init(gpa);
    defer h.deinit();
    var history = try ra8.session.history.History.init(gpa, undefined, 4);
    defer history.deinit();
    history.attachRecorder(&h.recorder);
    h.session.history = &history;
    defer h.session.history = null;
    h.recorder.observe(0);
    h.grid_state.at.r = 11;
    h.grid_state.at.o = 17;
    const at = h.session.currentPosition();
    var resolver: Resolver = .{};
    var live: hosted.net.Bridge = .{};
    try attach(&live, h, &resolver);
    defer close(&live);
    const response = try exchange(&live);
    const expected = (try hosted.frame.parse(&response)).payload;
    const answer = hosted.eth.udp(expected).?;
    try std.testing.expectEqual(@as(usize, 42), answer.data.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x81, 0x80 }, answer.data[0..4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, answer.data[6..8], .big));
    try std.testing.expectEqualSlices(u8, &resolver.address, answer.data[38..42]);
    try std.testing.expectEqual(@as(u32, 1), resolver.calls.load(.acquire));
    try std.testing.expectEqualDeep(at, h.session.currentPosition());
    try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&live).?.failed);
    try h.recorder.commit(1);
    const log = try gpa.dupe(u8, h.mock_storage.bytes.items);
    defer gpa.free(log);
    const decoded = try ra8.session.history_format.decode(log);
    try std.testing.expectEqual(log.len, decoded.consumed);
    const boundary = try ra8.session.history_record.decodeBoundary(decoded.frame.payload);
    try std.testing.expectEqual(ra8.session.history_record.Boundary.What.c6_answer, boundary.boundary.what);
    try std.testing.expectEqualDeep(at, boundary.header.position);
    const landing = try ra8.session.history_c6_landing.decode(boundary.boundary.body);
    try std.testing.expectEqual(hosted.hold.Kind.answer, landing.kind);
    try std.testing.expectEqual(hosted.hold.Site.poll, landing.site);
    try std.testing.expectEqual(@as(u32, 1), landing.ordinal);
    try std.testing.expectEqualSlices(u8, expected, landing.frame);
    for (0..2) |_| {
        resolver.calls.store(0, .release);
        resolver.address = .{ 203, 0, 113, 5 };
        try feeder.loadSessionInterventions(&h.session, log, .at);
        defer feeder.release(&h.session);
        var replay: hosted.net.Bridge = .{};
        try attach(&replay, h, &resolver);
        defer close(&replay);
        h.session.setReplaying(true);
        defer h.session.setReplaying(false);
        const again = try exchange(&replay);
        try std.testing.expectEqualSlices(u8, expected, (try hosted.frame.parse(&again)).payload);
        try std.testing.expectEqualDeep(at, h.session.currentPosition());
        try std.testing.expectEqual(@as(u32, 0), resolver.calls.load(.acquire));
        try std.testing.expect(replay.dns_bridge.job == null and replay.dns_bridge.thread == null);
        try std.testing.expectEqual(@as(u64, 1), recorded.from(&replay).?.replayed);
        try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&replay).?.failed);
        try std.testing.expect(h.session.replay_failure == null);
    }
    try h.recorder.commit(2);
    try std.testing.expectEqualSlices(u8, log, h.mock_storage.bytes.items);
}
