//! CPU load from the RTOS trace's events (RA8EMU-269).
//!
//! Fed the same events src/session/rtos/trace.zig records, in order, this
//! charges the virtual time between two of them to whatever ran in it on
//! that core: the innermost active exception if one is, else the running
//! thread, else idle. Time before a core's first event goes to `before`,
//! because nothing yet says what ran.
//!
//! One exception to "innermost exception first": ThreadX's Cortex-M
//! scheduler waits for work inside PendSV_Handler, looping on WFI in
//! `__tx_ts_wait` in Handler mode after storing 0 to the current-thread
//! pointer (RA8EMU-303). Charged as PendSV, an idle board reads as 99%
//! scheduler. So once an `idle` arrives while PendSV is the innermost
//! exception, that PendSV's time goes to idle until a thread is switched
//! in or the PendSV returns. An exception nested inside the wait (SysTick)
//! still charges itself.
//!
//! Only time inside the window [from, to) is charged, and totals run as the
//! events arrive, so the load does not depend on the trace's 256-event ring
//! and costs fixed memory however long the run goes.
const std = @import("std");
const rtos_trace = @import("trace.zig");

pub const limits = struct {
    /// Distinct owners (threads, exceptions, idle) kept per core. Time for
    /// any past this goes to `Core.other`.
    pub const slots: usize = 32;
    /// Exceptions nested deeper than this keep charging the deepest kept.
    pub const depth: usize = 8;
    pub const cores: usize = rtos_trace.limits.cores;
};

/// PendSV's exception number (DDI0553 B3.30).
pub const pend_sv: u16 = 14;

pub const Kind = enum { before, idle, thread, exception };

/// What time is charged to: a thread by its control block, an exception
/// by its number, or idle or `before` with no id.
pub const Owner = struct {
    kind: Kind,
    id: u32 = 0,

    fn eql(self: Owner, other: Owner) bool {
        return self.kind == other.kind and self.id == other.id;
    }
};

pub const Slot = struct {
    owner: Owner,
    ticks: u64 = 0,
};

/// One core's running state and totals.
pub const Core = struct {
    since: u64 = 0,
    thread: Owner = .{ .kind = .before },
    stack: [limits.depth]u16 = undefined,
    depth: usize = 0,
    /// The depth of the PendSV a scheduler is idling in, or 0 for none.
    waiting: usize = 0,
    slots: [limits.slots]Slot = undefined,
    len: usize = 0,
    /// Ticks owed to owners past `limits.slots`.
    other: u64 = 0,

    fn running(self: *const Core) Owner {
        if (self.depth == 0) return self.thread;
        if (self.waiting == self.depth) return .{ .kind = .idle };
        const top = @min(self.depth, limits.depth) - 1;
        return .{ .kind = .exception, .id = self.stack[top] };
    }

    fn add(self: *Core, owner: Owner, ticks: u64) void {
        if (ticks == 0) return;
        for (self.slots[0..self.len]) |*one| {
            if (one.owner.eql(owner)) {
                one.ticks += ticks;
                return;
            }
        }
        if (self.len == limits.slots) {
            self.other += ticks;
            return;
        }
        self.slots[self.len] = .{ .owner = owner, .ticks = ticks };
        self.len += 1;
    }

    fn take(self: *Core, one: rtos_trace.Event) void {
        switch (one.kind) {
            .switch_to => {
                self.thread = .{ .kind = .thread, .id = one.thread };
                self.waiting = 0;
            },
            .idle => {
                self.thread = .{ .kind = .idle };
                if (self.innermost() == pend_sv) self.waiting = self.depth;
            },
            .enter => {
                if (self.depth < limits.depth) self.stack[self.depth] = one.exception;
                self.depth += 1;
            },
            .leave => {
                if (self.waiting == self.depth) self.waiting = 0;
                self.depth -|= 1;
            },
        }
    }

    /// The innermost active exception's number, or null in Thread mode.
    fn innermost(self: *const Core) ?u16 {
        if (self.depth == 0) return null;
        return self.stack[@min(self.depth, limits.depth) - 1];
    }
};

/// The stretch of virtual time a load is charged over, [from, to).
pub const Window = struct {
    from: u64 = 0,
    to: u64 = std.math.maxInt(u64),
};

pub const Load = struct {
    from: u64 = 0,
    to: u64 = std.math.maxInt(u64),
    cores: [limits.cores]Core = .{ .{}, .{} },

    /// Take one trace event. Events for one core must come in time order.
    pub fn feed(self: *Load, one: rtos_trace.Event) void {
        self.charge(one.core, one.when);
        self.cores[one.core].take(one);
    }

    /// Charge every core up to `now`, as the run ends.
    pub fn finish(self: *Load, now: u64) void {
        for (0..limits.cores) |index| self.charge(@intCast(index), now);
    }

    /// The owners one core's time went to, in the order first charged.
    pub fn rows(self: *const Load, core: u1) []const Slot {
        const one = &self.cores[core];
        return one.slots[0..one.len];
    }

    /// Every tick charged on one core, `other` included.
    pub fn total(self: *const Load, core: u1) u64 {
        const one = &self.cores[core];
        var sum: u64 = one.other;
        for (one.slots[0..one.len]) |slot| sum += slot.ticks;
        return sum;
    }

    fn charge(self: *Load, core: u1, now: u64) void {
        const one = &self.cores[core];
        const start = @max(one.since, self.from);
        const end = @min(now, self.to);
        if (end > start) one.add(one.running(), end - start);
        if (now > one.since) one.since = now;
    }
};
