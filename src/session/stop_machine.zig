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
const break_table = @import("break_table.zig");
const breakpoint = @import("breakpoint.zig");
const watch_table = @import("watch_table.zig");
const fpb = @import("fpb.zig");
const dwt = @import("ra8_chip").periph.dwt;
const itm = @import("ra8_chip").periph.itm;
const dcb = @import("ra8_chip").periph.dcb;

/// What the CPU is about to execute, as the driver sees it.
pub const Event = struct {
    /// The instruction's own address.
    pc: u32,
    /// Its width in bytes, two or four on Thumb.
    size: u8,
    /// The stack pointer as it stands before the instruction runs.
    sp: u32,
    /// Whether the instruction is a call (BL, BLX). Decoding belongs to the
    /// driver, which already has the instruction in hand.
    call: bool = false,
};

/// How the session is moving, as the last command set it.
pub const Mode = enum { halted, running, step, step_over, step_out };

/// Why the session stopped. Everything above this file reports one of these.
pub const Stop = union(enum) {
    /// A single step, a step over or a step out finished.
    stepped,
    /// A break counted the arrival it was waiting for.
    breakpoint: break_table.Id,
    /// A watched range was read or written. The access has happened and
    /// the instruction that made it has retired, the way GDB reports one.
    watchpoint: watch_table.Hit,
    /// Someone asked the running session to halt.
    halt_requested,
    /// A comparator the firmware programmed into the core's own FPB
    /// matched, by index.
    unit_break: usize,
    /// A DWT comparator the firmware set to raise a debug event matched,
    /// by index. A data match is reported once its instruction retired.
    unit_watch: usize,
};

/// The point a step over or a step out is running to.
const Target = struct {
    pc: u32,
    /// The stack pointer the target must be reached at or above. A
    /// recursive call reaches the same return address on a deeper frame,
    /// with a lower stack pointer, and must not end the step.
    sp: u32,
};

/// What a unit event that did not halt would take DebugMonitor for.
pub const Monitor = enum { breakpoint, watchpoint };

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
    /// A watch tripped during the instruction that just ran. It is reported
    /// before the next one, so the stop lands after the access, never
    /// halfway through the instruction that made it.
    watch_pending: ?watch_table.Hit = null,
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
            self.watch_pending == null and self.unit_pending == null and
            self.monitor_pending == null and self.breaks.len == 0 and
            self.watches.len == 0 and !self.fpb.enabled and !dwtArmed(&self.dwt);
    }

    /// Decide on the instruction about to run. A returned stop means the
    /// driver must stop the CPU now, before this instruction executes.
    pub fn onInstruction(self: *Machine, event: Event) ?Stop {
        if (self.mode == .halted) return null;
        if (self.resumed) {
            self.resumed = false;
            self.armFrom(event);
            return null;
        }
        if (self.watch_pending) |tripped| return self.halt(.{ .watchpoint = tripped });
        if (self.unit_pending) |index| {
            if (self.unitEvent(.{ .unit_watch = index })) |stop| return stop;
        }
        if (self.halt_pending) return self.halt(.halt_requested);
        if (self.breaks.hit(event.pc)) |id| return self.halt(.{ .breakpoint = id });
        if (self.fpb.matches(event.pc)) |index| {
            if (self.unitEvent(.{ .unit_break = index })) |stop| return stop;
        }
        if (self.dwt.matchesPc(event.pc)) |index| {
            if (self.unitEvent(.{ .unit_watch = index })) |stop| return stop;
        }
        return switch (self.mode) {
            .halted, .running => null,
            .step => self.halt(.stepped),
            .step_over, .step_out => if (self.reached(event)) self.halt(.stepped) else null,
        };
    }

    /// Hand the machine a bus access made by the instruction now running,
    /// with the value it moved when known. The stop it may cause is
    /// reported on the next `onInstruction`.
    pub fn onAccess(self: *Machine, address: u32, width: u8, access: watch_table.Access, value: ?u32) void {
        if (self.mode == .halted) return;
        if (self.dwt.access(address, width, access, value)) |index| {
            if (self.unit_pending == null) self.unit_pending = index;
        }
        if (self.watch_pending != null) return;
        self.watch_pending = self.watches.hit(address, width, access);
    }

    /// A comparator matched on something other than an address: the Cycle
    /// Counter. The stop it may cause is reported on the next
    /// `onInstruction`.
    pub fn onUnitMatch(self: *Machine, index: usize) void {
        if (self.mode == .halted) return;
        if (self.unit_pending == null) self.unit_pending = index;
    }

    /// The monitor event the last instruction raised, once.
    pub fn takeMonitor(self: *Machine) ?Monitor {
        defer self.monitor_pending = null;
        return self.monitor_pending;
    }

    /// A unit event halts with halting debug on; otherwise it is held for
    /// DebugMonitor and the core runs on.
    fn unitEvent(self: *Machine, why: Stop) ?Stop {
        if (self.halting) return self.halt(why);
        self.unit_pending = null;
        self.monitor_pending = if (why == .unit_break) .breakpoint else .watchpoint;
        return null;
    }

    fn start(self: *Machine, mode: Mode, target: ?Target) void {
        self.mode = mode;
        self.resumed = true;
        self.halt_pending = false;
        self.watch_pending = null;
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
        self.watch_pending = null;
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
