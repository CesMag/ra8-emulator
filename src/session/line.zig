//! The line the session's machine runs on, and the positions it stands at
//! (time-travel design section 11).
//!
//! The scheduler's own position carries a branch field. The session stamps
//! the active line into it whenever the line changes, a checkpoint is
//! restored or a run starts, so every position read off the run names the
//! line it was taken on. Comparing such a position canonicalizes it on that
//! line, and a position recorded live is its owner's: live recording only
//! happens past the line's recorded end, which the line's own segment owns.
const std = @import("std");
const api = @import("api.zig");
const stop_machine = @import("stop_machine.zig");
const branch_mod = @import("history/branch.zig");
const history_position = @import("history/position.zig");
const replay_feeder = @import("history/replay_feeder.zig");
const window_fork = @import("history/window_fork.zig");

const Session = api.Session;
pub const Position = history_position.Position;
pub const BranchId = branch_mod.BranchId;

/// The session's position with the active line as its branch.
pub fn currentPosition(self: *const Session) Position {
    const line = if (self.fork_router) |router| router.active_line else branch_mod.root_branch_id;
    var p: Position = if (self.grid) |grid| grid.at else .{};
    p.branch = line;
    return p;
}

/// The session's position named by the branch whose segment owns it.
pub fn canonicalPosition(self: *const Session) Position {
    const p = currentPosition(self);
    const router = self.fork_router orelse return p;
    const graph = router.graph orelse return p;
    return graph.canonicalize(router.active_line, p) catch p;
}

/// Writes the active line into the run's scheduler position, so the
/// positions the transport and the checkpoints read off it name the line.
pub fn stampLine(self: *Session) void {
    const router = self.fork_router orelse return;
    const grid = self.grid orelse return;
    // The grid is the run's own saved scheduler state, which the session
    // reads through a const pointer; the line is the session's to write.
    @constCast(grid).at.branch = router.active_line;
}

/// Moves the session onto line `id`: the graph's active branch, the
/// scheduler position's branch, and the recorder's segment follow, and the
/// replay feeder drops the old line's interventions.
pub fn switchLine(self: *Session, id: BranchId) !void {
    const router = self.fork_router orelse return error.NoHistory;
    if (self.persistent_recorder) |rec| {
        if (rec.segment.branch != id) try rec.switchSegment(0, id, 0);
    }
    router.switchActiveLine(id);
    stampLine(self);
    replay_feeder.release(self);
    window_fork.noteBranchSwitch(self, id) catch {};
}

/// Advances the active line's recorded end to `pos` in memory. The end is
/// recoverable from the log, so it reaches branches.bin with the next
/// structural change or the history's close, never per run slice.
pub fn notePosition(self: *Session, pos: Position) void {
    if (self.replaying) return;
    const router = self.fork_router orelse return;
    const graph = router.graph orelse return;
    const canon = graph.canonicalize(router.active_line, pos) catch return;
    const node = graph.nodes.getPtr(router.active_line) orelse return;
    if (branch_mod.scalarOrder(canon, node.recorded_end) == .gt) node.recorded_end = canon;
}

/// Notes the first determinism error a recorded host source hit while
/// the machine replayed; the run slice that sees it stops with it.
pub fn failReplay(self: *Session, source: stop_machine.ReplaySource, err: anyerror) void {
    if (self.replay_failure == null) self.replay_failure = .{ .source = source, .err = err };
}

/// Whether host-facing output is muted: the machine is replaying, or stands
/// in the recorded past and would replay if it ran.
pub fn outputMuted(self: *const Session) bool {
    return self.replaying or inPast(self);
}

pub fn setReplaying(self: *Session, replaying: bool) void {
    self.replaying = replaying;
    if (self.history) |h| h.replaying = replaying;
    if (self.persistent_recorder) |rec| rec.replaying = replaying;
}

/// Orders two positions on the active line, canonicalizing both.
pub fn comparePositions(self: *const Session, a: Position, b: Position) anyerror!std.math.Order {
    if (self.fork_router) |router| {
        if (router.graph) |graph| return graph.compareOnLine(router.active_line, a, b);
    }
    return history_position.compare(a, b);
}

/// Whether the session's position is strictly before the active line's
/// recorded end: playing there replays, and an intervention there forks.
pub fn inPast(self: *const Session) bool {
    const router = self.fork_router orelse return false;
    const graph = router.graph orelse return false;
    const ord = graph.compareOnLine(router.active_line, currentPosition(self), router.recordedEnd()) catch return false;
    return ord == .lt;
}
