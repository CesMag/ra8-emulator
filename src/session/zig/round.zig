//! CPU0, then the latched CPU1 turn, then one atomic board completion.
const chip = @import("ra8_chip");
const scheduler = chip.core.scheduler;
const boundary = @import("boundary.zig");
const drive = @import("drive.zig");
const session = @import("session.zig");
const CutBus = @import("cut_bus.zig").CutBus;

pub const Target = struct { core: u1, slots: u64 };

pub fn run(live: *session.ZigSession, edge: boundary.Boundary, target: ?Target) session.Error!drive.Ended {
    const selected = live.index;
    const budget = live.budget;
    defer live.switchTo(selected) catch unreachable;
    const saved = edge.saved orelse &live.saved;
    try live.switchTo(0);
    const cpu0 = live.core.cpu;
    var cutting: CutBus = undefined;
    const inner = cpu0.bus;
    if (edge.cut) |cut| {
        cut.requester = &cpu0.banked;
        cut.instruction = &cpu0.slots;
        cutting = .{ .inner = inner, .cut = cut };
        cpu0.bus = cutting.view();
        cpu0.cut = cut;
    }
    defer cpu0.bus = inner;
    if (live.other) |other| scheduler.pairEvents(cpu0, other.core.cpu);
    var running: Round = .{ .live = live, .saved = saved, .edge = edge, .left = budget, .target = target };
    while (true) if (try running.advance()) |ended| return ended;
}

const Round = struct {
    live: *session.ZigSession,
    saved: *scheduler.State,
    edge: boundary.Boundary,
    left: u64,
    target: ?Target,

    fn advance(self: *Round) session.Error!?drive.Ended {
        return switch (self.saved.at.phase) {
            .cpu0 => self.cpu0(),
            .cpu1 => self.cpu1(),
            .board => done: {
                try self.edge.tick(self.saved.stretch.carry);
                self.saved.next();
                try self.edge.checkpoint(self.saved.at.r);
                break :done null;
            },
        };
    }

    fn limit(self: *const Round, core: u1) ?u64 {
        const asked = self.target orelse return null;
        return if (asked.core == core) asked.slots else null;
    }

    fn cpu0(self: *Round) session.Error!?drive.Ended {
        const saved = self.saved;
        const live = self.live;
        try live.switchTo(0);
        if (saved.cut) {
            saved.endCpu0(true, self.edge.pair != null);
            return null;
        }
        const cpu = live.core.cpu;
        const canonical = if (self.limit(0)) |at| cpu.slots >= at else false;
        if (self.left == 0 and !canonical and self.target == null) return .count;
        if (self.left == 0 and self.limit(0) != null and cpu.waiting != null) return .count;
        if (saved.stretch.full == 0) {
            saved.open(boundary.widthOf(self.edge), cpu.slots);
            saved.base[1] = if (live.other) |other| other.core.cpu.slots else 0;
        }
        const want = if (self.target != null and self.left == 0) saved.stretch.left() else @min(self.left, saved.stretch.left());
        var slots: u64 = 0;
        const ended = drive.runTarget(live.core, live.machine, want, live.watch, &live.clock, &slots, self.limit(0));
        const elapsed = if (ended == .count and cpu.waiting != null) want else slots;
        cpu.idle_cycles +|= elapsed -| slots;
        saved.advance(@intCast(elapsed), @intCast(slots));
        self.left -|= elapsed;
        const pending = if (self.edge.cut) |latch| latch.takePending() else null;
        const cut = pending != null;
        saved.cut = cut;
        saved.cut_pending = pending orelse .{};
        if (ended != .count) return stopped(live, saved, ended);
        // A store can both cut the interval and trigger a data comparator.
        // Deliver that stop at the following instruction before board close;
        // the saved cut then owns the deferred timer charge on resume.
        if (cut and live.machine.halting and live.machine.pendingData()) {
            var none: u64 = 0;
            const polled = drive.runTarget(live.core, live.machine, 0, live.watch, &live.clock, &none, cpu.slots);
            if (polled != .count) return stopped(live, saved, polled);
        }
        if (cut or saved.stretch.left() == 0) {
            saved.endCpu0(cut, self.edge.pair != null);
            return null;
        }
        if (self.limit(0)) |at| if (cpu.slots >= at and cpu.waiting == null) return stepped(live, saved);
        return if (elapsed == 0) drive.Ended.count else null;
    }

    fn cpu1(self: *Round) session.Error!?drive.Ended {
        const saved = self.saved;
        const live = self.live;
        const pair = self.edge.pair orelse return error.CoreNotAttached;
        try live.switchTo(1);
        pair.openTurn(saved.stretch.carry, chip.periph.clocks.timebase.default_hz);
        if (pair.second.state.fault != null) pair.closeTurn();
        if (!pair.turn_state.open) {
            self.boardPhase();
            return if (self.target != null and self.left == 0) drive.Ended.count else null;
        }
        const cpu = live.core.cpu;
        const want = pair.turn_state.share - pair.turn_state.elapsed;
        var slots: u64 = 0;
        const ended = drive.runTarget(live.core, live.machine, want, live.watch, &live.clock, &slots, self.limit(1));
        const elapsed = if (ended == .count and cpu.waiting != null) want else slots;
        cpu.idle_cycles +|= elapsed -| slots;
        pair.noteTurn(@intCast(elapsed), @intCast(slots));
        saved.lengths[1] += @intCast(slots);
        saved.at.o = saved.lengths[1];
        if (ended == .core) pair.second.state.fault = .{ .pc = cpu.regs.pc, .detail = @tagName(ended.core) };
        if (ended != .count) return stopped(live, saved, ended);
        if (pair.turn_state.elapsed == pair.turn_state.share) {
            pair.closeTurn();
            self.boardPhase();
            return null;
        }
        if (self.limit(1)) |at| if (cpu.slots >= at and cpu.waiting == null) {
            const settled = stepped(live, saved);
            if (settled == .core) pair.second.state.fault = .{ .pc = cpu.regs.pc, .detail = @tagName(settled.core) };
            return settled;
        };
        if (self.limit(1) != null and self.left == 0 and cpu.waiting != null) return .count;
        return if (elapsed == 0) drive.Ended.count else null;
    }

    fn boardPhase(self: *Round) void {
        self.saved.at.phase = .board;
        self.saved.at.o = 0;
        self.saved.at.gap = .retired;
    }
};

fn stopped(live: *session.ZigSession, saved: *scheduler.State, ended: drive.Ended) drive.Ended {
    saved.at.gap = boundary.gapOf(ended);
    live.ended_index = live.index;
    return ended;
}

/// The target slot is canonical after its poll. A host budget that ended on
/// the slot has not polled yet, so poll here without running an instruction.
fn stepped(live: *session.ZigSession, saved: *scheduler.State) drive.Ended {
    var none: u64 = 0;
    const polled = drive.runTarget(live.core, live.machine, 0, live.watch, &live.clock, &none, live.core.cpu.slots);
    if (polled != .count) return stopped(live, saved, polled);
    live.machine.mode = .halted;
    live.ended_index = live.index;
    saved.at.gap = .polled;
    return .{ .stop = .stepped };
}
