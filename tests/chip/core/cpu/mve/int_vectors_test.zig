//! Covers src/chip/core/cpu/mve/int_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const int = ra8.chip.core.cpu.mve.int;
const vectors = ra8.chip.core.cpu.mve.int_vectors;
const Operands = vectors.Operands;

fn vadd(in: Operands) u128 {
    return int.lanewise(in.a, in.b, in.size, .add);
}

fn vsub(in: Operands) u128 {
    return int.lanewise(in.a, in.b, in.size, .sub);
}

fn vmul(in: Operands) u128 {
    return int.lanewise(in.a, in.b, in.size, .mul);
}

fn vqadd(in: Operands) int.Sat {
    return int.saturating(in.a, in.b, in.size, in.unsigned, false);
}

fn vqsub(in: Operands) int.Sat {
    return int.saturating(in.a, in.b, in.size, in.unsigned, true);
}

fn pairOp(in: vectors.PairCase) u128 {
    const o = in.operands;
    return int.pairwise(o.a, o.b, o.size, o.unsigned, in.op);
}

test "VABD, VMAX, VMIN and the halving ops match the pseudocode" {
    try vector.expectAll(vectors.PairCase, u128, pairOp, &vectors.pair);
}

test "VADD (vector) matches the pseudocode" {
    try vector.expectAll(Operands, u128, vadd, &vectors.add);
}

test "VSUB (vector) matches the pseudocode" {
    try vector.expectAll(Operands, u128, vsub, &vectors.sub);
}

test "VMUL (vector) matches the pseudocode" {
    try vector.expectAll(Operands, u128, vmul, &vectors.mul);
}

test "VQADD (vector) matches the pseudocode" {
    try vector.expectAll(Operands, int.Sat, vqadd, &vectors.qadd);
}

test "VQSUB (vector) matches the pseudocode" {
    try vector.expectAll(Operands, int.Sat, vqsub, &vectors.qsub);
}

test "every vector is counted in covered" {
    const total = vectors.add.len + vectors.sub.len + vectors.mul.len + vectors.qadd.len + vectors.qsub.len + vectors.pair.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}
