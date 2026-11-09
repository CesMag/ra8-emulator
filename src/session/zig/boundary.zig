//! Board callbacks and a standalone single-core adapter for the saved grid.
//! Stops and budget returns preserve progress without closing the interval.
const zig_core = @import("core.zig");
const zig_cycles = @import("cycles.zig");
const zig_drive = @import("drive.zig");
const stop_machine = @import("../stop_machine.zig");
const watch_bus = @import("../watch/bus.zig");
const chip = @import("ra8_chip");
const scheduler = chip.core.scheduler;

/// Instructions between boundaries when the board names none.
pub const default_chunk: u32 = 1024;

pub const Error = error{BoundaryFailed};

/// Board completion after the core phases finish, measured in elapsed slots.
pub const Boundary = struct {
    context: *anyopaque,
    tickFn: *const fn (context: *anyopaque, instructions: u32) anyerror!void,
    chunk: u32 = default_chunk,
    /// Compatibility reach hook forwarded by instrumentation wrappers.
    sleepFn: ?*const fn (context: *anyopaque, normal: u32) u32 = null,
    /// Root grid configuration and board edges choose the frozen width.
    awakeFn: ?*const fn (context: *anyopaque, normal: u32) u32 = null,
    saved: ?*scheduler.State = null,
    pair: ?*chip.core.second.core.zig.run.Driver = null,
    cut: ?*chip.core.cpu.cpu.systick_cut.Cut = null,
    store: ?*chip.core.cpu.memory.store.Store = null,

    /// Drains what instrumentation recorded, reached by every stop or budget
    /// return. It runs no guest code and ticks no board.
    observeFn: ?*const fn (context: *anyopaque) void = null,

    /// Fires after a round closes (post tick, post next()), before the next
    /// interval opens. The session owns the policy and the recorder; the
    /// loop only offers the closed round.
    checkpointFn: ?*const fn (context: *anyopaque, round: u64) anyerror!void = null,
    /// The hook's own context when it differs from the boundary's: the
    /// session binds its checkpoint controller here, and instrumentation
    /// wrappers forward the pair untouched.
    checkpoint_context: ?*anyopaque = null,

    /// Offers the closed round to the session's checkpoint policy. A run
    /// without the hook checkpoints nothing.
    pub fn checkpoint(self: Boundary, round: u64) Error!void {
        const hook = self.checkpointFn orelse return;
        hook(self.checkpoint_context orelse self.context, round) catch return Error.BoundaryFailed;
    }

    pub fn tick(self: Boundary, instructions: u64) Error!void {
        if (instructions == 0) return;
        self.tickFn(self.context, @intCast(instructions)) catch return Error.BoundaryFailed;
    }
};

/// The observation point of a run's return, also for a return that closed no
/// interval.
pub fn observe(edge: Boundary) void {
    if (edge.observeFn) |look| look(edge.context);
}

/// As zig_drive.runClocked, passing `edge` after every chunk.
pub fn run(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus, clock: ?*zig_cycles.Clock, edge: Boundary) Error!zig_drive.Ended {
    var local: scheduler.State = .{};
    const saved = edge.saved orelse &local;
    if (edge.cut) |cut| cut.instruction = &core.cpu.slots;
    var left = count;
    while (left > 0) {
        if (saved.cut) {
            try edge.tick(saved.stretch.carry);
            saved.next();
            try edge.checkpoint(saved.at.r);
            continue;
        }
        if (saved.stretch.full == 0) saved.open(widthOf(edge), core.cpu.slots);
        const want = @min(left, saved.stretch.left());
        var slots: u64 = 0;
        const ended = zig_drive.runCounted(core, machine, want, watch, clock, &slots);
        const elapsed = if (ended == .count and core.cpu.waiting != null) want else slots;
        core.cpu.idle_cycles +|= elapsed -| slots;
        saved.advance(@intCast(elapsed), @intCast(slots));
        const pending = if (edge.cut) |latch| latch.takePending() else null;
        const cut = pending != null;
        saved.cut = cut;
        saved.cut_pending = pending orelse .{};
        if (ended != .count) {
            saved.at.gap = gapOf(ended);
            return ended;
        }
        left -= elapsed;
        if (cut or saved.stretch.left() == 0) {
            try edge.tick(saved.stretch.carry);
            saved.next();
            try edge.checkpoint(saved.at.r);
        } else if (elapsed < want) return .count;
    }
    return .count;
}

/// Called only when an interval opens, independent of debugger state.
pub fn widthOf(edge: Boundary) u32 {
    const normal = @max(edge.chunk, 1);
    const far = edge.awakeFn orelse return normal;
    return @max(1, far(edge.context, normal));
}

pub fn gapOf(ended: zig_drive.Ended) scheduler.position.Gap {
    if (ended == .stop) return switch (ended.stop) {
        .watchpoint, .unit_watch => .retired,
        else => .polled,
    };
    return .retired;
}
