const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.sqrt.vectors;

const In32 = case.Unary(u32);
const Out32 = case.Result(u32);
const In64 = case.Unary(u64);
const Out64 = case.Result(u64);

fn sqrt32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = fpu.sqrt.sqrt(fpu.format.single, in.a, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn sqrt64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = fpu.sqrt.sqrt(fpu.format.double, in.a, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VSQRT.F32 matches FPSqrt" {
    try vector.expectAll(In32, Out32, sqrt32, &vectors.sqrt32);
}

test "VSQRT.F64 matches FPSqrt" {
    try vector.expectAll(In64, Out64, sqrt64, &vectors.sqrt64);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.sqrt32.len + vectors.sqrt64.len, vectors.covered.len);
}
