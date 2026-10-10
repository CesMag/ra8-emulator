//! Covers src/chip/core/cpu/mve/gather64_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance_vector;
const gather = ra8.chip.core.cpu.mve.gather;
const vectors = ra8.chip.core.cpu.mve.gather64_vectors;

test "64-bit gather/scatter beat addresses match the pseudocode" {
    try vector.expectAll(gather.Beat, u32, gather.beatAddress, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
