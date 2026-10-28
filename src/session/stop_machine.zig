//! The one place a debugging session decides whether to stop.
//!
//! Run, step one instruction, step over a call, step out of the current
//! function, continue, and halt on request are all the same question asked
//! before each instruction runs: does the session stop here. This file
//! answers it once, so the command layer, the GDB stub and the old one-off
//! flags all step the same way instead of each growing its own.
//!
//! It never touches the engine. Whatever drives the CPU (the Zig core's
//! own loop) hands it an `Event` before
//! each instruction and stops the CPU when it says so. Stopping before the
//! instruction leaves the program counter on it, which is what makes a
//! reported stop address the instruction that has not run yet.
//!
//! Resuming is where steppers usually go wrong. The first instruction after
//! a resume is the one the session stopped on, and it must run: a break on
//! it would stop again without moving, and a single step that counted it
//! would never leave. So the first event after every resume is let through,
//! and only then does the machine start asking.
const break_table = @import("breaks/table.zig");
const breakpoint = @import("breakpoint.zig");
const watch_table = @import("watch/table.zig");
const fpb = @import("fpb.zig");
const dwt = @import("ra8_chip").periph.dwt;
const itm = @import("ra8_chip").periph.itm;
const dcb = @import("ra8_chip").periph.dcb;
const stop_types = @import("stop_types.zig");

pub const Event = stop_types.Event;
pub const Mode = stop_types.Mode;
pub const Stop = stop_types.Stop;
pub const ReplayFailure = stop_types.ReplayFailure;
pub const ReplaySource = stop_types.ReplaySource;
const Target = stop_types.Target;
pub const Monitor = stop_types.Monitor;
pub const Arrival = stop_types.Arrival;
pub const hit_capacity = stop_types.hit_capacity;
const dwt_capacity = stop_types.dwt_capacity;

pub const Machine = struct {
    breaks: break_table.Table = .{},
    watches: watch_table.Table = .{},
    /// The core's breakpoint unit, as the firmware programmed it.
    fpb: fpb.Fpb = .{},
    /// The core's DWT comparators, as the firmware programmed them.
    dwt: dwt.Dwt = .{},
    /// The core's ITM, and what the firmware printed through it.
    itm: itm.Itm = .{},
    /// The core's DHCSR, DCRSR and DCRDR, as the firmware sees them.
    dcb: dcb.Dcb = .{},
    unit_pending: ?usize = null,
    /// DHCSR.C_DEBUGEN: halting debug is on and a unit event halts. Off, the
    /// event is held in `monitor_pending` for the driver to pend
    /// DebugMonitor with, if DEMCR enables it.
    halting: bool = true,
    monitor_pending: ?Monitor = null,
    mode: Mode = .halted,
    /// Set by `resume`; cleared once the instruction resumed on has run.
    resumed: bool = false,
    halt_pending: bool = false,
    target: ?Target = null,
    /// The slot's collected arrivals, in the order they happened, the
    /// watch and unit ones waiting from the last slot. Cleared when a run
    /// starts or a stop is committed; frozen when a stop is chosen, so a
    /// report reads the whole hit set.
    hits: [hit_capacity]Arrival = undefined,
    hits_len: usize = 0,
    /// Set when a slot collected more arrivals than `hit_capacity`.
    hits_overflow: bool = false,
    /// How many buffered arrivals are unit events still undelivered; the
    /// monitor takes them back out, since they belong to no report.
    unit_held: usize = 0,
    /// Unit arrivals the monitor consumed in the `onInstruction` running.
    unit_taken: usize = 0,
    /// A second monitor cause the slot also raised, handed out after the
    /// first. Transient: a restore leaves the core halted.
    monitor_extra: ?Monitor = null,
    /// The next id a break or a watch gets. The two share one sequence per
    /// core, as gdb numbers them, so `delete N` names exactly one of either.
    next_id: u32 = 1,

    /// Add a break, numbered from the sequence breaks and watches share.
    pub fn addBreak(self: *Machine, point: breakpoint.Break) break_table.Error!break_table.Id {
        self.breaks.next_id = self.next_id;
        defer self.next_id = self.breaks.next_id;
        return self.breaks.add(point);
    }

    /// Add a watch, numbered from the same sequence as the breaks.
    pub fn addWatch(self: *Machine, watch: watch_table.Watch) watch_table.Error!watch_table.Id {
        self.watches.next_id = self.next_id;
        defer self.next_id = self.watches.next_id;
        return self.watches.add(watch);
    }

    /// Run until a break or a halt request, or one instruction when
    /// DHCSR.C_STEP is set.
    pub fn proceed(self: *Machine) void {
        self.start(if (self.dcb.stepping()) .step else .running, null);
    }

    /// Run from a fresh start rather than a resume: the first instruction
    /// is checked like any other, so a break on it counts its arrival.
    pub fn begin(self: *Machine) void {
        self.start(.running, null);
        self.resumed = false;
    }

    /// Run exactly one instruction.
    pub fn step(self: *Machine) void {
        self.start(.step, null);
    }

    /// Run one instruction, or the whole call when it is one. Whether it is
    /// a call is only known from the first event, so the target is set there.
    pub fn stepOver(self: *Machine) void {
        self.start(.step_over, null);
    }

    /// Run until the current function returns to `return_address` (its lr
    /// on entry) on the frame whose stack pointer is `sp` or above.
    pub fn stepOut(self: *Machine, return_address: u32, sp: u32) void {
        self.start(.step_out, .{ .pc = clear(return_address), .sp = sp });
    }

    /// Ask a running session to stop before its next instruction.
    pub fn requestHalt(self: *Machine) void {
        if (self.mode != .halted) self.halt_pending = true;
    }

    /// Halt between runs, with no instruction to wait for: gdb's interrupt
    /// arriving while a run spent its chunk.
    pub fn interrupt(self: *Machine) Stop {
        return self.halt(.halt_requested);
    }

    /// Nothing can stop the run or be recorded before the next instruction:
    /// running freely with no break, watch, comparator unit or pending stop.
    /// TRCENA alone only lets DWT_CYCCNT count, which the clocks do anyway,
    /// so it is quiet until a comparator is given something to match.
    /// Then `onInstruction` returns null and changes nothing, and no access
    /// the instruction makes can trip anything, so a driver may skip both.
    pub fn quiet(self: *const Machine) bool {
        return self.mode == .running and !self.resumed and !self.halt_pending and
            self.hits_len == 0 and self.unit_pending == null and
            self.monitor_pending == null and self.breaks.len == 0 and
            self.watches.len == 0 and !self.fpb.enabled and !dwtArmed(&self.dwt);
    }

    /// Decide on the instruction about to run. A returned stop means the
    /// driver must stop the CPU now, before this instruction executes.
    /// The stop's hit set keeps every arrival the slot collected, not just
    /// the cause that ended the run; an arrival is collected only when the
    /// decision reaches it, so nothing counts for an instruction a higher
    /// stop already claimed.
    pub fn onInstruction(self: *Machine, event: Event) ?Stop {
        if (self.mode == .halted) return null;
        if (self.resumed) {
            self.resumed = false;
            self.armFrom(event);
            return null;
        }
        const mark = self.hits_len;
        const overflow = self.hits_overflow;
        self.unit_taken = 0;
        if (self.halt_pending) self.record(.halt);
        if (self.firstWatch()) |tripped| return self.halt(.{ .watchpoint = tripped });
        if (self.unit_pending) |index| {
            if (self.unitEvent(.{ .unit_watch = index })) |stop| return stop;
        }
        if (self.halt_pending) return self.halt(.halt_requested);
        if (self.breaks.hit(event.pc)) |id| {
            self.record(.{ .breakpoint = id });
            return self.halt(.{ .breakpoint = id });
        }
        if (self.fpb.matches(event.pc)) |index| {
            self.record(.{ .unit_break = index });
            if (self.unitEvent(.{ .unit_break = index })) |stop| return stop;
        }
        if (self.dwt.matchesPc(event.pc)) |index| {
            self.record(.{ .unit_watch = index });
            if (self.unitEvent(.{ .unit_watch = index })) |stop| return stop;
        }
        const step_done = switch (self.mode) {
            .step => true,
            .step_over, .step_out => self.reached(event),
            else => false,
        };
        if (step_done) {
            self.record(.step);
            return self.halt(.stepped);
        }
        // Nothing stopped: monitor-consumed and in-call arrivals belong to
        // no report, so the slot's record starts clean.
        const delivered = self.unit_taken;
        self.hits_len = @min(self.hits_len -| delivered, mark -| delivered);
        self.hits_overflow = overflow;
        return null;
    }

    /// Hand the machine a bus access made by the instruction now running,
    /// with the value it moved when known. Every watch the access matches
    /// is collected, not just the first (X11), every DWT comparator match
    /// is held as a unit event, and with halting debug off a watch match
    /// pends the monitor instead. The stop lands on the next `onInstruction`;
    /// the return is the count for recorders that take the hit back.
    pub fn onAccess(self: *Machine, address: u32, width: u8, access: watch_table.Access, value: ?u32) usize {
        if (self.mode == .halted) return 0;
        var matched: [dwt_capacity]usize = undefined;
        const dwt_count = self.dwt.accessAll(address, width, access, value, &matched);
        for (matched[0..dwt_count]) |index| {
            if (self.unit_pending == null) self.unit_pending = index;
            self.record(.{ .unit_watch = index });
            self.unit_held += 1;
        }
        var found: [watch_table.limits.capacity]watch_table.Hit = undefined;
        const count = self.watches.collect(address, width, access, &found);
        for (found[0..count]) |hit| {
            if (self.halting) self.record(.{ .watch = hit }) else self.noteMonitor(.watchpoint);
        }
        return if (self.halting) count else 0;
    }

    /// A comparator matched on something other than an address: the Cycle
    /// Counter. The stop it may cause is reported on the next
    /// `onInstruction`.
    pub fn onUnitMatch(self: *Machine, index: usize) void {
        if (self.mode == .halted) return;
        if (self.unit_pending == null) self.unit_pending = index;
        self.record(.{ .unit_watch = index });
        self.unit_held += 1;
    }

    /// The slot's collected arrivals, in the order they happened.
    pub fn arrivals(self: *const Machine) []const Arrival {
        return self.hits[0..self.hits_len];
    }

    /// Whether a data hit from the last slot is waiting to be reported.
    pub fn pendingData(self: *const Machine) bool {
        return self.unit_pending != null or self.firstWatch() != null;
    }

    /// Take the last `count` arrivals back out, keeping the run going.
    pub fn dropLast(self: *Machine, count: usize) void {
        self.hits_len -= @min(count, self.hits_len);
    }

    fn record(self: *Machine, arrival: Arrival) void {
        if (self.hits_len == hit_capacity) {
            self.hits_overflow = true;
            return;
        }
        self.hits[self.hits_len] = arrival;
        self.hits_len += 1;
    }

    /// The earliest unreported watch arrival, the one that ends the run.
    fn firstWatch(self: *const Machine) ?watch_table.Hit {
        for (self.hits[0..self.hits_len]) |arrival| switch (arrival) {
            .watch => |hit| return hit,
            else => {},
        };
        return null;
    }

    /// The monitor events the last instruction raised, one per call, in
    /// the order they happened. A slot that raises both an FPB break and a
    /// DWT watch hands out both, so a monitor never sees only the first.
    pub fn takeMonitor(self: *Machine) ?Monitor {
        const cause = self.monitor_pending orelse return null;
        self.monitor_pending = self.monitor_extra;
        self.monitor_extra = null;
        return cause;
    }

    /// A unit event halts with halting debug on; otherwise it is held for
    /// DebugMonitor and the core runs on.
    fn unitEvent(self: *Machine, why: Stop) ?Stop {
        if (self.halting) return self.halt(why);
        self.unit_pending = null;
        self.unit_taken = self.unit_held;
        self.unit_held = 0;
        self.noteMonitor(if (why == .unit_break) .breakpoint else .watchpoint);
        return null;
    }

    /// Hold a monitor cause, keeping a second distinct one for the next
    /// take. The same cause twice needs no second slot.
    fn noteMonitor(self: *Machine, cause: Monitor) void {
        if (self.monitor_pending == null) {
            self.monitor_pending = cause;
        } else if (self.monitor_extra == null and self.monitor_pending.? != cause) {
            self.monitor_extra = cause;
        }
    }

    fn start(self: *Machine, mode: Mode, target: ?Target) void {
        self.mode = mode;
        self.resumed = true;
        self.halt_pending = false;
        self.hits_len = 0;
        self.hits_overflow = false;
        self.unit_held = 0;
        self.unit_pending = null;
        self.target = target;
    }

    /// A step over of a call runs to the instruction after it; a step over
    /// of anything else is a single step.
    fn armFrom(self: *Machine, event: Event) void {
        if (self.mode != .step_over) return;
        if (event.call) {
            self.target = .{ .pc = clear(event.pc) + event.size, .sp = event.sp };
        } else {
            self.mode = .step;
        }
    }

    fn reached(self: *const Machine, event: Event) bool {
        const target = self.target orelse return true;
        return clear(event.pc) == target.pc and event.sp >= target.sp;
    }

    fn halt(self: *Machine, why: Stop) Stop {
        self.mode = .halted;
        self.halt_pending = false;
        self.unit_pending = null;
        self.target = null;
        return why;
    }
};

fn clear(address: u32) u32 {
    return address & ~breakpoint.limits.thumb_bit;
}

/// Whether a DWT comparator can match: TRCENA on and one of the core's
/// comparators given a MATCH code (RA8EMU-712).
fn dwtArmed(unit: *const dwt.Dwt) bool {
    if (!unit.trcena) return false;
    for (unit.functions[0..unit.numcomp]) |function| {
        if (function & dwt.function_bits.match_mask != 0) return true;
    }
    return false;
}
