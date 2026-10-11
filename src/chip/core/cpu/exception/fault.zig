//! Taking a synchronous UsageFault on the Zig core.
//!
//! The core decides that an instruction faults; this file latches the UFSR
//! bit in CFSR, routes the fault against SHCSR, SHPR1 and the execution
//! priority with the rules in
//! src/chip/periph/fault/route.zig, owes HFSR.FORCED when it escalates to
//! HardFault, and enters the handler with the faulting instruction stacked
//! as the return address (or, for INVPC on a refused exception return,
//! tail-chains it onto the frame the return left behind). A HardFault that cannot preempt either (FAULTMASK
//! set, or already in HardFault) is lockup, which the caller reports as a
//! stop instead.
const std = @import("std");
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault/route.zig");
const status = @import("../../../periph/fault/status.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const Cpu = @import("../cpu.zig").Cpu;
const State = @import("../../banked.zig").State;
const target = @import("target.zig");

pub const Error = bus.Error || error{Lockup};
pub const Cause = status.Cause;

/// Keep a configurable fault pending when the original exception wins
/// DerivedLateArrival. SHCSR holds one pending bit for each fault.
pub fn pend(cpu: *const Cpu, cause: status.Cause) bus.Error!void {
    return setPending(cpu, pendingBit(cause.fault()));
}

/// Preserve a synchronous exception whose entry was replaced by a derived
/// fault. DebugMonitor uses DEMCR; the others use SHCSR pending bits.
pub fn pendException(cpu: *const Cpu, number: u9) bus.Error!void {
    if (number == 12) {
        const demcr = cpu.bus.readWord(memmap.scb.demcr) catch 0;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, demcr | (1 << 17), .little);
        return cpu.bus.write(memmap.scb.demcr, &bytes);
    }
    const bit: u32 = switch (number) {
        4 => 1 << 13,
        5 => 1 << 14,
        6 => 1 << 12,
        7 => 1 << 20,
        11 => 1 << 15,
        else => return,
    };
    return setPending(cpu, bit);
}

fn setPending(cpu: *const Cpu, bit: u32) bus.Error!void {
    const value = cpu.bus.readWord(memmap.scb.shcsr) catch 0;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value | bit, .little);
    try cpu.bus.write(memmap.scb.shcsr, &bytes);
}

/// The most urgent configurable fault synthesized during exception entry.
pub fn pending(on: bus.Bus) ?active.Entry {
    const shcsr = on.readWord(memmap.scb.shcsr) catch return null;
    const shpr1 = on.readWord(memmap.scb.shpr1) catch 0;
    const shpr2 = on.readWord(memmap.scb.shpr2) catch 0;
    var winner: ?active.Entry = null;
    for ([_]fault_route.Fault{ .mem_manage, .bus_fault, .usage_fault, .secure_fault }) |kind| {
        if (shcsr & pendingBit(kind) == 0 or shcsr & fault_route.enable(kind) == 0) continue;
        const candidate: active.Entry = .{
            .number = @intCast(fault_route.exception(kind)),
            .priority = fault_route.priority(kind, shpr1),
        };
        if (winner == null or precedes(candidate, winner.?)) winner = candidate;
    }
    if (shcsr & (1 << 15) != 0) {
        const svc: active.Entry = .{ .number = 11, .priority = @truncate(shpr2 >> 24) };
        if (winner == null or precedes(svc, winner.?)) winner = svc;
    }
    return winner;
}

pub fn precedes(a: active.Entry, b: active.Entry) bool {
    return a.priority < b.priority or (a.priority == b.priority and a.number < b.number);
}

pub fn clearPending(on: bus.Bus, number: u9) void {
    const bit: u32 = switch (number) {
        4 => 1 << 13,
        5 => 1 << 14,
        6 => 1 << 12,
        7 => 1 << 20,
        11 => 1 << 15,
        else => return,
    };
    const value = on.readWord(memmap.scb.shcsr) catch return;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value & ~bit, .little);
    on.write(memmap.scb.shcsr, &bytes) catch {};
}
fn pendingBit(kind: fault_route.Fault) u32 {
    return switch (kind) {
        .usage_fault => 1 << 12,
        .mem_manage => 1 << 13,
        .bus_fault => 1 << 14,
        .secure_fault => 1 << 20,
    };
}

/// Raise UsageFault for `cause`, which the instruction at `pc` caused.
pub fn usage(cpu: *Cpu, cause: status.Cause, pc: u32) Error!void {
    const which = try latch(cpu, cause);
    cpu.regs.pc = pc;
    try dispatch.enter(cpu, which, pc);
}

/// INVPC for an exception return that refused `value`. As in the Armv7-M
/// ExceptionReturn pseudocode, the handler that tried to return is no longer
/// active, its frame stays on the stack, and the fault is tail-chained with
/// LR set to 0xF000_0000 + EXC_RETURN, a value that cannot return again.
pub fn invalidReturn(cpu: *Cpu, value: u32) Error!void {
    try dispatch.left(cpu);
    const which = try latch(cpu, .invpc);
    try dispatch.chain(cpu, which, 0xF000_0000 +% value);
}
/// A frame-pop fault is measured against the context being restored and
/// tail-chained without touching that frame.
pub fn unstack(cpu: *Cpu, cause: status.Cause, value: u32) Error!void {
    try dispatch.left(cpu);
    const which = try latch(cpu, cause);
    const to_secure = target.secure(cpu, which.number);
    cpu.banked.switchTo(&cpu.regs, if (to_secure) .secure else .non_secure);
    try dispatch.chain(cpu, which, 0xF000_0000 +% value);
}

/// Latch a configurable fault derived during exception entry or return and
/// say which exception it routes to (HardFault when it escalates).
pub fn derived(cpu: *Cpu, cause: status.Cause) Error!active.Entry {
    return latch(cpu, cause);
}

/// Stack accesses are checked in the state owning the stack. Entry has
/// already selected the original handler's state, so temporarily restore
/// the complete background bank while routing and latching the derived fault.
pub fn derivedIn(cpu: *Cpu, cause: status.Cause, state: State) Error!active.Entry {
    const was = cpu.banked.current;
    cpu.banked.switchTo(&cpu.regs, state);
    defer cpu.banked.switchTo(&cpu.regs, was);
    return latch(cpu, cause);
}

pub fn pendIn(cpu: *Cpu, cause: status.Cause, state: State) bus.Error!void {
    const was = cpu.banked.current;
    cpu.banked.switchTo(&cpu.regs, state);
    defer cpu.banked.switchTo(&cpu.regs, was);
    return pend(cpu, cause);
}

/// Route `cause`, latch its CFSR bit and HFSR.FORCED when it escalates, and
/// say which exception to enter.
fn latch(cpu: *Cpu, cause: status.Cause) Error!active.Entry {
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    const route = fault_route.route(
        cause.fault(),
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        running(level),
    );
    if (route.escalated and (level < 0 or inHardFaultOrNmi(cpu))) return error.Lockup;
    orInto(cpu.bus, memmap.scb.cfsr, cause.bit());
    if (route.escalated) orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    return .{ .number = @intCast(route.number), .priority = route.priority };
}

/// HardFault and NMI run at -1 and -2, below any priority an Entry can hold,
/// so being inside either is checked by number.
pub fn inHardFaultOrNmi(cpu: *const Cpu) bool {
    const inner = cpu.active.running() orelse return false;
    return inner.number == 2 or inner.number == 3;
}

/// The execution priority as fault_route reads it: null with nothing
/// running and no mask set, 0 for anything boosted to 0 or below.
pub fn running(level: i16) ?u8 {
    if (level >= active.lowest) return null;
    return if (level <= 0) 0 else @intCast(level);
}

/// Set `bits` in the status word at `address` as a latch, never as a store
/// (Bus.latch). A bus with no SCS behind it keeps no status, so a refused
/// access is dropped.
pub fn orInto(on: bus.Bus, address: u32, bits: u32) void {
    on.latch(address, bits) catch {};
}
