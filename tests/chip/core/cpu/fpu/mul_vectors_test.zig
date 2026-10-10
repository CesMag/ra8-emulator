const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const format = ra8.chip.core.cpu.fpu.format;
const mul = ra8.chip.core.cpu.fpu.mul;
const case = ra8.chip.core.cpu.fpu.case;
const vectors = ra8.chip.core.cpu.fpu.mul_vectors;

const In32 = case.Binary(u32);
const Out32 = case.Result(u32);
const In64 = case.Binary(u64);
const Out64 = case.Result(u64);

fn mul32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = mul.mul(format.single, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn nmul32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = mul.nmul(format.single, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn mul64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = mul.mul(format.double, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn nmul64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = mul.nmul(format.double, in.a, in.b, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VMUL.F32 matches FPMul" {
    try vector.expectAll(In32, Out32, mul32, &vectors.mul32);
}

test "VNMUL.F32 matches FPNeg(FPMul)" {
    try vector.expectAll(In32, Out32, nmul32, &vectors.nmul32);
}

test "VMUL.F64 matches FPMul" {
    try vector.expectAll(In64, Out64, mul64, &vectors.mul64);
}

test "VNMUL.F64 matches FPNeg(FPMul)" {
    try vector.expectAll(In64, Out64, nmul64, &vectors.nmul64);
}

test "every vector is counted in covered" {
    const total = vectors.mul32.len + vectors.nmul32.len + vectors.mul64.len + vectors.nmul64.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}
