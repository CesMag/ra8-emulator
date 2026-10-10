//! Covers src/chip/core/cpu/fpu/scb.zig.
const std = @import("std");
const ra8 = @import("ra8");
const scb = ra8.chip.core.cpu.fpu.scb;
const State = ra8.chip.core.cpu.fpu.state.State;
const control_bits = ra8.chip.core.cpu.regs.control_bits;

test "each word reads back what the context holds, through its mask" {
    var state: State = .{};
    try std.testing.expect(scb.write(&state, scb.address.fpccr, 0xFFFF_FFFF));
    try std.testing.expect(scb.write(&state, scb.address.fpcar, 0x2000_0107));
    try std.testing.expect(scb.write(&state, scb.address.fpdscr, 0x0340_0000));
    try std.testing.expectEqual(state.context.readFpccr(), scb.read(&state, scb.address.fpccr).?);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), scb.read(&state, scb.address.fpcar).?);
    try std.testing.expectEqual(state.context.fpdscr, scb.read(&state, scb.address.fpdscr).?);
}

test "an FPDSCR write sets the FPSCR the next new context starts with" {
    var state: State = .{};
    _ = scb.write(&state, scb.address.fpdscr, 0x0340_0000);
    const control = state.context.touch(
        0,
        .secure,
        &state.fpscr,
        &state.vpr,
    );
    try std.testing.expect(control & control_bits.fpca != 0);
    try std.testing.expectEqual(state.context.fpdscr, state.fpscr.bits());
    try std.testing.expect(state.fpscr.bits() & 0x0340_0000 != 0);
}

test "other addresses are not this file's" {
    var state: State = .{};
    try std.testing.expect(scb.read(&state, 0xE000_EF30) == null);
    try std.testing.expect(!scb.write(&state, 0xE000_EF40, 1));
}

test "CPACR keeps CP10 and CP11 and starts with the FPU off" {
    var state: State = .{};
    try std.testing.expectEqual(@as(u32, 0), scb.read(&state, scb.address.cpacr).?);
    try std.testing.expect(scb.write(&state, scb.address.cpacr, 0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u32, 0x00F0_0000), scb.read(&state, scb.address.cpacr).?);
    const cpacr = ra8.chip.core.cpu.fpu.cpacr;
    try std.testing.expectEqual(cpacr.Access.full, cpacr.access(state.cpacr));
}
