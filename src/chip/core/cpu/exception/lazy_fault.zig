//! The faults a deferred FP push raises on the Zig core (RA8EMU-621).
//!
//! When the first FP instruction after a lazy exception entry runs, its
//! PreserveFPState may be refused: by the MPU, which is MemManage with
//! CFSR.MLSPERR, or by the bus, which is BusFault with CFSR.LSPERR (DDI0553
//! PreserveFPState). Neither writes MMFAR or BFAR. Whether it can be taken
//! is what the lazy entry recorded in FPCCR (RA8EMU-625), not the live
//! SHCSR: MMRDY or BFRDY set takes it at its SHPR1 priority; clear with
//! HFRDY set escalates to HardFault and owes HFSR.FORCED; both clear locks
//! up. The FP instruction is stacked as the return address and
//! FPCCR.LSPACT stays set, so the push is retried when it runs again.

const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault/route.zig");
const status = @import("../../../periph/fault/status.zig");
const dispatch = @import("dispatch.zig");
const fault = @import("fault.zig");
const cpu_mod = @import("../cpu.zig");
const Cpu = cpu_mod.Cpu;
const Stop = cpu_mod.Stop;

pub const Error = fault.Error;

/// Take the fault `err` names for the FP instruction at `pc`, or stop with a
/// bus fault when it locks up.
pub fn orStop(cpu: *Cpu, err: anyerror, pc: u32) ?Stop {
    const taken = if (err == error.LazyMemManage)
        raise(cpu, .mem_manage, .mlsperr, pc)
    else
        raise(cpu, .bus_fault, .lsperr, pc);
    taken catch return .{ .bus_fault = pc };
    return null;
}

/// Raise `kind` with `cause` set in CFSR for the instruction at `pc`.
pub fn raise(cpu: *Cpu, kind: fault_route.Fault, cause: status.Cause, pc: u32) Error!void {
    const fpccr = cpu.fp.context.fpccr;
    const ready = switch (kind) {
        .mem_manage => fpccr.mmrdy,
        .bus_fault => fpccr.bfrdy,
        else => fpccr.hfrdy,
    } == 1;
    if (!ready and fpccr.hfrdy == 0) return error.Lockup;
    const shpr1 = cpu.bus.readWord(memmap.scb.shpr1) catch 0;
    const route: fault_route.Taken = if (ready)
        .{ .number = fault_route.exception(kind), .priority = fault_route.priority(kind, shpr1), .escalated = false }
    else
        .{ .number = fault_route.hard_fault, .priority = fault_route.hard_fault_priority, .escalated = true };
    const r = &cpu.regs;
    fault.orInto(cpu.bus, memmap.scb.cfsr, cause.bit());
    if (route.escalated) fault.orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    r.pc = pc;
    try dispatch.enter(cpu, .{ .number = @intCast(route.number), .priority = route.priority }, pc);
}
