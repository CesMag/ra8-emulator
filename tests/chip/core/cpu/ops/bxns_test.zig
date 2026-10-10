//! Covers src/chip/core/cpu/ops/bxns.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bxns = ra8.chip.core.cpu.ops.bxns;
const fixture = @import("../exception/ram.zig");
const Instr = ra8.chip.core.cpu.instr.Instr;
const State = ra8.chip.core.banked.State;

fn claims(hw1: u16) bool {
    return bxns.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) != null;
}

fn at(hw1: u16) Instr {
    return .{ .address = fixture.code, .hw1 = hw1, .size = 2 };
}

test "BXNS claims every Rm but SP and PC, and leaves BX and BLXNS" {
    try std.testing.expect(claims(0x4704)); // bxns r0
    try std.testing.expect(claims(0x4774)); // bxns lr
    try std.testing.expect(!claims(0x476C)); // bxns sp
    try std.testing.expect(!claims(0x477C)); // bxns pc
    try std.testing.expect(!claims(0x4700)); // bx r0
    try std.testing.expect(!claims(0x4784)); // blxns r0
    try std.testing.expect(bxns.group.decode(.{ .address = 0, .hw1 = 0x4704, .hw2 = 0, .size = 4 }) == null);
}

test "BXNS to a target with bit 0 clear switches to Non-secure and banks the stack" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.banked.other.msp = fixture.base + 0x280;
    cpu.regs.low[0] = fixture.handler;
    try bxns.group.decode(at(0x4704)).?(&cpu, at(0x4704));
    try std.testing.expectEqual(State.non_secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(fixture.base + 0x280, cpu.regs.sp());
    try std.testing.expectEqual(fixture.msp_top, cpu.banked.other.msp);
}

test "BXNS trades the masks and banked CONTROL bits with the Non-secure bank" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.primask = 1;
    cpu.regs.basepri = 0x40;
    cpu.regs.control = 1; // nPRIV, Secure
    cpu.banked.other.faultmask = 1;
    cpu.banked.other.control = 2; // SPSEL, Non-secure
    cpu.banked.other.psp = fixture.base + 0x2C0;
    cpu.regs.low[0] = fixture.handler;
    try bxns.group.decode(at(0x4704)).?(&cpu, at(0x4704));
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.primask);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.basepri);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.faultmask);
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.control & 3);
    try std.testing.expectEqual(fixture.base + 0x2C0, cpu.regs.sp()); // Thread mode on PSP_NS
    try std.testing.expectEqual(@as(u32, 1), cpu.banked.other.primask);
    try std.testing.expectEqual(@as(u32, 1), cpu.banked.other.control & 3);
}

test "BXNS to a target with bit 0 set stays Secure and branches like BX" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.regs.lr = fixture.handler | 1;
    try bxns.group.decode(at(0x4774)).?(&cpu, at(0x4774));
    try std.testing.expectEqual(State.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.sp());
}

test "BXNS in Non-secure state is UNDEFINED" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    try std.testing.expectError(error.Undefined, bxns.group.decode(at(0x4704)).?(&cpu, at(0x4704)));
}
