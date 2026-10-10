//! Runs a `--faults FILE` schedule (RA8EMU-207) on a Zig-core run.
//!
//! The schedule goes through the session (setFault, clearFault, plug,
//! unplug), so the event stream records each change the same way it does
//! for the debugger. It wraps the run's own boundary rather than touching
//! the run loop: each stretch is cut short so it ends exactly on the next
//! event's virtual time, and at that boundary every event due is applied
//! in file order. Time is the board's TimeBase (RA8EMU-179); the wrapped
//! boundary converts its cycle edge when instructions and cycles differ.
const std = @import("std");
const boot = @import("ra8_chip").core.cpu.boot;
const api = @import("session_api.zig");
const fault_schedule = @import("../components/fault_schedule.zig");
const timebase = @import("ra8_chip").periph.timebase;

pub const Applier = struct {
    events: []const fault_schedule.Event,
    session: *api.Session,
    clock: *const timebase.TimeBase,
    inner: boot.Boundary,
    next: usize = 0,
    /// When set, the virtual time each event was applied at, by index.
    applied_ns: ?[]u64 = null,

    pub fn boundary(self: *Applier) boot.Boundary {
        return .{
            .context = self,
            .widthFn = widthThunk,
            .closeFn = closeThunk,
            .abortFn = if (self.inner.abortFn != null) abortThunk else null,
            .reboot = self.inner.reboot,
            .cyclesFn = if (self.inner.cyclesFn != null) cyclesThunk else null,
            .doneFn = if (self.inner.doneFn != null) doneThunk else null,
            .sleepFn = if (self.inner.sleepFn != null) sleepThunk else null,
        };
    }

    /// Apply what is due before the first instruction (events at 0s).
    pub fn start(self: *Applier) !void {
        try self.applyDue();
    }

    pub fn finished(self: *const Applier) bool {
        return self.next >= self.events.len;
    }

    /// Instructions until the next event, or null when none is left.
    fn untilNext(self: *const Applier) ?u64 {
        if (self.finished()) return null;
        return self.clock.cyclesUntil(self.events[self.next].at_ns);
    }

    /// `normal` cut so the stretch ends on the next event, never below one.
    fn cap(self: *const Applier, normal: u32) u32 {
        const left = self.untilNext() orelse return normal;
        const instructions = if (self.inner.cyclesFn) |convert| convert(self.inner.context, left) else left;
        return @intCast(@max(1, @min(normal, instructions)));
    }

    fn applyDue(self: *Applier) !void {
        const now = self.clock.now();
        while (!self.finished() and self.events[self.next].at_ns <= now) {
            try self.apply(self.events[self.next]);
            if (self.applied_ns) |times| times[self.next] = now;
            self.next += 1;
        }
    }

    fn apply(self: *Applier, event: fault_schedule.Event) !void {
        switch (event.action) {
            .fault => |mode| try self.session.setFault(.cpu0, event.target, mode),
            .clear => try self.session.clearFault(.cpu0, event.target),
            .unplug => try self.session.unplug(.cpu0, event.target),
            .plug => |name| try self.session.plug(.cpu0, event.target, name),
        }
    }
};

fn of(context: *anyopaque) *Applier {
    return @ptrCast(@alignCast(context));
}

fn widthThunk(context: *anyopaque) u32 {
    const self = of(context);
    return self.cap(self.inner.widthFn(self.inner.context));
}

fn closeThunk(context: *anyopaque, instructions: u32) anyerror!void {
    const self = of(context);
    try self.inner.closeFn(self.inner.context, instructions);
    try self.applyDue();
}

fn abortThunk(context: *anyopaque) void {
    const self = of(context);
    self.inner.abortFn.?(self.inner.context);
}

fn doneThunk(context: *anyopaque) bool {
    const self = of(context);
    return self.inner.doneFn.?(self.inner.context);
}

fn sleepThunk(context: *anyopaque, normal: u32) u32 {
    const self = of(context);
    return self.cap(self.inner.sleepFn.?(self.inner.context, normal));
}

fn cyclesThunk(context: *anyopaque, cycles: u64) u64 {
    const self = of(context);
    return self.inner.cyclesFn.?(self.inner.context, cycles);
}
