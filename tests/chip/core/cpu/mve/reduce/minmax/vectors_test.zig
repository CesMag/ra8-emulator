//! Covers src/chip/core/cpu/mve/reduce_minmax_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const rm = ra8.chip.core.cpu.mve.reduce_minmax;
const vectors = ra8.chip.core.cpu.mve.reduce_minmax_vectors;

fn run(in: vectors.MaxCase) u32 {
    return rm.maxminv(in.acc, in.a, in.size, in.mask, in.form);
}

test "VMAXV, VMINV, VMAXAV and VMINAV match the pseudocode" {
    try vector.expectAll(vectors.MaxCase, u32, run, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
