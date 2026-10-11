//! Raising a UsageFault for an instruction the core refused to execute.
//!
//! An undefined encoding, a branch to an ARM-state address, a bad EXC_RETURN,
//! a coprocessor access with no coprocessor, an integer divide by zero with
//! DIV_0_TRP set, a trapped unaligned access, a stack limit overrun: each
//! latches its own UFSR bit and is taken as a UsageFault, or as HardFault with
//! HFSR.FORCED when SHCSR.USGFAULTENA is clear or the fault cannot preempt
//! (DDI0553 D1.2.11). The faulting instruction is stacked as the return
//! address. Deciding THAT an instruction faults is the core's; this file only
//! raises what the core reports.

const memmap = @import("../core/memmap.zig");
const status = @import("fault/status.zig");
const fault_route = @import("fault/route.zig");
const fault_take = @import("fault/take.zig");
const nvic = @import("nvic/nvic.zig");

pub const Error = error{NotUsageFault};

/// Latch `cause` in UFSR and take the fault raised by the instruction at
/// `pc`. A cause from MMFSR or BFSR is refused: those have raisers of their
/// own, with their own address registers.
pub fn raise(core: anytype, controller: *nvic.Nvic, cause: status.Cause, pc: u32) !fault_route.Taken {
    if (cause.fault() != .usage_fault) return Error.NotUsageFault;
    const cfsr = core.readWord(memmap.scb.cfsr) catch 0;
    try core.writeWord(memmap.scb.cfsr, cfsr | cause.bit());
    return fault_take.take(core, controller, .usage_fault, pc);
}
