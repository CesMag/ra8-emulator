//! The stop machine fed from the Zig core (RA8EMU-105). The machine wants the machine each instruction before it
//! runs; here the debugger owns the loop, so it builds the same event,
//! asks the machine, and only then lets the core execute.
const std = @import("std");
const zig_core = @import("core.zig");
const stop_machine = @import("../stop_machine.zig");
const call_decode = @import("../call_decode.zig");
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const dispatch = @import("ra8_chip").core.cpu.exception.dispatch;
const watch_bus = @import("../watch/bus.zig");
const zig_cycles = @import("cycles.zig");
/// Re-exported for tests/session/zig/monitor_test.zig.
pub const zig_monitor = @import("monitor.zig");

/// How a driven run ended.
pub const Ended = union(enum) {
    /// The machine stopped the core before the instruction at the PC ran.
    stop: stop_machine.Stop,
    /// Every instruction allowed ran without a stop.
    count,
    /// The core itself stopped (an unknown encoding, a bus fault, ...).
    core: cpu_mod.Stop,
};

/// The event for the instruction under the PC: its address and width, SP before it runs, and whether it is a call.
pub fn event(core: zig_core.ZigCore) stop_machine.Event {
    const pc = core.register(.pc);
    const sp = core.register(.sp);
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    core.read(pc, bytes[0..2]) catch return .{ .pc = pc, .size = 2, .sp = sp };
    const width: u8 = if (wide(bytes[0..2].*)) 4 else 2;
    if (width == 4) core.read(pc +% 2, bytes[2..4]) catch {};
    return .{ .pc = pc, .size = width, .sp = sp, .call = call_decode.isCall(bytes[0..width]) };
}

/// A first halfword whose top five bits are 0b11101, 0b11110 or 0b11111
/// starts a 32-bit Thumb instruction.
fn wide(first: [2]u8) bool {
    return std.mem.readInt(u16, &first, .little) >> 11 >= 0b11101;
}

/// Run up to `count` instructions under the machine's current mode. A
/// pending exception is taken first, so the event describes the
/// instruction that is really about to run.
pub fn run(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64) Ended {
    return runWatched(core, machine, count, null);
}

/// As `run`, with `watch` listening to the loads and stores each
/// instruction makes (RA8EMU-113). It listens only while the instruction runs, so neither the
/// debugger's own reads nor the instruction's fetch count as an access.
pub fn runWatched(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus) Ended {
    return runClocked(core, machine, count, watch, null);
}

/// As `runWatched`, with `clock` counting DWT_CYCCNT for a Cycle Counter
/// comparator and recording each halt in DFSR (RA8EMU-172).
pub fn runClocked(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus, clock: ?*zig_cycles.Clock) Ended {
    var retired: u64 = 0;
    return runCounted(core, machine, count, watch, clock, &retired);
}

/// As `runClocked`, adding each instruction that ran to `retired`, so a
/// caller passing the board's boundary knows how far time moved
/// (RA8EMU-709).
pub fn runCounted(core: zig_core.ZigCore, machine: *stop_machine.Machine, count: u64, watch: ?*watch_bus.WatchBus, clock: ?*zig_cycles.Clock, retired: *u64) Ended {
    // The board moved, or the debugger wrote state, since the last chunk:
    // the poll asks the source afresh before trusting a hush again.
    if (core.cpu.quiet) |hushing| hushing.stirAll();
    var left = count;
    while (left > 0) {
        // Nothing armed: run as a plain run does. The watch bus stays armed
        // so firmware that programs the FPB or DWT still reaches them.
        if (machine.quiet()) {
            if (clock) |counting| counting.tick(core, machine);
            const went = quietRun(core, watch, left);
            retired.* += went.ran;
            left -= went.ran;
            if (went.stop) |stopped| return .{ .core = stopped };
            continue;
        }
        _ = dispatch.poll(core.cpu) catch return .{ .core = .{ .bus_fault = core.register(.pc) } };
        if (clock) |counting| counting.tick(core, machine);
        const now = event(core);
        const stop = machine.onInstruction(now);
        // A unit event with halting off pends DebugMonitor, as step_hook does.
        zig_monitor.take(core, machine);
        if (stop) |why| {
            if (clock) |counting| counting.halted(core, machine, why);
            return .{ .stop = why };
        }
        if (watch) |listening| listening.arm(now.pc, now.size);
        defer if (watch) |listening| listening.disarm();
        if (core.cpu.step()) |stopped| return .{ .core = stopped };
        retired.* += 1;
        left -= 1;
    }
    return .count;
}

/// What a quiet stretch did: instructions retired, and the core's own stop.
const Quiet = struct { ran: u64, stop: ?cpu_mod.Stop = null };

/// The rest of a chunk with nothing armed, through `Cpu.run`, so park loops
/// and trips that change nothing go by at once as in a plain run
/// (RA8EMU-712). A store into the PPB ends it, since it may arm the FPB or
/// DWT. A core asleep with nothing to wake it lets the rest of the chunk go
/// by as time, as a plain run charges a sleeping stretch to the clocks. A
/// core already waiting on a console line, or a stretch that moved nothing,
/// goes one instruction at a time instead.
fn quietRun(core: zig_core.ZigCore, watch: ?*watch_bus.WatchBus, left: u64) Quiet {
    const cpu = core.cpu;
    if (cpu.until != null) return quietOne(core, watch);
    const before = cpu.retired;
    if (watch) |listening| {
        listening.ppb = .{ .needle = "" };
        listening.arm(0, 0);
        listening.quiet = true;
        cpu.until = &listening.ppb;
    }
    defer if (watch) |listening| {
        listening.disarm();
        listening.quiet = false;
        cpu.until = null;
    };
    const stop = cpu.run(left);
    const ran = cpu.retired - before;
    if (stop != .count) return .{ .ran = ran, .stop = stop };
    if (cpu.waiting != null) return .{ .ran = left };
    if (ran == 0) return quietOne(core, watch);
    return .{ .ran = ran };
}

/// One quiet instruction, its interrupt poll first.
fn quietOne(core: zig_core.ZigCore, watch: ?*watch_bus.WatchBus) Quiet {
    core.cpu.trip.parked = false;
    _ = dispatch.poll(core.cpu) catch return .{ .ran = 0, .stop = .{ .bus_fault = core.register(.pc) } };
    if (quietStep(core, watch)) |stopped| return .{ .ran = 0, .stop = stopped };
    return .{ .ran = 1 };
}

/// One instruction with nothing to stop on. The fetch window is the widest
/// instruction at pc; no watch is set, so its exact width does not matter.
fn quietStep(core: zig_core.ZigCore, watch: ?*watch_bus.WatchBus) ?cpu_mod.Stop {
    if (watch) |listening| listening.arm(core.register(.pc), 4);
    defer if (watch) |listening| listening.disarm();
    return core.cpu.step();
}
