//! Thread switches as a trace, from stores to ThreadX's current-thread
//! pointer (RA8EMU-222).
//!
//! ThreadX names the running thread in `_tx_thread_current_ptr`: the
//! scheduler writes the next thread's control block there as it switches,
//! and zero while no thread runs. A store of a new value is a switch, a
//! store of zero is idle, and a store of the value already there is no
//! switch at all, so it is not recorded.
//!
//! Exception entry and return go in the same trace (RA8EMU-224), so a
//! switch reads between the PendSV that made it and the return after.
//!
//! This file knows nothing about the core. Whatever sees the
//! store hands it the core, the virtual time and the value; the hook that
//! does so is RA8EMU-221.
const rtos_load = @import("load.zig");

pub const limits = struct {
    /// Events kept, oldest first. A run that switches more than this keeps
    /// the opening and counts the rest, so the memory a trace costs is
    /// fixed however long the run goes.
    pub const kept: usize = 256;
    /// Cores the RA8 parts have: CPU0 and CPU1.
    pub const cores: usize = 2;
};

pub const Kind = enum { switch_to, idle, enter, leave };

/// One change of the running thread, or one exception entered or returned
/// from, on one core.
pub const Event = struct {
    /// Virtual time as the store landed, in the run's timebase.
    when: u64,
    core: u1,
    kind: Kind,
    /// The control block now running; zero for idle and for exceptions.
    thread: u32 = 0,
    /// The exception entered or returned from; zero for thread events.
    exception: u16 = 0,
};

pub const Trace = struct {
    events: [limits.kept]Event = undefined,
    len: usize = 0,
    /// Events past `limits.kept`, counted and not kept.
    dropped: usize = 0,
    /// What each core last stored, so a repeat is not taken for a switch.
    current: [limits.cores]?u32 = .{ null, null },
    /// CPU load, fed every event, kept ones and dropped ones alike
    /// (RA8EMU-267), so `--cpu-load` covers the whole run.
    load: rtos_load.Load = .{},
    /// The clock the load is charged in, borrowed: instructions retired on
    /// the traced core. Null charges in each event's own stamp, which is
    /// every unit test. The period clock is too coarse for load: a few
    /// SysTick periods cover millions of instructions.
    fine: ?*const u64 = null,

    /// Take one store to the current-thread pointer.
    pub fn store(self: *Trace, core: u1, when: u64, value: u32) void {
        if (self.current[core]) |was| {
            if (was == value) return;
        }
        self.current[core] = value;
        self.push(.{
            .when = when,
            .core = core,
            .kind = if (value == 0) .idle else .switch_to,
            .thread = value,
        });
    }

    /// Take one exception entered (`.enter`) or returned from (`.leave`).
    pub fn exception(self: *Trace, core: u1, when: u64, kind: Kind, number: u16) void {
        self.push(.{ .when = when, .core = core, .kind = kind, .exception = number });
    }

    fn push(self: *Trace, one: Event) void {
        var timed = one;
        if (self.fine) |clock| timed.when = clock.*;
        self.load.feed(timed);
        if (self.len == limits.kept) {
            self.dropped += 1;
            return;
        }
        self.events[self.len] = one;
        self.len += 1;
    }

    /// The load clock now: the borrowed fine clock, else `fallback`.
    pub fn loadNow(self: *const Trace, fallback: u64) u64 {
        return if (self.fine) |clock| clock.* else fallback;
    }

    /// The events kept, oldest first.
    pub fn list(self: *const Trace) []const Event {
        return self.events[0..self.len];
    }

    /// The events kept for one core, written into the caller's buffer.
    pub fn onCore(self: *const Trace, core: u1, into: []Event) []const Event {
        var count: usize = 0;
        for (self.list()) |one| {
            if (one.core != core) continue;
            if (count == into.len) break;
            into[count] = one;
            count += 1;
        }
        return into[0..count];
    }
};
