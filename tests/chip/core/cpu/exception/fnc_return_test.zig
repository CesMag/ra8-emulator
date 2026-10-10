//! Covers src/chip/core/cpu/exception/fnc_return.zig: a Secure BLXNS into a
//! Non-secure function and the branch to FNC_RETURN that comes back, run as
//! whole instructions on the Zig core.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const fnc_return = ra8.chip.core.cpu.exception.fnc_return;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const State = ra8.chip.core.banked.State;

const blxns_r0: u16 = 0x4784;
const bx_lr: u16 = 0x4770;
const push_lr: u16 = 0xB500;
const pop_pc: u16 = 0xBD00;
const sfpa: u32 = 1 << 3;
const ns_sp: u32 = fixture.base + 0x280;

/// A Secure core at fixture.code about to BLXNS to the Non-secure function
/// at fixture.handler, whose body is `body`.
fn caller(ram: *fixture.Ram, body: []const u16) !Cpu {
    ram.putHalf(fixture.code, blxns_r0);
    ram.putHalf(fixture.code + 2, 0xBF00); // nop
    for (body, 0..) |half, i| ram.putHalf(fixture.handler + 2 * @as(u32, @intCast(i)), half);
    var cpu = try fixture.boot(ram);
    cpu.banked.other.msp = ns_sp;
    cpu.regs.low[0] = fixture.handler;
    return cpu;
}

fn steps(cpu: *Cpu, n: usize) !void {
    for (0..n) |_| try std.testing.expectEqual(@as(?ra8.chip.core.cpu.cpu.Stop, null), cpu.step());
}

test "BLXNS then BX LR comes back to Secure after the call with the frame popped" {
    var ram: fixture.Ram = .{};
    var cpu = try caller(&ram, &.{bx_lr});
    try steps(&cpu, 1);
    try std.testing.expectEqual(State.non_secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.msp_top - 8, cpu.banked.other.msp);
    try steps(&cpu, 1);
    try std.testing.expectEqual(State.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(ns_sp, cpu.banked.other.msp);
    try std.testing.expect(cpu.regs.xpsr & ra8.chip.core.cpu.regs.xpsr_bits.thumb != 0);
    try std.testing.expectEqual(@as(?u32, null), cpu.regs.fnc_return);
    try steps(&cpu, 1); // the nop after the call runs Secure
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
}

test "POP {PC} to FNC_RETURN returns the same way" {
    var ram: fixture.Ram = .{};
    var cpu = try caller(&ram, &.{ push_lr, pop_pc });
    try steps(&cpu, 3);
    try std.testing.expectEqual(State.secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(ns_sp, cpu.banked.other.msp);
}

test "a call from Handler mode gets its IPSR and SFPA back" {
    var ram: fixture.Ram = .{};
    var cpu = try caller(&ram, &.{bx_lr});
    cpu.regs.xpsr |= 11;
    cpu.regs.control |= sfpa;
    try steps(&cpu, 1);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.xpsr & 0x1FF);
    try steps(&cpu, 1);
    try std.testing.expectEqual(State.secure, cpu.banked.current);
    try std.testing.expectEqual(@as(u32, 11), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(sfpa, cpu.regs.control & sfpa);
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
}

test "a frame that disagrees with the mode is refused and stays put" {
    var ram: fixture.Ram = .{};
    var cpu = try caller(&ram, &.{bx_lr});
    try steps(&cpu, 1);
    ram.putWord(fixture.msp_top - 4, 5); // RETPSR claims an exception in Thread mode
    try std.testing.expectError(error.InconsistentFrame, fnc_return.from(&cpu));
    try std.testing.expectEqual(State.non_secure, cpu.banked.current);
    try std.testing.expectEqual(fixture.msp_top - 8, cpu.banked.other.msp);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
}

test "consistency follows the Arm ARM: Thread with 0, or IPSR 1 with nonzero" {
    try std.testing.expect(fnc_return.consistent(0, 0));
    try std.testing.expect(fnc_return.consistent(1, 11));
    try std.testing.expect(!fnc_return.consistent(0, 11));
    try std.testing.expect(!fnc_return.consistent(1, 0));
    try std.testing.expect(!fnc_return.consistent(3, 3));
}

test "only bits 31:24 of 0xFE are FNC_RETURN, in Thread mode too" {
    var r: ra8.chip.core.cpu.regs.Regs = .{};
    r.bxWritePc(0xFEFF_FFFF);
    try std.testing.expectEqual(@as(?u32, 0xFEFF_FFFF), r.fnc_return);
    r.fnc_return = null;
    r.bxWritePc(0xFFFF_FFF9); // Thread mode: not an exception return either
    try std.testing.expectEqual(@as(?u32, null), r.fnc_return);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF8), r.pc);
}
