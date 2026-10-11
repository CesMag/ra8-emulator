//! Classify faults raised by exception-frame stack accesses.
//!
//! Exception entry uses privileged stack stores; exception return uses the
//! privilege of the context being restored. An MPU refusal is a MemManage
//! stacking or unstacking error; any other failed bus access is the
//! corresponding BusFault. Neither fault makes MMFAR or BFAR valid.

const Cpu = @import("../cpu.zig").Cpu;
const status = @import("../../../periph/fault/status.zig");

pub const Failure = enum { mem_manage, bus_fault };
pub const Phase = enum { stacking, unstacking };
pub const UnstackError = error{ MemManageUnstack, BusUnstack };

/// Exception entry's automatic frame stores are privileged. HardFault and
/// NMI disable the MPU unless HFNMIENA keeps it active.
pub fn beginEntry(cpu: *Cpu, number: u9) void {
    if (cpu.mpu) |check| check.arm(true, cpu.boosted() or number == 2 or number == 3);
}

/// Unstacking uses the privilege of the context being restored, not Handler
/// mode's privilege.
pub fn beginReturn(cpu: *Cpu, thread: bool) void {
    const outer = if (thread) null else cpu.active.returningTo();
    const boosted = cpu.regs.faultmask != 0 or if (outer) |entry| entry.number == 2 or entry.number == 3 else false;
    if (cpu.mpu) |check| check.arm(!thread or cpu.regs.control & @import("../regs.zig").control_bits.npriv == 0, boosted);
}

pub fn end(cpu: *Cpu) void {
    if (cpu.mpu) |check| check.disarm();
}

/// A failed bus access was caused by the MPU exactly when its latch names the
/// refused address. Reading the latch also leaves it ready for the handler.
pub fn failure(cpu: *Cpu) Failure {
    if (cpu.mpu) |check| if (check.take() != null) return .mem_manage;
    return .bus_fault;
}

pub fn cause(failed: Failure, phase: Phase) status.Cause {
    return switch (phase) {
        .stacking => if (failed == .mem_manage) .mstkerr else .stkerr,
        .unstacking => if (failed == .mem_manage) .munstkerr else .unstkerr,
    };
}

pub fn unstackError(cpu: *Cpu) UnstackError {
    return if (failure(cpu) == .mem_manage) error.MemManageUnstack else error.BusUnstack;
}
