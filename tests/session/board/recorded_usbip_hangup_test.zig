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
