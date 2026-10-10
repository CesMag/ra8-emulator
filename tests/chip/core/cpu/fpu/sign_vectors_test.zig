const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const sign = ra8.chip.core.cpu.fpu.sign;
const vectors = ra8.chip.core.cpu.fpu.sign_vectors;

test "VNEG.F32 matches FPNeg" {
    try vector.expectAll(u32, u32, sign.neg32, &vectors.neg32);
}

test "VABS.F32 matches FPAbs" {
    try vector.expectAll(u32, u32, sign.abs32, &vectors.abs32);
}

test "VNEG.F64 matches FPNeg" {
    try vector.expectAll(u64, u64, sign.neg64, &vectors.neg64);
}

test "VABS.F64 matches FPAbs" {
    try vector.expectAll(u64, u64, sign.abs64, &vectors.abs64);
}

test "every vector is counted in covered" {
    const total = vectors.neg32.len + vectors.abs32.len + vectors.neg64.len + vectors.abs64.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}
