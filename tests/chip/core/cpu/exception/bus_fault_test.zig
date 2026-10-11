//! Covers src/chip/core/cpu/exception/bus_fault.zig through Cpu.step: a load or
//! store the bus refuses is the precise BusFault when the run records
//! refusals, escalated to HardFault when BusFault is off or PRIMASK is
//! set, counted on the bus's tally, and a stop when the run records nothing.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;
const Profile = ra8.chip.core.cpu.decode.profile.Profile;
const Tally = ra8.chip.periph.fault.status.bus.Tally;

const bus_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const busfaultena: u32 = 1 << 17;
const preciserr: u32 = 1 << 9;
const bfarvalid: u32 = 1 << 15;
const forced: u32 = 1 << 30;
const hole: u32 = 0x6000_0010;
const str_r1_r0: u16 = 0x6001;
const ldr_r1_r0: u16 = 0x6801;
const profiles = [_]Profile{ Profile.m85, Profile.m33 };

/// `instr` at the reset PC with r0 = `hole`, r1 = 0xCAFE_F00D, refusals
/// recorded into `miss` when it is set.
fn bootWith(ram: *fixture.Ram, profile: Profile, instr: u16, miss: ?*u32) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 5 * 4, bus_handler | 1);
    ram.putHalf(fixture.code, instr);
    var cpu = try fixture.boot(ram);
    cpu.profile = profile;
    cpu.bus.miss = miss;
    cpu.regs.low[0] = hole;
    cpu.regs.low[1] = 0xCAFE_F00D;
    return cpu;
}

fn ipsr(cpu: *const Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

/// One refused access on both cores, BusFault enabled or not.
fn expectTaken(instr: u16, enabled: bool) !void {
    for (profiles) |profile| {
        var ram: fixture.Ram = .{};
        if (enabled) ram.putWord(memmap.scb.shcsr, busfaultena);
        var miss: u32 = 0;
        var cpu = try bootWith(&ram, profile, instr, &miss);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(if (enabled) bus_handler else hard_handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, if (enabled) 5 else 3), ipsr(&cpu));
        try std.testing.expectEqual(preciserr | bfarvalid, ram.word(memmap.scb.cfsr));
        try std.testing.expectEqual(hole, ram.word(memmap.scb.bfar));
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.afsr));
        try std.testing.expectEqual(if (enabled) 0 else forced, ram.word(memmap.scb.hfsr));
        // The faulting instruction is the stacked return address.
        try std.testing.expectEqual(fixture.code, ram.word(fixture.msp_top - 8));
        try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.low[1]);
    }
}

test "a refused store is a precise BusFault with BFAR" {
    try expectTaken(str_r1_r0, true);
}

test "a refused load is a precise BusFault and leaves its destination" {
    try expectTaken(ldr_r1_r0, true);
}

test "a refused access escalates to HardFault FORCED when BusFault is off" {
    try expectTaken(str_r1_r0, false);
}

test "a run that records no refusals stops on the bus fault" {
    for (profiles) |profile| {
        var ram: fixture.Ram = .{};
        ram.putWord(memmap.scb.shcsr, busfaultena);
        var cpu = try bootWith(&ram, profile, str_r1_r0, null);
        try std.testing.expectEqual(@as(?Stop, .{ .bus_fault = fixture.code }), cpu.step());
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
    }
}

/// One refused store with `tally` counting; returns where the core went.
fn counted(profile: Profile, primask: bool, tally: *Tally) !u32 {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, busfaultena);
    var miss: u32 = 0;
    var cpu = try bootWith(&ram, profile, str_r1_r0, &miss);
    cpu.bus.tally = tally;
    cpu.regs.primask = @intFromBool(primask);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    return cpu.regs.pc;
}

test "a taken BusFault is counted on the bus tally" {
    for (profiles) |profile| {
        var tally: Tally = .{};
        try std.testing.expectEqual(bus_handler, try counted(profile, false, &tally));
        try std.testing.expectEqual(Tally{ .raised = 1, .escalated = 0 }, tally);
    }
}

test "a refused store under PRIMASK escalates and counts as escalated" {
    for (profiles) |profile| {
        var tally: Tally = .{};
        try std.testing.expectEqual(hard_handler, try counted(profile, true, &tally));
        try std.testing.expectEqual(Tally{ .raised = 1, .escalated = 1 }, tally);
    }
}

test "a refused fetch raises IBUSERR without changing BFAR" {
    for (profiles) |profile| {
        var ram: fixture.Ram = .{};
        ram.putWord(fixture.base + 5 * 4, bus_handler | 1);
        ram.putWord(memmap.scb.shcsr, busfaultena);
        ram.putWord(memmap.scb.bfar, 0x1234_5678);
        var cpu = try fixture.boot(&ram);
        cpu.profile = profile;
        cpu.regs.pc = hole;
        var miss: u32 = 0;
        var tally: Tally = .{};
        cpu.bus.miss = &miss;
        cpu.bus.tally = &tally;
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(Tally{ .raised = 1, .escalated = 0 }, tally);
        try std.testing.expectEqual(bus_handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 5), ipsr(&cpu));
        try std.testing.expectEqual(@as(u32, 1 << 8), ram.word(memmap.scb.cfsr));
        try std.testing.expectEqual(@as(u32, 0x1234_5678), ram.word(memmap.scb.bfar));
        try std.testing.expectEqual(hole, ram.word(fixture.msp_top - 8));
    }
}

test "an unrecorded refused fetch remains a bus fault stop" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.pc = hole;
    try std.testing.expectEqual(@as(?Stop, .{ .bus_fault = hole }), cpu.step());
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "a refused fetch escalates to forced HardFault when BusFault is disabled" {
    var ram: fixture.Ram = .{};
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    var cpu = try fixture.boot(&ram);
    cpu.regs.pc = hole;
    var miss: u32 = 0;
    cpu.bus.miss = &miss;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 1 << 8), ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
}

test "a refused load from the ITCM window also raises AFSR.PPOISON" {
    for (profiles) |profile| {
        var ram: fixture.Ram = .{};
        ram.putWord(memmap.scb.shcsr, busfaultena);
        var miss: u32 = 0;
        var cpu = try bootWith(&ram, profile, ldr_r1_r0, &miss);
        cpu.regs.low[0] = 0;
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(bus_handler, cpu.regs.pc);
        try std.testing.expectEqual(preciserr | bfarvalid, ram.word(memmap.scb.cfsr));
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.bfar));
        try std.testing.expectEqual(@as(u32, 1 << 19), ram.word(memmap.scb.afsr));
    }
}
