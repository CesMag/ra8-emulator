//! Covers src/chip/core/cpu/mve/bit_reverse_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const br = ra8.chip.core.cpu.mve.bit_reverse;
const vectors = ra8.chip.core.cpu.mve.bit_reverse_vectors;

fn run(in: vectors.BrsrCase) u128 {
    return br.reverseShift(in.a, in.rm, in.size);
}

test "VBRSR matches the pseudocode" {
    try vector.expectAll(vectors.BrsrCase, u128, run, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
