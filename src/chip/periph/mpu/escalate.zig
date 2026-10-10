//! Which exception a refused access actually takes.
//!
//! MemManage is a configurable fault: it exists only while
//! SHCSR.MEMFAULTENA stands. With that bit clear the fault is DISABLED, and
//! a disabled fault does not vanish, it escalates to HardFault (DDI0553
//! B3.9). The escalated HardFault sets HFSR.FORCED to say so, and the
//! MemManage status the fault latched stays exactly where it was: a
//! HardFault handler reads CFSR to find out what really happened, and
//! MMFSR.DACCVIOL with MMFAR is how it finds out.
//!
//! This matters because a MemManage vector in the table is NOT the same
//! question as whether MemManage is enabled. A table built by the linker has
//! an entry for every exception whether or not the firmware ever enabled it,
//! so vectoring on the table alone sends a refused store to a handler that
//! silicon would never have run, and leaves the HardFault handler that
//! silicon WOULD have run untouched. FSP's R_BSP sets MEMFAULTENA in
//! bsp_irq_cfg when the MPU is brought up; firmware that programs the MPU
//! window itself, as several of the bare-metal images do, often does not.
//!
//!   SHCSR 0xE000_ED24, MEMFAULTENA [16]  (DDI0553 D1.2.9)
//!   HFSR  0xE000_ED2C, FORCED     [30]  (DDI0553 D1.2.12)

/// HardFault, exception 3 (DDI0553 B3.6).
const status = @import("../fault_status.zig");

pub const hard_fault: u16 = 3;

/// The priority an escalated HardFault runs at. Architecturally it is -1,
/// above everything configurable; the model's priority field is unsigned, so
/// zero is the most urgent it can say and nothing this model pends sits
/// above it.
pub const hard_fault_priority: u8 = 0;

pub const shcsr = struct {
    pub const memfaultena: u32 = 1 << 16;
};

pub const hfsr = struct {
    pub const forced: u32 = status.Hard.forced.bit();
};

/// The exception a refused access is taken as.
pub const Target = enum {
    /// MemManage is enabled and takes its own fault.
    mem_manage,
    /// MemManage is disabled, so the fault escalates.
    hard_fault,
};

/// Read the choice out of SHCSR. Nothing else in the register is consulted:
/// the other enables are for BusFault and UsageFault, which this model does
/// not raise.
pub fn targetFor(shcsr_value: u32) Target {
    return if (shcsr_value & shcsr.memfaultena != 0) .mem_manage else .hard_fault;
}

/// Whether an escalation needs to say so in HFSR. Only an escalated
/// HardFault sets FORCED, so a MemManage that took its own fault leaves the
/// register alone.
pub fn marks(target: Target) bool {
    return target == .hard_fault;
}
