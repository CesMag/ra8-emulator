const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.fixed_vectors;
const single = fpu.format.single;
const double = fpu.format.double;

fn toSingle(in: case.Fraction(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.fixed.toFixed(single, in.a, in.width, in.fbits, in.unsigned, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn toDouble(in: case.Fraction(u64)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.fixed.toFixed(double, in.a, in.width, in.fbits, in.unsigned, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn fromSingle(in: case.Fraction(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.fixed.fromFixed(single, in.a, in.width, in.fbits, in.unsigned, in.mode, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn fromDouble(in: case.Fraction(u32)) case.Result(u64) {
    var fpscr = in.fpscr();
    const bits = fpu.fixed.fromFixed(double, in.a, in.width, in.fbits, in.unsigned, in.mode, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VCVT to fixed point from F32 matches FPToFixed" {
    try vector.expectAll(case.Fraction(u32), case.Result(u32), toSingle, &vectors.to_single);
}

test "VCVT to fixed point from F64 matches FPToFixed" {
    try vector.expectAll(case.Fraction(u64), case.Result(u32), toDouble, &vectors.to_double);
}

test "VCVT from fixed point to F32 matches FixedToFP" {
    try vector.expectAll(case.Fraction(u32), case.Result(u32), fromSingle, &vectors.from_single);
}

test "VCVT from fixed point to F64 matches FixedToFP" {
    try vector.expectAll(case.Fraction(u32), case.Result(u64), fromDouble, &vectors.from_double);
}

test "every vector is counted in covered" {
    const n = vectors.to_single.len + vectors.to_double.len + vectors.from_single.len + vectors.from_double.len;
    try std.testing.expectEqual(n, vectors.covered.len);
}
