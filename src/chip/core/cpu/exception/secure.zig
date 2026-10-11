//! Taking a SecureFault on the Zig core (RA8EMU-358).
//!
//! src/chip/periph/secure_fault.zig says what each cause latches; this file does
//! the rest the way src/chip/core/cpu/exception/fault.zig does for UsageFault:
//! routes exception 7 against SHCSR.SECUREFAULTENA, SHPR1.PRI_7 and the
//! execution priority (src/chip/periph/fault/route.zig), owes HFSR.FORCED when
//! it escalates to HardFault, reports lockup when even HardFault cannot
//! preempt, and enters the handler with the faulting instruction stacked as
//! the return address. SFSR is latched either way, so a HardFault handler
//! can still read the cause. SFAR is written only for the causes that
//! report an address, together with SFARVALID.
const std = @import("std");
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault/route.zig");
const status = @import("../../../periph/fault/status.zig");
const secure_fault = @import("../../../periph/secure_fault.zig");
const fault = @import("fault.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const target = @import("target.zig");
const Cpu = @import("../cpu.zig").Cpu;

pub const Error = fault.Error;
pub const Cause = secure_fault.Cause;

/// Raise a SecureFault for `cause`, which the instruction at `pc` caused.
/// `address` is what AUVIOL and LSPERR report in SFAR; the other causes
/// ignore it.
pub fn raise(cpu: *Cpu, cause: Cause, pc: u32, address: u32) Error!void {
    const which = try latch(cpu, cause, address);
    cpu.regs.pc = pc;
    try dispatch.enter(cpu, which, pc);
}

/// INVER for an exception return that refused `value` (RA8EMU-472): a
/// Non-secure handler returned with EXC_RETURN.ES set. As for INVPC
/// (fault.invalidReturn), the handler is no longer active, its frame stays
/// on the stack, and the SecureFault is tail-chained in the state it is taken to with LR set to
/// 0xF000_0000 + EXC_RETURN.
pub fn invalidReturn(cpu: *Cpu, value: u32) Error!void {
    return chainReturn(cpu, .inver, value);
}

/// INVIS for a return that found the integrity signature corrupted
/// (RA8EMU-411). Nothing came off the stack, so the callee frame stays
/// where the return found it and the fault is chained the same way.
pub fn invalidIntegrity(cpu: *Cpu, value: u32) Error!void {
    return chainReturn(cpu, .invis, value);
}

/// Deactivate the returning handler, latch `cause`, and tail-chain the
/// SecureFault over the frame the return left in place.
fn chainReturn(cpu: *Cpu, cause: Cause, value: u32) Error!void {
    try dispatch.left(cpu);
    const which = try latch(cpu, cause, 0);
    // A tail-chain keeps the frame where it is but not the state: the fault
    // runs in the state it is taken to, so VTOR and the stacks are its own.
    const to_secure = target.secure(cpu, which.number);
    cpu.banked.switchTo(&cpu.regs, if (to_secure) .secure else .non_secure);
    try dispatch.chain(cpu, which, 0xF000_0000 +% value);
}

/// Route the fault, latch SFSR (and SFAR), owe HFSR.FORCED when it
/// escalates, and say which exception to enter.
fn latch(cpu: *Cpu, cause: Cause, address: u32) Error!active.Entry {
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    const route = fault_route.route(
        .secure_fault,
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        fault.running(level),
    );
    if (route.escalated and (level < 0 or fault.inHardFaultOrNmi(cpu))) return error.Lockup;
    const owed = secure_fault.latch(cause, address);
    fault.orInto(cpu.bus, secure_fault.sfsr, owed.sfsr);
    if (owed.address) |at| putWord(cpu.bus, secure_fault.sfar, at);
    if (route.escalated) fault.orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    return .{ .number = @intCast(route.number), .priority = route.priority };
}

/// A bus with no SCS behind it keeps no SFAR, so a refused write is dropped.
fn putWord(on: bus.Bus, address: u32, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    on.write(address, &bytes) catch {};
}
