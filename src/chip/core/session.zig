//! What runs alongside the core for the length of one run.
//!
//! A run is not just a core and a budget. Modelled time has to be charged,
//! a controller has to get its turn at each boundary, the board's blocks
//! have to tick, and a handful of watches (a counter, a console line,
//! a deadline) have to be given the chance to end it. All of that is optional
//! and none of it belongs to the core, so it is gathered here and handed to
//! `Engine.run` as one value rather than a growing argument list.
//!
//! Everything is off by default: a bare `.{}` is one uninterrupted stretch
//! of execution with no modelled time and no exceptions, which is what the
//! loader and the smaller tests want. Every field is a pointer rather than
//! a copy, so the caller still owns the thing and can ask it afterwards
//! what happened during the run.
const clocks = @import("../periph/clocks.zig");
const nvic = @import("../periph/nvic/nvic.zig");
const mpu_guard = @import("mpu_guard.zig");
const reboot = @import("reboot.zig");
const stop = @import("stop.zig");
const until = @import("until.zig");
const undefined_ops = @import("undefined_ops.zig");
const fault = @import("fault.zig");
const idle = @import("idle.zig");
const bus_fault = @import("../periph/bus_fault.zig");

/// Records the invalid access behind a fault.
pub const Watch = fault.Watch;

/// The board's chunk-boundary hook.
pub const Tick = @import("tick.zig").Tick;

pub const Session = struct {
    /// Records the invalid access behind a fault.
    watch: ?*Watch = null,
    /// Charged one chunk of time per chunk of execution.
    timebase: ?*clocks.Clocks = null,

    /// An explicit boundary width, from `--chunk`, overriding the time
    /// base's own. Null leaves the cadence where it was. This exists to
    /// test whether a result depends on where the boundaries fall, so it
    /// deliberately outranks the clock: see cadence.configuredFrom.
    per_boundary: ?u32 = null,
    /// Consulted at each chunk boundary for an exception to take.
    interrupts: ?*nvic.Nvic = null,
    /// Run at each chunk boundary, before the controller picks: the
    /// peripheral side of a tick, where a block that has something to raise
    /// raises it. The board hands one in; the engine only calls it.
    board: ?Tick = null,
    /// Where a reset request the board took at the boundary is left for the
    /// engine to perform. A reset resets the core, and the core is the
    /// engine's, so the board asks and this loop does it.
    reboot: ?*reboot.Reboot = null,
    /// A counter in RAM to watch, and the floor that ends the run once it
    /// gets there. Null watches nothing. A pointer rather than a copy so
    /// the caller can ask afterwards whether the stop was what ended it.
    stop: ?*stop.Stop = null,
    /// A console line to wait for (`--until`). Null waits for none.
    until: ?*until.Until = null,
    /// MPU enforcement: the traps over the read-only regions, and the store
    /// one of them caught. Null runs with the table captured but nothing
    /// checked against it, which is every test that does not program one.
    protection: ?*mpu_guard.Guard = null,
    /// Proves a stretch of execution cannot change anything, so it can be
    /// charged to the clocks without being run. Null executes every
    /// instruction, which is what every test that is not about the seam
    /// wants. src/chip/core/idle.zig says what has to hold before one is
    /// skipped.
    idle: ?*idle.Seam = null,

    /// The swept undefined sites, when reaching one should end the run.
    /// Null runs past them and only counts, which is the default: the
    /// sweep reports, it does not decide.
    undefined_sites: ?*undefined_ops.Found = null,
};
