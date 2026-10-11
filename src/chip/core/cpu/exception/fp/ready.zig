//! UpdateFPCCR's readiness bits (RA8EMU-621): at a lazy entry the core
//! records, for each fault the deferred push could raise, whether that
//! fault could be taken at the priority the interrupted code ran at
//! (DDI0553 UpdateFPCCR). A lazy push that faults later pends the fault
//! only when its bit says so.
//!
//! HFRDY: the execution priority was above -1. MMRDY, BFRDY, UFRDY and
//! SFRDY: the fault is enabled in SHCSR and its SHPR1 priority would
//! preempt, the same rule fault_route uses to decide escalation. MONRDY:
//! DEMCR.MON_EN is set and the DebugMonitor's SHPR3 priority would
//! preempt. SHCSR and SHPR1 are read as the running state sees them; their
//! Secure/Non-secure banking is the TrustZone lane's.
const memmap = @import("../../../memmap.zig");
const fault_route = @import("../../../../periph/fault/route.zig");
const Fpccr = @import("../../fpu/context.zig").Fpccr;
const active = @import("../active.zig");
const dispatch = @import("../dispatch.zig");
const fault = @import("../fault.zig");
const Cpu = @import("../../cpu.zig").Cpu;

const mon_en: u32 = 1 << 16;

pub const Ready = struct {
    hf: bool,
    mm: bool,
    bf: bool,
    sf: bool,
    mon: bool,
    uf: bool,
};

/// The readiness of each fault at execution priority `level`.
pub fn ready(shcsr: u32, shpr1: u32, shpr3: u32, demcr: u32, level: i16) Ready {
    const running = fault.running(level);
    const monitor: u8 = @truncate(shpr3);
    return .{
        .hf = level > -1,
        .mm = takes(.mem_manage, shcsr, shpr1, running),
        .bf = takes(.bus_fault, shcsr, shpr1, running),
        .sf = takes(.secure_fault, shcsr, shpr1, running),
        .mon = demcr & mon_en != 0 and if (running) |now| monitor < now else true,
        .uf = takes(.usage_fault, shcsr, shpr1, running),
    };
}

fn takes(which: fault_route.Fault, shcsr: u32, shpr1: u32, running: ?u8) bool {
    return !fault_route.route(which, shcsr, shpr1, running).escalated;
}

/// Copy the readiness at the current execution priority into `fpccr`.
/// Called before the entry raises the priority.
pub fn record(cpu: *const Cpu, fpccr: *Fpccr) void {
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    const now = ready(
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        cpu.bus.readWord(memmap.scb.shpr3) catch 0,
        cpu.bus.readWord(memmap.scb.demcr) catch 0,
        level,
    );
    fpccr.hfrdy = @intFromBool(now.hf);
    fpccr.mmrdy = @intFromBool(now.mm);
    fpccr.bfrdy = @intFromBool(now.bf);
    fpccr.sfrdy = @intFromBool(now.sf);
    fpccr.monrdy = @intFromBool(now.mon);
    fpccr.ufrdy = @intFromBool(now.uf);
}
