//! Covers src/chip/core/cpu/shift.zig.
const std = @import("std");
const ra8 = @import("ra8");
const shift = ra8.chip.core.cpu.shift;

const Case = struct { value: u32, kind: shift.Kind, amount: u32, result: u32, carry: bool };

test "Shift_C matches the pseudocode, carry in clear" {
    const cases = [_]Case{
        .{ .value = 0x8000_0001, .kind = .lsl, .amount = 1, .result = 0x0000_0002, .carry = true },
        .{ .value = 0x0000_0001, .kind = .lsl, .amount = 31, .result = 0x8000_0000, .carry = false },
        .{ .value = 0x0000_0001, .kind = .lsl, .amount = 32, .result = 0, .carry = true },
        .{ .value = 0xFFFF_FFFF, .kind = .lsl, .amount = 33, .result = 0, .carry = false },
        .{ .value = 0x8000_0003, .kind = .lsr, .amount = 1, .result = 0x4000_0001, .carry = true },
        .{ .value = 0x8000_0000, .kind = .lsr, .amount = 32, .result = 0, .carry = true },
        .{ .value = 0x8000_0000, .kind = .asr, .amount = 4, .result = 0xF800_0000, .carry = false },
        .{ .value = 0x8000_0000, .kind = .asr, .amount = 32, .result = 0xFFFF_FFFF, .carry = true },
        .{ .value = 0x7FFF_FFFF, .kind = .asr, .amount = 40, .result = 0, .carry = false },
        .{ .value = 0x0000_0001, .kind = .ror, .amount = 1, .result = 0x8000_0000, .carry = true },
        .{ .value = 0x1234_5678, .kind = .ror, .amount = 32, .result = 0x1234_5678, .carry = false },
    };
    for (cases) |case| {
        const out = shift.shiftC(case.value, case.kind, case.amount, false);
        try std.testing.expectEqual(case.result, out.result);
        try std.testing.expectEqual(case.carry, out.carry);
    }
}

test "a zero amount keeps the value and the carry in" {
    const out = shift.shiftC(0x55, .lsr, 0, true);
    try std.testing.expectEqual(@as(u32, 0x55), out.result);
    try std.testing.expect(out.carry);
}

test "an immediate of zero means 32 for LSR and ASR only" {
    try std.testing.expectEqual(@as(u6, 32), shift.immAmount(.lsr, 0));
    try std.testing.expectEqual(@as(u6, 32), shift.immAmount(.asr, 0));
    try std.testing.expectEqual(@as(u6, 0), shift.immAmount(.lsl, 0));
    try std.testing.expectEqual(@as(u6, 7), shift.immAmount(.lsr, 7));
}

test "rrx rotates the carry into bit 31 and bit 0 out" {
    const out = shift.rrx(0x0000_0003, true);
    try std.testing.expectEqual(@as(u32, 0x8000_0001), out.result);
    try std.testing.expect(out.carry);
}

test "immShiftC reads ROR #0 as RRX and LSR #0 as a shift of 32" {
    try std.testing.expectEqual(@as(u32, 0x0000_0001), shift.immShiftC(0x0000_0002, .ror, 0, false).result);
    const lsr32 = shift.immShiftC(0x8000_0000, .lsr, 0, false);
    try std.testing.expectEqual(@as(u32, 0), lsr32.result);
    try std.testing.expect(lsr32.carry);
}
