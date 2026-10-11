//! Covers src/chip/core/cpu/mve/bitwise_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const bitwise = ra8.chip.core.cpu.mve.bitwise;
const vectors = ra8.chip.core.cpu.mve.bitwise_vectors;

fn run(in: vectors.Case) u128 {
    return bitwise.apply(in.a, in.b, in.op);
}

test "VAND, VBIC, VORR, VORN and VEOR match the pseudocode" {
    try vector.expectAll(vectors.Case, u128, run, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
