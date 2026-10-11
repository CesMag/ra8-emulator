//! Covers src/chip/core/cpu/mve/int_mul_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const int = ra8.chip.core.cpu.mve.int;
const mul = ra8.chip.core.cpu.mve.int_mul;
const vectors = ra8.chip.core.cpu.mve.int_mul_vectors;

fn high(in: vectors.HighCase) int.Sat {
    return mul.multiplyHigh(in.a, in.b, in.size, in.high);
}

fn scalar(in: vectors.ScalarCase) u128 {
    return mul.multiplyAddScalar(in.da, in.n, in.scalar, in.size, in.form);
}

fn doubling(in: vectors.DoublingCase) int.Sat {
    return mul.doublingMultiplyAccumulateHigh(in.da, in.n, in.scalar, in.size, in.form);
}

test "VMULH, VRMULH, VQDMULH and VQRDMULH match the pseudocode" {
    try vector.expectAll(vectors.HighCase, int.Sat, high, &vectors.high);
}

test "VMLA and VMLAS match the pseudocode" {
    try vector.expectAll(vectors.ScalarCase, u128, scalar, &vectors.scalar);
}

test "VQDMLAH, VQRDMLAH, VQDMLASH and VQRDMLASH match the pseudocode" {
    try vector.expectAll(vectors.DoublingCase, int.Sat, doubling, &vectors.doubling);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.high.len + vectors.scalar.len + vectors.doubling.len, vectors.covered.len);
}
