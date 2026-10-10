const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const fpu = ra8.chip.core.cpu.fpu;
const case = fpu.case;
const vectors = fpu.minmax_vectors;
const In32 = case.Binary(u32);
const Out32 = case.Result(u32);
const In64 = case.Binary(u64);
const Out64 = case.Result(u64);

fn max32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = fpu.minmax.num(fpu.format.single, in.a, in.b, .max, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn min32(in: In32) Out32 {
    var fpscr = in.fpscr();
    const bits = fpu.minmax.num(fpu.format.single, in.a, in.b, .min, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn max64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = fpu.minmax.num(fpu.format.double, in.a, in.b, .max, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

fn min64(in: In64) Out64 {
    var fpscr = in.fpscr();
    const bits = fpu.minmax.num(fpu.format.double, in.a, in.b, .min, &fpscr);
    return .{ .bits = bits, .flags = case.flagsOf(fpscr) };
}

test "VMAXNM.F32 matches FPMaxNum" {
    try vector.expectAll(In32, Out32, max32, &vectors.max32);
}

test "VMINNM.F32 matches FPMinNum" {
    try vector.expectAll(In32, Out32, min32, &vectors.min32);
}

test "VMAXNM.F64 matches FPMaxNum" {
    try vector.expectAll(In64, Out64, max64, &vectors.max64);
}

test "VMINNM.F64 matches FPMinNum" {
    try vector.expectAll(In64, Out64, min64, &vectors.min64);
}

test "every vector is counted in covered" {
    const n = vectors.max32.len + vectors.min32.len + vectors.max64.len + vectors.min64.len;
    try std.testing.expectEqual(n, vectors.covered.len);
}
