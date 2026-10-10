//! Covers src/chip/core/cpu/exception/mem_manage.zig through Cpu.step: a load or
//! store the MPU refuses is turned away before memory, and a fetch it
//! refuses never runs; each is taken as MemManage or escalated to HardFault.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.chip.core.memmap;
const bus = ra8.chip.core.cpu.bus;
const mpu = ra8.chip.periph.mpu;
const mpu_check = ra8.chip.core.cpu.board_bus.mpu_check;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Stop = ra8.chip.core.cpu.cpu.Stop;

const mem_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const memfaultena: u32 = 1 << 16;
const daccviol: u32 = 1 << 1;
const mmarvalid: u32 = 1 << 7;
const forced: u32 = 1 << 30;
const window: u32 = fixture.base + 0x200;
const before: u32 = 0x1234_5678;

/// The fixture's RAM behind the check, the way BoardBus asks it.
const Guarded = struct {
    ram: *fixture.Ram,
    check: *mpu_check.Check,

    fn view(self: *Guarded) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }
    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Guarded = @ptrCast(@alignCast(ctx));
        if (!self.check.allows(address, .load)) return bus.Error.Unmapped;
        return self.ram.view().read(address, into);
    }
    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Guarded = @ptrCast(@alignCast(ctx));
        if (!self.check.allows(address, .store)) return bus.Error.Unmapped;
        return self.ram.view().write(address, from);
    }
};

/// RAM read-write for everyone, with a privileged read-only window at
/// `window` (region 1 outranks region 0).
fn unitOf(ctrl: u32) mpu.Mpu {
    var unit = mpu.Mpu{};
    unit.table[0] = mpu.Region.fromPair(fixture.base | mpu.field.rbar_ap_unprivileged, ((fixture.base + 0x3FF) & mpu.field.address) | mpu.field.rlar_enable);
    unit.table[1] = mpu.Region.fromPair(window | mpu.field.rbar_ap_ro, ((window + 0x3F) & mpu.field.address) | mpu.field.rlar_enable);
    unit.table[2] = mpu.Region.fromPair(no_access, ((no_access + 0x3F) & mpu.field.address) | mpu.field.rlar_enable);
    unit.ctrl = ctrl;
    return unit;
}

const Profile = ra8.chip.core.cpu.decode.profile.Profile;
/// CPU0's profile and CPU1's: every case runs on both.
const profiles = [_]Profile{ Profile.m85, Profile.m33 };
/// A privileged-only read-write region, no access to unprivileged code.
const no_access: u32 = fixture.base + 0x280;

/// `instr` at the reset PC with r0 = `address`, r1 = 0xCAFE_F00D.
fn bootWith(ram: *fixture.Ram, guarded: *Guarded, profile: Profile, instr: u16, address: u32) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 4 * 4, mem_handler | 1);
    ram.putHalf(fixture.code, instr);
    ram.putWord(window, before);
    var cpu = try fixture.boot(ram);
    cpu.profile = profile;
    cpu.bus = guarded.view();
    cpu.mpu = guarded.check;
    cpu.regs.low[0] = address;
    cpu.regs.low[1] = 0xCAFE_F00D;
    return cpu;
}

const str_r1_r0: u16 = 0x6001;
const ldr_r1_r0: u16 = 0x6801;

fn ipsr(cpu: *const Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

fn expectMemManage(ram: *fixture.Ram, cpu: *Cpu, at: u32) !void {
    try std.testing.expectEqual(mem_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 4), ipsr(cpu));
    try std.testing.expectEqual(daccviol | mmarvalid, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(at, ram.word(memmap.scb.mmfar));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    // The faulting instruction is the stacked return address.
    try std.testing.expectEqual(fixture.code, ram.word(fixture.msp_top - 8));
}

/// A fresh RAM, MPU and check for one case, MEMFAULTENA set when `enabled`.
const Rig = struct {
    ram: fixture.Ram = .{},
    unit: mpu.Mpu = undefined,
    check: mpu_check.Check = undefined,
    guarded: Guarded = undefined,

    fn init(self: *Rig, ctrl: u32, enabled: bool) void {
        self.* = .{};
        if (enabled) self.ram.putWord(memmap.scb.shcsr, memfaultena);
        self.unit = unitOf(ctrl);
        self.check = .{ .unit = &self.unit };
        self.guarded = .{ .ram = &self.ram, .check = &self.check };
    }
    fn boot(self: *Rig, profile: Profile, instr: u16, address: u32, unprivileged: bool) !Cpu {
        var cpu = try bootWith(&self.ram, &self.guarded, profile, instr, address);
        if (unprivileged) cpu.regs.control |= ra8.chip.core.cpu.regs.control_bits.npriv;
        return cpu;
    }
};

/// One store or load that the MPU refuses, taken as MemManage, on both cores.
fn expectRefused(ctrl: u32, instr: u16, address: u32, unprivileged: bool) !void {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(ctrl, true);
        rig.ram.putWord(address, before);
        var cpu = try rig.boot(profile, instr, address, unprivileged);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try expectMemManage(&rig.ram, &cpu, address);
        try std.testing.expectEqual(before, rig.ram.word(address));
        if (instr == ldr_r1_r0) try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.low[1]);
    }
}

/// One store the MPU lets through, on both cores.
fn expectAllowed(ctrl: u32, address: u32, unprivileged: bool) !void {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(ctrl, true);
        var cpu = try rig.boot(profile, str_r1_r0, address, unprivileged);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), rig.ram.word(address));
        try std.testing.expectEqual(@as(u32, 0), rig.ram.word(memmap.scb.cfsr));
    }
}

const on = mpu.field.ctrl_enable;
const privdef = mpu.field.ctrl_enable | mpu.field.ctrl_privdefena;
const uncovered: u32 = fixture.base + 0x3C0;

test "a privileged store to a read-only region is MemManage and never lands" {
    try expectRefused(on, str_r1_r0, window, false);
}

test "an unprivileged store to a read-only region is MemManage" {
    try expectRefused(on, str_r1_r0, window, true);
}

test "an unprivileged store to a no-access region is MemManage" {
    try expectRefused(on, str_r1_r0, no_access, true);
}

test "privileged code may store to that region" {
    try expectAllowed(on, no_access, false);
}

test "the same store to the read-write region beside it goes ahead" {
    try expectAllowed(on, window + 0x40, true);
}

test "an unprivileged load from a privileged-only region is MemManage" {
    try expectRefused(on, ldr_r1_r0, window, true);
}

test "the background with PRIVDEFENA lets privileged code through, not unprivileged" {
    try expectAllowedUncovered(privdef, false);
    try expectRefusedUncovered(privdef, true);
}

test "the background without PRIVDEFENA refuses privileged code too" {
    try expectRefusedUncovered(on, false);
    try expectRefusedUncovered(on, true);
}

/// Region 0 shrunk to the code and handler, so `uncovered` falls to the
/// background while the instruction itself may still be fetched.
fn backgroundOnly(ctrl: u32) mpu.Mpu {
    var unit = unitOf(ctrl);
    mapExceptionStack(&unit);
    unit.table[0] = mpu.Region.fromPair(fixture.code | mpu.field.rbar_ap_unprivileged, ((fixture.code + 0xFF) & mpu.field.address) | mpu.field.rlar_enable);
    return unit;
}

fn expectAllowedUncovered(ctrl: u32, unprivileged: bool) !void {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(ctrl, true);
        rig.unit = backgroundOnly(ctrl);
        var cpu = try rig.boot(profile, str_r1_r0, uncovered, unprivileged);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), rig.ram.word(uncovered));
    }
}

fn expectRefusedUncovered(ctrl: u32, unprivileged: bool) !void {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(ctrl, true);
        rig.unit = backgroundOnly(ctrl);
        var cpu = try rig.boot(profile, str_r1_r0, uncovered, unprivileged);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try expectMemManage(&rig.ram, &cpu, uncovered);
        try std.testing.expectEqual(@as(u32, 0), rig.ram.word(uncovered));
    }
}

test "with MEMFAULTENA clear the fault escalates to HardFault with FORCED" {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(on, false);
        var cpu = try rig.boot(profile, str_r1_r0, window, false);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(hard_handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
        try std.testing.expectEqual(forced, rig.ram.word(memmap.scb.hfsr));
        try std.testing.expectEqual(daccviol | mmarvalid, rig.ram.word(memmap.scb.cfsr));
        try std.testing.expectEqual(before, rig.ram.word(window));
    }
}

test "under FAULTMASK the MPU is off, unless HFNMIENA, which locks up" {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(on, false);
        var cpu = try rig.boot(profile, str_r1_r0, window, false);
        cpu.regs.faultmask = 1;
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), rig.ram.word(window));
        rig.unit.ctrl |= mpu.field.ctrl_hfnmiena;
        var locked = try rig.boot(profile, str_r1_r0, window, false);
        locked.regs.faultmask = 1;
        try std.testing.expectEqual(@as(?Stop, .{ .bus_fault = fixture.code }), locked.step());
    }
}

const iaccviol: u32 = 1 << 0;

/// A fetch of the instruction at the reset PC the MPU refuses: IACCVIOL
/// alone, MMFAR untouched, the store never made, on both cores.
fn expectFetchRefused(unit: mpu.Mpu, enabled: bool, unprivileged: bool) !void {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(0, enabled);
        rig.unit = unit;
        var cpu = try rig.boot(profile, str_r1_r0, window + 0x40, unprivileged);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(iaccviol, rig.ram.word(memmap.scb.cfsr));
        try std.testing.expectEqual(@as(u32, 0), rig.ram.word(memmap.scb.mmfar));
        try std.testing.expectEqual(@as(u32, 0), rig.ram.word(window + 0x40));
        try std.testing.expectEqual(fixture.code, rig.ram.word(fixture.msp_top - 8));
        if (enabled) {
            try std.testing.expectEqual(mem_handler, cpu.regs.pc);
            try std.testing.expectEqual(@as(u32, 0), rig.ram.word(memmap.scb.hfsr));
        } else {
            try std.testing.expectEqual(hard_handler, cpu.regs.pc);
            try std.testing.expectEqual(forced, rig.ram.word(memmap.scb.hfsr));
        }
    }
}

/// Region 0 made execute-never, so the code it covers cannot be fetched.
fn executeNever(ctrl: u32) mpu.Mpu {
    var unit = unitOf(ctrl);
    unit.table[0] = mpu.Region.fromPair(fixture.base | mpu.field.rbar_ap_unprivileged | mpu.field.rbar_xn, ((fixture.base + 0x3FF) & mpu.field.address) | mpu.field.rlar_enable);
    return unit;
}

/// Application regions dropped, so code falls to the background. The
/// exception stack stays mapped so the test isolates the fetch fault.
fn nothingMapped(ctrl: u32) mpu.Mpu {
    var unit = mpu.Mpu{};
    mapExceptionStack(&unit);
    unit.ctrl = ctrl;
    return unit;
}

fn mapExceptionStack(unit: *mpu.Mpu) void {
    unit.table[7] = mpu.Region.fromPair(
        fixture.msp_top - 0x20,
        ((fixture.msp_top - 1) & mpu.field.address) | mpu.field.rlar_enable,
    );
}

test "a fetch from an execute-never region is MemManage IACCVIOL, privileged or not" {
    try expectFetchRefused(executeNever(on), true, false);
    try expectFetchRefused(executeNever(on), true, true);
}

test "a fetch from an unmapped address without PRIVDEFENA is MemManage IACCVIOL" {
    try expectFetchRefused(nothingMapped(on), true, false);
    try expectFetchRefused(nothingMapped(on), true, true);
}

test "PRIVDEFENA lets privileged code fetch from the background, not unprivileged" {
    for (profiles) |profile| {
        var rig: Rig = undefined;
        rig.init(0, true);
        rig.unit = nothingMapped(privdef);
        var cpu = try rig.boot(profile, str_r1_r0, window + 0x40, false);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    }
    try expectFetchRefused(nothingMapped(privdef), true, true);
}

test "a refused fetch with MEMFAULTENA clear escalates to HardFault with FORCED" {
    try expectFetchRefused(executeNever(on), false, false);
}

/// A 32-bit store or load at the reset PC from privileged Thread mode, r0
/// at the privileged-only region, on both cores.
fn wide(profile: Profile, rig: *Rig, first: u16, second: u16) !Cpu {
    rig.init(on, true);
    var cpu = try rig.boot(profile, first, no_access, false);
    rig.ram.putHalf(fixture.code + 2, second);
    _ = &cpu;
    return cpu;
}

test "a privileged STRT or LDRT is checked as unprivileged; STR.W and LDR.W are not" {
    const strt = [2]u16{ 0xF840, 0x1E00 };
    const ldrt = [2]u16{ 0xF850, 0x1E00 };
    const str_w = [2]u16{ 0xF8C0, 0x1000 };
    const ldr_w = [2]u16{ 0xF8D0, 0x1000 };
    for (profiles) |profile| {
        for ([_][2]u16{ strt, ldrt }) |instr| {
            var rig: Rig = undefined;
            var cpu = try wide(profile, &rig, instr[0], instr[1]);
            try std.testing.expectEqual(@as(?Stop, null), cpu.step());
            try expectMemManage(&rig.ram, &cpu, no_access);
            try std.testing.expect(rig.check.privileged);
        }
        for ([_][2]u16{ str_w, ldr_w }) |instr| {
            var rig: Rig = undefined;
            var cpu = try wide(profile, &rig, instr[0], instr[1]);
            try std.testing.expectEqual(@as(?Stop, null), cpu.step());
            try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
            try std.testing.expectEqual(@as(u32, 0), rig.ram.word(memmap.scb.cfsr));
        }
    }
}

const mlsperr: u32 = 1 << 5;

/// VADD.F32 with a deferred FP push pending into `fpcar`, the lazy entry
/// having been `user` (FPCCR.USER) with HardFault ready.
fn lazyStep(rig: *Rig, fpcar: u32, user: u1) !Cpu {
    rig.ram.putHalf(fixture.code + 2, 0x0A81);
    var cpu = try rig.boot(Profile.m85, 0xEE30, 0, false);
    cpu.fp.context.writeFpcar(fpcar);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.context.fpccr.user = user;
    cpu.fp.context.fpccr.hfrdy = 1;
    cpu.fp.context.fpccr.mmrdy = 1;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    return cpu;
}

test "a deferred FP push the MPU refuses is MemManage MLSPERR without MMFAR" {
    var rig: Rig = undefined;
    rig.init(on, true);
    const cpu = try lazyStep(&rig, window, 0);
    try std.testing.expectEqual(mem_handler, cpu.regs.pc);
    try std.testing.expectEqual(mlsperr, rig.ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u32, 0), rig.ram.word(memmap.scb.mmfar));
    try std.testing.expectEqual(before, rig.ram.word(window));
    try std.testing.expectEqual(@as(u1, 1), cpu.fp.context.fpccr.lspact);
    try std.testing.expectEqual(fixture.code, rig.ram.word(fixture.msp_top - 8));
}

test "FPCCR.USER, not the running code, decides the deferred push's privilege" {
    var rig: Rig = undefined;
    rig.init(on, true);
    var cpu = try lazyStep(&rig, no_access, 1);
    try std.testing.expectEqual(mlsperr, rig.ram.word(memmap.scb.cfsr));
    rig.init(on, true);
    cpu = try lazyStep(&rig, no_access, 0);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), rig.ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(@as(u1, 0), cpu.fp.context.fpccr.lspact);
}
