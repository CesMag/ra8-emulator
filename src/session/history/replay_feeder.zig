//! Feeder for scheduled interventions during history replay (Slice 20.3).
//!
//! Reconstructs interventions recorded in committed log frames along the
//! active execution line, orders them by canonical position, and supplies them
//! to the session to be re-applied at their exact positions without re-recording.
const std = @import("std");
const branch_mod = @import("branch.zig");
const position_mod = @import("position.zig");
const record_mod = @import("record.zig");
const replay_mod = @import("replay.zig");
const fork_router_mod = @import("fork_router.zig");
const action_codec = @import("action_codec.zig");

pub const Action = fork_router_mod.Action;
pub const Position = position_mod.Position;
pub const BranchId = branch_mod.BranchId;
pub const BranchGraph = branch_mod.BranchGraph;
pub const Intervention = record_mod.Intervention;

pub const ScheduledIntervention = struct {
    position: Position,
    /// The record's sequence number: the order among items at one position.
    seq: u32 = 0,
    action: Action,
};

pub const EncodedAction = action_codec.EncodedAction;

/// Encodes a Session Action into an intervention record payload.
pub const encodeAction = action_codec.encode;

/// Frees memory allocated by encodeAction.
pub const freeEncodedAction = action_codec.free;

/// Decodes an intervention record back into a Session Action.
pub const decodeAction = action_codec.decode;

/// One camera frame the line recorded: the `camera_frame` record's body,
/// owned here, due at the position the capture armed.
pub const RecordedFrame = struct {
    position: Position,
    seq: u32 = 0,
    body: []u8,
};

pub const ReplayFeeder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ScheduledIntervention),
    cursor: usize = 0,
    /// The line's camera frames in recorded order; a replayed capture takes
    /// the next one instead of reading the host source.
    frames: std.ArrayList(RecordedFrame) = .empty,
    frame_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ReplayFeeder {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(ScheduledIntervention).empty,
            .cursor = 0,
        };
    }

    pub fn deinit(self: *ReplayFeeder) void {
        self.reset();
    }

    pub fn reset(self: *ReplayFeeder) void {
        for (self.items.items) |*item| {
            fork_router_mod.freeAction(self.allocator, &item.action);
        }
        self.items.deinit(self.allocator);
        self.items = std.ArrayList(ScheduledIntervention).empty;
        self.cursor = 0;
        for (self.frames.items) |frame| self.allocator.free(frame.body);
        self.frames.deinit(self.allocator);
        self.frames = .empty;
        self.frame_cursor = 0;
    }

    /// The camera frame recorded for a capture at `pos`, or null when the
    /// line holds none there. Taking it consumes it; a capture that finds
    /// null is a determinism error, never a live read.
    pub fn takeFrame(self: *ReplayFeeder, pos: Position) ?[]const u8 {
        if (self.frame_cursor >= self.frames.items.len) return null;
        const next = self.frames.items[self.frame_cursor];
        if (branch_mod.scalarOrder(next.position, pos) != .eq) return null;
        self.frame_cursor += 1;
        return next.body;
    }

    pub fn loadFromLog(
        self: *ReplayFeeder,
        graph: ?*const BranchGraph,
        active_line: BranchId,
        log_bytes: []const u8,
    ) !void {
        self.reset();
        var ctx = ScanContext{
            .feeder = self,
            .graph = graph,
            .active_line = active_line,
        };
        _ = try replay_mod.replay(log_bytes, &ctx, visitRecord);
        std.mem.sort(ScheduledIntervention, self.items.items, {}, sortLess);
        std.mem.sort(RecordedFrame, self.frames.items, {}, frameLess);
    }

    /// The next item due at `pos`: the first undelivered one whose
    /// recorded position is at or before `pos`. A position the run never
    /// stops on exactly still delivers its item at the first check past
    /// it, so a missed sample never holds the queue.
    pub fn peekDue(self: *ReplayFeeder, pos: Position) ?ScheduledIntervention {
        if (self.cursor >= self.items.items.len) return null;
        const next = self.items.items[self.cursor];
        if (branch_mod.scalarOrder(next.position, pos) == .gt) return null;
        return next;
    }

    pub fn advance(self: *ReplayFeeder) void {
        if (self.cursor < self.items.items.len) self.cursor += 1;
    }

    pub fn nextPosition(self: *ReplayFeeder) ?Position {
        if (self.cursor >= self.items.items.len) return null;
        return self.items.items[self.cursor].position;
    }

    /// Puts the cursor on the first item still due from `pos`. A machine
    /// restored to `pos` has none of the interventions made at `pos` yet
    /// (`.at`); a machine that is already there live has them all (`.after`).
    pub fn seekTo(self: *ReplayFeeder, pos: Position, from: From) void {
        self.cursor = 0;
        while (self.cursor < self.items.items.len) : (self.cursor += 1) {
            const ord = branch_mod.scalarOrder(self.items.items[self.cursor].position, pos);
            if (ord == .gt or (ord == .eq and from == .at)) break;
        }
        self.frame_cursor = 0;
        while (self.frame_cursor < self.frames.items.len) : (self.frame_cursor += 1) {
            const ord = branch_mod.scalarOrder(self.frames.items[self.frame_cursor].position, pos);
            if (ord == .gt or (ord == .eq and from == .at)) break;
        }
    }

    pub fn count(self: *const ReplayFeeder) usize {
        return self.items.items.len;
    }

    pub fn isEmpty(self: *const ReplayFeeder) bool {
        return self.items.items.len == 0;
    }

    /// Re-applies every item due at the session's position, in recorded
    /// order, without recording any of them again.
    pub fn checkAndApply(self: *ReplayFeeder, session: *api.Session) !void {
        const cur_pos = session.currentPosition();
        while (self.peekDue(cur_pos)) |item| {
            const prior = session.replaying;
            session.setReplaying(true);
            defer session.setReplaying(prior);
            self.advance();
            try apply.applyAction(session, item.action);
        }
    }
};

/// Where a load starts delivering, relative to the session's position.
pub const From = enum { at, after };

const api = @import("../api.zig");
const apply = @import("../apply.zig");

/// Loads the active line's interventions from the committed log into the
/// session's feeder, due from the session's position.
pub fn loadSessionInterventions(session: *api.Session, log_bytes: []const u8, from: From) !void {
    const router = session.fork_router orelse return;
    if (session.replay_feeder == null) {
        session.replay_feeder = ReplayFeeder.init(router.allocator);
    }
    try session.replay_feeder.?.loadFromLog(router.graph, router.active_line, log_bytes);
    session.replay_feeder.?.seekTo(session.currentPosition(), from);
}

/// Drops the session's feeder and everything it holds; the next replay
/// loads the line it then runs on.
pub fn release(session: *api.Session) void {
    if (session.replay_feeder) |*feeder| feeder.deinit();
    session.replay_feeder = null;
}

const ScanContext = struct {
    feeder: *ReplayFeeder,
    graph: ?*const BranchGraph,
    active_line: BranchId,
};

fn onLine(ctx: *ScanContext, raw_pos: Position) ?Position {
    if (ctx.graph) |g| return g.canonicalize(ctx.active_line, raw_pos) catch null;
    if (raw_pos.branch != ctx.active_line) return null;
    return raw_pos;
}

fn visitRecord(ctx: *ScanContext, entry: replay_mod.Entry) anyerror!void {
    switch (entry) {
        .intervention => |hit| {
            const canon_pos = onLine(ctx, hit.header.position) orelse return;
            // A kind this reader does not replay (an RPC mutation) is
            // kept in the log and skipped here; a known kind whose body
            // does not decode is a broken history, not a skip.
            if (!replayable(hit.intervention.what)) return;
            const action = try decodeAction(ctx.feeder.allocator, hit.intervention.what, hit.intervention.body);
            try ctx.feeder.items.append(ctx.feeder.allocator, .{
                .position = canon_pos,
                .seq = hit.header.seq,
                .action = action,
            });
        },
        .boundary => |hit| {
            if (hit.boundary.what != .camera_frame) return;
            const canon_pos = onLine(ctx, hit.header.position) orelse return;
            const body = try ctx.feeder.allocator.dupe(u8, hit.boundary.body);
            errdefer ctx.feeder.allocator.free(body);
            try ctx.feeder.frames.append(ctx.feeder.allocator, .{ .position = canon_pos, .seq = hit.header.seq, .body = body });
        },
        else => {},
    }
}

fn replayable(what: Intervention.What) bool {
    return switch (what) {
        .tap, .button, .keystroke, .register_write, .memory_write, .plug, .unplug, .fault, .camera_change, .skip_bkpt, .load => true,
        else => false,
    };
}

fn sortLess(_: void, a: ScheduledIntervention, b: ScheduledIntervention) bool {
    return switch (branch_mod.scalarOrder(a.position, b.position)) {
        .lt => true,
        .gt => false,
        .eq => a.seq < b.seq,
    };
}

fn frameLess(_: void, a: RecordedFrame, b: RecordedFrame) bool {
    return switch (branch_mod.scalarOrder(a.position, b.position)) {
        .lt => true,
        .gt => false,
        .eq => a.seq < b.seq,
    };
}
