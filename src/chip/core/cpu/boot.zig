//! A run on the Zig core.
//!
//! The image is loaded and the board RAM mapped; the Zig core then resets out of the same vector table and runs until
//! its budget is spent or it meets something it cannot do yet, most often an
//! encoding no group in src/chip/core/cpu/ops/table.zig claims. This file prints
//! one line saying which, so a corpus sweep can tell how far each image
//! gets; main then prints the board's own report (report/run.zig, zigCore).
const std = @import("std");
const Guest = @import("memory/guest.zig").Guest;
const GuestBus = @import("memory/guest_bus.zig").GuestBus;
const BoardBus = @import("board_bus.zig").BoardBus;
const registry = @import("../../periph/registry.zig");
const cpu_mod = @import("cpu.zig");
const sleep_pace = @import("../sleep_pace.zig");
const Choice = @import("choice.zig").Choice;
const NvicSource = @import("exception/nvic_source.zig").NvicSource;
const QuietSource = @import("exception/quiet_source.zig").QuietSource;
const DecodeCache = @import("decode/cache.zig").DecodeCache;
const BlockCache = @import("block_cache.zig").BlockCache;
const sau = @import("../../periph/sau/sau.zig");
const SauSource = @import("sau_source.zig").SauSource;
const DataGate = @import("data_gate.zig").Gate;
const Attribution = @import("attribution.zig").Attribution;
const mpu = @import("../../periph/mpu/mpu.zig");
const fault_clear = @import("../../periph/fault_clear.zig");
const fault_status = @import("../../periph/fault_status.zig");
const bus_fault = @import("../../periph/bus_fault.zig");
const Bus = @import("bus.zig").Bus;
const code_lines = @import("code_lines.zig");
const exclusive_peer = @import("exclusive_peer.zig");
const FpState = @import("fpu/state.zig").State;
const mpu_check = @import("mpu_check.zig");
const Source = @import("exception/source.zig").Source;
const Until = @import("../until.zig").Until;
const Reboot = @import("../reboot.zig").Reboot;
/// The register file a `--cpu zig` run hands back when it ends.
pub const Regs = @import("regs.zig").Regs;

/// Where a `--cpu zig` run hands time back to the board. The core runs
/// `width` instructions, then `close` charges them: SysTick and DWT_CYCCNT
/// count, the blocks tick, and whatever they pend is taken by the core's
/// own NVIC poll before the next instruction. Without one nothing on the
/// board moves, and a ThreadX image idles forever waiting for its first tick.
pub const Boundary = struct {
    context: *anyopaque,
    widthFn: *const fn (context: *anyopaque) u32,
    closeFn: *const fn (context: *anyopaque, instructions: u32) anyerror!void,
    /// Discard boundary-local state when a SysTick rearm cuts a stretch.
    abortFn: ?*const fn (context: *anyopaque) void = null,
    /// Convert a cycle edge to the instruction width that reaches it. Null
    /// means the boundary charges one cycle per instruction.
    cyclesFn: ?*const fn (context: *anyopaque, cycles: u64) u64 = null,
    /// The reset a block asked for at this boundary (a watchdog underflow,
    /// AIRCR.SYSRESETREQ), performed before the next stretch (RA8EMU-508).
    reboot: ?*Reboot = null,
    /// Asked after each closed stretch whether the run is over, which is
    /// how `--stop-sym` ends a Zig run on its counter (RA8EMU-603).
    doneFn: ?*const fn (context: *anyopaque) bool = null,
    /// Handed the width a stretch would get while the core sleeps with
    /// nothing to wake it, and returns the width it gets (`--idle-skip`,
    /// RA8EMU-185). Null keeps every stretch at `widthFn`.
    sleepFn: ?*const fn (context: *anyopaque, normal: u32) u32 = null,
};

/// A debugger listening to a `--cpu zig` run: handed the bus and the
/// exception source the core would use, it returns the ones the core uses
/// instead (src/session/rtos_zig.zig, RA8EMU-261).
pub const Wrap = struct {
    context: *anyopaque,
    busFn: *const fn (context: *anyopaque, inner: Bus) Bus,
    sourceFn: *const fn (context: *anyopaque, inner: Source) Source,
    /// Lent the core's retired-instruction count for the run, so a listener
    /// can time what it sees per instruction (RA8EMU-284).
    retiredFn: ?*const fn (context: *anyopaque, retired: *const u64) void = null,
    /// Lent the core's registers for the run, so a listener can name who
    /// made an access (`--watch`'s lr, RA8EMU-639).
    regsFn: ?*const fn (context: *anyopaque, regs: *const Regs) void = null,
};

/// Save and restore for a `--cpu zig` run (RA8EMU-695): `loadFn` runs right
/// after the core resets, before its first instruction; `saveFn` runs once
/// the budget is spent. Each is handed the core, which lives only in runOn.
/// Both carry what the run owes its clocks (`Owed`, RA8EMU-700): a load
/// returns what the saved run owed, a save is handed what this one owes.
pub const Snapshot = struct {
    context: *anyopaque,
    loadFn: ?*const fn (context: *anyopaque, core: *cpu_mod.Cpu) anyerror!u32 = null,
    saveFn: ?*const fn (context: *anyopaque, core: *const cpu_mod.Cpu, owed: u32) anyerror!void = null,
    /// `--snapshot-at` (RA8EMU-769): asked after each closed stretch, where
    /// the run owes its clocks nothing, and `atFn` writes the run there.
    dueFn: ?*const fn (context: *anyopaque) bool = null,
    atFn: ?*const fn (context: *anyopaque, core: *const cpu_mod.Cpu) anyerror!void = null,
};

/// Instructions a stretch retired but has not charged to the clocks yet
/// (RA8EMU-700). A budget that ends inside a stretch would close it short,
/// which a straight run never does, so a run that saves holds that stretch
/// open (`hold`), saves what it owes (`out`), then closes it. A loaded run
/// starts `in` instructions into its first stretch, so its boundaries, and
/// every SysTick pend they carry, land where the straight run's do.
pub const Owed = struct { in: u32 = 0, hold: bool = false, out: u32 = 0 };

/// What the board hands a `--cpu zig` run besides its peripheral bus: the
/// boundary that moves time, the core-private SAU and MPU its stores bank
/// into, and the fault status words its stores clear.
pub const Wiring = struct {
    boundary: ?Boundary = null,
    /// A finished console line that ends the run at its next boundary.
    until: ?*Until = null,
    /// A listener put in front of the core's bus and exception source.
    wrap: ?Wrap = null,
    /// A listener called with the address of each retired instruction.
    retire_listener: ?cpu_mod.RetireListener = null,
    /// Asked before each instruction (`--stop-on-undefined`).
    fetch_guard: ?cpu_mod.FetchGuard = null,
    partitions: ?*sau.Sau = null,
    /// The part's IDAU map beside the SAU (RA8EMU-277).
    idau: ?*const sau.idau.Map = null,
    regions: ?*mpu.Mpu = null,
    /// The Non-secure MPU (RA8EMU-446), banked beside `regions`.
    regions_ns: ?*mpu.Mpu = null,
    clears: ?*fault_clear.Clears = null,
    /// The SysTick timers whose arming ends a stretch (RA8EMU-464).
    cut: ?*cpu_mod.systick_cut.Cut = null,
    /// Direct MRAM/SRAM access is enabled only when the run has no memory
    /// watch or fault instrumentation that must observe each access.
    fast_memory: bool = false,
    /// `--blocks`: run from formed blocks (RA8EMU-405).
    blocks: bool = false,
    /// Filled with the core's registers as the run left them, for the
    /// `--report json` register dump (RA8EMU-579).
    final: ?*Regs = null,
    /// CPU1's core: each core's stores clear the other's exclusive monitor
    /// (RA8EMU-134). Null on a single-core run.
    peer: ?*cpu_mod.Cpu = null,
    /// Filled with the core the run builds, before reset, and cleared when
    /// the run returns, for a retire listener that reads it (RA8EMU-971).
    core: ?*?*cpu_mod.Cpu = null,
    /// Port 0 of the ITM, kept as text on a plain run (RA8EMU-629).
    itm: ?*@import("../../periph/itm.zig").Itm = null,
    /// `--bus-errors`: a refused data and fetch accesses raise BusFaults,
    /// counted here (RA8EMU-641); null ends the run on them instead.
    bus_errors: ?*bus_fault.Tally = null,
    /// `--save-state` / `--load-state` (RA8EMU-660).
    snapshot: ?Snapshot = null,
};

/// The hand-off from main to the CPU the run asked for.
/// `periph` is the board's peripheral bus; a `--cpu zig` run reaches the
/// peripherals through it.
/// `ran` is set to how many instructions a `--cpu zig` run retired.
pub fn start(out: anytype, choice: Choice, memory: Guest, periph: ?*registry.Bus, vector_base: u32, budget: u64, ran: *u64, wiring: Wiring) !u8 {
    return switch (choice) {
        .zig => if (periph) |board| runOnBoard(out, memory, board, vector_base, budget, ran, wiring) else run(out, memory, vector_base, budget, wiring.retire_listener),
    };
}

/// Run the image already loaded into `memory` on the Zig core, print how it
/// ended, and return the exit status: 0 when the budget was spent, 1 when
/// the core stopped short of it.
pub fn run(out: anytype, memory: Guest, vector_base: u32, budget: u64, retire_listener: ?cpu_mod.RetireListener) !u8 {
    var reach = GuestBus.of(&memory, false);
    return runOn(out, reach.view(), vector_base, budget, null, null, null, .{ .retire = retire_listener }, null, null, false, null, null);
}

/// As `run`, with the peripheral windows answered by the board's bus.
pub fn runOnBoard(out: anytype, memory: Guest, periph: *registry.Bus, vector_base: u32, budget: u64, ran: ?*u64, wiring: Wiring) !u8 {
    var board: BoardBus = .{ .memory = GuestBus.of(&memory, wiring.fast_memory), .periph = periph, .scs = .{ .partitions = wiring.partitions, .regions = wiring.regions, .regions_ns = wiring.regions_ns, .clears = wiring.clears, .cut = wiring.cut, .itm = wiring.itm } };
    var partitions: SauSource = undefined;
    const source: ?Attribution = if (wiring.partitions) |unit| blk: {
        partitions = .{ .unit = unit, .idau = wiring.idau };
        break :blk partitions.source();
    } else null;
    return runOn(out, board.view(), vector_base, budget, ran, wiring.boundary, wiring.wrap, .{ .retire = wiring.retire_listener, .fetch = wiring.fetch_guard, .bus_errors = wiring.bus_errors, .snapshot = wiring.snapshot, .peer = wiring.peer, .core = wiring.core }, &board, source, wiring.blocks, wiring.until, wiring.final);
}

/// What the core reports to, per instruction: after it retires and before
/// it is fetched.
const Watch = struct { retire: ?cpu_mod.RetireListener = null, fetch: ?cpu_mod.FetchGuard = null, bus_errors: ?*bus_fault.Tally = null, snapshot: ?Snapshot = null, peer: ?*cpu_mod.Cpu = null, core: ?*?*cpu_mod.Cpu = null };

fn runOn(out: anytype, memory: Bus, vector_base: u32, budget: u64, ran: ?*u64, boundary: ?Boundary, wrap: ?Wrap, watch: Watch, board: ?*BoardBus, source: ?Attribution, blocks: bool, until: ?*Until, final: ?*Regs) !u8 {
    var pending: NvicSource = .{};
    // A wrapped run listens to every poll, so it keeps the plain one.
    var quiet: QuietSource = .{ .inner = pending.source(), .memory = memory };
    var cpu: cpu_mod.Cpu = if (wrap) |w|
        .{ .bus = w.busFn(w.context, memory), .source = w.sourceFn(w.context, pending.source()) }
    else
        .{ .bus = quiet.bus(), .source = quiet.source(), .quiet = &quiet };
    pending.banked = &cpu.banked;
    if (watch.peer) |other| exclusive_peer.pair(&cpu, other);
    defer if (watch.peer) |other| exclusive_peer.unpair(&cpu, other);
    var decoded: DecodeCache = .{};
    cpu.decoded = &decoded;
    const formed: ?*BlockCache = if (blocks) try std.heap.page_allocator.create(BlockCache) else null;
    defer if (formed) |cache| std.heap.page_allocator.destroy(cache);
    if (formed) |cache| {
        cache.init();
        try code_lines.watch(&cache.lines);
    }
    defer if (formed) |cache| code_lines.unwatch(&cache.lines);
    cpu.blocks = formed;
    cpu.retire_listener = watch.retire;
    if (watch.core) |slot| slot.* = &cpu;
    defer if (watch.core) |slot| {
        slot.* = null;
    };
    cpu.fetch_guard = watch.fetch;
    var miss: u32 = 0;
    if (watch.bus_errors) |tally| cpu.bus.tally = tally;
    if (watch.bus_errors != null) cpu.bus.miss = &miss;
    cpu.until = until;
    cpu.attribution = source;
    var check: mpu_check.Check = undefined;
    var gate: DataGate = undefined;
    if (source) |from| {
        gate = .{ .source = from, .current = &cpu.banked.current };
        cpu.bus.gate = &gate;
    }
    if (board) |b| {
        b.scs.fp = &cpu.fp;
        b.security = &cpu.banked;
        cpu.cut = b.scs.cut;
        if (b.scs.regions) |unit| {
            check = .{ .unit = unit, .unit_ns = b.scs.regions_ns, .state = &cpu.banked.current };
            b.armCheck(&check);
            cpu.mpu = &check;
        }
    }
    if (wrap) |w| if (w.retiredFn) |lend| lend(w.context, &cpu.retired);
    if (wrap) |w| if (w.regsFn) |lend| lend(w.context, &cpu.regs);
    cpu.reset(vector_base) catch {
        try out.print("zig core: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    var owed: Owed = .{ .hold = if (watch.snapshot) |hook| hook.saveFn != null else false };
    if (watch.snapshot) |hook| if (hook.loadFn) |load| {
        owed.in = try load(hook.context, &cpu);
    };
    const stopped = try stretches(&cpu, budget, boundary, until, &owed, watch.snapshot);
    if (watch.snapshot) |hook| if (hook.saveFn) |save| try save(hook.context, &cpu, owed.out);
    if (owed.out != 0) if (boundary) |edge| try edge.closeFn(edge.context, owed.out);
    if (ran) |count| count.* = cpu.retired;
    if (final) |into| into.* = cpu.regs;
    const code = try report(out, cpu, stopped);
    if (until) |wait| if (wait.reached) {
        try out.print("stopped clean on the console line \"{s}\", pc 0x{X:0>8}\n", .{ wait.needle, cpu.regs.pc });
    };
    if (board) |b| try fault_status.line(out, b.faults());
    return code;
}

/// The budget in stretches, each closed by the boundary. A stretch the core
/// stops inside is not closed: it never ran to its edge. `owed` carries a
/// stretch across a save and a load (RA8EMU-700).
pub fn stretches(cpu: *cpu_mod.Cpu, budget: u64, boundary: ?Boundary, until: ?*Until, owed: *Owed, snapshot: ?Snapshot) !cpu_mod.Stop {
    const edge = boundary orelse return cpu.run(budget);
    var left = budget;
    var carry = owed.in;
    while (left > 0) {
        const full = widthOf(cpu, edge);
        if (carry >= full) {
            try edge.closeFn(edge.context, carry);
            carry = 0;
            continue;
        }
        const width: u32 = @intCast(@min(left, full - carry));
        const stopped = cpu.run(width);
        if (until) |wait| if (wait.reached) return .count;
        if (stopped != .count) return stopped;
        // The firmware armed SysTick inside this stretch: charge it one instruction and no time, and cut the next
        // stretch from the period now armed (RA8EMU-464). What the stretch carried in goes uncharged with it,
        // so a loaded run hands those instructions back to its budget, as the run left whole never spent them (RA8EMU-701).
        if (cpu.cut) |cut| if (cut.take()) {
            if (edge.abortFn) |abort| abort(edge.context);
            left = left - 1 + carry;
            carry = 0;
            continue;
        };
        left -= width;
        if (left == 0 and owed.hold and carry + width < full) {
            owed.out = carry + width;
            return .count;
        }
        try edge.closeFn(edge.context, carry + width);
        carry = 0;
        if (edge.doneFn) |done| if (done(edge.context)) return .count;
        if (edge.reboot) |pending| if (pending.requested) try rebooted(cpu, pending);
        if (snapshot) |hook| try midway(hook, cpu);
    }
    return .count;
}

/// A `--snapshot-at` write, once its time has come (RA8EMU-769).
fn midway(hook: Snapshot, cpu: *const cpu_mod.Cpu) !void {
    const due = hook.dueFn orelse return;
    const write = hook.atFn orelse return;
    if (due(hook.context)) try write(hook.context, cpu);
}

/// The next stretch's width: the boundary's, reached to the next edge by
/// its `sleepFn` while the core sleeps with nothing to wake it.
fn widthOf(cpu: *cpu_mod.Cpu, edge: Boundary) u32 {
    const normal = @max(1, edge.widthFn(edge.context));
    const reach = edge.sleepFn orelse return normal;
    if (!sleep_pace.still(cpu)) return normal;
    return @max(normal, reach(edge.context, normal));
}

/// A warm reboot of the Zig core: SP and PC from the vector table, PRIMASK clear, handler frames
/// abandoned, RAM kept. The retired count is the run's, so it carries on.
fn rebooted(cpu: *cpu_mod.Cpu, pending: *Reboot) !void {
    pending.requested = false;
    pending.performed +%= 1;
    const retired = cpu.retired;
    try cpu.reset(pending.vector_base);
    cpu.retired = retired;
}

pub fn report(out: anytype, cpu: cpu_mod.Cpu, stopped: cpu_mod.Stop) !u8 {
    switch (stopped) {
        .count => {
            try out.print("zig core: ran {d} instructions clean, pc 0x{X:0>8}\n", .{ cpu.retired, cpu.regs.pc });
            return 0;
        },
        .unknown => |instr| try out.print(
            "zig core: unknown encoding at {f} after {d} instructions\n",
            .{ instr, cpu.retired },
        ),
        .invalid_state => |at| try out.print(
            "zig core: EPSR.T clear at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .bus_fault => |at| try out.print(
            "zig core: bus fault at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .invalid_return => |at| try out.print(
            "zig core: invalid exception return at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .breakpoint => |at| try out.print(
            "zig core: BKPT halted at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .unaligned => |at| try out.print(
            "zig core: unaligned MemA access at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .stack_overflow => |at| try out.print(
            "zig core: stack limit overrun at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
    }
    return 1;
}
