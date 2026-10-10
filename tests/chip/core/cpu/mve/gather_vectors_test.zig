//! Covers src/chip/core/cpu/mve/gather_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const gather = ra8.chip.core.cpu.mve.gather;
const vectors = ra8.chip.core.cpu.mve.gather_vectors;

test "gather/scatter addresses match the pseudocode" {
    try vector.expectAll(gather.Address, u32, gather.address, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
