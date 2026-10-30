//! Covers the hang-up src/session/board/recorded_usbip.zig records when the
//! cursor goes into the past: a replay or seek past the old recorded end
//! holds no host and pumps no URB the original run left behind.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("recorded_usbip_rig.zig");

const recorded = ra8.session.board.recorded_usbip;
const feeder = ra8.session.history_replay_feeder;
const gpa = std.testing.allocator;
const openOut = rig.openOut;
const digest = rig.digest;
const Host = rig.Host;
const Run = rig.Run;
const Setup = rig.Setup;

/// Leaves the fork live after its disconnected host's pending transfer
/// would have reached the device, and returns that device state.
const ForkCase = enum { immediate, polled, ancestor };

fn recordFork(s: *Setup, which: ForkCase) !u64 {
    var host: Host = .{};
    var live: Run = .{};
    host.install(&live.target);
    try recorded.attach(gpa, &s.h.session, &live.target);
    defer recorded.release(&live.target, &s.h.session);
    openOut(&live.device);
    for (1..7) |n| live.poll(s.h, @intCast(n));
    // Keep the first packet unread, so the second transfer stays pending.
    live.poll(s.h, 8);
    try std.testing.expect(host.connected);
    try std.testing.expect(host.urbs.pending() > 0);
    s.h.graph.nodes.getPtr(0).?.recorded_end.r = 8;
    try s.h.recorder.commit(1);
    const parent = try gpa.dupe(u8, s.h.mock_storage.bytes.items);
    defer gpa.free(parent);
    if (which == .ancestor) {
        var at = s.h.session.currentPosition();
        at.r = 7;
        const child = try s.h.graph.addBranch(0, at, .keystrokes, 0);
        s.h.graph.nodes.getPtr(child).?.recorded_end.r = 8;
        s.h.router.switchActiveLine(child);
    }

    // Restore the device before replaying to a fork with an URB in flight.
    live.device = .{};
    openOut(&live.device);
    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, parent, .at);
    s.h.session.setReplaying(true);
    for (1..7) |n| live.poll(s.h, @intCast(n));
    s.h.session.setReplaying(false);
    try std.testing.expect(!host.connected);
    try std.testing.expect(host.replayer.urbs.pending() > 0);
    if (which == .polled) live.poll(s.h, 6);
    try std.testing.expectError(error.ForkNeedsConfirmation, s.h.session.consoleInput(.cpu0, "fork"));
    try s.h.session.confirmFork();
    try std.testing.expectEqual(@as(u32, if (which == .ancestor) 2 else 1), s.h.router.active_line);
    live.poll(s.h, 6);
    for (7..15) |n| live.poll(s.h, @intCast(n));
    try std.testing.expect(!host.replayer.connected);
    try std.testing.expectEqual(@as(usize, 0), host.replayer.urbs.pending());
    try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&live.target).?.failed);
    try s.h.recorder.commit(2);
    return digest(&live.device);
}

test "a fork after rewinding records its own disconnect before an abandoned URB can run" {
    try checkFork(.immediate);
}

test "polling in the past before a fork preserves the child's disconnect" {
    try checkFork(.polled);
}

test "a fork in an ancestor prefix disconnects even when its parent is not the old leaf" {
    try checkFork(.ancestor);
}

test "switching to an existing child leaves its recorded past unchanged" {
    const s = try Setup.open();
    defer s.close();
    var host: Host = .{};
    var live: Run = .{};
    host.install(&live.target);
    try recorded.attach(gpa, &s.h.session, &live.target);
    defer recorded.release(&live.target, &s.h.session);
    _ = live.go(s.h, 8);
    s.h.graph.nodes.getPtr(0).?.recorded_end.r = 8;
    var at = s.h.session.currentPosition();
    at.r = 6;
    const child = try s.h.graph.addBranch(0, at, .keystrokes, 0);
    s.h.graph.nodes.getPtr(child).?.recorded_end.r = 14;
    try s.h.recorder.commit(1);
    const before = s.h.mock_storage.bytes.items.len;
    const log = try gpa.dupe(u8, s.h.mock_storage.bytes.items);
    defer gpa.free(log);
    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, log, .at);
    defer feeder.release(&s.h.session);
    s.h.session.setReplaying(true);
    live.poll(s.h, 6);
    s.h.session.setReplaying(false);
    s.h.router.switchActiveLine(child);
    live.poll(s.h, 6);
    try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&live.target).?.failed);
    try s.h.recorder.commit(2);
    try std.testing.expectEqual(before, s.h.mock_storage.bytes.items.len);
}

fn checkFork(which: ForkCase) !void {
    const s = try Setup.open();
    defer s.close();
    const want = try recordFork(s, which);
    const log = s.h.mock_storage.bytes.items;
    var host: Host = .{};
    var again: Run = .{};
    host.install(&again.target);
    try recorded.attach(gpa, &s.h.session, &again.target);
    defer recorded.release(&again.target, &s.h.session);
    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, log, .at);
    defer feeder.release(&s.h.session);
    s.h.session.setReplaying(true);
    defer s.h.session.setReplaying(false);
    openOut(&again.device);
    for (1..15) |n| again.poll(s.h, @intCast(n));
    try std.testing.expectEqual(@as(?anyerror, null), recorded.from(&again.target).?.failed);
    try std.testing.expect(!host.replayer.connected);
    try std.testing.expectEqual(@as(usize, 0), host.replayer.urbs.pending());
    try std.testing.expectEqual(@as(u32, 0), host.polls);
    try std.testing.expectEqual(want, digest(&again.device));
}

test "a hang-up on rewinding is recorded at the old end, so a replay past it holds no abandoned host" {
    const s = try Setup.open();
    defer s.close();
    var host: Host = .{};
    var live: Run = .{};
    host.install(&live.target);
    try recorded.attach(gpa, &s.h.session, &live.target);
    defer recorded.release(&live.target, &s.h.session);
    openOut(&live.device);
    // Live to round 8 with both URBs in flight; the line ends there.
    for (1..9) |n| live.poll(s.h, @intCast(n));
    try std.testing.expect(host.connected);
    s.h.graph.nodes.getPtr(0).?.recorded_end.r = 8;
    try s.h.recorder.commit(1);
    const first = try gpa.dupe(u8, s.h.mock_storage.bytes.items);
    defer gpa.free(first);

    // Rewind (a replaying run carries the cursor back), then play on to
    // the old end and past it. The first poll that is not a replay writes
    // the hang-up.
    try feeder.loadSessionInterventions(&s.h.session, first, .at);
    defer feeder.release(&s.h.session);
    s.h.session.setReplaying(true);
    for (1..4) |n| live.poll(s.h, @intCast(n));
    s.h.session.setReplaying(false);
    try std.testing.expect(!host.connected);
    live.poll(s.h, 3);
    try s.h.recorder.commit(2);
    try std.testing.expect(s.h.mock_storage.bytes.items.len > first.len);
    for (4..15) |n| live.poll(s.h, @intCast(n));
    const want = digest(&live.device);
    const log = s.h.mock_storage.bytes.items;

    // A replay from the start, and a seek past the old end, both end with
    // no host and no URB left to pump, in the device state the run had.
    var replayed: Host = .{};
    var again: Run = .{};
    replayed.install(&again.target);
    try recorded.attach(gpa, &s.h.session, &again.target);
    defer recorded.release(&again.target, &s.h.session);
    s.h.grid_state.at.r = 0;
    try feeder.loadSessionInterventions(&s.h.session, log, .at);
    s.h.session.setReplaying(true);
    defer s.h.session.setReplaying(false);
    openOut(&again.device);
    for (1..15) |n| again.poll(s.h, @intCast(n));
    try std.testing.expectEqual(want, digest(&again.device));
    try std.testing.expect(!replayed.replayer.connected);
    try std.testing.expectEqual(@as(usize, 0), replayed.replayer.urbs.pending());

    s.h.grid_state.at.r = 12;
    try feeder.loadSessionInterventions(&s.h.session, log, .after);
    again.poll(s.h, 12);
    try std.testing.expect(!replayed.replayer.connected);
    try std.testing.expectEqual(@as(usize, 0), replayed.replayer.urbs.pending());
    try std.testing.expectEqual(@as(u32, 0), replayed.polls);
}
