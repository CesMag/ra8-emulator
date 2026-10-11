//! Covers src/chip/core/cpu/mve/int_insert_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const int = ra8.chip.core.cpu.mve.int;
const insert = ra8.chip.core.cpu.mve.int.insert;
const shift = ra8.chip.core.cpu.mve.int.shift;
const shift_vectors = ra8.chip.core.cpu.mve.int.shift.vectors;
const vectors = ra8.chip.core.cpu.mve.int.insert.vectors;

fn byInsert(in: vectors.InsertCase) u128 {
    return if (in.right) insert.sri(in.d, in.m, in.size, in.n) else insert.sli(in.d, in.m, in.size, in.n);
}

fn byImmediate(in: shift_vectors.ImmCase) int.Sat {
    return shift.byImmediate(in.a, in.shift, in.size, in.mode);
}

test "VSRI and VSLI match the pseudocode" {
    try vector.expectAll(vectors.InsertCase, u128, byInsert, &vectors.inserts);
}

test "VQSHLU matches the pseudocode" {
    try vector.expectAll(shift_vectors.ImmCase, int.Sat, byImmediate, &vectors.qshlu);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.inserts.len + vectors.qshlu.len, vectors.covered.len);
}
