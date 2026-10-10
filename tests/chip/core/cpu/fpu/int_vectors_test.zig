const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.int_vectors;
const single = fpu.format.single;
const double = fpu.format.double;

fn fromSingle(in: case.Fixed(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.to_int.toFixed(single, in.a, 0, in.unsigned, in.mode, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn fromDouble(in: case.Fixed(u64)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.to_int.toFixed(double, in.a, 0, in.unsigned, in.mode, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn toSingle(in: case.Fixed(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.from_int.fromFixed(single, in.a, 0, in.unsigned, in.mode, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn toDouble(in: case.Fixed(u32)) case.Result(u64) {
    var fpscr = in.fpscr();
    const bits = fpu.from_int.fromFixed(double, in.a, 0, in.unsigned, in.mode, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VCVT/VCVTR from F32 to an integer match FPToFixed" {
    try vector.expectAll(case.Fixed(u32), case.Result(u32), fromSingle, &vectors.from_single);
}

test "VCVT/VCVTR from F64 to an integer match FPToFixed" {
    try vector.expectAll(case.Fixed(u64), case.Result(u32), fromDouble, &vectors.from_double);
}

test "VCVT from an integer to F32 matches FixedToFP" {
    try vector.expectAll(case.Fixed(u32), case.Result(u32), toSingle, &vectors.to_single);
}

test "VCVT from an integer to F64 matches FixedToFP" {
    try vector.expectAll(case.Fixed(u32), case.Result(u64), toDouble, &vectors.to_double);
}

test "every vector is counted in covered" {
    const n = vectors.from_single.len + vectors.from_double.len + vectors.to_single.len + vectors.to_double.len;
    try std.testing.expectEqual(n, vectors.covered.len);
}
