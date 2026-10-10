//! FPRound worked by hand from the Arm ARM (DDI0553) pseudocode. Each vector
//! is an exact real, a rounding mode and FZ, and the bits plus cumulative
//! flags the pseudocode produces.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const format = ra8.chip.core.cpu.fpu.format;
const round = ra8.chip.core.cpu.fpu.round;
const fpscr_mod = ra8.chip.core.cpu.fpu.fpscr;
const Fpscr = fpscr_mod.Fpscr;
const RMode = fpscr_mod.RMode;
const Real = format.Real;

const In = struct { real: Real, mode: RMode = .nearest, fz: u1 = 0 };
const Out = struct { bits: u32, flags: u32 = 0 };
const V = vector.Vector(In, Out);

const ixc: u32 = 1 << 4;
const ufc: u32 = 1 << 3;
const ofc: u32 = 1 << 2;

fn round32(in: In) Out {
    var fpscr = Fpscr{ .fz = in.fz };
    const bits = round.round(format.single, in.real, &fpscr, in.mode);
    return .{ .bits = bits, .flags = fpscr.bits() & fpscr_mod.mask.cumulative };
}

fn r(sign: u1, mant: u128, exp: i32) Real {
    return .{ .sign = sign, .mant = mant, .exp = exp };
}

const one_and_half_ulp = r(0, (1 << 24) + 1, -24);

const single_vectors = [_]V{
    .{ .encoding = "FPRound", .name = "1.0 exact", .input = .{ .real = r(0, 1, 0) }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "FPRound", .name = "-1.0 exact", .input = .{ .real = r(1, 1, 0) }, .expect = .{ .bits = 0xBF80_0000 } },
    .{ .encoding = "FPRound", .name = "tie to even, RN", .input = .{ .real = one_and_half_ulp }, .expect = .{ .bits = 0x3F80_0000, .flags = ixc } },
    .{ .encoding = "FPRound", .name = "tie, RP", .input = .{ .real = one_and_half_ulp, .mode = .plus_inf }, .expect = .{ .bits = 0x3F80_0001, .flags = ixc } },
    .{ .encoding = "FPRound", .name = "tie, RM", .input = .{ .real = one_and_half_ulp, .mode = .minus_inf }, .expect = .{ .bits = 0x3F80_0000, .flags = ixc } },
    .{ .encoding = "FPRound", .name = "tie, RZ", .input = .{ .real = one_and_half_ulp, .mode = .zero }, .expect = .{ .bits = 0x3F80_0000, .flags = ixc } },
    .{ .encoding = "FPRound", .name = "0.75 ulp rounds up, RN", .input = .{ .real = r(0, (1 << 25) + 3, -25) }, .expect = .{ .bits = 0x3F80_0001, .flags = ixc } },
    .{ .encoding = "FPRound", .name = "carry into the exponent", .input = .{ .real = r(0, (1 << 25) - 1, -24) }, .expect = .{ .bits = 0x4000_0000, .flags = ixc } },
    .{ .encoding = "FPRound", .name = "largest normal exact", .input = .{ .real = r(0, 0xFF_FFFF, 104) }, .expect = .{ .bits = 0x7F7F_FFFF } },
    .{ .encoding = "FPRound", .name = "2^128 overflows to inf, RN", .input = .{ .real = r(0, 1, 128) }, .expect = .{ .bits = 0x7F80_0000, .flags = ofc | ixc } },
    .{ .encoding = "FPRound", .name = "2^128 overflows to max, RZ", .input = .{ .real = r(0, 1, 128), .mode = .zero }, .expect = .{ .bits = 0x7F7F_FFFF, .flags = ofc | ixc } },
    .{ .encoding = "FPRound", .name = "-2^128 to -max, RP", .input = .{ .real = r(1, 1, 128), .mode = .plus_inf }, .expect = .{ .bits = 0xFF7F_FFFF, .flags = ofc | ixc } },
    .{ .encoding = "FPRound", .name = "-2^128 to -inf, RM", .input = .{ .real = r(1, 1, 128), .mode = .minus_inf }, .expect = .{ .bits = 0xFF80_0000, .flags = ofc | ixc } },
    .{ .encoding = "FPRound", .name = "smallest denormal exact", .input = .{ .real = r(0, 1, -149) }, .expect = .{ .bits = 0x0000_0001 } },
    .{ .encoding = "FPRound", .name = "half the smallest denormal, RN", .input = .{ .real = r(0, 1, -150) }, .expect = .{ .bits = 0x0000_0000, .flags = ufc | ixc } },
    .{ .encoding = "FPRound", .name = "half the smallest denormal, RP", .input = .{ .real = r(0, 1, -150), .mode = .plus_inf }, .expect = .{ .bits = 0x0000_0001, .flags = ufc | ixc } },
    .{ .encoding = "FPRound", .name = "0.75 of the smallest denormal", .input = .{ .real = r(0, 3, -151) }, .expect = .{ .bits = 0x0000_0001, .flags = ufc | ixc } },
    .{ .encoding = "FPRound", .name = "tiny before rounding, carries to normal", .input = .{ .real = r(0, (1 << 24) - 1, -150) }, .expect = .{ .bits = 0x0080_0000, .flags = ufc | ixc } },
    .{ .encoding = "FPRound", .name = "FZ flushes a denormal result, UFC only", .input = .{ .real = r(1, 1, -149), .fz = 1 }, .expect = .{ .bits = 0x8000_0000, .flags = ufc } },
    .{ .encoding = "FPRound", .name = "FZ leaves the smallest normal alone", .input = .{ .real = r(0, 1, -126), .fz = 1 }, .expect = .{ .bits = 0x0080_0000 } },
    .{ .encoding = "FPRound", .name = "far below the format, RN", .input = .{ .real = r(0, 1, -400) }, .expect = .{ .bits = 0x0000_0000, .flags = ufc | ixc } },
};

test "single-precision FPRound matches the pseudocode" {
    try vector.expectAll(In, Out, round32, &single_vectors);
}

test "double precision rounds 1 + 2^-53 to 1.0 under RN and flags inexact" {
    var fpscr = Fpscr{};
    const bits = round.round(format.double, r(0, (1 << 53) + 1, -53), &fpscr, .nearest);
    try std.testing.expectEqual(@as(u64, 0x3FF0_0000_0000_0000), bits);
    try std.testing.expectEqual(@as(u1, 1), fpscr.ixc);
}

test "double precision keeps the smallest denormal exact" {
    var fpscr = Fpscr{};
    try std.testing.expectEqual(@as(u64, 1), round.round(format.double, r(0, 1, -1074), &fpscr, .nearest));
    try std.testing.expectEqual(Fpscr{}, fpscr);
}

test "scale splits the cut-off bits into the four error classes" {
    try std.testing.expectEqual(round.Err.none, round.scale(0b100, -2).err);
    try std.testing.expectEqual(round.Err.below_half, round.scale(0b101, -2).err);
    try std.testing.expectEqual(round.Err.half, round.scale(0b110, -2).err);
    try std.testing.expectEqual(round.Err.above_half, round.scale(0b111, -2).err);
    try std.testing.expectEqual(@as(u128, 1), round.scale(0b111, -2).int);
    try std.testing.expectEqual(round.Err.half, round.scale(@as(u128, 1) << 127, -128).err);
}
