//! The board side of a Zig-core run's boundary: how wide each stretch is,
//! when the run is done, and closing each stretch onto the board's clocks
//! (src/session/zig/wall.zig). The command line builds one per run
//! (src/interfaces/cli/zig/run.zig) and hands the core its boundary.
const std = @import("std");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const boot = @import("ra8_chip").core.cpu.boot;
const clocks = @import("ra8_chip").periph.clocks;
const soak_fault = @import("run.zig").soak.fault;
const bus_fault = @import("ra8_chip").periph.bus_fault;
const systick_bank = @import("ra8_chip").core.systick_bank;
const scs_route = @import("ra8_chip").core.cpu.scs_route;
const sleep_pace = @import("ra8_chip").core.sleep_pace;
const board_edge = @import("ra8_board").boundary;
const core_clock = @import("ra8_board").core_clock;
const quiet_due = @import("ra8_board").quiet_due;
const Board = @import("ra8_board").board.Board;
const second_core = @import("ra8_chip").core.second.core;
const RunPolicy = @import("policy.zig").RunPolicy;
const Stop = @import("ra8_chip").core.stop.Stop;
const Deadline = @import("ra8_chip").core.deadline.Deadline;
const clock_rate = @import("../zig/clock_rate.zig");
const break_sym = @import("../zig/break_sym.zig");
const undefined_sites = @import("../zig/undefined_sites.zig");
const state_options = @import("../state_options.zig");
const wall = @import("../zig/wall.zig");

/// The board side of a Zig-core boundary.
pub const Clock = struct {
    io: std.Io,
    /// The memory the clocks, the board tick and the reports read and write.
    memory: Guest,
    board: *Board,
    timebase: *clocks.Clocks,
    /// The run's pacing and soak (RA8EMU-1047), or null for a bare run.
    policy: ?*RunPolicy = null,
    /// CPU0's Non-secure SysTick (RA8EMU-449). Only its timer is charged:
    /// DWT_CYCCNT and the run's own count belong to `timebase`.
    ns_timebase: clocks.Clocks = .{ .words = systick_bank.non_secure_words },
    /// CPU1 on its Zig core under --cpu zig --cpu1, or null (RA8EMU-234).
    cpu1: ?*second_core.zig.run.Driver = null,
    /// The `--stop-sym` counter, read at each boundary (RA8EMU-603).
    stop: ?*Stop = null,
    /// The `--break-sym` arrival, which ends the run once met.
    point: ?*break_sym.Break = null,
    /// The `--ms` window, which ends the run once modelled time runs out.
    timed: ?*Deadline = null,
    undefined_sites: ?*undefined_sites.Found = null,
    /// The BusFaults a `--bus-errors` run raised (RA8EMU-641).
    bus_tally: bus_fault.Tally = .{},
    /// `--idle-skip`: a sleeping CPU0 runs straight to the next edge (RA8EMU-185).
    idle_skip: bool = false,
    /// `--save-state` / `--load-state` (RA8EMU-696): zig_snapshot.zig.
    state: state_options.Options = .{},
    resume_boundary: bool = false,
    resume_unscaled: bool = false,
    /// Rates selected when the current boundary opened.
    boundary_hz: ?u64 = null,
    cycle_remainder: u64 = 0,
    /// Common 1 ns external-memory fabric time and retired instructions
    /// already closed into it.
    wall_cycles: u64 = 0,
    accounted: u64 = 0,

    pub fn boundary(self: *Clock) boot.Boundary {
        return .{ .context = self, .widthFn = widthThunk, .closeFn = closeThunk, .abortFn = abortThunk, .cyclesFn = cyclesThunk, .reboot = self.board.reboot, .doneFn = doneThunk, .sleepFn = if (self.idle_skip) sleepThunk else null };
    }

    /// A sleeping CPU0's width: to the nearest armed SysTick period, the
    /// board's next queued event, the panel's next vsync or the GPT's next
    /// wrap, turn or match. CPU1 shares each boundary, so a run with
    /// it keeps the normal width, as does a board with a block mid-work.
    /// The first edge at or inside `normal` settles it, so the rest are not
    /// looked up: a ticking image's stretch already ends at the tick (RA8EMU-730).
    pub fn asleepWidth(self: *Clock, normal: u32) u32 {
        if (self.cpu1 != null or !quiet_due.quietUntilDue(self.board)) return normal;
        var edges: [5]u64 = undefined;
        for (&edges, 0..) |*edge, which| {
            edge.* = self.instructionsForCycles(self.edgeCycles(which));
            if (edge.* != 0 and edge.* <= normal) return normal;
        }
        return sleep_pace.width(normal, true, &edges);
    }

    /// Cycles until edge `which` of the five `asleepWidth` weighs; 0 is none.
    fn edgeCycles(self: *Clock, which: usize) u64 {
        return switch (which) {
            0 => self.timebase.untilWrap(self.memory),
            1 => self.ns_timebase.untilWrap(self.memory),
            2 => board_edge.cyclesToDue(self.board),
            3 => quiet_due.vsyncDue(self.board),
            else => quiet_due.gptDue(self.board),
        };
    }

    /// Has a soak event (a watchdog reset, or a fault latched since the last
    /// boundary) ended the run, or the watched counter climbed to its floor? An unreadable word is not a stop
    /// (src/chip/core/stop.zig).
    pub fn done(self: *Clock) bool {
        self.soakFaults();
        if (self.policy) |asked| if (asked.soak.ended()) return true;
        if (self.point) |point| if (point.reached) return true;
        if (self.timed) |due| if (due.met(self.timebase.ticks)) return true;
        if (self.undefined_sites) |found| if (found.stoppedAt() != null) return true;
        const watch = self.stop orelse return false;
        return watch.met(self.memory.readWord(watch.address) catch null);
    }

    /// Note a fault the core latched, or a watched canary or guard word that
    /// changed (RA8EMU-619), as the soak's event, when it is armed and has
    /// none yet. Also asked once after the run, for a core that stopped
    /// inside a stretch and never reached its boundary.
    pub fn soakFaults(self: *Clock) void {
        const asked = self.policy orelse return;
        const soak = &asked.soak;
        if (!soak.armed or soak.ended()) return;
        const latched = soak_fault.words(self.memory, &landScs);
        if (soak_fault.kind(latched)) |fault| soak.note(fault, self.board.time.base.now());
        soak.check(self.memory, self.board.time.base.now());
    }
    /// The chunk, cut down so a stretch never swallows a SysTick wrap.
    pub fn width(self: *Clock) u32 {
        const period_cycles = systick_bank.width(self.timebase.period(self.memory), self.ns_timebase.period(self.memory));
        const period: u32 = @intCast(@min(self.instructionsForCycles(period_cycles), std.math.maxInt(u32)));
        if (period != 0 and period < self.timebase.per_chunk) return period;
        return self.timebase.per_chunk;
    }
    fn instructionsForCycles(self: *Clock, cycles: u64) u64 {
        if (cycles == 0 or !self.rateScaled()) return cycles;
        return clock_rate.instructions(cycles, self.boundary_hz.?, self.cycle_remainder);
    }
    pub fn rateScaled(self: *Clock) bool {
        if (self.boundary_hz != null) return true;
        if (self.resume_unscaled) return false;
        if (self.timed == null or systick_bank.width(self.timebase.period(self.memory), self.ns_timebase.period(self.memory)) == 0) return false;
        if (!self.resume_boundary) core_clock.retune(self.board);
        self.boundary_hz = self.board.time.base.hz;
        return true;
    }

    pub fn close(self: *Clock, instructions: u32) !void {
        return wall.close(self, instructions);
    }
};

/// Where the Zig core keeps an SCB word, read as Secure (src/chip/core/cpu/scs_route.zig).
fn landScs(address: u32) ?u32 {
    return switch (scs_route.land(null, address)) {
        .at => |at| at,
        .res0 => null,
    };
}

fn widthThunk(context: *anyopaque) u32 {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.width();
}

fn sleepThunk(context: *anyopaque, normal: u32) u32 {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.asleepWidth(normal);
}

fn doneThunk(context: *anyopaque) bool {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.done();
}

fn closeThunk(context: *anyopaque, instructions: u32) anyerror!void {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.close(instructions);
}

fn abortThunk(context: *anyopaque) void {
    const self: *Clock = @ptrCast(@alignCast(context));
    self.resume_boundary = false;
    self.resume_unscaled = false;
    self.boundary_hz = null;
}

fn cyclesThunk(context: *anyopaque, cycles: u64) u64 {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.instructionsForCycles(cycles);
}
