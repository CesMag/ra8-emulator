//! Taking precise and instruction BusFaults on the Zig core (RA8EMU-219).
//!
//! An access the MPU refused is MemManage (mem_manage.zig). Any other recorded refusal
//! is a precise BusFault when the run records refused addresses on its bus
//! (`Bus.miss`): CFSR PRECISERR and BFARVALID, BFAR the address. The fault
//! routes against SHCSR.BUSFAULTENA, SHPR1.PRI_5 and the execution priority
//! (src/chip/periph/fault/route.zig); escalated, it owes HFSR.FORCED. The handler
//! is entered with the faulting instruction stacked as the return address,
//! and `Bus.tally` counts it. A run that records nothing, or a HardFault that
//! cannot preempt, stops instead.

const std = @import("std");
const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault/route.zig");
const status = @import("../../../periph/fault/status.zig");
const afsr = @import("../../../periph/afsr.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const fault = @import("fault.zig");
const mem_manage = @import("mem_manage.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Stop = @import("../cpu.zig").Stop;

pub const Error = fault.Error || error{NotRecorded};

/// Take what the data access the instruction at `pc` made and the bus
/// refused owes: MemManage for an MPU refusal, else the precise BusFault.
pub fn refused(cpu: *Cpu, pc: u32) Error!void {
    if (cpu.mpu) |m| if (m.take()) |at| return mem_manage.data(cpu, pc, at);
    const miss = cpu.bus.miss orelse return error.NotRecorded;
    const escalated = try data(cpu, pc, miss.*);
    if (cpu.bus.tally) |t| {
        t.raised +%= 1;
        if (escalated) t.escalated +%= 1;
    }
}

/// A refused instruction fetch sets IBUSERR and leaves BFAR unchanged.
pub fn instruction(cpu: *Cpu, pc: u32) Error!bool {
    return raise(cpu, pc, status.Cause.ibuserr.bit(), null);
}

/// Raise the precise BusFault for a data access to `bfar` the instruction
/// at `pc` made; true when it escalated to HardFault.
pub fn data(cpu: *Cpu, pc: u32, bfar: u32) Error!bool {
    return raise(cpu, pc, status.Cause.preciserr.bit() | status.Cause.bfarvalid.bit(), bfar);
}

fn raise(cpu: *Cpu, pc: u32, bits: u32, bfar: ?u32) Error!bool {
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    const route = fault_route.route(
        .bus_fault,
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        fault.running(level),
    );
    if (route.escalated and (level < 0 or fault.inHardFaultOrNmi(cpu))) return error.Lockup;
    fault.orInto(cpu.bus, memmap.scb.cfsr, bits);
    if (bfar) |at| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, at, .little);
        cpu.bus.write(memmap.scb.bfar, &bytes) catch {};
        const aux = afsr.forData(at);
        if (aux != 0) fault.orInto(cpu.bus, memmap.scb.afsr, aux);
    }
    if (route.escalated) fault.orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    cpu.regs.pc = pc;
    try dispatch.enter(cpu, .{ .number = @intCast(route.number), .priority = route.priority }, pc);
    return route.escalated;
}

/// Raise the recorded fetch BusFault, or keep the legacy stop when unrecorded.
pub fn instructionOrStop(cpu: *Cpu, pc: u32) ?Stop {
    if (cpu.bus.miss == null) return .{ .bus_fault = pc };
    const escalated = instruction(cpu, pc) catch return .{ .bus_fault = pc };
    if (cpu.bus.tally) |t| {
        t.raised +%= 1;
        if (escalated) t.escalated +%= 1;
    }
    return null;
}
