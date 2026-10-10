//! Covers src/chip/core/cpu/fpu/lazy.zig: PreserveFPState() writing the FP
//! context into the space FPCAR names, per the Arm ARM (DDI0553) extended
//! frame (S0 at FPCAR, FPSCR at +0x40, VPR at +0x44).
const std = @import("std");
const ra8 = @import("ra8");
const lazy = ra8.chip.core.cpu.fpu.lazy;
const State = ra8.chip.core.cpu.fpu.state.State;
const fixture = @import("../exception/ram.zig");

fn sample() State {
    var s: State = .{};
    for (0..16) |i| s.bank.writeS(@intCast(i), 0x3F80_0000 + @as(u32, @intCast(i)));
    s.bank.writeS(16, 0xDEAD_BEEF);
    s.fpscr = @bitCast(@as(u32, 0x8004_0001));
    s.vpr = @bitCast(@as(u32, 0x0021_00FF));
    return s;
}

test "nothing is pending out of reset" {
    const s: State = .{};
    try std.testing.expect(!lazy.pending(&s));
}

test "preserve writes S0-S15, FPSCR and VPR at FPCAR and clears LSPACT" {
    var ram: fixture.Ram = .{};
    var s = sample();
    const at = fixture.msp_top - 0x48;
    s.context.writeFpcar(at);
    s.context.fpccr.lspact = 1;
    try std.testing.expect(lazy.pending(&s));
    try lazy.preserve(ram.view(), &s);
    try std.testing.expect(!lazy.pending(&s));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(at));
    try std.testing.expectEqual(@as(u32, 0x3F80_000F), ram.word(at + 0x3C));
    try std.testing.expectEqual(@as(u32, 0x8004_0001), ram.word(at + 0x40));
    try std.testing.expectEqual(@as(u32, 0x0021_00FF), ram.word(at + 0x44));
}

test "SPLIMVIOL: preserve writes nothing but still clears LSPACT" {
    var ram: fixture.Ram = .{};
    var s = sample();
    const at = fixture.msp_top - 0x48;
    s.context.writeFpcar(at);
    s.context.fpccr.lspact = 1;
    s.context.fpccr.splimviol = 1;
    try lazy.preserve(ram.view(), &s);
    try std.testing.expect(!lazy.pending(&s));
    try std.testing.expectEqual(@as(u32, 0), ram.word(at));
    try std.testing.expectEqual(@as(u32, 0), ram.word(at + 0x40));
}

test "S16 and up stay out of the non-Secure frame" {
    var ram: fixture.Ram = .{};
    var s = sample();
    const at = fixture.msp_top - 0x48;
    s.context.writeFpcar(at - 8);
    ram.putWord(at - 8 + 0x48, 0x1234_5678);
    s.context.fpccr.lspact = 1;
    try lazy.preserve(ram.view(), &s);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), ram.word(at - 8 + 0x48));
}

test "an unmapped FPCAR is a bus error and LSPACT stays set" {
    var ram: fixture.Ram = .{};
    var s = sample();
    s.context.writeFpcar(0x1000_0000);
    s.context.fpccr.lspact = 1;
    try std.testing.expectError(error.Unmapped, lazy.preserve(ram.view(), &s));
    try std.testing.expect(lazy.pending(&s));
}

test "a Secure context with FPCCR.TS also writes S16-S31 from 0x48" {
    var ram: fixture.Ram = .{};
    var s = sample();
    for (16..32) |i| s.bank.writeS(@intCast(i), 0x4000_0000 + @as(u32, @intCast(i)));
    const at = fixture.msp_top - 0x88;
    s.context.writeFpcar(at);
    s.context.fpccr.lspact = 1;
    s.context.fpccr.s = 1;
    s.context.fpccr.ts = 1;
    try lazy.preserve(ram.view(), &s);
    try std.testing.expectEqual(@as(u32, 0x0021_00FF), ram.word(at + 0x44));
    try std.testing.expectEqual(@as(u32, 0x4000_0010), ram.word(at + 0x48));
    try std.testing.expectEqual(@as(u32, 0x4000_001F), ram.word(at + 0x84));
}

const cpu_mod = ra8.chip.core.cpu.cpu;
const Gate = cpu_mod.data_gate.Gate;
/// Everything from here up is Secure; below it is Non-secure.
const secure_from: u32 = fixture.base + 0x300;

const Split = struct {
    fn of(context: *anyopaque, address: u32) cpu_mod.attribution.State {
        _ = context;
        return if (address >= secure_from) .secure else .non_secure;
    }

    fn source(self: *Split) cpu_mod.attribution.Attribution {
        return .{ .context = self, .stateFn = of };
    }
};

/// A pending push at `at` for a context of security `s`, behind an armed
/// gate while Non-secure code runs.
fn behindGate(ram: *fixture.Ram, gate: *Gate, at: u32, s: u1) !void {
    var state = sample();
    state.context.writeFpcar(at);
    state.context.fpccr.lspact = 1;
    state.context.fpccr.s = s;
    var view = ram.view();
    view.gate = gate;
    gate.armed = true;
    const result = lazy.preserve(view, &state);
    try std.testing.expect(gate.armed);
    try std.testing.expectEqual(std.meta.isError(result), lazy.pending(&state));
    return result;
}

test "a Non-secure context's push into Secure memory is LSPERR and writes nothing" {
    var ram: fixture.Ram = .{};
    var split: Split = .{};
    var current: ra8.chip.core.banked.State = .non_secure;
    var gate: Gate = .{ .source = split.source(), .current = &current };
    try std.testing.expectError(error.LazyPreserveError, behindGate(&ram, &gate, secure_from, 0));
    try std.testing.expectEqual(@as(u32, 0), ram.word(secure_from));
    // Only its far end Secure is refused too.
    try std.testing.expectError(error.LazyPreserveError, behindGate(&ram, &gate, secure_from - 0x40, 0));
    // Secure code running does not change whose push it is.
    current = .secure;
    try std.testing.expectError(error.LazyPreserveError, behindGate(&ram, &gate, secure_from, 0));
}

test "a Non-secure context's push into Non-secure memory lands" {
    var ram: fixture.Ram = .{};
    var split: Split = .{};
    var current: ra8.chip.core.banked.State = .non_secure;
    var gate: Gate = .{ .source = split.source(), .current = &current };
    const at = secure_from - 0x48;
    try behindGate(&ram, &gate, at, 0);
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(at));
}

test "a Secure context's push lands in Secure memory while Non-secure code runs" {
    var ram: fixture.Ram = .{};
    var split: Split = .{};
    var current: ra8.chip.core.banked.State = .non_secure;
    var gate: Gate = .{ .source = split.source(), .current = &current };
    try behindGate(&ram, &gate, secure_from, 1);
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(secure_from));
    try std.testing.expectEqual(@as(u32, 0x0021_00FF), ram.word(secure_from + 0x44));
}
