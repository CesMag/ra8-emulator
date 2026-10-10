//! Covers src/chip/core/cpu/data_gate.zig and the SecureFault Cpu.step takes when
//! a Non-secure load or store reaches Secure memory (RA8EMU-274).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const memmap = ra8.chip.core.memmap;
const cpu_mod = ra8.chip.core.cpu.cpu;
const attribution = cpu_mod.attribution;
const Gate = cpu_mod.data_gate.Gate;
const Cpu = cpu_mod.Cpu;
const Profile = ra8.chip.core.cpu.decode.profile.Profile;

const secure_handler: u32 = fixture.base + 0x1C0;
const securefaultena: u32 = 1 << 19;
const sfsr: u32 = 0xE000_EDE4;
const sfar: u32 = 0xE000_EDE8;
const auviol: u32 = 1 << 3;
const sfarvalid: u32 = 1 << 6;
const lsperr: u32 = 1 << 5;
const ns_sp: u32 = fixture.base + 0x280;
/// The one Secure window in the fixture; everything else is Non-secure.
const secure_word: u32 = fixture.base + 0x200;
const open_word: u32 = fixture.base + 0x240;
const ldr_r0_r1: u16 = 0x6808;
const str_r0_r1: u16 = 0x6008;

const Split = struct {
    fn of(context: *anyopaque, address: u32) attribution.State {
        _ = context;
        const inside = address >= secure_word and address < secure_word + 0x20;
        return if (inside) .secure else .non_secure;
    }

    fn source(self: *Split) attribution.Attribution {
        return .{ .context = self, .stateFn = of };
    }
};

/// A core in Non-secure state at fixture.code running `op` with r1 = `target`.
fn nonSecure(ram: *fixture.Ram, profile: Profile, op: u16, target: u32) !Cpu {
    ram.putWord(memmap.scb.shcsr, securefaultena);
    ram.putWord(fixture.base + 7 * 4, secure_handler | 1);
    ram.putHalf(fixture.code, op);
    var cpu = try fixture.boot(ram);
    cpu.profile = profile;
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    cpu.regs.setSp(ns_sp);
    cpu.regs.set(1, target);
    cpu.regs.set(0, 0x1234_5678);
    return cpu;
}

fn expectAuviol(ram: *fixture.Ram, cpu: *Cpu) !void {
    try std.testing.expectEqual(@as(?cpu_mod.Stop, null), cpu.step());
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(auviol | sfarvalid, ram.word(sfsr));
    try std.testing.expectEqual(secure_word, ram.word(sfar));
    // SecureFault is taken Secure (RA8EMU-168): the frame is on the
    // Non-secure stack, parked in the other bank.
    try std.testing.expectEqual(fixture.code, ram.word(cpu.banked.other.msp + 24));
    try std.testing.expect(!cpu.bus.gate.?.armed);
}

fn refusedLoad(profile: Profile) !void {
    var ram: fixture.Ram = .{};
    ram.putWord(secure_word, 0xDEAD_BEEF);
    var split: Split = .{};
    var cpu = try nonSecure(&ram, profile, ldr_r0_r1, secure_word);
    var gate: Gate = .{ .source = split.source(), .current = &cpu.banked.current };
    cpu.bus.gate = &gate;
    try expectAuviol(&ram, &cpu);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), cpu.regs.get(0));
}

fn refusedStore(profile: Profile) !void {
    var ram: fixture.Ram = .{};
    var split: Split = .{};
    var cpu = try nonSecure(&ram, profile, str_r0_r1, secure_word);
    var gate: Gate = .{ .source = split.source(), .current = &cpu.banked.current };
    cpu.bus.gate = &gate;
    try expectAuviol(&ram, &cpu);
    try std.testing.expectEqual(@as(u32, 0), ram.word(secure_word));
}

test "a Non-secure load from Secure memory takes AUVIOL with SFAR, on the M85 and the M33" {
    try refusedLoad(Profile.m85);
    try refusedLoad(Profile.m33);
}

test "a Non-secure store to Secure memory takes AUVIOL and never lands, on both cores" {
    try refusedStore(Profile.m85);
    try refusedStore(Profile.m33);
}

test "a Non-secure load from Non-secure memory goes through" {
    for ([_]Profile{ Profile.m85, Profile.m33 }) |profile| {
        var ram: fixture.Ram = .{};
        ram.putWord(open_word, 0xCAFE_F00D);
        var split: Split = .{};
        var cpu = try nonSecure(&ram, profile, ldr_r0_r1, open_word);
        var gate: Gate = .{ .source = split.source(), .current = &cpu.banked.current };
        cpu.bus.gate = &gate;
        try std.testing.expectEqual(@as(?cpu_mod.Stop, null), cpu.step());
        try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.get(0));
        try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 0), ram.word(sfsr));
    }
}

test "a Secure core reaches Secure memory unchecked" {
    var ram: fixture.Ram = .{};
    ram.putWord(secure_word, 0xDEAD_BEEF);
    var split: Split = .{};
    var cpu = try nonSecure(&ram, Profile.m85, ldr_r0_r1, secure_word);
    cpu.banked.switchTo(&cpu.regs, .secure);
    var gate: Gate = .{ .source = split.source(), .current = &cpu.banked.current };
    cpu.bus.gate = &gate;
    try std.testing.expectEqual(@as(?cpu_mod.Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.regs.get(0));
}

test "the gate refuses nothing while disarmed and checks both ends of an access" {
    var split: Split = .{};
    var current: ra8.chip.core.banked.State = .non_secure;
    var gate: Gate = .{ .source = split.source(), .current = &current };
    try std.testing.expect(!gate.refuses(secure_word, 4));
    gate.armed = true;
    try std.testing.expect(gate.refuses(secure_word, 4));
    try std.testing.expectEqual(secure_word, gate.refused);
    try std.testing.expect(gate.refuses(secure_word - 2, 4));
    try std.testing.expectEqual(secure_word - 2, gate.refused);
    try std.testing.expect(!gate.refuses(secure_word - 4, 4));
    try std.testing.expect(!gate.refuses(secure_word, 0));
    current = .secure;
    try std.testing.expect(!gate.refuses(secure_word, 4));
}

test "a Non-secure FP op whose pending lazy push reaches Secure memory takes LSPERR with SFAR" {
    var ram: fixture.Ram = .{};
    var split: Split = .{};
    var cpu = try nonSecure(&ram, Profile.m85, 0, 0);
    ram.putHalf(fixture.code, 0xEE30); // vadd.f32 s0, s1, s2
    ram.putHalf(fixture.code + 2, 0x0A81);
    cpu.fp.context.writeFpcar(secure_word);
    cpu.fp.context.fpccr.lspact = 1;
    cpu.fp.context.fpccr.s = 0;
    var gate: Gate = .{ .source = split.source(), .current = &cpu.banked.current };
    cpu.bus.gate = &gate;
    try std.testing.expectEqual(@as(?cpu_mod.Stop, null), cpu.step());
    try std.testing.expectEqual(secure_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(lsperr | sfarvalid, ram.word(sfsr));
    try std.testing.expectEqual(secure_word, ram.word(sfar));
    try std.testing.expectEqual(@as(u32, 0), ram.word(secure_word));
    try std.testing.expectEqual(@as(u32, 1), cpu.fp.context.fpccr.lspact);
}
