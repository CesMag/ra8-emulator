const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.rint_vectors;

fn rint32(in: case.Integral(u32)) case.Result(u32) {
    var fpscr = in.fpscr();
    const bits = fpu.rint.rint(fpu.format.single, in.a, in.rounding, in.exact, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn rint64(in: case.Integral(u64)) case.Result(u64) {
    var fpscr = in.fpscr();
    const bits = fpu.rint.rint(fpu.format.double, in.a, in.rounding, in.exact, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VRINT .F32 forms match FPRoundInt" {
    try vector.expectAll(case.Integral(u32), case.Result(u32), rint32, &vectors.rint32);
}

test "VRINT .F64 forms match FPRoundInt" {
    try vector.expectAll(case.Integral(u64), case.Result(u64), rint64, &vectors.rint64);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.rint32.len + vectors.rint64.len, vectors.covered.len);
}
