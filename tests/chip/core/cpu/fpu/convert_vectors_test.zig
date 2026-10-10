const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.convert_vectors;
const single = fpu.format.single;
const double = fpu.format.double;

fn widen(in: case.Unary(u32)) case.Result(u64) {
    var fpscr = in.fpscr();
    const bits = fpu.convert.convert(single, double, in.a, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn narrow(in: case.Unary(u64)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.convert.convert(double, single, in.a, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VCVT.F64.F32 matches FPConvert" {
    try vector.expectAll(case.Unary(u32), case.Result(u64), widen, &vectors.widen);
}

test "VCVT.F32.F64 matches FPConvert" {
    try vector.expectAll(case.Unary(u64), case.Result(u32), narrow, &vectors.narrow);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.widen.len + vectors.narrow.len, vectors.covered.len);
}
