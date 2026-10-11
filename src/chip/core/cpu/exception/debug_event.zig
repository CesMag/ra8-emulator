//! A BKPT debug event on the Zig core (DDI0553 B3.18, debug event behaviour).
//!
//! The core latches DFSR.BKPT and then picks one of three outcomes:
//! - Halting debug is on (DHCSR.C_DEBUGEN, which the debugger sets when it
//!   attaches): the core halts with the PC on the BKPT.
//! - DEMCR.MON_EN is set and DebugMonitor can preempt: the core takes
//!   DebugMonitor, exception 12, at its SHPR3 priority.
//! - Otherwise the event escalates to HardFault with HFSR.DEBUGEVT. A
//!   HardFault that cannot preempt is lockup.
//!
//! When an exception is taken, the BKPT itself is the stacked return
//! address. The register addresses match src/chip/periph/dcb.zig; the core does
//! not import the debug layer.
const memmap = @import("../../memmap.zig");
const status = @import("../../../periph/fault/status.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const fault = @import("fault.zig");
const Cpu = @import("../cpu.zig").Cpu;

pub const dhcsr: u32 = 0xE000_EDF0;
pub const dfsr: u32 = 0xE000_ED30;
pub const c_debugen: u32 = 1 << 0;
pub const dfsr_bkpt: u32 = 1 << 1;
pub const mon_en: u32 = 1 << 16;
pub const debug_monitor: u9 = 12;
pub const hard_fault: u9 = 3;

/// Take the debug event the BKPT at `pc` raises. Returns false when the
/// core halts for the debugger instead. error.Lockup when the HardFault it
/// escalates to cannot be taken.
pub fn breakpoint(cpu: *Cpu, pc: u32) fault.Error!bool {
    fault.orInto(cpu.bus, dfsr, dfsr_bkpt);
    cpu.regs.pc = pc;
    if (read(cpu, dhcsr) & c_debugen != 0) return false;
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    if (read(cpu, memmap.scb.demcr) & mon_en != 0) {
        const own: u8 = @truncate(read(cpu, memmap.scb.shpr3));
        const preempts = if (fault.running(level)) |now| own < now else true;
        if (preempts) {
            try dispatch.enter(cpu, .{ .number = debug_monitor, .priority = own }, pc);
            return true;
        }
    }
    if (level < 0 or fault.inHardFaultOrNmi(cpu)) return error.Lockup;
    fault.orInto(cpu.bus, memmap.scb.hfsr, status.Hard.debugevt.bit());
    try dispatch.enter(cpu, .{ .number = hard_fault, .priority = 0 }, pc);
    return true;
}

/// A register this bus cannot answer for reads as zero: no debugger, no
/// monitor.
fn read(cpu: *const Cpu, address: u32) u32 {
    return cpu.bus.readWord(address) catch 0;
}
