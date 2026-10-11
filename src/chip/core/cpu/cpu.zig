//! The Zig core: a register file, the bus it fetches through, and the
//! fetch-decode-execute step.
const bus = @import("bus.zig");
const regs_mod = @import("regs.zig");
const reset_mod = @import("reset.zig");
const decode = @import("decode/decode.zig");
const divide = @import("ops/divide.zig");
const decode_cache = @import("decode/cache.zig");
const block_cache = @import("block_cache.zig");
const cond = @import("cond.zig");
const it_state = @import("it_state.zig");
/// What step() does with a nonzero EPSR.ECI (RA8EMU-453).
pub const eci_gate = @import("eci_gate.zig");
const Instr = @import("instr.zig").Instr;
const fp_state = @import("fpu/state.zig");
const exception = @import("exception/all.zig");
const banked_mod = @import("../banked.zig");
const mpu_check = @import("mpu_check.zig");
const sysreg = @import("sysreg.zig");
const park = @import("park.zig");
pub const fixed_trip = @import("fixed_trip.zig");
pub const trip_decode = @import("trip_decode.zig");
pub const counted_bound = @import("counted_bound.zig");
pub const counted_trip = @import("counted_trip.zig");
const Until = @import("../until.zig").Until;
/// Public so its tests reach it without a root export.
pub const systick_cut = @import("systick_cut.zig");
pub const bti = @import("bti.zig");
pub const attribution = @import("attribution.zig");
pub const sau_source = @import("sau_source.zig");
pub const data_gate = @import("data_gate.zig");
pub const tt_mpu = @import("tt_mpu.zig");

/// Why `run` or `step` stopped.
pub const Stop = union(enum) {
    /// Ran every instruction it was asked to.
    count,
    /// No group in the decode table knows this encoding. The PC is left on
    /// it and nothing has changed.
    unknown: Instr,
    /// EPSR.T is clear at this address and the INVSTATE UsageFault it raises
    /// locked up or could not be stacked.
    invalid_state: u32,
    /// The fetch at this address, or an access the instruction there made,
    /// reached memory nothing answers for. The PC is left on it.
    bus_fault: u32,
    /// The instruction at this address branched to an EXC_RETURN value the
    /// core cannot honour, or to one whose stacked frame contradicts it, and
    /// the INVPC UsageFault it raises locked up or could not be taken.
    invalid_return: u32,
    /// The instruction at this address made an unaligned access and the
    /// UNALIGNED UsageFault it raises locked up or could not be stacked. The
    /// PC is left on it.
    unaligned: u32,
    /// A BKPT at this address halted the core for an attached debugger
    /// (DHCSR.C_DEBUGEN), or the HardFault it escalated to locked up. The PC
    /// is left on it.
    breakpoint: u32,
    /// The instruction crossed MSPLIM or PSPLIM and its STKOF UsageFault
    /// locked up or could not be stacked.
    stack_overflow: u32,
};

/// Asked before each instruction: src/chip/core/cpu/fetch_guard.zig.
pub const FetchGuard = @import("fetch_guard.zig").FetchGuard;

/// A listener called once for each instruction that retires.
pub const RetireListener = struct {
    context: *anyopaque,
    instructionFn: *const fn (context: *anyopaque, address: u32) void,

    pub fn instruction(self: RetireListener, address: u32) void {
        self.instructionFn(self.context, address);
    }
};

pub const Cpu = struct {
    regs: regs_mod.Regs = .{},
    bus: bus.Bus,
    /// S0-S31/D0-D15 and FPSCR, for the FPU groups (RA8EMU-26).
    fp: fp_state.State = .{},
    /// Instructions retired since reset.
    retired: u64 = 0,
    /// Optional observer for each retired instruction (profiling/debugging).
    retire_listener: ?RetireListener = null,
    /// Optional check before each instruction; a held one ends the stretch.
    fetch_guard: ?FetchGuard = null,
    /// The vector table the core reset from, for exception entry while
    /// nothing answers at VTOR.
    vtor: u32 = 0,
    /// An exception the instruction just executed raises (SVC), taken once
    /// it retires.
    raised: ?exception.entry.Number = null,
    /// The exceptions the core is inside.
    active: exception.active.Active = .{},
    /// What is pending, asked before each instruction `run` executes. Null
    /// runs with no asynchronous exceptions, as a lockstep step does.
    source: ?exception.source.Source = null,
    /// The poll shortcut `source` and `bus` go through on the board, stirred
    /// as each `run` starts because the board moves between stretches.
    quiet: ?*exception.quiet_source.QuietSource = null,
    /// Latched by a store that arms SysTick; `run` ends the stretch after
    /// the instruction that made it (RA8EMU-464). Null never cuts.
    cut: ?*systick_cut.Cut = null,
    /// Stops after the instruction that completes a requested console line.
    until: ?*Until = null,
    /// Decodes kept per address on the board; null decodes every step.
    decoded: ?*decode_cache.DecodeCache = null,
    /// Formed blocks, under `--blocks` (RA8EMU-405); null fetches and
    /// decodes every step.
    blocks: ?*block_cache.BlockCache = null,
    /// The local exclusive monitor: the address a load-exclusive tagged.
    exclusive: ?u32 = null,
    /// The other Security state's banked registers, which Secure code reaches
    /// through the _NS forms of MRS and MSR.
    banked: banked_mod.Banked = .{},
    /// Set while a SysTick or PendSV from the Non-secure copy is being
    /// taken, so it goes to Non-secure state (RA8EMU-438).
    entering_non_secure: bool = false,
    /// Which security state an address belongs to; null means all Secure.
    attribution: ?attribution.Attribution = null,
    /// How many SecureFaults this core has taken.
    secure_faults: u32 = 0,
    /// The MPU check the board bus asks during an instruction's own accesses;
    /// null checks nothing.
    mpu: ?*mpu_check.Check = null,
    /// The event register WFE waits on: set by SEV and by exception entry
    /// and return, cleared by a WFE that finds it set.
    event: bool = false,
    /// What a WFI or WFE left the core waiting for, or null while it runs.
    waiting: ?exception.sleep.Wait = null,
    /// Which encodings this core implements: an M85's unless the board
    /// says otherwise (src/chip/core/part/part.zig, RA8EMU-233).
    profile: decode.profile.Profile = decode.profile.Profile.m85,
    /// One trip of a calm loop under watch (RA8EMU-463).
    trip: fixed_trip.Watch = .{},

    pub fn reset(self: *Cpu, vtor: u32) bus.Error!void {
        try reset_mod.fromVectorTable(&self.regs, self.bus, vtor);
        self.retired = 0;
        self.vtor = vtor;
        self.raised = null;
        self.active = .{};
        self.event = false;
        self.waiting = null;
    }

    /// The instruction at `address` and its decode: from the block cache
    /// when there is one and it answers, else fetched and decoded here.
    fn fetchDecoded(self: *Cpu, address: u32) bus.Error!Fetched {
        if (self.blocks) |cache| if (cache.next(self.bus, self.profile, address)) |kept|
            return .{ .instr = kept.instr, .found = kept.hit };
        const instr = try Instr.fetch(self.bus, address);
        const found = if (self.decoded) |cache| cache.findFor(self.profile, instr) else decode.decodeFor(self.profile, instr);
        return .{ .instr = instr, .found = found };
    }

    /// One instruction, or the reason there was none.
    pub fn step(self: *Cpu) ?Stop {
        const address = self.regs.pc;
        if (self.regs.xpsr & regs_mod.xpsr_bits.thumb == 0) return self.usageFault(.invstate, address, .{ .invalid_state = address });
        if (self.mpu) |m| if (m.unit.on() and m.refusesFetch(address, sysreg.privileged(&self.regs), self.boosted()))
            return self.fetchRefused(address);
        const fetched = self.fetchDecoded(address) catch return self.fetchBusFault(address);
        const instr = fetched.instr;
        if (self.banked.current == .non_secure and attribution.refusesEntry(self.attribution, instr))
            return self.secureFault(.invep, address, 0, .{ .invalid_state = address });
        if (self.banked.current == .secure and attribution.refusesTransition(self.attribution, address))
            return self.secureFault(.invtran, address, 0, .{ .invalid_state = address });
        const it = it_state.get(self.regs.xpsr);
        const runs = !it_state.active(it) or cond.passed(it_state.condition(it), self.regs.xpsr);
        if (runs and self.regs.xpsr & regs_mod.xpsr_bits.bti != 0 and bti.enabled(&self.regs, self.profile.v8_1m) and !bti.allowed(instr))
            return self.usageFault(.invstate, address, .{ .invalid_state = address });
        const found = fetched.found;
        // An encoding whose IT condition failed never runs, so it is skipped
        // whether or not any group knows it.
        if (found == null and runs) {
            if (decode.refused(self.profile, instr)) return self.usageFault(.undefinstr, address, .{ .unknown = instr });
            return .{ .unknown = instr };
        }
        if (found) |hit| switch (eci_gate.action(it, hit.eci)) {
            .run => {},
            .fault => return self.usageFault(.invstate, address, .{ .invalid_state = address }),
            .restart => self.regs.xpsr = it_state.put(self.regs.xpsr, 0),
        };
        if (runs and divide.group.decode(instr) != null and divide.traps(self, instr)) {
            return self.usageFault(.divbyzero, address, .{ .unknown = instr });
        }
        self.regs.pc = address +% instr.size;
        if (runs) {
            const before = StackPointers.read(self);
            if (self.mpu) |m| if (m.unit.on()) m.arm(sysreg.privileged(&self.regs), self.boosted());
            self.armGate(true);
            const ran = found.?.exec(self, instr);
            self.armGate(false);
            if (self.mpu) |m| m.disarm();
            ran catch |err| {
                self.regs.pc = address;
                return switch (err) {
                    error.Unaligned => self.usageFault(.unaligned, address, .{ .unaligned = address }),
                    error.Undefined => self.usageFault(.undefinstr, address, .{ .unknown = instr }),
                    error.Breakpoint => self.breakpoint(address),
                    error.StackOverflow => self.usageFault(.stkof, address, .{ .stack_overflow = address }),
                    error.InvalidState => self.usageFault(.invstate, address, .{ .invalid_state = address }),
                    error.InvalidEntry => self.secureFault(.invep, address, 0, .{ .invalid_state = address }),
                    error.NoCoprocessor => self.usageFault(.nocp, address, .{ .unknown = instr }),
                    error.LazyStateError => self.secureFault(.lserr, address, 0, .{ .invalid_state = address }),
                    error.LazyMemManage, error.LazyBusFault => |e| exception.lazy_fault.orStop(self, e, address),
                    error.LazyPreserveError => self.secureFault(.lsperr, address, self.fp.context.fpcar, .{ .invalid_state = address }),
                    error.SecurityViolation => self.secureFault(.auviol, address, self.bus.gate.?.refused, .{ .bus_fault = address }),
                    else => self.refusedOr(address),
                };
            };
            if (before.overrun(self)) {
                before.restore(self);
                self.regs.pc = address;
                return self.usageFault(.stkof, address, .{ .stack_overflow = address });
            }
        }
        // An instruction an IT block governs moves the block on whether it
        // ran or not. IT itself leaves the state it just wrote.
        if (it_state.active(it)) self.regs.xpsr = it_state.put(self.regs.xpsr, it_state.advance(it));
        self.retired += 1;
        if (self.retire_listener) |listener| listener.instruction(address);
        return self.finish(address);
    }

    /// What an instruction leaves for after it retires and its IT state has
    /// moved on: an exception return, or an exception it raised.
    fn finish(self: *Cpu, address: u32) ?Stop {
        if (self.regs.exc_return) |value| {
            self.regs.exc_return = null;
            exception.ret.from(self, value) catch |err| return switch (err) {
                error.InvalidReturn => {
                    exception.fault.invalidReturn(self, value) catch return .{ .invalid_return = address };
                    return null;
                },
                error.Integrity => self.chainedSecure(exception.secure.invalidIntegrity, value, address),
                error.SecureReturn => self.chainedSecure(exception.secure.invalidReturn, value, address),
                error.MemManageUnstack => self.derivedUnstack(.munstkerr, value, address),
                error.BusUnstack => self.derivedUnstack(.unstkerr, value, address),
                else => .{ .bus_fault = address },
            };
            exception.dispatch.left(self) catch return .{ .bus_fault = address };
        }
        if (self.regs.fnc_return) |_| {
            self.regs.fnc_return = null;
            exception.fnc_return.from(self) catch |err| return switch (err) {
                error.InconsistentFrame => self.usageFault(.invpc, address, .{ .invalid_return = address }),
                else => .{ .bus_fault = address },
            };
        }
        if (self.raised) |number| {
            self.raised = null;
            exception.dispatch.supervisorCall(self, number, self.regs.pc) catch return .{ .bus_fault = address };
        }
        return null;
    }
    fn derivedUnstack(self: *Cpu, cause: exception.fault.Cause, value: u32, address: u32) ?Stop {
        exception.fault.unstack(self, cause, value) catch return .{ .bus_fault = address };
        return null;
    }
    /// Take a UsageFault caused by the current instruction, or stop.
    fn usageFault(self: *Cpu, cause: exception.fault.Cause, address: u32, otherwise: Stop) ?Stop {
        exception.fault.usage(self, cause, address) catch return otherwise;
        return null;
    }

    /// Take MemManage or BusFault for a refused data access, or stop.
    fn refusedOr(self: *Cpu, address: u32) ?Stop {
        exception.bus_fault.refused(self, address) catch return .{ .bus_fault = address };
        return null;
    }

    /// Take BusFault for a refused fetch when the run records it.
    fn fetchBusFault(self: *Cpu, address: u32) ?Stop {
        return exception.bus_fault.instructionOrStop(self, address);
    }

    /// Take MemManage for an MPU-refused fetch, or stop.
    fn fetchRefused(self: *Cpu, address: u32) ?Stop {
        exception.mem_manage.instruction(self, address) catch return .{ .bus_fault = address };
        return null;
    }

    /// A negative execution priority: HardFault, NMI, or FAULTMASK set.
    pub fn boosted(self: *const Cpu) bool {
        return self.regs.faultmask != 0 or exception.fault.inHardFaultOrNmi(self);
    }

    /// Take a SecureFault the instruction at `address` caused, or stop.
    /// `sfar` is the address AUVIOL reports; the other causes ignore it.
    fn secureFault(self: *Cpu, cause: exception.secure.Cause, address: u32, sfar: u32, otherwise: Stop) ?Stop {
        exception.secure.raise(self, cause, address, sfar) catch return otherwise;
        self.secure_faults +%= 1;
        return null;
    }

    /// Chain the SecureFault a refused exception return of `value` owes
    /// over the frame it left, or stop when that locks up.
    fn chainedSecure(self: *Cpu, chain: *const fn (*Cpu, u32) exception.secure.Error!void, value: u32, address: u32) ?Stop {
        chain(self, value) catch return .{ .invalid_return = address };
        self.secure_faults +%= 1;
        return null;
    }

    /// Arm the data gate for the instruction executing, or disarm it after.
    fn armGate(self: *Cpu, on: bool) void {
        if (self.bus.gate) |gate| gate.armed = on;
    }

    /// Take the debug event a BKPT at `address` raises, or stop on it for an
    /// attached debugger or when the HardFault it escalates to locks up.
    fn breakpoint(self: *Cpu, address: u32) ?Stop {
        const taken = exception.debug_event.breakpoint(self, address) catch return .{ .breakpoint = address };
        return if (taken) null else .{ .breakpoint = address };
    }

    pub fn run(self: *Cpu, count: u64) Stop {
        if (self.quiet) |q| q.stir();
        defer self.trip.drop(self);
        var left = count;
        self.trip.parked = false;
        while (left > 0) : (left -= 1) {
            const lent = self.trip.lend(self);
            const taken = exception.dispatch.poll(self) catch return .{ .bus_fault = self.regs.pc };
            self.trip.reclaim(self, lent, taken);
            if (taken) self.waiting = null;
            if (self.waiting) |why| {
                const up = exception.sleep.wakes(self, why) catch return .{ .bus_fault = self.regs.pc };
                // Asleep with nothing to wake it: nothing changes before the
                // next boundary, so the rest of the stretch goes by at once.
                if (!up) return .count;
                self.waiting = null;
            }
            // Whole trips of a park loop (RA8EMU-450) or of a loop whose
            // trip changes nothing (RA8EMU-463) go by at once.
            // A guard sees every arrival, so no trips are skipped under one.
            if (self.fetch_guard) |guard| if (guard.holds(self.regs.pc)) return .count;
            const trips = if (self.fetch_guard == null) park.trips(self, left) else 0;
            if (trips != 0) {
                self.retired += trips;
                left -= trips - 1;
                continue;
            }
            if (self.step()) |stopped| return stopped;
            if (self.until) |wait| if (wait.met()) return .count;
            if (self.cut) |edge| if (edge.fired) return .count;
        }
        return .count;
    }
};

const Fetched = struct { instr: Instr, found: ?decode.Hit };

/// The four stack pointers an instruction may move, taken before it runs so
/// a write that crosses MSPLIM or PSPLIM can be undone. SG and BXNS swap the
/// banks without moving a pointer, so each is compared in its own bank.
const StackPointers = struct {
    msp: u32,
    psp: u32,
    other_msp: u32,
    other_psp: u32,
    state: @TypeOf(@as(Cpu, undefined).banked.current),

    fn read(cpu: *const Cpu) StackPointers {
        return .{
            .msp = cpu.regs.msp,
            .psp = cpu.regs.psp,
            .other_msp = cpu.banked.other.msp,
            .other_psp = cpu.banked.other.psp,
            .state = cpu.banked.current,
        };
    }

    /// Whether a pointer the instruction changed now sits below its limit.
    fn overrun(self: StackPointers, cpu: *const Cpu) bool {
        const r = &cpu.regs;
        const o = &cpu.banked.other;
        const was = self.inBanks(cpu);
        return (r.msp != was.msp and r.msp < r.msplim) or
            (r.psp != was.psp and r.psp < r.psplim) or
            (o.msp != was.other_msp and o.msp < o.msplim) or
            (o.psp != was.other_psp and o.psp < o.psplim);
    }

    fn restore(self: StackPointers, cpu: *Cpu) void {
        const was = self.inBanks(cpu);
        cpu.regs.msp = was.msp;
        cpu.regs.psp = was.psp;
        cpu.banked.other.msp = was.other_msp;
        cpu.banked.other.psp = was.other_psp;
    }

    /// The snapshot laid out the way the banks sit now.
    fn inBanks(self: StackPointers, cpu: *const Cpu) StackPointers {
        if (cpu.banked.current == self.state) return self;
        return .{ .msp = self.other_msp, .psp = self.other_psp, .other_msp = self.msp, .other_psp = self.psp, .state = cpu.banked.current };
    }
};
