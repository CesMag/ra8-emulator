//! Covers src/chip/core/cpu/mve/interleave/vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.chip.core.cpu.conformance.vector;
const interleave = ra8.chip.core.cpu.mve.interleave;
const vectors = ra8.chip.core.cpu.mve.interleave.vectors;

test "VLD2/VLD4/VST2/VST4 beat offsets match the pseudocode" {
    try vector.expectAll(interleave.Beat, u32, interleave.beatOffset, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}
