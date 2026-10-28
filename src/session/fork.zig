//! Session-level fork routing choke point and intervention execution
//! (time-travel design section 11).
//!
//! Every host intervention reaches the machine through routeIntervention.
//! At or past the active line's recorded end it applies live and is
//! recorded where it happened. Before the recorded end it forks: the first
//! fork of a session waits for a confirmation, and a fork is all or
//! nothing. Its steps run in the order that keeps them undoable: checks
//! that can refuse the action, the graph node, branches.bin, the new
//! segment with the Branch record and the fork's own intervention, the
//! line switch, then the action itself. A step that fails puts every
//! earlier one back.
const std = @import("std");
const api = @import("api.zig");
const fork_router_mod = @import("history/fork_router.zig");
const history_record = @import("history/record.zig");
const history_position = @import("history/position.zig");
const history_root = @import("history/root.zig");
const recorder_mod = @import("history/recorder.zig");
const input_script = @import("ra8_components").input_script;
const action_codec = @import("history/action_codec.zig");
const async_traffic = @import("history/async_traffic.zig");
const replay_feeder = @import("history/replay_feeder.zig");
const lifecycle = @import("history/lifecycle.zig");
const new_history = @import("new_history.zig");
const apply = @import("apply.zig");
const line = @import("line.zig");
const run_slice = @import("run_slice.zig");
const window_fork = @import("history/window_fork.zig");
const session_window = @import("window.zig");

const Session = api.Session;
const Core = api.Core;
const Register = api.Register;
const Endpoint = api.Endpoint;
const FaultMode = api.FaultMode;

pub const ForkRouter = fork_router_mod.ForkRouter;
pub const PendingFork = fork_router_mod.PendingFork;
pub const Action = fork_router_mod.Action;
pub const RouteDecision = fork_router_mod.RouteDecision;
pub const ForkReason = history_record.ForkReason;
pub const Position = history_position.Position;

pub const fork_types = @import("fork_types.zig");
pub const NetHook = fork_types.NetHook;
pub const ConsoleHook = fork_types.ConsoleHook;
pub const CameraHook = fork_types.CameraHook;
pub const GraphSink = fork_types.GraphSink;

pub const applyAction = apply.applyAction;
pub const currentPosition = line.currentPosition;
pub const notePosition = line.notePosition;
pub const setReplaying = line.setReplaying;
pub const failReplay = line.failReplay;
pub const outputMuted = line.outputMuted;
pub const comparePositions = line.comparePositions;
pub const run = run_slice.run;
pub const advanceBoard = run_slice.advanceBoard;
pub const recordStop = run_slice.recordStop;
pub const checkAndApplyReplayIntervention = run_slice.deliverDue;

/// Loads the active line's interventions for a machine just restored to
/// its position: the ones recorded there are still to apply.
pub fn loadReplayInterventions(self: *Session, log_bytes: []const u8) anyerror!void {
    return replay_feeder.loadSessionInterventions(self, log_bytes, .at);
}

/// Stages the intervention record for `action` at `pos`.
fn recordActionIntervention(self: *Session, pos: Position, action: Action) anyerror!void {
    if (self.replaying) return;
    const router = self.fork_router;
    const allocator = if (router) |r| r.allocator else if (self.persistent_recorder) |rec| rec.gpa else return;
    var encoded = try action_codec.encode(allocator, action);
    defer action_codec.free(allocator, &encoded);
    const seq = if (router) |r| r.nextSeq() else if (self.history) |h| h.seq else 0;
    if (self.history) |h| h.seq += 1;
    if (self.persistent_recorder) |rec| {
        try rec.recordIntervention(.{ .position = pos, .seq = seq }, .{ .what = encoded.what, .body = encoded.body });
    } else if (self.history) |h| {
        try h.recordIntervention(pos, encoded.what, encoded.body);
    }
}

/// How far a fork got; a failure undoes every step it reached.
const Stage = enum { none, node, persisted, segment, switched };

const Undo = struct {
    stage: Stage = .none,
    new_id: u32 = 0,
    old_line: u32 = 0,
    old_next: u32 = 0,
    segment: recorder_mod.Segment = .{},
    mark: u64 = 0,
};

fn undoFork(self: *Session, undo: Undo) void {
    const router = self.fork_router.?;
    const graph = router.graph.?;
    if (@backingInt(undo.stage) >= @backingInt(Stage.switched)) {
        router.switchActiveLine(undo.old_line);
        line.stampLine(self);
    }
    if (@backingInt(undo.stage) >= @backingInt(Stage.segment)) {
        if (self.persistent_recorder) |rec| rec.abandonSegment(undo.segment, undo.mark);
    }
    if (@backingInt(undo.stage) >= @backingInt(Stage.node)) {
        _ = graph.nodes.remove(undo.new_id);
        // An id whose segment was never opened is free again; one whose
        // segment was opened stays spent, so a later fork never opens a
        // segment an abandoned fork wrote.
        if (@backingInt(undo.stage) < @backingInt(Stage.segment)) graph.next_branch_id = undo.old_next;
    }
    // branches.bin goes back to the graph without the branch. The fork's
    // own error is the one reported; a failed rewrite leaves a node whose
    // segment is empty, which every reader treats as a line with no future.
    if (@backingInt(undo.stage) >= @backingInt(Stage.persisted)) lifecycle.persistGraph(self) catch {};
}

/// Executes a branch fork from a past cursor position.
pub fn executeFork(self: *Session, reason: ForkReason, fork_pos: Position, action: Action) anyerror!void {
    const router = self.fork_router orelse return error.NoHistory;
    const graph = router.graph orelse return error.NoHistory;
    try apply.preflight(self, action);
    const now_ns = if (self.event_clock) |clock| clock.nowFn(clock.context) else self.now() catch 0;
    const canon = try graph.canonicalize(router.active_line, fork_pos);
    var undo: Undo = .{ .old_line = router.active_line, .old_next = graph.next_branch_id };
    errdefer undoFork(self, undo);
    undo.new_id = try graph.addBranch(canon.branch, canon, reason, now_ns);
    undo.stage = .node;
    try lifecycle.persistGraph(self);
    undo.stage = .persisted;
    // The child owns its fork point: the Branch record, the fork's own
    // intervention and the node all name the new branch there.
    var at = canon;
    at.branch = undo.new_id;
    if (self.persistent_recorder) |rec| {
        undo.segment = rec.segment;
        try rec.switchSegment(now_ns, undo.new_id, 0);
        undo.mark = rec.committed_bytes;
        undo.stage = .segment;
        try rec.recordBranch(
            .{ .position = at, .seq = router.nextSeq() },
            .{ .id = undo.new_id, .parent = canon.branch, .fork_at = at, .reason = reason },
        );
        try recordActionIntervention(self, at, action);
        try rec.commit(now_ns);
    }
    router.switchActiveLine(undo.new_id);
    line.stampLine(self);
    window_fork.noteFork(self, undo.new_id);
    undo.stage = .switched;
    try apply.applyAction(self, action);
    // The cut window still holds the state before the write.
    session_window.replantWindow(self);
    if (self.persistent_recorder == null) try recordActionIntervention(self, at, action);
    if (self.net_hook) |hook| hook.closeFlowsFn(hook.context);
    _ = async_traffic.clearOnFork(self);
    replay_feeder.release(self);
}

/// The single Session-level routing choke point for host interventions.
pub fn routeIntervention(self: *Session, core: Core, reason: ForkReason, action: Action) anyerror!void {
    _ = core;
    if (self.replaying) return applyAction(self, action);
    const router = self.fork_router orelse {
        try applyAction(self, action);
        session_window.replantWindow(self);
        try recordActionIntervention(self, currentPosition(self), action);
        return;
    };
    const cursor = currentPosition(self);
    const decision = fork_router_mod.decide(router.graph, router.active_line, cursor, router.recordedEnd(), router.first_fork_confirmed, reason);
    switch (decision) {
        .live => {
            try applyAction(self, action);
            // The window's slots predate the change; a step back across it
            // would land on a state that never ran.
            session_window.replantWindow(self);
            try recordActionIntervention(self, line.canonicalPosition(self), action);
        },
        .needs_confirmation => {
            try router.setPending(reason, cursor, action);
            return error.ForkNeedsConfirmation;
        },
        .fork => try executeFork(self, reason, cursor, action),
    }
}

/// Returns details of any pending fork awaiting user confirmation.
pub fn forkPending(self: *const Session) ?PendingFork {
    if (self.fork_router) |router| return router.pending_fork;
    return null;
}

/// Confirms the pending fork, executes it, and applies the intervention.
/// The fork was asked for at one position on one line; a machine that has
/// moved or changed lines since refuses with error.ForkStale and drops it.
pub fn confirmFork(self: *Session) anyerror!void {
    const router = self.fork_router orelse return error.NoHistory;
    const pending = router.pending_fork orelse return error.NoPendingFork;
    const at = currentPosition(self);
    if (!std.meta.eql(at, pending.position) or !line.inPast(self)) {
        router.cancel();
        return error.ForkStale;
    }
    try executeFork(self, pending.reason, pending.position, pending.action);
    router.cancel();
    router.first_fork_confirmed = true;
}

/// Cancels the pending fork, clearing it without mutating state.
pub fn cancelFork(self: *Session) void {
    if (self.fork_router) |router| router.cancel();
}

pub fn setRegister(self: *Session, core: Core, which: Register, value: u32) anyerror!void {
    return routeIntervention(self, core, .writes, .{ .register = .{ .core = core, .which = which, .value = value } });
}

pub fn write(self: *Session, core: Core, address: u32, bytes: []const u8) anyerror!void {
    return routeIntervention(self, core, .writes, .{ .memory = .{ .core = core, .address = address, .bytes = bytes } });
}

pub fn scheduleInput(self: *Session, core: Core, at_ns: u64, event: input_script.Event) anyerror!void {
    const reason: ForkReason = switch (event) {
        .button => .buttons,
        else => .taps,
    };
    return routeIntervention(self, core, reason, .{ .input = .{ .core = core, .at_ns = at_ns, .event = event } });
}

pub fn consoleInput(self: *Session, core: Core, bytes: []const u8) anyerror!void {
    return routeIntervention(self, core, .keystrokes, .{ .console = .{ .core = core, .bytes = bytes } });
}

pub fn plug(self: *Session, core: Core, at: Endpoint, name: []const u8) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .plug = .{ .core = core, .at = at, .name = name } });
}

pub fn unplug(self: *Session, core: Core, at: Endpoint) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .plug = .{ .core = core, .at = at, .name = null } });
}

pub fn setFault(self: *Session, core: Core, at: Endpoint, mode: FaultMode) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .fault = .{ .core = core, .at = at, .mode = mode } });
}

pub fn clearFault(self: *Session, core: Core, at: Endpoint) anyerror!void {
    return routeIntervention(self, core, .plug_unplug_fault, .{ .fault = .{ .core = core, .at = at, .mode = null } });
}

pub fn changeCamera(self: *Session, core: Core, spec: []const u8) anyerror!void {
    return routeIntervention(self, core, .camera_change, .{ .camera = .{ .core = core, .spec = spec } });
}

pub fn skipBkpt(self: *Session, core: Core) anyerror!void {
    return routeIntervention(self, core, .skip_bkpt, .{ .skip_bkpt = .{ .core = core } });
}

pub fn load(self: *Session, core: Core, image: []const u8) anyerror!void {
    if (new_history.differs(self, core, image)) return new_history.start(self, core, image);
    if (self.root == null and self.fork_router != null) {
        const idx = @as(usize, @backingInt(core));
        if (self.image_identity[idx] == null) self.image_identity[idx] = history_root.identity(image);
    }
    return routeIntervention(self, core, .load, .{ .load = .{ .core = core, .image = image } });
}
