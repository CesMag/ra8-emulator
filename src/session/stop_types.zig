//! Stop reasons, execution modes and machine events for stop_machine.zig.
const break_table = @import("breaks/table.zig");
const watch_table = @import("watch/table.zig");

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

/// Which recorded host source a replay could not serve.
pub const ReplaySource = enum(u8) { camera = 1, usbip = 2, c6 = 3 };

/// A determinism error a replay hit: the source that had nothing, or
/// something other than what was recorded, for the machine, and why.
pub const ReplayFailure = struct { source: ReplaySource, err: anyerror };

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
    /// A backward run reached the beginning of the recorded history: no
    /// earlier canonical stop exists on this line (RA8EMU-1196).
    history_start,
    /// A replay hit a determinism error in a recorded host source; the
    /// machine past this point is not the recorded one.
    replay_failed: ReplayFailure,
};

/// The point a step over or a step out is running to.
pub const Target = struct {
    pc: u32,
    /// The stack pointer the target must be reached at or above. A
    /// recursive call reaches the same return address on a deeper frame,
    /// with a lower stack pointer, and must not end the step.
    sp: u32,
};

/// What a unit event that did not halt would take DebugMonitor for.
pub const Monitor = enum { breakpoint, watchpoint };

/// One arrival a slot collected, in the order it happened, so a stop's
/// hit set is never narrowed to the single cause that ended the run.
pub const Arrival = union(enum) {
    watch: watch_table.Hit,
    unit_break: usize,
    unit_watch: usize,
    halt,
    breakpoint: break_table.Id,
    step,
};

/// How many arrivals one hit set keeps. A store-multiple against a full
/// watch table can pass this; past it `hits_overflow` is set instead of
/// an arrival silently dropped, since every count still lands in its table.
pub const hit_capacity: usize = 64;

/// The most DWT comparators one access can match: NUMCOMP is four bits.
pub const dwt_capacity: usize = 16;
