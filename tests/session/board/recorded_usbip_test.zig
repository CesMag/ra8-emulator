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
const rig = @import("recorded_usbip_rig.zig");
const at = rig.at;
const openOut = rig.openOut;
const command = rig.command;
const digest = rig.digest;
const Host = rig.Host;
const Run = rig.Run;
const Setup = rig.Setup;

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
    // The session hears of it too, so the run stops on it.
    try std.testing.expectEqual(ra8.session.stop_machine.ReplaySource.usbip, s.h.session.replay_failure.?.source);
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

/// Records the scripted connection live and returns the committed log.
fn recordConnection(s: *Setup) !struct { want: u64, log: []const u8 } {
    var host: Host = .{};
    var live: Run = .{};
    host.install(&live.target);
    try recorded.attach(gpa, &s.h.session, &live.target);
    const want = live.go(s.h, 14);
    recorded.release(&live.target, &s.h.session);
    try s.h.recorder.commit(1);
    return .{ .want = want, .log = s.h.mock_storage.bytes.items };
}

test "a seek into the middle of a connection replays on to the same device state as a straight replay" {
    const s = try Setup.open();
    defer s.close();
    const made = try recordConnection(s);

    // A straight replay, with the device as the checkpoint at round 6 had it:
    // the first URB is done, the second is still in flight.
    var host: Host = .{};
    var straight: Run = .{};
    host.install(&straight.target);
    try recorded.attach(gpa, &s.h.session, &straight.target);
    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, made.log, .at);
    s.h.session.setReplaying(true);
    openOut(&straight.device);
    var checkpoint: usbfs.Device = undefined;
    for (1..15) |n| {
        straight.poll(s.h, @intCast(n));
        if (n == 6) checkpoint = straight.device;
    }
    try std.testing.expectEqual(made.want, digest(&straight.device));
    recorded.release(&straight.target, &s.h.session);
    feeder.release(&s.h.session);
    s.h.session.setReplaying(false);

    // A fresh machine restored to that checkpoint continues from it.
    var other: Host = .{};
    var seeked: Run = .{};
    other.install(&seeked.target);
    try recorded.attach(gpa, &s.h.session, &seeked.target);
    defer recorded.release(&seeked.target, &s.h.session);
    seeked.device = checkpoint;
    s.h.grid_state.at.r = 6;
    try feeder.loadSessionInterventions(&s.h.session, made.log, .after);
    defer feeder.release(&s.h.session);
    s.h.session.setReplaying(true);
    defer s.h.session.setReplaying(false);
    for (7..15) |n| seeked.poll(s.h, @intCast(n));
    const port = recorded.from(&seeked.target).?;
    try std.testing.expectEqual(@as(?anyerror, null), port.failed);
    try std.testing.expect(s.h.session.replay_failure == null);
    try std.testing.expectEqual(made.want, digest(&seeked.device));
    try std.testing.expectEqual(@as(u32, 0), other.polls);
}

test "going into the past hangs up a connected host and coming back drops the replayed one" {
    const s = try Setup.open();
    defer s.close();
    var host: Host = .{};
    var run: Run = .{};
    host.install(&run.target);
    try recorded.attach(gpa, &s.h.session, &run.target);
    defer recorded.release(&run.target, &s.h.session);
    openOut(&run.device);
    for (1..7) |n| run.poll(s.h, @intCast(n));
    try std.testing.expect(host.connected);
    try std.testing.expectEqual(@as(usize, 1), host.urbs.pending());
    const polls = host.polls;

    // The cursor goes into the past: the live host's URBs are gone, so the
    // transfers in flight cannot run on the machine put back, and the bridge
    // is not polled.
    s.h.session.setReplaying(true);
    run.poll(s.h, 7);
    try std.testing.expect(!host.connected);
    try std.testing.expectEqual(@as(usize, 0), host.urbs.pending());
    try std.testing.expectEqual(polls, host.polls);

    // The replayed host leaves with the replay; none of its URBs outlive it.
    var head: [wire.basic_len + 4]u8 = undefined;
    const cmd = command(&head, 9, "xy", null);
    try host.replayer.restore(.{ .kind = .import, .head = "1-1" });
    try host.replayer.restore(.{ .kind = .submit, .head = cmd[0..wire.basic_len], .data = cmd[wire.basic_len..] });
    try std.testing.expectEqual(@as(usize, 1), host.replayer.urbs.pending());
    s.h.session.setReplaying(false);
    run.poll(s.h, 8);
    try std.testing.expectEqual(@as(usize, 0), host.replayer.urbs.pending());
    try std.testing.expect(!host.replayer.connected);
    try std.testing.expectEqual(polls + 1, host.polls);
}
