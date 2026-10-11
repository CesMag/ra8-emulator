//! The run loop that drives both cores (ADR 0004 section 3, RA8EMU-1071).
//! It wires the board's time, the RTOS tracer, the watch, the stack profile
//! and the ITM console around boot.start, and leaves the result in a Loop
//! for the application to report. The CLI's adapter is
//! src/interfaces/cli/zig_run.zig.
const std = @import("std");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const boot = @import("ra8_chip").core.cpu.boot;
const choice = @import("ra8_chip").core.cpu.choice;
const systick_cut = @import("ra8_chip").core.cpu.cpu.systick_cut;
const second_core = @import("ra8_chip").core.second_core;
const Until = @import("ra8_chip").core.until.Until;
const Stop = @import("ra8_chip").core.stop.Stop;
const Deadline = @import("ra8_chip").core.deadline.Deadline;
const clocks = @import("ra8_chip").periph.clocks;
const elf = @import("ra8_board").image.elf;
const Board = @import("ra8_board").board.Board;
const RunPolicy = @import("run_policy.zig").RunPolicy;
const fault_file = @import("fault_file.zig");
const rtos_hook = @import("rtos_hook.zig");
const rtos_load = @import("rtos_load.zig");
const profile = @import("profile.zig");
const stack_profile = @import("stack_profile.zig");
const zig_watch = @import("zig_watch.zig");
const soak_symbols = @import("soak_symbols.zig");
const itm_console = @import("itm_console.zig");
const break_sym = @import("zig_break.zig");
const undefined_sites = @import("zig_undefined.zig");
const zig_snapshot = @import("zig_snapshot.zig");
const state_options = @import("state_options.zig");
const run_clock = @import("run_clock.zig");
const wall = @import("zig_wall.zig");

pub const Clock = run_clock.Clock;

/// What ends a run before its budget: the `--stop-sym` counter and the
/// `--break-sym` arrival (RA8EMU-603).
pub const Ends = struct {
    stop: ?*Stop = null,
    point: ?*break_sym.Break = null,
    /// The `--ms` window, read against the clocks' SysTick periods.
    timed: ?*Deadline = null,
    /// The swept sites `--stop-on-undefined` ends the run on.
    undefined_sites: ?*undefined_sites.Found = null,
    /// The `--faults FILE` schedule, applied at its virtual times (RA8EMU-207).
    schedule: ?*fault_file.Applier = null,
    /// `--speed` and `--run-for`, attached to the board (RA8EMU-1047).
    policy: ?*RunPolicy = null,
};

/// What the loop reads from the application's options.
pub const Options = struct {
    cpu: choice.Choice = .zig,
    blocks: bool = true,
    rtos: ?rtos_load.Window = null,
    watch_place: ?[]const u8 = null,
    idle_skip: bool = true,
    state: state_options.Options = .{},
    console: bool = false,
    bus_errors: bool = true,
    budget: usize,
};

/// One run, left for the application to read once `run` returns.
pub const Loop = struct {
    clock: Clock = undefined,
    tracer: ?rtos_hook.Tracer = null,
    watcher: zig_watch.Recorder = .{},
    retire: break_sym.Retire = .{},
    final: boot.Regs = .{},
    ran: u64 = 0,
    status: u8 = 0,

    /// Run `image` from `vector_base` until its budget or one of `ends`.
    /// `said` takes the boot lines and `out` the ITM console. `cpu1` is the
    /// second core the application brought up, or null.
    pub fn run(self: *Loop, said: anytype, out: *std.Io.Writer, io: std.Io, memory: Guest, board: *Board, timebase: *clocks.Clocks, image: elf.Image, options: Options, vector_base: u32, profile_table: ?*profile.Table, until: ?*Until, cpu1: ?*second_core.zig_run.Driver, ends: Ends) !void {
        self.clock = .{ .io = io, .memory = memory, .board = board, .timebase = timebase, .stop = ends.stop, .point = ends.point, .timed = ends.timed, .undefined_sites = ends.undefined_sites, .policy = ends.policy, .idle_skip = options.idle_skip, .state = options.state, .cpu1 = cpu1 };
        const clock = &self.clock;
        var cut: systick_cut.Cut = .{ .clocks = .{ timebase, &clock.ns_timebase } };
        if (ends.policy) |asked| if (asked.soak.armed) soak_symbols.resolve(image, &asked.soak.threads);
        // --trace-rtos listens in front of the core (src/session/rtos_zig.zig).
        self.tracer = if (options.cpu == .zig) rtos_hook.resolve(image, options.rtos) else null;
        var listener: rtos_hook.zig.Listener = undefined;
        if (self.tracer) |*found| {
            found.now = &timebase.ticks;
            listener = .{ .tracer = found };
        }
        const wrap = self.watcher.arm(image, options.watch_place, if (self.tracer != null) listener.wrap() else null, &timebase.ticks);
        self.retire = .{ .table = profile_table, .point = ends.point };
        var stacks = stack_profile.Run.of(profile_table, image, options.budget, &clock.wall_cycles, if (self.tracer) |*found| &found.trace else null);
        var itm_port = itm_console.opened(); // --console opens the ITM as a probe would (RA8EMU-629)
        if (options.console) try itm_console.prime(clock.memory, &itm_port);
        self.status = try boot.start(said, options.cpu, clock.memory.asInitiator(.cpu0), &board.bus, vector_base, options.budget, &self.ran, .{
            .boundary = try fault_file.boundary(ends.schedule, clock.boundary()),
            .partitions = &board.partitions,
            .idau = &board.idau,
            .regions = &board.regions,
            .regions_ns = &board.regions_ns,
            .clears = &board.clears,
            .cut = &cut,
            .fast_memory = options.watch_place == null and wrap == null,
            .blocks = options.blocks,
            .wrap = wrap,
            .retire_listener = stacks.listener(self.watcher.listener(self.retire.listener())),
            .core = stacks.lend(if (cpu1) |second| &second.core.cpu else null),
            .fetch_guard = if (ends.undefined_sites) |found| undefined_sites.guard(found) else null,
            .until = if (options.cpu == .zig) until else null,
            .final = &self.final,
            .itm = if (options.console) &itm_port else null,
            .bus_errors = if (options.bus_errors) &clock.bus_tally else null,
            .snapshot = zig_snapshot.hook(clock),
            .peer = if (cpu1) |second| &second.core.cpu else null,
        });
        try wall.finish(clock, self.ran);
        if (options.console) try itm_port.flush(out, true);
    }
};
