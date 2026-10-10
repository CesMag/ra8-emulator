//! RA8EMU-484 (the lockstep clause of RA8EMU-380): a Non-secure call through
//! an NSC veneer into a Secure callee that uses FP, stepped one instruction
//! at a time through Cpu.step on the Zig core. There is no lockstep oracle
//! for SG or BXNS (blxns_test, "BLXNS has no lockstep oracle"), so
//! this register trace is the reference the ticket asks for instead of a
//! lockstep row. Encodings from arm-none-eabi-as 13.3
//! -march=armv8.1-m.main+mve.fp+fp.dp:
//!   sg                       E97F E97F
//!   vadd.f32 s0, s1, s2      EE30 0A81
//!   vscclrm {s0-s15, vpr}    EC9F 0A10
//!   bxns lr                  4774
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("../exception/ram.zig");
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Attribution = ra8.chip.core.cpu.cpu.attribution.Attribution;
const State = ra8.chip.core.cpu.cpu.attribution.State;
const Banked = ra8.chip.core.banked.State;

const sfpa = ra8.chip.core.cpu.regs.control_bits.sfpa;
const ns_sp: u32 = fixture.base + 0x280;
const veneer = [_]u16{ 0xE97F, 0xE97F, 0xEE30, 0x0A81, 0xEC9F, 0x0A10, 0x4774 };
const one: u32 = 0x3F80_0000;
const two: u32 = 0x4000_0000;
const three: u32 = 0x4040_0000;
const marker: u32 = 0x4120_0000;

/// Every address is Secure and Non-secure callable, so SG is a valid entry
/// and the callee runs from the same Secure memory.
const Callable = struct {
    fn of(context: *anyopaque, address: u32) State {
        _ = context;
        _ = address;
        return .callable;
    }
};

/// A Non-secure caller about to fetch the veneer: LR holds its return with
/// bit 0 set, as BL leaves it, and the S registers carry known values.
fn caller(ram: *fixture.Ram, context: *u8) !Cpu {
    for (veneer, 0..) |half, i| ram.putHalf(fixture.code + 2 * @as(u32, @intCast(i)), half);
    var cpu = try fixture.boot(ram);
    cpu.attribution = Attribution{ .context = context, .stateFn = Callable.of };
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    cpu.regs.setSp(ns_sp);
    cpu.regs.lr = fixture.handler | 1;
    cpu.regs.pc = fixture.code;
    var n: u5 = 0;
    while (n < 16) : (n += 1) cpu.fp.bank.writeS(n, marker);
    cpu.fp.bank.writeS(1, one);
    cpu.fp.bank.writeS(2, two);
    cpu.fp.bank.writeS(16, marker);
    cpu.fp.vpr = @bitCast(@as(u32, 0x0000_FFFF));
    return cpu;
}

fn step(cpu: *Cpu) !void {
    if (cpu.step()) |stop| {
        std.debug.print("unexpected stop at 0x{X:0>8}: {s}\n", .{ cpu.regs.pc, @tagName(stop) });
        return error.Stopped;
    }
}

test "SG enters Secure state with SFPA clear and LR marked for BXNS" {
    var ram: fixture.Ram = .{};
    var context: u8 = 0;
    var cpu = try caller(&ram, &context);
    try step(&cpu);
    try std.testing.expectEqual(Banked.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.lr);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.control & sfpa);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
}

test "the callee's first FP instruction sets CONTROL_S.SFPA and computes" {
    var ram: fixture.Ram = .{};
    var context: u8 = 0;
    var cpu = try caller(&ram, &context);
    try step(&cpu);
    try step(&cpu);
    try std.testing.expectEqual(sfpa, cpu.regs.control & sfpa);
    try std.testing.expectEqual(three, cpu.fp.bank.readS(0));
}

test "VSCCLRM clears S0-S15 and VPR and leaves S16" {
    var ram: fixture.Ram = .{};
    var context: u8 = 0;
    var cpu = try caller(&ram, &context);
    for (0..3) |_| try step(&cpu);
    var n: u5 = 0;
    while (n < 16) : (n += 1) try std.testing.expectEqual(@as(u32, 0), cpu.fp.bank.readS(n));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(cpu.fp.vpr)));
    try std.testing.expectEqual(marker, cpu.fp.bank.readS(16));
}

test "BXNS LR returns to the Non-secure caller" {
    var ram: fixture.Ram = .{};
    var context: u8 = 0;
    var cpu = try caller(&ram, &context);
    for (0..4) |_| try step(&cpu);
    try std.testing.expectEqual(Banked.non_secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(ns_sp, cpu.regs.sp());
}
