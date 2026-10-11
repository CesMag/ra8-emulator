//! Covers src/chip/core/cpu/mve/compare_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const compare = ra8.chip.core.cpu.mve.compare;
const vectors = ra8.chip.core.cpu.mve.compare.vectors;

fn run(in: vectors.CmpCase) u16 {
    return compare.compare(in.a, in.b, in.size, in.cond);
}

test "VCMP and VPT match the pseudocode" {
    try vector.expectAll(vectors.CmpCase, u16, run, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
